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
    /// 账号级复刻音色（M2：由上传音频 / 从素材库视频提取参考音注册）。
    ///
    /// - `voiceID` 是注册返回的音色 id（不是显示名）。
    /// - `model` 是**驱动该音色的合成型号**，注册与合成必须同型号，否则服务端报错。
    ///   M2 走了 Qwen 复刻路线（`qwen-voice-enrollment`，base64 内联 + 同步返回），
    ///   故这里的 model 形如 `qwen3-tts-vc-*`。
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

    /// 合成引擎路由：**由型号决定，不硬编码**。
    ///
    /// M2 之前的写法是「`globalClone` 一律 `.cosyVoice`」——那是在「M2 必定走
    /// CosyVoice 复刻」的假设下写的。实际选定Qwen 复刻路线后，账号级复刻音色
    /// 注册自 `qwen-voice-enrollment`、由 `qwen3-tts-vc-*` 驱动，**必须走 qwen-vc 分支**
    /// （走 atempo 对齐 + 重试取最短），否则会用 CosyVoice 客户端去请求一个
    /// qwen 音色 —— 服务端直接报错，而且这种错在类型层面看不出来。
    ///
    /// 判据用型号前缀（`qwen3-tts-vc` / `qwen-audio-` ⇒ qwen 系），而不是「是不是
    /// globalClone」—— 后者在两条复刻路线都存在时是错的。
    public var engine: VoiceEngine {
        switch self {
        case .preset:
            return .cosyVoice
        case .videoClone:
            return .qwenVC
        case .globalClone(_, _, let model):
            return Self.isQwenFamily(model) ? .qwenVC : .cosyVoice
        }
    }

    /// 型号是否属于 Qwen 系（`qwen3-tts-vc-*` / `qwen-audio-*` 等）。
    public static func isQwenFamily(_ model: String) -> Bool {
        model.lowercased().hasPrefix("qwen")
    }

    /// CosyVoice 系合成所需型号；qwen-vc 引擎下为 nil（App 层映射到 qwen 克隆型号）。
    public var cosyVoiceModel: String? {
        switch self {
        case .preset: return CosyVoiceCatalog.model
        case .globalClone(_, _, let model): return Self.isQwenFamily(model) ? nil : model
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

        // MARK: - M2 段级克隆（克隆音色从视频级搬到分镜级）

        /// **段级克隆音色 id（M2）**：该**分镜**自己的克隆音色。nil/空=该分镜未克隆。
        ///
        /// ## 为什么必须有这个字段（2026-10-08 根因）
        ///
        /// M2 把克隆从「按视频」改成「按分镜时间范围」（`Segment.clonedVoiceId` +
        /// `cloneWindowStartFrame/EndFrame`）。但本结构**只有视频级字段**，
        /// ⇒ 整条解析链**在契约层就无法表达「这个分镜有自己的克隆声」**
        /// ⇒ 每个读侧只能自己想办法（多数没想）⇒ 一次改造产生 6 处读侧回归
        /// （音色菜单消失 / 一键改写跳过已有克隆合成错音色 / 点「生成」报音色失效…）。
        ///
        /// **优先级：段级 > 视频级**（视频级是存量兼容层，见 `resolveForLegacyDub`）。
        public var segmentCloneVoiceID: String?

        /// 本作用域内**是否有任一分镜**已克隆（M2）。
        ///
        /// ## 为什么它与 `segmentCloneVoiceID` 是两件事
        ///
        /// 前者回答「**这个**分镜用哪个克隆声」；本字段回答「本次操作**是不是**克隆链路」。
        /// 后者决定 `rewrite()` 走克隆分支还是预置分支，而**分支不能只看 voiceID**：
        /// 视频未按视频克隆过（`videoCloneVoiceID == nil`）但分镜已按分镜克隆过时，
        /// 只看 voiceId 会退回预置分支 ⇒ 已付费注册的音色被跳过 ⇒ 合成出错误音色。
        ///
        /// ⚠️ 段级化必然产生**混合状态**（部分分镜已克隆、部分没有），
        /// 所以它不是「本视频是否克隆过」而是「**本作用域**是否有克隆」。
        public var hasAnySegmentClone: Bool

        public init(projectOverrideRaw: String? = nil,
                    globalDefaultRaw: String? = nil,
                    videoCloneVoiceID: String? = nil,
                    suppressVideoClone: Bool = false,
                    segmentCloneVoiceID: String? = nil,
                    hasAnySegmentClone: Bool = false) {
            self.projectOverrideRaw = projectOverrideRaw
            self.globalDefaultRaw = globalDefaultRaw
            self.videoCloneVoiceID = videoCloneVoiceID
            self.suppressVideoClone = suppressVideoClone
            self.segmentCloneVoiceID = segmentCloneVoiceID
            self.hasAnySegmentClone = hasAnySegmentClone
        }
    }

    /// 素材库改写链路（M2 段级优先）：
    /// 1) 未显式跟随全局、且**该分镜**已有克隆声 → 分镜克隆优先（`segmentCloneVoiceID`）；
    /// 2) 存量回落到视频级克隆声（`videoCloneVoiceID`，仅段级为空时）；
    /// 3) 否则 项目覆盖 → 全局默认；
    /// 4) 皆无 → unconfigured。
    ///
    /// ⚠️ **本函数只回答「用哪个音色」**；「是否走克隆分支」由
    /// `CloneBranchDecider.shouldClone` 回答 ——两者必须用同一套判据，
    /// 否则会出现「解析说克隆、分支说预置」的错配（这正是 M2 的 R3 回归）。
    public static func resolveForLegacyDub(_ input: LegacyInput) -> VoiceResolution {
        if !input.suppressVideoClone {
            // 段级优先（默认 nil 时行为与 M2 前完全一致 ⇒ 存量零变化）
            if let segID = nonEmpty(input.segmentCloneVoiceID) {
                return .resolved(.videoClone(voiceID: segID))
            }
            if let cloneID = nonEmpty(input.videoCloneVoiceID) {
                return .resolved(.videoClone(voiceID: cloneID))
            }
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
