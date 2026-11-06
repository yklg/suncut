import SwiftUI
import SwiftData

/// 选择分镜的右侧抽屉，支持插入/替换两种语义。
///
/// 两级浏览（方案 A，单层不跳页）：顶部产品下拉（默认当前项目所属产品，可跨产品切换）
/// → 来源芯片（自拍/搬运/AI生产/未分类，计数为当前产品域全量口径）→ 搜索 → 分镜网格。
/// 归属/借用/计数规则全部在 MixCutCore.SegmentPickerCatalog（C1-C7 单测），本视图只拍平数据。
struct SegmentPickerDrawer: View {
    enum Operation: Equatable {
        case insert(position: Int)
        case replace(schemeSegmentID: UUID, originalSemantic: [SemanticType])
    }

    let project: Project
    let scheme: MixScheme
    /// 剪枝信号来源（会话内另一项目被真删 ⇒ 本地卡片剪枝，见 onChange）。
    let schemeVM: SchemeViewModel
    let operation: Operation
    let onPick: (Segment) -> Void
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    /// nil = 全部；否则按来源过滤
    @State private var sourceFilter: SegmentSource? = nil
    /// 当前浏览的产品；nil = 尚未初始化（用当前项目产品/默认产品兜底）
    @State private var selectedProductID: UUID?

    // MARK: 拍平的全库数据（进抽屉算一次，产品/来源切换不重 fetch）
    @State private var products: [CatalogProduct] = []
    @State private var catalogProjects: [CatalogProject] = []
    @State private var catalogVideos: [CatalogVideo] = []
    @State private var flatSegments: [CatalogSegment] = []
    @State private var associations: [ProjectVideoAssociation] = []

    /// 跨 to-one 边的解边索引：从活 fetch 结果构建，跨边只读 persistentModelID 再查映射。
    @State private var liveIndex = LiveModelIDIndex()
    /// 分镜卡片快照（值类型；构建后不再 fault 任何模型，G20 守卫钉住快照零跨边）。
    @State private var cards: [SegmentCardSnapshot] = []

    private var operationTitle: String {
        switch operation {
        case .insert(let position): return "在 #\(position) 处插入"
        case .replace: return "选择替换分镜"
        }
    }

    private var existingSegmentIDs: Set<UUID> {
        // 跨边只取边目标的 persistentModelID（结构性标识，不加载 backing）；
        // 目标已真删 ⇒ 索引查无映射 ⇒ 不计入。
        Set(scheme.schemeSegments.compactMap { liveIndex.uuid(for: $0.segment) })
    }

    private var defaultProductID: UUID { ProductCatalogDefaults.defaultProductID }

    private var effectiveProductID: UUID {
        if let id = selectedProductID, products.contains(where: { $0.id == id }) { return id }
        return liveIndex.uuid(for: project.product) ?? defaultProductID
    }

    /// 当前产品的目录投影（entries + 计数）
    private var catalog: CatalogResult {
        SegmentPickerCatalog.entries(forProduct: effectiveProductID,
                                     products: products,
                                     projects: catalogProjects,
                                     videos: catalogVideos,
                                     segments: flatSegments,
                                     associations: associations)
    }

    private var cardByID: [UUID: SegmentCardSnapshot] {
        Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 经过来源芯片 + 搜索过滤后的卡片（顺序沿用投影）。
    private var filteredCards: [SegmentCardSnapshot] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.entries.compactMap { entry in
            if let f = sourceFilter, entry.source != f { return nil }
            guard let card = cardByID[entry.segmentID] else { return nil }
            if !keyword.isEmpty, !card.text.localizedCaseInsensitiveContains(keyword) { return nil }
            return card
        }
    }

    /// header 上那句「共 N 个分镜」与网格**同一判据**：被门筛掉的分镜不进列表，也就不该算进总数
    /// （否则界面一边少画一边照报，属于"筛掉死人之后数字说假话"）。口径仍是**当前产品域全量**，不含来源/搜索筛。
    private var listableEntryCount: Int {
        catalog.entries.count { cardByID[$0.segmentID] != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            productBar
            sourceBar
            filterBar
            Divider()
            content
        }
        .frame(width: 320)
        .background(.regularMaterial)
        // 切项目铁律：挂在 body 最外层且以 project 的 id 为 id，切换项目自动重建。
        // id 走 `live` 门：项目被真删后这里是 nil ⇒ 任务不再重建，由父视图 SchemeDetailView 的
        // 同一道门把抽屉整体收起（不新造一套「任务取消」语义）。
        .task(id: project.live?.id) { rebuild() }
        // 会话内另一项目真删 ⇒ 经既有广播唯一路由分发的剪枝信号：本地摘除陈旧卡片与索引，
        // 只剪枝、不 fetch、不 post。
        .onChange(of: schemeVM.pruneVersion) { _, _ in
            let gone = schemeVM.prunedSegmentIDs
            guard !gone.isEmpty else { return }
            cards.removeAll { gone.contains($0.id) }
            liveIndex.invalidate(uuids: gone)
        }
    }

    // MARK: 数据拍平

