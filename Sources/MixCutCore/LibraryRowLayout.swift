import Foundation

/// 素材库滚动内容的「语义分组 → 可滚动行序列」纯投影。
///
/// 为什么需要它（滚动条跳动的结构性修复）：SwiftUI 懒容器要求 ForEach 的每个元素对应
/// 一个身份稳定、高度可预测、出现后布局不再变的子视图。VM 输出的是二维分组
/// （分组 → 分镜数组），直接用「LazyVStack 内嵌 LazyVGrid」时两个懒布局系统各自
/// 估算屏外高度，快速滚动中真实行高成片落地、内容总高连续修正，滚动条 knob 随之跳。
///
/// 本投影把分组拍平为**单层行序列**（标题行 / 卡片行），与 UI 无关、无状态、可单测；
/// 视图只负责 `ForEach(rows)`。投影只承载模型 id（MixCutCore 零依赖，不能引用 App 层
/// 的 SwiftData 模型），模型对象由视图层按 id 回查。
public struct LibraryGroupRef: Equatable, Sendable {
    public let id: UUID
    /// 组内分镜 id，顺序即 VM 已完成的筛选/排序结果，投影不重排。
    public let segmentIDs: [UUID]

    public init(id: UUID, segmentIDs: [UUID]) {
        self.id = id
        self.segmentIDs = segmentIDs
    }
}

/// 滚动列表中的一行。
public enum LibraryRow: Equatable, Sendable {
    /// 分组标题行（视频封面 / 编号 / 组配音栏）
    case header(groupID: UUID)
    /// 一卡片行：网格模式含 1...columnCount 个分镜（末行可能更少），列表模式恒为 1 个
    case cards(groupID: UUID, index: Int, segmentIDs: [UUID])

    /// 稳定行身份：`h-<groupID>` / `r-<groupID>-<行序>`。
    /// 用 String 而非让 enum 直接做 Identifiable：每帧哈希零成本，且 id 语义对 UI 层显式。
    public var id: String {
        switch self {
        case .header(let groupID):
            return "h-\(groupID.uuidString)"
        case .cards(let groupID, let index, _):
            return "r-\(groupID.uuidString)-\(index)"
        }
    }
}

public enum LibraryRowLayout {
    /// 把分组投影为扁平行序列。
    /// - Parameters:
    ///   - groups: 有序分组（空 segmentIDs 的组跳过，不产任何行）
    ///   - columnCount: 网格列数；<1 一律 clamp 到 1
    ///   - isGrid: 网格模式按列切块；列表模式每个分镜独占一行
    public static func rows(for groups: [LibraryGroupRef], columnCount: Int, isGrid: Bool) -> [LibraryRow] {
        let effectiveColumns = isGrid ? max(1, columnCount) : 1
        var result: [LibraryRow] = []
        result.reserveCapacity(groups.count * 2)

        for group in groups {
            guard !group.segmentIDs.isEmpty else { continue }
            result.append(.header(groupID: group.id))

            if effectiveColumns == 1 {
                for (index, segmentID) in group.segmentIDs.enumerated() {
                    result.append(.cards(groupID: group.id, index: index, segmentIDs: [segmentID]))
                }
            } else {
                var index = 0
                var start = group.segmentIDs.startIndex
                while start < group.segmentIDs.endIndex {
                    let end = min(start.advanced(by: effectiveColumns), group.segmentIDs.endIndex)
                    result.append(.cards(groupID: group.id,
                                         index: index,
                                         segmentIDs: Array(group.segmentIDs[start..<end])))
                    start = end
                    index += 1
                }
            }
        }
        return result
    }
}
