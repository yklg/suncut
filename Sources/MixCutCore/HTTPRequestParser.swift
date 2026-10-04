import Foundation

/// 解析出的一个完整 HTTP 请求
public struct ParsedHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    /// 全部请求头：**键统一小写并去首尾空白**（HTTP 头名大小写不敏感），值已去首尾空白。
    /// 同名多个时按 RFC 7230 §3.2.2 的字段组合语义用 ", " 拼接，同名同值只留一条。
    /// 鉴权与跨域要读的 `authorization` / `cookie` / `origin` / `access-control-*` 全从这里取。
    public let headers: [String: String]
    public let body: Data
    /// 本请求在缓冲区中占用的字节数（keep-alive 时调用方据此裁掉已消费部分）
    public let consumedBytes: Int
}

/// 极简 HTTP/1.1 请求解析（短头部 + Content-Length 定长 body）。
/// 明确不支持的：`Transfer-Encoding: chunked`（分片上传走的是自定分片协议，不是 HTTP chunked）、
/// obs-fold 折行头（没有冒号的续行会被整条跳过，不凭空造头）。
public enum HTTPRequestParser {
    /// 缓冲区中还没有完整请求时返回 nil，调用方应继续收包后重试
    public static func parse(buffer: Data) -> ParsedHTTPRequest? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let terminatorRange = buffer.range(of: headerTerminator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<terminatorRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        // 先把每一条头都收下（旧实现只抠 Content-Length，其余全丢，浏览器要的
        // Origin / Cookie / Authorization 因此根本到不了 handler）
        var collected: [String: [String]] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            var values = collected[name] ?? []
            if !values.contains(value) { values.append(value) }
            collected[name] = values
        }
        let headers = collected.mapValues { $0.joined(separator: ", ") }

        // 长度缺失按 0（GET 探活）；**present-but-坏** 一律返回 nil，不 `?? 0`：
        // 把畸形长度读成 0 会吐出一个"空 body 的正常请求"，真正的 body 留在缓冲区里
        // 被当成下一个请求的头部 —— keep-alive 上就是串流。
        var contentLength = 0
        if let lengths = collected["content-length"] {
            // lengths 已去重：多于 1 条即冲突，HTTP 语义下不许猜哪一个
            guard lengths.count == 1, let parsed = Int(lengths[0]), parsed >= 0 else { return nil }
            contentLength = parsed
        }

        let bodyStart = terminatorRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyEnd)
        return ParsedHTTPRequest(method: method, path: path, headers: headers, body: body,
                                 consumedBytes: consumed)
    }
}
