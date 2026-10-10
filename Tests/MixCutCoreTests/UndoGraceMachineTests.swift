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
private let grace: Double = 300                               // 本文件自造的夹具值，与 App 的 `graceSeconds`（产品档位）无关：Tests 不 import MixCut，状态机的算术也不该跟着档位漂

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

    // MARK: TC-UG-16 / 17 三态交错与「义务只交一次」的其余形状
    // UG-05 只测了同一枚 ticket 上重复 expire；这两条补的是**了结之后再登记新的一枚**时
    // 旧那枚的迟到事件（真机形态：宽限期到点与用户连点/切项目挤在一起）。

    @Test("TC-UG-16 arm→expire→arm 交错：旧事务的迟到 expire/flush 既不动当前事务，也不再交一次义务")
    func expireThenRearmKeepsObligationSingle() {
        var m = UndoGraceMachine()
        let first = deletion("已删除视频 #1")
        _ = m.arm(first)
        #expect(m.expire(id: first.id, now: t0.addingTimeInterval(300)) == first, "第一次到点交出义务")
        #expect(m.phase == .expired)

        let second = deletion("已删除视频 #2", at: t0.addingTimeInterval(301))
        #expect(m.arm(second) == nil,
                "已了结的第一枚不该被算成「被顶掉」—— 否则它被真删两次，第二次的 commit 是空转")
        #expect(m.phase == .armed && m.isStripVisible)

        // 旧 ticket 的定时器此刻才跑到（主线程忙、或 App 侧那条 Task 还挂着）
        #expect(m.expire(id: first.id, now: t0.addingTimeInterval(9_999)) == nil)
        #expect(m.flush(id: first.id) == nil)
        #expect(m.phase == .armed, "当前事务必须毫发无损")
        #expect(m.ticket == second)
        // 新的一枚照常可撤销
        #expect(m.requestUndo(id: second.id, now: t0.addingTimeInterval(301)) == .performUndo(second))
    }

    @Test("TC-UG-17 undo 迟到（tooLate）之后再 flush / expire：真删义务不二次交出（幂等）")
    func flushAfterTooLateDoesNotCommitTwice() {
        var m = UndoGraceMachine()
        let ticket = deletion()
        _ = m.arm(ticket)
        // 点的时候已过 deadline：不撤销，但把义务补交出去（UG-06 那一档）
        #expect(m.requestUndo(id: ticket.id, now: t0.addingTimeInterval(301)) == .tooLate(commit: ticket))
        #expect(m.phase == .expired)
        // 补交之后，任何一条收口路径都不该再交出第二次真删义务
        #expect(m.flush(id: ticket.id) == nil)
        #expect(m.flush() == nil, "带 nil id 的「了结当前那枚」同样不许重交")
        #expect(m.expire(id: ticket.id, now: t0.addingTimeInterval(400)) == nil)
        #expect(!m.isStripVisible)
        #expect(m.secondsLeft(now: t0.addingTimeInterval(400)) == 0)
        // 了结过的事务再 arm 新的一枚：不产生「上一条已确认删除」的交代（它不是被顶掉的）
        #expect(m.arm(deletion("已删除视频 #2", at: t0.addingTimeInterval(401))) == nil)
    }
}

