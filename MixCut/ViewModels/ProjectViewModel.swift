import Foundation
import SwiftData
import SwiftUI

/// 项目列表 ViewModel
@MainActor
@Observable
final class ProjectViewModel {
    var projects: [Project] = []
    var selectedProject: Project? {
        didSet {
            // 切换项目时，先把待删除项真正删除（兜底，尤其 ImportView 无 VM load 方法）
            if oldValue?.id != selectedProject?.id {
                PendingDeletionCenter.shared.flushNow()
            }
            // 记忆最后访问的项目，下次启动自动选中
            if let id = selectedProject?.id {
                UserDefaults.standard.set(id.uuidString, forKey: "lastSelectedProjectID")
            }
        }
    }
    var isCreatingProject = false
    var newProjectName = ""
    var errorMessage: String?

    /// 概览页的数字快照。
    ///
    /// 原先这四个值写在 `ProjectOverviewView` 的 `@State` 里，而视图实例每次切模块都被销毁重建
    /// （`ContentView.detailView` 是 `@ViewBuilder switch`），于是每次进入都得从骨架屏重画一遍 —— 就是用户看到的闪屏。
    /// 快照与「就绪与否」必须同生命周期，所以搬到本 VM。
    struct OverviewSnapshot: Equatable {
        var videos: [Video] = []
        var videoCount = 0
        var segmentCount = 0
        var schemeCount = 0
    }

    private(set) var overviewSnapshot = OverviewSnapshot()
    private(set) var readiness = ProjectDataReadiness()

    private var modelContext: ModelContext?

    /// 概览页的数据读取：关系字段是计算属性（每次访问都走一遍 dedup），所以一次读全、缓存到本 VM。
    func refreshOverviewSnapshot(for project: Project) {
        let t0 = Date()
        let allVideos = project.videos
        let realVideos = allVideos.filter { !$0.isUserUploaded }            // 成片视频（自建分镜不算「视频」，只在分镜库出现）
        let segCount = allVideos.reduce(0) { $0 + $1.segments.count }       // 分镜计数含自建分镜
        overviewSnapshot = OverviewSnapshot(videos: realVideos,
                                            videoCount: realVideos.count,
                                            segmentCount: segCount,
                                            schemeCount: project.schemeCount)
        readiness.markLoaded(for: project.id)
        MixLog.info("[Readiness] 项目概览已就绪 project=\(project.id)")
        MixLog.info("[Perf] ProjectOverview: \(Int(Date().timeIntervalSince(t0) * 1000))ms / videos=\(overviewSnapshot.videoCount) segs=\(overviewSnapshot.segmentCount)")
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchProjects()
        // 启动时恢复上次选中的项目
        if selectedProject == nil,
           let idString = UserDefaults.standard.string(forKey: "lastSelectedProjectID"),
           let id = UUID(uuidString: idString),
           let proj = projects.first(where: { $0.id == id }) {
            selectedProject = proj
        }
    }

    /// 获取所有项目
    func fetchProjects() {
        guard let context = modelContext else { return }
        // 重新从库读取前，先把待删除项目真正删除，避免隐藏项又被读出来
        PendingDeletionCenter.shared.flushNow()
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\Project.updatedAt, order: .reverse)]
        )
        projects = (try? context.fetch(descriptor)) ?? []
    }

    /// 创建新项目（同步创建"自定义组合"策略容器）
    func createProject() {
        guard let context = modelContext else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let project = Project(name: name)
        context.insert(project)

        let customGroup = MixStrategy(
            name: "自定义组合",
            style: "",
            description: "手动挑选分镜组合的方案",
            targetAudience: "",
            narrativeStructure: "",
            targetDuration: 0
        )
        customGroup.isCustomGroup = true
        customGroup.project = project
        project.strategies.append(customGroup)
        context.insert(customGroup)

        context.safeSave()

        newProjectName = ""
        isCreatingProject = false
        fetchProjects()
        selectedProject = project
    }

    /// 删除项目
    /// ProjectVideo 会级联删除，但 Video 仅在无其他引用时才删除
    func deleteProject(_ project: Project) {
        guard modelContext != nil else { return }
        let projectID = project.id
        if selectedProject?.id == projectID { selectedProject = nil }
        let idx = projects.firstIndex { $0.id == projectID }
        projects.removeAll { $0.id == projectID }   // 界面隐藏（不真删）
        PendingDeletionCenter.shared.schedule(
            message: "已删除项目",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return }
                // 收集该项目引用的视频（在删除关联前）
                let referencedVideos = project.videos
                // 删除项目（级联删除 ProjectVideo、MixStrategy、MixScheme、SchemeSegment）
                context.delete(project)
                context.safeSave()
                // 检查每个视频是否还被其他项目引用，无引用则删除视频+分镜「记录」
                // （磁盘文件交给启动时孤儿 GC）
                for video in referencedVideos where video.projectVideos.isEmpty {
                    let segmentSnapshot = Array(video.segments)
                    for segment in segmentSnapshot { context.delete(segment) }
                    context.delete(video)
                    MixLog.info(" 视频无引用，已删除记录: \(video.name)")
                }
                context.safeSave()
            },
            undo: { [weak self] in
                guard let self else { return }
                if let idx, idx <= self.projects.count { self.projects.insert(project, at: idx) }
                else { self.projects.append(project) }
            }
        )
    }

    /// 重命名项目
    func renameProject(_ project: Project, to newName: String) {
        modelContext?.undoManager?.setActionName("重命名项目")
        project.name = newName
        project.updatedAt = Date()
        modelContext?.safeSave()
        fetchProjects()
    }
}
