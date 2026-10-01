import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 批 1 · 1.3-A 撤销宽限事务状态机的判据用例（UG-01~14）
//
// 本文件锁定的接口：
//   enum UndoPhase { idle, armed, undone, expired, flushed }
//   struct UndoTicket { id, kind(.deletion|.batchOverwrite), message, actionTitle,
//                       graceSeconds, armedAt ; var deadline ; var needsCommitOnSettle }
//   enum UndoDecision { performUndo(UndoTicket), tooLate(commit: UndoTicket?), stale }
//   struct UndoGraceMachine { ticket, phase, isStripVisible, secondsLeft(now:),
//                             arm(_:), requestUndo(id:now:), expire(id:now:), flush(id:),
//                             static armMessage(lost:next:) }
//
// 规则（每条都对应审查报告里一条会被 5s→300s 放大的竞态）：
//   R1 浮条可见 ⟺ phase == .armed。了结（undo / expire / flush / 被顶掉）必须**同帧**收回浮条。
//   R2 每枚 ticket 的真删义务只交出去一次 ⇒ 重复 expire/flush 返回 nil，迟到点击判 .stale。
//      这条是"撤销把已真删对象放回界面"（竞态①）在类型层写不出来的根据。
//   R3 只有"当前这枚、仍 armed、且 now < deadline"三者同时成立才执行 undo。
//   R4 到点判定用 `>= deadline`，与 requestUndo 的 `< deadline` 互补 ⇒ 边界上不留空隙、不留重叠。
//   R5 batchOverwrite 类不欠真删（改动已落库，到点无事可做），但**照样**收回浮条。
//   R6 顶掉旧事务时，新浮条文案必须交代旧的那条已怎么着了（竞态②的可见性）。
//   R7 迟到的旧定时器不许动当前事务：带 id 的转换一律按 id 匹配。
//
// ⚠️ 契约（App 侧必须配合，本文件测不到）：`UndoGraceMachine` 是**唯一**的浮条可见性来源。
// 若 App 侧另用 `ToastCenter.current` 决定撤销条显示，R1/R2 整体失真 —— 挂在防回潮守卫上。
// ============================================================================

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 固定基准，避免用例间隔秒漂移
private let grace: Double = 300                               // 1.3 的目标宽限期：5 分钟

private func deletion(_ msg: String = "已删除分镜",
                      at armedAt: Date = t0,
                      seconds: Double = grace) -> UndoTicket {
    UndoTicket(kind: .deletion, message: msg, actionTitle: "撤销删除",
               graceSeconds: seconds, armedAt: armedAt)
}

private func batch(_ msg: String = "已把遮挡设置应用到 16 个分镜",
                   at armedAt: Date = t0,
                   seconds: Double = 5) -> UndoTicket {
    UndoTicket(kind: .batchOverwrite, message: msg, actionTitle: "撤销批量遮挡",
               graceSeconds: seconds, armedAt: armedAt)
}

@Suite("UndoGraceMachine · 撤销宽限事务判据")
struct UndoGraceMachineTests {

    // MARK: R1 可见性唯一判据

    @Test("UG-01 初始 idle：浮条不可见、剩余 0 秒")
    func initialIdle() {
        var m = UndoGraceMachine()
        #expect(m.phase == .idle)
        #expect(m.ticket == nil)
        #expect(!m.isStripVisible)
        #expect(m.secondsLeft(now: t0) == 0)
    }

    @Test("UG-02 arm 之后 armed：浮条可见、剩余等于宽限期")
    func armBecomesVisible() {
        var m = UndoGraceMachine()
        let lost = m.arm(deletion())
        #expect(lost == nil)                       // 之前没挂着的事务
        #expect(m.phase == .armed)
        #expect(m.isStripVisible)
        #expect(m.secondsLeft(now: t0) == grace)
    }

    @Test("UG-03 竞态①主案：flush 了结事务的同帧，浮条收回")
    func flushHidesStripSameFrame() {
        var m = UndoGraceMachine()
        let ticket = deletion()
        _ = m.arm(ticket)
        let commit = m.flush()
        #expect(commit == ticket)                  // 真删义务交出去了
        #expect(m.phase == .flushed)
        #expect(!m.isStripVisible)                 // ← 现状缺的就是这一条
    }

