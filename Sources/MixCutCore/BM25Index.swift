import Foundation

/// BM25 检索索引 —— 关键词路检索的纯内存实现。
///
/// 算法（Okapi BM25）：
/// - 每条文档预分词（`ChineseTextTokenizer`）并记录词频、长度；
/// - IDF 采用 `ln(1 + (N - df + 0.5) / (df + 0.5))`，恒为非负；
/// - 词频饱和项 `tf * (k1 + 1) / (tf + k1 * (1 - b + b * |d|/avgdl))`；
/// - 查询词逐项累加得分，按分降序返回。
public final class BM25Index {

    /// 索引中的一条文档。
    public struct Document: Equatable, Sendable {
        public let id: UUID
        public let termFrequency: [String: Int]
        public let length: Int
    }

    /// 检索命中。
    public struct Hit: Equatable, Sendable {
        public let id: UUID
        public let score: Double
    }

    private let documents: [Document]
    private let k1: Double
    private let b: Double
    private let averageLength: Double
    /// 词 → 出现该词的文档数。
    private let documentFrequency: [String: Int]

    // MARK: - Init

    public init(documents: [Document], k1: Double = 1.5, b: Double = 0.75) {
        self.documents = documents
        self.k1 = k1
        self.b = b
        let totalLength = documents.reduce(0) { $0 + $1.length }
        self.averageLength = documents.isEmpty ? 0 : Double(totalLength) / Double(documents.count)

        var df: [String: Int] = [:]
        for doc in documents {
            for term in doc.termFrequency.keys {
                df[term, default: 0] += 1
            }
        }
        self.documentFrequency = df
    }

    /// 便捷构造：直接用（id, 原文）建索引。
    public static func build(from sources: [(id: UUID, text: String)],
                             k1: Double = 1.5, b: Double = 0.75) -> BM25Index {
        let docs: [Document] = sources.map { source in
            let tokens = ChineseTextTokenizer.tokenStrings(in: source.text)
            var tf: [String: Int] = [:]
            for token in tokens { tf[token, default: 0] += 1 }
            return Document(id: source.id, termFrequency: tf, length: tokens.count)
        }
        return BM25Index(documents: docs, k1: k1, b: b)
    }

    // MARK: - Search

    /// 用自然语言查询检索，返回按 BM25 分降序的命中（0 分文档不返回）。
    public func search(_ query: String, topK: Int = 10) -> [Hit] {
        let queryTerms = ChineseTextTokenizer.tokenStrings(in: query)
        return search(terms: queryTerms, topK: topK)
    }

    /// 用已切分的查询词检索。
    public func search(terms: [String], topK: Int = 10) -> [Hit] {
        guard !documents.isEmpty, averageLength > 0, !terms.isEmpty else { return [] }

        // 查询词去重（同词重复不累计）。
        let uniqueTerms = Set(terms)
        var hits: [Hit] = []

        for doc in documents {
            var score = 0.0
            for term in uniqueTerms {
                guard let tf = doc.termFrequency[term], tf > 0 else { continue }
                guard let df = documentFrequency[term] else { continue }

                let idf = idf(documentFrequency: df)
                let saturation = Double(tf) * (k1 + 1) / (
                    Double(tf) + k1 * (1 - b + b * Double(doc.length) / averageLength))
                score += idf * saturation
            }
            if score > 0 {
                hits.append(Hit(id: doc.id, score: score))
            }
        }

        return Array(hits.sorted { $0.score > $1.score }.prefix(max(0, topK)))
    }

    /// BM25 IDF（非负形式）。
    private func idf(documentFrequency df: Int) -> Double {
        let n = Double(documents.count)
        return log(1 + (n - Double(df) + 0.5) / (Double(df) + 0.5))
    }
}
