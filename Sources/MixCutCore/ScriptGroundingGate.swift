import Foundation

/// 文案事实校验（`GroundingChecker`）的适用门 —— 纯判据，可单测。
///
/// 为什么需要这道门（M4 逆向链路的根因修复）：
/// - GroundingChecker 的承诺是「AI 依据**外部资料**新撰的文案，硬事实必须能在所引片段中落地」；
/// - 逆向方向的文案是**用户本人粘贴的原文**，事实来源是用户自己，不经过 AI 写作、
///   也没有知识库引用可引——对它跑 grounding，任何数字/型号都会被判「无依据事实」，
///   逆向文案将永远无法物化（带货文案几乎必然含「99 元」「ISO9001」这类事实）。
/// - 因此 grounding 只约束正向；逆向仍过合规扫描（极限词/占位与来源无关，一律拦）。
public enum ScriptGroundingGate {

    /// 该创作方向是否要求「文案硬事实必须落地到外部引用资料」。
    /// - 正向（产品资料 → AI 写文案）：true；
    /// - 逆向（粘贴现成文案 → 只结构化）：false。
    public static func requiresExternalEvidence(_ direction: ScriptDirection) -> Bool {
        switch direction {
        case .forward: return true
        case .reverse: return false
        }
    }
}
