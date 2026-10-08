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
// ⇒ 正确形态是**两个条件缺一不可**，且必须抽成可单测的纯函数，
// 否则它会散落在多个调用点、各自漂移（这正是本缺陷的成因）。
// ============================================================================

public enum CloneBranchDecider {

    /// 本次改写是否走「逐分镜克隆 → 合成」链路。
    ///
    /// - Parameters:
    ///   - suppressVideoClone: 用户是否显式选择「跟随全局/项目音色」。
    ///     **true 时一律不克隆**——即使有克隆字段（尊重用户选择 = 不花钱）。
    ///   - hasAnySegmentClone: 本作用域内**是否有任一分镜**已按段级克隆。
    ///     注意是「本作用域」而非「本视频」：段级化必然产生混合状态。
    ///   - hasLegacyVideoClone: 存量视频级克隆声是否存在（M2 前的库兼容）。
    ///     新库恒为 false；但存量库必须仍能走克隆，否则用户要重新付费克隆。
    /// - Returns: true = 走克隆分支。
    public static func shouldClone(suppressVideoClone: Bool,
                                   hasAnySegmentClone: Bool,
                                   hasLegacyVideoClone: Bool = false) -> Bool {
        // 条件一：用户没显式压制（尊重显式选择——它优先于任何"已有克隆"的事实）
        guard !suppressVideoClone else { return false }
        // 条件二：确实有可用的克隆声（段级或存量视频级）
        return hasAnySegmentClone || hasLegacyVideoClone
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