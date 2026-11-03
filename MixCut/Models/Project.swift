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

    /// 项目级配音音色覆盖（VoiceChoiceCoder 版本化 JSON 串）。
    /// nil = 跟随 App 全局默认；坏串由 VoiceChoiceCoder 解为 nil（自动回落全局，不崩）。
    /// 带默认值 optional 字段，走 SwiftData 轻量迁移（同 v3.4 字段惯例）。
    var preferredVoiceChoiceRaw: String?

    /// 项目级 logo 角标配置（LogoOverlayCoder 版本化 JSON 串）。
    /// nil / 坏串 = 关闭；写入唯一收口见 `ProjectViewModel.setProjectLogoOverlay`。
    /// optional ⇒ 轻量迁移；schema 指纹会变，`SchemaGuard` 只增路径会先备份再开库。
    var logoOverlayRaw: String?

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

    /// 项目内**可显示**的分镜（决议 K9 的聚合出口；体形照下面那颗 `videoNoByVideoID`：
    /// 唯一一处遍历，调用方读全再用自己的缓存，别在视图 body 里逐次调）。
    var displayableSegments: [Segment] {
        var out: [Segment] = []
        for video in associatedVideos { out.append(contentsOf: video.displayableSegments) }
        return out
    }

    /// 可显示分镜总数（方案页那句「N 个分镜可用」用它）。
    /// ⚠ 与 `segmentCount` 是**两颗不同的数**，且刻意不是同一颗：那颗一颗两用
    ///   （既当数字又当三处「有没有料」的禁用闸），闸必须继续看见混剪内部段，否则等于偷改闸。
    var displayableSegmentCount: Int {
        associatedVideos.reduce(0) { $0 + $1.displayableSegmentCount }
    }

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

// MARK: - 「建一个可用项目」的唯一动作

extension Project {

    /// 新建项目并同步挂上「自定义组合」容器。
    ///
    /// 为什么要有这颗：`Project(name:) + insert + MixStrategy(自定义组合) + append + insert`
    /// 这五步在仓里有两份逐字拷贝（UI 的 `ProjectViewModel.createProject` 与
    /// `MCPToolHandlers` 的建项工具，后者那句注释写着「与 UI 的 createProject 保持一致」——
    /// 靠人记着抄对的一致性不是一致性）。文件夹混剪是第三个调用方（类别项目 + 汇总项目），
    /// 所以动作收在这里：**只落对象，不落盘、不刷列表** —— 那些是每个调用方自己的事务边界
    /// （UI 要刷 `projects`/`products`，MCP 走 `notifyUIReload`，混剪要连着入库）。
    /// 容器本体见 `MixStrategy.attachCustomGroup`。
    @discardableResult
    static func makeWithName(_ name: String, product: Product?, in context: ModelContext) -> Project {
        let project = Project(name: name)
        project.product = product
        context.insert(project)
        MixStrategy.attachCustomGroup(to: project, in: context)
        return project
    }
}
