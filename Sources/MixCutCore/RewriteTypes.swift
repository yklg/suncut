import Foundation

/// 送入改写引擎的单个可重配分镜（明星保留原声分镜由调用方提前剔除）。
public struct RewriteSegmentInput: Equatable, Sendable {
    public let segmentId: String
    public let originalText: String
    public let durationSeconds: Double
    public let keywords: [String]

    public init(segmentId: String, originalText: String, durationSeconds: Double, keywords: [String]) {
        self.segmentId = segmentId
        self.originalText = originalText
        self.durationSeconds = durationSeconds
        self.keywords = keywords
    }
}

/// 已经产出的某一版改写台词（多轮改写互斥输入）。
///
/// 外层 `[ [RewritePriorVersion] ]` 表示「轮次 → 该轮各分镜版本」：
/// 新一轮改写时把历史版本注入 prompt，要求模型避开它们的开头/句式，
/// 避免 K 轮互相盲写导致多版雷同。App 层负责从持久化模型映射为本纯值类型，
/// Core 不认识任何数据模型。
public struct RewritePriorVersion: Equatable, Sendable {
    public let segmentId: String
    public let rewrittenText: String

    public init(segmentId: String, rewrittenText: String) {
        self.segmentId = segmentId
        self.rewrittenText = rewrittenText
    }
}

/// 改写引擎产出的单个分镜结果。
public struct RewrittenSegment: Equatable, Sendable {
    public let segmentId: String
    public let rewrittenText: String
    /// AI 未返回该分镜 → 回退原台词，置 true
    public let isFallback: Bool
    /// 字数是否落在预算区间内
    public let withinBudget: Bool

    public init(segmentId: String, rewrittenText: String, isFallback: Bool, withinBudget: Bool) {
        self.segmentId = segmentId
        self.rewrittenText = rewrittenText
        self.isFallback = isFallback
        self.withinBudget = withinBudget
    }
}

/// AI 返回的原始 JSON 结构（generateJSON 的 responseType）。
public struct RewriteResultDTO: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let segmentId: String
        public let rewrittenText: String

        public init(segmentId: String, rewrittenText: String) {
            self.segmentId = segmentId
            self.rewrittenText = rewrittenText
        }
    }
    public let segments: [Item]

    public init(segments: [Item]) {
        self.segments = segments
    }
}
