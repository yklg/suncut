import Foundation

/// 叙事结构中的一段：顺序 + 一组标签（SemanticType 的 rawValue 字符串）
public struct NarrativeSlot: Codable, Equatable, Sendable {
    public var order: Int
    public var tags: [String]
    /// 该段候选分镜的最短时长（秒），nil=不限
    public var minDuration: Double?
    /// 该段候选分镜的最长时长（秒），nil=不限
    public var maxDuration: Double?
    public init(order: Int, tags: [String], minDuration: Double? = nil, maxDuration: Double? = nil) {
        self.order = order
        self.tags = tags
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }
}

/// 分镜的轻量描述（供匹配/校验，不依赖 SwiftData）
public struct SegmentDescriptor: Equatable, Sendable {
    public let id: UUID
    public let tags: [String]
    public let text: String
    public let duration: Double
    public let quality: Double
    /// 这条分镜来自**哪条素材**。连贯性只判同素材的相邻对（跨素材必然换画面，没有客观连续性）。
    /// 必填、无默认值：拿不到来源就必须显式给一个"永不与人相同"的键（如 `detached:<id>`），
    /// 否则一个漏传会让整条校验静默变成"全部跨素材 ⇒ 全部通过"。
    public let sourceKey: String
    /// 在原片里的起始秒（不是方案里的位置）。台词先后与画面重叠都靠它判。
    public let startSeconds: Double
    public init(id: UUID, tags: [String], text: String, duration: Double, quality: Double,
                sourceKey: String, startSeconds: Double) {
        self.id = id
        self.tags = tags
        self.text = text
        self.duration = duration
        self.quality = quality
        self.sourceKey = sourceKey
        self.startSeconds = startSeconds
    }
}
