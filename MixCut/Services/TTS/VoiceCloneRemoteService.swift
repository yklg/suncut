import Foundation

/// 远端复刻音色的注销（释放服务商侧配额）。
///
/// ## 只服务于 M2 qwen 路线
///
/// 阿里云的「声音复刻」有两套协议，本仓 M2 走 Qwen（`qwen-voice-enrollment`）：
/// - 创建：`model=qwen-voice-enrollment`，`action=create`，`audio` 支持 **base64 内联**；
/// - 删除：`model=qwen-voice-enrollment`，`action=delete`，参数是 **`voice`（不是 `voice_id`）**，
///   返回体回显被删的 `voice` 名。
///
/// （CosyVoice 侧是 `voice-enrollment` + `action=delete_voice` + `voice_id`。
/// 若将来切回那条路线，这里要按 `voice-enrollment` 分支；M2 不做——
/// 计划已定走qwen，且两套字段名不同、混用会静默失败。）
///
/// ## 失败不阻断本地删除
///
/// 见 `VoiceCloneViewModel.delete`：本地记录已删、远端注销失败时**不回滚**，
/// 如实提示用户去控制台手删。回滚会把用户卡在更糟的状态。
actor VoiceCloneRemoteService {
    enum RevokeError: Error, LocalizedError {
        case missingAPIKey
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "尚未配置千问 API Key，无法注销远端音色"
            case .badResponse(let d):
                return "注销远端音色失败：\(d)"
            }
        }
    }

    private static let endpoint =
        URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/tts/customization")!
    /// Qwen 复刻绑定的合成型号（与注册时必须一致）。
    static let targetModel = VoiceCloneService.targetModel

    private let apiKeyProvider: @Sendable () -> String?

    init(apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.dashScopeKey }) {
        self.apiKeyProvider = apiKeyProvider
    }

    /// 注销远端音色，释放配额。
    /// - Parameter voiceId: 注册时返回的音色 id（Qwen 侧叫 `voice`）。
    func revoke(voiceId: String) async throws {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw RevokeError.missingAPIKey }
        let body: [String: Any] = [
            "model": "qwen-voice-enrollment",
            "input": ["action": "delete", "voice": voiceId],
        ]
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw RevokeError.badResponse(
                "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        // 不解析返回体：删除成功时 output 只回显 voice 名，其余字段无业务含义。
        // 真失败会走 HTTP 非 2xx 分支并把原文带出去。
    }
}