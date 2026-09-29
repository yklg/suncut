import Foundation

/// 台词这条链上"用哪台引擎"的**9 格决策表**（计划 §3.2/§3.4，红线 R6）。
///
/// 纯函数：结论只由入参决定（TC-75 钉确定性），外部状态一律由调用方取好后传入。
public enum ASRPurpose: String, CaseIterable, Sendable {
    /// 整片听写，产出字级时间戳 —— 分镜边界的依据
    case wholeVideoTimeline
    /// 自建分镜：对用户上传的短片做整段听写（只取文本）
    case singleClipListening
    /// 逐段重听，覆盖 `Segment.text`
    case segmentTextRetake
}

public enum ASRPreference: String, CaseIterable, Sendable {
    case auto
    case cloud
    case local
}

/// 引擎清单。`CaseIterable` 是给能力表完备性判据用的（TC-120）：
/// 新增一台引擎（如计划工作流二的 F 路线）时，忘了给它配逐段重听能力会在测试里变红，
/// 而不是静默走"什么都不支持"的默认值。
public enum ASREngine: String, CaseIterable, Equatable, Sendable {
    case cloud
    case local
}

public enum EngineDecision: Equatable, Sendable {
    /// 走这条引擎，并给一句能显示给用户的原因
    case use(ASREngine, reason: String)
    /// 这个组合不可行 —— 必须拒绝，**不许静默换成另一条路线**
    case refused(reason: String)
}

/// 本地引擎的现状（由 App 侧从 `WhisperModelCatalog` 读好后传入）。
public struct LocalASRState: Equatable, Sendable {
    public let usable: Bool
    public let tier: String?

    public init(usable: Bool, tier: String?) {
        self.usable = usable
        self.tier = tier
    }
}

public enum ASREngineDecision {

    public static func decide(purpose: ASRPurpose,
                              preference: ASRPreference?,
                              hasCloudKey: Bool,
                              local: LocalASRState) -> EngineDecision {
        // "用户从没设过"与"用户选了自动"是两种状态，但落到同一条默认值上（TC-76）。
        let pref = preference ?? ASRPolicy.defaultPreference

        switch purpose {
        case .wholeVideoTimeline:
            return decideWholeVideo(preference: pref, local: local)
        case .singleClipListening:
            return decideSingleClip(preference: pref, local: local)
        case .segmentTextRetake:
            return decideSegmentRetake(preference: pref, hasCloudKey: hasCloudKey, local: local)
        }
    }

    // MARK: - 三种 purpose 各自的行为（一格一格对着计划 §3.2 的表读）

    /// 整片听写**恒本地**：云端 paraformer 只回文本、没有时间戳，喂给分镜切分会把边界搞坏。
    /// 这是能力线，与用户偏好无关 —— 偏好设为云端时是"这条路不存在"，不是"偷偷走本地"。
    private static func decideWholeVideo(preference: ASRPreference, local: LocalASRState) -> EngineDecision {
        if preference == .cloud {
            return .refused(reason: "整片听写需要字级时间戳，云端识别只返回文本，无法用于整片")
        }
        guard local.usable else {
            return .refused(reason: "本机没有可用的语音模型，整片听写跑不了；可在设置里下载语音模型")
        }
        return .use(.local, reason: "整片听写走本机 whisper（要字级时间戳）")
    }

    /// 单段整听：能力上云端够用（只取文本），但**默认不外流用户上传的文件**。
    /// 这一格是选择不是能力 —— 要放开就同时改测试与计划，别只改实现。
    private static func decideSingleClip(preference: ASRPreference, local: LocalASRState) -> EngineDecision {
        if preference == .cloud {
            return .refused(reason: "自建分镜是你自己上传的文件，默认不送到云端识别")
        }
        guard local.usable else {
            return .refused(reason: "本机没有可用的语音模型，这段上传文件的听写跑不了")
        }
        return .use(.local, reason: "上传片段的整段听写走本机 whisper")
    }

    /// 逐段覆盖台词：唯一会被偏好真正改变的入口（红线 R6 的作用域）。
    private static func decideSegmentRetake(preference: ASRPreference,
                                            hasCloudKey: Bool,
                                            local: LocalASRState) -> EngineDecision {
        switch preference {
        case .auto:
            if hasCloudKey {
                return .use(.cloud, reason: "已配千问 API Key，逐段重听走云端")
            }
            guard local.usable else {
                return .refused(reason: "既没有千问 API Key，本机也没有可用语音模型，逐段重听跑不了")
            }
            return .use(.local, reason: "未配置千问 API Key，逐段重听改走本机 whisper")

        case .cloud:
            guard hasCloudKey else {
                return .refused(reason: "尚未配置千问 API Key，无法走云端识别；可在设置里填写，或把引擎改成本地")
            }
            return .use(.cloud, reason: "按你的设置，逐段重听走云端")

        case .local:
            guard local.usable else {
                return .refused(reason: "你把引擎设成了本地，但本机没有可用的语音模型；可在设置里下载")
            }
            return .use(.local, reason: "按你的设置，逐段重听走本机 whisper（\(ASRPolicy.engineTier)）")
        }
    }
}
