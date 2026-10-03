import Foundation
import Testing
@testable import MixCutCore

/// `BoundaryAdjustLayout` 宽度契约测试。
/// 守卫目标：微调行最小宽落在 Inspector 槽位内；组宽由有序项数组求和派生。
struct BoundaryAdjustLayoutTests {

    @Test("宽度预算：最小行宽 ≤ 槽位可用宽；两值钉为 184 / 312")
    func widthBudgetHolds() {
        #expect(BoundaryAdjustLayout.widthBudgetHolds)
        #expect(BoundaryAdjustLayout.minimumRowWidth == 184)
        #expect(BoundaryAdjustLayout.availableRowWidth == 312)
    }

    @Test("槽位派生：inspectorWidth − padding×2 = availableRowWidth（独立重算防漂移）")
    func availableWidthIsDerivedFromInspector() {
        typealias L = BoundaryAdjustLayout
        let independent = L.inspectorWidth - L.inspectorHorizontalPadding * 2
        #expect(L.availableRowWidth == independent)
    }

    @Test("组宽派生：按 items 独立求和 = timeGroupWidth = 81")
    func groupWidthIsDerivedFromItems() {
        let independent = BoundaryAdjustLayout.timeGroupItems.reduce(0) {
            $0 + BoundaryAdjustLayout.itemWidth($1)
        }
        #expect(BoundaryAdjustLayout.timeGroupWidth == independent)
        #expect(BoundaryAdjustLayout.timeGroupWidth == 81)
    }

    @Test("最小行独立推导：两时间组 + groupGap + menuWidth = minimumRowWidth")
    func minimumWidthIsDerivedFromComponents() {
        typealias L = BoundaryAdjustLayout
        let independent = L.timeGroupWidth * 2 + L.groupGap + L.menuWidth
        #expect(L.minimumRowWidth == independent)
    }

    @Test("项顺序契约：label → adjustButton → timeField → adjustButton")
    func itemOrderContract() {
        #expect(BoundaryAdjustLayout.timeGroupItems == [
            .label, .adjustButton, .timeField, .adjustButton
        ])
    }

    @Test("项宽度钉死：label 10 / adjustButton 14 / timeField 43")
    func itemWidthsArePinned() {
        typealias L = BoundaryAdjustLayout
        #expect(L.itemWidth(.label) == L.labelWidth)
        #expect(L.itemWidth(.adjustButton) == L.adjustButtonWidth)
        #expect(L.itemWidth(.timeField) == L.timeFieldWidth)
        #expect(L.labelWidth == 10)
        #expect(L.adjustButtonWidth == 14)
        #expect(L.timeFieldWidth == 43)
    }

    @Test("槽位常量钉死：inspectorWidth 340 / padding 14 / menu 20 / gap 2")
    func inspectorConstantsArePinned() {
        typealias L = BoundaryAdjustLayout
        #expect(L.inspectorWidth == 340)
        #expect(L.inspectorHorizontalPadding == 14)
        #expect(L.menuWidth == 20)
        #expect(L.groupGap == 2)
    }
}
