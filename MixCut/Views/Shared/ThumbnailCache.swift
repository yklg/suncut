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

    /// 在飞的预热任务，以及它属于哪个项目。
    ///
    /// 旧实现是「一条全局 task + 每次调用无条件 cancel」：分镜库在同一个 `.task` 里先预热视频封面、
    /// 再预热分镜封面，第二次调用必然掐死第一次 —— 视频封面从来没预热成过，第一次上屏全靠主线程同步解码。
    private var prewarmTask: Task<Void, Never>?
    private var prewarmProjectID: UUID?

    /// 预热批次编号。只用来判断「我是不是最新那一批」，以便跑完后干净地让出 `prewarmTask`，
    /// 不要让一个已经完成的 task 引用长期挂在字典里。
    private var prewarmGeneration = 0

    private init() {}

    /// 同步取缩略图（已缓存就返回，未缓存就降采样加载并缓存）
    func image(for path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard !failedPaths.contains(path) else { return nil }
        guard let img = Self.downsampledImage(path: path) else {
            failedPaths.insert(path)
            return nil
        }
        cache.setObject(img, forKey: key, cost: Self.cost(of: img))
        return img
    }

    /// 预热：异步预加载（后台线程降采样解码，主线程入缓存）。
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

        prewarmTask = Task.detached(priority: .utility) {
            if let previous { _ = await previous.value }
            for path in paths {
                if Task.isCancelled { return }
                // 已在缓存里、或已知解码失败的，直接跳过
                let skip = await MainActor.run {
                    self.cache.object(forKey: path as NSString) != nil || self.failedPaths.contains(path)
                }
                if skip { continue }
                guard let img = Self.downsampledImage(path: path) else {
                    await MainActor.run { _ = self.failedPaths.insert(path) }
                    continue
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    let key = path as NSString
                    if self.cache.object(forKey: key) == nil {
                        self.cache.setObject(img, forKey: key, cost: Self.cost(of: img))
                    }
                }
            }
            await MainActor.run {
                // 只有「我仍然是最新一批」才让出手柄，别把后一批的 task 引用清掉
                if generation == self.prewarmGeneration { self.prewarmTask = nil }
            }
        }
    }

    /// 缩略图重新生成后调用，让这个路径有机会重新解码。
    func invalidate(path: String) {
        cache.removeObject(forKey: path as NSString)
        failedPaths.remove(path)
    }

    func clear() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmProjectID = nil
        prewarmGeneration += 1      // 让已在飞的批次跑完时不去清别人的柄
        cache.removeAllObjects()
        failedPaths.removeAll()
    }

    // MARK: - 降采样解码

    /// 用 ImageIO 只解码到 `maxPixelSize` 长边，避免全尺寸解码。
    /// `nonisolated` 以便 `prewarm` 在后台线程直接调用。
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
