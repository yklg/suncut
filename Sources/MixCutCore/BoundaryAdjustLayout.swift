import Foundation

/// 分镜卡片「边界微调行」的宽度契约。
///
/// 存在意义：微调行住在右侧 Inspector（宽 340、横向 padding 14）内，行最小宽必须
/// 落在槽位可用宽里。宽度项以**有序数组**为唯一真源——组宽由数组求和派生，
/// 无法静默漂移；视图侧 frame 只准引用这里的常量（BoundaryAdjustUsageGuard 源码守卫）。
///
/// 纪律：行内新增固定宽项，必须先入 ``timeGroupItems``（组内）或补常量（组间），
/// 重新验证契约。
public enum BoundaryAdjustLayout {

    /// 时间组（入 / 出各一）内的固定宽项，顺序 = 渲染顺序。
    public enum TimeGroupItem: Sendable, Equatable {
        /// 「入/出」文字标签
        case label
        /// −/＋ 微调按钮
        case adjustButton
        /// 时间码输入字段
        case timeField
    }

    // MARK: Inspector 槽位契约

    /// Inspector 写死宽度（SegmentVariantInspector 340）
    public static let inspectorWidth: Double = 340
    /// Inspector 内容横向内边距
    public static let inspectorHorizontalPadding: Double = 14

    // MARK: 行内项宽度

    public static let labelWidth: Double = 10
    public static let adjustButtonWidth: Double = 14
    /// 容纳双位帧的 8 字符时间码（10pt 等宽实测 ≈42.7pt）
    public static let timeFieldWidth: Double = 43

    /// 两个时间组之间的间隔（本行为纵向布局时该项仅作契约保留）
    public static let groupGap: Double = 2
    /// 行尾预留宽。
    ///
    /// ⚠️ 名字里的 "Menu" 已经名不副实：它原本给的是 ellipsis 菜单的占位，而那颗菜单
    /// 随「分类」分区改成行内 chip 面板已经整颗移除（2026-11-06）。但这颗值**仍进
    /// `minimumRowWidth` 的求和**（见下方），并被 `BoundaryAdjustLayoutTests` 钉成 20 ⇒
    /// 数值与求和口径都不许动，动的代价是整行宽度契约重算。留着它等于给行尾留一处余量。
    public static let menuWidth: Double = 20

    // MARK: 有序真源与派生

    /// 一个时间组的组成项（组内顺序单一真源）。
    public static let timeGroupItems: [TimeGroupItem] = [
        .label, .adjustButton, .timeField, .adjustButton
    ]

    public static func itemWidth(_ item: TimeGroupItem) -> Double {
        switch item {
        case .label: return labelWidth
        case .adjustButton: return adjustButtonWidth
        case .timeField: return timeFieldWidth
        }
    }

    /// 一个时间组宽度：由 ``timeGroupItems`` 求和，非硬写。
    public static var timeGroupWidth: Double {
        timeGroupItems.reduce(0) { $0 + itemWidth($1) }
    }

    /// 槽位可用宽：Inspector 宽 − 横向 padding×2。
    public static var availableRowWidth: Double {
        inspectorWidth - inspectorHorizontalPadding * 2
    }

    /// 行最小宽：两时间组 + 组间间隔 + Menu（Spacer 压到 0 之后的下界）。
    public static var minimumRowWidth: Double {
        timeGroupWidth * 2 + groupGap + menuWidth
    }

    /// 宽度预算契约：行最小宽不得超过槽位可用宽。
    public static var widthBudgetHolds: Bool {
        minimumRowWidth <= availableRowWidth
    }
}
