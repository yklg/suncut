import Foundation
import SwiftData

/// 知识库检索产物（一条命中片段的快照投影）。
struct RetrievedMaterial: Equatable {
    let chunkID: UUID
    let documentTitle: String
    let sourceURL: String?
    let content: String
    let score: Double
}

/// 候选资料投影（产品下启用文档的全部 chunk；写作前一次 fetch 得到）。
///
/// 不变量（槽位隔离契约）：同一产品的候选池在全部槽位间**完全相同**——槽位差异只
/// 体现在查询串与 BM25/向量的**排序结果**，不在候选集合。若未来需要按槽位收窄可见
/// 范围，必须在 `retrieve` 的排序结果上做，禁止在候选池层过滤，否则会造成静默的跨槽
/// 资料泄露或缺失。
struct CandidateMaterial: Equatable {
    let chunkID: UUID
    let documentTitle: String
    let sourceURL: String?
    let content: String
    let embeddingData: Data?
}

/// 知识库逐槽检索服务 —— 脚本写作的事实来源唯一入口。
///
/// 管线：candidateMaterials（一次全量 fetch + 标识符优先的解边过滤）→ BM25 关键词路
/// （全量可建）+ 向量语义路（查询嵌入尽力而为：未配 Key/网络失败/维度不符只记日志，
/// 自动退化为关键词单路）→ RRF 融合。
///
/// 纪律：
/// - 跨边关系（document/product）只在 candidateMaterials 读取，View 不直接碰；
/// - 检索扇出：每槽恰好 1 次排序（查询嵌入至多 1 次网络），无 rerank 额外调用；
/// - 全部 6 槽共享同一候选池：全流程仅 3 次 fetch（文档/产品/chunk 各一）。
@MainActor
enum KnowledgeRetrievalService {

    /// 产品下启用文档的全部 chunk（一次 fetch + 解边过滤；6 槽共享）。
    static func candidateMaterials(product: Product, context: ModelContext) -> [CandidateMaterial] {
        // 标识符优先的分段投影（无跨多层 to-one 链的 #Predicate）：
        // CoreData SQL 生成器翻译不了 `chunk.document?.product?.id == … && document?.isEnabled`
        // 这类两层链谓词——会在 SQL 生成阶段抛 ObjC 异常且 Swift 无法捕获（进程 abort）。
        let documents = (try? context.fetch(FetchDescriptor<KnowledgeDocument>())) ?? []
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []

        // 文档→产品的解边索引（只读 persistentModelID，不 fault backing）。
        var productIndex = LiveModelIDIndex()
        productIndex.insert(products, id: \.id)

        // ① 文档侧过滤（纯函数 KnowledgeDocumentFilter）：本产品（经索引解边）且启用。
        let inputs = documents.map {
            KnowledgeDocumentFilter.Input(
                id: $0.id,
                isEnabled: $0.isEnabled,
                productID: productIndex.uuid(for: $0.product))
        }
        let enabledIDs = KnowledgeDocumentFilter.enabledIDs(
            inputs, targetProductID: product.id)

        // ② chunk 侧过滤：document 边可解析且命中文档集。
        let chunks = (try? context.fetch(FetchDescriptor<KnowledgeChunk>())) ?? []
        var documentIndex = LiveModelIDIndex()
        documentIndex.insert(documents, id: \.id)
        let documentByID = Dictionary(documents.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

        return chunks.compactMap { chunk in
            guard let documentID = documentIndex.uuid(for: chunk.document),
                  enabledIDs.contains(documentID),
                  let document = documentByID[documentID] else { return nil }
            return CandidateMaterial(
                chunkID: chunk.id,
                documentTitle: document.title,
                sourceURL: document.sourceURL,
                content: chunk.content,
                embeddingData: chunk.embeddingData)
        }
    }

    /// 为一个槽的查询串在给定候选池上排序检索。
    /// - Parameters:
    ///   - query: 经 SlotRetrievalIntent 生成的查询
    ///   - candidates: 本产品的共享候选池（candidateMaterials 一次取得）
    ///   - topK: 返回片段上限
    static func retrieve(
        query: String,
        candidates: [CandidateMaterial],
        topK: Int = 6
    ) async -> [RetrievedMaterial] {
        guard !candidates.isEmpty else { return [] }

        // 关键词路：候选上全量 BM25。
        let bm25 = BM25Index.build(from: candidates.map { (id: $0.chunkID, text: $0.content) })
        let keywordHits = bm25.search(query, topK: topK)

        // 向量路：查询嵌入尽力而为；候选无向量/失败 ⇒ 空路（RRF 自动单路）。
        var vectorHits: [VectorIndex.Hit] = []
        let vectorEntries = candidates.compactMap { candidate -> VectorIndex.Entry? in
            guard let data = candidate.embeddingData,
                  let vector = VectorCoding.vector(from: data) else { return nil }
            return VectorIndex.Entry(id: candidate.chunkID, vector: vector)
        }
        if !vectorEntries.isEmpty, let queryVector = await embedQuery(query) {
            vectorHits = VectorIndex(entries: vectorEntries).search(query: queryVector, topK: topK)
        }

        let fused = HybridRetrievalEngine.fuse(
            keyword: keywordHits.map { (id: $0.id, score: $0.score) },
            vector: vectorHits.map { (id: $0.id, score: $0.score) },
            topK: topK)

        let candidateByID = Dictionary(candidates.map { ($0.chunkID, $0) },
                                       uniquingKeysWith: { first, _ in first })
        return fused.compactMap { ranked in
            guard let candidate = candidateByID[ranked.id] else { return nil }
            return RetrievedMaterial(
                chunkID: candidate.chunkID,
                documentTitle: candidate.documentTitle,
                sourceURL: candidate.sourceURL,
                content: candidate.content,
                score: ranked.score)
        }
    }

    // MARK: - Query Embedding

    /// 查询串单条嵌入。任何失败返回 nil（不阻塞、不重试轰炸）。
    private static func embedQuery(_ query: String) async -> [Float]? {
        guard let key = KeychainHelper.dashScopeKey, !key.isEmpty else { return nil }
        let client = DashScopeEmbeddingClient(apiKey: key)
        do {
            return try await client.embed(texts: [query]).first
        } catch {
            MixLog.info("查询向量嵌入失败，向量路降级：\(error.localizedDescription)")
            return nil
        }
    }
}
