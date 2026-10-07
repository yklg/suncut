import Foundation
import Testing
// ⚠️ module 名是 **SunCut**：App target 的 PRODUCT_NAME = SunCut 且未设
// PRODUCT_MODULE_NAME ⇒ Swift module 名默认取 PRODUCT_NAME（同 TEST_HOST 那个 SunCut）。
@testable import SunCut

// ============================================================================
// EN · `VoiceCloneService.enroll` 网络路径契约（M2 test target 首批用例）
//
// ## 为什么这组测试存在
//
// `preferred_name` 的 400 缺陷就发生在 `VoiceCloneService.swift`，而该文件此前**零测试**。
// 根因链：`isLetter` 对汉字返回 true ⇒ 汉字原样发给服务端 ⇒ 服务端 400；
// 而这一切**没有任何测试会发现**，因为 `enroll` 固定用 `URLSession.shared` 没法 mock。
// 现已加 `session` 注入点 + 建了本 test target ⇒ 有了测试载体。
//
// ## 判别式设计（防「假绿」）
//
// 断言用「**把 mock 收到的请求体解析出来**」，而不是断言被测函数内部的变量。
// 只测被测函数自己产出的值 ⇒ 无论实现对错都可能绿（假绿）。
// 必须走完整流程（构造请求 → mock 响应 → 解析回请求体）才拿得到独立证据。
// ============================================================================

/// 拦截所有请求的 URLProtocol mock。
private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var responseJSON: String =
        #"{"output":{"voice":"mocked_voice_id"},"request_id":"req-1"}"#
    nonisolated(unsafe) static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // 关键：**在协议层读 body**。URLSession 在传输层会把 httpBody 转成
        // httpBodyStream（且只能读一次），但 URLProtocol 拿到的 request 仍可读。
        Self.lastRequestBody = request.httpBody ?? request.httpBodyStream.map { s in
            s.open(); defer { s.close() }
            var buf = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while s.hasBytesAvailable {
                let read = s.read(buffer, maxLength: size)
                if read <= 0 { break }
                buf.append(buffer, count: read)
            }
            return buf
        }

        let data = Data(Self.responseJSON.utf8)
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func makeService(key: String = "sk-test") throws -> (VoiceCloneService, URL) {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    // ⚠️ 必须先清 mock 状态，否则上一个用例的 body 会让下一个假绿。
    MockURLProtocol.lastRequestBody = nil
    MockURLProtocol.statusCode = 200
    MockURLProtocol.responseJSON =
        #"{"output":{"voice":"mocked_voice_id"},"request_id":"req-1"}"#
    let tmp = FileHelper.tempDirectory
        .appendingPathComponent("enroll-test-\(UUID().uuidString).mp3")
    try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: tmp)
    return (VoiceCloneService(apiKeyProvider: { key }, session: URLSession(configuration: cfg)), tmp)
}

