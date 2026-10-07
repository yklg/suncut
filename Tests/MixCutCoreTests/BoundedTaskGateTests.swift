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
                try await gate.run {
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
}

// MARK: - Test helpers

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
