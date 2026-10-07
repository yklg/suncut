import Foundation

/// 博查（Bocha）AI 搜索客户端 —— 知识库联网调研的搜索路。
///
/// 规格（官方文档，2026-10）：
/// - Endpoint：`POST https://api.bochaai.com/v1/web-search`；
/// - Header：`Authorization: Bearer <BOCHA_API_KEY>`；
/// - 语义：`query` 必填；`count` 1–50；`summary=true` 返回正文级摘要（喂 LLM 用）；
/// - 结果解析见 Core `BochaResponseParsing`。
struct BochaSearchClient {

    let apiKey: String
    private let endpoint = "https://api.bochaai.com/v1/web-search"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    enum SearchError: LocalizedError {
        case missingAPIKey
        case httpFailed(status: Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:       return "未配置博查 API Key"
            case .httpFailed(let s):   return "博查搜索请求失败（HTTP \(s)）"
            case .invalidResponse:     return "博查搜索响应格式无效"
            }
        }
    }

    /// 执行一次联网搜索。
    /// - Parameters:
    ///   - query: 查询串
    ///   - count: 结果条数（1–50）
    func search(_ query: String, count: Int = 10) async throws -> [BochaWebResult] {
        guard !apiKey.isEmpty else { throw SearchError.missingAPIKey }

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "count": max(1, min(count, 50)),
            "summary": true
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.httpFailed(status: http.statusCode)
        }
        do {
            return try BochaResponseParsing.parse(data)
        } catch {
            throw SearchError.invalidResponse
        }
    }
}
