import Testing
@testable import MixCutCore

/// 分镜规划的契约测试。
///
/// 数值全部来自 2026-10-09 真实库基线（165 条素材、164 条同参数 scene 读数），
/// 不是凭手感：`segs > sents` 只命中 2/165（故废弃），`segs > scene+1` 命中 41% 且其中
/// 40 条是一镜到底口播（故 scene 轴转作连贯性信息，不当合并判据），全库 `<2s` 段为 0
/// （故 2.0s 兜底不动）。fixture 只用来钉规则形状，不是线上证据。
@Suite("分镜规划 SegmentationPlanner")
struct SegmentationPlannerTests {

    private func timing(_ start: Double, _ end: Double) -> SegmentTiming {
        SegmentTiming(start: start, end: end, scoreFromModel: true)
    }

    /// 把一串长度摊成首尾相接的分镜
    private func contiguous(_ lengths: [Double], from start: Double = 0) -> [SegmentTiming] {
        var cursor = start
        return lengths.map { len in
            let seg = timing(cursor, cursor + len)
            cursor += len
            return seg
        }
    }

    // MARK: 整片保留（必须能在调模型之前判定）

    @Test("TC-P01 恰好 10.0s 且 6 句 → 整片保留")
    func keepsAtExactBoundary() {
        #expect(SegmentationPlanner.shouldKeepWholeVideo(duration: 10.0, sentenceCount: 6))
    }

    @Test("TC-P02 10.01s 就不保留（下限只包到 10s）")
    func rejectsJustOverBoundary() {
        #expect(!SegmentationPlanner.shouldKeepWholeVideo(duration: 10.01, sentenceCount: 6))
    }

    @Test("TC-P03 句子数超预算（7 句）→ 不压，保住时间粒度")
    func rejectsWhenSentencesExceedBudget() {
        #expect(!SegmentationPlanner.shouldKeepWholeVideo(duration: 9.0, sentenceCount: 7))
        #expect(SegmentationPlanner.shouldKeepWholeVideo(duration: 9.0, sentenceCount: 6))
    }

    @Test("TC-P04 句子数为 0 不是短片是没数据；时长 ≤0 同样不保留")
    func rejectsUntrustworthyInputs() {
        #expect(!SegmentationPlanner.shouldKeepWholeVideo(duration: 5.0, sentenceCount: 0))
        #expect(!SegmentationPlanner.shouldKeepWholeVideo(duration: 0, sentenceCount: 3))
        #expect(!SegmentationPlanner.shouldKeepWholeVideo(duration: -1, sentenceCount: 3))
    }

    @Test("TC-P05 阈值是入参不是硬编码：改 config 判定就得跟着变")
    func thresholdsAreInjectedNotBaked() {
        var cfg = SegmentationPlanConfig()
        cfg.wholeVideoMaxSeconds = 20
        cfg.wholeVideoMaxSentences = 12
        #expect(SegmentationPlanner.shouldKeepWholeVideo(duration: 18.0, sentenceCount: 10, in: cfg))
        #expect(!SegmentationPlanner.shouldKeepWholeVideo(duration: 18.0, sentenceCount: 10))
    }

    // MARK: 过碎判据（取代"段数 > 句子数"那条死规则）

    @Test("TC-P06 平均段长 ≥ 3.5s → 一条都不动")
    func leavesHealthyPartitionAlone() {
        let segs = contiguous([4.0, 5.0, 6.0])
        let plan = SegmentationPlanner.plan(segments: segs, duration: 15.0)
        #expect(plan.groups == [[0], [1], [2]])
        #expect(plan.appliedRules.isEmpty)
    }

    @Test("TC-P07 平均段长 2.0s → 相邻并回，每组成 ≥3.5s")
    func mergesFragmentedPartition() {
        let segs = contiguous([2.0, 2.0, 2.0, 2.0, 2.0, 2.0])
        let plan = SegmentationPlanner.plan(segments: segs, duration: 12.0)
        #expect(plan.groups.count == 3)
        #expect(plan.appliedRules == [.fragmentedMerged])
        let lengths = plan.groups.map { g in segs[g.last!].end - segs[g.first!].start }
        #expect(lengths.allSatisfy { $0 >= 3.5 - 0.005 })
    }

