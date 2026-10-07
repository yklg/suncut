import Foundation
import SwiftData

/// 知识库文档（产品脚本成片的事实来源）。
///
/// 生命周期：
/// - 按 **Product 隔离**（用户在某产品的知识库中上传/调研/解析链接）；
/// - 来源见 `KnowledgeSource`：本地上传 / AI 联网调研 / 电商链接 / 手动粘贴；
/// - 删除文档级联删除其 chunks；文档与产品之间是 optional to-one（非 cascade），产品被删不带走文档。
@Model
final class KnowledgeDocument: Identifiable {
    @Attribute(.unique) var id: UUID
    var product: Product?
    var title: String
    /// KnowledgeSource.rawValue
    var sourceRaw: String
    /// 电商链接/信源 URL（快照，作为引用溯源）
    var sourceURL: String?
    /// 纯文本全文
    var content: String
    var wordCount: Int
    /// 是否参与检索（关闭后保留文档但不进索引）
    var isEnabled: Bool
    var chunkCount: Int
    /// 产生向量的 embedding 模型名（换模型后据此重索引）
    var embeddingModelName: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \KnowledgeChunk.document)
    var chunks: [KnowledgeChunk] = []

    var source: KnowledgeSource {
        get { KnowledgeSource(rawValue: sourceRaw) ?? .manualPaste }
        set { sourceRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         product: Product?,
         title: String,
         source: KnowledgeSource,
         sourceURL: String? = nil,
         content: String,
         embeddingModelName: String,
         isEnabled: Bool = true) {
        self.id = id
        self.product = product
        self.title = title
        self.sourceRaw = source.rawValue
        self.sourceURL = sourceURL
        self.content = content
        self.wordCount = content.count
        self.isEnabled = isEnabled
        self.chunkCount = 0
        self.embeddingModelName = embeddingModelName
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
