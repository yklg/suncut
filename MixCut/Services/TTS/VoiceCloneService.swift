import Foundation

/// 用 DashScope qwen 声音克隆：拿一段参考音频(mp3) 注册出一个克隆音色 voice_id。
/// 合成时用 QwenTTSClient(model: VoiceCloneService.targetModel) + 该 voice_id。
actor VoiceCloneService {
    enum CloneError: Error, LocalizedError {
        case missingAPIKey
        case badResponse(String)
        case noVoiceId

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "尚未配置千问 API Key，请到「设置」里填写后重试"
            case .badResponse(let d): return "声音克隆失败：\(d)"
            case .noVoiceId: return "声音克隆未返回音色 ID"
            }
        }
    }

    /// 克隆音色绑定的合成模型；注册与合成必须用同一个。
    static let targetModel = "qwen3-tts-vc-2026-01-22"
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization")!

    private let apiKeyProvider: @Sendable () -> String?
    /// 注入的会话（测试用；生产走 `.shared`）。
    /// ⚠️ 之前固定用 `URLSession.shared` ⇒ 本文件**零测试覆盖**（缺陷所在文件却没有网络测试）。
    private let session: URLSession

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.dashScopeKey },
         session: URLSession = .shared) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    /// 注册结果：远端音色 id + **实际发出的** `preferred_name`。
    ///
    /// 为什么必须把 `providerName` 带出来（M2 踩过的坑）：
    /// 清洗发生在本函数**内部**（`CloneVoiceNaming` 唯一真源），而清洗结果**依赖转写**
    /// （中文 → 拼音）⇒ 调用方自己再算一遍既是重复实现、也会与实际发出的值不一致
    /// （`VoiceProfile.providerName` 曾因此恒定对不上远端）。
    /// 由返回值携带 ⇒ **类型层保证一致**，不依赖调用方自觉。
    struct EnrollResult: Sendable {
        /// 服务端返回的音色 id（合成时的 voice 参数）。
        let voiceId: String
        /// 实际发给服务端的标识名（纯 ASCII，≤ 协议上限）。
        let providerName: String
    }

    /// 用参考音频注册克隆音色。
    /// - Parameters:
    ///   - preferredName: **原始显示名**（可含中文）。清洗在本函数内收口，
    ///     调用方不要自己洗——那会产生第二个真源。
    func enroll(referenceAudioPath: String, preferredName: String) async throws -> EnrollResult {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw CloneError.missingAPIKey }
        // 同 Wan25：映射只覆盖 base64 编码，不跨越后面的网络请求（避免文件被清理时 SIGBUS）
        let b64: String = try {
            let data = try Data(contentsOf: URL(fileURLWithPath: referenceAudioPath), options: .mappedIfSafe)
            MixLog.info("[VoiceClone] 参考音频 \(data.count / 1024) KB")
            return data.base64EncodedString()
        }()

        // 清洗唯一真源（Core）：中文 → 拼音 → 纯ASCII → 截断/消歧。
        // ⚠️ 旧实现用 `filter { $0.isLetter || $0.isNumber }`，而 **Swift 对汉字的
        // `isLetter` 返回 true** ⇒ 汉字被原样发出，服务端报400 InvalidParameter。
        let providerName = CloneVoiceNaming.sanitizeForProvider(
            preferredName, maxLength: CloneVoiceNaming.ProviderLimit.qwenPreferredName)

        let body: [String: Any] = [
            "model": "qwen-voice-enrollment",
            "input": [
                "action": "create",
                "target_model": Self.targetModel,
                "preferred_name": providerName,
                "audio": ["data": "data:audio/mpeg;base64,\(b64)"]
            ]
        ]

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: respData, encoding: .utf8)?.prefix(300) ?? ""
            throw CloneError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let output = obj["output"] as? [String: Any],
              let voice = output["voice"] as? String, !voice.isEmpty else {
            throw CloneError.noVoiceId
        }
        // 把「实际发出的标识名」与 voiceId 一起返回 ⇒ 调用方无需（也无法）重算。
        return EnrollResult(voiceId: voice, providerName: providerName)
    }

    // ⚠️ 原先这里有一个私有的 `sanitizedName`，**已删除**：
    // 它用 `filter { $0.isLetter || $0.isNumber }`，而 Swift 对汉字的 `isLetter`
    // 返回 true（CJK 属 Unicode `Lo`）⇒ 汉字被原样发给服务端 ⇒ 400 InvalidParameter。
    // 且它的长度上限写死 20（官方是 16）。清洗已收口到
    // `CloneVoiceNaming.sanitizeForProvider`（Core 唯一真源，含拼音 + 截断 + 消歧）。
}
