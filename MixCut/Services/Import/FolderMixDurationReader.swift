import Foundation
import AVFoundation
import SwiftData
// 没有 `import MixCutCore`：本工程把 Core 源码逐文件编进 App target（同模块），
// 写 import 反而编不过 —— 见 `MixCut/App/LaunchSteps.swift` 顶部那条同样说明。

// ============================================================================
// 文件夹混剪 · 时长两层解析（D33 的第二层入口）
//
// 分工（守卫 G-c 的同一口径：判定住 Core，这里只做装配与 IO）：
//   · **第一层在 Core**：`FolderMixLibrary.duration(of:)` 判"库里那份算不算命中"，
//     `FolderMixResolver.plan(...)` 算"哪些还得读盘"（含预算截断）。所以"库里命中 ⇒ 零读盘"
//     这条能被 `swift test` 钉住（FMX-14），不靠真机目测。
//   · 这颗 enum 只做两件事：把库里的两列读成 `FolderMixLibraryRecord`、对未命中的路径
//     逐条付一次 `AVURLAsset` 解析。
//
// 为什么不写死并发颗数：走 `ConcurrencyPolicy.maxProbeConcurrency()`（硬件派生 +
//   `UserDefaults` 覆盖键 + 环境变量覆盖键，与导入分析那颗同一套约定）。
// 为什么闸要复用而不是新造：`BoundedTaskGate` 已经有 FIFO 许可、`cancelAll`、`inFlightCount`
//   三件，且取消语义有整套判据（`BoundedTaskGateTests` BC-3…BC-6）。这里再写一套
//   `withTaskGroup`/信号量 = 把已证过的东西重新变成未证的（判据 T-28 钉这条）。
//
// 拦不住什么 / 最坏代价：探针是"读时长"，不是解码 —— 单条成本是解析容器头，
//   实测读数由真机端到端第 2 步回填（本文件不声称已经量过）。预算封顶
//   `FolderMixLimits.durationProbeBudgetFiles`，超出部分留 nil（界面显示「—」）。
// ============================================================================

/// 只读时长回填器。**不持有、不写入任何 UI 状态**（T-24 的同一规矩）。
@MainActor
enum FolderMixDurationReader {

    /// 扫描期第一层的取数：**按文件名**去问库里那份（计划 2026-10-22 决议 J3）。
    ///
    /// 为什么不按路径问（旧写法就是它，永不相交）：库里那一行的路径是拷贝落地的
    /// `<应用程序支持>/videos/<校验和>/<文件名>`，与素材目录里的路径是两个域 ——
    /// 真机实测「库里命中时长 0、待探 59」，而那 59 条其实全在库里。
    /// 为什么此刻只能猜：真正的对应关系要到生成期入库那一刻才存在（见 `FolderMixLibraryJoin`
    /// 与 `ClipIngestService` 交回的那张表）。这层的产物**只喂磁盘与耗时预估**，
    /// 不参与出片正确性 —— 所以它故意不返回任何 id，拼不出一条方案。
    ///
    /// 判定本体（H1 相等口径 / H2 同名多行整条不采信 / H3 认不出退探针）在 Core，
    /// `swift test` 钉得住（TC-J4/J5、H1/H2 那四条）；这里只做一次 fetch + 装配。
    static func libraryGuess(files: [FolderMixScannedFile], in context: ModelContext)
        -> FolderMixNameHeuristic.Outcome {
        guard !files.isEmpty else {
            return FolderMixNameHeuristic.guess(files: [], libraryRows: [])
        }
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        let rows = videos.map { video in
            FolderMixLibraryNameRow(videoName: video.name,
                                    record: FolderMixLibraryRecord(contentHash: video.contentHash,
                                                                   durationSeconds: video.duration))
        }
        return FolderMixNameHeuristic.guess(files: files, libraryRows: rows)
    }

    /// 第二层：对**计划里排进来的**路径并发读时长，边读边回吐（渐进回填的形状由这里定）。
    ///
    /// - Parameters:
    ///   - paths: 只该收到 `FolderMixProbePlan.durationProbePaths`（预算与"库里命中就跳过"
    ///     都在 Core 判过 —— 这里再判一次就是第二份真源）。
    ///   - gate: 既有 `BoundedTaskGate`，颗数来自 `ConcurrencyPolicy.maxProbeConcurrency()`。
    ///   - probe: 探针缝。真链路传 `assetDuration`；判据/基准传假探针**数调用次数** ——
    ///     没有这颗缝，"库里命中 ⇒ 零读盘"只能在真机上开 Instruments 看，那就不是判据。
    ///
    /// 为什么回吐用 `AsyncStream` 而不是 `@MainActor` 回调：并发子任务里直接调主 actor 闭包
    /// 要把闭包标成跨隔离传参，编译期能过但语义含糊；流则由调用方（`FolderMixViewModel`，
    /// 本来就在 MainActor 上）`for await` 消费，回填显示与取消传播都留在调用方那一侧
    /// （照 `MixCut/Views/Shared/ThumbnailCache.swift` 的「占位 → 异步补 → 取消安全」形状）。
    static func readings(paths: [String],
                         gate: BoundedTaskGate,
                         probe: @escaping @Sendable (URL) async -> Double?
    ) -> AsyncStream<FolderMixDurationReading> {
        MixLog.info("[FolderMix] 时长探针起：待读 \(paths.count) 条（库里已命中者不在清单里）")
        return AsyncStream { continuation in
            let work = Task {
                await withTaskGroup(of: Void.self) { group in
                    for path in paths {
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            do {
                                let seconds = try await gate.runCancellable {
                                    await probe(URL(fileURLWithPath: path))
                                }
                                continuation.yield(FolderMixDurationReading(path: path,
                                                                            seconds: seconds))
                                if seconds == nil {
                                    // 逐名出声（第九节「读不出时长」档）：界面上是「—」，
                                    // 日志里要能说**是哪一条**，否则报障只有一句"有几个没读到"。
                                    MixLog.info("[FolderMix] 时长读不出：\(path)")
                                }
                            } catch {
                                // 只有 CancellationError 走得进来（探针不抛）。
                                // 这条**不回吐**：界面对它保持「—」，而不是把"取消"报成"0 秒"。
                                MixLog.info("[FolderMix] 时长探针被取消：\(path)")
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// 真探针：AVFoundation 只解析容器时长，不起解码、不产缩略图、不写库。
    /// 读不出（损坏 / 格式不支持 / 文件在扫描之后被移走）返回 nil —— 由调用方显示「—」，
    /// **不许**在这里替它编一个 0（决定 6）。
    static func assetDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds > 0, seconds.isFinite else { return nil }
        return seconds
    }

    /// 取消 = 把闸的整体取消透传下去（复用既有语义，不自己实现"任务取消"）。
    /// 之后 `inFlightCount` 会随在飞任务自然跑完归零，排队者当场退场不占令牌
    /// （这两条已有整套判据：`BoundedTaskGateTests` 的 BC-3…BC-6，本轮不重写一遍）。
    static func cancel(_ gate: BoundedTaskGate) {
        Task { await gate.cancelAll() }
    }
}

/// 一条第二层读数。`seconds == nil` = 读了但读不出（损坏/格式不支持/文件已不在盘上），
/// 与"没读"（这条压根不出现在流里，被取消了）在调用方是两种显示，别混。
struct FolderMixDurationReading: Sendable {
    let path: String
    let seconds: Double?
}
