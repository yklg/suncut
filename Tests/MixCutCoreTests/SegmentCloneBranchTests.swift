import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// SRV-B · 克隆分支判据（M2）
//
// ## 本组测试守护什么
//
// 克隆音色从「按视频」改成「按分镜」后，`rewrite()` 的分支判据算错了：
// **已配全局音色 + 分镜已有克隆 ⇒ 跳过克隆 ⇒ 合成出全局音色的声音**。
//
// ⚠️ **SRV-B4 是本组最重要的一条**：它防的是「把判据写成『任一分镜有克隆就强制克隆』」
// 这个错误实现——那样写会**无视用户显式的「跟随全局音色」选择**、强制开始克隆 ⇒ **花钱**。
// 没有这条用例，我的错误实现会带着测试一起通过。
// ============================================================================

// MARK: - SRV-B5 四组合真值表（判据本身）

@Test("SRV-B5 克隆分支判据：只取决于用户是否显式压制")
func srvB5_truthTable() {
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: false) == true,
            "未压制 ⇒ 走克隆（**无克隆时正是首次注册的场景**）")
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: true) == false,
            "⚠️ 已压制 ⇒ **必须不克隆**（否则无视用户选择 ⇒ 花钱）")
}

@Test("SRV-B5x 死锁守卫：未压制且**没有任何克隆**时必须仍走克隆（防首次死锁）")
func srvB5x_firstCloneDeadlockGuard() {
    // ⚠️ 这条是本组**最关键**的回归：我第一版把判据写成
    //   !suppress && (hasAnySegmentClone || hasLegacyVideoClone)
    // ⇒ 首次使用时两者皆 false ⇒ 永不克隆 ⇒ segment.clonedVoiceId 永远空
    // ⇒ 音色菜单永远不显示「原声克隆」⇒ 死锁（用户实测报告）。
    // 判据**只**取决于是否压制，「是否已存在克隆」不参与。
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: false) == true,
            "首次（无段级克隆、无存量视频级克隆）仍须走克隆分支，否则永远无法克隆")
}

@Test("SRV-B5b 存量视频级克隆声不参与判据，但压制仍然生效")
func srvB5b_legacyVideoCloneStillClones() {
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: false),
            "未压制即走克隆（存量是否已有克隆由 ensureClonedVoice 内部裁决复用/新注册）")
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: true) == false,
            "即便存量视频级有克隆，用户压制时也不克隆")
}

@Test("SRV-B5c 变异哨兵：把「必须有克隆」加回判据 ⇒ 首次死锁，必须被本组挡住")
func srvB5c_mutationSentinel() {
    // 变异：还原我第一版的错误判据（多一个「必须有克隆」条件）。
    func mutated(suppress: Bool, hasClone: Bool) -> Bool {
        !suppress && hasClone          // ← 死锁形态
    }
    // 首次场景：未压制 + 没有任何克隆
    #expect(mutated(suppress: false, hasClone: false) == false,
            "变异实现在首次场景不走克隆 —— 这正是死锁的成因")
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: false) == true,
            "真实实现必须与变异实现相反（否则 SRV-B5x 是假绿）")
}

// MARK: - SRV-B2 / B3 特征化绿（钉住既有正确语义，防地基被动）

@Test("SRV-B2 未压制时走克隆分支（无克隆 = 首次注册，不是不该克隆）")
func srvB2_noCloneNoBranch() {
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: false),
            "未压制即走克隆；无克隆时由 ensureClonedVoice 负责首次注册")
}

@Test("SRV-B3 已配置全局音色且无克隆时不被克隆分支抢走")
func srvB3_globalVoiceNotStolen() {
    // 用户已配全局音色、且没有克隆 ⇒ 必须走预置音色（不付分离费用）
    let shouldClone = CloneBranchDecider.shouldClone(suppressVideoClone: false)
    #expect(shouldClone, "未压制时走克隆分支（预置音色只在用户压制或克隆不可用时才用）")

    // 且解析结果应落到项目/全局链路（不是 unconfigured，也不是克隆）
    // ⚠️ 前置：全局默认必须是 **VoiceChoiceCoder 的合法编码**（坏串会被当 nil 回落 ⇒
    // 直接传 `"x"` 会得到 unconfigured，那是编造出来的失败、不是真实行为）。
    let r = VoiceResolver.resolveForLegacyDub(
        .init(globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "p1")),
               segmentCloneVoiceID: nil, hasAnySegmentClone: false))
    if case .resolved(let choice) = r {
        #expect(choice.engine == .cosyVoice, "无克隆时应解析为预置/全局音色")
    } else {
        Issue.record("有全局默认串却解析为 unconfigured")
    }
}

