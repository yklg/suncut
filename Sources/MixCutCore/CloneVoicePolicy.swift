import Foundation

/// 复刻音色库（M2）——样本校验 / 授权留存 / Key 指纹失效 / 删除口径的**纯值层**。
///
/// ## 为什么这些判据必须在 Core
///
/// 复刻音色是**付费且带合规约束**的资产：
/// - 样本质量直接决定注册会不会被审核驳回（时长/体积不合规 → 白花钱）；
/// - 未授权的声音注册上去会污染音色库，且商用有法律风险；
/// - 换Key 后旧音色在新账户不存在（合成会报 InvalidParameter），必须**显式置灰**
///   而不是让用户撞到报错才知道。
///
/// 这三类判据一旦与UI/VM 的取值逻辑散在一起，就��出现「设置页显示合规、
/// 注册接口却放行」这类漂移。故全部下沉为纯函数，由单测钉死。
public enum CloneSampleValidator {

    // MARK: 官方约束（CosyVoice/Qwen 复刻文档口径）

    /// 官方建议的样本时长下限（秒）。过短提取不到稳定声纹。
    public static let minDurationSeconds: Double = 10
    /// 官方建议的样本时长上限（秒）。过长浪费上传时间，且可能超审核时长上限。
    public static let maxDurationSeconds: Double = 20
    /// 样本体积上限（MB）。
    public static let maxBytes: Int = 10 * 1024 * 1024

    /// 校验结论：一条错误信息或 nil（通过）。**不做多错误聚合** ——
    /// UI 一次只提示一条最关键的（时长优先，其次体积），用户改完再验，
    /// 比一次甩三条更可操作。
    public enum Verdict: Equatable, Sendable {
        case ok
        case tooShort(seconds: Double)
        case tooLong(seconds: Double)
        case tooLarge(megabytes: Double)
        case emptyFile
    }

    /// 校验样本音频。
    /// - Parameters:
    ///   - durationSeconds: 探测到的时长（秒）。
    ///   - byteSize: 文件字节数。
    public static func validate(durationSeconds: Double, byteSize: Int) -> Verdict {
        if byteSize <= 0 { return .emptyFile }
        if durationSeconds < minDurationSeconds {
            return .tooShort(seconds: durationSeconds)
        }
        if durationSeconds > maxDurationSeconds {
            return .tooLong(seconds: durationSeconds)
        }
        if byteSize > maxBytes {
            return .tooLarge(megabytes: Double(byteSize) / (1024 * 1024))
        }
        return .ok
    }

    /// Verdict → 用户可读文案（设置/注册向导共用同一份，避免两处措辞不一致）。
    public static func message(for verdict: Verdict) -> String? {
        switch verdict {
        case .ok: return nil
        case .emptyFile:
            return "音频文件是空的，换一个文件试试"
        case .tooShort(let s):
            return String(format: "样本只有 %.1f 秒，太短了提取不到稳定音色；建议 %d–%d 秒",
                          s, Int(minDurationSeconds), Int(maxDurationSeconds))
        case .tooLong(let s):
            return String(format: "样本有 %.1f 秒，太长了；建议 %d–%d 秒",
                          s, Int(minDurationSeconds), Int(maxDurationSeconds))
        case .tooLarge(let mb):
            return String(format: "样本有 %.1f MB，超过 %d MB 上限",
                          mb, maxBytes / (1024 * 1024))
        }
    }

    /// 边界形态单测用的「刚好合规」样本（10.0s / 1MB）。
    public static let acceptableDurationSeconds: Double = 12
    public static let acceptableByteSize: Int = 2 * 1024 * 1024
}

// MARK: - Key 指纹与失效

/// 音色与创建它的 API Key 绑定：DashScope 的克隆音色注册在**某个账户**下，
/// 换 Key 后旧 voice_id 在新账户不存在，合成时服务端报 InvalidParameter。
///
/// 处置口径（与逐视频克隆的 `generateAllAudioWithRecloneFallback` 同源、同一理由）：
/// **Key 指纹不匹配 ⇒ 该音色置灰，不自动重注册、不保留样本**。
/// 理由：自动重注册会静默消耗配额、且用户可能已经换回原Key（置灰反而是错的）；
/// 保留样本则等于把用户的声音留在盘上等人误用。处置权交回用户。
public enum VoiceProfileValidity {
    /// 当前音色是否应被置灰。
    /// - Parameters:
    ///   - profileKeyFingerprint: 注册时记录的 Key 指纹（nil = 存量无指纹，见下）。
    ///   - currentFingerprint: 当前 Key 的指纹（nil = 未配置 Key）。
    /// - Returns: true = 置灰。
    public static func isInvalidated(profileKeyFingerprint: String?,
                                     currentFingerprint: String?) -> Bool {
        // 当前无 Key：不置灰 —— 那是「未配置」的引导问题，不是「音色失效」。
        guard let currentFingerprint, !currentFingerprint.isEmpty else { return false }
        // 存量音色无指纹：乐观复用（与逐视频克隆 `ensureClonedVoice` 同口径）。
        // 存量优先零行为变化；真失效时合成会报错，落到既有重克隆兜底。
        guard let profileKeyFingerprint, !profileKeyFingerprint.isEmpty else { return false }
        return profileKeyFingerprint != currentFingerprint
    }

