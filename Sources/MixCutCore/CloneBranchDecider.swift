import Foundation

// ============================================================================
// 克隆分支判据（M2）
//
// ## 为什么需要这个函数（而不是在 VM 里写个if）
//
// 克隆音色从「按视频」改成「按分镜」之后，「本次改写要不要走克隆链路」这个判据
// 被算错了（实测：已配全局音色 + 分镜已有克隆 ⇒ 跳过克隆 ⇒ **合成出全局音色的声音**）。
//
// 根因是**判据被写在了错误的地方**：它原本只是 `rewrite()` 里的一行
// `if initialChoice.engine == .qwenVC`，而那行的输入来自 `resolveForLegacy`，
// 后者只拿得到**视频级**克隆 id ⇒ 分镜级克隆在判据输入里根本不存在。
//
// ⚠️ **这里有一个必须避开的陷阱**：判据写成「任一分镜有克隆 ⇒ 强制克隆」是**错的**——
// 用户显式点了「跟随全局音色」（`suppressVideoClone == true`）时，段级克隆字段**仍有值**
// （开关只影响解析、不清字段）⇒ 那样写会**无视用户的显式选择**、强制开始克隆 ⇒ **花钱**。
//
// 反过来只判 `suppressVideoClone` 也不行：那会退回 M2 前的行为（段级克隆被忽略）。
//
// ⇒ 正确形态：判据抽成可单测的纯函数，否则它会散落在多个调用点、各自漂移（本缺陷的成因）。
//
// ## ⭐ 判据只有一条：`!suppressVideoClone`（不要加第二个条件）
//
// 我（2026-10-08）第一版把判据写成两个条件「缺一不可」：
//
// ```
// !suppressVideoClone && (hasAnySegmentClone || hasLegacyVideoClone)   // ❌ 错
// ```
//
// 第二个条件造成了**首次克隆的死锁**（用户实测报告「还是选不了原声克隆」）：
//
// ```
// 想用原声克隆 → 需要 Menu 显示该选项 → 需要 hasAnyClone == true
//             → 需要先有 segment.clonedVoiceId
//             → 而克隆只在克隆分支里发生
//             → 克隆分支要求「已有克隆」⇒ false ⇒ 永不克隆 ⇒ 死锁
// ```
//
// ⚠️ **「有没有已存在的克隆」不参与判据**：
//   - 没有克隆时**正需要首次克隆** —— 克隆分支内 `ensureClonedVoice` 会自己裁决
//     （窗口可复用则复用，否则新注册）；它不存在"白跑"的问题
//   - `voiceFollowsGlobal` 默认 `false`（`Video.swift:91`）⇒ **默认行为就是用原声克隆**，
//     首次改写会克隆并计费（这与计费确认文案一致：「首次克隆含人声分离与声音注册费用」）
//
// ⇒ **若有人把第二个条件加回来，首次克隆会再次死锁。** 这条注释就是防线。
// ============================================================================

public enum CloneBranchDecider {

    /// 本次改写是否走「逐分镜克隆 → 合成」链路。
    ///
    /// - Parameter suppressVideoClone: 用户是否显式选择「跟随全局/项目音色」。
    ///   **true 时一律不克隆**——即使有克隆字段（尊重用户选择 = 不花钱）。
    /// - Returns: true = 走克隆分支（有克隆则复用，无克隆则**首次注册**）。
    ///
    /// ⚠️ **判据只有这一条**。「是否已存在克隆」**绝不参与判据**，理由见文件头
    /// 「判据只有一条」一节：把它写进来会造成首次克隆的死锁。
    public static func shouldClone(suppressVideoClone: Bool) -> Bool {
        !suppressVideoClone
    }

    /// 该分镜解析出的音色是否属于「克隆链路」（用于 `DubbingViewModel.isCloned` 的段级化）。
    ///
    /// - Parameters:
    ///   - voiceId: 待判定的音色 id。
    ///   - segmentCloneVoiceID: 该分镜自己的克隆音色（M2）。
    ///   - legacyVideoCloneVoiceID: 存量视频级克隆音色（回落）。
    /// - Returns: true = 该音色是这个分镜（或该视频）的克隆声。
    public static func isCloneVoice(_ voiceId: String,
                                    segmentCloneVoiceID: String?,
                                    legacyVideoCloneVoiceID: String? = nil) -> Bool {
        let target = voiceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        // 段级优先；段级为空（存量/未克隆）时回落视频级。
        if let seg = segmentCloneVoiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !seg.isEmpty {
            return target == seg
        }
        if let legacy = legacyVideoCloneVoiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            return target == legacy
        }
        return false
    }
}