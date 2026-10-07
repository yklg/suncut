import Foundation

/// 博查（Bocha）联网搜索的结果模型与响应解析（纯逻辑，可单测）。
///
/// 响应结构：`{ "webPages": { "value": [ {name,url,snippet,summary,siteName,datePublished} ] } }`
public struct BochaWebResult: Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
    public let summary: String
    public let siteName: String
    public let datePublished: String?

    public init(title: String, url: String, snippet: String, summary: String,
                siteName: String, datePublished: String?) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.summary = summary
        self.siteName = siteName
        self.datePublished = datePublished
    }
}

public enum BochaResponseParsing {

    public enum ParseError: Error {
        case invalidResponse
    }

    /// 解析博查 web-search 响应。
    public static func parse(_ data: Data) throws -> [BochaWebResult] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.invalidResponse
        }
        guard let root = json as? [String: Any],
              let webPages = root["webPages"] as? [String: Any],
              let value = webPages["value"] as? [[String: Any]] else {
            throw ParseError.invalidResponse
        }

        return value.map { item in
            BochaWebResult(
                title: item["name"] as? String ?? "",
                url: item["url"] as? String ?? "",
                snippet: item["snippet"] as? String ?? "",
                summary: item["summary"] as? String ?? "",
                siteName: item["siteName"] as? String ?? "",
                datePublished: item["datePublished"] as? String)
        }
    }
}
