import Foundation
// 没有 `import MixCutCore`：Core 源码逐文件编进 App target（同模块），写 import 反而编不过
// —— 见 `MixCut/App/LaunchSteps.swift` 顶部那条同样说明。

// ============================================================================
// 文件夹混剪 · 「精确识别（慢）」的第二层（D31 / 决定 8）
//
// 它只做一件事：对**计划里排进来的**路径现算内容校验和。
//
// 为什么这颗 reader 在默认档下**一次都不该被调到**：
//   「精确识别」关闭时 `FolderMixResolver.plan(preciseIdentity: false, ...)` 返回的
//   `identityProbePaths` 恒为空 ⇒ 这里收到空清单，一次哈希都不算。
//   这条不是顺手写的分支，是被判据钉着的：Core 侧 FMX-14b（把 `plan` 里的
//   `if preciseIdentity` 摘掉必红），App 侧 T-23（本类型的调用点全仓恰好 1 处，
//   且必须挂在开关分支上）。为什么两边都要钉：只钉 App 的那条 grep 抓不到"有人图省事
//   总是算一遍"，只钉 Core 的那条又管不住 App 直接绕过 plan 自己发哈希。
//
// 口径（不许在界面上写成"完全相同"）：`ClipIngestService.computeFileHash` 是
//   SHA-256 over `String(fileSize)` + 头 4 MB + 尾 4 MB —— **不是整片**。
//   所以页面文案只能写「按大小 + 头尾各 4 MB 校验和归并内容相同的素材」。
//
// 成本与红利：已在库的素材那份哈希早就是 `Video.contentHash`（第一层，零成本，
//   由 `FolderMixDurationReader.libraryGuess` 一并取回），≈8 MB/条只发生在未入库的文件上
//   ⇒ 同一目录重扫近乎免费，首次扫大目录才贵。收益读数（「库里已有 X 条｜需新算 Y 条」）
//   由 `FolderMixProbePlan.libraryIdentityHits / identityProbePaths` 直接给。
//
// 为什么 `compute` 是注入缝而不是硬调：数「算了几次」是这条通路唯一的可机检形态；
//   没有缝就只能靠真机掐秒表。真链路传 `ClipIngestService.computeFileHash`。
// ============================================================================

/// 一条内容键读数。`hash == nil` = 算了但读不出（文件不可读 / 在扫描之后被移走）——
/// 调用方必须**逐名**上报，不许退回用路径当键：那会让同一内容在这一轮里算两个候选，
/// 而用户以为开关生效了。
struct FolderMixContentKeyReading: Sendable {
    let path: String
    let hash: String?
}

/// 内容键第二层。**不持有、不写入任何 UI 状态**（T-24 的同一规矩）。
@MainActor
enum FolderMixContentKeyReader {

    /// 并发读哈希，颗数由调用方给的闸决定（同一个 `ConcurrencyPolicy.maxProbeConcurrency()`）。
    ///
    /// 与时长那颗同形（`AsyncStream` 逐条回吐）：两条探针都是"后台渐进补数"，
    /// 形状统一才只有一处会写错。
    static func readings(paths: [String],
                         gate: BoundedTaskGate,
                         compute: @escaping @Sendable (String) -> String?
    ) -> AsyncStream<FolderMixContentKeyReading> {
        MixLog.info("[FolderMix] 校验和探针起：待算 \(paths.count) 条（库里已有哈希者不在清单里）")
        return AsyncStream { continuation in
            let work = Task {
                await withTaskGroup(of: Void.self) { group in
                    for path in paths {
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            do {
                                let hash = try await gate.runCancellable { compute(path) }
                                continuation.yield(FolderMixContentKeyReading(path: path, hash: hash))
                            } catch {
                                // 只有 CancellationError 走得进来（compute 不抛）⇒ 不回吐、不退回路径键。
                                MixLog.info("[FolderMix] 校验和探针被取消：\(path)")
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
