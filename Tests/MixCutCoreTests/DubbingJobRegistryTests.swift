import Foundation
import Testing
@testable import MixCutCore

/// DubbingJobRegistry 契约测试。
/// 种子：CoalescingLoaderTests 的 Gate/Counter 确定性同步（禁 sleep 猜时序）；
/// 以及 DubbingViewModel 旧 busyRefCount 注释记录的真实事故（先结束的作业不得解除整体忙碌）。
@MainActor
@Suite("DubbingJobRegistry")
struct DubbingJobRegistryTests {

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func parkedTask(_ gate: Gate, _ tracker: TrackedCancellation) -> Task<Void, Never> {
        Task {
            await tracker.started()
            await gate.wait()
            if Task.isCancelled { await tracker.cancelled() }
        }
    }

    @Test("引用计数：两次 begin、一次 end 仍忙碌；归零才空闲（双作业事故契约）")
    func refCountOverlap() {
        let r = DubbingJobRegistry()
        let v = UUID()
        r.begin(v)
        r.begin(v)
        #expect(r.isBusy(v))
        r.end(v)
        #expect(r.isBusy(v), "先结束的作业不得解除忙碌（否则用户能重复触发付费链路）")
        r.end(v)
        #expect(!r.isBusy(v))
        #expect(r.slot(v) == nil, "归零必须清整键")
    }

    @Test("end 未 begin 的键：不崩溃、不留幽灵键")
    func endWithoutBegin() {
        let r = DubbingJobRegistry()
        let v = UUID()
        r.end(v)
        #expect(!r.isBusy(v))
        #expect(r.slot(v) == nil)
    }

    @Test("register/removeTask：句柄正常登记与摘除")
    func registerAndRemove() {
        let r = DubbingJobRegistry()
        let v = UUID()
        r.begin(v)
        defer { r.end(v) }
        let id = UUID()
        r.register(v, taskID: id, targets: [UUID()], name: "a.mp4", task: Task {})
        #expect(r.slot(v)?.taskIDs == [id])
        #expect(r.canStop(v))
        r.removeTask(v, taskID: id)
        #expect(r.slot(v)?.taskIDs == [])
        #expect(!r.canStop(v))
    }

