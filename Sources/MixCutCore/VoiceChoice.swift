import Foundation

// ============================================================================
// 全局配音音色：身份 / 持久化编解码 / 工作流解析 / 合成合法性门 —— 全部纯值可单测。
//
// 背景：音色原本挂在视频级（Video.clonedVoiceId），且唯一获取路径是「逐视频克隆」。
// 本文件补上缺失的全局层：App 全局默认（UserDefaults）与项目覆盖（Project 字段）
// 都以 VoiceChoiceCoder 的版本化 JSON 串存储，解析按工作流分流。
//
// 纪律：
// - 解析不碰 SwiftData，入参全为纯值（raw 串/已解出的克隆 id）；
// - 坏串/未知版本一律解 nil（= 未配置，UI 引导设置），绝不 crash、绝不猜音色；
// - 选择「按哪个引擎合成」只看音色身份，不看业务模式（产品脚本/改写等业务词禁止进入路由）。
// ============================================================================

/// 合成引擎路由标识（与具体供应商型号解耦；型号由 VoiceChoice/默认值携带）。
public enum VoiceEngine: String, Equatable, Sendable {
    /// DashScope CosyVoice（预置音色与新注册复刻；rate 语速对齐）。
    case cosyVoice
    /// qwen3-tts-vc 逐视频原声克隆（atempo 对齐；存量链路）。
    case qwenVC
}

/// 一次配音合成使用的音色身份。
public enum VoiceChoice: Equatable, Sendable {
    /// 系统预置音色（CosyVoice 目录 id，如 longyingxiao）。
    case preset(voiceID: String)
    /// 账号级复刻音色（M2 起由上传/视频提取注册；绑定 CosyVoice 系具体型号）。
    case globalClone(profileID: UUID, voiceID: String, model: String)
    /// 存量逐视频克隆音色（qwen-vc）；voiceID 即 Video.clonedVoiceId。
    case videoClone(voiceID: String)

    /// 合成用 voice 参数（供应商 voice id）。
    public var voiceID: String {
        switch self {
        case .preset(let id), .videoClone(let id): return id
        case .globalClone(_, let id, _): return id
        }
    }

    /// 合成引擎：预置与全局复刻走 CosyVoice；逐视频克隆走 qwen-vc。
    public var engine: VoiceEngine {
        switch self {
        case .preset, .globalClone: return .cosyVoice
        case .videoClone: return .qwenVC
        }
    }

    /// CosyVoice 系合成所需型号（qwen-vc 引擎下为 nil，由 App 层映射到 qwen 克隆型号）。
    public var cosyVoiceModel: String? {
        switch self {
        case .preset: return CosyVoiceCatalog.model
        case .globalClone(_, _, let model): return model
        case .videoClone: return nil
        }
    }
}

/// 解析结果：成功携带音色；未配置是显式状态（调用方必须阻断并引导，不得静默兜底）。
public enum VoiceResolution: Equatable, Sendable {
    case resolved(VoiceChoice)
    case unconfigured
}

/// 音色解析（唯一真源；App 层负责把模型拍平成纯值入参）。
public enum VoiceResolver {

    /// 素材库改写/单段配音工作流的解析入参。
    public struct LegacyInput: Equatable, Sendable {
        /// 项目级覆盖串（Project.preferredVoiceChoiceRaw）；nil/坏=未覆盖。
        public var projectOverrideRaw: String?
        /// App 全局默认串（UserDefaults）；nil/坏=未配置。
        public var globalDefaultRaw: String?
        /// 当前视频的逐视频克隆音色 id（Video.clonedVoiceId）；nil/空=未克隆。
        public var videoCloneVoiceID: String?
        /// M1b：用户已在视频上显式选择「跟随全局/项目」，此时即使有历史克隆也压制克隆。
        public var suppressVideoClone: Bool

        public init(projectOverrideRaw: String? = nil,
                    globalDefaultRaw: String? = nil,
                    videoCloneVoiceID: String? = nil,
                    suppressVideoClone: Bool = false) {
            self.projectOverrideRaw = projectOverrideRaw
            self.globalDefaultRaw = globalDefaultRaw
            self.videoCloneVoiceID = videoCloneVoiceID
            self.suppressVideoClone = suppressVideoClone
        }
    }

