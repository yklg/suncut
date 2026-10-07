import Foundation

/// 文本向量化（embedding）客户端协议 —— 知识库检索的向量路唯一依赖。
///
/// 实现：
/// - `DashScopeEmbeddingClient`：阿里云百炼 text-embedding-v3（默认）；
/// - `OpenAICompatibleEmbeddingClient`：用户自带/转发网关的 OpenAI 兼容 `/v1/embeddings`。
/// 失败（网络/Key/额度）由调用方捕获并降级 BM25 单路，不阻塞资料入库。
protocol EmbeddingClient: Sendable {
    /// 为一批文本生成等长向量。
    /// - Parameter texts: 单次调用文本条数（DashScope v3 上限 10 行，由调用方分片）
    /// - Returns: 与入参等长、维度一致的向量数组
    func embed(texts: [String]) async throws -> [[Float]]

    /// 当前模型名（写入 KnowledgeDocument.embeddingModelName，换模型后据此重索引）。
    var modelName: String { get }
}

enum EmbeddingClientError: LocalizedError {
    case emptyInput
    case invalidResponse
    case countMismatch(expected: Int, actual: Int)
    case httpFailed(status: Int)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .emptyInput:               return "没有待向量化的文本"
        case .invalidResponse:          return "Embedding 响应格式无效"
        case .countMismatch(let e, let a): return "Embedding 条数不符（期望 \(e)，实际 \(a)）"
        case .httpFailed(let s):        return "Embedding 请求失败（HTTP \(s)）"
        case .missingAPIKey:            return "未配置 API Key"
        }
    }
}
