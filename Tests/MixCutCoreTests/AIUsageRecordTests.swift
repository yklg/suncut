import Testing
@testable import MixCutCore

/// 用量记录的口径测试。核心主张：**花了钱但白跑的那一笔必须看得见**，
/// 而后端没给的数据**不许被补成 0**。
@Suite("AIUsageRecord 用量与场景")
struct AIUsageRecordTests {

    private func record(usage: AITokenUsage?, outcome: AIUsageRecord.Outcome = .succeeded) -> AIUsageRecord {
        AIUsageRecord(scene: .segmentAnalysis, provider: "DeepSeek", model: "deepseek-v4-flash",
                      thinkingEnabled: false, promptChars: 6393, responseChars: 1364,
                      elapsedSeconds: 27.5, usage: usage, outcome: outcome)
    }

    @Test("TC-U01 场景名册是唯一一份：数量与不重复都被钉住")
    func sceneRosterIsClosed() {
        #expect(AIScene.allCases.count == 10, "实际 \(AIScene.allCases.count)")
        let raws = AIScene.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "实际：\(raws)")
    }

    @Test("TC-U02 usage 整个缺席时报「缺席」，一个 0 都不许出现")
    func missingUsageIsNotZero() {
        let line = record(usage: nil).tokenBreakdown
        #expect(line.contains("缺席"))
        #expect(!line.contains("0"), "实际：\(line)")
    }

    @Test("TC-U03 四项全空的 usage 与「没有 usage 字段」同口径处理")
    func emptyUsageCountsAsMissing() {
        let r = record(usage: AITokenUsage())
        #expect(r.tokenBreakdown.contains("后端未返回 usage"), "实际：\(r.tokenBreakdown)")
    }

    @Test("TC-U04 部分字段缺席时逐项标注，有值的照常写出")
    func partialUsageKeepsItsOwnValues() {
        let r = record(usage: AITokenUsage(promptTokens: 3666, completionTokens: nil, totalTokens: nil))
        let line = r.tokenBreakdown
        #expect(line.contains("prompt=3666"), "实际：\(line)")
        #expect(line.contains("completion=缺席"), "实际：\(line)")
        #expect(line.contains("total=缺席"), "实际：\(line)")
    }

    @Test("TC-U05 reasoning 只在后端真给了的时候出现")
    func reasoningAppearsOnlyWhenReported() {
        let given = record(usage: AITokenUsage(promptTokens: 1, completionTokens: 2,
                                               totalTokens: 3, reasoningTokens: 41))
        #expect(given.tokenBreakdown.contains("reasoning=41"), "实际：\(given.tokenBreakdown)")
        let absent = record(usage: AITokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3))
        #expect(!absent.tokenBreakdown.contains("reasoning"),
                "后端没说就是没说，不许写成缺席：\(absent.tokenBreakdown)")
    }

    @Test("TC-U06 空正文与长度截断都是「已计费但白跑」，成功不是")
    func wastedClassification() {
        #expect(AIUsageRecord.Outcome.succeeded.wasted == false)
        for outcome in [AIUsageRecord.Outcome.emptyBody, .truncated, .unparsable] {
            #expect(outcome.wasted, "\(outcome.rawValue) 必须算白跑")
            let line = record(usage: AITokenUsage(promptTokens: 5483, completionTokens: 8192,
                                                 totalTokens: 13675), outcome: outcome).logLine()
            #expect(line.contains("已计费但白跑"), "实际：\(line)")
        }
    }

    @Test("TC-U07 一行日志把归属、思考状态、耗时、结果、用量五件事都说清")
    func logLineCarriesAllFiveThings() {
        let line = record(usage: AITokenUsage(promptTokens: 3666, completionTokens: 8192,
                                             totalTokens: 11858), outcome: .truncated).logLine()
        for needle in ["[AI用量]", "场景=分镜切分", "model=deepseek-v4-flash", "思考=关",
                       "耗时=27.5s", "结果=长度截断", "prompt=3666"] {
            #expect(line.contains(needle), "缺 \(needle)；实际：\(line)")
        }
    }

    @Test("TC-U08 连接测试这类小额调用也走同一条记录形状（不许有第二条口径）")
    func everySceneUsesTheSameShape() {
        let r = AIUsageRecord(scene: .connectionTest, provider: "千问", model: "qwen-flash",
                              thinkingEnabled: true, promptChars: 20, responseChars: 5,
                              elapsedSeconds: 1.2, usage: nil, outcome: .succeeded)
        let line = r.logLine()
        #expect(line.contains("场景=连接测试"), "实际：\(line)")
        #expect(line.contains("思考=开"), "实际：\(line)")
        #expect(!line.contains("白跑"), "实际：\(line)")
    }
}
