import Testing
@testable import MixCutCore

@Suite("RewritePromptBuilder")
struct RewritePromptBuilderTests {
    private var sampleInputs: [RewriteSegmentInput] {
        [
            // 原台词 10 字 → forOriginalLength(10) = 区间 10~12
            RewriteSegmentInput(segmentId: "s1", originalText: "补水保湿一整天超划算", durationSeconds: 3.0, keywords: ["补水", "9.9元"]),
            // 原台词 5 字 → forOriginalLength(5) = 区间 5~6
            RewriteSegmentInput(segmentId: "s2", originalText: "限时抢9块", durationSeconds: 2.0, keywords: [])
        ]
    }

    @Test("占位符被替换，风格与分镜清单注入")
    func substitutesPlaceholders() {
        let tpl = "风格：{{STYLE}}\n分镜：\n{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "快闪风格")
        #expect(!out.contains("{{STYLE}}"))
        #expect(!out.contains("{{SEGMENTS}}"))
        #expect(out.contains("快闪风格"))
    }

    /// 契约：每个分镜的 **id / 长度要求 / 关键词 / 原台词** 都必须进 prompt。
    ///
    /// ⚠️ 2026-10-08：原先这里还断言了「原字数=N字」「N~M字」两个数字。
    /// 那两个数字是**被有意删掉的**——见 `RewritePromptBuilder.build` 的注释：
    /// 把字数区间摆给推理模型，它会去逐条核对（数原文、重算区间、反复确认开头几字），
    /// 实测 `deepseek-v4-flash` 因此烧光 8192 token 在 `reasoning_content` 上、
    /// `content` 为空 ⇒ 用户侧表现为「模型这次没有输出正文」。
    /// 字数改由 `RewriteResultMapper` 按 `CharBudget` **在代码侧**校验（越界重试），
    /// 不再让模型自己数。
    ///
    /// 本用例断言的语义（关键事实不丢）**未变**，只是不再钉「必须出现数字区间」，
    /// 并补一条反向断言：数字区间**不该**回到 prompt 里。
    @Test("每个分镜的 id / 长度要求 / 关键词 / 原台词都进入 prompt（且不再回退到数字区间）")
    func includesPerSegmentFacts() {
        let tpl = "{{SEGMENTS}}"
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs, style: "x")
        // 核心契约：逐分镜的关键事实一个都不能丢
        #expect(out.contains("s1"))
        #expect(out.contains("s2"))
        #expect(out.contains("补水"))
        #expect(out.contains("9.9元"))
        #expect(out.contains("补水保湿一整天超划算"))
        #expect(out.contains("无")) // s2 无关键词
        #expect(out.contains("长度与原台词相当"))

