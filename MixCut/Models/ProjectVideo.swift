import Foundation
import SwiftData

/// Project 与 Video 的多对多关联（视频全局共享，不再从属单一项目）
@Model
final class ProjectVideo: Identifiable {
    @Attribute(.unique) var id: UUID
    var addedAt: Date

    var project: Project?
    var video: Video?

    init(project: Project, video: Video) {
        self.id = UUID()
        self.addedAt = Date()
        self.project = project
        self.video = video
    }
}

extension ProjectVideo {

    /// 项目 ↔ 视频关联的**幂等入口**：本项目已挂这个视频时返回既有行，不再插入第二行。
    ///
    /// 重复关联会让挂载层把同一素材算两次（分镜列表翻倍、概览数字虚高、UI/MCP 的 `video_no` 错位，
    /// 并在素材库建编号字典时 SIGTRAP）。所有创建关联的地方都必须走这里，逐处加判断必漏。
    ///
    /// ⚠️ 必须是**同步**函数：判重与插入之间一旦出现 `await`，MainActor 上的
    /// check-then-insert 就不再原子，并发导入会重新造出重复行。
    @discardableResult
    static func associate(project: Project, video: Video, in context: ModelContext) -> ProjectVideo {
        if let existing = project.projectVideos.first(where: { $0.video?.id == video.id }) {
            MixLog.error("项目「\(project.name)」已关联视频「\(video.name)」，幂等返回既有行（不重复挂载）")
            return existing
        }
        let pv = ProjectVideo(project: project, video: video)
        context.insert(pv)
        return pv
    }
}