    @Test("UG-04 flush 之后再点撤销判 stale，且不再交出真删义务")
    func undoAfterFlushIsImpossible() {
        var m = UndoGraceMachine()
        let ticket = deletion()
        _ = m.arm(ticket)
        _ = m.flush()
        #expect(m.requestUndo(id: ticket.id, now: t0.addingTimeInterval(1)) == .stale)
        #expect(m.flush() == nil)                  // 义务只交一次，不会二次真删
    }

    @Test("UG-04b 反向对照：armed 内点击必须真的撤销（防 UG-04 测成恒真）")
    func undoInsideGraceStillWorks() {
        var m = UndoGraceMachine()
        let ticket = deletion()
        _ = m.arm(ticket)
        #expect(m.requestUndo(id: ticket.id, now: t0.addingTimeInterval(299)) == .performUndo(ticket))
        #expect(m.phase == .undone)
        #expect(!m.isStripVisible)
    }

    // MARK: R4 边界三点法

    @Test("UG-05 到点判定三点：差 1 秒不算到期、恰好到期算、之后不重复交义务")
    func expireBoundaryThreePoints() {
        // 差 1 秒：仍 armed，不交出真删
        var early = UndoGraceMachine()
        let a = deletion()
        _ = early.arm(a)
        #expect(early.expire(id: a.id, now: t0.addingTimeInterval(299)) == nil)
        #expect(early.isStripVisible)

        // 恰好 deadline：转 expired，交出真删，浮条收回
        #expect(early.expire(id: a.id, now: t0.addingTimeInterval(300)) == a)
        #expect(early.phase == .expired)
        #expect(!early.isStripVisible)

        // 再叫一次：不重复交义务
        #expect(early.expire(id: a.id, now: t0.addingTimeInterval(301)) == nil)
    }

    @Test("UG-06 主线程忙导致定时器没跑到：过期后的点击补交真删，而不是执行 undo")
    func clickAtOrAfterDeadlineCommits() {
        var m = UndoGraceMachine()
        let ticket = deletion()
        _ = m.arm(ticket)
        let decision = m.requestUndo(id: ticket.id, now: t0.addingTimeInterval(300))
        #expect(decision == .tooLate(commit: ticket))
        #expect(m.phase == .expired)
        #expect(!m.isStripVisible)
        // 补交之后再来一次迟到点击：stale，不会二次真删
        #expect(m.requestUndo(id: ticket.id, now: t0.addingTimeInterval(301)) == .stale)
    }

    // MARK: R5 批量覆盖类

    @Test("UG-07 批量覆盖：flush 不欠真删，但浮条照样收回")
    func batchOverwriteFlushesWithoutCommit() {
        var m = UndoGraceMachine()
        let ticket = batch()
        _ = m.arm(ticket)
        #expect(m.flush() == nil)                  // 改动已落库，到点/被切项目都无事可做
        #expect(m.phase == .flushed)
        #expect(!m.isStripVisible)
    }

    @Test("UG-07b 批量覆盖过期：tooLate 的 commit 必须是 nil（不能把批量覆盖当真删）")
    func batchOverwriteExpireCarriesNoCommit() {
        var m = UndoGraceMachine()
        let ticket = batch(seconds: 5)
        _ = m.arm(ticket)
        #expect(m.requestUndo(id: ticket.id, now: t0.addingTimeInterval(5)) == .tooLate(commit: nil))
    }

    // MARK: R6 顶掉旧事务

    @Test("UG-08 连删两条：前一条被顶掉时必须以「已确认删除」交代")
    func displacedDeletionIsDisclosed() {
        var m = UndoGraceMachine()
        let first = deletion("已删除分镜 #3")
        _ = m.arm(first)
        let next = deletion("已删除分镜 #7")
        let lost = m.arm(next)
        #expect(lost == first)                     // App 侧拿到它就得立刻真删
        #expect(m.ticket == next)
        let text = UndoGraceMachine.armMessage(lost: lost, next: next)
        #expect(text == "已删除分镜 #7（上一条「已删除分镜 #3」已确认删除）")
    }

