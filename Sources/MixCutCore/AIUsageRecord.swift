import Foundation

/// 一次 AI 调用**属于哪件事**。
///
/// 为什么要有这张名册：用户的抱怨是"花了钱看不见花在哪"。没有场景标签的用量只有一个总数，
/// 说不出"切分白跑了三次"还是"方案生成吃掉了大半"。名册住 Core 是为了让它可被单测覆盖，
/// 并且**调用点必须显式申报**（守卫 `check_ai_completeness_guards.sh` 数的是调用形状），
/// 不许由"哪个文件调的"反推 —— 反推出来的归属会在重构那天悄悄错位。
public enum AIScene: String, CaseIterable, Sendable {
    case segmentAnalysis = "分镜切分"
    case segmentTags = "分镜打标"
    case schemeStrategy = "方案策略"
    case schemeComposition = "方案组合"
    case schemeMetadata = "方案元信息"
    case scriptStructure = "脚本结构"
    case scriptWriting = "脚本写作"
    case scriptRewrite = "脚本改写"
    case productResearch = "产品调研"
    case connectionTest = "连接测试"

    public var displayName: String { rawValue }
}

/// 一次**拿到 HTTP 2xx 应答**的调用的用量快照。
///
/// 关键口径（红线：来源不能说谎）：
/// - **空正文与长度截断也是花了钱的**。判失败不等于没消费：prompt 全额计费，
///   截断那次还把 completion 额度跑满过（实测 8192）。所以 `wasted` 不是"没花钱"，
///   是"花了钱没拿到可用结果"—— 这一栏才是用户真正想知道的那笔。
/// - `usage` 缺席（有的后端不返回 usage 字段）时**不许补 0**，要写"缺席"。
///   补 0 会把"不知道"伪装成"没花"。
public struct AIUsageRecord: Sendable {

    /// 这次调用的落点。`billedButWasted` 由它自己判定，不由调用方申报。
    public enum Outcome: String, Sendable {
        case succeeded = "成功"
        case emptyBody = "空正文"
        case truncated = "长度截断"
        case unparsable = "无法解析"

        /// 花了钱但没有可用产物。
        public var wasted: Bool { self != .succeeded }
    }

    public var scene: AIScene
    public var provider: String
    public var model: String
    public var thinkingEnabled: Bool
    public var promptChars: Int
    public var responseChars: Int
    public var elapsedSeconds: Double
    public var usage: AITokenUsage?
    public var outcome: Outcome
    /// 这颗模型的单价行；nil = 表里没有 ⇒ 金额显示"单价未知"，**不许估算**。
    public var price: AIModelPrice?

    public init(scene: AIScene, provider: String, model: String, thinkingEnabled: Bool,
                promptChars: Int, responseChars: Int, elapsedSeconds: Double,
                usage: AITokenUsage?, outcome: Outcome, price: AIModelPrice? = nil) {
        self.scene = scene
        self.provider = provider
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.promptChars = promptChars
        self.responseChars = responseChars
        self.elapsedSeconds = elapsedSeconds
        self.usage = usage
        self.outcome = outcome
        self.price = price
    }

    /// 金额（上界）。nil = 不知道，不是 0。
    public var cost: Double? { AICostCalculator.cost(usage: usage, per: price) }

    /// token 分解。四项各自都可能是缺席（有的网关不返回），**缺席必须写"缺席"而不是 0** ——
    /// 补 0 会把"不知道"伪装成"没花"。整个 usage 全空也按缺席报（与 `AITokenUsage.isEmpty` 同口径）。
    public var tokenBreakdown: String {
        guard let usage, !usage.isEmpty else { return "用量缺席(后端未返回 usage)" }
        func field(_ label: String, _ value: Int?) -> String {
            "\(label)=" + (value.map(String.init) ?? "缺席")
        }
        var line = field("prompt", usage.promptTokens)
        + " " + field("completion", usage.completionTokens)
        + " " + field("total", usage.totalTokens)
        // reasoning 只在后端真的返回时才写：多数字段没有它，硬凑一行"reasoning=缺席"
        // 会让人以为"这次确实没推理"，而真实情况常常是"这个网关不告诉你"。
        if let reasoning = usage.reasoningTokens { line += " reasoning=\(reasoning)" }
        return line
    }

    /// 一行进日志。日志是这一层目前的唯一落点（落库与看板在下一笔）。
    public func logLine() -> String {
        "[AI用量] 场景=\(scene.displayName) provider=\(provider) model=\(model)"
        + " 思考=\(thinkingEnabled ? "开" : "关") 耗时=\(String(format: "%.1f", elapsedSeconds))s"
        + " 正文=\(responseChars)字符 结果=\(outcome.rawValue)"
        + (outcome.wasted ? "(已计费但白跑)" : "")
        + " \(tokenBreakdown)"
        + " " + AICostCalculator.label(usage: usage, per: price)
    }
}
