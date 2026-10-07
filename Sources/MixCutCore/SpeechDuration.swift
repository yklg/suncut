import Foundation

/// 口播时长估算与变速安全判据（纯逻辑，可单测）。
///
/// - 逆向结构化：粘贴文案没有真实时长，按「字数 ÷ 常速每秒字数」估时长；
/// - 正向写作：写出来的文案真实朗读时长应贴近槽位时长，偏差由 atempo 变速补偿，
///   FFmpeg atempo 单次有效区间为 0.5–2.0，超出即音质不可接受/算法不支持，必须重写。
public enum SpeechDuration {

    /// 中文口播常速（字/秒，含自然停顿的经验值；短视频带货口播约 4–5 字/秒）。
    public static let charactersPerSecond = 4.3

    /// 按字数估算口播时长（秒）。
    public static func estimate(characterCount: Int) -> Double {
        guard characterCount > 0 else { return 0 }
        return Double(characterCount) / charactersPerSecond
    }

    /// 给定文案与槽位时长，计算满足槽位时长所需的 atempo 系数。
    ///
    /// - 文案时长 ≤ 0 或槽位时长 ≤ 0 ⇒ nil（无法判）；
    /// - 系数落在 0.5–2.0 ⇒ 返回该系数；超出 ⇒ 返回 nil（调用方须要求重写，不许硬变速）。
    public static func atempoFactor(for text: String, slotDuration: Double) -> Double? {
        let spoken = estimate(characterCount: spokenCharacterCount(text))
        guard spoken > 0, slotDuration > 0 else { return nil }
        let factor = spoken / slotDuration
        guard (0.5...2.0).contains(factor) else { return nil }
        return factor
    }

    /// 有效朗读字数：去除空白与换行（标点保留——停顿已含在常速经验值里）。
    static func spokenCharacterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !$0.isNewline }.count
    }
}
