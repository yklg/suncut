import Foundation

// ============================================================================
// 有界并发闸（Core actor 原语）—— 整方案跨视频配音：视频内串行、跨视频最多 N 路并行。
//
// 为什么下沉 Core：并发上限是可独立验证的契约（「3 个视频任务在飞峰值 ≤2」），
// 写在 VM 闭包里无法单测。VM 只负责把「每视频一条任务」交给闸执行。
//
// 语义：
// - 任务按提交顺序获得进入许可（FIFO 公平）；
// - 闸 cancelAll 后：排队中的任务收到 .cancelled、任务体不启动、不占令牌；
//   已在执行的任务通过 Task.isCancelled 在计费检查点自行停止，其令牌走正常 release；
// - 单个任务失败不影响其他任务（错误由任务自己处理，闸只做限流）。
// ============================================================================

public actor BoundedTaskGate {

    private enum Wait { case granted, cancelled }

    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Wait, Never>] = []
    private var cancelled = false

    public init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 当前在飞数（已拿到许可、任务体在跑）。
    public var inFlightCount: Int { running }

    /// 取消闸：排队者全部以 .cancelled 唤醒且不分配令牌；在飞任务不强制杀死。
    public func cancelAll() {
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        for c in pending { c.resume(returning: .cancelled) }
    }

    /// 在闸限内执行任务；排队期间被取消则抛 CancellationError，任务体不启动。
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if cancelled { throw CancellationError() }
        let wait = await acquire()
        guard wait == .granted, !cancelled else { throw CancellationError() }
        defer { release() }
        return try await operation()
    }

    // MARK: - Internals

    private func acquire() async -> Wait {
        if running < maxConcurrent {
            running += 1
            return .granted
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Wait, Never>) in
            waiters.append(c)
        }
    }

    /// 回收一个令牌并按顺序唤醒排队者；每个被唤醒者都领到一个新令牌。
    private func release() {
        running = max(0, running - 1)
        while running < maxConcurrent, !waiters.isEmpty {
            let next = waiters.removeFirst()
            running += 1
            next.resume(returning: .granted)
        }
    }
}
