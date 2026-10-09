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

    /// 排队者带身份标识：`runCancellable` 需要在**入队之前**就落下的取消不被吞掉。
    private struct Waiter {
        let id: UUID
        let cont: CheckedContinuation<Wait, Never>
    }

    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [Waiter] = []
    /// 取消时刻早于入队时刻的 id：入队时立即自检并直接退场，否则会永久占住一个令牌位。
    private var earlyCancelled: Set<UUID> = []
    private var cancelled = false

    public init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// 当前在飞数（已拿到许可、任务体在跑）。
    public var inFlightCount: Int { running }

    /// 排队中的人数（不含在飞）。
    public var queuedCount: Int { waiters.count }

    /// 取消闸：排队者全部以 .cancelled 唤醒且不分配令牌；在飞任务不强制杀死。
    public func cancelAll() {
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.cont.resume(returning: .cancelled) }
    }

    /// 在闸限内执行任务；排队期间被取消则抛 CancellationError，任务体不启动。
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if cancelled { throw CancellationError() }
        let wait = await acquire(id: UUID())
        guard wait == .granted, !cancelled else { throw CancellationError() }
        defer { release() }
        return try await operation()
    }

    /// 同 `run`，但**当前任务**（不是整个闸）被取消时立即退场：
    /// 排队中就抛 `CancellationError` 且不占令牌；已拿到令牌则把令牌归还后再抛。
    /// 用在"取消要秒级生效"的链路上（如导入逐段重认排在 whisper 闸后）。
    public func runCancellable<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if cancelled { throw CancellationError() }
        let id = UUID()
        let wait: Wait = await withTaskCancellationHandler(operation: {
            await self.acquire(id: id)
        }, onCancel: {
            Task { await self.cancelWaiting(id: id) }
        })
        // 令牌已到手，取消却落在"拿到之后"⇒ 先销掉早取消标记再归还，不许让闸少一路
        if wait == .granted { discard(earlyCancelFor: id) }
        guard wait == .granted, !cancelled, !Task.isCancelled else {
            if wait == .granted { release() }
            throw CancellationError()
        }
        defer { release() }
        return try await operation()
    }

    // MARK: - Internals

    private func acquire(id: UUID) async -> Wait {
        if earlyCancelled.contains(id) {
            earlyCancelled.remove(id)
            return .cancelled
        }
        if running < maxConcurrent {
            running += 1
            return .granted
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Wait, Never>) in
            waiters.append(Waiter(id: id, cont: c))
        }
    }

    private func cancelWaiting(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.cont.resume(returning: .cancelled)
            return
        }
        earlyCancelled.insert(id)
    }

    private func discard(earlyCancelFor id: UUID) {
        earlyCancelled.remove(id)
    }

    /// 回收一个令牌并按顺序唤醒排队者；每个被唤醒者都领到一个新令牌。
    private func release() {
        running = max(0, running - 1)
        while running < maxConcurrent, !waiters.isEmpty {
            let next = waiters.removeFirst()
            running += 1
            next.cont.resume(returning: .granted)
        }
    }
}
