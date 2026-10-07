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
    /// - Parameter suppressVideoClone: M1b 视频级「跟随全局」开关；M1 恒 false。
    static func resolveForLegacy(video: Video,
                                 projectOverrideRaw: String?,
                                 suppressVideoClone: Bool = false) -> VoiceResolution {
        VoiceResolver.resolveForLegacyDub(.init(
            projectOverrideRaw: projectOverrideRaw,
            globalDefaultRaw: globalDefaultRaw,
            videoCloneVoiceID: video.clonedVoiceId,
            suppressVideoClone: suppressVideoClone))
    }

    /// 产品脚本成片的音色解析（只看项目覆盖与全局默认，不回退视频克隆）。
    static func resolveForScript(project: Project?) -> VoiceResolution {
        VoiceResolver.resolveForScript(projectOverrideRaw: project?.preferredVoiceChoiceRaw,
                                       globalDefaultRaw: globalDefaultRaw)
    }
}
