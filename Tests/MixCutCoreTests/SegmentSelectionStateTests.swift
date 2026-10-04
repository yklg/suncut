import Foundation
import XCTest
@testable import MixCutCore

/// `SegmentSelectionState` 选中状态机契约测试（S1-S3）。
final class SegmentSelectionStateTests: XCTestCase {

    private let a = UUID(), b = UUID()

    func testInitialResolvedNil() {
        let s = SegmentSelectionState()
        XCTAssertNil(s.pinnedID)
        XCTAssertNil(s.hoveredID)
        XCTAssertNil(s.resolvedID)
        XCTAssertFalse(s.isPinned)
    }

    func testHoverOnlyResolvesHover() {
        var s = SegmentSelectionState()
        s.setHovered(a)
        XCTAssertEqual(s.resolvedID, a)
        XCTAssertFalse(s.isPinned)
    }

    func testPinPromotesAndClearsHover() {
        var s = SegmentSelectionState()
        s.setHovered(a)
        s.pin(a)
        XCTAssertEqual(s.pinnedID, a)
        XCTAssertNil(s.hoveredID, "pin 同源时必须清 hover")
        XCTAssertEqual(s.resolvedID, a)
        XCTAssertTrue(s.isPinned)
    }

    func testPinWinsOverHover() {
        var s = SegmentSelectionState()
        s.pin(a)
        s.setHovered(b)
        XCTAssertEqual(s.resolvedID, a, "pinned 恒优先")
        XCTAssertEqual(s.hoveredID, b)
    }

    func testPinTransfers() {
        var s = SegmentSelectionState()
        s.pin(a)
        s.pin(b)
        XCTAssertEqual(s.pinnedID, b)
        XCTAssertEqual(s.resolvedID, b)
    }

    func testClearPinnedWithNoHoverResolvesNil() {
        var s = SegmentSelectionState()
        s.pin(a)
        s.clearPinned()
        XCTAssertNil(s.pinnedID)
        XCTAssertNil(s.resolvedID)
    }

    func testClearPinnedFallsBackToHoveredThenClearAll() {
        var s = SegmentSelectionState()
        s.pin(a)
        s.setHovered(b)
        s.clearPinned()
        XCTAssertEqual(s.resolvedID, b, "取消 pin 后应回退 hover")
        s.clearAll()
        XCTAssertNil(s.resolvedID)
        XCTAssertNil(s.hoveredID)
    }

    // MARK: PS-1~5 SegmentPruneSignals（剪枝信号状态机）

    private let c = UUID()

    func testPSEmptyNoteIsNoOp() {
        var s = SegmentPruneSignals()
        XCTAssertFalse(s.note([]))
        XCTAssertTrue(s.ids.isEmpty)
        XCTAssertEqual(s.version, 0)
    }

    func testPSNewIDsUnionAndBump() {
        var s = SegmentPruneSignals()
        XCTAssertTrue(s.note([a, b]))
        XCTAssertEqual(s.ids, [a, b])
        XCTAssertEqual(s.version, 1)
    }

    func testPSSameBatchIdempotent() {
        var s = SegmentPruneSignals()
        s.note([a])
        XCTAssertFalse(s.note([a]))
        XCTAssertEqual(s.ids, [a])
        XCTAssertEqual(s.version, 1)
    }

    func testPSDisjointBatchesUnion() {
        var s = SegmentPruneSignals()
        s.note([a])
        XCTAssertTrue(s.note([b, c]))
        XCTAssertEqual(s.ids, [a, b, c])
        XCTAssertEqual(s.version, 2)
    }

    func testPSPartialOverlapAddsOnlyNew() {
        var s = SegmentPruneSignals()
        s.note([a, b])
        XCTAssertTrue(s.note([b, c]))
        XCTAssertEqual(s.ids, [a, b, c])
        XCTAssertEqual(s.version, 2)
    }
}
