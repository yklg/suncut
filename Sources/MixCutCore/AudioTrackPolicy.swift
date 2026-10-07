import Foundation

/// 成片的声音轨策略 —— MixScheme 导出时选择声音来源的唯一依据。
///
/// - `keepOriginal`：现有行为。逐段「有配音用配音、无配音回退原声」；
/// - `dubOnly`：产品脚本成片。全槽必须使用全新配音；任一缺失即在导出时报错，
///   绝不静默回退原声（脚本的承诺：画面静音 + 全新配音）；
/// - `dubWithSeparatedBGM`：预留档。新配音叠加经 demucs 分离的背景音乐；
///   本期可不实现，枚举先到位（对齐「新增成片模式不改导出代码」的扩展点）。
public enum AudioTrackPolicy: String, CaseIterable, Codable, Sendable {
    case keepOriginal
    case dubOnly
    case dubWithSeparatedBGM

    /// 该策略下，某段缺少已生成配音时是否允许回退到原片声音。
    public var allowsOriginalFallback: Bool {
        switch self {
        case .keepOriginal:
            return true
        case .dubOnly, .dubWithSeparatedBGM:
            return false
        }
    }

    public var displayLabel: String {
        switch self {
        case .keepOriginal:        return "保留原声"
        case .dubOnly:             return "全新配音"
        case .dubWithSeparatedBGM: return "全新配音+分离BGM"
        }
    }
}