    @Test("TC-P08 最小干预：一达到下限就收组，不凑满上限")
    func mergeIsMinimalNotMaximalPacking() {
        let segs = contiguous(Array(repeating: 3.4, count: 6))
        let plan = SegmentationPlanner.plan(segments: segs, duration: 20.4)
        // 两两成组（6.8s 已达 3.5s 下限即收口），不是 5×3.4=17s 凑到上限才收
        #expect(plan.groups == [[0, 1], [2, 3], [4, 5]])
    }

    @Test("TC-P08b 上限只当硬护栏：装不下就当场切组，且没有组超上限")
    func capActsAsHardGuard() {
        let segs = contiguous(Array(repeating: 3.4, count: 6))
        var tight = SegmentationPlanConfig()
        tight.minAverageSegmentSeconds = 8.0    // 想攒到 8s 才收口
        tight.segmentSecondsCap = 7.0           // 但上限只有 7s ⇒ 3×3.4=10.2 装不下
        let plan = SegmentationPlanner.plan(segments: segs, duration: 20.4, in: tight)
        let lengths = plan.groups.map { segs[$0.last!].end - segs[$0.first!].start }
        #expect(lengths.allSatisfy { $0 <= 7.0 + 0.005 })
        #expect(plan.groups.count == 3)
        // 若护栏失效（照 8s 收口）会切成两两…不，会变成 [[0,1,2],[3,4,5]]，组数=2 —— 这条正是那面的刀
        #expect(plan.groups.flatMap { $0 } == Array(0..<6))
    }

    @Test("TC-P09 收尾碎尾并进前组；撞上限则宁可独立")
    func handlesShortTail() {
        let merged = SegmentationPlanner.plan(segments: contiguous([2.0, 2.0, 0.5]), duration: 4.5)
        #expect(merged.groups == [[0, 1, 2]])

        var tight = SegmentationPlanConfig()
        tight.segmentSecondsCap = 4.2          // 4.0 + 0.5 会超
        tight.minAverageSegmentSeconds = 3.5
        let kept = SegmentationPlanner.plan(segments: contiguous([2.0, 2.0, 0.5]), duration: 4.5, in: tight)
        #expect(kept.groups == [[0, 1], [2]])
    }

    @Test("TC-P10 退化形状不许崩：空集、单条、全部超短")
    func degenerateShapes() {
        #expect(SegmentationPlanner.plan(segments: [], duration: 0).groups.isEmpty)
        let single = contiguous([1.0])
        #expect(SegmentationPlanner.plan(segments: single, duration: 1.0).groups == [[0]])
        let allTiny = contiguous([0.3, 0.3, 0.3])
        let plan = SegmentationPlanner.plan(segments: allTiny, duration: 0.9)
        // 攒不满 3.5s 也不许丢下标：分组必须恰好覆盖 0/1/2
        #expect(plan.groups.flatMap { $0 }.sorted() == [0, 1, 2])
    }

    @Test("TC-P11 分组保序且不重不漏（防「改完段数对，顺序却乱了」）")
    func groupsAreOrderPreservingCovering() {
        let segs = contiguous(Array(repeating: 1.5, count: 9))
        let plan = SegmentationPlanner.plan(segments: segs, duration: 13.5)
        let flat = plan.groups.flatMap { $0 }
        #expect(flat == (0..<9).map { $0 })          // 有序
        #expect(Set(flat).count == 9)                 // 不重
    }

    @Test("TC-P12 判据互斥：把 minAverage 调到 0 就不该有任何合并")
    func ruleAxisIndependentOfOtherAxes() {
        var cfg = SegmentationPlanConfig()
        cfg.minAverageSegmentSeconds = 0
        let plan = SegmentationPlanner.plan(segments: contiguous([2.0, 2.0, 2.0]), duration: 6.0, in: cfg)
        #expect(plan.groups == [[0], [1], [2]])
        #expect(plan.appliedRules.isEmpty)
    }

    // MARK: 区间换算

    @Test("TC-P13 末段区间被拉到片尾，前面各组保持原边界")
    func intervalsTileTheVideo() {
        let segs = contiguous([2.0, 2.0, 2.0])
        let plan = SegmentationPlanner.plan(segments: segs, duration: 6.9)   // 片长比段和更长
        let iv = SegmentationPlanner.intervals(of: plan, segments: segs, duration: 6.9)
        #expect(iv.count == plan.groups.count)
        #expect(iv.first?.start == 0.0)
        #expect(abs((iv.last?.end ?? 0) - 6.9) < 0.005)
    }

