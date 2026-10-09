import Foundation

/// 一个模型的单价行。**必须带来源与生效日期** —— 没有出处价格就是编的，
/// 而"编的数"比"不知道"危险得多：用户会拿它去决定要不要少导入几个视频。
public struct AIModelPrice: Equatable, Sendable {

    /// 计价货币代号，直接进日志与（后续）看板文案。
    public var currency: String
    /// 每 100 万输入 tokens（**未命中缓存**的价）。缓存命中价另存一列，
    /// 因为我们的 usage 里没有"命中了多少"这一项 ⇒ 只能按上界算，见 `AICostCalculator`。
    public var inputPerMTokens: Double
    /// 每 100 万输入 tokens（命中缓存）。nil = 官方没给这一档。
    public var cachedInputPerMTokens: Double?
    /// 每 100 万输出 tokens。推理(reasoning) tokens 也在这一档里计费，不单独收。
    public var outputPerMTokens: Double
    /// 取数出处（官方页 URL）。
    public var source: String
    /// 生效日 = 我去官方页取数那天。价格会变，没有这一栏的价不许进表。
    public var asOf: String
    /// 计费口径说明，直接进给用户看的那一行（例：峰时价，谷时减半）。
    public var note: String

    public init(currency: String, inputPerMTokens: Double, cachedInputPerMTokens: Double?,
                outputPerMTokens: Double, source: String, asOf: String, note: String) {
        self.currency = currency
        self.inputPerMTokens = inputPerMTokens
        self.cachedInputPerMTokens = cachedInputPerMTokens
        self.outputPerMTokens = outputPerMTokens
        self.source = source
        self.asOf = asOf
        self.note = note
    }
}

/// 内置单价表。**只收一手取到、且写清了出处与生效日的行**。
///
/// 为什么不全：千问 / MiniMax / Claude / 转发网关 / 自定义后端这几家本次没取到可比口径的数，
/// 表里没有就等于"单价未知" —— 未知必须显示成未知，不许拿邻近模型的价顶上去。
public enum AIPriceTable {

    /// key = `provider.rawValue + "/" + 模型名`（与 `AIProviderType` 的 rawValue 同一套名字）。
    public static let prices: [String: AIModelPrice] = [
        "deepseek/deepseek-v4-flash": AIModelPrice(
            currency: "CNY",
            inputPerMTokens: 2.0,
            cachedInputPerMTokens: 0.04,
            outputPerMTokens: 8.0,
            source: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing",
            asOf: "2026-10-09",
            note: "按官方峰时价（谷时为半价）"
        ),
        "deepseek/deepseek-v4-pro": AIModelPrice(
            currency: "CNY",
            inputPerMTokens: 4.0,
            cachedInputPerMTokens: 0.08,
            outputPerMTokens: 24.0,
            source: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing",
            asOf: "2026-10-09",
            note: "按官方峰时价（谷时为半价）"
        ),
    ]

    public static func key(provider: String, model: String) -> String {
        "\(provider)/\(model)"
    }

    public static func price(provider: String, model: String) -> AIModelPrice? {
        prices[key(provider: provider, model: model)]
    }
}

/// 金额计算。纯函数，可单测。
public enum AICostCalculator {

    /// 这次调用花了多少钱。**三种"不知道"都返回 nil，绝不返回 0**：
    /// 没价（表里没这颗模型）、没 usage（后端没返回用量）、用量四项全空。
    /// 返回 0 会把"不知道"显示成"没花钱"，那是谎。
    ///
    /// 口径：输入一律按**未命中缓存**价算 ⇒ 这是**上界**（真实账单只会更小）。
    /// 我们的 usage 里没有"缓存命中了多少 tokens"这一项，所以拿不到精确值；
    /// 宁可报高，不可报低，也不可假装精确。
    public static func cost(usage: AITokenUsage?, per price: AIModelPrice?) -> Double? {
        guard let price, let usage, !usage.isEmpty else { return nil }
        guard let prompt = usage.promptTokens, let completion = usage.completionTokens else {
            return nil
        }
        let input = Double(prompt) / 1_000_000.0 * price.inputPerMTokens
        let output = Double(completion) / 1_000_000.0 * price.outputPerMTokens
        return input + output
    }

    /// 给人看的一小段。nil 时说清是"哪一栏不知道"，不含糊。
    public static func label(usage: AITokenUsage?, per price: AIModelPrice?) -> String {
        guard let price else { return "金额=单价未知(表内无此模型，不估算)" }
        guard let usage, !usage.isEmpty, usage.promptTokens != nil, usage.completionTokens != nil else {
            return "金额=无法计算(后端未返回用量)"
        }
        guard let cost = cost(usage: usage, per: price) else {
            return "金额=无法计算"
        }
        return String(format: "金额≈%.4f%@", cost, price.currency) + "(\(price.note))"
    }
}
