import Foundation

/// 台词头部可显示的标签种类。
public enum SegmentHeaderLabelKind: Sendable, Equatable, CaseIterable {
    /// 「引号」图标（任何档位恒在）
    case icon
    /// 「台词」字样
    case title
    /// 「N 字」字数
    case wordCount
    /// 台词来源（如整片听写切片 / 手动编辑）
    case provenance
}

/// 台词头部在不同容器宽度下的降级布局契约。
///
/// 从宽到窄共 ``tiers`` 四档，每档是上一档只删尾部元素的严格前缀：
/// 降级顺序恒定（来源 → 字数 → 台词 → 图标）、icon 恒在、末档任意宽度兜底。
///
/// 该契约独立于 SwiftUI 的 `ViewThatFits` 测量：宽度选择交给 ViewThatFits，
/// 「各档包含什么、按什么顺序」由本静态数据单一承载，视图只按 kind 映射渲染。
public enum SegmentHeaderLayout: Sendable {
    /// 从宽到窄的四档标签集合。
    public static let tiers: [[SegmentHeaderLabelKind]] = [
        [.icon, .title, .wordCount, .provenance],
        [.icon, .title, .wordCount],
        [.icon, .title],
        [.icon]
    ]
}