    @Test("UG-08b 正向对照：没有旧事务时文案就是原句，不得凭空多出「上一条」")
    func firstArmMessageIsPlain() {
        let next = deletion("已删除分镜 #3")
        #expect(UndoGraceMachine.armMessage(lost: nil, next: next) == "已删除分镜 #3")
    }

    @Test("UG-09 顶掉的是批量覆盖类：文案说「已生效」而不是「已确认删除」")
    func displacedBatchSaysEffective() {
        let lost = batch()
        let next = deletion()
        let text = UndoGraceMachine.armMessage(lost: lost, next: next)
        #expect(text == "已删除分镜（上一条「已把遮挡设置应用到 16 个分镜」已生效）")
    }

    // MARK: R7 迟到的旧定时器

    @Test("UG-10 旧事务的迟到 expire / flush 不得动当前事务")
    func staleTimersCannotKillCurrentTicket() {
        var m = UndoGraceMachine()
        let first = deletion("已删除分镜 #3")
        _ = m.arm(first)
        let second = deletion("已删除分镜 #7")
        _ = m.arm(second)

        #expect(m.expire(id: first.id, now: t0.addingTimeInterval(9999)) == nil)
        #expect(m.flush(id: first.id) == nil)
        #expect(m.phase == .armed)                 // 当前事务毫发无损
        #expect(m.isStripVisible)
        #expect(m.requestUndo(id: first.id, now: t0.addingTimeInterval(1)) == .stale)
        // 但新事务照常可撤销
        #expect(m.requestUndo(id: second.id, now: t0.addingTimeInterval(1)) == .performUndo(second))
    }

    @Test("UG-11 了结后的事务再 arm 新事务：不产生「上一条」交代（它不是被顶掉的）")
    func settleThenArmHasNoDisplaced() {
        var m = UndoGraceMachine()
        let first = deletion("已删除分镜 #3")
        _ = m.arm(first)
        _ = m.flush()                              // 已了结
        let lost = m.arm(deletion("已删除分镜 #7"))
        #expect(lost == nil)                       // 了结过的事务不该再被算成"被顶掉"
    }

    // MARK: 剩余秒数

    @Test("UG-12 剩余秒数随时间单调递减，且下限为 0（倒计时不许显示负数）")
    func secondsLeftMonotonicAndClamped() {
        var m = UndoGraceMachine()
        let ticket = deletion()
        _ = m.arm(ticket)
        let a = m.secondsLeft(now: t0.addingTimeInterval(100))
        let b = m.secondsLeft(now: t0.addingTimeInterval(200))
        let c = m.secondsLeft(now: t0.addingTimeInterval(400))
        #expect(a == 200 && b == 100)
        #expect(a > b && b > c)
        #expect(c == 0)                            // 过期后钳在 0，不出现 -100
    }

    @Test("UG-13 浮条收回后剩余秒数一律 0（不许留残影读数）")
    func secondsLeftZeroOnceNotArmed() {
        for settle in ["undo", "expire", "flush"] {
            var m = UndoGraceMachine()
            let ticket = deletion()
            _ = m.arm(ticket)
            switch settle {
            case "undo": _ = m.requestUndo(id: ticket.id, now: t0)
            case "expire": _ = m.expire(id: ticket.id, now: t0.addingTimeInterval(300))
            default: _ = m.flush()
            }
            #expect(!m.isStripVisible, "\(settle) 之后浮条必须收回")
            #expect(m.secondsLeft(now: t0.addingTimeInterval(1)) == 0, "\(settle) 之后不许有剩余秒数")
        }
    }

    @Test("UG-14 ticket 的 deadline 与 needsCommitOnSettle 按 kind 分档")
    func ticketDerivedProperties() {
        let d = deletion(seconds: 300)
        #expect(d.deadline == t0.addingTimeInterval(300))
        #expect(d.needsCommitOnSettle)
        let b = batch(seconds: 5)
        #expect(b.deadline == t0.addingTimeInterval(5))
        #expect(!b.needsCommitOnSettle)
    }
}
