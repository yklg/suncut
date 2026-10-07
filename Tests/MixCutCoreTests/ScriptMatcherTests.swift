import Testing
import Foundation
@testable import MixCutCore

private func uuid(_ s: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(s)")!
}

private func slot(_ s: String, _ order: Int, _ tag: String, _ duration: Double) -> ScriptMatcher.Slot {
    ScriptMatcher.Slot(id: uuid(s), order: order, tag: tag, targetDuration: duration)
}

private func candidate(_ s: String, _ tags: [String], _ duration: Double) -> ScriptMatcher.Candidate {
    ScriptMatcher.Candidate(id: uuid(s), tags: tags, duration: duration)
}

// MARK: - 基本匹配

@Test func matcher_tagAndDurationInWindowMatches() {
    let outcome = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["痛点"], 3.2)])
    #expect(outcome.allMatched)
    guard case .matched(let segmentID) = outcome.results[0] else {
        Issue.record("应为 matched")
        return
    }
    #expect(segmentID == uuid("01"))
    #expect(outcome.conflicts.isEmpty)
}

@Test func matcher_tagMismatchBecomesUnmatched() {
    let outcome = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["产品方案"], 3.0)])
    #expect(outcome.results[0] == .unmatched)
    #expect(!outcome.allMatched)
}

@Test func matcher_durationOutsideWindowBecomesUnmatched() {
    // 目标 3.0，窗口 2.55–3.45；候选 4.0 出窗
    let outcome = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["痛点"], 4.0)])
    #expect(outcome.results[0] == .unmatched)
}

@Test func matcher_durationWindowEdgesAccepted() {
    // ±15% 窗口 2.55–3.45：取窗口内侧安全值 2.56 / 3.44，必须包含。
    // 不用字面量 2.55/3.45：3.0*1.15 的 Double 表示与字面量 3.45 不严格相等（浮点固有现象）。
    let lower = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["痛点"], 2.56)])
    let upper = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["痛点"], 3.44)])
    #expect(lower.allMatched)
    #expect(upper.allMatched)
}

@Test func matcher_durationJustOutsideWindowRejected() {
    // 窗口外的 2.5 / 3.5 必须排除。
    let lower = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["痛点"], 2.5)])
    let upper = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [candidate("01", ["痛点"], 3.5)])
    #expect(lower.results[0] == .unmatched)
    #expect(upper.results[0] == .unmatched)
}

@Test func matcher_multiTagCandidateMatchesAnyListedTag() {
    let outcome = ScriptMatcher.match(
        slots: [slot("01", 1, "噱头引入", 2.0)],
        candidates: [candidate("01", ["噱头引入", "痛点"], 2.0)])
    #expect(outcome.allMatched)
}

// MARK: - 多候选

@Test func matcher_multipleCandidatesReportedAndRankedByDeviation() {
    let outcome = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [
            candidate("01", ["痛点"], 2.9),
            candidate("02", ["痛点"], 3.0),
        ])
    // 无冲突时多候选首选自动锁定
    #expect(outcome.allMatched)
    guard case .matched(let segmentID) = outcome.results[0] else {
        Issue.record("首选应升级 matched")
        return
    }
    #expect(segmentID == uuid("02"))
}

// MARK: - 冲突

@Test func matcher_sameSegmentClaimedByTwoSlotsReportedAsConflict() {
    let outcome = ScriptMatcher.match(
        slots: [
            slot("01", 1, "痛点", 3.0),
            slot("02", 2, "噱头引入", 3.0),
        ],
        candidates: [candidate("01", ["痛点", "噱头引入"], 3.0)])
    #expect(!outcome.allMatched)
    #expect(outcome.conflicts.count == 1)
    #expect(outcome.conflicts[0].segmentID == uuid("01"))
    #expect(Set(outcome.conflicts[0].slotIDs) == [uuid("01"), uuid("02")])
}

@Test func matcher_greedyAssignsDistinctSegmentsWithoutConflict() {
    let outcome = ScriptMatcher.match(
        slots: [
            slot("01", 1, "痛点", 3.0),
            slot("02", 2, "噱头引入", 3.0),
        ],
        candidates: [
            candidate("01", ["痛点"], 3.0),
            candidate("02", ["噱头引入"], 3.0),
        ])
    #expect(outcome.allMatched)
    #expect(outcome.conflicts.isEmpty)
}

// MARK: - 确定性

@Test func matcher_tieScoresStableByID() {
    // 两个偏离度完全相同的候选，两次跑结果必须一致且按 id 升序
    let run1 = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [
            candidate("02", ["痛点"], 3.0),
            candidate("01", ["痛点"], 3.0),
        ])
    let run2 = ScriptMatcher.match(
        slots: [slot("01", 1, "痛点", 3.0)],
        candidates: [
            candidate("01", ["痛点"], 3.0),
            candidate("02", ["痛点"], 3.0),
        ])
    guard case .matched(let id1) = run1.results[0],
          case .matched(let id2) = run2.results[0] else {
        Issue.record("两跑都应 matched")
        return
    }
    #expect(id1 == uuid("01"))
    #expect(id1 == id2)
}

@Test func matcher_zeroTargetDurationMatchesByTagOnly() {
    let outcome = ScriptMatcher.match(
        slots: [slot("01", 1, "过渡", 0)],
        candidates: [
            candidate("01", ["过渡"], 1.0),
            candidate("02", ["过渡"], 9.0),
        ])
    // 无目标时长 → 全部偏离度等价，按 id 升序锁定
    #expect(outcome.allMatched)
    guard case .matched(let segmentID) = outcome.results[0] else { return }
    #expect(segmentID == uuid("01"))
}
