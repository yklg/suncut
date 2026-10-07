import Foundation

/// 脚本生命周期状态机 —— ScriptDocument 的唯一状态判据。
public enum ScriptLifecycle: Sendable {

    /// draft（结构定稿、匹配进行）→ matched（全部槽位锁定，检索/写作进行）→ materialized（终态冻结）。
    public enum State: String, CaseIterable, Sendable {
        case draft
        case matched
        case materialized
    }

    /// 合法迁移表：
    /// - draft → matched（全部槽位匹配锁定）
    /// - matched → materialized（用户确认；须同时绑定 realizedScheme）
    /// - materialized 为终态，不存在任何出边。
    public static func canMove(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.draft, .matched): return true
        case (.matched, .materialized): return true
        default: return false
        }
    }
}

/// 脚本创作方向。
public enum ScriptDirection: String, CaseIterable, Sendable {
    /// 正向：产品资料 → 新脚本
    case forward
    /// 逆向：现成文案 → 结构化
    case reverse
}

/// 脚本结构来源。
public enum StructureMode: String, CaseIterable, Sendable {
    /// 模板预设（生成前可编辑槽位）
    case template
    /// AI 自动确定结构
    case aiAuto
}

/// 场景匹配状态。
public enum SceneMatchStatus: String, CaseIterable, Sendable {
    /// 已唯一锁定匹配分镜
    case matched
    /// 有多个候选待用户选择
    case multiCandidate
    /// 无匹配（可改标签/手工选片）
    case unmatched
}
