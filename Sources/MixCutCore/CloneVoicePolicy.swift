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
/// 与供应商的命名约束**分开**：供应商要的是 ASCII 标识名（Qwen `preferred_name`
/// ≤16 字符、仅数字/字母/下划线；CosyVoice `prefix` ≤10 字符、仅数字/字母），
/// 本地显示名要的是**用户能认出来的中文名**。两者是**同一条音色的两个名字**。
///
/// ## 清洗链（唯一真源，`VoiceCloneService.enroll` 也走这里）
///
/// ```
/// 中文等非 ASCII 字母 → StringTransform.toLatin → folding(.diacriticInsensitive)
///                      → 保留 ASCII 字母数字 → 截断到上限 → 空则回落
/// ```
///
/// **为什么用系统转写而不是拼音表**：`StringTransform.toLatin` 是 macOS 11+ 系统能力
/// （本工程 `Package.swift` 声明 `.macOS(.v14)`），本机实测 11 个样本全部产出合规 ASCII
/// （市土产仓库→`shituchancangku`、阿坝州→`abazhou` 多音字自动消歧），**零依赖零维护**；
/// 自建拼音表是几百行数据 + 长期维护成本。
///
/// **早前那个「不做拼音转写」的判断是错的**：原注释说「中文名清洗后往往为空」——
/// 实测确实为空（`我的声音` → 空 → 回落默认名），但那意味着**所有中文名都拿到同一个标识名**，
/// 用户在服务端控制台完全认不出哪个音色是自己注册的。转写后才有对账价值。
public enum CloneVoiceNaming {
    /// 生成供应商侧要求的 ASCII 标识名（清洗链唯一出口）。
    ///
    /// - Parameters:
    ///   - displayName: 用户输入的名字（中文会被转写为拼音；纯 ASCII 原样保留）。
    ///   - maxLength: 该供应商协议的字符上限。
    /// - Returns: 合规的标识名；**保证**纯 ASCII 且长度 ≤ `maxLength`；
    ///   清洗后为空时回落到品牌默认名（服务端不允许空名）。
    public static func sanitizeForProvider(_ displayName: String, maxLength: Int) -> String {
        let transliterated = transliterateToASCII(displayName)
        let ascii = transliterated.lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        // ⚠️ 上限至少留 1 位：`maxLength <= 0` 时 `prefix(0)` 会产出空串，
        // 触发下面的空回落 ⇒ 名字完全丢失（NV-3 钉住这条）。
        let room = max(1, maxLength)
        let trimmed = String(ascii.prefix(room))
        // ⚠️ **回落值也必须受 maxLength 约束**（NV-9 抓到的真缺陷）：
        // 直接 `return Brand.voiceAliasFallback`（"suncut"，6 字符），
        // 在 `maxLength = 1/4` 时**产出反而超限** —— 而「长度 ≤ maxLength」
        // 是本函数对调用方的**硬承诺**（服务端会拒超长名）。
        // 回落值同样截断：宁可给一个短名，也不可给一个会被服务端拒的名字。
        guard !trimmed.isEmpty else {
            return String(Brand.voiceAliasFallback.lowercased()
                .prefix(room))
        }

        // 截断后若发生碰撞，追加**稳定哈希**后缀消歧。
        //
        // ⚠️ **只对「转写后才变长」的名字消歧**（本机实测踩到的坑）：
        // 中文经拼音后长度暴涨（11 字 → 29 字符），截断到 16 后极易与另一个
        // 长中文名撞成同一结果 ⇒ 必须消歧。
        // 但纯 ASCII 输入（如 "My Voice 2024" 清洗后 12 字符 > 上限 10）**不该**消歧：
        // 那不是「转写导致的溢出」，而是用户名字本来就长；且 NV-2 已钉住
        // 「纯 ASCII 只保留+ 截断」这条语义。判据用**转写前后长度比**，
        // 不用「截断后是否变短」——后者会把纯 ASCII 长名也卷进来。
        let transliteratedLength = transliterateToASCII(displayName)
            .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.count
        let grewByTransliteration = transliteratedLength
            > displayName.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.count
        if trimmed.count < ascii.count, grewByTransliteration {
            return disambiguated(trimmed, original: ascii, room: room)
        }
        return trimmed
    }