    @Test("TC-P14 越界下标（解码丢条留下的洞）被跳过而不是崩")
    func intervalsSkipOutOfRangeIndices() {
        let segs = contiguous([2.0, 2.0])
        let plan = SegmentationPlan(groups: [[0], [1], [7]])
        let iv = SegmentationPlanner.intervals(of: plan, segments: segs, duration: 4.0)
        #expect(iv.count == 2)
    }

    // MARK: 单一真源

    @Test("TC-P15 段长上限复用唯一那处定义，不在规划层重抄一个数")
    func capComesFromSingleSource() {
        #expect(SegmentationPlanConfig().segmentSecondsCap == SegmentationCompleteness.promptSegmentLimit)
        #expect(SegmentationPlanConfig().minSegmentSeconds == 2.0)
    }

    // MARK: prompt 同源（模型听到的秒数 == 代码判的秒数）

    @Test("TC-P16 prompt 粒度段的数字全部来自 config，改一处文本就跟着变")
    func promptBlockIsGeneratedFromConfig() {
        var cfg = SegmentationPlanConfig()
        cfg.suggestedSegmentSeconds = 4...12
        cfg.segmentSecondsCap = 14
        let block = cfg.granularityPromptBlock()
        #expect(block.contains("4-12 秒"))
        #expect(block.contains("不得超过 14 秒"))
        #expect(!block.contains("3-15"))
        #expect(!block.contains("18 秒"))
    }

    @Test("TC-P17 默认文本与历史 prompt 逐字一致（同源不许偷偷改口）")
    func defaultBlockMatchesWhatThePromptSaidBefore() {
        let block = SegmentationPlanConfig().granularityPromptBlock()
        #expect(block.contains("- 目标片段时长：3-15 秒（语义完整性优先于时长）"))
        #expect(block.contains("**硬性上限：任何单个片段不得超过 18 秒**"))
        #expect(block.contains("- 短视频（< 40s）：平均 5-8s/片段"))
        #expect(block.contains("- 中视频（40-80s）：平均 6-12s/片段"))
        #expect(block.contains("- 长视频（> 80s）：平均 8-15s/片段"))
    }

    @Test("TC-P18 各档区间标签取自己前一档的上界，不写死也不串档")
    func bandScopeFollowsPreviousBand() {
        var cfg = SegmentationPlanConfig()
        cfg.granularityBands = [
            GranularityBand(videoMaxSeconds: 30, label: "短视频", minAverageSeconds: 4, maxAverageSeconds: 7),
            GranularityBand(videoMaxSeconds: .infinity, label: "长视频", minAverageSeconds: 9, maxAverageSeconds: 14),
        ]
        let block = cfg.granularityPromptBlock()
        #expect(block.contains("短视频（< 30s）：平均 4-7s/片段"))
        #expect(block.contains("长视频（> 30s）：平均 9-14s/片段"))
    }

    @Test("TC-P19 提示给模型的最小说片长与规划层下限同源")
    func minSizeHintSharesTheFloor() {
        let block = SegmentationPlanConfig().granularityPromptBlock()
        #expect(block.contains("短于 2 秒的片段几乎一定会被后处理并回相邻段"))
        var cfg = SegmentationPlanConfig()
        cfg.minSegmentSeconds = 6          // 提示应跟 minAverage(3.5) 取小的那个，不是 6
        #expect(cfg.granularityPromptBlock().contains("短于 3.5 秒"))
    }
    // MARK: 超长再切（与过碎合并对称；2026-10-09 实测误杀之后补的轴）

    @Test("TC-P20 不超过上限的段一律原样带走，origin 就是它自己的下标")
    func shortSegmentsAreUntouched() {
        let segs = contiguous([5, 12, 8])
        let split = SegmentationPlanner.splitOverLong(segments: segs, sentenceEdges: [3, 6, 20])
        #expect(split.count == 3)
        #expect(split.map(\.origin) == [0, 1, 2])
        #expect(split.map(\.timing) == segs)
    }

