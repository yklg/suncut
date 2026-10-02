import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 全局缩略图缓存（NSCache，自动响应内存压力）
///
/// 用 NSCache 而非 Dictionary：
/// - countLimit / totalCostLimit 自动 eviction
/// - 系统内存压力时自动清理
/// - 多 view 共享，避免重复加载
///
/// ⚠️ 性能要点：磁盘上的缩略图是源分辨率（1080×1920），**直接 `NSImage(contentsOfFile:)` 会全尺寸解码**，
/// 单张占 1080×1920×4 ≈ 8.3MB，150MB 缓存实际只装得下 18 张 → 滚动时反复读盘解码、明显卡顿。
/// 这里改为用 ImageIO **降采样解码**（只解到实际显示需要的像素），单张降到 ≈1.3MB，
/// 同样的内存可缓存 100+ 张，滚动不再颠簸。
///
/// ⚠️ 线程契约（素材库滚动掉帧的修复之一）：
/// - `cachedImage(for:)` **只查缓存，绝不同步解码**——可以安全地在 body 中同步判断；
/// - 缓存未命中必须走 `loadImage(for:)`（async）：在后台降采样解码，可视区由 `.task`
///   以 userInitiated 发起、后台预热以 utility 发起，同路径经 `CoalescingLoader` 合并为一次解码；
/// - 任何「未命中即在当前线程读盘解码」的公开入口都不许再加回来（有源码守卫测试钉着）。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// 降采样长边上限。卡片最大显示宽约 250pt（@2x = 500px），768 足够清晰且省 6 倍内存。
    private static let maxPixelSize: Int = 768

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300                    // 最多 300 张缩略图
        c.totalCostLimit = 150 * 1024 * 1024  // 总 150MB（降采样后约可容纳 110+ 张）
        return c
    }()

    /// 解码失败的路径（文件缺失 / 格式损坏）。
    /// ⚠️ 没有这层的话，一张坏缩略图会在**每次 body 求值**时重新打开文件、重新尝试解码；
    /// 网格滚动时这是每秒几十次的无谓磁盘 IO，且永远不会成功。
    private var failedPaths: Set<String> = []

    /// 在飞解码任务的合并器：同路径（主图与遮罩层、可视区与预热、重复挂载）只解码一次。
    /// 消费者滚出屏被取消不会杀掉共享解码（见 CoalescingLoader 契约）。
    ///
    /// 载荷用 `ThumbLoadResult` 而非 `NSImage?`：**nil 专属于「任务被取消」**
    /// （换项目取消预热 / invalidate），不落 failedPaths；只有 `.failed` 才记失败。
    /// 否则一次取消会让有效路径被永久当成坏图跳过。
    private let loader = CoalescingLoader<String, ThumbLoadResult>()

    private enum ThumbLoadResult: @unchecked Sendable {
        case image(NSImage)
        case failed
    }

    /// 预热批次的外层任务（按项目取消 / 同项目排队）。
    /// 单张解码的合并由 `loader` 负责，这里只管「这批还要不要继续」。
    private var prewarmTask: Task<Void, Never>?
    private var prewarmProjectID: UUID?

    /// 预热批次编号。只用来判断「我是不是最新那一批」，以便跑完后干净地让出 `prewarmTask`，
    /// 不要让一个已经完成的 task 引用长期挂在字典里。
    private var prewarmGeneration = 0

    private init() {}

    /// 同步取缩略图：**只查缓存（含失败表），绝不触发磁盘 IO/解码**。
    /// 未命中返回 nil，由调用方改用 `loadImage(for:)` 异步加载（或直接用 AsyncCachedImage）。
    func cachedImage(for path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        return nil
    }

    /// 异步取缩略图：命中缓存立即返回；未命中在**后台线程降采样解码**后入缓存。
    /// - 同路径并发只解码一次（经 CoalescingLoader 合并）；
    /// - 调用方的 Task 即使被取消（视图滚出屏），共享解码仍会跑完并写缓存，下一次滚回直接命中；
    /// - 可视区按需加载（userInitiated）与后台预热（utility）共用同一条解码通道，不重复解码。
    func loadImage(for path: String, priority: TaskPriority = .userInitiated) async -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard !failedPaths.contains(path) else { return nil }

        let result = await loader.value(for: path, priority: priority) { () -> ThumbLoadResult? in
            // 任务被 invalidate/换项目取消时，detached 工作的取消状态为真：
            // 返回 nil（取消），而不是 .failed——坏图记录只能来自真实的解码失败。
            if Task.isCancelled { return nil }
            guard let image = Self.downsampledImage(path: path) else { return .failed }
            return .image(image)
        }
        // 注意：这里不因调用方取消而丢弃结果——共享工作的结果无论谁还在等都要落缓存。
        switch result {
        case .none:
            // 取消：什么都不记，下次正常重试
            return nil
        case .failed:
            failedPaths.insert(path)
            return nil
        case .image(let image):
            let key = path as NSString
            if cache.object(forKey: key) == nil {
                cache.setObject(image, forKey: key, cost: Self.cost(of: image))
            }
            return image
        }
    }

    /// 预热：异步预加载（utility 优先级；未命中的解码与可视区共用合并器）。
    ///
    /// 取消策略按项目走：**换了项目**才取消上一条（用户已经不在旧项目上，继续解码是纯浪费 CPU）；
    /// **同一个项目**的多次预热排成一条队列接着跑，不再互相掐死。
    func prewarm(paths: [String], for projectID: UUID) {
        let previous: Task<Void, Never>?
        if projectID != prewarmProjectID {
            prewarmTask?.cancel()
            prewarmTask = nil
            previous = nil
        } else {
            previous = prewarmTask          // 同项目：排队接手，而不是取消
        }

        prewarmProjectID = projectID
        prewarmGeneration += 1
        let generation = prewarmGeneration

        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            if let previous { _ = await previous.value }
            for path in paths {
                if Task.isCancelled { return }
                // loadImage 内部已处理「缓存命中 / 已知失败 / 在飞合并」，这里不再重复判断。
                _ = await self?.loadImage(for: path, priority: .utility)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 只有「我仍然是最新一批」才让出手柄，别把后一批的 task 引用清掉
                if generation == self.prewarmGeneration { self.prewarmTask = nil }
            }
        }
    }

    /// 缩略图重新生成后调用：丢弃缓存与失败记录，并**取消在飞的旧解码**
    ///（否则旧图解码完会被重新写回缓存，盖掉即将到来的新图）。
    func invalidate(path: String) {
        cache.removeObject(forKey: path as NSString)
        failedPaths.remove(path)
        Task { await loader.invalidate(path) }
    }

    func clear() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmProjectID = nil
        prewarmGeneration += 1      // 让已在飞的批次跑完时不去清别人的柄
        cache.removeAllObjects()
        failedPaths.removeAll()
        Task { await loader.invalidateAll() }
    }

    // MARK: - 降采样解码

    /// 用 ImageIO 只解码到 `maxPixelSize` 长边，避免全尺寸解码。
    /// `nonisolated` 以便在后台线程（CoalescingLoader 的 detached 工作）直接调用。
    nonisolated private static func downsampledImage(path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else { return nil }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 尊重 EXIF 方向
            kCGImageSourceShouldCacheImmediately: true,         // 在后台线程就完成解码
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 按**实际解码后的像素**计费，而不是 `NSImage.size`（后者是点尺寸，会严重低估/高估）。
    nonisolated private static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first else {
            return Int(image.size.width * image.size.height * 4)
        }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }
}

