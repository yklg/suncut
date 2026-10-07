import Foundation

/// 向量索引 —— 语义路检索的纯内存实现（线性扫描）。
///
/// 规模依据（v3.1 调研）：单产品知识库约数百 chunk、1024 维，线性扫描毫秒级，
/// 不引入 ANN 索引。空向量与零向量显式防护。
public struct VectorIndex {

    /// 一条带向量的文档。
    public struct Entry: Equatable {
        public let id: UUID
        public let vector: [Float]
    }

    public struct Hit: Equatable {
        public let id: UUID
        public let score: Double
    }

    private let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// 用 query 向量检索，返回 cosine 相似度降序命中。
    public func search(query: [Float], topK: Int = 10) -> [Hit] {
        guard !query.isEmpty else { return [] }
        let queryNorm = Self.norm(query)
        guard queryNorm > 0 else { return [] }

        var hits: [Hit] = []
        for entry in entries {
            guard entry.vector.count == query.count else { continue }
            let docNorm = Self.norm(entry.vector)
            guard docNorm > 0 else { continue }

            let dot = zip(query, entry.vector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let cosine = dot / (queryNorm * docNorm)
            hits.append(Hit(id: entry.id, score: cosine))
        }

        return Array(hits.sorted { $0.score > $1.score }.prefix(max(0, topK)))
    }

    // MARK: - Helpers

    /// L2 范数。
    static func norm(_ vector: [Float]) -> Double {
        let sumSquares = vector.reduce(0.0) { $0 + Double($1 * $1) }
        return sqrt(sumSquares)
    }

    /// cosine 相似度（供需要直接打分的调用方）。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let na = norm(a), nb = norm(b)
        guard na > 0, nb > 0 else { return nil }
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return dot / (na * nb)
    }
}
