import Foundation

/// 项目 ↔ 视频关联行的**值类型快照**，用于把「挂载层唯一性」这条规则放到可单测的地方。
///
/// App target 没有测试 target（`Package.swift` 只承载 MixCutCore），所以规则本体必须住在这里；
/// 读取侧（`Project.associatedVideos`）与一次性清理迁移共用同一个 `deduplicate`，避免规则被写两遍。
public struct ProjectVideoAssociation: Sendable, Hashable {
    public let pvID: UUID
    /// nil = 关系对象取不到的悬挂关联
    public let projectID: UUID?
    public let videoID: UUID?
    public let addedAt: Date

    public init(pvID: UUID, projectID: UUID?, videoID: UUID?, addedAt: Date) {
        self.pvID = pvID
        self.projectID = projectID
        self.videoID = videoID
        self.addedAt = addedAt
    }
}

public struct ProjectVideoDedupResult: Sendable, Equatable {
    /// 每个 (project, video) 恰好一条，按 addedAt 升序（tie 见 `deduplicate` 的说明）
    public let retained: [ProjectVideoAssociation]
    /// 应从 store 删除的关联行 id
    public let deleted: Set<UUID>
    /// 悬挂关联（project/video 取不到）：既不删也不参与计数与编号
    public let untouched: Set<UUID>

    init(retained: [ProjectVideoAssociation], deleted: Set<UUID>, untouched: Set<UUID>) {
        self.retained = retained
        self.deleted = deleted
        self.untouched = untouched
    }

    /// 项目内的视频 id 序列（与 UI 卡片 # / MCP video_no 同一顺序）
    public func retainedVideos(inProject projectID: UUID) -> [UUID] {
        retained.compactMap { $0.projectID == projectID ? $0.videoID : nil }
    }

    /// 项目内 1-based 编号。键是 videoID ⇒ 用它构造字典不可能再撞重复键。
    public func videoNoByVideoID(inProject projectID: UUID) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for (index, videoID) in retainedVideos(inProject: projectID).enumerated() {
            result[videoID] = index + 1
        }
        return result
    }
}

public enum ProjectVideoDedup {

    /// 按 `(project, video)` 分组，每组只保留最早一条关联。
    ///
    /// 组内选择键 = `addedAt` 升序；**`addedAt` 相等时按 `pvID.uuidString` 字典序**（先例
    /// `MixScheme.orderedSegments`）。tie-break 不是可有可无的收尾：少了它，同一毫秒导入的两行
    /// 谁留下取决于遍历顺序，编号就会跨启动漂移，而 `video_no` 是 Agent 的寻址契约。
    ///
    /// 每组必然留下一条（保留数 ≥ 1）是硬约束：某个视频的最后一条关联一旦被删，
    /// 它的磁盘文件就会被启动时的孤儿 GC 连带回收。
    public static func deduplicate(_ rows: [ProjectVideoAssociation]) -> ProjectVideoDedupResult {
        var untouched: Set<UUID> = []
        var keeper: [PairKey: ProjectVideoAssociation] = [:]

        for row in rows {
            guard let projectID = row.projectID, let videoID = row.videoID else {
                untouched.insert(row.pvID)
                continue
            }
            let key = PairKey(projectID: projectID, videoID: videoID)
            guard let current = keeper[key] else {
                keeper[key] = row
                continue
            }
            if isEarlier(row, than: current) {
                keeper[key] = row
            }
        }

        let retained = keeper.values.sorted(by: earlier)
        let retainedIDs = Set(retained.map(\.pvID))
        let deleted = Set(rows.compactMap { row -> UUID? in
            guard row.projectID != nil, row.videoID != nil else { return nil }
            return retainedIDs.contains(row.pvID) ? nil : row.pvID
        })

        return ProjectVideoDedupResult(retained: retained, deleted: deleted, untouched: untouched)
    }

    /// 组内胜出判定：时间更早者胜；时间相同则 pvID 字典序更小者胜
    private static func isEarlier(_ lhs: ProjectVideoAssociation, than rhs: ProjectVideoAssociation) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.pvID.uuidString < rhs.pvID.uuidString
    }

    /// 全局排序：同一把尺子，保证编号稳定且不依赖输入数组顺序
    private static func earlier(_ lhs: ProjectVideoAssociation, _ rhs: ProjectVideoAssociation) -> Bool {
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.pvID.uuidString < rhs.pvID.uuidString
    }
}

private struct PairKey: Hashable {
    let projectID: UUID
    let videoID: UUID
}