    /// 中文等非 ASCII 字母 → 拉丁转写 → 去声调 → 纯 ASCII。
    ///
    /// ⚠️ `applyingTransform` 返回 **`String?`**（实测踩过：直接 `.unicodeScalars`
    /// 会编译失败），必须 `?? ""` 兜底 ⇒ 转换失败时退化为「过滤非 ASCII」，
    /// 与旧行为一致而不是崩溃。
    private static func transliterateToASCII(_ raw: String) -> String {
        guard let latin = raw.applyingTransform(.toLatin, reverse: false) else { return raw }
        // 声调符号（shì 的 `ì`）是非 ASCII，必须折掉，否则后面的 isASCII 过滤会把它删掉
        // —— 直接删会让 `shì` 变成 `sh`（丢信息），所以先 folding 去声调。
        return latin.folding(options: [.diacriticInsensitive], locale: nil)
    }

    /// 截断碰撞时的消歧后缀。
    ///
    /// ⚠️ **禁用 `hashValue`**：Swift 的字符串哈希**每个进程都不同**（默认随机种子），
    /// 不可持久化、不可复算 ⇒ 跨进程/重启后同一名字会得到不同后缀。
    /// 这里用 FNV-1a（纯值、可复算、无依赖）。
    ///
    /// ⚠️ **房间装不下后缀时不加后缀**（NV-9 抓到的第二个真缺陷）：
    /// 原实现 `keep = max(1, room - suffix.count)`，在 `room = 1` 时虽然前缀只剩 1 位，
    /// 但后缀本身就有 9 字符 ⇒ 产出 10 字符，**远超 room**，直接违反「长度 ≤ maxLength」
    /// 这个对调用方的硬承诺（服务端会拒超长名）。
    /// 判据：**后缀必须能让出位置**，放不下就退回纯截断——
    /// 「撞名」是坏体验，「服务端拒绝」是功能不可用，后者更糟。
    private static func disambiguated(_ prefix: String, original: String, room: Int) -> String {
        let hash = fnv1a(original)
        // 总预算 = room。**先定后缀长度，再让前缀用剩下的**——
        // 反过来算（先给前缀 `room - suffix.count` 再拼）会在 suffix 恰好等于 room 时
        // 产出 room+1 字符（NV-9 实测抓到：room=4 产出 5、room=8 产出 9）。
        // 判据直接写成「总长 ≤ room」，不靠中间量推导。
        let dashRoom = room - 1// 后缀里 `-` 占 1
        guard dashRoom >= 1 else { return String(prefix.prefix(room)) }
        let hexRoom = min(8, dashRoom)             // FNV-1a 是 32bit ⇒ 十六进制最多 8 位
        let hex = String(hash, radix: 16)
        let hexPart = String(hex.prefix(hexRoom))
        let suffix = "-" + hexPart
        let keep = max(0, room - suffix.count)
        return String(prefix.prefix(keep)) + suffix
    }

    /// FNV-1a 32 位哈希（纯值、可复算、跨进程稳定）。
    private static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in Array(s.utf8) {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// 名字能否产出合规标识名（供 UI 提交前预检，**不检查撞名**——
    /// 「库里已有哪些名字」只有 App 层知道，纯值层不依赖 App 状态）。
    public enum NameVerdict: Equatable, Sendable {
        /// 可以注册。
        case ok(providerName: String)
        /// 转写后没有任何可用的 ASCII 字母数字（如纯 emoji / 纯标点）。
        case notRepresentable
        /// 名太长，截断后加了消歧后缀才合规。
        case truncated(original: String, providerName: String)
    }

    /// 预检：这个显示名能不能用？返回结果而不只是 Bool，好让 UI 展示预览。
    public static func validate(_ displayName: String, maxLength: Int) -> NameVerdict {
        let cleaned = sanitizeForProvider(displayName, maxLength: maxLength)
        // 回落 = 什么都没剩下（否则 sanitize 至少会给 Brand.voiceAliasFallback）。
        // 注意回落本身是**合法**的（服务端接受），故不算 notRepresentable；
        // 只有「用户什么都没填」才是真问题。
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .notRepresentable
        }
        let transliterated = transliterateToASCII(displayName)
            .lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if cleaned.count < min(transliterated.count, max(1, maxLength)) {
            return .notRepresentable
        }
        if cleaned.count < transliterated.count {
            return .truncated(original: transliterated, providerName: cleaned)
        }
        return .ok(providerName: cleaned)
    }

    /// 供应商协议字符上限（供注册向导按目标协议取值，避免散落魔法数）。
    public enum ProviderLimit {
        /// Qwen `preferred_name`：数字/字母/下划线，≤16。
        public static let qwenPreferredName = 16
        /// CosyVoice `prefix`：数字/英文字母，≤10。
        public static let cosyVoicePrefix = 10
    }
}