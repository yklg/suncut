import Foundation
import Testing
@testable import MixCutCore

// V-4：概览投影「剪与算」的纯判据（计划 2026-10-23 笔 V2/V-4）。
// 这颗必须证明「只剪 rows 不重算 segmentCount」会被抓出来 —— 否则概览上方两张卡
// 与下方卡片列表会各说一套数。

struct OverviewProjectionPruneTests {

    private func video(_ id: UUID, _ segments: Int, card: Bool = true) -> OverviewProjectionPrune.VideoCount {
        .init(id: id, visibleSegmentCount: segments, showsAsCard: card)
    }

    @Test("空摘除：videoCount 只数卡片行，segmentCount 含自建分镜视频")
    func emptyRemovalKeepsBothCalleis() {
        let a = UUID(), b = UUID(), selfBuilt = UUID()
        let counts = OverviewProjectionPrune.counts(
            removing: [],
            from: [video(a, 5), video(b, 3), video(selfBuilt, 7, card: false)])
        #expect(counts.videoCount == 2, "自建分镜视频不进视频卡，但仍计入分镜")
        #expect(counts.segmentCount == 15)
    }

    @Test("摘掉一张卡片：videoCount 与 segmentCount 同时减")
    func removingCardRowDecrementsBoth() {
        let a = UUID(), b = UUID()
        let counts = OverviewProjectionPrune.counts(
            removing: [a],
            from: [video(a, 5), video(b, 3)])
        #expect(counts.videoCount == 1)
        #expect(counts.segmentCount == 3)
    }

    @Test("摘掉自建分镜视频：只减 segmentCount，videoCount 不动")
    func removingHiddenRowOnlyDecrementsSegments() {
        let a = UUID(), selfBuilt = UUID()
        let counts = OverviewProjectionPrune.counts(
            removing: [selfBuilt],
            from: [video(a, 5), video(selfBuilt, 7, card: false)])
        #expect(counts.videoCount == 1)
        #expect(counts.segmentCount == 5, "自建分镜在分镜统计里，摘掉它必须减；视频卡数不受影响")
    }

    @Test("未知 id 与重复 id 都不改变结果")
    func unknownAndDuplicateIDsAreNoOps() {
        let a = UUID()
        let rows = [video(a, 4)]
        let counts = OverviewProjectionPrune.counts(removing: [UUID(), UUID()], from: rows)
        #expect(counts == .init(videoCount: 1, segmentCount: 4))
    }

    @Test("变异腿：只按卡片行重算 segmentCount 会丢自建分镜 —— 判据必须咬住这个错法")
    func naiveCardOnlyRecountLosesSelfBuiltSegments() {
        let a = UUID(), selfBuilt = UUID()
        let rows = [video(a, 5), video(selfBuilt, 7, card: false)]
        let correct = OverviewProjectionPrune.counts(removing: [a], from: rows)
        // 错法：只拿卡片行（selfBuilt 不在其中）做剪枝后求和。
        let cardOnly = rows.filter(\.showsAsCard).filter { $0.id != a }
        let wrong = cardOnly.reduce(0) { $0 + $1.visibleSegmentCount }
        #expect(correct.segmentCount == wrong + 7,
                "正确口径必须包含自建分镜的那 7 条；错法恰好少算它 ⇒ 这条变异腿就是为了让错法红")
    }
}