        // 反向断言（防回归）：数字字数区间**不允许**回到 prompt。
        // 一旦回退，推理模型就会重新开始逐字数字数 ⇒ 正文被思考挤空。
        #expect(!out.contains("原字数="), "prompt 不得再出现「原字数=N字」这类精确数字")
        #expect(!out.contains("允许 "), "prompt 不得再出现「允许区间」表述")
    }

    // MARK: - RewriteStylePlan 风格轮次编排

    @Test("风格计划：base0/K5/池5 → 顺序 0...4")
    func stylePlanBaseZero() {
        #expect(RewriteStylePlan.roundIndices(base: 0, rounds: 5, poolCount: 5) == [0, 1, 2, 3, 4])
    }

    @Test("风格计划：偏移起点保持同序回绕且一轮内不重复（K≤池）")
    func stylePlanOffset() {
        #expect(RewriteStylePlan.roundIndices(base: 2, rounds: 5, poolCount: 5) == [2, 3, 4, 0, 1])
    }

    @Test("风格计划：零轮次 / 零池 → 空数组（不崩）")
    func stylePlanEmpty() {
        #expect(RewriteStylePlan.roundIndices(base: 0, rounds: 0, poolCount: 5) == [])
        #expect(RewriteStylePlan.roundIndices(base: 0, rounds: 5, poolCount: 0) == [])
    }

    @Test("风格计划：K 超过池长时显式回绕")
    func stylePlanWrapsBeyondPool() {
        #expect(RewriteStylePlan.roundIndices(base: 2, rounds: 7, poolCount: 5) == [2, 3, 4, 0, 1, 2, 3])
    }

    @Test("风格计划：任意合法 base × K，恒有 K 个且第 j 个=(base+j)%池",
          arguments: [0, 1, 2, 3, 4], [1, 2, 3, 4, 5])
    func stylePlanInvariant(base: Int, k: Int) {
        let out = RewriteStylePlan.roundIndices(base: base, rounds: k, poolCount: 5)
        #expect(out.count == k)
        #expect(out == (0..<k).map { (base + $0) % 5 })
    }

    // MARK: - cappedPriors 历史轮次截断

    private func roundWith(textChars: Int, id: String = "s1") -> RewritePriorVersion {
        RewritePriorVersion(segmentId: id, rewrittenText: String(repeating: "字", count: textChars))
    }

    @Test("截断：空轮次 → 空")
    func capEmpty() {
        #expect(RewritePromptBuilder.cappedPriors([]) == [])
    }

    @Test("截断：≤3 轮且不超字符 → 原样保序")
    func capWithinLimits() {
        let rounds: [[RewritePriorVersion]] = [
            [roundWith(textChars: 10, id: "s1")],
            [roundWith(textChars: 20, id: "s1")],
            [roundWith(textChars: 30, id: "s1")]
        ]
        let out = RewritePromptBuilder.cappedPriors(rounds)
        #expect(out.count == 3)
        #expect(out[0][0].rewrittenText.count == 10)
        #expect(out[2][0].rewrittenText.count == 30)
    }

    @Test("截断：超 maxRounds → 只保留最近 3 轮，最旧被丢，顺序不变")
    func capKeepsLatestRounds() {
        let rounds = (1...5).map { [roundWith(textChars: 10, id: "r\($0)")] }
        let out = RewritePromptBuilder.cappedPriors(rounds)
        #expect(out.count == 3)
        #expect(out.flatMap { $0 }.map(\.segmentId) == ["r3", "r4", "r5"])
    }

    @Test("截断：超字符预算时整轮丢弃，保留的轮文本完整（不切半轮）")
    func capWholeRoundCharBudget() {
        // 10 + 10 + 100 = 120；预算 100：丢第 1 轮(10) 仍 110，再丢第 2 轮，留 100 字整轮
        let rounds: [[RewritePriorVersion]] = [
            [roundWith(textChars: 10, id: "a")],
            [roundWith(textChars: 10, id: "b")],
            [roundWith(textChars: 100, id: "c")]
        ]
        let out = RewritePromptBuilder.cappedPriors(rounds, maxRounds: 3, maxChars: 100)
        #expect(out.count == 1)
        #expect(out[0].map(\.segmentId) == ["c"])
        #expect(out[0][0].rewrittenText.count == 100)
    }

    @Test("截断：单分镜真实规模（3 轮 × 约 50 字）在默认阈值下不触发")
    func capSingleSegmentRealScale() {
        let rounds = (0..<3).map { _ in [roundWith(textChars: 50)] }
        let out = RewritePromptBuilder.cappedPriors(rounds)
        #expect(out.count == 3)
    }

    @Test("截断：双约束顺序固定——先最近 N 轮，再在其中从最旧按字符丢")
    func capDualConstraintsOrder() {
        // 5 轮 × 3000 字：先取最近 3 轮（9000 > 6000），丢其中最旧一轮（→6000），留最近 2 轮
        let rounds = (1...5).map { [roundWith(textChars: 3000, id: "r\($0)")] }
        let out = RewritePromptBuilder.cappedPriors(rounds)
        #expect(out.flatMap { $0 }.map(\.segmentId) == ["r4", "r5"])
    }

    // MARK: - assemblePriors 轮次组装（覆盖旧 k 版优先）

    private func seedMap(_ indices: [Int], id: String = "s1") -> [Int: [RewritePriorVersion]] {
        Dictionary(uniqueKeysWithValues: indices.map {
            ($0, [RewritePriorVersion(segmentId: id, rewrittenText: "旧版\($0)")])
        })
    }

    @Test("组装：5 存量轮、K=2 首轮(k=0)——截断后必须保住将被覆盖的旧 0 版")
    func assembleKeepsOverwrittenSeedAtFirstRound() {
        let out = RewritePromptBuilder.assemblePriors(
            seedIndices: [0, 1, 2, 3, 4], seedRounds: seedMap([0, 1, 2, 3, 4]),
            currentIndex: 0, freshRounds: [])
        let texts = out.flatMap { $0 }.map(\.rewrittenText)
        #expect(texts.contains("旧版0"), "即将被覆盖的旧 0 版不能被截断丢弃：\(texts)")
        #expect(out.count <= RewritePromptBuilder.priorMaxRounds)
    }

    @Test("组装：k=1 时旧 1 版与同次新产出的第 0 轮都在窗口内")
    func assembleKeepsOverwrittenAndFresh() {
        let fresh: [[RewritePriorVersion]] = [
            [RewritePriorVersion(segmentId: "s1", rewrittenText: "新版0")]
        ]
        let out = RewritePromptBuilder.assemblePriors(
            seedIndices: [0, 1, 2, 3, 4], seedRounds: seedMap([0, 1, 2, 3, 4]),
            currentIndex: 1, freshRounds: fresh)
        let texts = out.flatMap { $0 }.map(\.rewrittenText)
        #expect(texts.contains("旧版1"))
        #expect(texts.contains("新版0"))
        // 最新产出必须排在最末（下一轮的最高优先级互斥对象）
        #expect(out.last?.first?.rewrittenText == "新版0")
    }

    @Test("组装：无存量时只透传新轮次；无任何历史时为空")
    func assembleEmptySeed() {
        let fresh: [[RewritePriorVersion]] = [
            [RewritePriorVersion(segmentId: "s1", rewrittenText: "新")]
        ]
        let withFresh = RewritePromptBuilder.assemblePriors(
            seedIndices: [], seedRounds: [:], currentIndex: 0, freshRounds: fresh)
        #expect(withFresh.count == 1)
        let empty = RewritePromptBuilder.assemblePriors(
            seedIndices: [], seedRounds: [:], currentIndex: 0, freshRounds: [])
        #expect(empty.isEmpty)
    }

    @Test("组装：currentIndex 不在存量中（新增档位）时按升序+新轮次排列")
    func assembleCurrentIndexAbsent() {
        let out = RewritePromptBuilder.assemblePriors(
            seedIndices: [0, 1], seedRounds: seedMap([0, 1]),
            currentIndex: 4, freshRounds: [])
        #expect(out.flatMap { $0 }.map(\.rewrittenText) == ["旧版0", "旧版1"])
    }

    // MARK: - priorVersions prompt 注入

    private let priorTpl = """
    风格：{{STYLE}}
    分镜：
    {{SEGMENTS}}
    历史：
    {{PRIOR_VERSIONS}}
    """

    @Test("注入：非空 prior → 占位符消失，含版本序号与历史文本")
    func priorsRendered() {
        let priors: [[RewritePriorVersion]] = [
            [RewritePriorVersion(segmentId: "s1", rewrittenText: "历史改写一句")]
        ]
        let out = RewritePromptBuilder.build(template: priorTpl, inputs: sampleInputs,
                                             style: "x", priorVersions: priors)
        #expect(!out.contains("{{PRIOR_VERSIONS}}"))
        #expect(out.contains("历史版本 1"))
        #expect(out.contains("历史改写一句"))
    }

    @Test("注入：空 prior → 首轮占位文案，无占位符残留")
    func priorsEmptyRendersFirstRoundNote() {
        let out = RewritePromptBuilder.build(template: priorTpl, inputs: sampleInputs,
                                             style: "x", priorVersions: [])
        #expect(!out.contains("{{PRIOR_VERSIONS}}"))
        #expect(out.contains("第一版"))
    }

    @Test("注入：轮内按 inputs 顺序对齐，乱序传入也先渲染 s1 再 s2")
    func priorsAlignedToInputsOrder() {
        let priors: [[RewritePriorVersion]] = [
            [RewritePriorVersion(segmentId: "s2", rewrittenText: "乙版本"),
             RewritePriorVersion(segmentId: "s1", rewrittenText: "甲版本")]
        ]
        let out = RewritePromptBuilder.build(template: priorTpl, inputs: sampleInputs,
                                             style: "x", priorVersions: priors)
        guard let lineS1 = out.components(separatedBy: "\n")
            .first(where: { $0.contains("segmentId=s1") }),
              let lineS2 = out.components(separatedBy: "\n")
            .first(where: { $0.contains("segmentId=s2") }) else {
            Issue.record("两个分镜的历史版本行都应存在：\(out)")
            return
        }
        #expect(lineS1 < lineS2)
    }

    @Test("注入：未知 segmentId 的脏数据被忽略，不崩")
    func priorsIgnoreUnknownSegment() {
        let priors: [[RewritePriorVersion]] = [
            [RewritePriorVersion(segmentId: "ghost", rewrittenText: "幽灵文本"),
             RewritePriorVersion(segmentId: "s1", rewrittenText: "有效版本")]
        ]
        let out = RewritePromptBuilder.build(template: priorTpl, inputs: sampleInputs,
                                             style: "x", priorVersions: priors)
        #expect(out.contains("有效版本"))
        #expect(!out.contains("ghost"))
        #expect(!out.contains("幽灵文本"))
    }

    @Test("注入：旧模板无 PRIOR_VERSIONS 占位符时不崩，其余替换正常（向前兼容）")
    func priorsLegacyTemplateCompatible() {
        let tpl = "风格：{{STYLE}}\n分镜：\n{{SEGMENTS}}"
        let priors: [[RewritePriorVersion]] = [
            [RewritePriorVersion(segmentId: "s1", rewrittenText: "历史")]
        ]
        let out = RewritePromptBuilder.build(template: tpl, inputs: sampleInputs,
                                             style: "快闪", priorVersions: priors)
        #expect(out.contains("快闪"))
        #expect(out.contains("s1"))
        #expect(!out.contains("{{"))
    }
}