    /// 置灰时给用户看的提示（与 `isInvalidated` 同源导出，避免 UI 自己拼）。
    public static func invalidatedMessage() -> String {
        "这个复刻音色是在另一个 API Key 下注册的，当前 Key 用不了它。"
        + "请用原 Key 合成，或删除后用当前 Key 重新注册。"
    }
}

// MARK: - 删除口径

/// 删除复刻音色时，音色库里这一项该怎么处置。
///
/// 关键语义（M2 计划的「删除选仅本地 / 同时注销远端释放配额」）：
/// - **仅本地**：只删库里的记录，**已生成音频全部保留** —— 用户已有成片不受影响，
///   只是这个音色不能再用于新合成；
/// - **同时注销远端**：额外调远端 delete 释放配额。远端注销失败**不能**回滚本地删除
///   （那会把用户卡在「本地已删但远端还在」的比配额更糟的状态），应如实提示远端失败。
public enum CloneProfileDeletion {
    public enum Scope: String, Equatable, Sendable, CaseIterable {
        /// 只删本地记录，远端音色保留（会继续占配额）。
        case localOnly
        /// 删本地记录 + 注销远端音色（释放配额）。
        case alsoRevokeRemote

        public var label: String {
            switch self {
            case .localOnly: return "仅删除本地记录"
            case .alsoRevokeRemote: return "同时注销远端并释放配额"
            }
        }

        public var detail: String {
            switch self {
            case .localOnly:
                return "已生成的配音全部保留；远端音色仍占配额。"
            case .alsoRevokeRemote:
                return "已生成的配音仍全部保留；远端音色被注销后释放配额，不能再用它合成。"
            }
        }
    }

    /// 该口径下，已生成音频是否保留（恒 true，写成函数而非常量是为了把
    /// 「删音色绝不能毁掉用户的成片」这条铁律显式钉在代码里，让守卫能引用）。
    public static func keepsExistingAudio(_ scope: Scope) -> Bool { true }
}

// MARK: - 命名清洗（Qwen preferred_name）

/// 复刻音色的本地显示名清洗。
///
/// 与供应商的命名约束**分开**：供应商要的是 ASCII 前缀（Qwen `preferred_name`
/// ≤16 字符、仅数字/字母/下划线；CosyVoice `prefix` ≤10 字符、仅数字/字母），
/// 本地显示名要的是**用户能认出来的中文名**。
/// 早前把两者共用一个清洗函数（过滤中文 + 截断 20）会两头不讨好：
/// 用户看到的是一串拼音，而供应商侧其实还有更严的字符集约束。
public enum CloneVoiceNaming {
    /// 生成供应商侧要求的 ASCII 名称。
    /// - Parameters:
    ///   - displayName: 用户输入的中文名（会被转写/过滤）。
    ///   - maxLength: 该供应商协议的字符上限。
    /// - Returns: 清洗后的名称；清洗后为空时回落到品牌默认名（与服务端要求一致）。
    public static func sanitizeForProvider(_ displayName: String, maxLength: Int) -> String {
        // 注意：不做「拼音转写」——那需要引入拼音库，且中文名清洗后往往为空。
        // 服务端侧本来就会带唯一 id（如 `cosyvoice-v3-plus-<prefix>-xxxxxx`），
        // 本地显示名走 VoiceProfile.name，不需要与远端名一致。
        let ascii = displayName.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let trimmed = String(ascii.prefix(max(1, maxLength)))
        return trimmed.isEmpty ? Brand.voiceAliasFallback : trimmed
    }

    /// 供应商协议字符上限（供注册向导按目标协议取值，避免散落魔法数）。
    public enum ProviderLimit {
        /// Qwen `preferred_name`：数字/字母/下划线，≤16。
        public static let qwenPreferredName = 16
        /// CosyVoice `prefix`：数字/英文字母，≤10。
        public static let cosyVoicePrefix = 10
    }
}