// MARK: - 异步缩略图视图

/// 缓存缩略图的异步容器：缓存命中直接显示；未命中显示占位，后台解码完成后淡入。
///
/// 用 `.task(id:)` 驱动：滚出屏自动取消等待（共享解码不被杀），路径变化（替换画面切换、
/// 边界调整后首帧换新）自动重取。图片的样式（resizable/aspectRatio/裁剪）由 `imageContent`
/// 闭包决定，本容器只负责「何时有图」。
struct AsyncCachedImage<Placeholder: View, ImageContent: View>: View {
    let path: String?
    @ViewBuilder private let placeholder: () -> Placeholder
    @ViewBuilder private let imageContent: (NSImage) -> ImageContent

    @State private var image: NSImage?

    init(path: String?,
         @ViewBuilder placeholder: @escaping () -> Placeholder,
         @ViewBuilder imageContent: @escaping (NSImage) -> ImageContent) {
        self.path = path
        self.placeholder = placeholder
        self.imageContent = imageContent
    }

    var body: some View {
        ZStack {
            placeholder()
            if let image {
                imageContent(image)
                    .transition(.opacity)
            }
        }
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            // 同步路径只查缓存：预热已命中时零等待、无淡入闪烁。
            if let cached = ThumbnailCache.shared.cachedImage(for: path) {
                image = cached
                return
            }
            let loaded = await ThumbnailCache.shared.loadImage(for: path)
            // 滚出屏或路径已变（同一 task 身份被新 id 取代）时不要写 @State。
            if !Task.isCancelled, let loaded {
                withAnimation(.easeInOut(duration: 0.15)) {
                    image = loaded
                }
            }
        }
    }
}
