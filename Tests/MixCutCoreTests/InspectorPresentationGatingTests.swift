import Foundation
import Testing
@testable import MixCutCore

/// `InspectorPresentationGating` 列数边界与自动选中判定测试（G1-G2）。
struct InspectorPresentationGatingTests {

    let minCard: Double = 360
    let spacing: Double = 12

    @Test("下界：宽不足一张卡片 → 1")
    func belowOneCard() {
        #expect(InspectorPresentationGating.columnCount(available: 100,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 1)
        #expect(InspectorPresentationGating.columnCount(available: 0,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 1)
    }

    @Test("精确边界：恰好一张 → 1；恰好两张（2×卡片+间距）→ 2")
    func exactBoundaries() {
        #expect(InspectorPresentationGating.columnCount(available: minCard,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 1)
        let twoFit = minCard * 2 + spacing
        #expect(InspectorPresentationGating.columnCount(available: twoFit,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 2)
    }

    @Test("边界之间：差 1pt 也取下界（floor）")
    func betweenBoundariesFloors() {
        let twoFit = minCard * 2 + spacing
        #expect(InspectorPresentationGating.columnCount(available: twoFit - 1,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 1)
    }

    @Test("宽区扣减后列数不变 → 允许自动选中")
    func unchangedColumnsAllows() {
        // 1400 → floor(1412/372)=3；扣 341 → 1059 → floor(1071/372)=2？实测验证
        // 选用确实不变的宽度：三列满宽 3×360+2×12=1104；四列满宽 1476。
        // width=1476：before=4；after=1135：floor(1147/372)=3 → 会变，改作拒绝例。
        // 取极宽：2000 → floor(2012/372)=5；after=1659 → floor(1671/372)=4 也变。
        // 真正不变需要 width 与 width−341 落在同一列区间：
        // 5 列区间 [1848 .. 2219)（floor((w+12)/372)=5）
        // width=2200 → after=1859，两者都在 5 列区间 → 允许
        #expect(InspectorPresentationGating.columnCount(available: 2200,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 5)
        #expect(InspectorPresentationGating.columnCount(
            available: InspectorPresentationGating.widthAfterInspector(2200),
            minCardWidth: minCard, spacing: spacing) == 5)
        #expect(InspectorPresentationGating.hoverAutoSelectionAllows(available: 2200,
                                                                     minCardWidth: minCard,
                                                                     spacing: spacing))
    }

    @Test("扣减跨过列边界 → 拒绝")
    func crossingBoundaryDenies() {
        // 5 列下界 1848：width=1848 → before=5；after=1507 → floor(1519/372)=4 → 拒绝
        #expect(InspectorPresentationGating.columnCount(available: 1848,
                                                        minCardWidth: minCard,
                                                        spacing: spacing) == 5)
        #expect(InspectorPresentationGating.columnCount(
            available: InspectorPresentationGating.widthAfterInspector(1848),
            minCardWidth: minCard, spacing: spacing) == 4)
        #expect(!InspectorPresentationGating.hoverAutoSelectionAllows(available: 1848,
                                                                      minCardWidth: minCard,
                                                                      spacing: spacing))
    }

    @Test("widthAfterInspector：扣 341；窄宽夹到 0")
    func widthAfterClamps() {
        #expect(InspectorPresentationGating.widthAfterInspector(1000) == 659)
        #expect(InspectorPresentationGating.widthAfterInspector(100) == 0)
        #expect(InspectorPresentationGating.widthAfterInspector(0) == 0)
    }
}
