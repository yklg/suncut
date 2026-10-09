import Foundation
import Network

/// 内嵌本地 MCP server 的 HTTP 传输壳。
/// 只绑定 127.0.0.1，只接受 POST /mcp；JSON-RPC 语义全部委托给注入的 handler。
actor MCPServer {
    private let port: UInt16
    private let handler: @Sendable (Data) async -> Data?
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping @Sendable (Data) async -> Data?) {
        self.port = port
        self.handler = handler
    }

    /// 启动并**等到端口真的绑上**才返回。
    ///
    /// 为什么必须等：`NWListener.start(queue:)` 是异步的，端口被别的进程占用时这一行**不抛错**，
    /// 失败只会让 `state` 走到 `.failed`。旧实现在 `start()` 之后直接打「server 已监听」，
    /// 于是"这个实例根本没拿到端口"在日志、异常、界面上全都看不见 ——
    /// 后果不是启动失败，而是**自动化调用静默打到持有端口的另一个实例上**（也就是用户的活 App）。
    func start() async throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPServerError.invalidPort(port)
        }
        let params = NWParameters.tcp
        // 只监听回环地址：外部机器不可达
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = StartGate(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.succeed()
                case .failed(let error):
                    gate.fail(MCPServerError.listenFailed(port: self.port, error: error))
                case .cancelled:
                    gate.fail(MCPServerError.cancelled(port: self.port))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            // 兜底：状态回调一次都不来的话（极端情况），3 秒后按失败处理，
            // 绝不"超时也算启动成功" —— 那等于把这次的静默失效原样保留。
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                gate.fail(MCPServerError.startTimeout(port: self.port))
            }
        }

        self.listener = listener
        MixLog.info("[MCP] server 已监听 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        MixLog.info("[MCP] server 已停止")
    }

    // MARK: - 单连接处理（支持 keep-alive 串行多请求）

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        while true {
            if let request = HTTPRequestParser.parse(buffer: buffer) {
                buffer.removeFirst(request.consumedBytes)
                let response = await route(request)
                let sent = await send(response, over: connection)
                if !sent { break }
                continue
            }
            guard let chunk = await receiveChunk(connection), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if buffer.count > 4 * 1024 * 1024 { break }   // 防御：异常大请求直接断开
        }
        connection.cancel()
    }

    private func route(_ request: ParsedHTTPRequest) async -> Data {
        guard request.method == "POST", request.path == "/mcp" else {
            return Self.httpResponse(status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
        }
        guard let responseBody = await handler(request.body) else {
            // JSON-RPC notification：无应答体
            return Self.httpResponse(status: "202 Accepted", body: Data(), contentType: "application/json")
        }
        return Self.httpResponse(status: "200 OK", body: responseBody, contentType: "application/json")
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if error != nil {
                    continuation.resume(returning: nil)
                } else if isComplete && (data?.isEmpty ?? true) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private static func httpResponse(status: String, body: Data, contentType: String) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum MCPServerError: Error, LocalizedError {
    case invalidPort(UInt16)
    case listenFailed(port: UInt16, error: Error)
    case cancelled(port: UInt16)
    case startTimeout(port: UInt16)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let p): return "非法端口号：\(p)"
        case .listenFailed(let p, let error): return "端口 \(p) 绑定失败：\(error.localizedDescription)"
        case .cancelled(let p): return "端口 \(p) 的监听已取消，未能建立"
        case .startTimeout(let p): return "端口 \(p) 绑定超时（3s 内没有进入 ready）"
        }
    }
}

/// `start()` 的一次性续体盒子：状态回调与超时兜底都可能到，只许放行第一个。
private final class StartGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() { resolve(with: nil) }
    func fail(_ error: Error) { resolve(with: error) }

    private func resolve(with error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
