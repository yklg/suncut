import Foundation

/// 分镜选中状态机：pinned（点击持久）+ hovered（hover 临时）双态。
///
/// 存在意义：素材库需要区分「点击钉住」与「鼠标停留临时查看」，且解析规则
/// （pinned 优先、pin 时清 hover、取消 pin 后自然回退 hover）必须单一可测——
/// 本值类型只承载该纯逻辑，由 SegmentLibraryViewModel 以私有值持有
/// （同其现有 PlaybackActivationGate 持有方式），视图不直接操作此状态。
public struct SegmentSelectionState: Sendable, Equatable {
    public private(set) var pinnedID: UUID?
    public private(set) var hoveredID: UUID?

    public init() {}

    /// 当前生效的选中：pinned 恒优先于 hovered
    public var resolvedID: UUID? { pinnedID ?? hoveredID }

    public var isPinned: Bool { pinnedID != nil }

    /// 点击钉住：覆盖旧 pin，并清掉同源临时 hover（避免冗余双态）
    public mutating func pin(_ id: UUID) {
        pinnedID = id
        hoveredID = nil
    }

    /// hover 更新（鼠标移入/移出；pinned 存在时仍可记录，但不改变 resolved）
    public mutating func setHovered(_ id: UUID?) {
        hoveredID = id
    }

    /// 取消钉住：若 hovered 仍在则解析自然回退（连续性）
    public mutating func clearPinned() {
        pinnedID = nil
    }

    /// 全部清空（切项目等）
    public mutating func clearAll() {
        pinnedID = nil
        hoveredID = nil
    }
}
