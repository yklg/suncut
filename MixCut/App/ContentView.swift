import SwiftUI
import SwiftData

/// 侧边栏导航项
extension Notification.Name {
    static let mixCutNavigate = Notification.Name("mixCutNavigate")
    static let mixCutNewProject = Notification.Name("mixCutNewProject")
    static let mixCutShowShortcuts = Notification.Name("mixCutShowShortcuts")
    /// 脚本物化为方案后请求在「混剪方案」页聚焦选中（object = scheme UUID）。
    /// 与 mixCutNavigate(schemes) 配对投递；SchemeListView 经 loadSchemes 后消费。
    static let mixCutFocusScheme = Notification.Name("mixCutFocusScheme")
    /// 打开设置窗口（配音缺凭证报错 → 点「去设置配置」时广播，侧栏接收开 sheet）
    static let mixCutShowSettings = Notification.Name("mixCutShowSettings")
    /// 撤销 / 重做后广播：当前视图据此重载，避免显示已回滚 / 恢复前的陈旧数据
    static let mixCutDataDidUndo = Notification.Name("mixCutDataDidUndo")
}

/// 「图已变更」的**唯一发布口**。
///
/// 为什么需要这么一颗：通道（`.mixCutDataDidUndo`）本身早就在，但**只有 MCP 链发得出**（16 处），
/// UI 自己的每一条删除链一次都不发 —— 两起同族 SIGTRAP 的共同背景正是"库里真删了、投影还握着"。
/// 把所有发布收进这里，才有唯一的地方同时管住两件事：
/// ① 载荷规则：能剪枝就带 id；实体类型 UI 不认得就**自动降级成无载荷**，走旧的"全量重载"语义（一字不改）；
/// ② **防重入但不丢事件**：`NotificationCenter.post` 是同步的，观察者里只要有人再走 `loadXXX()` → `flushNow()`
///    → 执行待删事务 → 再 post，就是同栈递归（前案 §10 健壮-1，P0）。
///    做法是**排空队列**而不是丢弃：嵌套那次带的 id 与外层**不是同一次删除**（外层剪的是 A，
///    内层那次是 flushNow 顺带真删的 B），丢弃就又回到"库里删了、投影还握着"。
///    队列在最外层那次 post 返回前逐条补发 ⇒ 栈不增长（是循环不是递归），每条真删都必有一次投递。
@MainActor
enum GraphBroadcast {
    private static var isBroadcasting = false
    /// 嵌套期间攒下的载荷。`nil`（全量重载）一旦攒到就清空其余 —— 全量重载覆盖任何剪枝。
    private static var queued: [GraphChange?] = []

    /// `change == nil` = 旧的全量重载语义。不可剪枝的变更集会在这里被降成 nil。
    static func post(_ change: GraphChange? = nil) {
        if isBroadcasting {
            enqueue(change)
            return
        }
        isBroadcasting = true
        defer { isBroadcasting = false }
        deliver(change)
        while !queued.isEmpty {
            deliver(queued.removeFirst())
        }
    }

    private static func enqueue(_ change: GraphChange?) {
        if change == nil {
            MixLog.info("[GraphPrune] 嵌套广播入队：全量重载覆盖此前攒下的剪枝项")
            queued = [nil]
            return
        }
        if queued.count == 1, queued.first == nil { return }   // 已有全量重载 ⇒ 这条剪枝被它覆盖
        queued.append(change)
    }

    private static func deliver(_ change: GraphChange?) {
        let payload: Any? = (change?.isPrunable ?? false) ? change : nil
        NotificationCenter.default.post(name: .mixCutDataDidUndo, object: payload)
    }
}

enum NavigationItem: String, Hashable, CaseIterable, Identifiable {
    case overview = "项目概览"
    case importMedia = "素材导入"
    case segmentLibrary = "分镜素材库"
    case knowledge = "知识库"
    case schemes = "混剪方案"
    case bgmLibrary = "BGM 库"
    case export = "导出"
    /// 文件夹混剪：放「工作区」列表**末尾**、快捷键 ⌘8，既有 ⌘1–⌘7 不动（D18）。
    /// 它排在最后是因为 `SidebarView` 直接按 `allCases` 的顺序渲染，枚举顺序就是侧栏顺序。
    case folderMix = "文件夹混剪"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .importMedia: return "square.and.arrow.down"
        case .segmentLibrary: return "film.stack"
        case .knowledge: return "books.vertical"
        case .schemes: return "list.bullet.clipboard"
        case .bgmLibrary: return "music.note.list"
        case .export: return "square.and.arrow.up"
        case .folderMix: return "folder.badge.plus"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var projectVM = ProjectViewModel()
    @State private var importVM = ImportViewModel()
    @State private var segmentLibraryVM = SegmentLibraryViewModel()
    @State private var schemeVM = SchemeViewModel()
    /// 混剪页的会话状态**提在这里**，不放页面自己的 `@State`：
    /// 页面 `@State` 会随侧栏切页或选中项目变化整页销毁重建 ⇒ 刚抽好的预览凭空清空、
    /// 类别勾选与条数全部回零（上一轮实测到的那条"入库后左侧啥也不是"就是这个）。
    @State private var folderMixVM = FolderMixViewModel()