// ============================================================================
// 批 1 · 刀 2 变更台账（GraphEntity / GraphChange）判据用例（GC-01~06）
//
// 锁定的接口：
//   enum GraphEntity : 10 类实体 + static let prunable: Set<GraphEntity>
//   struct GraphChange { noteDeleted(_:of:), idsDeleted(of:), isEmpty, isPrunable }
//
// 规则（每条都对应发布口 `GraphBroadcast.post` 里的一行判据）：
//   C1 noteDeleted 是**并集**，不是追加事件 ⇒ 同一实体被分几笔记下，观察者看到的仍是同一份。
//   C2 空集不落键 ⇒ 没删任何东西的变更必须 isEmpty==true，且不可剪枝（回落全量重载）。
//   C3 只要变更里混进一类 UI 不认得的实体，**整个变更**都不可剪枝 —— 而不是「剪能剪的那部分」。
//      这条是降级规则的全部意义：半剪半不剪会留下没人认领的投影。
//   C5 「能不能剪」看的是**有没有人接得住**，不是 id 好不好拿：`.video` 虽是三类之一，
//      它的投影却只随所属项目一起被摘 ⇒ 带 video 却不带 project 的变更一律降级（GC-07）。
//   C4 prunable 名册改动必须经过 review（少一类=少剪一处投影；多一类=多一处没人重算的边）。
//   注意：App 层的重入闸与「saveFailed 时丢弃 change」在 MixCut target 里，swift test 看不见，
//   由 G19（源码扫描：发布口唯一 + 三条承重写法逐字钉住）与真机 T-0 兜。
// ============================================================================

@Suite("GraphChange · 变更台账与剪枝判据")
struct GraphChangeTests {

