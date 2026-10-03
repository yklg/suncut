import Foundation

/// Inspector 展示门禁：网格列数纯算术 + hover 自动选中判定。
///
/// 存在意义：hover 自动选中会让 Inspector 在 280ms 停留后展开、内容区收窄；
/// 若这导致网格列数改变，会出现布局重排甚至「hover 区域位移 → 播放/选中弹一下又收」。
/// 是否允许自动选中是一个纯算术问题（展开前后列数是否一致），本枚举为唯一真源——
/// 视图的列数/卡片宽计算与实施前的门禁判定都引用这里，不保留私有副本。
public enum InspectorPresentationGating {

    /// Inspector 写死宽度（SegmentVariantInspector 340）
    public static let inspectorWidth: Double = 340
    /// Inspector 与内容区之间的分隔线宽
    public static let dividerWidth: Double = 1

    /// 网格列数：`floor((width + spacing) / (minCardWidth + spacing))`，至少 1。
    /// 与视图历史公式一致（卡片最小宽 + 间距的栅格）。
    public static func columnCount(available width: Double,
                                   minCardWidth: Double,
                                   spacing: Double) -> Int {
        guard width > 0, minCardWidth > 0 else { return 1 }
        let denom = minCardWidth + spacing
        let raw = (width + spacing) / denom
        return max(1, Int(raw.rounded(.down)))
    }

    /// Inspector 展开后留给素材区的宽度（扣除分隔线），不小于 0。
    public static func widthAfterInspector(_ width: Double) -> Double {
        max(0, width - inspectorWidth - dividerWidth)
    }

    /// hover 自动选中是否保持列数不变：展开前后列数相等才允许。
    public static func hoverAutoSelectionAllows(available width: Double,
                                               minCardWidth: Double,
                                               spacing: Double) -> Bool {
        let before = columnCount(available: width,
                                 minCardWidth: minCardWidth, spacing: spacing)
        let after = columnCount(available: widthAfterInspector(width),
                                minCardWidth: minCardWidth, spacing: spacing)
        return before == after
    }
}
