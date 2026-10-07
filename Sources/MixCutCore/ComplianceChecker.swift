import Foundation

/// 文案合规扫描器（纯逻辑，可单测）。
///
/// 两族判据：
/// - **极限词**（《广告法》第九条/第十七条禁用的绝对化用语）：命中即阻断 materialize，
///   必须改文案；词表为常见高风险集合，不声称穷尽全部法条；
/// - **草稿占位**：TODO / TBD / XXX / 待补充 / Lorem ipsum 等未成品标记，
///   命中说明文案不是成品，同样阻断。
public enum ComplianceChecker {

    public enum Issue: Equatable, Sendable {
        case forbiddenWord(String)
        case placeholder(String)
    }

    /// 极限词表（2026-10 常见执法高频集合，按字符串包含匹配）。
    public static let forbiddenWords: [String] = [
        "国家级", "最高级", "最佳", "最好", "最优", "最大", "最低", "最先进",
        "第一", "唯一", "顶级", "顶尖", "极品", "绝佳", "万能", "百分百",
        "百分之百", "世界级", "王牌", "销量冠军", "绝无仅有", "史无前例",
        "永久", "彻底根治", "包治百病",
    ]

    /// 草稿占位词（小写匹配；中文直接包含）。
    public static let placeholders: [String] = [
        "todo", "tbd", "xxx", "待补充", "待完善", "占位", "lorem ipsum", "此处省略",
    ]

    /// 扫描文本，返回命中问题（极限词在前，按词表顺序；占位随后）。
    public static func scan(_ text: String) -> [Issue] {
        var issues: [Issue] = []
        for word in forbiddenWords where text.contains(word) {
            issues.append(.forbiddenWord(word))
        }
        let lowered = text.lowercased()
        for word in placeholders where lowered.contains(word) {
            issues.append(.placeholder(word))
        }
        return issues
    }

    /// 便捷读侧：仅返回问题的可读说明。
    public static func describe(_ issue: Issue) -> String {
        switch issue {
        case .forbiddenWord(let w): return "极限词「\(w)」违反广告法，需替换"
        case .placeholder(let w):  return "草稿占位「\(w)」，文案尚未完成"
        }
    }
}
