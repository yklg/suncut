import Foundation
import Testing
@testable import MixCutCore

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    private func request(_ s: String) -> Data { Data(s.utf8) }

    @Test("完整 POST 带 body")
    func parsePostWithBody() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"jsonrpc\":1}"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/mcp")
        #expect(String(data: parsed.body, encoding: .utf8) == "{\"jsonrpc\":1}")
        #expect(parsed.consumedBytes == raw.utf8.count)
    }

    @Test("头部不完整返回 nil")
    func incompleteHeaders() {
        #expect(HTTPRequestParser.parse(buffer: request("POST /mcp HTTP/1.1\r\nContent-Le")) == nil)
    }

    @Test("body 未收全返回 nil")
    func incompleteBody() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"partial\":"
        #expect(HTTPRequestParser.parse(buffer: request(raw)) == nil)
    }

    @Test("无 Content-Length 视为空 body（GET 探活）")
    func getWithoutContentLength() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.method == "GET")
        #expect(parsed.path == "/health")
        #expect(parsed.body.isEmpty)
    }

    @Test("Content-Length 大小写不敏感")
    func caseInsensitiveHeader() throws {
        let raw = "POST /mcp HTTP/1.1\r\ncontent-length: 2\r\n\r\nhi"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(String(data: parsed.body, encoding: .utf8) == "hi")
    }

    @Test("consumedBytes 支持同一缓冲区多请求（keep-alive）")
    func pipelinedRequests() throws {
        let first = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\nab"
        let second = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\ncd"
        var buffer = request(first + second)
        let parsed1 = try #require(HTTPRequestParser.parse(buffer: buffer))
        #expect(String(data: parsed1.body, encoding: .utf8) == "ab")
        buffer.removeFirst(parsed1.consumedBytes)
        let parsed2 = try #require(HTTPRequestParser.parse(buffer: buffer))
        #expect(String(data: parsed2.body, encoding: .utf8) == "cd")
    }

    @Test("畸形请求行返回 nil")
    func malformedRequestLine() {
        #expect(HTTPRequestParser.parse(buffer: request("GARBAGE\r\n\r\n")) == nil)
    }

    // MARK: - 头部收集（浏览器要用 Origin / Cookie / Authorization，之前只抠 Content-Length 一条）

    @Test("完整收集全部头部，键归一小写、值去首尾空白")
    func collectsAllHeaders() throws {
        let raw = "POST /mcp HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8787\r\n"
            + "Content-Type:   application/json\r\n"
            + "Authorization:\r\n"
            + "X-Trace-ID: abc123\r\n"
            + "Content-Length: 2\r\n\r\nhi"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.headers["host"] == "127.0.0.1:8787")
        #expect(parsed.headers["content-type"] == "application/json")
        #expect(parsed.headers["x-trace-id"] == "abc123")
        // 空值头是合法的（`Authorization:` 什么都不带），不能因为值为空就整条丢掉
        #expect(parsed.headers.keys.contains("authorization"))
        #expect(parsed.headers["authorization"]?.isEmpty ?? false)
        // body 仍然只按 Content-Length 走，头部多几条不影响帧算
        #expect(String(data: parsed.body, encoding: .utf8) == "hi")
        #expect(parsed.consumedBytes == raw.utf8.count)
    }

    @Test("头名大小写与空格都归一到同一个键")
    func headerNameNormalization() throws {
        let raw = "GET /health HTTP/1.1\r\nCONTENT-TYPE: text/plain\r\nOrigin : http://x\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.headers["content-type"] == "text/plain")
        #expect(parsed.headers["origin"] == "http://x")
    }

    @Test("没有冒号的行整条跳过，不凭空造出一个头")
    func lineWithoutColonIsSkipped() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: x\r\ngarbage line without colon\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.headers["host"] == "x")
        #expect(!parsed.headers.values.contains { $0.contains("garbage") })
    }

    @Test("值里的冒号不被截断")
    func valueKeepsInnerColons() throws {
        let raw = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer a:b:c\r\nContent-Length: 0\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.headers["authorization"] == "Bearer a:b:c")
    }

    @Test("同名不同值按 HTTP 语义逗号合并，同名同值只留一条")
    func duplicateHeadersCombined() throws {
        let raw = "POST /mcp HTTP/1.1\r\n"
            + "X-Tag: a\r\nX-Tag: b\r\nX-Tag: a\r\n"
            + "Content-Length: 0\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.headers["x-tag"] == "a, b")
    }

    // MARK: - Content-Length 的畸形与冲突：不许拿默认值当真值

    @Test("重复且相同的 Content-Length 照常解析（不许被当成冲突）")
    func identicalDuplicateContentLengthAccepted() throws {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nhi"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(String(data: parsed.body, encoding: .utf8) == "hi")
    }

    @Test("Content-Length 冲突直接判畸形返回 nil")
    func conflictingContentLengthRejected() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 5\r\n\r\nhi"
        #expect(HTTPRequestParser.parse(buffer: request(raw)) == nil)
    }

    @Test("Content-Length 不是数字返回 nil，不再静默当 0")
    func nonNumericContentLengthRejected() {
        // 旧行为：`Int("abc") ?? 0` 把畸形长度读成 0 ⇒ 返回一个"空 body 的正常请求"，
        // 后面的 JSON 体被留在缓冲区里当成下一个请求的头部，keep-alive 上就串了。
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: abc\r\n\r\n{\"jsonrpc\":1}"
        #expect(HTTPRequestParser.parse(buffer: request(raw)) == nil)
    }

    @Test("Content-Length 为负返回 nil")
    func negativeContentLengthRejected() {
        #expect(HTTPRequestParser.parse(buffer: request("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) == nil)
    }

    @Test("没有 Content-Length 时头照样收齐，长度按 0")
    func headersPresentWithoutContentLength() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: x\r\nOrigin: http://192.168.1.20\r\n\r\n"
        let parsed = try #require(HTTPRequestParser.parse(buffer: request(raw)))
        #expect(parsed.headers["origin"] == "http://192.168.1.20")
        #expect(parsed.body.isEmpty)
    }
}
