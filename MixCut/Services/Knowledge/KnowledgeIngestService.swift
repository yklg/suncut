import Foundation
import SwiftData

/// 知识库入库服务：原始资料 → 纯文本 → 切块 → KnowledgeDocument + KnowledgeChunks 落库
/// → 尝试向量嵌入（失败不阻塞，检索自动降级 BM25）。
///
/// 纪律：
/// - 提取/切块失败抛错，由 UI 提示，绝不写空文档；
/// - 文档与 chunks 在同一次 ModelContext save 落库；
/// - embedding 是「尽力而为」：未配置 Key、网络失败、维度不符只记日志，
///   chunk 行仍保留（embeddingData = nil），不回滚文档。
enum KnowledgeIngestService {

    /// 入库结果摘要（供 UI toast）。
    struct Outcome {
        let documentID: UUID
        let title: String
        let chunkCount: Int
        let embeddedChunkCount: Int
        let embeddingSkipped: Bool
    }

    // MARK: - Entry Points

    /// 从文件入库（txt/md/pdf/docx）。
    static func ingest(
        fileURL: URL,
        product: Product?,
        source: KnowledgeSource,
        defaultTitle: String? = nil,
        context: ModelContext,
        embeddingModelName: String = Self.defaultEmbeddingModel
    ) async throws -> Outcome {
        let text = try DocumentTextExtractor.plainText(from: fileURL)
        let title = defaultTitle ?? fileURL.deletingPathExtension().lastPathComponent
        return try await ingest(
            title: title, text: text, product: product,
            source: source, sourceURL: nil,
            context: context, embeddingModelName: embeddingModelName)
    }

    /// 从纯文本入库（手动粘贴/调研结果）。
    static func ingest(
        title: String,
        text: String,
        product: Product?,
        source: KnowledgeSource,
        sourceURL: String? = nil,
        context: ModelContext,
        embeddingModelName: String = defaultEmbeddingModel
    ) async throws -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IngestError.emptyText }

        let chunks = TextChunker.chunks(in: trimmed)
        guard !chunks.isEmpty else { throw IngestError.chunkingFailed }

        let document = KnowledgeDocument(
            product: product,
            title: title,
            source: source,
            sourceURL: sourceURL,
            content: trimmed,
            embeddingModelName: embeddingModelName)

        for chunk in chunks {
            let estimate = ChineseTextTokenizer.tokenStrings(in: chunk.text).count
            let row = KnowledgeChunk(
                document: document,
                chunkIndex: chunk.index,
                content: chunk.text,
                tokenEstimate: estimate)
            document.chunks.append(row)
            context.insert(row)
        }
        document.chunkCount = chunks.count
        context.insert(document)

        do {
            try context.save()
        } catch {
            throw IngestError.saveFailed
        }

        // 尽力嵌入；失败不影响已落库文档。
        let embedded = try? await embedChunks(of: document, context: context)
        return Outcome(
            documentID: document.id,
            title: title,
            chunkCount: chunks.count,
            embeddedChunkCount: embedded ?? 0,
            embeddingSkipped: (embedded ?? 0) == 0)
    }

    // MARK: - Embedding

    static let defaultEmbeddingModel = "text-embedding-v3"
    /// DashScope 每批最大行数（官方规格）。
    private static let embeddingBatchSize = 10

    /// 为文档的 chunks 批量生成向量并写回。
    /// - Returns: 成功嵌入的 chunk 数；任何失败返回 0（调用方按「未嵌入」处理）。
    static func embedChunks(of document: KnowledgeDocument, context: ModelContext) async throws -> Int {
        guard let apiKey = KeychainHelper.dashScopeKey, !apiKey.isEmpty else { return 0 }
        let pending = document.chunks
            .filter { $0.embeddingData == nil }
            .sorted { $0.chunkIndex < $1.chunkIndex }
        guard !pending.isEmpty else { return document.chunks.count }

        let client = DashScopeEmbeddingClient(apiKey: apiKey, modelName: document.embeddingModelName)
        var embeddedCount = 0

        for batchStart in stride(from: 0, to: pending.count, by: embeddingBatchSize) {
            let batch = Array(pending[batchStart..<min(batchStart + embeddingBatchSize, pending.count)])
            do {
                let vectors = try await client.embed(texts: batch.map(\.content))
                guard vectors.count == batch.count else { continue }
                for (chunk, vector) in zip(batch, vectors) {
                    chunk.embeddingData = VectorCoding.data(from: vector)
                    chunk.embeddedAt = Date()
                    embeddedCount += 1
                }
                try? context.save()
            } catch {
                // 单批失败：已完成的批次保留，其余按未嵌入处理。
                MixLog.error("知识库向量嵌入批失败：\(error)")
                continue
            }
        }
        return embeddedCount
    }

    // MARK: - Delete

    /// 删除文档（chunks 经 cascade 删除）。
    static func delete(_ document: KnowledgeDocument, context: ModelContext) throws {
        context.delete(document)
        try context.save()
    }
}

enum IngestError: LocalizedError {
    case emptyText
    case chunkingFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:      return "内容为空，无法加入知识库"
        case .chunkingFailed: return "文本切块失败"
        case .saveFailed:     return "知识库保存失败"
        }
    }
}
