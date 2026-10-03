import XCTest
@testable import MixCutCore

final class HoverTipStateTests: XCTestCase {
    /// 进入驻留 → waiting 不显示；驻留到点（同 token）→ visible。
    func testDwellSucceedsWithCurrentToken() {
        var state = HoverTipState()
        XCTAssertFalse(state.isVisible)

        let token = state.hoverBegan()
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(state.isVisible)

        state.succeed(token)
        XCTAssertEqual(state.phase, .visible)
        XCTAssertTrue(state.isVisible)
    }

    /// 驻留未到即离开 → idle；之后旧 token 到点也不能点亮（在途计时作废）。
    func testHoverEndedInvalidatesPendingToken() {
        var state = HoverTipState()
        let token = state.hoverBegan()

        state.hoverEnded()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.isVisible)

        state.succeed(token)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.isVisible)
    }

    /// 再次进入 / 移动后重新驻留：颁发新 token，旧 token 到点被吞，仅最新 token 可点亮。
    func testRestartIssuesNewTokenAndOnlyLatestCanShow() {
        var state = HoverTipState()
        let oldToken = state.hoverBegan()
        let newToken = state.hoverBegan()
        XCTAssertNotEqual(oldToken, newToken)

        // 旧计时晚到 → 被去重
        state.succeed(oldToken)
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(state.isVisible)

        state.succeed(newToken)
        XCTAssertEqual(state.phase, .visible)
        XCTAssertTrue(state.isVisible)
    }
}
