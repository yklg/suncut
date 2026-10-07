import Foundation

/// 槽位检索意图 —— 把脚本场景的标签转换为该槽的检索查询串。
///
/// 设计：检索质量取决于查询是否命中资料里的措辞。按标签给出查询模板，
/// 并在查询中带上产品名（产品资料中高频出现），提高召回相关性。
public enum SlotRetrievalIntent {

    /// 单个槽的检索意图。
    public struct Intent: Equatable, Sendable {
        public let tag: String
        public let query: String
    }

    /// 标签 → 查询后缀模板（在产品名之后补充该段关心的事实维度）。
    ///
    /// 与 11 类 SemanticType 对应；未列标签走兜底（仅产品名）。
    static let templates: [String: String] = [
        "噱头引入": "痛点 问题 困扰",
        "痛点": "用户痛点 难题 抱怨",
        "产品方案": "功能 原理 参数 怎么解决",
        "效果展示": "效果 实测 变化 使用前后",
        "信任背书": "检测报告 认证 销量 评价 资质",
        "行动号召": "价格 优惠 活动 下单 福利",
        "过渡": "接下来 下面",
    ]

    /// 为一个带标签的槽生成查询。
    /// - Parameters:
    ///   - tag: SemanticType.rawValue
    ///   - productName: 当前产品名（查询前缀）
    public static func makeQuery(tag: String, productName: String) -> String {
        let prefix = productName.isEmpty ? "" : productName
        if let suffix = templates[tag] {
            return prefix.isEmpty ? suffix : "\(prefix) \(suffix)"
        }
        return prefix
    }

    /// 批量为整组槽生成意图（顺序与入参一致）。
    public static func makeIntents(tags: [String], productName: String) -> [Intent] {
        tags.map { Intent(tag: $0, query: makeQuery(tag: $0, productName: productName)) }
    }
}
