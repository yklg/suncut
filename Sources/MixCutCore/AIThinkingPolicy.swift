import Foundation

/// 「思考（reasoning）开关」在**请求体里长什么样**，以及与之配套的**输出预算**。
///
/// 为什么这条规则要住 Core：它决定"用户界面上那个思考开关到底有没有落到 API"。
/// 2026-10-09 实测两次 AI 切分失败，一手证据是 `finish_reason=length` 且
/// `completion=8192 / reasoning_content=12529~15744 字符` —— 也就是**正文还没开始写，
/// 额度已经被推理吃光**。根因是当时的能力表认定"DeepSeek 无参数可切换思考"，于是
/// `thinking=false` 从没发出去，而官方文档写着 `thinking.type` 默认 `enabled`、
/// `reasoning_effort` 默认 `high`。一个没人验证的表 = 界面上的谎。
public enum ThinkingWireShape: String, Equatable, Sendable {
    /// 该组合不提供思考开关：不发任何思考参数（发了会被 400 或静默忽略）
    case none
    /// DashScope 形态：顶层布尔 `enable_thinking`
    case enableThinkingBool
    /// DeepSeek V4 / Anthropic 形态：嵌套对象 `thinking = {type: enabled|disabled}`
    case thinkingTypeObject
}

public enum AIThinkingPolicy {

    /// provider 的 `AIProviderType.rawValue` 与模型名都按**字符串**进来：
    /// 名字表的真源在 App 侧（那里才有 Keychain/转发网关），这里只做形状裁定，
    /// 避免把 App 的枚举搬进 Core 造成第二个名册。
    public static func wireShape(provider: String, model: String) -> ThinkingWireShape {
        switch provider {
        case "deepseek":
            // V4 双版可显式开关；`deepseek-chat` 是非思考旧别名、`deepseek-reasoner` 恒思考，
            // 对这两颗发 disabled 要么是谎、要么是 400 ⇒ 不发。
            return model.hasPrefix("deepseek-v4") ? .thinkingTypeObject : .none
        case "qwen":
            // DashScope 商业版这几颗支持 enable_thinking（非流式可用）；
            // qwen-max-latest（旧架构）与 coder 系不支持。
            return ["qwen3-max", "qwen-plus-latest", "qwen-flash", "qwen-turbo-latest"].contains(model)
                ? .enableThinkingBool : .none
        case "claude":
            // 原生 4 系及以上全系支持 extended thinking
            return .thinkingTypeObject
        default:
            // MiniMax 思考由模型本身决定；转发网关/自定义后端参数透传不可靠 ⇒ 不开这个口
            return .none
        }
    }

    /// 该组合是否露出"思考"开关（UI 与请求体必须同一个答案，不许两处各判一次）。
    public static func supportsToggle(provider: String, model: String) -> Bool {
        wireShape(provider: provider, model: model) != .none
    }

    /// OpenAI 兼容路径的**唯一**输出预算表（原先这份表住在 App 侧 `providerMaxTokens`，
    /// 那里只按 provider 给值、不看思考状态，于是"开思考 = 推理吃光额度"没人管）。
    ///
    /// Claude **原生** messages 接口不走这里：它的 max_tokens 上限按模型而变、我没核实，
    /// 那条分支保持原样，不在没验证过的地方动数。
    public static func maxOutputTokens(provider: String, model: String, thinkingEnabled: Bool) -> Int {
        let base: Int
        switch provider {
        case "minimax", "claude_relay": base = 16_384
        default: base = 8_192
        }
        // 推理与正文共用同一份 completion 额度 ⇒ 开思考必须把上限抬到装得下两者
        if thinkingEnabled, wireShape(provider: provider, model: model) == .thinkingTypeObject {
            return max(base, 32_768)
        }
        return base
    }
}
