import SwiftUI

/// 弹窗（sheet）统一尺寸契约——App 内所有模态弹窗的尺寸唯一真源。
///
/// 为什么需要它：
/// - 只给 `maxHeight`（上限）时，弹窗实际尺寸随内容自适应——音色选择器切到
///   「童声/角色」等少结果筛选，列表收缩会把整个弹窗拉矮，切回「全部」又变高，
///   窗口上下边缘跳动；
/// - 写死 `height` 虽然不跳，但在更小的宿主（设置页 sheet / 低分屏）里会溢出。
///
/// 正解：固定 **ideal** 目标尺寸（SwiftUI sheet 按 ideal 定窗，内容变化不回流 →
/// 不跳动），同时给 **min** 让小窗宿主可收缩、**max** 让大屏不被钉死。
/// 内容区内部用弹性 ScrollView 承接超出/不足，弹窗外框恒定。
extension View {
    /// - Parameters:
    ///   - minWidth/idealWidth/maxWidth: 宽度约束；宽度通常固定时三者传同值。
    ///   - minHeight/idealHeight: 必传；idealHeight 是弹窗的稳定目标高（不随内容变化）。
    ///   - maxHeight: 默认无穷大，允许大屏舒展；小窗时由系统夹到 minHeight。
    func sheetContainerFrame(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat,
        idealHeight: CGFloat,
        maxHeight: CGFloat? = .infinity
    ) -> some View {
        frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
              minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
    }
}
