import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// WholeClipShape 判据（W1–W5）。
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md Step 2 的 P0-1 块
//
// 这颗判据从"兜底启发式"被升级成了"承重判定"（R18 摊开的代价①），所以它必须：
//   ① 有独立测试（不靠 MixCutApp 那段自愈代码顺带跑到）；
//   ② 每个容差方向都有一条对照 —— 判假会让混存回来，判真会白删一份切分。
// 段数、起点、终点、时长四个维度各配"稍微不足"与"恰好越界"两侧。
// ============================================================================

struct WholeClipShapeTests {

    private func seg(_ start: Double, _ end: Double) -> WholeClipSegmentShape {
        WholeClipSegmentShape(startTime: start, endTime: end)
    }

    @Test("W1a 一条覆盖整片 ⇒ 真（这就是 C 的载体形态）")
    func singleWholeClipIsTrue() {
        #expect(WholeClipShape.isWholeClip(segments: [seg(0, 47.5)], videoDuration: 47.5))
        #expect(WholeClipShape.isWholeClip(segments: [seg(0, 200)], videoDuration: 200))
    }

    @Test("W1b 没有段 ⇒ 假：真·首跑本来就没有旧段可退，不许白删一次")
    func noSegmentsIsFalse() {
        #expect(!WholeClipShape.isWholeClip(segments: [], videoDuration: 30))
    }

    @Test("W1c 两条及以上 ⇒ 假：已有一份切分，去留归重跑链（:362-367 显式传 true）")
    func multipleSegmentsAreFalse() {
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 15), seg(15, 30)], videoDuration: 30))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 30), seg(0, 30)], videoDuration: 30),
                "两条同边界的重复段也不该被判成整片段（那是另一条缺陷，不该被这里顺手掩盖）")
    }

    @Test("W2 起点两侧：0.005 算贴零，0.5 不算，负数不算（下界是本判定比先例多出来的）")
    func startBoundaryHasTwoSides() {
        #expect(WholeClipShape.isWholeClip(segments: [seg(0.005, 30)], videoDuration: 30),
                "帧边界反推回秒会带量化残差，写成 == 0 会把整片段判假 ⇒ 混存回来")
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0.5, 30)], videoDuration: 30))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(-1, 30)], videoDuration: 30),
                "负起点不是「贴零」，是坏数据")
    }

    @Test("W3 终点容差两侧：短 0.1 秒仍算整片，短 5 秒不算")
    func endBoundaryHasTwoSides() {
        #expect(WholeClipShape.isWholeClip(segments: [seg(0, 29.9)], videoDuration: 30))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 25)], videoDuration: 30))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 35)], videoDuration: 30),
                "超出全片的段说明边界被改过，不该被当成机器整片段删掉")
    }

    @Test("W4 坏时长/坏边界一律判假（拒收发生在比较链上，实测不需要额外预检）")
    func unreadableDurationIsFalse() {
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 30)], videoDuration: 0))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 30)], videoDuration: -3))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 30)], videoDuration: .nan))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, 30)], videoDuration: .infinity))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, .nan)], videoDuration: 30))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(.nan, 30)], videoDuration: 30))
        #expect(!WholeClipShape.isWholeClip(segments: [seg(0, .infinity)], videoDuration: 30))
    }

    @Test("W5 判据只认形状：同形状的来源不同，结果必须相同（④ 公开的代价②）")
    func shapeOnlyJudgementIsSourceAgnostic() {
        // C 的载体、B 自建分镜的载体、母体链"整片保留"的产物，三者形状一致 ⇒ 判定一致。
        // 这条不是"实现没做完"，是 R18 代价表第②格里明说接受的同侧处置。
        let shape = [seg(0, 12.3)]
        #expect(WholeClipShape.isWholeClip(segments: shape, videoDuration: 12.3))
        #expect(WholeClipShape.isWholeClip(segments: shape, videoDuration: 12.35),
                "差 0.05 秒落在容差内 —— 三链路共享同一形状判定")
    }

    @Test("W6 容差常量本身被钉住：改动它等于改动 MixCutApp 的自愈判据口径")
    func tolerancesMatchTheInRepoPrecedent() {
        // 出处 MixCutApp.swift:289 / :290。这里若被单方面改宽，
        // `restoreSelfBuiltFlags` 与首跑清段判定就会分家（两份形状口径）。
        #expect(WholeClipShape.startTolerance == 0.01)
        #expect(WholeClipShape.endTolerance == 0.2)
    }
    @Test("JOIN-27 补建后段数恒 ≥2 ⇒ W1 恒 false，母体首跑与启动回填都不会误命中（跨模块不变量）")
    func backfilledRowKeepsStoryboardIntact() {
        // 这条钉的是「补建不毁用户旧段」这个前提本身：守门用逐段形状问，补完的集合是 N+1 段，
        // 而 W1 要求段数恰好 1 ⇒ clearsExistingSegments 恒 false、`restoreSelfBuiltFlags` 恒不命中。
        // 谁哪天把补建条件放宽（比如允许在空段行上补），这条必须一起改 —— 所以它是判据不是注释。
        let duration = 12.0
        let storyboard = [WholeClipSegmentShape(startTime: 0, endTime: duration / 3),
                          WholeClipSegmentShape(startTime: duration / 3, endTime: duration)]
        #expect(!WholeClipShape.isWholeClip(segments: storyboard, videoDuration: duration),
                "两条切分段本来就不是整片段形态")
        let afterBackfill = storyboard + [WholeClipSegmentShape(startTime: 0, endTime: duration)]
        #expect(!WholeClipShape.isWholeClip(segments: afterBackfill, videoDuration: duration),
                "补建之后集合里多了一条整片段，但 W1 只认「恰好一条」⇒ 首跑不会替用户清旧段")
        #expect(WholeClipShape.isWholeClip(segments: [afterBackfill[2]], videoDuration: duration),
                "混剪要的那颗覆盖全片的段确实在（逐段问，不按集合问）")
    }

}
