import Foundation

// ============================================================================
// App 层全局配音音色偏好（UserDefaults 单一存取处）。
//
// 解析的纯规则在 Core VoiceResolver；本类型只负责「全局默认串从哪来」这一个环境值，
// 并把 Video/Project 模型拍平成纯值喂给 Core 判据（视图/VM 不直接拼解析入参）。
// ============================================================================

enum VoicePreferences {

    /// 全局默认音色 VoiceChoiceCoder 串的存储键。
    static let globalDefaultKey = "globalDefaultVoiceChoiceRaw_v1"

    /// 全局默认串（未配置/坏值都以 nil 表达；解码校验交给 VoiceChoiceCoder）。
    static var globalDefaultRaw: String? {
        get { UserDefaults.standard.string(forKey: globalDefaultKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: globalDefaultKey)
            } else {
                UserDefaults.standard.removeObject(forKey: globalDefaultKey)
            }
        }
    }

    /// 当前配置的全局默认音色（解析后）；nil = 未配置。
    static var globalDefaultChoice: VoiceChoice? {
        VoiceChoiceCoder.decode(globalDefaultRaw)
    }

    // MARK: - 素材库链路解析（模型 → 纯值 → Core）

    /// 素材库改写/单段配音的音色解析。
    ///
    /// - Parameters:
    ///   - suppressVideoClone: M1b 视频级「跟随全局」开关；M1 恒 false。
    ///   - segment: M2 段级克隆音色。**带默认值 nil ⇒ 行为与M2 前完全一致**
    ///     （存量7 个调用点无需改动）。
    ///
    /// ⚠️ **M2：段级优先 + 视频级回落**
    /// 克隆改为按分镜时间范围后，同一视频里不同分镜可能持有**不同**的克隆音色
    /// （实测某 58.8s 视频 0~18s 男声、21s+ 女声）。若仍只读 `video.clonedVoiceId`，
    /// 解析出的音色会与该分镜实际注册的不一致 ⇒ 合成时用错voiceId。
    ///
    /// ⚠️ **漏改的调用点会静默退回视频级**：默认 nil 时行为与旧版一致，
    /// 所以新增段级语义时**必须**显式传 segment（见 DubbingViewModel 的调用点）。
    static func resolveForLegacy(video: Video,
                                 projectOverrideRaw: String?,
                                 suppressVideoClone: Bool = false,
                                 segment: Segment? = nil) -> VoiceResolution {
        // 段级优先；段级为nil（存量库/未克隆）时回落视频级。
        let cloneVoiceID = segment?.clonedVoiceId ?? video.clonedVoiceId
        return VoiceResolver.resolveForLegacyDub(.init(
            projectOverrideRaw: projectOverrideRaw,
            globalDefaultRaw: globalDefaultRaw,
            videoCloneVoiceID: cloneVoiceID,
            suppressVideoClone: suppressVideoClone))
    }

    /// 产品脚本成片的音色解析（只看项目覆盖与全局默认，不回退视频克隆）。
    static func resolveForScript(project: Project?) -> VoiceResolution {
        VoiceResolver.resolveForScript(projectOverrideRaw: project?.preferredVoiceChoiceRaw,
                                       globalDefaultRaw: globalDefaultRaw)
    }
}
