import Foundation
import SwiftData

/// 项目状态
enum ProjectStatus: String, Codable, CaseIterable {
    case created = "created"          // 刚创建
    case importing = "importing"      // 导入素材中
    case analyzing = "analyzing"      // AI 分析中
    case ready = "ready"              // 分析完成，可生成方案
    case generating = "generating"    // 生成方案中
    case completed = "completed"      // 已完成
    case archived = "archived"        // 已归档
}

@Model
final class Project: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var status: ProjectStatus
    var customPrompt: String?
    var createdAt: Date
    var updatedAt: Date

    /// 所属产品（建项目时选定；nil 仅可能出现在 backfill 之前，读侧经 Product 目录回退默认产品）。
    /// optional to-one + 产品侧不挂 cascade：产品删除不连带删项目（本期产品不做删除）。
    var product: Product?

    @Relationship(deleteRule: .cascade, inverse: \ProjectVideo.project)
    var projectVideos: [ProjectVideo] = []

    @Relationship(deleteRule: .cascade, inverse: \MixStrategy.project)
    var strategies: [MixStrategy] = []

    @Relationship(deleteRule: .cascade, inverse: \MixScheme.project)
    var schemes: [MixScheme] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.status = .created
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// 关联的视频列表：挂载层唯一性的**读取侧唯一出口**。
    ///
    /// 「同一项目内同一视频只挂一份」这条不变量，写入侧由 `ProjectVideo.associate` 保证，
    /// 这里对历史脏数据做兜底去重 —— 规则本体在 `MixCutCore.ProjectVideoDedup`（App target 没有测试
    /// target，所以规则不能在这里重写一遍）。
    var associatedVideos: [Video] {
        dedupedAssociationIDs.compactMap { videoByPvID[$0] }
    }

    /// 兼容既有调用点；语义等同 `associatedVideos`（不再是"每条关联一行"）
    var videos: [Video] { associatedVideos }

    /// 视频总数：与 `associatedVideos` 同口径，悬空关联与重复关联都不计入
    var videoCount: Int { associatedVideos.count }

    /// UI 卡片 # 与 MCP `video_no` 的**唯一定义处**（原来在素材库、导入页、MCP 三处各抄了一遍）
    var videoNoByVideoID: [UUID: Int] {
        ProjectVideoDedup.deduplicate(associationRows).videoNoByVideoID(inProject: id)
    }

    private var associationRows: [ProjectVideoAssociation] {
        projectVideos.map {
            ProjectVideoAssociation(pvID: $0.id, projectID: $0.project?.id,
                                    videoID: $0.video?.id, addedAt: $0.addedAt)
        }
    }

    /// 每个 (project, video) 保留下来的那条关联的 pvID（按导入时间升序）
    private var dedupedAssociationIDs: [UUID] {
        ProjectVideoDedup.deduplicate(associationRows).retained.map(\.pvID)
    }

    private var videoByPvID: [UUID: Video] {
        var lookup: [UUID: Video] = [:]
        for pv in projectVideos {
            // 同一 pvID 只会有一行；这里的冲突分支只防"关系数组被并发写入弄出重复元素"
            if let video = pv.video { lookup[pv.id] = video }
        }
        return lookup
    }

    /// 分镜总数
    var segmentCount: Int {
        associatedVideos.reduce(0) { $0 + $1.segments.count }
    }

    /// 方案总数
    var schemeCount: Int { schemes.count }
}
