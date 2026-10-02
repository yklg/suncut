import Foundation
import Testing

/// 缩略图线程契约守卫：
/// 1. ThumbnailCache 不允许存在「未命中即在当前线程同步解码」的公开入口
///    （旧 `func image(for:)` 就是它：body 里调一下就是一次主线程 ImageIO 解码，快速滚动掉帧）；
/// 2. 必须保留一对新契约：`cachedImage`（只查缓存）与 `loadImage`（async 后台解码）；
/// 3. 全仓 MixCut/ 下不允许再出现 `ThumbnailCache.shared.image(` 形态的调用。
///
/// 注释不报错，所以这是源码扫描而非口头约定。
private let tcGuardRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func tcGuardRead(_ rel: String) -> String {
    (try? String(contentsOf: tcGuardRepoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

private func tcGuardSwiftFiles(under dir: String) -> [String] {
    let base = tcGuardRepoRoot.appendingPathComponent(dir)
    guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
    return en.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
}

struct ThumbnailCacheContractGuardTests {
    @Test("同步解码入口不得复活；新契约必须在场")
    func cacheContractIntact() {
        let rel = "MixCut/Views/Shared/ThumbnailCache.swift"
        let src = tcGuardRead(rel)
        #expect(src.count > 200, "读不到 ThumbnailCache.swift，判据没跑起来")

        let stripped = TagRowHostScan.codeOnly(src)   // 复用剥注释/字符串的公共件
        let code = String(stripped)

        #expect(!code.contains("func image(for "),
                "又出现了同步取图入口（未命中会在调用线程同步解码）。body 里请用 cachedImage/loadImage（AsyncCachedImage）。")
        #expect(code.contains("func cachedImage(for "),
                "cachedImage(for:) 契约缺失：需要一个只查缓存、绝不解码的同步入口")
        #expect(code.contains("func loadImage(for "),
                "loadImage(for:) 契约缺失：缓存未命中必须走 async 后台解码")
        #expect(code.contains("CoalescingLoader<"),
                "异步解码必须经 CoalescingLoader 合并，别重新引入每条调用各自解码")
    }

    @Test("全仓不得再有 ThumbnailCache.shared.image( 形态的调用")
    func noCallerInvokesSyncDecode() {
        let files = tcGuardSwiftFiles(under: "MixCut")
        #expect(files.count >= 50, "扫描到的文件数异常，判据可能没跑在仓库根上")
        var offenders: [String] = []
        for path in files {
            let src = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let code = String(TagRowHostScan.codeOnly(src))
            if code.contains("ThumbnailCache.shared.image(") {
                offenders.append((path as NSString).lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "这些文件仍在同步取图（未命中=主线程解码）：\(offenders)。改用 AsyncCachedImage 或 cachedImage + loadImage。")
    }
}
