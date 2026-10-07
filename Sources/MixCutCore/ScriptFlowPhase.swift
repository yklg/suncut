import Foundation

/// 脚本成片向导的**单一进度状态**（v3.4 · E1）。
///
/// 为什么用枚举而非多个 Bool：匹配/检索/写作是互斥阶段，布尔组合会出现
/// 「匹配中 + 写作中」这类非法状态；关联值 `retrieving(slot:total:)` 直接携带进度。
public enum ScriptFlowPhase: Equatable, Sendable {
    case idle
    case matching
    /// 逐槽检索；slot 从 0 起，total = 槽位数。
    case retrieving(slot: Int, total: Int)
    case writing
    case ready
    case failed(reason: String)

    /// 是否处于不可重复触发的忙碌态。
    public var isBusy: Bool {
        switch self {
        case .idle, .ready, .failed: return false
        case .matching, .retrieving, .writing: return true
        }
    }

    /// 面向用户的阶段说明（进度态视图使用）。
    public var progressLabel: String {
        switch self {
        case .idle:        return "待开始"
        case .matching:    return "正在按标签和时长匹配分镜…"
        case .retrieving(let slot, let total):
            return "正在检索资料（\(slot + 1)/\(total)）…"
        case .writing:     return "正在撰写脚本…"
        case .ready:       return "脚本已生成，请确认"
        case .failed(let reason): return "生成失败：\(reason)"
        }
    }
}

/// AI 调研（知识库页）的进度枚举。
public enum ResearchPhase: Equatable, Sendable {
    case idle
    case searching
    case synthesizing
    case ready
    case failed(reason: String)

    public var isBusy: Bool {
        switch self {
        case .idle, .ready, .failed: return false
        case .searching, .synthesizing: return true
        }
    }
}
