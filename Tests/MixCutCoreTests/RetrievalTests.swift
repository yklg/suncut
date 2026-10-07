import Testing
import Foundation
@testable import MixCutCore

// MARK: - BM25

private func uuid(_ s: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(s)")!
}

@Test func bm25_matchingDocumentRanksAboveNonMatching() {
    let index = BM25Index.build(from: [
        (uuid("01"), "除螨仪 高频 拍打 吸力"),
        (uuid("02"), " unrelated 内容 完全不同"),
    ])
    let hits = index.search("除螨仪 吸力")
    #expect(hits.first?.id == uuid("01"))
    #expect(hits.count == 1)
}

@Test func bm25_moreFrequentTermInDocScoresHigher() {
    // 文档A "螨虫" 出现两次，文档B 一次；查 "螨虫" A 应排前
    let index = BM25Index.build(from: [
        (uuid("01"), "螨虫 很多 螨虫 反复"),
        (uuid("02"), "螨虫 少量"),
    ])
    let hits = index.search("螨虫")
    #expect(hits.first?.id == uuid("01"))
}

@Test func bm25_emptyQueryOrEmptyIndexReturnsNoHits() {
    let index = BM25Index.build(from: [(uuid("01"), "任意文本")])
    #expect(index.search("").isEmpty)
    let empty = BM25Index(documents: [])
    #expect(empty.search("任意").isEmpty)
}

@Test func bm25_idfIsNonNegative() {
    // 所有文档都含同一词时，IDF 仍应 ≥ 0（非负形式）
    let index = BM25Index.build(from: [
        (uuid("01"), "共同词 甲"),
        (uuid("02"), "共同词 乙"),
        (uuid("03"), "共同词 丙"),
    ])
    let hits = index.search("共同词")
    #expect(hits.allSatisfy { $0.score >= 0 })
    #expect(hits.count == 3)
}

@Test func bm25_topKLimitRespected() {
    let index = BM25Index.build(from: [
        (uuid("01"), "螨虫"), (uuid("02"), "螨虫"),
        (uuid("03"), "螨虫"), (uuid("04"), "螨虫"),
    ])
    #expect(index.search("螨虫", topK: 2).count == 2)
}

// MARK: - Vector

@Test func vector_identicalDirectionScoresOne() {
    let index = VectorIndex(entries: [
        .init(id: uuid("01"), vector: [1, 0]),
        .init(id: uuid("02"), vector: [0, 1]),
    ])
    let hits = index.search(query: [1, 0])
    #expect(hits.first?.id == uuid("01"))
    #expect(abs(hits.first!.score - 1.0) < 1e-6)
}

@Test func vector_orthogonalVectorScoresZero() {
    let index = VectorIndex(entries: [.init(id: uuid("01"), vector: [0, 1])])
    let hits = index.search(query: [1, 0])
    #expect(abs(hits.first!.score) < 1e-6)
}

@Test func vector_zeroQueryAndZeroDocAreGuarded() {
    let index = VectorIndex(entries: [
        .init(id: uuid("01"), vector: [0, 0]),
        .init(id: uuid("02"), vector: [1, 1]),
    ])
    // 零查询 ⇒ 无结果
    #expect(index.search(query: [0, 0]).isEmpty)
}

@Test func vector_dimensionMismatchIsSkipped() {
    let index = VectorIndex(entries: [.init(id: uuid("01"), vector: [1, 0, 0])])
    #expect(index.search(query: [1, 0]).isEmpty)
}

@Test func vector_cosineHelper() {
    #expect(abs(VectorIndex.cosine([1, 0], [1, 0])! - 1) < 1e-6)
    #expect(VectorIndex.cosine([1], [1, 2]) == nil)
    #expect(VectorIndex.cosine([0], [1]) == nil)
}

// MARK: - Hybrid RRF

@Test func rrf_documentInBothRoadsOutranksSingleRoad() {
    let a = uuid("01"), b = uuid("02"), c = uuid("03")
    let fused = HybridRetrievalEngine.fuse(
        keyword: [a, b],
        vector: [a, c])
    // a 在两路都排第一 ⇒ RRF 分最高
    #expect(fused.first?.id == a)
    #expect(fused.map(\.id) == [a, c, b] || fused.map(\.id) == [a, b, c])
}

@Test func rrf_singleRoadDegradesGracefully() {
    let a = uuid("01"), b = uuid("02")
    let fused = HybridRetrievalEngine.fuse(keyword: [a, b], vector: [])
    #expect(fused.map(\.id) == [a, b])
}

@Test func rrf_rankFormulaUsesOneBasedRank() {
    let a = uuid("01")
    let fused = HybridRetrievalEngine.fuse(keyword: [a], vector: [], rrfK: 60)
    // 单路首位 ⇒ 1/(60+1)
    #expect(abs(fused.first!.score - 1.0/61.0) < 1e-9)
}

@Test func rrf_topKLimit() {
    let ids = (1...5).map { uuid(String(format: "%02d", $0)) }
    let fused = HybridRetrievalEngine.fuse(keyword: ids, vector: ids, topK: 3)
    #expect(fused.count == 3)
}

// MARK: - Slot Intent

@Test func intent_knownTagUsesTemplate() {
    let q = SlotRetrievalIntent.makeQuery(tag: "痛点", productName: "除螨仪")
    #expect(q.contains("除螨仪"))
    #expect(q.contains("痛点"))
}

@Test func intent_unknownTagFallsBackToProductName() {
    #expect(SlotRetrievalIntent.makeQuery(tag: "不存在", productName: "产品X") == "产品X")
    #expect(SlotRetrievalIntent.makeQuery(tag: "不存在", productName: "").isEmpty)
}

@Test func intent_batchPreservesOrder() {
    let intents = SlotRetrievalIntent.makeIntents(tags: ["痛点", "行动号召"], productName: "P")
    #expect(intents.map(\.tag) == ["痛点", "行动号召"])
    #expect(intents.allSatisfy { $0.query.contains("P") })
}
