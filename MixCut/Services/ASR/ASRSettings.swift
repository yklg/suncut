import Foundation

/// App 侧 ASR 偏好读写宿主 —— 全仓库**唯一**允许读写 ASR 相关 UserDefaults 的地方（计划 §3.1）。
///
/// 规则住在 `MixCutCore/ASRPolicy`（纯函数层，禁止碰存储）；这里只回答"用户当前选了什么"。
/// 关键区分：`storedPreference` 在用户从没设过时返回 **nil**，回落动作交给规则层的
/// `ASRPolicy.defaultPreference` 做 —— 存储层自己写一个默认值，就会出现"第三个默认值"，
/// 而那正是本轮要消灭的形状。
enum ASRSettings {

    static let preferenceKey = "asr.enginePreference"

    /// 用户显式设置过的偏好；从没设过、或存的是认不出的值 ⇒ nil。
    static var storedPreference: ASRPreference? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: preferenceKey) else { return nil }
            return ASRPreference(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
        }
    }

    /// 当前生效偏好（回落在规则层，不在这里）。
    static var preference: ASRPreference {
        storedPreference ?? ASRPolicy.defaultPreference
    }

    /// 云端凭据是否就绪。**只回布尔** —— Key 的任何片段不得进日志、能力面或界面文案。
    static var hasCloudKey: Bool {
        guard let key = KeychainHelper.getAPIKey(for: .qwen) else { return false }
        return !key.isEmpty
    }
}

/// 模型所在根的用户可见说法。放 App 侧：核心层管规则，措辞归界面。
extension ModelRoot {
    var displayName: String {
        switch self {
        case .userDirectory: "你下载的模型文件夹"
        case .appBundle:     "应用内置"
        case .legacyCache:   "旧版缓存目录"
        case .systemDirectory: "系统目录"
        }
    }
}

/// 三档偏好的用户可见说法（设置页与 `get_asr_status` 共用一份，避免两处各写一遍措辞）。
extension ASRPreference {
    var displayName: String {
        switch self {
        case .auto:  "自动"
        case .cloud: "云端（千问）"
        case .local: "本地（whisper）"
        }
    }
}

/// 引擎本身的用户可见说法。
extension ASREngine {
    var displayName: String {
        switch self {
        case .cloud: "云端（千问）"
        case .local: "本机 whisper"
        }
    }
}

/// 三种用途的用户可见说法（能力面报"这次走哪条"时，光看 `wholeVideoTimeline` 这种机器名看不懂）。
extension ASRPurpose {
    var displayName: String {
        switch self {
        case .wholeVideoTimeline: "整片听写（分镜边界的依据）"
        case .singleClipListening: "自建分镜整段听写"
        case .segmentTextRetake: "逐段重认台词"
        }
    }
}

/// 四层里 L2/L3/L4 的提示措辞。**设置页与 `get_asr_status` 共用这一份** ——
/// 两处各写一遍，就会出现"界面说有损坏、Agent 问出来却是一种新说法"。
extension ModelIssue {
    var userText: String {
        switch self {
        case .truncated(let expected, let actual):
            let e = ByteCountFormatter.string(fromByteCount: expected, countStyle: .binary)
            let a = ByteCountFormatter.string(fromByteCount: actual, countStyle: .binary)
            return "提示：体积与官方值不符（期望 \(e)，实到 \(a)），可能没下完"
        case .badHeader:
            return "提示：有模型文件头不是 ggml 格式，可能已损坏"
        case .tierUnknown:
            return "提示：检测到档位表之外的模型文件名，仍按位置优先级使用"
        }
    }
}
