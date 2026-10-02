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
    /// 分镜 id → Segment 模型（网格卡片仍需模型对象；按 id 安全回查，禁止强解）
    @State private var segmentByID: [UUID: Segment] = [:]

    private var operationTitle: String {
        switch operation {
        case .insert(let position): return "在 #\(position) 处插入"
        case .replace: return "选择替换分镜"
        }
    }

    private var existingSegmentIDs: Set<UUID> {
        Set(scheme.schemeSegments.compactMap { $0.segment?.id })
    }

    private var defaultProductID: UUID { ProductCatalogDefaults.defaultProductID }

    private var effectiveProductID: UUID {
        if let id = selectedProductID, products.contains(where: { $0.id == id }) { return id }
        return project.product?.id ?? defaultProductID
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

    /// 经过来源芯片 + 搜索过滤后的分镜（顺序沿用投影）
    private var filteredSegments: [Segment] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.entries.compactMap { entry in
            if let f = sourceFilter, entry.source != f { return nil }
            guard let segment = segmentByID[entry.segmentID] else { return nil }
            if !keyword.isEmpty, !segment.text.localizedCaseInsensitiveContains(keyword) { return nil }
            return segment
        }
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
        // 切项目铁律：挂在 body 最外层且以 project.id 为 id，切换项目自动重建。
        .task(id: project.id) { rebuild() }
    }

    // MARK: 数据拍平

    private func rebuild() {
        let products = (try? modelContext.fetch(FetchDescriptor<Product>())) ?? []
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        let projectVideos = (try? modelContext.fetch(FetchDescriptor<ProjectVideo>())) ?? []
        let videos = (try? modelContext.fetch(FetchDescriptor<Video>())) ?? []
        let segments = (try? modelContext.fetch(FetchDescriptor<Segment>())) ?? []

        self.products = products.map {
            CatalogProduct(id: $0.id, name: $0.name, isDefault: $0.isBuiltInDefault)
        }
        self.catalogProjects = projects.map { CatalogProject(id: $0.id, productID: $0.product?.id) }
        self.catalogVideos = videos.map { CatalogVideo(id: $0.id, ownerProjectID: $0.ownerProject?.id) }
        self.flatSegments = segments.map {
            CatalogSegment(id: $0.id, videoID: $0.video?.id, sourceRaw: $0.sourceRaw)
        }
        self.associations = projectVideos.map {
            ProjectVideoAssociation(pvID: $0.id, projectID: $0.project?.id,
                                    videoID: $0.video?.id, addedAt: $0.addedAt)
        }
        self.segmentByID = Dictionary(segments.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        if selectedProductID == nil { selectedProductID = project.product?.id ?? defaultProductID }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(operationTitle)
                    .font(DesignTokens.Typography.bodyEmphasis)
                Text("共 \(catalog.entries.count) 个分镜 · 已在方案 \(existingSegmentIDs.count) 个")
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

    // MARK: - 第一层：产品

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
                        Label(product.name,
                              systemImage: product.id == effectiveProductID ? "checkmark" : "")
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

    // MARK: - 第二层：来源芯片

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
                ForEach(filteredSegments, id: \.id) { seg in
                    let isAlreadyInScheme = existing.contains(seg.id)
                    SegmentCardCompact(
                        segment: seg,
                        isDisabled: isAlreadyInScheme,
                        disabledReason: isAlreadyInScheme ? "该分镜已在方案中" : nil,
                        onTap: { onPick(seg) }
                    )
                    .overlay(alignment: .top) {
                        if let borrowed = borrowedByID[seg.id] {
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
                        if let source = sourceByID[seg.id] {
                            SourceBadge(source: source)
                                .padding(5)
                        }
                    }
                }
            }
            .padding(10)

            if filteredSegments.isEmpty {
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
            .foregroundStyle(selected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }
}
