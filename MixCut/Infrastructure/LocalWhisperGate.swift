import Foundation

// 没有 `import MixCutCore`：Core 源码是逐文件编进 App target 的（见 LaunchSteps.swift 顶部说明），
// BoundedTaskGate 与这里同模块，写 import 反而编不过。

/// 本机 whisper 的**全局单模型闸门**：把 `ConcurrencyPolicy.maxASRConcurrency()`
/// 从"只有设置页文案在读"的死配置，变成链路上真的挡一道。
///
/// 实测依据（计划 §Q-2，同机 Apple M4 base / 32GB / large-v3）：
/// 两个 whisper 进程并行跑两条 5s 音频 = **27s**，同一对任务串行 = **8s**；
/// 而基线里逐段重听被整片识别挤到 11.1s/段（无争用时 4.8s/段，§Q-1）。
/// 所以本机这条腿**并行是负收益**，闸门的数必须真的生效，而不是只写在注释里。
///
/// 闸加在 `ASRService` 的两个进程汇流点上（整片识别与逐段重听都从那里出去），
/// 因此调用方无从绕过；排队期间允许被取消，避免导入取消后还挂在队列里等一整轮。
actor LocalWhisperGate {

    static let shared = LocalWhisperGate()

    private var inner: BoundedTaskGate?

    private func gate() async -> BoundedTaskGate {
        if let inner { return inner }
        let permits = await MainActor.run { ConcurrencyPolicy.maxASRConcurrency() }
        let created = BoundedTaskGate(maxConcurrent: permits)
        inner = created
        return created
    }

    /// 在本机识别闸内跑一次识别。当前任务被取消时立即退场并抛 `CancellationError`。
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let inner = await gate()
        // 排队要留痕：导入一批素材时"这条怎么还不动"是用户最常误判成卡死的时刻，
        // 而这一层串行是刻意的（并行实测更慢），日志里必须看得出来。
        let busy = await inner.inFlightCount
        if busy > 0 {
            MixLog.info("[ASR闸] 本机识别排队中（前面 \(busy) 路在跑）—— 单模型闸刻意串行，不是卡死")
        }
        return try await inner.runCancellable(operation)
    }
}
