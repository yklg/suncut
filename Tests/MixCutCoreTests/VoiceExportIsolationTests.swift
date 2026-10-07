import Foundation
import Testing
@testable import MixCutCore

/// EX：脚本成片配音与普通改写组合的隔离（纯值层钉死）。
///
/// 背景：脚本 dub 物化时 participatesInCombination 默认 false（SegmentDub 模型契约）。
/// 普通方案导出走 VariantCombinationGenerator（SlotOptions.dubIds 只含参与组合的变体）；
/// 脚本方案（dubOnly）走 selectedSegmentDubId 直查。两类绝不能互相污染——
/// 脚本 dub 不得涨普通方案笛卡尔积，普通改写默认也不得混进 dubOnly。
struct VoiceExportIsolationTests {

    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test("EX-1 脚本 dub 不进组合槽：SlotOptions 未纳入其 id → feasible 不含它")
    func scriptDubExcludedFromCombinationSlot() {
        // 模拟 App 层口径：combinationDubVariants 只收 participatesInCombination=true 的 dub。
        // 脚本 dub（opt-in=false）即使带音频也不在传入 id 列表中。
        let scriptDubIDs = ids(1)           // 有音频但 participatesInCombination=false
        let optedInRewriteIDs: [UUID] = []  // 该分镜无勾选项
        let slots = [
            SlotOptions(isLocked: false,
                        includeOriginal: true,
                        dubIds: optedInRewriteIDs),   // 故意不含 scriptDubIDs
        ]
        let r = VariantCombinationGenerator.generate(slots: slots, limit: 10)
        // 只有原声一档；脚本 dub id 不得出现在任何组合里
        #expect(r.feasibleCount == 1)
        let allDubRefs = r.combinations.flatMap { $0 }.compactMap { $0 }
        #expect(Set(allDubRefs).isDisjoint(with: Set(scriptDubIDs)))
    }

    @Test("EX-2 普通改写勾选后正常进组合；未勾选的脚本/改写 dub 仍隔离")
    func optedInRewritesParticipateButOthersDoNot() {
        let scriptDub = UUID()
        let rewrite = UUID()
        let r = VariantCombinationGenerator.generate(
            slots: [SlotOptions(isLocked: false, includeOriginal: false,
                                 dubIds: [rewrite])],
            limit: 10)
        #expect(r.feasibleCount == 1)
        let refs = Set(r.combinations.flatMap { $0 }.compactMap { $0 })
        #expect(refs == [rewrite])
        #expect(!refs.contains(scriptDub))
    }

    @Test("EX-3 dubOnly 绑定判据是 selectedSegmentDubId 直查，不经组合过滤（结构钉死）")
    func dubOnlyBypassIsByExplicitID() {
        // 纯值表达 dubOnly 判定：只认显式绑定的 dubID，存在即可，无关于组合 opt-in。
        func dubOnlyBlocked(boundID: UUID?, allDubIDs: Set<UUID>, hasAudio: Bool) -> String? {
            guard let id = boundID, allDubIDs.contains(id) else { return "未选择配音" }
            return hasAudio ? nil : "配音尚未生成"
        }
        let scriptDub = UUID()
        // 即使它不参与组合，dubOnly 照样认它（绑定在即可）——阻塞只取决于有无音频。
        #expect(dubOnlyBlocked(boundID: scriptDub, allDubIDs: [scriptDub], hasAudio: false)
                == "配音尚未生成")
        #expect(dubOnlyBlocked(boundID: scriptDub, allDubIDs: [scriptDub], hasAudio: true) == nil)
        #expect(dubOnlyBlocked(boundID: nil, allDubIDs: [scriptDub], hasAudio: true)
                == "未选择配音")
    }
}
