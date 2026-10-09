import Foundation
import Testing
@testable import MixCutCore

/// BC：有界并发闸。钉死「视频内串行、跨视频最多 N 路」「取消排队者不启动」。
struct BoundedTaskGateTests {

    @Test("BC-1 5 个任务、闸限 2 → 在飞峰值 ≤2 且全部完成")
    func peakConcurrencyCapped() async throws {
        let gate = BoundedTaskGate(maxConcurrent: 2)
        let state = PeakState()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    try await gate.run {
                        await state.enter(i)
                        try? await Task.sleep(for: .milliseconds(30))
                        await state.exit(i)
                    }
                }
            }
            try await group.waitForAll()
        }

        let peak = await state.peak
        let done = await state.doneCount
        #expect(peak <= 2, "在飞峰值 \(peak) 超过闸限 2")
        #expect(peak == 2, "闸限 2 应允许 2 路并行，实测峰值 \(peak)")
        #expect(done == 5)
    }

    @Test("BC-2 闸限 1 → 严格串行（同时在飞恒为 1，顺序即提交顺序）")
    func serialGateRunsOneAtATimeInOrder() async throws {
        let gate = BoundedTaskGate(maxConcurrent: 1)
        let state = PeakState()
        let order = OrderRecorder()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask {
                    try await gate.run {
                        await order.begin(i)
                        await state.enter(i)
                        #expect(await state.inFlight == 1)
                        try? await Task.sleep(for: .milliseconds(15))
                        await state.exit(i)
                        await order.end(i)
                    }
                }
                // 略错峰提交，保证排队顺序
                try? await Task.sleep(for: .milliseconds(2))
            }
            try await group.waitForAll()
        }
        #expect(await state.peak == 1)
        #expect(await order.begins == [0, 1, 2, 3])
    }

    @Test("BC-3 取消后排队任务不启动；已启动任务自然跑完")
    func cancelSkipsQueuedTasks() async throws {
        let gate = BoundedTaskGate(maxConcurrent: 1)
        let started = StartedSet()

        // 占住唯一许可
        let blockerSettled = AsyncStreamContinuation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await gate.run {
                    await started.add(-1)
                    await blockerSettled.wait()   // 不释放，后续任务全部排队
                }
            }
            // 等 blocker 拿到许可
            try? await Task.sleep(for: .milliseconds(30))

            for i in 0..<3 {
                group.addTask {
                    try? await gate.run { await started.add(i) }
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
            await gate.cancelAll()
            await blockerSettled.fire()

            try? await group.waitForAll()
        }

        let ids = await started.ids
        #expect(ids == [-1], "排队任务不应启动，实得：\(ids.sorted())")
    }

    // MARK: - runCancellable：只取消**一个**排队者，不许动别人的令牌

    @Test("BC-4 排队中被取消：任务体不启动、从队列消失、且没吃掉令牌")
    func cancelWhileQueuedNeverStarts() async throws {
        let gate = BoundedTaskGate(maxConcurrent: 1)
        let started = StartedSet()
        let blockerHold = AsyncStreamContinuation()

        let blocker = Task {
            try? await gate.run {
                await started.add(-1)
                await blockerHold.wait()
            }
        }
        try await waitUntilInFlight(gate, 1)

        let queued = Task {
            try await gate.runCancellable { await started.add(7); return 7 }
        }
        try await waitUntilQueued(gate, 1)
        queued.cancel()

        var threwCancellation = false
        do {
            _ = try await queued.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {}
        let ids = await started.ids
        let queuedNow = await gate.queuedCount
        #expect(threwCancellation, "排队中被取消必须以 CancellationError 退出")
        #expect(queuedNow == 0, "取消者应从队列里消失，实得排队数 \(queuedNow)")
        #expect(ids == [-1], "任务体不该启动，实得：\(ids.sorted())")

        await blockerHold.fire()
        _ = await blocker.value
        // 令牌没被取消动作吃掉：闸还能正常跑满一次
        let after = try await gate.runCancellable { 42 }
        #expect(after == 42)
        #expect(await gate.inFlightCount == 0)
    }

    @Test("BC-5 拿到令牌前后才取消：任务体不启动，令牌当场归还")
    func cancelAfterGrantReturnsToken() async throws {
        let gate = BoundedTaskGate(maxConcurrent: 1)
        let started = StartedSet()

        let task = Task {
            try await gate.runCancellable { await started.add(1); return 1 }
        }
        task.cancel()
        var threwCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {}
        let ids = await started.ids
        let inFlight = await gate.inFlightCount
        #expect(threwCancellation)
        #expect(ids.isEmpty, "任务体不该启动，实得：\(ids.sorted())")
        #expect(inFlight == 0, "令牌必须归还，实得在飞 \(inFlight)")
        #expect(try await gate.runCancellable { 1 } == 1)
    }

    @Test("BC-6 取消落在入队之前也不许把位置永久占住（早到取消分支）")
    func earlyCancelDoesNotLeakSlot() async throws {
        let gate = BoundedTaskGate(maxConcurrent: 1)
        let started = StartedSet()
        let blockerHold = AsyncStreamContinuation()

        let blocker = Task {
            try? await gate.run {
                await started.add(-1)
                await blockerHold.wait()
            }
        }
        try await waitUntilInFlight(gate, 1)

        let doomed = Task {
            try await gate.runCancellable { await started.add(9); return 9 }
        }
        doomed.cancel()                       // 立刻取消：可能早于它排进队列
        var threwCancellation = false
        do {
            _ = try await doomed.value
        } catch is CancellationError {
            threwCancellation = true
        } catch {}
        let idsEarly = await started.ids
        #expect(threwCancellation, "已取消的任务不该成功")
        #expect(idsEarly == [-1], "实得：\(idsEarly.sorted())")

        await blockerHold.fire()
        _ = await blocker.value
        let queuedNow = await gate.queuedCount
        #expect(queuedNow == 0, "队列里不许留下已取消的幽灵，实得 \(queuedNow)")
        // 一路闸限仍能正常工作 = 没有位置被幽灵长期占住
        #expect(try await gate.runCancellable { 1 } == 1)
    }
}

// MARK: - Test helpers

/// 等到闸内在飞数变成 n（轮询 actor 状态，不靠猜时长）。
private func waitUntilInFlight(_ gate: BoundedTaskGate, _ n: Int) async throws {
    for _ in 0..<2_000 {
        if await gate.inFlightCount == n { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let got = await gate.inFlightCount
    Issue.record("等不到在飞数 = \(n)，实得 \(got)")
}

/// 等到排队人数变成 n。
private func waitUntilQueued(_ gate: BoundedTaskGate, _ n: Int) async throws {
    for _ in 0..<2_000 {
        if await gate.queuedCount == n { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let got = await gate.queuedCount
    Issue.record("等不到排队数 = \(n)，实得 \(got)")
}

private actor PeakState {
    var inFlight = 0
    var peak = 0
    var doneCount = 0
    func enter(_: Int) {
        inFlight += 1
        peak = max(peak, inFlight)
    }
    func exit(_: Int) {
        inFlight -= 1
        doneCount += 1
    }
}

private actor OrderRecorder {
    var begins: [Int] = []
    func begin(_ i: Int) { begins.append(i) }
    func end(_: Int) {}
}

private actor StartedSet {
    var ids: Set<Int> = []
    func add(_ i: Int) { ids.insert(i) }
}

/// 单触发等待：任务在 fire 前挂起。
private actor AsyncStreamContinuation {
    private var cont: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { cont = $0 }
    }
    func fire() {
        fired = true
        cont?.resume()
        cont = nil
    }
}