    /// 素材库改写链路：
    /// 1) 未显式跟随全局、且视频已有克隆声 → 视频克隆优先（存量行为零变化）；
    /// 2) 否则 项目覆盖 → 全局默认；
    /// 3) 皆无 → unconfigured。
    public static func resolveForLegacyDub(_ input: LegacyInput) -> VoiceResolution {
        if !input.suppressVideoClone,
           let cloneID = nonEmpty(input.videoCloneVoiceID) {
            return .resolved(.videoClone(voiceID: cloneID))
        }
        return resolveChain(projectRaw: input.projectOverrideRaw, globalRaw: input.globalDefaultRaw)
    }

    /// 产品脚本成片工作流：项目覆盖 → 全局默认 → unconfigured。
    /// **绝不回退视频历史克隆**——脚本成片是全新配音语义（dubOnly，不使用原声）。
    public static func resolveForScript(projectOverrideRaw: String?,
                                       globalDefaultRaw: String?) -> VoiceResolution {
        resolveChain(projectRaw: projectOverrideRaw, globalRaw: globalDefaultRaw)
    }

    /// 公共级联：项目覆盖优先于全局默认；坏串按 nil 处理（继续向下回落）。
    private static func resolveChain(projectRaw: String?, globalRaw: String?) -> VoiceResolution {
        if let choice = VoiceChoiceCoder.decode(projectRaw) {
            return .resolved(choice)
        }
        if let choice = VoiceChoiceCoder.decode(globalRaw) {
            return .resolved(choice)
        }
        return .unconfigured
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - 持久化编解码（全局默认与项目字段的唯一编解码处）

/// VoiceChoice ↔ 版本化 JSON 串。
///
/// 串形态示例：`{"v":1,"kind":"preset","voice_id":"longyingxiao"}`。
/// 任何缺字段/类型漂移/未知版本/非法 JSON 都返回 nil（调用方按「未配置」处理）。
public enum VoiceChoiceCoder {
    public static let version = 1

    private enum Kind {
        static let preset = "preset"
        static let globalClone = "globalClone"
        static let videoClone = "videoClone"  // 理论上不持久化（随视频走），容忍解析
    }

    public static func encode(_ choice: VoiceChoice) -> String {
        var dict: [String: Any] = ["v": version]
        switch choice {
        case .preset(let voiceID):
            dict["kind"] = Kind.preset
            dict["voice_id"] = voiceID
        case .globalClone(let profileID, let voiceID, let model):
            dict["kind"] = Kind.globalClone
            dict["profile_id"] = profileID.uuidString
            dict["voice_id"] = voiceID
            dict["model"] = model
        case .videoClone(let voiceID):
            dict["kind"] = Kind.videoClone
            dict["voice_id"] = voiceID
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    public static func decode(_ raw: String?) -> VoiceChoice? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 版本：必须存在且等于当前版本；未知版本拒绝（未来向前兼容时在此显式迁移）。
        guard let v = obj["v"] as? Int, v == version else { return nil }
        guard let kind = obj["kind"] as? String else { return nil }
        switch kind {
        case Kind.preset:
            guard let id = nonEmptyString(obj["voice_id"]) else { return nil }
            return .preset(voiceID: id)
        case Kind.globalClone:
            guard let profileStr = nonEmptyString(obj["profile_id"]),
                  let profileID = UUID(uuidString: profileStr),
                  let voiceID = nonEmptyString(obj["voice_id"]),
                  let model = nonEmptyString(obj["model"]) else { return nil }
            return .globalClone(profileID: profileID, voiceID: voiceID, model: model)
        case Kind.videoClone:
            guard let id = nonEmptyString(obj["voice_id"]) else { return nil }
            return .videoClone(voiceID: id)
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

// MARK: - 合成合法性门（generateAudio 前置守卫的唯一判据）

/// 音色能否用于合成：预置在目录 ∪ 有效复刻 profile ∪ 当前视频自己的克隆声。
/// 空字符串/已失效音色一律拒绝（旧实现把空 voiceId 放进合成必报「音色已失效」）。
public enum VoiceSynthesisGate {

    public static func isUsable(_ choice: VoiceChoice,
                                isCatalogVoice: (String) -> Bool,
                                isValidCloneProfile: (UUID) -> Bool) -> Bool {
        switch choice {
        case .preset(let voiceID):
            return isCatalogVoice(voiceID)
        case .globalClone(let profileID, _, _):
            return isValidCloneProfile(profileID)
        case .videoClone:
            // 逐视频克隆的合法性由调用方对照「当前视频 clonedVoiceId」确认，
            // 门本身只保证形态合法（非空），不跨视频授权。
            return !choice.voiceID.isEmpty
        }
    }
}
