import Foundation

/// 分镜规划阈值的双层参数。
///
/// 出厂值住 Core（`SegmentationPlanConfig`，可单测、不碰 UserDefaults）；这里**只存用户改过的那几项**，
/// 没改过的项回落出厂值 —— 与 `ASRSettings`（`Services/ASR/ASRSettings.swift`）同一形状，
/// 避免"默认值在两层各写一遍、日后不同源"。
@MainActor
enum SegmentationPlanSettings {

    static let wholeVideoMaxSecondsKey = "segmentationPlan.wholeVideoMaxSeconds"
    static let wholeVideoMaxSentencesKey = "segmentationPlan.wholeVideoMaxSentences"
    static let minAverageSegmentSecondsKey = "segmentationPlan.minAverageSegmentSeconds"

    /// 取值边界。上限故意收紧：整片保留超过 30s 就等于"整片不切"，会把混剪的原料一次性清空。
    static let secondsRange: ClosedRange<Double> = 0...30
    static let sentencesRange: ClosedRange<Int> = 0...20
    static let averageRange: ClosedRange<Double> = 0...10

    /// 当前生效的配置（用户覆盖 ∘ 出厂默认）。
    static var current: SegmentationPlanConfig {
        var cfg = SegmentationPlanConfig()
        if let v = stored(wholeVideoMaxSecondsKey, as: Double.self), secondsRange.contains(v) {
            cfg.wholeVideoMaxSeconds = v
        }
        if let v = stored(wholeVideoMaxSentencesKey, as: Int.self), sentencesRange.contains(v) {
            cfg.wholeVideoMaxSentences = v
        }
        if let v = stored(minAverageSegmentSecondsKey, as: Double.self), averageRange.contains(v) {
            cfg.minAverageSegmentSeconds = v
        }
        return cfg
    }

    /// 写入覆盖值；越界直接夹到边界内，不静默丢弃（丢了用户会以为改了没生效）。
    static func setWholeVideoMaxSeconds(_ value: Double) {
        UserDefaults.standard.set(clamp(value, secondsRange), forKey: wholeVideoMaxSecondsKey)
    }

    static func setWholeVideoMaxSentences(_ value: Int) {
        UserDefaults.standard.set(clampInt(value, sentencesRange), forKey: wholeVideoMaxSentencesKey)
    }

    static func setMinAverageSegmentSeconds(_ value: Double) {
        UserDefaults.standard.set(clamp(value, averageRange), forKey: minAverageSegmentSecondsKey)
    }

    /// 恢复出厂：删键而不是写回默认值，这样 Core 那边改了出厂值也不会被旧覆盖值钉住。
    static func resetToDefaults() {
        let defaults = UserDefaults.standard
        [wholeVideoMaxSecondsKey, wholeVideoMaxSentencesKey, minAverageSegmentSecondsKey].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    private static func stored<T>(_ key: String, as type: T.Type) -> T? {
        UserDefaults.standard.object(forKey: key) as? T
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clampInt(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
