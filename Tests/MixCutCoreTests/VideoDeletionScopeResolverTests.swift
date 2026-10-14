import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 批 3 · VideoDeletionScopeResolver / VideoDeletionTotals 判据（VS-01…08）
//
// 规则：
//   R1 越界 ⇒ **整条拒绝**（`isRejected`），越界 id 一律不进 units —— 不做"删我能删的那半"，
//      否则「已删除 30 个视频」这句 Toast 就是说谎（用户勾 30、实删 22、剩 8 个无声消失）。
//   R2 每个被勾选的 id 恰好落进 units / foreign / unresolvable 之一（计数诚实，从
//      `SegmentBatchPolicy.tally` 那颗既有真源搬来的同一条纪律）。
//   R3 同项目同视频两条关联（历史脏形状）⇒ **一个** unit，但两条 pv 都收 —— 少摘一条就删不掉。
//   R4 空勾选 ⇒ 空且**不是**错误。
//   R5 顺序确定：乱序输入 ⇒ 同一份 units 顺序（按 videoID.uuidString），文案与编号才不抖。
//   R6 定义域是"当前可见集合"：不在可见集合里的一律算越界，哪怕它确实在项目里
//      （隐藏项被删 = 用户看不见却少了一条素材，是最坏的分叉）。
//   R7 分档取自删除**之前**的引用数快照：`referenceCountBefore == 本项目关联数` 才算"只被本项目用"。
//   R8 只有 localOnly 那些的分镜计入 `segmentsDeleted`（别的项目的分镜一条都不动）。
// ============================================================================

private func vid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
}

@Suite("VideoDeletionScopeResolver · 批量删除的作用域与实数")
struct VideoDeletionScopeResolverTests {

    // MARK: R1 越界拒绝

