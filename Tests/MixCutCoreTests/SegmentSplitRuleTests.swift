import Testing
@testable import MixCutCore

/// 拆分合法性规则。核心主张只有一条：**这条规则只能有一份** ——
/// UI 与 MCP 判「这个点能不能拆」必须是同一个函数，否则第二条腿会静默切出零宽度分镜。
@Suite("分镜拆分合法性 SegmentSplitRule")
struct SegmentSplitRuleTests {

    @Test("TC-S01 每段最少帧数按 0.3s 折算，且至少 1 帧")
    func minFramesFollowsFps() {
        #expect(SegmentSplitRule.minFrames(fps: 30) == 9)
        #expect(SegmentSplitRule.minFrames(fps: 25) == 8)     // 0.3×25 = 7.5 → 就近进位
        #expect(SegmentSplitRule.minFrames(fps: 60) == 18)
        #expect(SegmentSplitRule.minFrames(fps: 1) == 1, "低帧率不许取整成 0 帧")
        #expect(SegmentSplitRule.minFrames(fps: 0) == 1)
    }

    @Test("TC-S02 合法区间两端都要留出最短段，边界本身不算合法点")
    func legalRangeKeepsBothEnds() {
        let r = SegmentSplitRule.legalCutRange(startFrame: 100, endFrame: 200, fps: 30)
        #expect(r == 109...191, "实际：\(String(describing: r))")
        #expect(SegmentSplitRule.isLegalCut(109, startFrame: 100, endFrame: 200, fps: 30))
        #expect(SegmentSplitRule.isLegalCut(191, startFrame: 100, endFrame: 200, fps: 30))
        // 108 ⇒ 前段只有 8 帧（0.27s）；192 ⇒ 后段只有 8 帧
        #expect(!SegmentSplitRule.isLegalCut(108, startFrame: 100, endFrame: 200, fps: 30))
        #expect(!SegmentSplitRule.isLegalCut(192, startFrame: 100, endFrame: 200, fps: 30))
    }

    @Test("TC-S03 太短的分镜根本没有合法拆分点，且失败原因要说得出是多少秒")
    func tooShortHasNoLegalPoint() {
        let r = SegmentSplitRule.legalCutRange(startFrame: 100, endFrame: 110, fps: 30)
        #expect(r == nil)
        #expect(!SegmentSplitRule.isLegalCut(105, startFrame: 100, endFrame: 110, fps: 30))
        let why = SegmentSplitRule.refusal(startFrame: 100, endFrame: 110, fps: 30)
        #expect(why.contains("0.33s"), "实际：\(why)")
        #expect(why.contains("不足 0.3 秒"), "实际：\(why)")
    }

    @Test("TC-S04 有解时失败原因报出合法区间（Agent 要能自己改对再重试）")
    func refusalCarriesTheLegalWindow() {
        let why = SegmentSplitRule.refusal(startFrame: 100, endFrame: 200, fps: 30)
        #expect(why.contains("109~191"), "实际：\(why)")
    }

    @Test("TC-S05 零帧与负长度区间不能凭空造出合法点")
    func degenerateRangesRefuse() {
        #expect(SegmentSplitRule.legalCutRange(startFrame: 50, endFrame: 50, fps: 30) == nil)
        #expect(SegmentSplitRule.legalCutRange(startFrame: 60, endFrame: 50, fps: 30) == nil)
        #expect(SegmentSplitRule.legalCutRange(startFrame: 0, endFrame: 1000, fps: 0) != nil)
    }

    @Test("TC-S06 与收口前 UI 里那份逐字等价（抽规则不许改行为）")
    func equivalentToTheOldInlineFormula() {
        for fps in [1.0, 12.0, 25.0, 29.97, 30.0, 60.0] {
            for span in [0, 1, 5, 17, 18, 19, 20, 30, 240] {
                let start = 100, end = 100 + span
                // 旧写法（SplitSegmentSheet 里的私有变量，原样搬来当对照）
                let minFrames = max(1, Int((0.3 * fps).rounded()))
                let lo = start + minFrames
                let hi = max(start + minFrames, end - minFrames)
                let old: ClosedRange<Int>? = hi <= lo ? nil : lo...hi
                #expect(SegmentSplitRule.legalCutRange(startFrame: start, endFrame: end,
                                                       fps: fps) == old,
                        "fps=\(fps) span=\(span) 分家了")
            }
        }
    }
}