private func sentPreferredName() throws -> String {
    guard let body = MockURLProtocol.lastRequestBody,
          let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          let input = obj["input"] as? [String: Any],
          let name = input["preferred_name"] as? String else {
        throw NSError(domain: "ENTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "没抓到请求体（mock 未生效或 body 为空）"])
    }
    return name
}

// MARK: - EN-1..3：缺陷的直接契约

/// EN 用例**串行**执行：mock 的响应体/请求体存在**静态可变状态**里，而 Swift Testing
/// 默认并行 ⇒ A 用例设的响应会被 B 用例在断言前改掉（实测：6 条里 4 条失败、
/// 单独跑却全绿）。mock 必须能跨 `URLProtocol.startLoading`（另一个对象）传状态，
/// 只能走静态 ⇒ 正解是序列化 suite，而不是给每条用例各建一个 mock（那就无法断言了）。
@Suite(.serialized)
struct VoiceCloneServiceContractTests {
    @Test("EN-1 送出的 preferred_name 必须是纯 ASCII（400 InvalidParameter 的直接根因）")
    func en1_sentNameIsPureASCII() async throws {
        let (svc, tmp) = try makeService()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 用户实测场景：中文名直接发给服务端 ⇒ 服务端 400。
        _ = try await svc.enroll(referenceAudioPath: tmp.path, preferredName: "市土产仓库 5")

        let sent = try sentPreferredName()
        #expect(sent.unicodeScalars.allSatisfy { $0.isASCII },
                "送出的标识名含非ASCII 字符：\(sent) ⇒ 服务端会 400")
    }

    @Test("EN-2 EnrollResult.providerName 等于实际送出的值（对账字段不得本地重算）")
    func en2_providerNameMatchesSentValue() async throws {
        let (svc, tmp) = try makeService()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await svc.enroll(referenceAudioPath: tmp.path, preferredName: "我的声音")
        let sent = try sentPreferredName()

        #expect(result.providerName == sent,
                "返回值声称发了「\(result.providerName)」，实际发出「\(sent)」⇒ 对账字段会与远端不一致")
        #expect(result.voiceId == "mocked_voice_id", "voiceId 应来自响应体 output.voice")
    }

    @Test("EN-3 请求体结构符合官方契约（model/action/target_model 三者齐备）")
    func en3_requestBodyMatchesOfficialContract() async throws {
        let (svc, tmp) = try makeService()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try await svc.enroll(referenceAudioPath: tmp.path, preferredName: "测试")

        guard let body = MockURLProtocol.lastRequestBody,
              let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = obj["input"] as? [String: Any] else {
            Issue.record("没抓到请求体")
            return
        }
        #expect(obj["model"] as? String == "qwen-voice-enrollment")
        #expect(input["action"] as? String == "create")
        #expect(input["target_model"] as? String == VoiceCloneService.targetModel,
                "target_model 必须与合成时用的型号一致，否则服务端合成会失败")
        #expect(input["audio"] != nil, "audio.data 必须存在（base64 内联）")
    }

    // MARK: - EN-4：零回归（逐视频克隆链路）

    @Test("EN-4 纯 ASCII 名不被改写（逐视频克隆链路零回归）")
    func en4_pureASCIINameUnchanged() async throws {
        // 🔵 负向哨兵：这条防的是「给所有名字都跑一遍转写 / 消歧」。
        // 逐视频克隆传的是 `Brand.shortName + hash`（纯 ASCII），必须逐字不变。
        let (svc, tmp) = try makeService()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = Brand.shortName + "1a2b3c4d"
        let result = try await svc.enroll(referenceAudioPath: tmp.path, preferredName: input)

        #expect(result.providerName == input,
                "纯 ASCII 名被改写：「\(input)」→ 「\(result.providerName)」⇒ 逐视频克隆链路会回归")
        #expect(try sentPreferredName() == input)
    }

    // MARK: - EN-5/6：错误路径

    @Test("EN-5 服务端 400 时抛错而非静默成功")
    func en5_serverErrorThrows() async throws {
        let (svc, tmp) = try makeService()
        defer { try? FileManager.default.removeItem(at: tmp) }

        MockURLProtocol.statusCode = 400
        MockURLProtocol.responseJSON =
            #"{"request_id":"r","code":"InvalidParameter","message":"Required input 'preferred_name' is invalid"}"#

        await #expect(throws: VoiceCloneService.CloneError.self) {
            _ = try await svc.enroll(referenceAudioPath: tmp.path, preferredName: "测试")
        }
    }

    @Test("EN-6 未配置 API Key 时不发起请求（省一次无谓往返）")
    func en6_missingAPIKeyFailsBeforeRequest() async throws {
        let tmp = FileHelper.tempDirectory
            .appendingPathComponent("enroll-test-\(UUID().uuidString).mp3")
        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let svc = VoiceCloneService(apiKeyProvider: { nil },
                                    session: URLSession(configuration: cfg))
        MockURLProtocol.lastRequestBody = nil

        await #expect(throws: VoiceCloneService.CloneError.self) {
            _ = try await svc.enroll(referenceAudioPath: tmp.path, preferredName: "测试")
        }
        #expect(MockURLProtocol.lastRequestBody == nil, "无 Key 时不该发出请求（不该消耗网络往返）")
    }
}
