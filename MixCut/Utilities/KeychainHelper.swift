import Foundation

/// API Key 存储封装（使用 UserDefaults，避免 Keychain 弹窗）
enum KeychainHelper {

    private static let defaults = UserDefaults.standard
    private static let apiKeyPrefix = "api_key_"

    // MARK: - API Key 管理（UserDefaults）

    /// 保存 API Key
    static func saveAPIKey(_ key: String, for provider: AIProviderType) throws {
        defaults.set(key, forKey: apiKeyPrefix + provider.rawValue)
    }

    /// 获取 API Key
    static func getAPIKey(for provider: AIProviderType) -> String? {
        let key = defaults.string(forKey: apiKeyPrefix + provider.rawValue)
        return (key?.isEmpty == true) ? nil : key
    }

    /// 删除 API Key
    static func removeAPIKey(for provider: AIProviderType) throws {
        defaults.removeObject(forKey: apiKeyPrefix + provider.rawValue)
    }

    /// 是否已配置 API Key
    static func hasAPIKey(for provider: AIProviderType) -> Bool {
        guard let key = getAPIKey(for: provider) else { return false }
        return !key.isEmpty
    }

    /// 语音/画面类能力（原声克隆 / TTS 配音 / 云端 ASR / Wan25 画面替换）统一使用的
    /// 阿里云百炼 DashScope 凭证。
    ///
    /// 凭证路由规则的单点真源：这些能力只走 DashScope，与 `activeProvider` 无关——
    /// 用户文本智能选 DeepSeek 时，配音/画面仍读这里。日后接入第二家语音厂商时，
    /// 只需改此访问点（或升级为带厂商参数的路由），不必全库搜索 getAPIKey。
    static var dashScopeKey: String? { getAPIKey(for: .qwen) }

    // MARK: 博查搜索（v3.4 知识库调研）

    /// 博查 API Key（独立于 AI 提供商，UserDefaults 存储）。
    static var bochaKey: String? {
        let key = defaults.string(forKey: "bocha_api_key")
        return (key?.isEmpty == true) ? nil : key
    }

    static func saveBochaKey(_ key: String) {
        defaults.set(key, forKey: "bocha_api_key")
    }

    // MARK: - 活跃提供商

    private static let activeProviderKey = "active_ai_provider"

    static var activeProvider: AIProviderType {
        get {
            guard let raw = defaults.string(forKey: activeProviderKey),
                  let type = AIProviderType(rawValue: raw) else {
                return .qwen
            }
            return type
        }
        set {
            defaults.set(newValue.rawValue, forKey: activeProviderKey)
        }
    }

    // MARK: - 自定义提供商配置

    static var customBaseURL: String {
        get { defaults.string(forKey: "custom_base_url") ?? "" }
        set { defaults.set(newValue, forKey: "custom_base_url") }
    }

    static var customModelName: String {
        get { defaults.string(forKey: "custom_model_name") ?? "" }
        set { defaults.set(newValue, forKey: "custom_model_name") }
    }

    /// 国内转发网关地址（用户自行配置，要求兼容 OpenAI 协议）
    static var relayBaseURL: String {
        get {
            // 兼容旧 key：claude_relay_base_url
            if let v = defaults.string(forKey: "relay_base_url"), !v.isEmpty { return v }
            return defaults.string(forKey: "claude_relay_base_url") ?? ""
        }
        set { defaults.set(newValue, forKey: "relay_base_url") }
    }

    /// 国内转发网关下选择的平台（Claude / Gemini / OpenAI）
    static var relayPlatform: RelayPlatform {
        get {
            guard let raw = defaults.string(forKey: "relay_platform"),
                  let platform = RelayPlatform(rawValue: raw) else {
                return .claude
            }
            return platform
        }
        set { defaults.set(newValue.rawValue, forKey: "relay_platform") }
    }

    // MARK: - 模型选择

    private static let modelKeyPrefix = "selected_model_"

    static func selectedModel(for provider: AIProviderType) -> String {
        defaults.string(forKey: modelKeyPrefix + provider.rawValue) ?? provider.defaultModel
    }

    static func setSelectedModel(_ model: String, for provider: AIProviderType) {
        defaults.set(model, forKey: modelKeyPrefix + provider.rawValue)
    }

    // MARK: - 深度思考开关（按提供商存储，默认关闭）

    private static let thinkingKeyPrefix = "thinking_enabled_"

    static func thinkingEnabled(for provider: AIProviderType) -> Bool {
        defaults.bool(forKey: thinkingKeyPrefix + provider.rawValue)
    }

    static func setThinkingEnabled(_ enabled: Bool, for provider: AIProviderType) {
        defaults.set(enabled, forKey: thinkingKeyPrefix + provider.rawValue)
    }
}
