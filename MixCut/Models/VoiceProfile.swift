import Foundation
import SwiftData

/// 账号级复刻音色（M2）。区别于 `Video.clonedVoiceId`（逐视频、注册后即绑死那个视频）：
/// `VoiceProfile` 是**跨项目共享**的账号级资产，存进音色库后可被任意项目引用。
///
/// ## 为什么不再沿用 `Video.clonedVoiceId`
///
/// 存量链路里，音色是「视频」的私有属性：为了给一个视频配音，得先给那个视频跑demucs
/// 分离 + 注册一次，注册出来的 `voiceId` 只存在那个视频上。代价有三：
/// ① 同一份声音在N 个视频上要注册 N 次（**重复付费、重复上传样本**）；
/// ② 换项目想用同一个声音 ⇒ 做不到；
/// ③ 用户没有「我的音色库」这个概念，也没法统一管理/删除自己的声音。
///
/// M2 把它提升为独立实体，「我的复刻音色库」才有意义。
///
/// ## 删除语义（重要）
///
/// 删除 profile **只删这条记录**：
/// - 引用它的 `VoiceChoice.globalClone`（全局默认 / 项目覆盖 / 脚本段覆盖）在读侧
///   解析失败 ⇒ 回落到下一级（全局默认 → unconfigured），UI 引导重新选，**不静默换音色**；
/// - **已生成的配音音频全部保留**（`SegmentDub.audioFilePath` 指向的成品 m4a 自包含，
///   与本实体无文件级依赖）—— 删音色绝不能毁掉用户已经做好的成片。
@Model
final class VoiceProfile {
    @Attribute(.unique) var id: UUID
    /// 用户可读的名字（中文即可，不受供应商 ASCII 命名约束——见 Core CloneVoiceNaming）。
    var name: String
    /// 注册返回的音色 id，直接作为 TTS 的 voice 参数（不是显示名）。
    var voiceId: String
    /// 注册时的显示名清洗结果（供应商侧 ASCII 名）。仅用于排查与远端对账；
    /// 合成**不用**它（用 voiceId）。
    var providerName: String
    /// 驱动该音色的合成型号（如 `qwen3-tts-vc-2026-01-22`）。
    /// 注册与合成必须同型号（服务端要求），故随记录一起持久化。
    var rawModel: String
    /// 来源：上传音频 / 从素材库视频提取参考音。
    var kindRaw: String = CloneProfileKind.upload.rawValue
    /// 创建时的 API Key 指纹（换 Key 后该音色在新账户不存在 ⇒ 置灰，见 Core VoiceProfileValidity）。
    /// "" = 存量无指纹（乐观复用）。
    var keyFingerprint: String = ""
    /// 注册时刻（用于「授权确认于何时」的追溯）。
    var createdAt: Date = Date()
    /// 用户是否已确认拥有该声音的合法授权（**注册前置条件，未勾选不得注册**）。
    var consentAccepted: Bool = false
    /// 授权确认时间（nil = 未确认）。与 consentAccepted 冗余保存是刻意的：
    /// 后台要展示「授权于 X 时确认」，只有布尔值答不了这个问题。
    var consentAcceptedAt: Date?
    /// 参考音频在本机的路径（M2 qwen 路线把样本留在本机，便于用户重注册；
    /// nil = 样本已被清理，此时「重新注册」需用户重新选文件）。
    var sampleAudioPath: String?
    /// 样本时长（秒），注册时快照；用于库内展示与「为什么被拒」复盘。
    var sampleDurationSeconds: Double = 0

    init(id: UUID = UUID(),
         name: String,
         voiceId: String,
         providerName: String,
         rawModel: String,
         kind: CloneProfileKind = .upload,
         keyFingerprint: String = "",
         sampleAudioPath: String? = nil,
         sampleDurationSeconds: Double = 0) {
        self.id = id
        self.name = name
        self.voiceId = voiceId
        self.providerName = providerName
        self.rawModel = rawModel
        self.kindRaw = kind.rawValue
        self.keyFingerprint = keyFingerprint
        self.sampleAudioPath = sampleAudioPath
        self.sampleDurationSeconds = sampleDurationSeconds
        self.createdAt = Date()
    }

    /// 来源读侧（认不出的存量值回落 .upload，不猜测）。
    var kind: CloneProfileKind {
        get { CloneProfileKind(rawValue: kindRaw) ?? .upload }
        set { kindRaw = newValue.rawValue }
    }

    /// 唯一写入口：授权确认与时间戳必须同时落（不允许有勾选没时间，或有时间没勾选）。
    /// 授权是合规留痕，两者是**一条事实**而不是两个可独立修改的字段。
    func recordConsent(at date: Date = Date()) {
        consentAccepted = true
        consentAcceptedAt = date
    }

    /// 本音色对应的合成身份（写进 `VoiceChoice.globalClone` / 解析时的形态）。
    var voiceChoice: VoiceChoice {
        .globalClone(profileID: id, voiceID: voiceId, model: rawModel)
    }

    /// 当前 Key 下该音色是否已失效（置灰）。判据在 Core，App 只负责取当前指纹喂进去。
    func isInvalidated(currentKeyFingerprint: String?) -> Bool {
        VoiceProfileValidity.isInvalidated(profileKeyFingerprint: keyFingerprint,
                                           currentFingerprint: currentKeyFingerprint)
    }

    /// 库内展示用副标题（状态 + 来源 + 型号），不掺业务词。
    var displaySubtitle: String {
        var parts: [String] = [VoiceCatalog.displayName(id: voiceId) == voiceId
            ? rawModel : VoiceCatalog.displayName(id: voiceId)]
        parts.append(kind.displayName)
        if !consentAccepted { parts.append("未确认授权") }
        return parts.joined(separator: " · ")
    }
}

/// 复刻音色的来源（与 `TranscriptSource` 无关，别混）。
enum CloneProfileKind: String, CaseIterable {
    /// 用户上传一段音频。
    case upload
    /// 从素材库里某个视频提取参考音。
    case fromVideo

    var displayName: String {
        switch self {
        case .upload: return "上传音频"
        case .fromVideo: return "视频提取"
        }
    }
}