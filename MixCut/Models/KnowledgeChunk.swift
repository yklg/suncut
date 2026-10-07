import Foundation
import SwiftData

/// 知识库片段：文档切块后的最小检索单元。
///
/// - `embeddingData`：[Float]（text-embedding-v3 = 1024 维）的字节编码；
///   保持**可选**——嵌入失败/尚未嵌入时行仍可保留，向量路缺失时检索自动降级 BM25；
/// - 删除文档时 chunks 随 cascade 删除。
@Model
final class KnowledgeChunk: Identifiable {
    @Attribute(.unique) var id: UUID
    var document: KnowledgeDocument?
    var chunkIndex: Int
    var content: String
    var tokenEstimate: Int
    var embeddingData: Data?
    var embeddedAt: Date?

    init(id: UUID = UUID(),
         document: KnowledgeDocument?,
         chunkIndex: Int,
         content: String,
         tokenEstimate: Int) {
        self.id = id
        self.document = document
        self.chunkIndex = chunkIndex
        self.content = content
        self.tokenEstimate = tokenEstimate
    }
}
