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
}
