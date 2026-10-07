import Foundation

/// 原始 TTS 音频缓存（M3）——键与 LRU 判据的**纯值层**，App 层不碰。
///
/// ## 为什么缓存「原始 TTS」而不是成品m4a
///
/// `DubAudioFinalizer` 产出的 m4a 与 `targetDuration`/`fps` **强绑定**
/// （atempo 变速 + 定格补帧 + 末尾静音）。同一个文案出现在两个不同时长的分镜里，
/// 成品 m4a 无法复用；而 TTS 供应商侧的原始音频**与时长无关**，
/// 各分镜拿到同一份原始音频后**各自 finalize**（自己的 atempo + 补帧）。
/// 所以缓存必须发生在 finalize **之前**，绝不能直接复用成品 m4a。
///
/// ## 键的构成（缺一不可）
///
/// `engine + model + voice + textHash + rateBucket`：
/// - **engine**：预置/CosyVoice 复刻走 cosyVoice，逐视频克隆走 qwen-vc —— 两家产物不可混。
/// - **model**：同一家下不同型号（cosyvoice-v2 / v3-plus）音色与音质都不同。
/// - **voice**：音色 id。
/// - **textHash**：文案内容（归一化后取哈希，见 `normalizedTextHash`）。
/// - **rateBucket**：**语速档位**，不是精确 rate —— 见下方分桶口径。
///
/// ## 为什么 rate 要分桶而不是用精确值
///
/// `generateAudio` 里有 `SpeechRatePlanner.retargetRate`：先按 rate=1.0 合成，
/// 再按目标时长反算一个 rate 复合成第二次。若把精确 rate 写进键，
/// 同一文案因目标时长不同会算出不同 rate → 永远命中不了，缓存形同虚设。
/// 而真正决定音频内容的是「语速档位」——同一档内的 rate 差异人耳不可辨，
/// 复合成结果在工程上等价。故按 `rateBucket` 分档（0.05 一档），
/// 命中后**用命中档的音频**喂finalize，由 finalize 的 atempo 把时长对齐到各自目标。
///
/// ## sampleRate / format 为什么进键
///
/// 采样率与容器格式由**客户端实现**决定（CosyVoice 固定 24kHz/mp3；
/// qwen-vc 是另一条路）。它们变了音频内容就变，故进键。
/// 客户端换型号/换实现时，键自然不同，不会误命中旧产物。
public struct RawAudioCacheKey: Equatable, Hashable, Sendable {
    /// 引擎标识（与 `VoiceEngine` 同名同义，独立于 App 层以免 Core 依赖 App）。
    public enum Engine: String, Sendable { case cosyVoice, qwenVC }

    /// 归一化后的语速档（`Int32`，步长 `rateBucketStep`）。
    public let rateBucket: Int32
    public let textHash: String
    public let engine: Engine
    public let model: String
    public let voiceID: String
    public let sampleRate: Int
    public let format: String

    public init(engine: Engine, model: String, voiceID: String,
                text: String, rate: Double, sampleRate: Int, format: String) {
        self.engine = engine
        self.model = model
        self.voiceID = voiceID
        self.sampleRate = sampleRate
        self.format = format
        self.rateBucket = Self.bucket(for: rate)
        // 局部变量再赋值：`self.x = Self.f(...)` 在 init 里 Swift 会先解析成隐式
        // self 捕获（而 init 尚未完成，let 属性不能在被 init 体内直接赋值）。
        let hash = Self.normalizedTextHash(text)
        self.textHash = hash
    }

    /// 分桶步长：0.05。太小会让命中率崩（rate 是连续值），太大则档内差异可闻。
    ///
    /// 步长取0.05 的依据：`SpeechRatePlanner.retargetRate` 只在 drift 超过
    /// `acceptTolerance` 时才返回不同的 rate，而实际抖动幅度通常 < 0.05；
    /// 也就是说**同一段文案在不同分镜上算出的 retarget rate 几乎总落同一档**
    /// —— 这正是缓存能命中的前提。
    public static let rateBucketStep: Double = 0.05

    /// rate → 档号。四舍五入到步长，clamp 到 [0.5, 2.0]（与 CosyVoice 的合法区间一致）。
    ///
    /// ⚠️ 边界语义：档边界附近（如 1.025）相邻 0.01 的两个 rate 会分属两档。
    /// 这是分桶的固有性质、也是刻意接受的取舍 —— 宁可偶尔不命中一次
    /// （多合成一次，仅费一次短文本费），也不要把步长放大到牺牲音质。
    /// RA-2/RA-3 钉的正是这个契约。
    public static func bucket(for rate: Double) -> Int32 {
        let clamped = min(max(rate, 0.5), 2.0)
        return Int32((clamped / rateBucketStep).rounded())
    }

