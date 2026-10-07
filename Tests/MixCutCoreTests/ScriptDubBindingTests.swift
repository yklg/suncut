import Foundation
import Testing
@testable import MixCutCore

/// IA：ScriptDubIndexAllocator；SB：ScriptDubBinding 四分支；RP：ScriptDubReap 归属。
struct ScriptDubBindingTests {

    private func dub(_ id: UUID = UUID(), index: Int, voice: String = "vc",
                     text: String = "文案", audio: Bool = false) -> ExistingDub {
        ExistingDub(dubID: id, variantIndex: index, voiceID: voice, text: text, hasAudio: audio)
    }

    // MARK: IA

    @Test("IA-1 空分镜 → 新 index 0")
    func allocatorEmpty() {
        #expect(ScriptDubIndexAllocator.nextIndex(occupied: []) == 0)
    }

    @Test("IA-2 现存 [0,2] → 3")
    func allocatorGapsTakeMaxPlusOne() {
        #expect(ScriptDubIndexAllocator.nextIndex(occupied: [0, 2]) == 3)
    }

    @Test("IA-3 仅克隆 index0 → 新壳 index1（不撞号）")
    func allocatorAfterCloneZero() {
        #expect(ScriptDubIndexAllocator.nextIndex(occupied: [0]) == 1)
    }

    @Test("IA-4 重复调用确定性（纯函数无副作用）")
    func allocatorDeterministic() {
        let occupied = [0, 1]
        #expect(ScriptDubIndexAllocator.nextIndex(occupied: occupied) == 2)
        #expect(ScriptDubIndexAllocator.nextIndex(occupied: occupied) == 2)
    }

    // MARK: SB

