import Foundation

/// 混合检索引擎 —— 关键词（BM25）与语义（向量 cosine）两路结果的融合。
///
/// 融合方法：**RRF（Reciprocal Rank Fusion）**
/// `score(d) = Σ 1 / (k + rank_i(d))`，rank 从 1 起；
/// - 不直接加两路原始分（量纲不同），只看各路内排名；
/// - 某一路缺失（未配 Key / 无向量）自动退化为单路，结果仍正确；
/// - 输出按 RRF 分降序，并合并返回最终顺序。
public enum HybridRetrievalEngine {

    public struct RankedResult: Equatable, Sendable {
        public let id: UUID
        public let score: Double
    }

    /// RRF 常数（常用 60）。
    public static let defaultRRFK: Int = 60

    /// 主入口：传入两路按各自分数降序排列的 ID 列表。
    /// - Parameters:
    ///   - keywordRank：BM25 降序 ID（可为空）
    ///   - vectorRank：向量 cosine 降序 ID（可为空）
    ///   - rrfK：RRF 常数
    ///   - topK：返回条数上限
    public static func fuse(
        keyword keywordRank: [UUID],
        vector vectorRank: [UUID],
        rrfK: Int = defaultRRFK,
        topK: Int = 10
    ) -> [RankedResult] {
        var scores: [UUID: Double] = [:]

        func accumulate(_ rankedIDs: [UUID]) {
            for (position, id) in rankedIDs.enumerated() {
                let rank = position + 1
                scores[id, default: 0] += 1.0 / Double(rrfK + rank)
            }
        }

        accumulate(keywordRank)
        accumulate(vectorRank)

        return Array(
            scores.map { RankedResult(id: $0.key, score: $0.value) }
                .sorted { $0.score > $1.score }
                .prefix(max(0, topK))
        )
    }

    /// 便捷封装：直接接两路 `(id, score)` 形式（调用方各自排好序）。
    public static func fuse(
        keyword: [(id: UUID, score: Double)],
        vector: [(id: UUID, score: Double)],
        rrfK: Int = defaultRRFK,
        topK: Int = 10
    ) -> [RankedResult] {
        fuse(
            keyword: keyword.sorted { $0.score > $1.score }.map(\.id),
            vector: vector.sorted { $0.score > $1.score }.map(\.id),
            rrfK: rrfK, topK: topK)
    }
}