    @State private var selectedNavItem: NavigationItem? = .overview

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var sidebarVisible = true
    @State private var showShortcuts = false

    var body: some View {
        ZStack {
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            // 侧边栏（可隐藏，⌘B）
            if sidebarVisible {
                SidebarView(
                    projectVM: projectVM,
                    selectedNavItem: $selectedNavItem
                )
                .frame(width: 220)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            // 详情区域 — 切换菜单 / 项目时加平滑过渡
            // 关键：不用 .id() 强制重建，否则每次切换都从零构造大量 NSView/AVPlayer，
            // 直接慢 500-1000ms。让 SwiftUI 自然 diff 重用就好。
            VStack(spacing: 0) {
                // ⚠ 分支顺序是承重的：`.folderMix` 必须在 `if let project` **之前**。
                // 这一页自己建产品与项目（D1/D12），一个项目都没有时也得进得去；
                // 而若它排在后面，用户在页上选中/取消某个项目时分支会翻面 ⇒ 同一页面被
                // 当成两个不同视图重建，@State 全丢（刚抽好的预览卡片会凭空清空）。
                if selectedNavItem == .folderMix {
                    FolderMixView(projectVM: projectVM, schemeVM: schemeVM, vm: folderMixVM)
                } else if let project = projectVM.selectedProject {
                    ProjectProductCrumb(project: project, moduleName: selectedNavItem?.rawValue)
                    detailView(for: project)
                } else {
                    WelcomeView(projectVM: projectVM)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 交叉淡入得有东西垫在后面，否则新旧两页会一起透出窗口白底 —— 就是「闪一下白」。
            .background(DesignTokens.Palette.detailBackdrop)
            // 动画只在这一处驱动。导航写入散在 12 个地方（6 处带 withAnimation、6 处裸写），
            // 挂在分支上只会让侧栏有淡入、概览的「快速操作」硬切 —— 同一个手势两种手感。
            .animation(DesignTokens.Motion.transition, value: selectedNavItem)
            // 素材导入页已经没有骨架屏了，靠它自己的 .task 清 banner 会晚一帧，
            // 上一个项目的红色报错会在切换那一瞬露出来。改在换项目当帧同步清。
            .onChange(of: projectVM.selectedProject?.id) { _, _ in
                importVM.errorMessage = nil
            }
        }
        .onAppear {
            projectVM.setModelContext(modelContext)
            importVM.setModelContext(modelContext)
            segmentLibraryVM.setModelContext(modelContext)
            schemeVM.setModelContext(modelContext)
            // 冷启动预热：此刻分镜素材库那个面还没有任何项目的数据，第一次点它就会上一次骨架 ——
            // 实测那次骨架上屏要在同一次提交里拆掉整棵内容树，窗口连续 100ms 拿不到新帧
            // （尺子 scripts/measure_nav_blank.sh；它自己的 .task 照旧会再跑一次，这里不替代它）。
            // 守卫刻意用 loadedProjectID == nil：每进程至多预热一次，后续 onAppear 不会再擦掉用户的选中。
            if let project = projectVM.selectedProject,
               segmentLibraryVM.readiness.loadedProjectID == nil {
                segmentLibraryVM.loadSegments(for: project)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutNavigate)) { notification in
            if let item = notification.object as? NavigationItem {
                withAnimation(DesignTokens.Motion.transition) {
                    selectedNavItem = item
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutFocusScheme)) { note in
            // 仅登记 pending；SchemeListView onAppear/onChange 的 loadSchemes 末尾统一消费，
            // 保证先切到方案页、数据重载后再选中（焦点不会被 loadSchemes 的清空覆盖）。
            if let id = note.object as? UUID {
                schemeVM.requestFocus(schemeID: id)
                // 若当前已在方案页（不会再触发 onAppear），立即重载消费一次。
                if selectedNavItem == .schemes, let project = projectVM.selectedProject {
                    schemeVM.loadSchemes(for: project)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutNewProject)) { _ in
            projectVM.createProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutShowShortcuts)) { _ in
            showShortcuts = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .mixCutDataDidUndo)) { note in
            reloadAfterUndo(change: note.object as? GraphChange)
        }
        .background(
            VStack(spacing: 0) {
                Button("") {
                    withAnimation(DesignTokens.Motion.transition) {
                        sidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("") { showShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
            .opacity(0)
        )
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsSheet()
        }
        }   // close VStack

        ToastOverlay()
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { newValue in
                if !newValue { hasCompletedOnboarding = true }
            }
        )) {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }

    /// 撤销 / 重做后重载当前数据。
    /// 全局单一撤销栈：⌘Z 可能回滚任意项目的改动，所以统一重建项目列表 +
    /// 重载持有自身快照数组（不随 SwiftData Observation 自动刷新）的各 VM。
    /// 复用「切换项目」同款 loadXXX(for:) 路径，遵守切换项目铁律。
    /// 图变更后的收口。两条路，分叉必须在**第一行**：
    /// - 带 `GraphChange`（发布口已保证它可剪枝）⇒ 只剪投影。**一条都不许碰** `fetchProjects` /
    ///   `loadSegments` / `loadSchemes`：`loadSegments` 首行是 `flushNow()`，会在同一个同步广播栈里
    ///   再执行一遍待删事务并再次广播 ⇒ 递归（前案 §10 健壮-1）。
    /// - 无载荷（⌘Z、MCP 链、不可剪枝的变更）⇒ 旧的全量重载语义，行为一字未改。
    private func reloadAfterUndo(change: GraphChange?) {
        if let change {
            let goneSegments = change.idsDeleted(of: .segment)
            let goneProjects = change.idsDeleted(of: .project)
            segmentLibraryVM.pruneDeletedSegments(goneSegments)
            projectVM.pruneDeletedProjects(goneProjects)
            // 分发给持有快照的抽屉（剪枝信号状态机，不新增观察者/post）。
            schemeVM.notePrunedSegments(goneSegments)
            MixLog.info("[GraphPrune] 剪枝 projects=\(goneProjects.count) videos=\(change.idsDeleted(of: .video).count) "
                        + "segs=\(goneSegments.count) 剩余 segs=\(segmentLibraryVM.segments.count)")
            return
        }
        // 1) 项目列表可能因删除/恢复项目而变化；产品列表一并刷（MCP create_project 可能新建产品）
        projectVM.fetchProducts()
        projectVM.fetchProjects()

        // 2) 当前选中项目若已被撤销删除（恢复了"删除项目"操作），从最新列表里取消选中
        if let selected = projectVM.selectedProject,
           !projectVM.projects.contains(where: { $0.id == selected.id }) {
            projectVM.selectedProject = nil
        }

        // 3) 重载当前项目下持有快照的 VM（ImportView 直接读 project.videos，靠 Observation 自动刷新，无需手动）
        guard let project = projectVM.selectedProject else { return }
        segmentLibraryVM.loadSegments(for: project)
        schemeVM.loadSchemes(for: project)
    }

    @ViewBuilder
    private func detailView(for project: Project) -> some View {
        switch selectedNavItem {
        case .overview:
            ProjectOverviewView(project: project, projectVM: projectVM, selectedNavItem: $selectedNavItem)
        case .importMedia:
            ImportView(project: project, importVM: importVM)
        case .segmentLibrary:
            SegmentLibraryView(project: project, viewModel: segmentLibraryVM, schemeVM: schemeVM)
        case .knowledge:
            KnowledgeLibraryView(project: project)
        case .schemes:
            SchemeListView(project: project, viewModel: schemeVM, segmentLibraryVM: segmentLibraryVM)
        case .bgmLibrary:
            BGMLibraryView()
        case .export:
            ExportView(project: project, schemeVM: schemeVM, projectVM: projectVM)
        case .folderMix:
            // 这一页由上面的路由直接接住（它自己建产品与项目，不依赖已选中的 project），
            // 这里只是让 switch 保持穷尽。**不要**在这里再实例化一次同一个视图：
            // 两处实例化就是两个视图身份，选中项目一变就会重建整页、丢掉刚抽好的预览。
            EmptyView()
        case .none:
            ProjectOverviewView(project: project, projectVM: projectVM, selectedNavItem: $selectedNavItem)
        }
    }
}
