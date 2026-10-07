import Foundation

/// 阿里云百炼 Embedding 客户端（默认 text-embedding-v3）。
///
/// 规格（官方文档，2026-10）：
/// - Endpoint：`POST https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings`；
/// - 1024 维（默认 dimensions）；**10 行/批，单行 ≤ 8,192 token**；
/// - 响应为标准 OpenAI Embedding 格式。
struct DashScopeEmbeddingClient: EmbeddingClient {

    let apiKey: String
    let modelName: String
    /// 允许设置中改用其他 DashScope embedding 模型（如 text-embedding-v4）。
    init(apiKey: String, modelName: String = "text-embedding-v3") {
        self.apiKey = apiKey
        self.modelName = modelName
    }

    private let endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings"

    func embed(texts: [String]) async throws -> [[Float]] {
        guard !apiKey.isEmpty else { throw EmbeddingClientError.missingAPIKey }
        guard !texts.isEmpty else { throw EmbeddingClientError.emptyInput }

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "input": texts
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw EmbeddingClientError.httpFailed(status: http.statusCode)
        }
        return try EmbeddingResponseParser.parse(data, expectedCount: texts.count)
    }
}

/// OpenAI 兼容（自带/转发网关）embedding 客户端。
///
/// 请求/响应与 OpenAI `/v1/embeddings` 同构；模型名、baseURL 由用户设置提供。
struct OpenAICompatibleEmbeddingClient: EmbeddingClient {

    let apiKey: String
    let modelName: String
    let baseURL: String

    init(apiKey: String, modelName: String, baseURL: String) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.baseURL = baseURL
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        guard !apiKey.isEmpty else { throw EmbeddingClientError.missingAPIKey }
        guard !texts.isEmpty else { throw EmbeddingClientError.emptyInput }

        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBase)/embeddings") else {
            throw EmbeddingClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "input": texts
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw EmbeddingClientError.httpFailed(status: http.statusCode)
        }
        return try EmbeddingResponseParser.parse(data, expectedCount: texts.count)
    }
}

/// 解析标准 OpenAI Embedding 响应：`{"data":[{"embedding":[…]}]}`。
/// 抽成纯函数便于单测；条数不符直接报错（对齐项目「不静默」纪律）。
enum EmbeddingResponseParser {

    static func parse(_ data: Data, expectedCount: Int) throws -> [[Float]] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EmbeddingClientError.invalidResponse
        }
        guard let root = json as? [String: Any],
              let items = root["data"] as? [[String: Any]] else {
            throw EmbeddingClientError.invalidResponse
        }
        guard items.count == expectedCount else {
            throw EmbeddingClientError.countMismatch(expected: expectedCount, actual: items.count)
        }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(items.count)
        for item in items {
            guard let embedding = item["embedding"] as? [Double] else {
                throw EmbeddingClientError.invalidResponse
            }
            vectors.append(embedding.map(Float.init))
        }
        return vectors
    }
}