    @Test("TC-P21 真机那次形状：尾段 24.2s 超 18s ⇒ 在句边界切成两块，两块都合规")
    func splitsTheRealTailSegment() {
        let tail = timing(117.6, 141.8)                       // 实测第 16 段
        let split = SegmentationPlanner.splitOverLong(segments: [tail],
                                                      sentenceEdges: [120.0, 126.5, 132.1, 138.0])
        let shapes = split.map { "\($0.timing.start)-\($0.timing.end)" }
        #expect(split.count == 2, "实际：\(shapes)")
        for piece in split {
            let len = piece.timing.end - piece.timing.start
            #expect(len <= 18.0 + 0.001, "块长 \(len) 仍超上限")
            #expect(len >= 2.0, "块长 \(len) 低于下限")
            #expect(piece.origin == 0)                        // 两块都记得自己来自第 0 条提案
        }
        #expect(split[0].timing.start == 117.6)
        #expect(split.last!.timing.end == 141.8)              // 区间守恒：不许吞掉片尾
    }

    @Test("TC-P22 贪心取装得下的最后一个边界 ⇒ 块数最少且每块合规")
    func usesFewestPieces() {
        let segs = [timing(0, 50)]
        let edges = stride(from: 2.0, through: 48.0, by: 2.0).map { $0 }
        let split = SegmentationPlanner.splitOverLong(segments: segs, sentenceEdges: edges)
        #expect(split.count == 3, "ceil(50/18)=3，实际 \(split.count)")
        for piece in split {
            let len = piece.timing.end - piece.timing.start
            #expect(len <= 18.0 + 0.001 && len >= 2.0, "块长 \(len) 不合规")
        }
        // 首尾相接：不许出现空洞或重叠
        for i in 1..<split.count {
            #expect(split[i].timing.start == split[i - 1].timing.end)
        }
    }

    @Test("TC-P23 段内没有合法边界就原样返回 —— 绝不为了把数字做达标而凭空造刀")
    func neverInventsACut() {
        let segs = [timing(0, 18.5)]
        // 17.0 会让剩下那块只有 1.5s（低于 2s 下限）⇒ 不算合法；1.0 又太靠前
        let split = SegmentationPlanner.splitOverLong(segments: segs, sentenceEdges: [1.0, 17.0])
        let shapes = split.map { "\($0.timing.start)-\($0.timing.end)" }
        #expect(split.count == 1, "实际：\(shapes)")
        #expect(split[0].timing == segs[0])
    }

    @Test("TC-P24 边界必须严格晚于「起点+最短段」，恰好在 2.0s 上不算")
    func edgeMustBeStrictlyInsideTheFloor() {
        let split = SegmentationPlanner.splitOverLong(segments: [timing(0, 20)],
                                                      sentenceEdges: [2.0])
        #expect(split.count == 1, "2.0 处切会让首块正好 2s；边界要求严格大于，不许切")
    }

    @Test("TC-P25 只有被切过的那条会多出来，其它段的 origin 不许漂")
    func originsStayAlignedPerSegment() {
        let segs = contiguous([6, 30, 4])
        let split = SegmentationPlanner.splitOverLong(segments: segs,
                                                      sentenceEdges: [10.0, 22.0, 34.0])
        #expect(split.map(\.origin).first == 0)
        #expect(split.filter { $0.origin == 1 }.count > 1, "第 1 条 30s 必须被切")
        #expect(split.last!.origin == 2)
        #expect(split.filter { $0.origin == 2 }.count == 1)
    }

    @Test("TC-P26 切完再走合并规划：分组下标仍然覆盖全部块，不吞段也不重段")
    func plannedGroupsCoverEveryPiece() {
        let segs = contiguous([24.2, 3.0, 2.5])
        let split = SegmentationPlanner.splitOverLong(segments: segs,
                                                      sentenceEdges: [12.0, 20.0, 30.0, 32.0])
        let plan = SegmentationPlanner.plan(segments: split.map(\.timing), duration: 33.2)
        let flattened = plan.groups.flatMap { $0 }
        #expect(flattened.sorted() == Array(0..<split.count), "实际：\(flattened)")
    }

    @Test("TC-P27 规则名册长出一颗，且给用户看的文案是「超长再切」")
    func ruleRosterGrowsOneEntry() {
        #expect(SegmentationRule.allCases.count == 3)
        #expect(SegmentationRule.overLongSplit.displayName == "超长再切")
        let raws = SegmentationRule.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "实际：\(raws)")
    }

    @Test("TC-P28 分数从被切的提案继承，不许在切刀处换成别的来源")
    func scoresSurviveTheCut() {
        let seg = SegmentTiming(start: 100, end: 124, scoreFromModel: true)
        let split = SegmentationPlanner.splitOverLong(segments: [seg], sentenceEdges: [112])
        #expect(split.count == 2)
        #expect(split.allSatisfy { $0.timing.scoreFromModel == true })
    }
}