    @Test("VS-01 勾选里混进不属于本项目可见集合的 id ⇒ 整条拒绝，且越界那条绝不进 units")
    func foreignSelectionRejectsTheWholeBatch() {
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: [vid(1), vid(2), vid(99)],
            visibleVideoIDs: [vid(1), vid(2)],
            associationsByVideo: [vid(1): [vid(11)], vid(2): [vid(12)]])
        #expect(scope.isRejected, "越界却没拒绝 ⇒ 会只删能删的那半，Toast 上的数字就开始说谎")
        #expect(scope.foreignIDs == [vid(99)])
        // 咽喉唯一准读的是 deletableUnits：拒绝态下它必须恒空 ⇒「忘了判 isRejected 就只删那半」写不出来
        #expect(scope.deletableUnits.isEmpty, "拒绝态下还交出可执行单元 ⇒ 会静默只删能删的那半")
        // 诊断字段仍留全（写文案/报错要点名越界的是哪几个），这不是矛盾，是两个用途
        #expect(scope.units.map(\.videoID) == [vid(1), vid(2)])
        // 空操作的另一半保证：拒绝态下调用方只要不再往下走，就不会有任何删除发生
        #expect(!scope.isEmpty, "有越界成员时不许被当成「什么都没勾」")
    }

    @Test("VS-01b 正向对照：一个越界都没有时 deletableUnits 必须等于 units（不许两者恒空成假闸门）")
    func gateOpensWhenNothingIsForeign() {
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: [vid(1), vid(2)],
            visibleVideoIDs: [vid(1), vid(2), vid(3)],
            associationsByVideo: [vid(1): [vid(11)], vid(2): [vid(12)]])
        #expect(!scope.isRejected)
        #expect(scope.deletableUnits == scope.units && scope.units.count == 2,
                "无越界时闸门却不放行 ⇒ 上一批用例的「恒空」其实是恒假，这条判据就白立了")
    }

    @Test("VS-02 全部越界与部分越界同一条判据：foreign 集合就是被拒的理由清单")
    func allForeignIsStillRejected() {
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: [vid(7), vid(8)],
            visibleVideoIDs: [],
            associationsByVideo: [:])
        #expect(scope.isRejected)
        #expect(scope.foreignIDs == [vid(7), vid(8)])
        #expect(scope.units.isEmpty)
    }

    // MARK: R3 脏形状：同项目同视频两条关联

    @Test("VS-03 同项目同视频两条关联：两条 pv 都收，但只出一个 unit（一个视频被删两次是不可逆的）")
    func duplicateAssociationsMergeIntoOneUnit() {
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: [vid(1)],
            visibleVideoIDs: [vid(1)],
            associationsByVideo: [vid(1): [vid(11), vid(12)]])
        #expect(scope.units.count == 1)
        #expect(scope.units.first?.projectVideoIDs == [vid(11), vid(12)],
                "少摘一条关联 ⇒ 那个视频的 pv 还挂在库里，表现为「删了还在」")
        #expect(!scope.isRejected && !scope.isEmpty)
    }

    // MARK: R4 空勾选

    @Test("VS-04 空勾选：空、且不是错误（没有「什么都没勾」被报成越界的道理）")
    func emptySelectionIsNotAnError() {
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: [], visibleVideoIDs: [vid(1)],
            associationsByVideo: [vid(1): [vid(11)]])
        #expect(scope.isEmpty)
        #expect(!scope.isRejected)
        #expect(scope.units.isEmpty && scope.foreignIDs.isEmpty && scope.unresolvableIDs.isEmpty)
    }

    // MARK: R2 分桶守恒

    @Test("VS-05 计数诚实：三桶互斥且求和等于勾选数，一条不许进两个桶、也不许被静默丢")
    func bucketsPartitionTheSelection() {
        // 混合形状：4 个可见有 pv、3 个越界、2 个可见但关联取不到（悬挂那一族）
        let visibleWithPV = (1...4).map { vid($0) }
        let visibleDangling = (5...6).map { vid($0) }
        let foreign = (7...9).map { vid($0) }
        var associations: [UUID: Set<UUID>] = [:]
        for id in visibleWithPV { associations[id] = [UUID()] }
        associations[visibleDangling[0]] = []        // 空关联
        // visibleDangling[1] 干脆缺键 —— 两种"取不到"的形态都要落进同一个桶
        let selected = Set(visibleWithPV + visibleDangling + foreign)
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: selected,
            visibleVideoIDs: Set(visibleWithPV + visibleDangling),
            associationsByVideo: associations)

        #expect(scope.units.count == 4)
        #expect(scope.foreignIDs.count == 3)
        #expect(scope.unresolvableIDs == Set(visibleDangling), "空关联与缺键都算取不到，不许一有一无")
        #expect(scope.units.count + scope.foreignIDs.count + scope.unresolvableIDs.count == selected.count,
                "有 id 被漏计 = 「已删除 N 个视频」里的 N 与实际条数分家")
        // 互斥：同一 id 既进 units 又进别的桶 ⇒ 会被做两遍
        let unitIDs = Set(scope.units.map(\.videoID))
        #expect(unitIDs.isDisjoint(with: scope.foreignIDs))
        #expect(unitIDs.isDisjoint(with: scope.unresolvableIDs))
        #expect(scope.foreignIDs.isDisjoint(with: scope.unresolvableIDs))
        #expect(scope.isRejected)
    }

    // MARK: R5 确定性

    @Test("VS-05b 乱序勾选 ⇒ units 顺序恒同（按 videoID.uuidString 升序），文案与编号才不抖")
    func orderingIsDeterministic() {
        let associations: [UUID: Set<UUID>] = [vid(1): [vid(11)], vid(2): [vid(12)], vid(3): [vid(13)]]
        let visible = Set([vid(1), vid(2), vid(3)])
        let a = VideoDeletionScopeResolver.resolve(selectedVideoIDs: [vid(3), vid(1), vid(2)],
                                                  visibleVideoIDs: visible, associationsByVideo: associations)
        let b = VideoDeletionScopeResolver.resolve(selectedVideoIDs: [vid(2), vid(3), vid(1)],
                                                   visibleVideoIDs: visible, associationsByVideo: associations)
        #expect(a.units == b.units)
        #expect(a.units.map(\.videoID) == [vid(1), vid(2), vid(3)],
                "夹具的 vid() 是定宽十六进制 ⇒ uuidString 序即数值序，期望可手算")
    }

    // MARK: R6 定义域只认"可见"

    @Test("VS-06 定义域是当前可见集合：在项目里但**当前不可见**的 id 也算越界")
    func domainIsTheVisibleSetNotTheProject() {
        let hidden = vid(50)
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: [hidden],
            visibleVideoIDs: [vid(1)],                       // hidden 在库里但被过滤掉了
            associationsByVideo: [hidden: [vid(51)]])
        #expect(scope.isRejected,
                "拿项目全集当定义域会删掉用户看不见的卡 —— 批 4 的「丢失隐藏」与筛选态都会撞上")
        #expect(scope.units.isEmpty)
    }

    // MARK: R7 / R8 分档与分镜实数

    @Test("VS-07 二次确认的实数：只被本项目用的连记录删、还被别的项目用的只解关联，两档互斥")
    func totalsSplitByReferenceSnapshot() {
        // 两条 localOnly（各自所有关联都在本项目）、一条被两个项目共用
        let entries = [
            VideoDeletionTotals.Entry(referenceCountBefore: 1, associationCountInProject: 1, segmentCount: 4),
            VideoDeletionTotals.Entry(referenceCountBefore: 2, associationCountInProject: 2, segmentCount: 3),
            VideoDeletionTotals.Entry(referenceCountBefore: 3, associationCountInProject: 1, segmentCount: 9),
        ]
        let t = VideoDeletionTotals.tally(entries)
        #expect(t.localOnlyCount == 2 && t.stillReferencedCount == 1)
        #expect(t.localOnlyCount + t.stillReferencedCount == entries.count, "两档并起来必须是全部勾选")
        // R8：被共用那条的 9 个分镜一条都不许算进来 —— 别的项目的分镜不会被这次删除碰到
        #expect(t.segmentsDeleted == 7, "分镜数只能来自 localOnly 那两档，实得 \(t.segmentsDeleted)")
    }

    @Test("VS-08 边界：空批次与「全部被共用」两档都不许崩，也不许报出凭空多出的数字")
    func totalsEdgeCases() {
        let empty = VideoDeletionTotals.tally([])
        #expect(empty.localOnlyCount == 0 && empty.stillReferencedCount == 0 && empty.segmentsDeleted == 0)
        let allShared = VideoDeletionTotals.tally([
            VideoDeletionTotals.Entry(referenceCountBefore: 2, associationCountInProject: 1, segmentCount: 5),
        ])
        #expect(allShared.localOnlyCount == 0 && allShared.segmentsDeleted == 0,
                "没有一条会被真删记录时，文案里的「连 B 个分镜一起删」必须是 0，不能拿 5 去吓人")
        #expect(allShared.stillReferencedCount == 1)
    }
}
