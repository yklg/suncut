import Testing
@testable import MixCutCore

/// 单价表与金额计算。核心主张只有两条：**没有出处就不许进表**，
/// **不知道就显示不知道 —— 返回 0 会把「不知道」说成「没花钱」**。
@Suite("AI 单价表与金额计算")
struct AIModelPricingTests {

    private let flashKey = "deepseek/deepseek-v4-flash"

    private func usage(_ prompt: Int, _ completion: Int) -> AITokenUsage {
        AITokenUsage(promptTokens: prompt, completionTokens: completion,
                     totalTokens: prompt + completion)
    }

    @Test("TC-C01 表里每一行都必须带出处与生效日（没出处的价就是编的）")
    func everyPriceCarriesItsSource() {
        #expect(!AIPriceTable.prices.isEmpty)
        for (key, price) in AIPriceTable.prices {
            #expect(price.source.hasPrefix("https://"), "\(key) 缺出处")
            #expect(price.asOf.count == 10 && price.asOf.contains("-"), "\(key) 生效日不成形：\(price.asOf)")
            #expect(!price.note.isEmpty, "\(key) 缺计费口径说明")
            #expect(price.currency == "CNY", "\(key) 币种必须显式写出")
            #expect(key.contains("/"), "key 必须是 provider/模型：\(key)")
        }
    }

    @Test("TC-C02 一手算式：真机那次 5468/1969 按峰时价约 ¥0.0267")
    func computesTheRealCall() {
        let price = AIPriceTable.price(provider: "deepseek", model: "deepseek-v4-flash")
        #expect(price != nil, "表里应当有 deepseek-v4-flash")
        guard let price else { return }
        // (5468×2 + 1969×8) / 1e6 = 26688 / 1e6 = 0.026688
        let cost = AICostCalculator.cost(usage: usage(5468, 1969), per: price)
        #expect(cost != nil)
        if let cost {
            #expect(abs(cost - 0.026688) < 1e-9, "实际 \(cost)")
        }
    }

    @Test("TC-C03 表里没有的模型：金额写「单价未知」，一个 0 都不许出现")
    func unknownModelIsNotZeroCost() {
        for (provider, model) in [("deepseek", "deepseek-chat"), ("qwen", "qwen3-max"),
                                  ("minimax", "MiniMax-M2.7"), ("custom", "某个自建后端")] {
            #expect(AIPriceTable.price(provider: provider, model: model) == nil,
                    "\(provider)/\(model) 本次没取到官方数，不许进表")
            let label = AICostCalculator.label(usage: usage(1000, 500),
                                               per: AIPriceTable.price(provider: provider, model: model))
            #expect(label.contains("单价未知"), "实际：\(label)")
            #expect(!label.contains("0.0000"), "不许把未知写成零：\(label)")
        }
    }

    @Test("TC-C04 后端没给用量时报「无法计算」，与「没花钱」是两件事")
    func missingUsageCannotBeCosted() {
        let price = AIPriceTable.prices[flashKey]
        #expect(AICostCalculator.cost(usage: nil, per: price) == nil)
        #expect(AICostCalculator.cost(usage: AITokenUsage(), per: price) == nil)
        let label = AICostCalculator.label(usage: nil, per: price)
        #expect(label.contains("无法计算"), "实际：\(label)")
        #expect(label.contains("未返回用量"), "实际：\(label)")
    }

    @Test("TC-C05 用量只给一半也不算：缺 completion 就是缺，不许拿单边数凑")
    func partialUsageIsNotHalfCosted() {
        let price = AIPriceTable.prices[flashKey]
        let half = AITokenUsage(promptTokens: 5468, completionTokens: nil, totalTokens: nil)
        #expect(AICostCalculator.cost(usage: half, per: price) == nil)
    }

    @Test("TC-C06 上界口径：按未命中缓存价算出的金额不低于按命中缓存价算的")
    func cacheMissRateIsTheUpperBound() {
        guard let price = AIPriceTable.prices[flashKey],
              let cached = price.cachedInputPerMTokens else {
            Issue.record("deepseek 行应带命中缓存价"); return
        }
        let lower = AIModelPrice(currency: price.currency, inputPerMTokens: cached,
                                 cachedInputPerMTokens: cached,
                                 outputPerMTokens: price.outputPerMTokens,
                                 source: price.source, asOf: price.asOf, note: price.note)
        let u = usage(5468, 1969)
        let a = AICostCalculator.cost(usage: u, per: price)
        let b = AICostCalculator.cost(usage: u, per: lower)
        #expect(a != nil && b != nil)
        if let a, let b { #expect(a >= b, "上界口径破了：\(a) < \(b)") }
    }

    @Test("TC-C07 用量行把金额带在一起，归属-用量-金额三件事不出两行")
    func usageLineCarriesTheMoney() {
        let r = AIUsageRecord(scene: .segmentAnalysis, provider: "DeepSeek",
                              model: "deepseek-v4-flash", thinkingEnabled: false,
                              promptChars: 9839, responseChars: 4322, elapsedSeconds: 6.2,
                              usage: usage(5468, 1969), outcome: .succeeded,
                              price: AIPriceTable.price(provider: "deepseek",
                                                        model: "deepseek-v4-flash"))
        let line = r.logLine()
        #expect(line.contains("金额≈0.0267CNY"), "实际：\(line)")
        #expect(line.contains("场景=分镜切分") && line.contains("prompt=5468"))
        #expect(r.cost != nil)
    }

    @Test("TC-C08 没传单价的记录仍然完整（金额那栏说未知，不影响其它读数）")
    func recordWithoutPriceStillReportsEverything() {
        let r = AIUsageRecord(scene: .connectionTest, provider: "千问", model: "qwen-flash",
                              thinkingEnabled: false, promptChars: 20, responseChars: 5,
                              elapsedSeconds: 1.2, usage: usage(10, 5), outcome: .succeeded)
        let line = r.logLine()
        #expect(r.cost == nil)
        #expect(line.contains("单价未知"), "实际：\(line)")
        #expect(line.contains("prompt=10"), "实际：\(line)")
    }
}
