import Foundation

/// URL 正文抓取器 —— 用户粘贴单个产品/电商链接时的最佳努力提取。
///
/// 约束（v3.1 调研结论）：
/// - 淘宝/京东等主流电商未登录页为 JS 渲染 + 签名接口 + 滑块风控，硬爬不可行；
/// - 因此只做单次、低频 GET，能拿到 HTML 就用 `HTMLTextStripper` 转纯文本；
/// - 命中验证码 / 正文过短 / 请求失败 ⇒ 抛出 `fetchBlocked`，由 UI 引导用户改为手动粘贴，
///   绝不尝试绕过验证码或高频重试。
/// - 合规：仅处理用户本人主动粘贴的单个链接。
struct URLTextFetcher {

    enum FetchError: LocalizedError {
        case invalidURL
        case httpFailed(status: Int)
        case fetchBlocked

        var errorDescription: String? {
            switch self {
            case .invalidURL:          return "链接格式无效"
            case .httpFailed(let s):   return "链接无法访问（HTTP \(s)）"
            case .fetchBlocked:        return "该页面需要登录或验证，无法自动读取，请手动复制页面内容后使用「粘贴文本」"
            }
        }
    }

    /// 抓取并返回正文纯文本。
    /// - Parameter minimumLength：判定有效正文的最小字符数（过短视为被风控拦截）
    func fetchText(from urlString: String, minimumLength: Int = 120) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            throw FetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.fetchBlocked }
        guard (200...299).contains(http.statusCode) else {
            throw FetchError.httpFailed(status: http.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        let text = HTMLTextStripper.plainText(from: html)
        guard text.count >= minimumLength else { throw FetchError.fetchBlocked }
        return text
    }
}