    @Test("SB-1 同音色同文案现存 dub（有音频）→ 复用并删壳，零合成")
    func bindReusesSameTextDubWithAudio() {
        let shell = UUID(); let reusable = UUID()
        let existing = [
            dub(shell, index: 0, voice: "", text: "脚本台词", audio: false),
            dub(reusable, index: 0, voice: "longyingxiao", text: "脚本台词", audio: true),
        ]
        let r = ScriptDubBinding.resolve(shellDubID: shell, shellIndex: 0,
                                         shellText: "脚本台词", existing: existing,
                                         voiceID: "longyingxiao")
        #expect(r == .reuseExisting(reusableDubID: reusable, shellDubID: shell,
                                    reusableVoiceID: "longyingxiao", reusableHasAudio: true))
    }

    @Test("SB-2 撞号但文案不同 → 壳迁到空闲 index，既有 dub 不动")
    func bindRelocatesOnCollisionDifferentText() {
        let shell = UUID(); let other = UUID()
        let existing = [
            dub(other, index: 0, voice: "vc1", text: "改写文案A", audio: true),
            dub(shell, index: 0, voice: "", text: "脚本台词", audio: false),
        ]
        let r = ScriptDubBinding.resolve(shellDubID: shell, shellIndex: 0,
                                         shellText: "脚本台词", existing: existing,
                                         voiceID: "longyingxiao")
        #expect(r == .relocate(shellDubID: shell, newIndex: 1, voiceID: "longyingxiao"))
    }

    @Test("SB-3 无冲突 → 原地绑定")
    func bindInPlaceWhenIndexFree() {
        let shell = UUID()
        let existing = [
            dub(UUID(), index: 0, voice: "vc1", text: "改写A", audio: true),
            dub(shell, index: 1, voice: "", text: "脚本台词", audio: false),
        ]
        let r = ScriptDubBinding.resolve(shellDubID: shell, shellIndex: 1,
                                         shellText: "脚本台词", existing: existing,
                                         voiceID: "longyingxiao")
        #expect(r == .bindInPlace(shellDubID: shell, voiceID: "longyingxiao"))
    }

    @Test("SB-4 载体缺失（壳 id 不存在于现存）→ 新建并返回新 index")
    func bindCreatesNewWhenShellMissing() {
        let goneShell = UUID()
        let existing = [dub(UUID(), index: 0, voice: "vc1", text: "改写A", audio: true)]
        let r = ScriptDubBinding.resolve(shellDubID: goneShell, shellIndex: 0,
                                         shellText: "脚本台词", existing: existing,
                                         voiceID: "longyingxiao")
        #expect(r == .createNew(dubIndex: 1, voiceID: "longyingxiao"))
    }

    @Test("SB-4b 载体缺失且槽位无绑定 id → 从现存最大 index 继续")
    func bindCreatesNewWhenNoShellAtAll() {
        let existing = [dub(UUID(), index: 0), dub(UUID(), index: 2)]
        let r = ScriptDubBinding.resolve(shellDubID: nil, shellIndex: nil,
                                         shellText: "脚本台词", existing: existing,
                                         voiceID: "longyingxiao")
        #expect(r == .createNew(dubIndex: 3, voiceID: "longyingxiao"))
    }

    @Test("SB-5 同文案但音色不同 → 不复用（A 音色成果不能冒充 B 音色）")
    func bindDoesNotReuseDifferentVoice() {
        let shell = UUID(); let other = UUID()
        let existing = [
            dub(other, index: 0, voice: "voiceA", text: "脚本台词", audio: true),
            dub(shell, index: 0, voice: "", text: "脚本台词", audio: false),
        ]
        let r = ScriptDubBinding.resolve(shellDubID: shell, shellIndex: 0,
                                         shellText: "脚本台词", existing: existing,
                                         voiceID: "voiceB")
        // 撞号 → 迁移，而不是复用
        #expect(r == .relocate(shellDubID: shell, newIndex: 1, voiceID: "voiceB"))
    }

    @Test("SB-6 多方案引用同一现存 dub 是 Reap 的事，绑定层仍可复用该 dub（不删除共享者）")
    func bindReuseDoesNotImplyDeletionOfShared() {
        // 仅钉复用判定本身不受其他因素影响；共享保护在 RP 系列验证。
        let reusable = UUID()
        let existing = [dub(reusable, index: 0, voice: "v", text: "t", audio: true)]
        let r = ScriptDubBinding.resolve(shellDubID: nil, shellIndex: nil,
                                         shellText: "t", existing: existing, voiceID: "v")
        #expect(r == .reuseExisting(reusableDubID: reusable, shellDubID: nil,
                                    reusableVoiceID: "v", reusableHasAudio: true))
    }

    // MARK: RP

    @Test("RP-1 本方案独占脚本 dub → 可删")
    func reapOwnedOnly() {
        let d = UUID()
        #expect(ScriptDubReap.reapable(provenanceIsScript: true, dubID: d,
                                       boundByDeletingSchemeIDs: [d],
                                       referencedBySurvivingSchemeIDs: []) == true)
    }

    @Test("RP-2 被另一存活方案引用 → 保留")
    func reapKeepsSharedBySurvivor() {
        let d = UUID()
        #expect(ScriptDubReap.reapable(provenanceIsScript: true, dubID: d,
                                       boundByDeletingSchemeIDs: [d],
                                       referencedBySurvivingSchemeIDs: [d]) == false)
    }

    @Test("RP-3 非脚本族（普通改写资产）→ 永不判可删")
    func reapNeverTouchesNonScriptDubs() {
        let d = UUID()
        #expect(ScriptDubReap.reapable(provenanceIsScript: false, dubID: d,
                                       boundByDeletingSchemeIDs: [d],
                                       referencedBySurvivingSchemeIDs: []) == false)
    }

    @Test("RP-4 脚本 dub 但未绑定待删方案 → 保留")
    func reapKeepsUnboundScriptDub() {
        let d = UUID(); let other = UUID()
        #expect(ScriptDubReap.reapable(provenanceIsScript: true, dubID: d,
                                       boundByDeletingSchemeIDs: [other],
                                       referencedBySurvivingSchemeIDs: []) == false)
    }

    @Test("RP-5 批量：两条独占删、一条共享留，顺序保持")
    func reapCandidatesFiltersAndKeepsOrder() {
        let a = UUID(); let b = UUID(); let shared = UUID()
        let result = ScriptDubReap.reapableCandidates(
            provenanceScriptDubIDs: [a, shared, b],
            boundByDeletingSchemeIDs: [a, shared, b],
            referencedBySurvivingSchemeIDs: [shared])
        #expect(result == [a, b])
    }
}