    /// 档号 → 桶心率值（命中后用它复述给调用方，避免拿到「档号」这种抽象值）。
    public static func rate(forBucket bucket: Int32) -> Double {
        Double(bucket) * rateBucketStep
    }

    /// 文案归一化后取哈希。
    ///
    /// 归一化：去首尾空白 + 折叠内部连续空白 + 统一全角空格。
    /// 目的是让「排版差异」（换行、缩进、多余空格）**算同一份文案**——
    /// 用户从不同来源粘贴同一段文案时不该重复付费。
    public static func normalizedTextHash(_ text: String) -> String {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return "empty" }
        // FNV-1a 32bit：够短（可作文件名）、够均匀、纯 Swift 无依赖。
        // 代价是理论碰撞率~1/2^32 —— 缓存只是省一次 TTS，撞了也只是多合成一次，
        // 不涉及正确性或安全，故可接受。**不要**用它做安全用途。
        var hash: UInt32 = 0x811c9dc5
        for byte in Array(normalized.utf8) {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(hash, radix: 16, uppercase: false)
    }

    /// 文案归一化（折叠空白）。
    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        var hasContent = false
        for ch in text {
            if ch.isWhitespace || ch == "\u{3000}" {
                if hasContent { pendingSpace = true }
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(ch)
            hasContent = true
        }
        return out
    }

    /// 落盘文件名（不含扩展名）：**全键的稳定摘要**。
    /// 用键各字段拼一个可读串再哈希 —— 目录里能看出大致来源，便于人工排查；
    /// 同时对语音 id / 文案长度不设限（长文案不会撑爆文件名）。
    public var fileStem: String {
        let raw = [
            engine.rawValue, model, voiceID,
            String(sampleRate), format,
            String(rateBucket), textHash,
        ].joined(separator: "|")
        return RawAudioCacheKey.stableDigest(raw)
    }

    /// FNV-1a（与 `normalizedTextHash` 同算法，单测可复用同一真源）。
    public static func stableDigest(_ string: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in Array(string.utf8) {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(hash, radix: 16, uppercase: false)
    }
}

// MARK: - LRU 淘汰判据（纯函数，供App 层 actor 调用）

/// 缓存条目的一行账（文件属性扫出来的，不含文件内容）。
public struct RawAudioCacheEntry: Equatable, Sendable {
    public let fileStem: String
    /// 文件字节数。
    public let byteSize: Int64
    /// 最后访问时刻（用于 LRU 排序）。
    public let lastAccess: Date

    public init(fileStem: String, byteSize: Int64, lastAccess: Date) {
        self.fileStem = fileStem
        self.byteSize = byteSize
        self.lastAccess = lastAccess
    }
}

/// LRU 判据：哪些条目该被淘汰才能把总量压到 `budgetBytes` 以内。
///
/// 纪律：
/// - **被引用者跳过**（`protectedStems`）—— 引用的文件删掉会让用户的配音变哑，
///   宁可缓存超限也不能删（超限只多占磁盘，删掉是功能损坏）；
/// - 其余按 lastAccess **升序**（最久未用的先走）淘汰；
/// - 永不返回 `protectedStems` 内的条目，即便预算为 0（宁可超限）；
/// - 预算 ≤ 0 视为「不限制」（全留），避免误配把缓存清空。
public enum RawAudioCacheEvictor {
    public static func victims(_ entries: [RawAudioCacheEntry],
                               budgetBytes: Int64,
                               protectedStems: Set<String>) -> [RawAudioCacheEntry] {
        guard budgetBytes > 0 else { return [] }   // 预算非正 = 不限制
        var total = entries.reduce(Int64(0)) { $0 + $1.byteSize }
        guard total > budgetBytes else { return [] }
        // 升序：最久未访问在前
        let evictable = entries
            .filter { !protectedStems.contains($0.fileStem) }
            .sorted { lhs, rhs in
                if lhs.lastAccess != rhs.lastAccess { return lhs.lastAccess < rhs.lastAccess }
                return lhs.fileStem < rhs.fileStem   // 时间相同用文件名定序，保证确定性
            }
        var victims: [RawAudioCacheEntry] = []
        for entry in evictable {
            if total <= budgetBytes { break }
            victims.append(entry)
            total -= entry.byteSize
        }
        return victims
    }

    /// 淘汰后应剩多少字节（供设置页显示，不重复扫盘）。
    public static func bytesAfterEviction(_ entries: [RawAudioCacheEntry],
                                           victims: [RawAudioCacheEntry]) -> Int64 {
        let removed = Dictionary(uniqueKeysWithValues: victims.map { ($0.fileStem, $0.byteSize) })
        return entries.reduce(Int64(0)) { sum, e in
            sum + (removed[e.fileStem] == nil ? e.byteSize : 0)
        }
    }
}