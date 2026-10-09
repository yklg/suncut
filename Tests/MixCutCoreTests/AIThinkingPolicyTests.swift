import Testing
@testable import MixCutCore

/// 思考开关与输出预算的契约。核心主张：**界面上的开关必须能在请求体里落成对应的参数**，
/// 而开思考时额度必须给推理留出位置。
@Suite("AIThinkingPolicy 思考参数形状与输出预算")
struct AIThinkingPolicyTests {

    @Test("TC-T01 DeepSeek V4 双版可显式开关思考（失败根因：这颗以前被当成没法开关）")
    func deepSeekV4ExposesToggle() {
        #expect(AIThinkingPolicy.wireShape(provider: "deepseek", model: "deepseek-v4-flash")
                == .thinkingTypeObject)
        #expect(AIThinkingPolicy.wireShape(provider: "deepseek", model: "deepseek-v4-pro")
                == .thinkingTypeObject)
    }

    @Test("TC-T02 非思考别名与恒思考模型不发开关（发了要么是谎要么 400）")
    func legacyDeepSeekModelsStaySilent() {
        #expect(AIThinkingPolicy.wireShape(provider: "deepseek", model: "deepseek-chat") == .none)
        #expect(AIThinkingPolicy.wireShape(provider: "deepseek", model: "deepseek-reasoner") == .none)
    }

    @Test("TC-T03 千问仍是 enable_thinking 布尔形态，且只在那几颗上发")
    func qwenKeepsBoolShapeAndWhitelist() {
        #expect(AIThinkingPolicy.wireShape(provider: "qwen", model: "qwen3-max") == .enableThinkingBool)
        #expect(AIThinkingPolicy.wireShape(provider: "qwen", model: "qwen-flash") == .enableThinkingBool)
        #expect(AIThinkingPolicy.wireShape(provider: "qwen", model: "qwen-max-latest") == .none)
        #expect(AIThinkingPolicy.wireShape(provider: "qwen", model: "qwen3-coder-plus") == .none)
    }

    @Test("TC-T04 Claude 原生用 thinking 对象；MiniMax/转发/自定义/未知一律不开口")
    func otherProviders() {
        #expect(AIThinkingPolicy.wireShape(provider: "claude", model: "claude-sonnet-4-6")
                == .thinkingTypeObject)
        for provider in ["minimax", "claude_relay", "custom", "某个没见过的名字"] {
            #expect(AIThinkingPolicy.wireShape(provider: provider, model: "x") == .none,
                    "实际：\(provider)")
        }
    }

    @Test("TC-T05 supportsToggle 与 wireShape 永不自相矛盾（两处判一次就会漂移）")
    func toggleIsDerivedFromShape() {
        let combos = [("deepseek", "deepseek-v4-flash"), ("deepseek", "deepseek-chat"),
                      ("qwen", "qwen3-max"), ("qwen", "qwen-max-latest"),
                      ("claude", "claude-sonnet-4-6"), ("minimax", "MiniMax-M2.7")]
        for (p, m) in combos {
            let shape = AIThinkingPolicy.wireShape(provider: p, model: m)
            #expect(AIThinkingPolicy.supportsToggle(provider: p, model: m) == (shape != .none),
                   "\(p)/\(m)")
        }
    }

    @Test("TC-T06 开思考时 DeepSeek V4 的额度必须抬高；不支持开关的组合不许抬")
    func budgetRaisesOnlyWhenThinkingActuallyRuns() {
        #expect(AIThinkingPolicy.maxOutputTokens(provider: "deepseek", model: "deepseek-v4-flash",
                                                thinkingEnabled: true) > 8_192)
        // 关键对照：同样开思考，但这颗压根发不出开关 ⇒ 抬额度没有依据（不验证过的数不改）
        #expect(AIThinkingPolicy.maxOutputTokens(provider: "deepseek", model: "deepseek-chat",
                                                 thinkingEnabled: true) == 8_192)
    }

    @Test("TC-T07 关思考时 DeepSeek 回到 8192 —— 正文独享额度，失败形状随之消失")
    func thinkingOffKeepsBaselineBudget() {
        #expect(AIThinkingPolicy.maxOutputTokens(provider: "deepseek", model: "deepseek-v4-flash",
                                                thinkingEnabled: false) == 8_192)
    }

    @Test("TC-T08 原表里的其它 provider 值一字不动（不能顺手把谁调小）")
    func otherProvidersKeepTheirExistingCaps() {
        for model in ["MiniMax-M2.7", "任意"] {
            #expect(AIThinkingPolicy.maxOutputTokens(provider: "minimax", model: model,
                                                    thinkingEnabled: false) == 16_384)
            #expect(AIThinkingPolicy.maxOutputTokens(provider: "minimax", model: model,
                                                    thinkingEnabled: true) == 16_384)
        }
        #expect(AIThinkingPolicy.maxOutputTokens(provider: "claude_relay", model: "claude-sonnet-4-6",
                                                thinkingEnabled: false) == 16_384)
        #expect(AIThinkingPolicy.maxOutputTokens(provider: "qwen", model: "qwen3-max",
                                                thinkingEnabled: false) == 8_192)
        #expect(AIThinkingPolicy.maxOutputTokens(provider: "custom", model: "x",
                                                thinkingEnabled: false) == 8_192)
    }
}
