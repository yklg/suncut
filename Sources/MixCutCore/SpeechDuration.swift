import Foundation

/// 口播时长估算（纯逻辑，可单测）。
///
/// 逆向结构化：粘贴文案没有真实时长，按「字数 ÷ 常速每秒字数」估时长。
///
/// 这里**只估时长**，不再判"能不能变速" —— 旧的 `atempoFactor`（放行区间 0.5–2.0）
/// 已删除：语速固定口径下超字一律拒绝，判据住在 `DubLengthGate`。
/// 那颗旧判据的坑记在 `DubRatePolicy.swift` 的文件头，别再照它写第二道闸。
///
/// ⚠️ `charactersPerSecond` 是未校准经验值。固定语速后估不准不再被 atempo 吸收，
/// 而是直接决定这稿字会不会被闸掉 ⇒ 实测回校走 `DubVoiceCalibration`。
public enum SpeechDuration {

    /// 中文口播常速（字/秒，含自然停顿的经验值；短视频带货口播约 4–5 字/秒）。
    public static let charactersPerSecond = 4.3

    /// 按字数估算口播时长（秒）。
    public static func estimate(characterCount: Int) -> Double {
        guard characterCount > 0 else { return 0 }
        return Double(characterCount) / charactersPerSecond
    }

    /// 按**指定字/秒**估算口播时长 —— 供 `DubVoiceCalibration` 的实测回校档使用。
    /// 非正的 cps 一律回落到常速档，不许除出 inf 或负数冒充估算值。
    public static func estimatedSeconds(for text: String,
                                        charsPerSecond: Double = charactersPerSecond) -> Double {
        let cps = charsPerSecond.isFinite && charsPerSecond > 0 ? charsPerSecond : charactersPerSecond
        return Double(spokenCharacterCount(text)) / cps
    }

    /// 有效朗读字数：去除空白与换行（标点保留——停顿已含在常速经验值里）。
    public static func spokenCharacterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !$0.isNewline }.count
    }
}