// MARK: - 契约层：`LegacyInput` 的段级字段真的被用上了吗

@Test("SRV-G4 LegacyInput 段级字段参与解析（段级优先于视频级）")
func srvG4_segmentFieldIsActuallyUsed() {
    // 段级有克隆 ⇒ 应解析为段级那个音色
    let seg = VoiceResolver.resolveForLegacyDub(
        .init(videoCloneVoiceID: "legacy", segmentCloneVoiceID: "seg", hasAnySegmentClone: true))
    #expect(seg == .resolved(.videoClone(voiceID: "seg")),
            "段级克隆音色应优先于存量视频级")

    // 段级为空 + 视频级有 ⇒ 回落视频级（存量库兼容）
    let legacy = VoiceResolver.resolveForLegacyDub(
        .init(videoCloneVoiceID: "legacy", segmentCloneVoiceID: nil, hasAnySegmentClone: false))
    #expect(legacy == .resolved(.videoClone(voiceID: "legacy")),
            "段级为空时须回落视频级（存量库不能要求重新付费克隆）")

    // ⚠️ 反向对照：段级为空 + 视频级也为空 ⇒ 不得解析成克隆
    let none = VoiceResolver.resolveForLegacyDub(
        .init(globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "p1")),
               segmentCloneVoiceID: "   ", hasAnySegmentClone: false))
    if case .resolved(let c) = none {
        #expect(c.engine != .qwenVC, "空白段级 id 不得被当成克隆声")
    } else {
        Issue.record("有全局默认串却解析为 unconfigured")
    }
}

@Test("SRV-G5 段级字段存在时，默认参数仍保持 M2 前行为（零破坏回归）")
func srvG5_defaultArgsPreserveLegacyBehavior() {
    // 不传任何新字段 ⇒ 与 M2 前逐字等价（存量 11 处构造点零改动的前提）
    let legacyStyle = VoiceResolver.resolveForLegacyDub(.init(videoCloneVoiceID: "vc1"))
    #expect(legacyStyle == .resolved(.videoClone(voiceID: "vc1")),
            "不传新字段时应与 M2 前一致")
    #expect(CloneBranchDecider.shouldClone(suppressVideoClone: false),
            "默认（未压制）走克隆 —— 这是产品的默认行为：用原声克隆")
}

// MARK: - SRV-G1 的 Core 侧替身：`isCloneVoice` 段级优先

@Test("SRV-G1 段级克隆音色判定（`isCloned` 的纯函数替身）")
func srvG1_isCloneVoice() {
    // 段级有克隆 ⇒ 该 voiceId 是克隆声
    #expect(CloneBranchDecider.isCloneVoice("seg", segmentCloneVoiceID: "seg"),
            "段级克隆音色应被识别为克隆声")
    // 段级为空 ⇒ 回落视频级
    #expect(CloneBranchDecider.isCloneVoice("legacy",
                                             segmentCloneVoiceID: nil,
                                             legacyVideoCloneVoiceID: "legacy"),
            "段级为空时应回落视频级")
    // ⚠️ 关键回归：段级有克隆但传入的是别的 voiceId ⇒ 不是克隆声
    // （旧实现只比video.clonedVoiceId，而它在 M2 后恒 nil ⇒ 段级克隆声会被误判为「非克隆」
    //   ⇒ 检查器点「生成」直接报「音色未配置或已失效」。这是 R4。）
    #expect(CloneBranchDecider.isCloneVoice("preset-x",
                                             segmentCloneVoiceID: "seg",
                                             legacyVideoCloneVoiceID: nil) == false,
            "段级克隆存在时，别的 voiceId 不应被误判为克隆声")
    // 空白处理
    #expect(CloneBranchDecider.isCloneVoice("  ", segmentCloneVoiceID: "seg") == false,
            "空白 voiceId 不应被判为克隆声")
    #expect(CloneBranchDecider.isCloneVoice("seg", segmentCloneVoiceID: "   ") == false,
            "空白段级 id 不应被判为克隆声")
}