    @Test("compare-and-remove：任务 A 结束不得清掉后登记的任务 B")
    func removeOnlyOwnHandle() async {
        let r = DubbingJobRegistry()
        let v = UUID()
        r.begin(v)
        defer { r.end(v) }
        let idA = UUID()
        let idB = UUID()
        r.register(v, taskID: idA, targets: [], name: "a", task: Task {})
        r.register(v, taskID: idB, targets: [], name: "a", task: Task {})
        r.removeTask(v, taskID: idA)
        #expect(r.slot(v)?.taskIDs == [idB])
        // 让 Task {} 结构有机会落地，避免未使用告警语义不清。
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    @Test("cancel(k)：只取消 k 的句柄，他键任务继续")
    func cancelIsolatesOtherVideo() async {
        let r = DubbingJobRegistry()
        let v1 = UUID(); let v2 = UUID()
        let g1 = Gate(); let g2 = Gate()
        let t1 = TrackedCancellation(); let t2 = TrackedCancellation()
        r.begin(v1); r.begin(v2)
        r.register(v1, taskID: UUID(), targets: [], name: "1", task: parkedTask(g1, t1))
        r.register(v2, taskID: UUID(), targets: [], name: "2", task: parkedTask(g2, t2))
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(r.cancel(v1))
        await g1.open(); await g2.open()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let cancelled1 = await t1.didCancel
        let cancelled2 = await t2.didCancel
        #expect(cancelled1)
        #expect(!cancelled2, "取消一个视频不得波及另一个视频的作业")
        r.end(v1); r.end(v2)
    }

    @Test("cancel：无句柄时返回 false（MCP 直跑管线不可由 UI 停）")
    func cancelWithoutHandles() {
        let r = DubbingJobRegistry()
        let v = UUID()
        #expect(!r.cancel(v))
    }

    @Test("cancelAll：取消全部并返回受影响键集合")
    func cancelAllReturnsKeys() async {
        let r = DubbingJobRegistry()
        let v1 = UUID(); let v2 = UUID(); let v3 = UUID()
        let g = Gate()
        let t = TrackedCancellation()
        r.begin(v1); r.begin(v2); r.begin(v3)
        r.register(v1, taskID: UUID(), targets: [], name: "1", task: parkedTask(g, t))
        r.register(v2, taskID: UUID(), targets: [], name: "2", task: parkedTask(g, t))
        // v3 只有忙碌计数、无句柄 → 不在返回集合
        let changed = r.cancelAll()
        #expect(changed == [v1, v2])
        await g.open()
        r.end(v1); r.end(v2); r.end(v3)
    }

    @Test("首引建槽记 startedAt；二次 begin 不覆盖；归零清空")
    func startedAtSemantics() {
        let r = DubbingJobRegistry()
        let v = UUID()
        let t0 = Date()
        r.begin(v)
        guard let s1 = r.slot(v)?.startedAt else {
            Issue.record("首引必须记录开始时间"); return
        }
        #expect(s1 >= t0)
        r.begin(v)
        #expect(r.slot(v)?.startedAt == s1, "后续引用不得重置计时起点")
        r.end(v); r.end(v)
        #expect(r.slot(v) == nil)
    }

    @Test("进度写读一致；槽位销毁后读数归零")
    func progressLifecycle() {
        let r = DubbingJobRegistry()
        let v = UUID()
        r.begin(v)
        r.setProgress(v, DubbingJobProgress(phase: .rewrite, phaseText: "改写第 1/2 套…", fraction: 0.5))
        #expect(r.progressText(v) == "改写第 1/2 套…")
        #expect(r.slot(v)?.progress.fraction == 0.5)
        r.end(v)
        #expect(r.progressText(v) == "")
    }

    @Test("setProgress 对不存在的槽位 no-op（管线收尾竞争不崩）")
    func setProgressAfterEnd() {
        let r = DubbingJobRegistry()
        r.setProgress(UUID(), DubbingJobProgress(phase: .rewrite, phaseText: "x"))
        #expect(r.busyIDs.isEmpty)
    }

    @Test("两个视频的忙碌/进度互不联动")
    func videosIndependent() {
        let r = DubbingJobRegistry()
        let v1 = UUID(); let v2 = UUID()
        r.begin(v1); r.begin(v2)
        r.setProgress(v1, DubbingJobProgress(phase: .prepareClone, phaseText: "分离人声…"))
        #expect(r.isBusy(v1)); #expect(r.isBusy(v2))
        #expect(r.progressText(v2) == "")
        #expect(r.busyIDs == [v1, v2])
        r.end(v1)
        #expect(!r.isBusy(v1)); #expect(r.isBusy(v2))
        r.end(v2)
        #expect(r.busyIDs.isEmpty)
    }

    // MARK: 进程级共享与修订号

    @Test("shared 是进程级单例：两次访问同一对象；public init 仍给独立实例")
    func sharedIsProcessWideSingleton() {
        #expect(DubbingJobRegistry.shared === DubbingJobRegistry.shared)
        let isolated = DubbingJobRegistry()
        #expect(isolated !== DubbingJobRegistry.shared, "测试用独立实例不得与 shared 同体")
    }

    @Test("revision：状态变更自增，供跨实例（UI/MCP）观察投影")
    func revisionBumpsOnMutations() {
        let r = DubbingJobRegistry()
        let v = UUID()
        let r0 = r.revision
        r.begin(v)
        #expect(r.revision > r0)
        let r1 = r.revision
        r.setProgress(v, DubbingJobProgress(phase: .rewrite, phaseText: "x"))
        #expect(r.revision > r1)
        let r2 = r.revision
        r.end(v)
        #expect(r.revision > r2)
        // 无状态变化的 no-op 不得自增（避免无谓 UI 刷新）。
        let r3 = r.revision
        r.end(UUID())
        r.setProgress(UUID(), DubbingJobProgress(phase: .rewrite, phaseText: "x"))
        #expect(r.revision == r3, "no-op 路径不应推进 revision")
    }
}

private actor TrackedCancellation {
    private(set) var didCancel = false
    private var startedCount = 0
    func started() { startedCount += 1 }
    func cancelled() { didCancel = true }
}