    private func rebuild() {
        let products = (try? modelContext.fetch(FetchDescriptor<Product>())) ?? []
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let projectVideos = (try? modelContext.fetch(FetchDescriptor<ProjectVideo>())) ?? []
        let videos = (try? modelContext.fetch(FetchDescriptor<Video>())) ?? []
        let segments = ((try? modelContext.fetch(FetchDescriptor<Segment>())) ?? [])
            .filter { !$0.mixInternalWholeClip }   // 决议 K9：混剪补建的内部段不在抽屉里挑

        // ① 先从**活 fetch 结果**统一构建解边索引（persistentModelID → 业务 UUID）。
        var index = LiveModelIDIndex()
        index.insert(products, id: \.id)
        index.insert(projects, id: \.id)
        index.insert(projectVideos, id: \.id)
        index.insert(videos, id: \.id)
        index.insert(segments, id: \.id)
        self.liveIndex = index

        self.products = products.map {
            CatalogProduct(id: $0.id, name: $0.name, isDefault: $0.isBuiltInDefault)
        }
        // 下面四处跨 to-one 边的解析全部走索引：只取边目标的 persistentModelID（结构性、
        // 不加载 backing），目标已真删 ⇒ 查无映射 ⇒ nil。折算成 nil 不是发明兜底：
        // 目录侧 R4 规则（SegmentPickerCatalog）与 C3 用例早就定义了
        // 「owner 缺失/悬空 → 回退最早可解析关联 → 默认产品」这条语义。
        self.catalogProjects = projects.map {
            CatalogProject(id: $0.id, productID: index.uuid(for: $0.product))
        }
        self.catalogVideos = videos.map {
            CatalogVideo(id: $0.id, ownerProjectID: index.uuid(for: $0.ownerProject))
        }
        self.flatSegments = segments.map {
            CatalogSegment(id: $0.id, videoID: index.uuid(for: $0.video), sourceRaw: $0.sourceRaw)
        }
        self.associations = projectVideos.map {
            ProjectVideoAssociation(pvID: $0.id, projectID: index.uuid(for: $0.project),
                                    videoID: index.uuid(for: $0.video), addedAt: $0.addedAt)
        }

        // ② 卡片快照只读分镜**自有列**构建（init 内零跨边，见 SegmentCardSnapshot）。
        self.cards = segments.map(SegmentCardSnapshot.init)

        if selectedProductID == nil {
            selectedProductID = index.uuid(for: project.product) ?? defaultProductID
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operationTitle)
                    .font(DesignTokens.Typography.bodyEmphasis)
                Text("共 \(listableEntryCount) 个分镜 · 已在方案 \(existingSegmentIDs.count) 个")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(DesignTokens.Typography.bodyLarge)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 第一层：产品

    private var productBar: some View {
        HStack(spacing: 6) {
            Text("产品")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.tertiary)
            Menu {
                ForEach(products) { product in
                    Button {
                        selectedProductID = product.id
                    } label: {
                        // 选中态写进标题文字（本 App 的 `Menu` 不渲染 `Label` 的 image，真屏证过）。
                        // 同一约定见 `SegmentCard.menuItem(_:_)`。
                        Text(product.id == effectiveProductID
                             ? "✓ \(product.name)"
                             : "　\(product.name)")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(productName(effectiveProductID))
                        .font(DesignTokens.Typography.labelEmphasis)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func productName(_ id: UUID) -> String {
        products.first { $0.id == id }?.name
            ?? (id == defaultProductID ? ProductCatalogDefaults.defaultProductName : "未知产品")
    }

    // MARK: 第二层：来源芯片

    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                SourceChip(title: "全部", count: catalog.entries.count,
                           dot: nil, selected: sourceFilter == nil) {
                    sourceFilter = nil
                }
                ForEach([SegmentSource.selfShot, .curated, .aiGenerated, .unclassified],
                        id: \.rawValue) { source in
                    SourceChip(title: source.displayName,
                               count: catalog.counts[source] ?? 0,
                               dot: source.dotColor,
                               selected: sourceFilter == source) {
                        sourceFilter = source
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var filterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
            TextField("搜索台词", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.label)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var content: some View {
        let existing = existingSegmentIDs
        // 分镜 id → 借用信息（紫条用）
        let borrowedByID: [UUID: BorrowedInfo] = Dictionary(
            catalog.entries.compactMap { entry in entry.borrowed.map { (entry.segmentID, $0) } },
            uniquingKeysWith: { first, _ in first })
        let sourceByID: [UUID: SegmentSource] = Dictionary(
            catalog.entries.map { ($0.segmentID, $0.source) },
            uniquingKeysWith: { first, _ in first })

        return ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: DesignTokens.Spacing.compact) {
                ForEach(filteredCards) { card in
                    let isAlreadyInScheme = existing.contains(card.id)
                    SegmentCardCompact(
                        card: card,
                        isDisabled: isAlreadyInScheme,
                        disabledReason: isAlreadyInScheme ? "该分镜已在方案中" : nil,
                        onTap: { cardTapped(card.id) }
                    )
                    .overlay(alignment: .top) {
                        if let borrowed = borrowedByID[card.id] {
                            Text("来自：\(borrowed.productName)")
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2.5)
                                .background(Color(red: 0.49, green: 0.25, blue: 0.87).opacity(0.92))
                                .foregroundStyle(.white)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let source = sourceByID[card.id] {
                            SourceBadge(source: source)
                                .padding(5)
                        }
                    }
                }
            }
            .padding(10)

            if filteredCards.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(.tertiary)
                    Text("没有匹配的分镜")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }
        }
    }

    /// 点击卡片：以一次新鲜 fetch 解析 Segment（快照只负责展示，不持有模型）。
    private func cardTapped(_ id: UUID) {
        let descriptor = FetchDescriptor<Segment>(predicate: #Predicate<Segment> { $0.id == id })
        guard let segment = try? modelContext.fetch(descriptor).first else {
            ToastCenter.shared.show("该分镜已被删除", icon: "exclamationmark.triangle.fill",
                                   style: .warning)
            return
        }
        // 调用链全程同步在 MainActor，fetch 与使用之间无删除可插入。
        onPick(segment)
    }
}

/// 抽屉里的来源芯片（紧凑胶囊，带计数与色点）
private struct SourceChip: View {
    let title: String
    let count: Int
    let dot: Color?
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(title).font(.system(size: 11.5))
                Text("\(count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.10)))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
