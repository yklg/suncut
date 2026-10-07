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

    // MARK: - 产品（第一层分类）
    /// 全库产品，按创建时间升序
    private(set) var products: [Product] = []
    /// 每个产品下的项目数（产品菜单「名称 · N 个项目」消歧用）
    private(set) var projectCountByProduct: [UUID: Int] = [:]
    /// 新建项目弹窗里选中的产品 id；nil = 用默认产品（与存量数据/未选择口径一致）
    var newProjectProductID: UUID?
    /// 新建产品名称（弹窗内联输入）；非空即处于「新建产品」模式
    var newProductName: String = ""

    // MARK: - 侧栏分组（派生状态，零 stored 缓存）

    /// 用户显式折叠的产品（@AppStorage 同源；仅记录「折叠」，展开与否还要结合当前选中项目）
    private(set) var collapsedProductIDs: Set<UUID> = {
        Set(UserDefaults.standard.stringArray(forKey: "collapsedProductIDs_v1")?
            .compactMap(UUID.init(uuidString:)) ?? [])
    }()

    /// 侧栏「产品 → 项目」分组。计算属性：deleteProject/undo 等路径直接改 projects 数组、
    /// 不经过 fetch，stored 缓存会漏刷新；@Observable 在 products/projects 变化时自动重算。
    var sidebarGroups: [SidebarProductGroup] {
        let productRefs = products.map {
            SidebarProductRef(id: $0.id, name: $0.name, isDefault: $0.isBuiltInDefault,
                              createdAt: $0.createdAt)
        }
        let projectRefs = projects.map {
            SidebarProjectRef(id: $0.id, productID: $0.product?.id,
                              updatedAt: $0.updatedAt, isArchived: $0.status == .archived)
        }
        return SidebarProductGrouping.groups(products: productRefs, projects: projectRefs)
    }

    /// 组是否展开：用户折叠后，只要当前选中项目不在该组即收起；选中项目所在组永远可见。
    func isExpanded(_ groupID: UUID) -> Bool {
        !(collapsedProductIDs.contains(groupID) && selectedProject?.product?.id != groupID)
    }

    func toggleCollapsed(_ groupID: UUID) {
        if collapsedProductIDs.contains(groupID) {
            collapsedProductIDs.remove(groupID)
        } else {
            collapsedProductIDs.insert(groupID)
        }
        UserDefaults.standard.set(collapsedProductIDs.map(\.uuidString),
                                  forKey: "collapsedProductIDs_v1")
    }

    func product(byID id: UUID) -> Product? {
        products.first { $0.id == id }
    }

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
        fetchProducts()
        fetchProjects()
        // 启动时恢复上次选中的项目
        if selectedProject == nil,
           let idString = UserDefaults.standard.string(forKey: "lastSelectedProjectID"),
           let id = UUID(uuidString: idString),
           let proj = projects.first(where: { $0.id == id }) {
            selectedProject = proj
        }
    }

    // MARK: - 配音音色（M1b 项目覆盖唯一写入收口）

    /// 设置/清除项目级配音音色覆盖（VoiceChoiceCoder 串；nil=跟随全局默认）。
    /// 视图不直写 Project.preferredVoiceChoiceRaw——G-V7 守此收口函数名。
    func setProjectVoiceOverride(raw: String?, project: Project) {
        guard let modelContext else { return }
        project.preferredVoiceChoiceRaw = raw
        modelContext.safeSave()
    }

    // MARK: - 产品操作

    /// 取或建内置「默认产品」（哨兵 UUID，全库唯一）。
    /// backfill（LaunchSteps）负责给存量项目补归属；VM 这个入口保证 UI 期间也永远有默认项可选。
    @discardableResult
    func ensureDefaultProduct(in context: ModelContext? = nil) -> Product? {
        guard let context = context ?? modelContext else { return nil }
        if let existing = products.first(where: { $0.isBuiltInDefault }) { return existing }
        if let existing = try? context.fetch(FetchDescriptor<Product>()),
           let found = existing.first(where: { $0.isBuiltInDefault }) {
            fetchProducts()
            return found
        }
        let product = Product(id: ProductCatalogDefaults.defaultProductID,
                              name: ProductCatalogDefaults.defaultProductName,
                              isBuiltInDefault: true)
        context.insert(product)
        context.safeSave()
        fetchProducts()
        return product
    }

    /// 精确同名产品查询（去首尾空白后比较；UI 用它做「已存在同名产品」二次确认）。
    func product(named name: String) -> Product? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return products.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    /// 创建产品。重名由 UI 层先确认（使用已有 / 仍要创建），这里不做静默合并。
    @discardableResult
    func createProduct(name: String) -> Product? {
        guard let context = modelContext else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let product = Product(name: trimmed)
        context.insert(product)
        context.safeSave()
        fetchProducts()
        return product
    }

    func fetchProducts() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Product>(sortBy: [SortDescriptor(\Product.createdAt, order: .forward)])
        let fetched = (try? context.fetch(descriptor)) ?? []
        products = fetched
        // 项目数统计走内存（产品数/项目数都是个位~几十量级）
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        var counts: [UUID: Int] = [:]
        for project in projects {
            guard let pid = project.product?.id else { continue }
            counts[pid, default: 0] += 1
        }
        projectCountByProduct = counts
    }

    /// 弹窗里产品选择的当前值：显式选择 → 记住的产品 → 默认产品。
    var effectiveNewProjectProduct: Product? {
        if let id = newProjectProductID {
            if let p = products.first(where: { $0.id == id }) { return p }
        }
        if let idString = UserDefaults.standard.string(forKey: "lastSelectedProductID"),
           let id = UUID(uuidString: idString),
           let p = products.first(where: { $0.id == id }) {
            return p
        }
        return products.first(where: { $0.isBuiltInDefault })
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

    /// 创建新项目（同步创建"自定义组合"策略容器），归属到弹窗选定的产品。
    func createProject() {
        guard let context = modelContext else { return }
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // 产品归属：内联新输入的产品名优先（重名时 UI 已让用户拍板）；否则用选中产品；兜底默认产品。
        let product: Product?
        let trimmedNewProduct = newProductName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNewProduct.isEmpty {
            product = self.product(named: trimmedNewProduct) ?? createProduct(name: trimmedNewProduct)
        } else if let id = newProjectProductID, let selected = products.first(where: { $0.id == id }) {
            product = selected
        } else {
            product = effectiveNewProjectProduct ?? ensureDefaultProduct()
        }
        if let pid = product?.id {
            UserDefaults.standard.set(pid.uuidString, forKey: "lastSelectedProductID")
        }

        let project = Project(name: name)
        project.product = product
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
        newProductName = ""
        newProjectProductID = product?.id
        isCreatingProject = false
        fetchProducts()
        fetchProjects()
        selectedProject = project
    }

    /// 删除项目：界面立刻隐藏（不真删），宽限期到点才走咽喉。
    /// 真删的全部细节 —— 入边结算、级联、无引用视频补删、落盘 —— 收在
    /// `ModelContext.deleteProjectSettlingOwnerEdges(_:)` 一处，这里不再摆第二份实现。
    func deleteProject(_ project: Project) {
        guard modelContext != nil else { return }
        let projectID = project.id
        if selectedProject?.id == projectID { selectedProject = nil }
        let idx = projects.firstIndex { $0.id == projectID }
        projects.removeAll { $0.id == projectID }   // 界面隐藏（不真删）
        PendingDeletionCenter.shared.schedule(
            message: "已删除项目",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return GraphChange() }
                let outcome = context.deleteProjectSettlingOwnerEdges(project)
                if outcome.saveFailed {
                    ToastCenter.shared.show("删除项目后保存失败，改动可能在重启后丢失。请重试；日志见 \(MixLog.logFileURL.path)",
                                            icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
                    // 内存与库此刻不一致：剪枝会让界面"看起来已经删干净"，而重启后那一项又冒出来。
                    // 宁可不广播 —— 交回空台账，`PendingDeletionCenter` 就不发（这条判断只有一份，在发布口那里）。
                    return GraphChange()
                }
                // 谁删谁广播（前案 §2 的不变量）。此前 UI 的每条删除链一次都不发，
                // 于是"库里真删了、投影还握着"成了两起同族 SIGTRAP 的共同背景。
                return outcome.change
            },
            undo: { [weak self] in
                guard let self else { return }
                if let idx, idx <= self.projects.count { self.projects.insert(project, at: idx) }
                else { self.projects.append(project) }
            }
        )
    }

    /// 从投影里剪掉已真删的项目 —— 广播带 id 时走这里，**不重新 fetch**。
    ///
    /// 为什么不用 `fetchProjects()` 顶替：本方法是 `GraphBroadcast.post` 的**同步栈**里执行的，
    /// 而重载路径上到处挂着 `flushNow()` —— 再走一次就是自己把自己递归掉（前案 §10 健壮-1，P0）。
    /// ⚠️ 下面把 `selectedProject` 置 nil 会触发它的 `didSet → flushNow()`（既有语义，:10-15，不改）。
    ///    递归由 `GraphBroadcast` 的重入闸挡下；被丢弃的那次广播会留 error 日志 ——
    ///    彻底的做法是把那颗 `flushNow` 从 `didSet` 挪到显式调用点，属独立小批，别记成"这里没有二次删除"。
    func pruneDeletedProjects(_ ids: Set<UUID>) {
        guard !ids.isEmpty, projects.contains(where: { ids.contains($0.id) }) else { return }
        projects.removeAll { ids.contains($0.id) }
        if let selected = selectedProject, ids.contains(selected.id) {
            selectedProject = nil
            overviewSnapshot = OverviewSnapshot()   // 快照里装的是模型对象，项目没了就成了一串死引用
        }
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