    private func uuid(_ seed: Int) -> UUID {
        // 12 位末组是 UUID 的硬格式，多一位少一位都会让 uuidString 返回 nil
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", seed))")!
    }

    @Test("GC-01 noteDeleted 是并集语义：同实体分两笔记，读数仍是合起来的 1 组")
    func noteDeletedUnions() {
        var c = GraphChange()
        c.noteDeleted([uuid(1), uuid(2)], of: .segment)
        c.noteDeleted([uuid(2), uuid(3)], of: .segment)
        #expect(c.idsDeleted(of: .segment) == [uuid(1), uuid(2), uuid(3)])
        #expect(c.deleted.count == 1, "同一实体不该占两个键")
        c.noteDeleted([uuid(4)], of: .video)
        #expect(c.deleted.count == 2)
        #expect(c.idsDeleted(of: .video) == [uuid(4)])
    }

    @Test("GC-02 空集不落键：空删除必须 isEmpty 且不可剪枝（回落全量重载）")
    func emptyDeletesDoNotCreateKeys() {
        var c = GraphChange()
        c.noteDeleted([], of: .project)
        #expect(c.deleted.isEmpty, "空集不该造出一个值为 [] 的键")
        #expect(c.isEmpty)
        #expect(!c.isPrunable, "空变更不可剪枝 ⇒ 发布口会按无载荷发，走旧的全量重载")
        var mixed = GraphChange()
        mixed.noteDeleted([uuid(9)], of: .segment)
        mixed.noteDeleted([], of: .video)
        #expect(!mixed.isEmpty)
        #expect(mixed.idsDeleted(of: .video).isEmpty)
    }

    @Test("GC-03 未登记的实体读数为空集而不是崩（观察者按 id 剪枝前先问有没有）")
    func unrecordedEntityReadsEmpty() {
        var c = GraphChange()
        c.noteDeleted([uuid(1)], of: .project)
        #expect(c.idsDeleted(of: .scheme).isEmpty)
        #expect(c.idsDeleted(of: .strategy).isEmpty)
    }

    @Test("GC-04 有直接消费者的实体单独成变更即可剪枝")
    func prunableRosterAllCount() {
        // `.video` 不在这一档：它没有直接消费者，判据见 GC-07
        for entity: GraphEntity in [.project, .segment] {
            var c = GraphChange()
            c.noteDeleted([uuid(7)], of: entity)
            #expect(c.isPrunable, "\(entity) 有 VM 侧剪枝入口，单独出现就该能剪")
        }
    }

    @Test("GC-07 视频是「条件可剪」：跟着项目走才有人接得住，单独出现必须整条降级")
    func videoIsConditionallyPrunable() {
        var solo = GraphChange()
        solo.noteDeleted([uuid(1)], of: .video)
        #expect(GraphEntity.prunable.contains(.video))
        #expect(!solo.isPrunable, "只删视频没有剪枝入口 ⇒ 必须降级为全量重载，不许半剪")

        var withProject = GraphChange()
        withProject.noteDeleted([uuid(2)], of: .project)
        withProject.noteDeleted([uuid(3), uuid(4)], of: .video)
        #expect(withProject.isPrunable, "视频投影随所属项目一起摘 ⇒ 这一档可以剪")

        var withSegmentOnly = GraphChange()
        withSegmentOnly.noteDeleted([uuid(5)], of: .segment)
        withSegmentOnly.noteDeleted([uuid(6)], of: .video)
        #expect(!withSegmentOnly.isPrunable, "有 segment 消费者不代表接得住 video")

        var throatShape = GraphChange()
        throatShape.noteDeleted([uuid(7)], of: .project)
        throatShape.noteDeleted([uuid(8)], of: .video)
        throatShape.noteDeleted([uuid(9), uuid(10)], of: .segment)
        #expect(throatShape.isPrunable, "咽喉现在的真实形状必须能剪")
    }

    @Test("GC-05 混入一类不可剪枝 ⇒ 整个变更降级（不许半剪半不剪）")
    func mixedChangeDowngradesWholesale() {
        var c = GraphChange()
        c.noteDeleted([uuid(1), uuid(2)], of: .project)   // 会剪
        c.noteDeleted([uuid(3)], of: .scheme)             // UI 不认得
        #expect(!c.isPrunable)
        #expect(c.idsDeleted(of: .project) == [uuid(1), uuid(2)],
                "降级只该关掉剪枝资格，台账本身不能丢内容")
        var schemeOnly = GraphChange()
        schemeOnly.noteDeleted([uuid(4)], of: .schemeSegment)
        #expect(!schemeOnly.isPrunable)
    }

    @Test("GC-06 prunable 名册逐字对账：改动必须过一次 review")
    func prunableRosterIsExact() {
        #expect(GraphEntity.prunable == [.project, .video, .segment],
                "prunable 名册变了：实得 \(GraphEntity.prunable.map(\.rawValue).sorted())")
        // 全表 10 类，且与 prunable 无重名漂移（新增实体时两处要一起想清楚）
        #expect(GraphEntity.allCases.count == 10)
        #expect(Set(GraphEntity.allCases).isSuperset(of: GraphEntity.prunable))
        let notPrunable = Set(GraphEntity.allCases).subtracting(GraphEntity.prunable)
        #expect(notPrunable == [.projectVideo, .scheme, .strategy, .schemeSegment,
                                .segmentDub, .physicalShot, .shotVariant])
    }

    @Test("TC-UG-15 连 arm N 枚删除类 ⇒ 前 N−1 枚都被交出且都欠即刻真删（「循环单删」的机械证明）")
    func consecutiveArmsDisplaceEveryPredecessor() {
        // 素材导入要做批量删除时，最省事的写法是「循环调单条删除」。这条用例就是它的化验单：
        // 状态机同一时刻只挂一枚 ticket，后一枚登记时前一枚**当场**被交出 ⇒ 前 N−1 条根本没有宽限期。
        var m = UndoGraceMachine()
        var displaced: [UndoTicket] = []
        for i in 1...5 {
            let t = deletion("已删除视频 #\(i)", at: t0.addingTimeInterval(Double(i)))
            if let lost = m.arm(t) { displaced.append(lost) }
        }
        #expect(displaced.count == 4,
                "5 枚依次登记，只有最后那枚保得住宽限期；实际交出 \(displaced.count) 枚")
        #expect(displaced.allSatisfy { $0.needsCommitOnSettle },
                "被顶掉的每一枚都必须立刻真删 ⇒ 批量删除必须一次登记一枚 ticket，绝不允许循环单删")
        #expect(displaced.map(\.message) == ["已删除视频 #1", "已删除视频 #2",
                                             "已删除视频 #3", "已删除视频 #4"])
    }
}
