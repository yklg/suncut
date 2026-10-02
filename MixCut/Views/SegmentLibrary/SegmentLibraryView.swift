import SwiftUI
import SwiftData
import AVKit
import AppKit
import UniformTypeIdentifiers

struct SegmentLibraryView: View {
    let project: Project
    @Bindable var viewModel: SegmentLibraryViewModel
    @Bindable var schemeVM: SchemeViewModel

    @State private var showBatchExportSheet = false
    @State private var showBatchDeleteConfirm = false
    @State private var showArrangeSheet = false
    @State private var dubVM = DubbingViewModel()
    /// 搜索防抖任务句柄：新按键到来时取消上一个，避免每敲一个字就全量重算。
    @State private var searchDebounceTask: Task<Void, Never>?
    /// 字幕烧录字号（全局设置，与卡片预览、导出共用同一 UserDefaults 键）
    /// ⚠️ 这是本视图**私有**的 ImportViewModel，与 ContentView 那个不是同一实例；
    ///    .task 里那句 setModelContext 是给它注上下文的**唯一一处**，删不得（自建分镜上传/拆分都走它）。
    @State private var importVM = ImportViewModel()
    /// 滚动内容实测宽（背景 GeometryReader 间接测量），驱动网格列数与固定卡宽
    @State private var libraryWidth: CGFloat = 0
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        // ⚠️ .task(id: project.id) 必须放在 body 最外层，不能放进子分支（见 CLAUDE.md）
        Group {
            // 骨架只在屏上还没有任何项目数据时亮。换项目**不**换分支：那次结构翻转要在同一次提交里
            // 拆掉整棵旧内容树，窗口因此连续 50–133ms 拿不到新帧 —— 就是用户报的闪屏（见 ProjectDataReadiness）。
            if viewModel.readiness.needsSkeleton {
                SkeletonView(layout: .segmentLibrary)
            } else {
                // 数据还没换过来时屏上是上一个项目的画面：照常画，但点不动。
                // 不能留可点 —— 这里面的按钮回调捕获的 project 已经是新那一个了。
                mainContent
                    .allowsHitTesting(viewModel.readiness.holdsData(for: project.id))
            }
        }
        .task(id: project.id) {
            // 上面那个 @State importVM 是本视图私有的实例，这里是它拿到 context 的唯一一处 ——
            // 删不得：自建分镜上传与拆分两条路径都走它。
            importVM.setModelContext(modelContext)
            let t0 = Date()
            // 退出多选模式 + 清空选中（避免不同项目的 ID 串到一起）
            viewModel.setSelectionMode(false)
            let videoCovers = project.videos.compactMap(\.thumbnailPath)
            viewModel.loadSegments(for: project)
            // ⚠️ 一次调用同时预热「每个视频的封面」和「全部分镜缩略图」。
            // 旧写法是连发两次 prewarm，而第二次会 cancel 第一次 —— 视频封面从来没预热成过。
            // 真正铺满屏幕的是分镜缩略图（可达数百张）；不预热的话 LazyVGrid 每滚出一行
            // 都要在主线程同步读盘+解码 → 滚动掉帧。
            let covers = videoCovers + viewModel.segments.compactMap(\.thumbnailPath)
            ThumbnailCache.shared.prewarm(paths: covers, for: project.id)
            MixLog.info("[Perf] SegmentLibrary: \(Int(Date().timeIntervalSince(t0) * 1000))ms / segs=\(viewModel.segments.count)")
        }
        .confirmationDialog("这批自建分镜的素材来源是？",
                            isPresented: $showSelfSegmentSourcePicker,
                            titleVisibility: .visible) {
            ForEach([SegmentSource.selfShot, .curated, .aiGenerated], id: \.rawValue) { source in
                Button {
                    selfSegmentSourceRaw = source.rawValue
                    presentSelfSegmentFilePanel(source: source)
                } label: {
                    let current = SegmentSource(persisted: selfSegmentSourceRaw) == source
                    Text(current ? "✓ \(source.displayName)" : source.displayName)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("自拍=公司原创拍摄；搬运=他人视频；AI生产=外部 AI 工具生成。选择会记住（仅本入口），之后可逐条改。")
        }
    }

    /// 上传自建分镜：先选来源（自拍/搬运/AI，独立记忆），再选文件
    @State private var showSelfSegmentSourcePicker = false
    @AppStorage("selfSegmentDefaultSourceRaw") private var selfSegmentSourceRaw: String = SegmentSource.curated.rawValue

    private func presentSelfSegmentUpload() {
        showSelfSegmentSourcePicker = true
    }

    private func presentSelfSegmentFilePanel(source: SegmentSource) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.prompt = "上传"
        panel.message = "选择要作为自建分镜上传的视频（单条 ≤ \(Int(ImportViewModel.selfSegmentMaxDuration)) 秒）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { @MainActor in
            await importVM.importSelfSegments(urls: urls, into: project, source: source) {
                viewModel.loadSegments(for: project)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            filterToolbar
                .padding(.horizontal, DesignTokens.Padding.page)
                .padding(.vertical, 12)
                // 用原生工具栏材质而非纯色：内容滚动到下方时透出模糊，
                // 形成 macOS 应有的"工具条浮在内容之上"的层次感（原来全靠平铺的半透明灰）。
                .background(.bar)

            if viewModel.isSelectionMode {
                Divider()
                batchActionBar
                    .padding(.horizontal, DesignTokens.Padding.page)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.06))
            }

            Divider()

            HStack(spacing: 0) {
                Group {
                    if viewModel.filteredSegments.isEmpty {
                        emptyState
                    } else {
                        segmentContent
                    }
                }
                .frame(maxWidth: .infinity)

                if let seg = viewModel.selectedSegment {
                    Divider()
                    SegmentVariantInspector(segment: seg, dubVM: dubVM)
                }
            }
        }
        .navigationTitle("分镜素材库")
        // ⚠️ 配音错误的 alert 必须挂在**页面顶层**。
        // 原先它挂在 DubSettingsBar 里，而那个组件只在「普通视频」分组标题行渲染，
        // 外层还是 LazyVStack —— 于是两种情况下报错完全看不到：
        //   ① 项目只有「自建分镜」（该分支不渲染 DubSettingsBar）
        //   ② 分组标题被滚出可视区，Lazy 容器把宿主回收掉
        // 结果就是配音失败后界面只是转一圈然后恢复原样，用户完全不知道发生了什么。
        .alert("配音", isPresented: Binding(
            get: { dubVM.errorMessage != nil },
            set: { if !$0 { dubVM.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { dubVM.errorMessage = nil }
        } message: {
            Text(dubVM.errorMessage ?? "")
        }
        .sheet(item: $viewModel.shotEditRequestSegment) { seg in
            ShotEditSheet(segment: seg)
        }
        .sheet(item: $viewModel.splitRequestSegment) { seg in
            SplitSegmentSheet(segment: seg, importVM: importVM) {
                viewModel.loadSegments(for: project)
            }
        }
        .sheet(isPresented: $showBatchExportSheet) {
            BatchExportSheet(
                segments: viewModel.selectedSegments,
                numberProvider: { viewModel.number(for: $0) }
            )
        }
        .background(
            // 隐藏快捷键：ESC 退出多选；⌘A 全选；⌘D 反选；⌘0 清空
            Group {
                if viewModel.isSelectionMode {
                    Button("") {
                        withAnimation(DesignTokens.Motion.hover) {
                            viewModel.setSelectionMode(false)
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)

                    Button("") { viewModel.selectAllVisible() }
                        .keyboardShortcut("a", modifiers: .command)
                        .opacity(0)

                    Button("") { viewModel.invertSelectionVisible() }
                        .keyboardShortcut("d", modifiers: .command)
                        .opacity(0)

                    Button("") { viewModel.clearSelection() }
                        .keyboardShortcut("0", modifiers: .command)
                        .opacity(0)
                }
            }
        )
    }

    // MARK: - 多选操作栏（启用多选时显示）

    private var batchActionBar: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: "checkmark.square.fill")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(Color.accentColor)
            // ⚠️ 这一行元素多、且都是中文：不加 lineLimit/fixedSize 的话，
            // 窄窗口下 SwiftUI 会把中文逐字换行，压成竖排单字（导入页标签就踩过这个坑）。
            Text("已选 \(viewModel.selectedSegmentIDs.count) 个 · \(String(format: "%.1fs", viewModel.selectedDuration))")
                .font(DesignTokens.Typography.labelEmphasis)
                .lineLimit(1)
                .fixedSize()

            Divider().frame(height: 12)

            // ⚠️ `.buttonStyle(.plain)` 不会自动做 disabled 减淡，而显式 `.foregroundStyle`
            // 又会**覆盖**系统的禁用态着色 —— 结果禁用和可用像素级一致，用户点了没反应会以为卡死。
            // 这里改用 `.borderless`（原生支持禁用态），颜色交给 tint。
            Button("全选") { viewModel.selectAllVisible() }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .fixedSize()

            Button("反选") { viewModel.invertSelectionVisible() }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .fixedSize()

            Button("清空选择") { viewModel.clearSelection() }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .fixedSize()
                .disabled(viewModel.selectedSegmentIDs.isEmpty)

            // 发现性提示：⇧+点击是隐藏能力，不提示用户根本不会知道
            Text("⇧ 点击可连选")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help("按住 Shift 点击另一个分镜，可一次选中两者之间的全部分镜")

            Spacer()

            Button {
                showBatchDeleteConfirm = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "trash")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("批量删除")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .disabled(viewModel.selectedSegmentIDs.isEmpty)

            // 批量标记素材来源（自拍/搬运/AI/未分类，5 秒撤销）
            Menu {
                ForEach([SegmentSource.selfShot, .curated, .aiGenerated, .unclassified],
                        id: \.rawValue) { source in
                    Button(source.displayName) {
                        viewModel.applySourceToSelected(source)
                    }
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "tag")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("标记来源")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.selectedSegmentIDs.isEmpty)
            .help("把所选分镜统一标记为自拍/搬运/AI/未分类")

            Button {
                showArrangeSheet = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("组合为方案")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.purple)
            .disabled(viewModel.selectedSegmentIDs.count < 2)
            .help(viewModel.selectedSegmentIDs.count < 2 ? "至少选择 2 个分镜" : "把选中分镜组合为自定义方案")

            Button {
                showBatchExportSheet = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "square.and.arrow.up")
                        .font(DesignTokens.Typography.captionEmphasis)
                    Text("批量导出 \(viewModel.selectedSegmentIDs.count) 个")
                        .font(DesignTokens.Typography.labelEmphasis)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.selectedSegmentIDs.isEmpty)
        }
        .sheet(isPresented: $showArrangeSheet) {
            ArrangeOrderSheet(
                // 用"勾选先后顺序"而非"按时间排序"——尊重用户挑选先后
                initialSegments: viewModel.orderedSelectedSegments,
                onCancel: { showArrangeSheet = false },
                onConfirm: { ordered in
                    // ⚠️ 不要在 await 之前关窗：sheet 自带的 isGenerating 转圈才有机会显示，
                    // 否则整个 AI 调用期间界面毫无指示，用户以为"点了没反应"。
                    let scheme = await schemeVM.createCustomScheme(from: ordered, in: project)
                    showArrangeSheet = false
                    if scheme != nil {
                        ToastCenter.shared.show("自定义方案已生成", icon: "checkmark.circle.fill", style: .success)
                        viewModel.setSelectionMode(false)
                        // 通过通知跳转到方案板块
                        NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.schemes)
                    } else {
                        // 失败必须出声：此前没有 else 分支，用户只会看到 toast 淡出后什么都没发生。
                        ToastCenter.shared.show(schemeVM.errorMessage ?? "方案生成失败，请重试",
                                                icon: "exclamationmark.triangle.fill", style: .warning, duration: 4)
                    }
                }
            )
        }
        .alert("确认批量删除", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                // Toast（含「撤销」按钮）由 deleteSelectedSegments 内部弹出
                viewModel.deleteSelectedSegments()
            }
        } message: {
            Text("将删除 \(viewModel.selectedSegmentIDs.count) 个分镜。删除后 5 秒内可点「撤销」找回。")
        }
    }

    // MARK: - 筛选工具栏

    private var filterToolbar: some View {
        VStack(spacing: 10) {
            // 搜索 + 视图切换 + 排序
            HStack(spacing: DesignTokens.Spacing.normal) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.tertiary)
                    TextField("搜索台词或关键词...", text: $viewModel.filter.searchText)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.body)
                        // 防抖：每次按键都跑 applyFilter 会对全部分镜重新筛选 + 排序 + 重建分组，
                        // 分镜多时打字会明显掉帧。停止输入 250ms 后再算一次。
                        .onChange(of: viewModel.filter.searchText) { _, _ in
                            searchDebounceTask?.cancel()
                            searchDebounceTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                guard !Task.isCancelled else { return }
                                viewModel.applyFilter()
                            }
                        }
                    if !viewModel.filter.searchText.isEmpty {
                        Button {
                            viewModel.filter.searchText = ""
                            viewModel.applyFilter()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DesignTokens.Typography.label)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 图标分段控件隐藏文字标签：标签和控件挤在 80pt 固定宽里，
                // 会把「视图」压成竖排单字。图标语义自明，用 tooltip 补充说明即可。
                Picker("视图", selection: $viewModel.isGridView) {
                    Image(systemName: "square.grid.2x2").tag(true)
                    Image(systemName: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
                .help("切换网格 / 列表视图")

                Picker("排序", selection: $viewModel.sortByQuality) {
                    Text("时间").tag(false)
                    Text("质量").tag(true)
                }
                .onChange(of: viewModel.sortByQuality) { _, _ in
                    viewModel.applyFilter()
                }
                // 宽度要同时容纳「排序」标签 + 选项，原来的 100pt 会把标签挤换行
                .frame(width: 150)


                // 多选开关
                Button {
                    viewModel.setSelectionMode(!viewModel.isSelectionMode)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: viewModel.isSelectionMode
                            ? "checkmark.square.fill" : "square.dashed")
                            .font(DesignTokens.Typography.captionEmphasis)
                        Text(viewModel.isSelectionMode ? "退出多选" : "多选")
                            .font(DesignTokens.Typography.labelStrong)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(viewModel.isSelectionMode
                        ? Color.accentColor.opacity(0.15)
                        : Color.secondary.opacity(0.08))
                    .foregroundStyle(viewModel.isSelectionMode ? Color.accentColor : .primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                // 上传自建分镜（PRD 05）：分镜库工具栏右侧常驻
                Button {
                    presentSelfSegmentUpload()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(DesignTokens.Typography.captionEmphasis)
                        Text("上传自建分镜")
                            .font(DesignTokens.Typography.bodyEmphasis)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("上传自己剪好的分镜（mp4/mov，单条 ≤ \(Int(ImportViewModel.selfSegmentMaxDuration)) 秒）")
            }

            // 素材来源筛选芯片（自拍/搬运/AI/未分类，与语义类型同排，用分隔点区分）
            SourceFilterChips(filter: $viewModel.filter,
                              counts: viewModel.countBySource,
                              onChange: { viewModel.applyFilter() })

            // 语义类型筛选芯片
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // 来源组与语义组之间留一个分隔点（首颗语义芯片前）
                    ForEach(SemanticType.allCases) { type in
                        FilterChip(
                            label: type.rawValue,
                            color: SemanticTypeTag.color(for: type),
                            count: viewModel.countByType[type] ?? 0,
                            isSelected: viewModel.filter.semanticTypes.contains(type)
                        ) {
                            if viewModel.filter.semanticTypes.contains(type) {
                                viewModel.filter.semanticTypes.remove(type)
                            } else {
                                viewModel.filter.semanticTypes.insert(type)
                            }
                            viewModel.applyFilter()
                        }
                    }
                }
            }

            // 统计 + 重置
            // ⚠️ lineLimit(1) 挂在拼接后的整条上，不挂在右半边 —— Text 修饰符对 `A + B`
            // 是否逐段生效没有保证，套在 Group 上才是确定的。这里只加 lineLimit、
            // **不加 fixedSize**：这一行今天没塌，加 fixedSize 反而可能把它顶出工具栏。
            HStack(spacing: DesignTokens.Spacing.compact) {
                Group {
                    Text("\(viewModel.filteredSegments.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    +
                    Text(" / \(viewModel.segments.count) 个分镜")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)

                Spacer()

                if !viewModel.filter.semanticTypes.isEmpty || !viewModel.filter.searchText.isEmpty {
                    Button {
                        withAnimation(DesignTokens.Motion.transition) {
                            viewModel.resetFilter()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(DesignTokens.Typography.microBold)
                            Text("重置")
                                .font(DesignTokens.Typography.caption)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 按视频分组的内容区（单层懒容器 + 扁平行投影）
    //
    // 滚动条不跳的结构前提（WWDC26 Session 321）：ForEach 每个元素必须对应一个身份稳定、
    // 高度可预测、出现后布局不再变的子视图。旧实现「LazyVStack(section) 内嵌 LazyVGrid」是
    // 两个懒布局系统互相估算，快速滚动时总高成片修正 → knob 跳。现在由 MixCutCore 的
    // LibraryRowLayout 把分组拍平成「标题行/卡片行」单层序列，行高固定、id 稳定。

    private var gridColumnCount: Int {
        guard libraryWidth > 0 else { return 1 }
        let spacing = DesignTokens.Spacing.normal
        return max(1, Int((libraryWidth + spacing) / (SegmentLibraryMetrics.gridMinCardWidth + spacing)))
    }

    private var cardWidth: CGFloat {
        guard libraryWidth > 0 else { return SegmentLibraryMetrics.gridMinCardWidth }
        let cols = CGFloat(gridColumnCount)
        let spacing = DesignTokens.Spacing.normal
        return floor((libraryWidth - (cols - 1) * spacing) / cols)
    }

    private var libraryRows: [LibraryRow] {
        let refs = viewModel.groupedSegments.map {
            LibraryGroupRef(id: $0.id, segmentIDs: $0.segments.map(\.id))
        }
        return LibraryRowLayout.rows(for: refs,
                                    columnCount: gridColumnCount,
                                    isGrid: viewModel.isGridView)
    }

    private var segmentContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                ForEach(libraryRows, id: \.id) { row in
                    if case .header(let groupID) = row, let group = viewModel.groupByID[groupID] {
                        sectionHeader(group)
                            .padding(.top, DesignTokens.Spacing.normal)
                    }
                    if case .cards(let groupID, _, let segmentIDs) = row {
                        cardsRow(groupID: groupID, segmentIDs: segmentIDs)
                    }
                }
            }
            .padding(DesignTokens.Spacing.comfortable)
            // 宽度在背景层间接测量：GeometryReader 不做内容根，避免以零宽/无限提案扰乱懒布局。
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: LibraryContentWidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(LibraryContentWidthKey.self) { width in
                if abs(width - libraryWidth) > 0.5 { libraryWidth = width }
            }
        }
    }

    /// 视频编号：与素材导入页徽章、Agent（MCP）的 video_no 同一套规则——
    /// 项目内按导入时间升序 1 起，动态计算，删除后自动前补。
    /// 规则真源在 `Project.videoNoByVideoID`（内部调用 MixCutCore.ProjectVideoDedup）；
    /// 这里曾经自己 sort + 建 uniqueKeys 字典，重复关联一到就 SIGTRAP —— 别再在本文件重写一遍。
    private var videoNoByID: [UUID: Int] {
        project.videoNoByVideoID
    }

    /// 分组标题行（自建分镜聚合组 vs 普通视频分组）
    private func sectionHeader(_ group: VideoSegmentGroup) -> some View {
        HStack(spacing: 10) {
            if group.isSelfBuilt {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 20, height: 36)
                    .overlay {
                        Image(systemName: "square.and.arrow.up")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(Color.accentColor)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("自建分镜")
                        .font(DesignTokens.Typography.labelStrong)
                        .lineLimit(1)
                    Text("\(group.segments.count) 个分镜 · 我上传的")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else if let video = group.video {
                AsyncCachedImage(
                    path: video.thumbnailPath,
                    placeholder: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "film")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.tertiary)
                            }
                    },
                    imageContent: { image in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(DesignTokens.Palette.border, lineWidth: 1)
                            )
                    }
                )
                .frame(width: 20, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let no = videoNoByID[video.id] {
                            Text("\(no) 号")
                                .font(DesignTokens.Typography.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1.5)
                                .background(.black.opacity(0.62), in: Capsule())
                        }
                        Text(video.name)
                            .font(DesignTokens.Typography.labelStrong)
                            .lineLimit(1)
                    }
                    Text("\(group.segments.count) 个分镜 · \(String(format: "%.0f", video.duration))s")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 视频专属「配音」栏（自建分镜组由多个载体视频组成，不显示视频级批量栏，逐卡各自配音）
                // 放进分组标题行：这些控件作用于「这个视频」，单独占一行浮在右侧看不出归属。
                DubSettingsBar(video: video, dubVM: dubVM)
            }
        }
        .padding(.horizontal, 4)
    }

    /// 一行卡片（网格模式 1...N 个、固定等宽；列表模式恒 1 个、铺满）。
    ///
    /// 性能关键（沿袭旧实现）：父视图一次性算好 isChecked / sequenceNumber 等 props 下发，
    /// 卡片 Equatable + .equatable() 后，选中变化只重绘对应卡片。模型按 id 从 VM 字典回查，
    /// 禁止强解（重认台词/删除撤销等异步回写可能让行投影与字典短暂跨相位）。
    @ViewBuilder
    private func cardsRow(groupID: UUID, segmentIDs: [UUID]) -> some View {
        let selectionMode = viewModel.isSelectionMode
        let selectedIDs = viewModel.selectedSegmentIDs
        let selectedSegID = viewModel.selectedSegment?.id
        let numMap = viewModel.numberByVideo[groupID] ?? [:]

        if viewModel.isGridView {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.normal) {
                ForEach(segmentIDs, id: \.self) { segmentID in
                    if let segment = viewModel.segmentByID[segmentID] {
                        SegmentCard(
                            segment: segment,
                            isChecked: selectedIDs.contains(segment.id),
                            isSelectionMode: selectionMode,
                            isSelected: segment.id == selectedSegID,
                            sequenceNumber: numMap[segment.id] ?? 0,
                            viewModel: viewModel
                        )
                        .equatable()
                        // 必须显式给宽：HStack 不像 LazyVGrid 那样提供列宽提案，
                        // 不给宽卡片会按理想宽塌缩、右面板 flexible 宽度分配不确定。
                        .frame(width: cardWidth)
                    }
                }
            }
        } else if let segment = segmentIDs.first.flatMap({ viewModel.segmentByID[$0] }) {
            SegmentRow(
                segment: segment,
                isChecked: selectedIDs.contains(segment.id),
                isSelectionMode: selectionMode,
                isSelected: segment.id == selectedSegID,
                sequenceNumber: numMap[segment.id] ?? 0,
                viewModel: viewModel
            )
            .equatable()
        }
    }

    // MARK: - 空状态

    /// 是否"本来就没有分镜"（而非被筛选条件挡掉了）。
    /// 两种情况的文案与出口完全不同，混用会出现「已有 200 个分镜却提示请先导入视频」的误导。
    private var hasNoSegmentsAtAll: Bool { viewModel.segments.isEmpty }

    @ViewBuilder
    private var emptyState: some View {
        if hasNoSegmentsAtAll {
            emptyStateNoData
        } else {
            emptyStateNoMatch
        }
    }

    /// 真的一个分镜都没有 —— 给明确的下一步出口，别让用户困在死胡同里。
    private var emptyStateNoData: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            VStack(spacing: DesignTokens.Spacing.tight) {
                Text("还没有分镜")
                    .font(DesignTokens.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Text("导入视频后，AI 会自动切分并标注分镜；也可以直接上传已剪好的分镜。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            HStack(spacing: DesignTokens.Spacing.compact) {
                Button {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.importMedia)
                } label: {
                    Label("去导入视频", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    presentSelfSegmentUpload()
                } label: {
                    Label("上传自建分镜", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 有数据但被筛选挡掉了 —— 给「清除筛选」而不是"请先导入视频"。
    private var emptyStateNoMatch: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
            VStack(spacing: DesignTokens.Spacing.tight) {
                Text("没有符合条件的分镜")
                    .font(DesignTokens.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Text("共 \(viewModel.segments.count) 个分镜，当前筛选条件下没有匹配项。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.tertiary)
            }
            Button {
                viewModel.clearFilters()
            } label: {
                Label("清除筛选条件", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 滚动性能基础设施

/// 素材库布局常量。两态等高（cell 出现后高度永不变，是滚动条不跳的前提）用到的数字集中在此。
private enum SegmentLibraryMetrics {
    /// 边界微调行的固定行高（TextField 16pt + 上下边距），卡片/列表行的「激活/非激活」两态共用。
    static let boundaryRowHeight: CGFloat = 24
    /// hover 停留多久才激活重子树（播放器完整态/AVPlayer、BoundaryAdjustRow、编辑按钮）。
    /// 快速惯性滚动中单卡停留远小于此值 → 滚动中零结构翻转、零误播放。
    static let hoverActivationDelay: Duration = .milliseconds(280)
    /// 网格最小卡宽（与旧 GridItem(.adaptive(minimum:)) 同一口径）。
    static let gridMinCardWidth: CGFloat = 360
}

/// 滚动内容宽度偏好键：只在滚动内容上放一个 GeometryReader（间接测量，不做内容根）。
private struct LibraryContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 延迟激活的 hover 状态（仅激活态）。播放器使用：不需要即时底色反馈。
private struct HoverActivationModifier: ViewModifier {
    @Binding var isActive: Bool
    var delay: Duration
    @State private var activationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                activationTask?.cancel()
                activationTask = nil
                guard hovering else {
                    isActive = false
                    return
                }
                activationTask = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    isActive = true
                }
            }
            .onDisappear {
                activationTask?.cancel()
                activationTask = nil
                isActive = false
            }
    }
}

/// 两层 hover 状态：`isHovering` 即时跟随（只喂底色等零成本反馈，不加动画）；
/// `isActive` 停留 `delay` 后才翻转（喂重子树）。卡片/列表行使用。
private struct HoverStateModifier: ViewModifier {
    @Binding var isHovering: Bool
    @Binding var isActive: Bool
    var delay: Duration
    @State private var activationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                activationTask?.cancel()
                activationTask = nil
                isHovering = hovering
                guard hovering else {
                    isActive = false
                    return
                }
                activationTask = Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    isActive = true
                }
            }
            .onDisappear {
                activationTask?.cancel()
                activationTask = nil
                isHovering = false
                isActive = false
            }
    }
}

private extension View {
    func hoverActivated(isActive: Binding<Bool>,
                        delay: Duration = SegmentLibraryMetrics.hoverActivationDelay) -> some View {
        modifier(HoverActivationModifier(isActive: isActive, delay: delay))
    }

    func hoverState(isHovering: Binding<Bool>,
                    isActive: Binding<Bool>,
                    delay: Duration = SegmentLibraryMetrics.hoverActivationDelay) -> some View {
        modifier(HoverStateModifier(isHovering: isHovering, isActive: isActive, delay: delay))
    }
}

// MARK: - 分镜卡片

/// 把「可拖的遮挡框 + 可调高的底部手柄」挂到一个 9:16 画布上。
///
/// ⚠️ 网格卡与列表行**共用这一份挂载**：以前它只写在卡片里，我把效果预览放进三处共用的播放器之后，
/// 列表行就变成"看得见带子、却改不了位置和高度"——作用面比控制面宽，正是用户报的第 3 个 bug 的同一形状。
/// 抄第二份到行里，将来改下限规则/保存时机就会两处漂移，所以收成一条扩展方法。
///
/// 前提：调用方给的是**固定 9:16 画布**（`maskRect` 的归一化空间就是它）。卡片 200×200·16/9，
/// 行 160×160·16/9 —— 两侧都必须写死高度，不能让播放器按缩略图自身比例长，否则横屏素材上
/// 行内的带子位置与导出（按 pad 后的 9:16 算）会分叉。
fileprivate extension View {
    func subtitleMaskHandle(on segment: Segment, save: @escaping () -> Void) -> some View {
        overlay {
            if segment.hasHardSubtitle {
                SubtitleMaskOverlay(
                    rect: Binding(
                        get: { segment.maskRect },
                        set: { segment.maskRect = $0 }      // 仅写内存，拖拽期间不保存
                    ),
                    // 下限跟着**这个分镜自己的**字号：带再矮就盖不住它要挡的那行字了
                    minBandHeight: SubtitleMaskRect
                        .minimumHeight(fontRatio: segment.subtitleFontRatio),
                    onCommit: save                          // 松手才保存一次
                )
            }
        }
    }
}

/// SegmentCard 关键性能优化：
/// - 实现 Equatable，让 SwiftUI 在 reconcile 时跳过未变化的卡片 body 评估
/// - isChecked / isSelectionMode / sequenceNumber 通过 props 接收，**不直接访问 viewModel**
///   避免「访问 selectedSegmentIDs → 整个 Set 注册依赖 → 任意选中变化触发所有卡片重绘」的陷阱
/// - viewModel 仍然持有，用于 action（toggleSelection / deleteSegment / requestPlay）
struct SegmentCard: View, Equatable {
    let segment: Segment
    let isChecked: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let sequenceNumber: Int
    @Bindable var viewModel: SegmentLibraryViewModel

    @Environment(\.modelContext) private var modelContext

    /// 即时 hover（只喂底色/描边等零成本反馈）
    @State private var isHovering = false
    /// 延迟激活 hover（停留 SegmentLibraryMetrics.hoverActivationDelay 后才 true，喂重子树）
    @State private var isHoverActive = false
    @State private var showDeleteConfirm = false

    // 行内编辑台词
    @State private var isEditingText = false
    @State private var draftText = ""
    @FocusState private var textEditorFocused: Bool

    // Equatable：SwiftUI 看到这俩相等就跳过 body 评估
    // viewModel 引用不参与比较（Bindable 让其变化通过 @State observation 触发，跟 Equatable 跳过逻辑互不冲突）
    //
    // ⚠️ **这里只准比较父级每次重建的值类型 props。**
    // `Segment` 是 class，同一个 ModelContext 里对象唯一 ⇒ `lhs.segment === rhs.segment` 恒成立，
    // 于是任何 `lhs.segment.<字段> == rhs.segment.<字段>` 都是拿一次读数和它自己比 —— 恒真、不承重。
    // 它长得极像一道防线，所以曾经骗过我们一次：:724 那条「字号必须参与比较」的注释说漏掉它会让
    // EquatableView 跳过重绘，实际加不加都一样，字号滑条一直是靠 Observation 刷新的。
    // 卡片内容的刷新纪律在模型层：body 只准读被跟踪的访问器，带缓存的计算属性必须先读底层字段
    // （见 Segment.swift `DecodedCache` 约束 #4）。守卫 = SegmentRenderFreshnessTests 的 G1。
    // 唯一豁免 `.id`：它防的是"这张卡被重绑到另一行"，不是恒真。
    static func == (lhs: SegmentCard, rhs: SegmentCard) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.isSelected == rhs.isSelected
            && lhs.sequenceNumber == rhs.sequenceNumber
    }

    var body: some View {
        fullCard
    }

    /// 完整卡片
    private var fullCard: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧：视频 + 标签 + 时间调整
            // ⚠️ 200pt 是**写死的**，它和侧栏 220（ContentView.swift:59）、配音变体池 340
            // （SegmentVariantInspector.swift:107）三处相加，在窗口 minWidth 900（ContentView.swift:137）
            // 之下只给右面板留下约 100pt（2026-10-01 真机截图量得，卡片宽 ≈300）。
            // 台词头部行的三档降级就是照这个数选的档；⌘B 收起侧栏能拿回 220pt。
            // 想缩这个 200 之前先读 `SubtitleSizePreviewOverlay(frameWidth:)` 那一处 —— 所见即所得的
            // 字幕预览与遮挡层几何是按 200 宽算的，改宽度得连换算一起改。
            leftPanel
                .frame(width: 200)

            // 分隔线
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .padding(.vertical, 8)

            // 右侧：台词全文显示（不再内嵌 ScrollView，也不再用 preference 回传高度二次布局）
            rightPanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isChecked
                      ? Color.accentColor.opacity(0.10)
                      : isSelected
                        ? Color.accentColor.opacity(0.06)
                        : isHovering
                          ? Color(.controlBackgroundColor).opacity(0.8)
                          : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isChecked ? Color.accentColor :
                        isSelected ? Color.accentColor.opacity(0.5) : DesignTokens.Palette.border,
                        lineWidth: isChecked ? 2 : 1)
        )
        .overlay {
            // 自建分镜处理态占位：识别中 → 打标中（就绪/失败则不显示）
            if segment.video?.isUserUploaded == true,
               let st = segment.video?.status, st != .completed, st != .failed {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.38))
                    .overlay {
                        VStack(spacing: DesignTokens.Spacing.compact) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(st == .analyzing ? "打标中…" : "识别中…")
                                .font(DesignTokens.Typography.caption).foregroundStyle(.white)
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        // 两层 hover：底色即时反馈、重子树（BoundaryAdjustRow/播放/编辑按钮）延迟激活。
        // 惯性滚动中卡片从指针下穿过，停留不足激活延时，重子树全程不挂载。
        .hoverState(isHovering: $isHovering, isActive: $isHoverActive)
        // ⇧+点击 = 范围多选（Finder 同款）；普通点击 = 单个切换
        .onTapGesture {
            if isSelectionMode {
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.extendSelection(to: segment)
                } else {
                    viewModel.toggleSelection(segment)
                }
            } else {
                // 非多选：点击选中分镜 → 打开右侧配音变体检视栏
                viewModel.selectedSegment = segment
            }
        }
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
                ToastCenter.shared.show("台词已复制", icon: "doc.on.doc.fill")
            } label: {
                Label("复制台词", systemImage: "doc.on.doc")
            }
            .disabled(segment.text.isEmpty)

            Button {
                draftText = segment.text
                isEditingText = true
                textEditorFocused = true
            } label: {
                Label("编辑台词", systemImage: "square.and.pencil")
            }

            Button {
                viewModel.shotEditRequestSegment = segment
            } label: {
                Label("分镜头替换", systemImage: "wand.and.stars")
            }

            Button {
                if segment.schemeSegments.isEmpty {
                    viewModel.splitRequestSegment = segment
                } else {
                    ToastCenter.shared.show("该分镜已被 \(segment.schemeSegments.count) 个方案组合使用，请先在方案里移除对它的使用，再来拆分",
                                            icon: "exclamationmark.triangle.fill", style: .warning, duration: 3.5)
                }
            } label: {
                Label("拆分分镜", systemImage: "scissors")
            }

            if segment.replacedPictureVideoPath != nil {
                Button(role: .destructive) {
                    segment.replacedPictureVideoPath = nil
                    segment.replacedPictureThumbnailPath = nil
                    segment.replacedPictureFrameCount = 0
                    segment.pictureShowsReplaced = false
                    try? modelContext.save()   // 旧文件留给孤儿 GC 回收
                } label: {
                    Label("删除替换画面", systemImage: "photo.badge.arrow.down")
                }
            }

            // 素材来源（分镜级逐条改；菜单内按钮只在弹出时挂载，不增加卡片常驻重量）
            Menu("标记素材来源") {
                ForEach([SegmentSource.selfShot, .curated, .aiGenerated, .unclassified],
                        id: \.rawValue) { source in
                    Button {
                        modelContext.undoManager?.setActionName("标记来源")
                        segment.setSource(source)
                        try? modelContext.save()
                    } label: {
                        Label(source.displayName,
                              systemImage: segment.source == source ? "checkmark" : "")
                    }
                }
            }

            if let videoPath = segment.video?.localPath, !videoPath.isEmpty {
                Button {
                    let url = URL(fileURLWithPath: videoPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("在 Finder 中显示原视频", systemImage: "folder")
                }
            }

            if isSelectionMode {
                Button {
                    viewModel.toggleSelection(segment)
                } label: {
                    Label(isChecked ? "取消选中" : "选中",
                          systemImage: isChecked ? "checkmark.square" : "square")
                }
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除分镜", systemImage: "trash")
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                // Toast（含「撤销」按钮）由 deleteSegment 内部弹出
                viewModel.deleteSegment(segment)
            }
        } message: {
            Text("将删除这个分镜。删除后 5 秒内可点「撤销」找回。")
        }
    }

    // MARK: - 左侧面板
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 播放器 + 左上角 #编号 + 多选 checkbox 叠加
            // SegmentInlinePlayer 不再内部约束 aspect ratio，由调用方给死 9:16 (CLAUDE.md)
            SegmentInlinePlayer(segment: segment, viewModel: viewModel)
                .frame(width: 200, height: 200.0 * 16.0 / 9.0)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        if isSelectionMode {
                            Image(systemName: isChecked
                                ? "checkmark.square.fill" : "square")
                                .font(DesignTokens.Typography.title)
                                .foregroundStyle(isChecked ? Color.accentColor : .white)
                                .shadow(color: .black.opacity(0.5), radius: 1)
                        }
                        if sequenceNumber > 0 {
                            Text("#\(sequenceNumber)")
                                .font(DesignTokens.Typography.microMetric)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    // 就地替换画面：切换按钮（仅当存在替换画面时显示）原画面 ↔ 替换画面
                    if segment.replacedPictureVideoPath != nil {
                        Button {
                            segment.pictureShowsReplaced.toggle()
                            try? modelContext.save()
                        } label: {
                            HStack(spacing: 3) {
                                // ⚠️ 原来用 arrow.triangle.2.circlepath（HIG 里是"刷新/重试"语义），
                                // 与全 App 的重试按钮撞车。这里是"原画面 ↔ 替换画面"的二选一切换，
                                // 用交换语义的图标才不会误导。
                                Image(systemName: "rectangle.2.swap")
                                Text(segment.pictureShowsReplaced ? "替换画面" : "原画面")
                            }
                            .font(DesignTokens.Typography.microEmphasis)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(segment.pictureShowsReplaced
                                ? Color.green.opacity(0.75) : Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("在原画面与 AI 替换画面之间切换")
                    }
                }
                .subtitleMaskHandle(on: segment) { try? modelContext.save() }
                // 字幕字号所见即所得：示例字幕按全局比例叠在真实画面上，居中于遮挡区、
                // 跟随遮挡框移动，可与原字幕比大小与位置
                .overlay {
                    if !segment.isVoiceLocked {
                        SubtitleSizePreviewOverlay(
                            fontRatio: segment.subtitleFontRatio,
                            frameWidth: 200,
                            frameHeight: 200.0 * 16.0 / 9.0,
                            maskRect: segment.maskRect,
                            burnsBackdrop: SubtitleMaskMode
                                .from(hasHardSubtitle: segment.hasHardSubtitle,
                                      maskStyleRaw: segment.maskStyleRaw)
                                .burnsCaptionBackdrop)
                    }
                }

            // 标签行：语义类型 + 位置 + 来源
            FlowLayout(spacing: 3) {
                ForEach(segment.semanticTypes, id: \.self) { type in
                    SemanticTypeTag(type: type)
                }
                PositionTypeTag(type: segment.positionType)
                QualityBadge(score: segment.qualityScore)
                SourceBadge(source: segment.source)
                    .help("素材来源：\(segment.source.displayName)（右键可改）")
            }

            // 配音控件：保留原声 + 硬字幕遮挡开关
            SegmentDubControls(
                isVoiceLocked: Binding(
                    get: { segment.isVoiceLocked },
                    set: { segment.isVoiceLocked = $0; try? modelContext.save() }
                ),
                treatment: Binding(
                    get: { segment.subtitleTreatment },
                    set: { segment.subtitleTreatment = $0; try? modelContext.save() }
                ),
                onApplyMaskToAll: { Self.applyMaskToAllSegments(of: segment, in: modelContext) },
                fontRatio: Binding(
                    get: { segment.subtitleFontRatio },
                    set: {
                        segment.setSubtitleFontRatio($0)
                        modelContext.safeSave()
                    }
                ),
                onApplyFontSizeToAll: { Self.applyFontSizeToAllSegments(of: segment, in: modelContext) }
            )

            // 边界微调 —— 激活或选中时才挂载（含多 TextField+@FocusState，常驻会让几十个卡片
            // 同步实例化上百颗交互控件）。两态共用同一固定高度槽位：激活前后卡片高度零变化，
            // 这是懒容器行高估算稳定（滚动条不跳）的前提。
            ZStack(alignment: .topLeading) {
                Color.clear
                if isHoverActive || isSelected {
                    BoundaryAdjustRow(segment: segment, viewModel: viewModel)
                }
            }
            .frame(height: SegmentLibraryMetrics.boundaryRowHeight)
        }
        .padding(8)
    }

    // MARK: - 右侧台词面板的头部行（窄容器三档降级）
    //
    // ⚠️ 这一行四段中文原先**一个 lineLimit 都没有**。素材库窗口里右面板被三处硬宽度挤到
    // 约 100pt（侧栏 220 + 配音变体池 340 + 卡片左面板 200，见下面 leftPanel 的 `.frame(width: 200)`），
    // SwiftUI 于是把中文逐字断行、压成"台/词"这样的竖排单字，再被 `rightPanel` 的
    // `.frame(height: leftHeight).clipped()` 裁掉 —— 看起来就像"台词 16字 手动编辑"撞在一起。
    // 同类缺陷这文件里已是第三次（:168 与 :339 的注释各记过一次），差别只在这行的可压缩性没声明。
    //
    // 三档降级靠 `ViewThatFits` 选档，**关键是前两档必须 fixedSize**：
    // 只给 `.lineLimit(1)` 的 Text 在水平方向是可变窄的（靠截断接受任何提案宽），
    // `sizeThatFits` 会永远回报"放得下" ⇒ 第一档永选、后两档成为死码。
    // 兜底档反过来**不能** fixedSize —— `ViewThatFits` 的语义是"一档都放不下就用最后一个"，
    // 若最后一个也按理想宽报，它会溢出再被裁掉，丢的是行尾的编辑/重认按钮。
    private func transcriptHeader(count: Bool, provenance: Bool, compressibleLabels: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            Image(systemName: "text.quote")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary)
            transcriptHeaderLabel(Text("台词")
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.secondary), compressibleLabels)
            if count {
                transcriptHeaderLabel(Text("\(segment.text.count)字")
                    .font(DesignTokens.Typography.microMono)
                    .foregroundStyle(.tertiary), compressibleLabels)
            }
            if provenance {
                // 台词来源。旧数据那一档显示"旧数据·未记录来源"，用**中性色**：
                // 它是"没记过"，不是"坏了"——标红会让升级当天的整库看起来全出问题（计划 §6 P2-8）。
                // 它也是这一行里最长的一段，所以窄窗口下第一个被丢掉。
                transcriptHeaderLabel(Text(TextProvenance.displayLabel(of: segment.textSource))
                    .font(DesignTokens.Typography.microMono)
                    .foregroundStyle(.tertiary), compressibleLabels)
            }
            Spacer(minLength: 4)
            transcriptHeaderButtons
        }
    }

    private func transcriptHeaderLabel(_ label: Text, _ compressible: Bool) -> some View {
        label.lineLimit(1).fixedSize(horizontal: !compressible, vertical: false)
    }

    /// 按钮区固定单行高度：按钮按激活/编辑态出现与否都不改变台词头部高度
    ///（cell 出现后布局不得变化，滚动条稳定性的前提）。
    @ViewBuilder private var transcriptHeaderButtons: some View {
        Group {
            if isEditingText {
                Button { isEditingText = false } label: {
                    Image(systemName: "xmark.circle.fill").font(DesignTokens.Typography.label)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("取消编辑").help("取消")
                Button { saveText() } label: {
                    Image(systemName: "checkmark.circle.fill").font(DesignTokens.Typography.label)
                }
                .buttonStyle(.plain).foregroundStyle(.green).accessibilityLabel("保存台词").help("保存（⌘↩）")
            } else if isHoverActive || isSelected {
            Button {
                draftText = segment.text
                isEditingText = true
                textEditorFocused = true
            } label: {
                Image(systemName: "square.and.pencil").font(DesignTokens.Typography.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("编辑台词").help("编辑台词")
            Button {
                Task { await viewModel.reextractTranscript(segment, context: modelContext) }
            } label: {
                if viewModel.busyASRSegmentIDs.contains(segment.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").font(DesignTokens.Typography.caption)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("重新识别台词")
            .disabled(viewModel.busyASRSegmentIDs.contains(segment.id))
            .help("重认这一段的台词：用哪台引擎由「设置 › 台词重听引擎」与决策表定；没认到字时原台词一字不动")
            }
        }
        .frame(height: 18)
    }

    // MARK: - 右侧台词面板
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                transcriptHeader(count: true, provenance: true, compressibleLabels: false)
                transcriptHeader(count: true, provenance: false, compressibleLabels: false)
                transcriptHeader(count: false, provenance: false, compressibleLabels: true)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if isEditingText {
                TextEditor(text: $draftText)
                    .font(DesignTokens.Typography.caption)
                    .lineSpacing(3)
                    .focused($textEditorFocused)
                    .scrollContentBackground(.hidden)
                    .background(Color(.textBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                    // ⌘↩ 保存
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { saveText(); return .handled }
                        return .ignored
                    }
            } else if segment.text.isEmpty {
                VStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "waveform.slash")
                        .font(DesignTokens.Typography.bodyLarge)
                        .foregroundStyle(.tertiary)
                    Text("暂无台词")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 全文显示（不截断）：不再内嵌 ScrollView——每卡一颗 NSScrollView 宿主曾是滚动掉帧源，
                // 且它依赖 preference 回传高度（首次布局先错后修）。卡片随台词自然增高，首次布局即真相。
                Text(segment.text)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 台词编辑

    /// 保存行内编辑的台词（全局共享，写回 Segment.text）
    private func saveText() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != segment.text {
            segment.setText(trimmed, source: .manualEdit)
            try? modelContext.save()
            ToastCenter.shared.show("台词已更新", icon: "checkmark.circle.fill")
        }
        isEditingText = false
        textEditorFocused = false
    }

    // MARK: - 遮挡应用

    /// 把当前分镜的字幕字号应用到**同一视频**的所有分镜（不跨视频）。
    /// 与「遮挡区应用到所有分镜」同一套模式：覆盖前存快照、完成后给可撤销的 Toast。
    ///
    /// 做成 `static` 是为了让网格卡与列表行共用同一份批量逻辑 —— 这两个入口改的是同一批字段，
    /// 各写一份就会出现"卡上撤销得回来、行上撤销不回来"这类分叉。
    fileprivate static func applyFontSizeToAllSegments(of source: Segment, in context: ModelContext) {
        guard let video = source.video else { return }
        let ratio = SubtitleFontSize.clamp(source.subtitleFontRatio)
        let targets = video.segments.filter { $0.id != source.id }
        guard !targets.isEmpty else {
            ToastCenter.shared.show("这个视频只有一个分镜，无需应用", icon: "info.circle.fill", style: .info)
            return
        }
        let snapshot: [(seg: Segment, ratio: Double)] = targets.map { ($0, $0.subtitleFontRatio) }
        for seg in targets { seg.subtitleFontRatio = ratio }
        context.safeSave()

        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已把字幕字号应用到本视频 \(targets.count) 个分镜",
            actionTitle: "撤销批量字号",
            seconds: 5
        ) {
            // 宽限期内分镜可能已被删除，写已删对象会崩溃 → 逐项守卫
            var restored = 0
            for item in snapshot where item.seg.modelContext != nil {
                item.seg.subtitleFontRatio = item.ratio
                restored += 1
            }
            context.safeSave()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原字幕字号"
                                    : "已还原 \(restored) 个分镜的字幕字号（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }

    /// 把当前分镜的遮挡设置应用到同一视频的所有分镜。
    ///
    /// 这是个**批量覆盖**操作：会盖掉其他分镜可能已经逐个微调好的遮挡框。
    /// 以前点完界面毫无变化（当前卡片本来就是这个值），用户根本不知道有没有生效，
    /// 也没有后悔药。现在：① 覆盖前先存快照；② 完成后 Toast 说明影响范围；③ 提供撤销。
    /// ⚠️ `static` 的理由同上：网格卡与列表行共用这一份批量逻辑与同一份撤销账。
    fileprivate static func applyMaskToAllSegments(of source: Segment, in context: ModelContext) {
        guard let video = source.video else { return }
        let rect = source.maskRect
        let style = source.maskStyle
        let hasSub = source.hasHardSubtitle

        let targets = video.segments.filter { $0.id != source.id }
        guard !targets.isEmpty else {
            ToastCenter.shared.show("这个视频只有一个分镜，无需应用", icon: "info.circle.fill", style: .info)
            return
        }

        // 快照旧值，供撤销还原
        let snapshot: [(seg: Segment, hasSub: Bool, rect: SubtitleMaskRect, style: MaskStyle)] =
            targets.map { ($0, $0.hasHardSubtitle, $0.maskRect, $0.maskStyle) }

        for seg in targets {
            seg.hasHardSubtitle = hasSub
            seg.maskRect = rect
            seg.maskStyle = style
        }
        try? context.save()

        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已把遮挡设置应用到 \(targets.count) 个分镜",
            actionTitle: "撤销批量遮挡",
            seconds: 5
        ) {
            // ⚠️ 撤销闭包最长在 5 秒后才执行，这期间用户完全可能删掉其中某个分镜
            // （删除走 PendingDeletionCenter，宽限期 5 分钟，到点后台自动真删）。
            // 两个窗口本来就不等长，所以这里从来不能假设"对象还在"：
            // 对已被 delete 的 SwiftData 对象写属性会直接崩溃（见 CLAUDE.md 删对象崩溃记录），
            // 所以逐项检查对象是否仍在上下文里，失效的跳过。
            var restored = 0
            for item in snapshot where item.seg.modelContext != nil {
                item.seg.hasHardSubtitle = item.hasSub
                item.seg.maskRect = item.rect
                item.seg.maskStyle = item.style
                restored += 1
            }
            try? context.save()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原遮挡设置"
                                    : "已还原 \(restored) 个分镜的遮挡设置（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }
}

// MARK: - 字幕字号所见即所得预览

/// 叠在分镜真实画面上的示例字幕，字号 = 画面显示宽 × 全局比例（与导出换算一致，见
/// SubtitleFontSize）；居中落在遮挡区（maskRect）正中并跟随遮挡框移动，与导出落位一致
/// （见 CaptionLayout.overlayOrigin）。拖字号滑条/拖遮挡框时实时变化。仅预览，不参与交互。
private struct SubtitleSizePreviewOverlay: View {
    /// 用**该分镜自己的**字号（不是全局设置），拖动弹层滑条时这里实时跟随
    let fontRatio: Double
    /// 画面在屏上的显示尺寸（此处播放器固定 200 × 200*16/9）
    let frameWidth: CGFloat
    let frameHeight: CGFloat
    let maskRect: SubtitleMaskRect
    /// 示例字幕要不要自带底衬 —— 由 `SubtitleMaskMode.burnsCaptionBackdrop` 给，
    /// 与导出侧读同一条规则（`solid` 已经铺了一条实色带，再叠底衬就是糊上加糊）。
    let burnsBackdrop: Bool

    var body: some View {
        let fontPt = frameWidth * SubtitleFontSize.clamp(fontRatio)
        let rect = maskRect.clamped()
        let cx = CGFloat(rect.x + rect.width / 2) * frameWidth
        let cy = CGFloat(rect.y + rect.height / 2) * frameHeight
        Text("这里是字幕")
            .font(.custom("PingFangSC-Semibold", size: fontPt))
            .foregroundStyle(.white)
            .padding(.horizontal, fontPt * 0.35)
            .padding(.vertical, fontPt * 0.18)
            .background {
                if burnsBackdrop {
                    RoundedRectangle(cornerRadius: fontPt * 0.25).fill(Color.black.opacity(0.5))
                }
            }
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
            .position(x: cx, y: cy)   // 落在遮挡区正中
            .allowsHitTesting(false)
    }
}

// MARK: - 缩略图缓存（避免 View body 中反复磁盘 IO）

// ThumbnailCache 已移到 Views/Shared/ThumbnailCache.swift，全局共享

// MARK: - 分镜原地播放器（hover 播放，全局唯一播放，原始比例）

struct SegmentInlinePlayer: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel
    /// 可选：选中配音变体的音频路径。非 nil 时播放静音视频原声、同步播此变体音轨（方案预览用）。
    var dubAudioPath: String? = nil

    @State private var player: AVPlayer?
    @State private var dubPlayer: AVAudioPlayer?
    @State private var bgmPlayer: AVAudioPlayer?   // 变体预览时叠加的分离背景音乐
    @State private var isPlaying = false
    @State private var isFrozen = false        // 播放到结尾后定格在最后一帧（非 nil player，但已暂停）
    @State private var timeObserver: Any?
    @State private var endNotifObserver: NSObjectProtocol?  // 到达 forwardPlaybackEndTime / 视频自然播完 → 定格
    @State private var currentTime: Double = 0
    /// hover 停留足够久后才激活：驱动「轻量缩略图态 → 完整播放态」翻转与自动播放。
    /// 快速惯性滚动中卡片在指针下一闪而过，永不激活（不翻转 UI、不创建 AVPlayer）。
    @State private var isHoverActive = false
    /// 当前缩略图（异步加载；主图与遮罩预览共用同一份，每卡只解码一次）
    @State private var thumbnail: NSImage?

    /// 视频原始宽高比
    private var videoAspectRatio: CGFloat {
        guard let video = segment.video, video.width > 0, video.height > 0 else {
            return 16.0 / 9.0
        }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    /// 显示用宽高比：固定为手机端 9:16 竖屏（信息流广告投放比例，见 CLAUDE.md）
    /// 视频原始比例不是 9:16 也会被 fit 到 9:16 容器内（contentMode: .fit 留黑边）
    private var displayAspectRatio: CGFloat {
        return 9.0 / 16.0
    }

    private var segmentDuration: Double {
        segment.endTime - segment.startTime
    }

    var body: some View {
        // 性能关键：默认只渲染缩略图 + 时长（最轻量），激活/播放才组装完整 ZStack
        Group {
            if !isHoverActive && !isPlaying && !isFrozen {
                // 静态轻量态：只有缩略图 + 时长角标
                thumbnailView
                    .overlay(alignment: .bottomTrailing) {
                        Text(String(format: "%.1fs", segmentDuration))
                            .font(DesignTokens.Typography.microMonoStrong)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                // 激活或播放态：完整 player UI
                playerUI
            }
        }
        // hover 统一挂在外层 Group（稳定容器）：静态↔playerUI 子视图切换不丢 hover 事件。
        // 延迟激活：滚动中一闪而过的卡片不翻转、不播放。
        .hoverActivated(isActive: $isHoverActive)
        .onChange(of: isHoverActive) { _, active in
            if active {
                viewModel.requestPlay(segment: segment)
            } else {
                if isPlaying || isFrozen { stopPlayback() }
                // 仅当全局仍是"我"在播才清空——避免离开本分镜时误杀刚移入的下一个分镜。
                if viewModel.playingSegmentID == segment.id { viewModel.stopCurrentPlayback() }
            }
        }
        // 缩略图按路径异步加载（主图与遮罩层共用）；路径变化（替换画面/边界换首帧）自动重取。
        .task(id: segment.effectivePicture.thumbnailPath) {
            guard let thumbPath = segment.effectivePicture.thumbnailPath else {
                thumbnail = nil
                return
            }
            if let cached = ThumbnailCache.shared.cachedImage(for: thumbPath) {
                thumbnail = cached
                return
            }
            let loaded = await ThumbnailCache.shared.loadImage(for: thumbPath)
            if !Task.isCancelled { thumbnail = loaded }
        }
        // ⚠️ 播放请求监听必须挂在 body 顶层（而非 playerUI 内）：空闲态只渲染缩略图时
        // 也要能响应微调（adjustStartTime/adjustEndTime）触发的 requestPlay，否则点加减不播放。
        // play() 会把 isPlaying 置 true，body 随即切到 playerUI。
        .onChange(of: viewModel.playingSegmentID) { _, newID in
            if newID != segment.id && (isPlaying || isFrozen) {
                stopPlayback()
            }
        }
        .onChange(of: viewModel.previewRequest) { _, newRequest in
            guard let request = newRequest,
                  request.segmentID == segment.id else { return }
            play(from: request.from, to: request.to)
            viewModel.previewRequest = nil
        }
    }

    @ViewBuilder
    private var playerUI: some View {
        ZStack {
            if (isPlaying || isFrozen), let player {
                PlayerRepresentable(player: player)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)   // F11/F12: 横屏视频在 9:16 容器内留黑边，不裁切
            } else {
                thumbnailView
            }

            if isHoverActive && !isPlaying && !isFrozen {
                Color.black.opacity(0.15)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }

            if isPlaying {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                            Capsule().fill(.white)
                                .frame(width: progressWidth(in: geo.size.width), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)   // 横屏视频 fit 进 9:16 的留边填黑，避免透出卡片底色的「透明边」
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // 注意：hover 已统一挂在 body 外层 Group，playerUI 内不再重复挂 onHover（会与子视图切换打架）。
        .onDisappear {
            stopPlayback()
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard segmentDuration > 0 else { return 0 }
        // 进度基准：替换版从 0 起（整段独立片），原版从源 startTime 起。
        let elapsed = currentTime - segment.effectivePicture.startTime
        return totalWidth * max(0, min(1, elapsed / segmentDuration))
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)   // F11/F12: 横屏视频在 9:16 容器内留黑边，不裁切
            } else {
                Rectangle()
                    .fill(Color(.windowBackgroundColor).opacity(0.3))
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)   // 横屏视频 fit 进 9:16 的留边填黑（否则透出卡片半透明底=「透明边」）
        // 遮挡效果预览。挂在**外层 Group** 上而不是里面的 Image 上：Image 经 `.aspectRatio(.fit)`
        // 之后只是中间那条带，而 `maskRect` 的归一化空间是**已 pad 的 9:16 画布**
        // （ffmpeg 侧同序：先 scale+pad 成画布，再套 mask）。
        .overlay { maskTreatmentPreview }
        .clipped()
    }

    /// 静止帧上的遮挡效果预览。
    ///
    /// ⚠️ 值全部来自 `SubtitleMaskMode.renderSpec` —— 与 `DubSegmentGraph` 读的是**同一张表**，
    /// 所以"屏幕上看到的"与"导出来的"由构造对齐，不靠人记得两边同改。
    /// 模式也走 `SubtitleMaskMode.from(...)` 同一个表达式（导出侧 `DubExportService` 用的是它），
    /// 于是存量 `maskStyleRaw == "dim"` 的行这里会画压暗、与导出一致，哪怕卡片上的胶囊
    /// 因为 `SubtitleTreatment` 只有三档而把它显示成「模糊虚化」。
    ///
    /// 只挂在 `thumbnailView` 上是有意的：播放中播的是活动画面，SwiftUI 取不到 `AVPlayerLayer`
    /// 的帧，糊不了 ⇒ 播放态退回只有描边手柄。**静止态才有效果预览。**
    @ViewBuilder private var maskTreatmentPreview: some View {
        let mode = SubtitleMaskMode.from(hasHardSubtitle: segment.hasHardSubtitle,
                                         maskStyleRaw: segment.maskStyleRaw)
        if mode != .none,
           segment.effectivePicture.thumbnailPath != nil,
           let image = thumbnail {
            GeometryReader { geo in
                let px = segment.maskRect.pixelRect(width: geo.size.width, height: geo.size.height)
                switch mode.renderSpec {
                case .passthrough:
                    EmptyView()
                case .blur:
                    // 与 ffmpeg 的 crop=w:h:x:y → boxblur → overlay=x:y **同序**：先开窗裁到带、
                    // 只糊这一小块，再搬回原位。半径按画布宽折算（表里存的是导出像素）。
                    //
                    // 裁的时候四周多留 `bleed`，糊完再 `.clipped()` 收回带本身：Gaussian 会向窗口
                    // 外取像素，不留边则带的上下沿会吃到 SwiftUI 的边缘复制，把边界画糊成一条毛边。
                    //
                    // ⚠️ 旧写法是「整块 9:16 画布糊完再裁」—— 代价 ∝ 画布面积，卡片一多滚动就掉帧；
                    // 现在代价 ∝ 带面积，且和导出一样只吃带内像素。
                    let r = mode.previewBlurRadius(displayWidth: geo.size.width,
                                                   displayCropHeight: px.height)
                    let bleed = r * 2
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .offset(x: -(px.x - bleed), y: -(px.y - bleed))
                        .frame(width: px.width + bleed * 2,
                               height: px.height + bleed * 2,
                               alignment: .topLeading)
                        .clipped()
                        .blur(radius: r)
                        .frame(width: px.width, height: px.height)
                        .clipped()
                        .offset(x: px.x, y: px.y)
                case .fill(let hex, let alpha):
                    Rectangle()
                        .fill(maskFillColor(hex: hex, alpha: alpha))
                        .frame(width: px.width, height: px.height)
                        .offset(x: px.x, y: px.y)
                }
            }
        }
    }

    /// 表里的 hex 是 ffmpeg `drawbox` 的取值口径，这里翻成 SwiftUI 的 Color。
    /// 解析失败退回黑底同 alpha —— 但那是**看得见**的错，不会静默画成另一种颜色。
    private func maskFillColor(hex: String, alpha: Double) -> Color {
        guard let packed = UInt32(hex, radix: 16), hex.count == 6 else {
            return Color.black.opacity(alpha)
        }
        return Color(red: Double((packed >> 16) & 0xFF) / 255.0,
                     green: Double((packed >> 8) & 0xFF) / 255.0,
                     blue: Double(packed & 0xFF) / 255.0,
                     opacity: alpha)
    }

    private func play(from requestedStart: Double, to requestedEnd: Double) {
        stopPlayback()

        // 当前生效画面：替换版是整段独立片(0..duration)，忽略传入的源时间轴区间；原版用传入区间。
        let ep = segment.effectivePicture
        let startTime = ep.isReplaced ? ep.startTime : requestedStart
        let endTime = ep.isReplaced ? ep.endTime : requestedEnd
        let videoPath = ep.videoPath
        guard !videoPath.isEmpty, FileManager.default.fileExists(atPath: videoPath) else { return }

        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))

        // 半帧偏移：零容差 seek 会落到「pts ≤ 目标时间」的那一帧。若分镜起点 startTime
        // 比目标帧真实 pts 早哪怕几微秒（编码后帧 pts 常为非整值），就会掉到前一帧，
        // 开头多出上个镜头的尾帧。把目标时间挪到帧正中央 (startTime + 0.5/fps) 即可稳定命中目标帧。
        let fps = ep.fps
        let halfFrame = fps > 0 ? 0.5 / fps : 0.01

        // 关键：让播放器在「本段最后一帧」处物理停住，绝不越过 endTime 冲进下一个镜头。
        // 这样就不需要「越界后 pause+seek 回退」——那个回退正是肉眼看到的「往后闪一下又回来」。
        // endTime 是下一段起点(exclusive)，本段最后一帧落在 endTime 前半帧。
        item.forwardPlaybackEndTime = CMTime(seconds: max(0, endTime - halfFrame), preferredTimescale: 600)

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.actionAtItemEnd = .pause   // 到结尾停住，不回到开头、不循环
        self.player = avPlayer
        isPlaying = true
        isFrozen = false

        // 方案预览：有选中变体音频时静音视频原声（含原人声），改放「克隆人声 + 分离BGM」
        if let dubPath = dubAudioPath, FileManager.default.fileExists(atPath: dubPath) {
            avPlayer.isMuted = true
            do {
                let ap = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: dubPath))
                ap.prepareToPlay()
                dubPlayer = ap
            } catch {
                dubPlayer = nil
            }
            // 背景音乐：用 demucs 分离出的 bgm.wav（已去人声、保持原响度），按原时间轴定位到本段起点，
            // 与画面同步播放，使变体配音不再「干声无背景」。无分离文件则跳过（仅放克隆人声）。
            if let hash = segment.video?.contentHash {
                let bgmURL = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav")
                if FileManager.default.fileExists(atPath: bgmURL.path) {
                    do {
                        let bp = try AVAudioPlayer(contentsOf: bgmURL)
                        bp.currentTime = max(0, startTime)   // BGM 与画面同走原时间轴
                        bp.prepareToPlay()
                        bgmPlayer = bp
                    } catch {
                        bgmPlayer = nil
                    }
                }
            }
        }

        let startCMTime = CMTime(seconds: startTime + halfFrame, preferredTimescale: 600)
        avPlayer.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // 进度更新（periodic，仅刷新进度条，不做结束判断）
        // 频率从 20Hz 降到 4Hz：currentTime 是 @State，每次变更都会重评估含 GeometryReader 的播放器 UI；
        // 一条几像素宽的进度条 4Hz 肉眼已经连续，20Hz 纯属浪费。
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            currentTime = CMTimeGetSeconds(time)
        }

        // 到达 forwardPlaybackEndTime（本段结尾）或视频自然播完，都会发这个通知 → 统一定格。
        // 不再用 boundary 观察者：boundary 是「越过后」才触发，必然先冲过头。
        endNotifObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in freezeAtLastFrame(endTime: endTime) }
        }

        avPlayer.play()
        dubPlayer?.play()
        bgmPlayer?.play()
    }

    /// 播放到分镜结尾：暂停并定格在分镜最后一帧（endTime 前半帧），不回缩略图。
    /// 便于肉眼确认最后一帧是否已串入下一个镜头（验证 endTime 边界是否切晚了）。
    private func freezeAtLastFrame(endTime: Double) {
        guard !isFrozen else { return }   // 防重入：forwardPlaybackEndTime 到点与自然播完通知可能都触发
        // 移除所有观察者，防止重复/继续触发
        if let observer = timeObserver, let p = player { p.removeTimeObserver(observer) }
        timeObserver = nil
        if let no = endNotifObserver { NotificationCenter.default.removeObserver(no) }
        endNotifObserver = nil
        dubPlayer?.stop()
        dubPlayer = nil
        bgmPlayer?.stop()
        bgmPlayer = nil
        guard let p = player else { return }
        p.pause()
        // endTime 是下一段起点(exclusive)，本段最后一帧落在 endTime 前半帧
        let fps = segment.video?.fps ?? 0
        let halfFrame = fps > 0 ? 0.5 / fps : 0.01
        let lastFrame = CMTime(seconds: max(0, endTime - halfFrame), preferredTimescale: 600)
        p.seek(to: lastFrame, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = endTime
        isPlaying = false
        isFrozen = true
        // 关键：不调 viewModel.stopCurrentPlayback()。那会把 playingSegmentID 置 nil，
        // 反过来触发本视图 onChange(playingSegmentID) → stopPlayback() 把定格画面清掉回封面。
        // 保留 playingSegmentID = 本段，定格留存；hover 到别的分镜时才会被清理。
    }

    private func stopPlayback() {
        if let observer = timeObserver, let p = player {
            p.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let no = endNotifObserver { NotificationCenter.default.removeObserver(no) }
        endNotifObserver = nil
        dubPlayer?.stop()
        dubPlayer = nil
        bgmPlayer?.stop()
        bgmPlayer = nil
        player?.pause()
        player = nil
        isPlaying = false
        isFrozen = false
        currentTime = 0
    }
}

// MARK: - 分镜行（列表模式）

/// 同 SegmentCard：Equatable + props 隔离选中状态
struct SegmentRow: View, Equatable {
    let segment: Segment
    let isChecked: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let sequenceNumber: Int
    @Bindable var viewModel: SegmentLibraryViewModel
    @Environment(\.modelContext) private var modelContext
    /// 即时 hover（底色）/ 延迟激活 hover（重子树），语义同 SegmentCard
    @State private var isHovering = false
    @State private var isHoverActive = false

    // ⚠️ 只比值类型 props —— 理由同 SegmentCard.== 上面那段：`segment` 是 class，
    // `lhs.segment.<字段> == rhs.segment.<字段>` 恒真、不承重，写在这里只会让人以为行内容已被守住。
    // 行内标签/质量分的刷新走 Observation，纪律见 Segment.swift `DecodedCache` 约束 #4。
    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isSelectionMode == rhs.isSelectionMode
            && lhs.isSelected == rhs.isSelected
            && lhs.sequenceNumber == rhs.sequenceNumber
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.normal) {
            // 多选 checkbox（只在多选模式下显示）
            if isSelectionMode {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(DesignTokens.Typography.title)
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                    .frame(width: 20)
            }

            SegmentInlinePlayer(segment: segment, viewModel: viewModel)
                // ⚠️ 高度必须写死成 9:16（与卡片同一规则）。只给宽度的话播放器会按缩略图自身比例长，
                // 横屏素材上行内会矮一截 ⇒ `maskRect` 的归一化空间与导出（pad 后的 9:16）分叉，
                // 于是"行里拖到刚好盖住、导出却没盖住"。
                .frame(width: 160, height: 160.0 * 16.0 / 9.0)
                .subtitleMaskHandle(on: segment) { try? modelContext.save() }
                .overlay(alignment: .topLeading) {
                    if sequenceNumber > 0 {
                        Text("#\(sequenceNumber)")
                            .font(DesignTokens.Typography.microMetric)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                // 标签行 —— 必须换行、不许压扁。
                // 这一行原先是裸 HStack：列表列实测 339pt（侧栏右沿 220pt、列表分界 559pt 两处纯色边界量得），
                // 减去 `.padding(10)`×2 + 播放器 `.frame(width: 160)` + `Spacing.normal` 12 ⇒ 文字列只剩 147pt，
                // 而 3 颗语义标签 + 位置 + 质量分按理想宽加齐 ≈250pt。HStack 装不下时压的是**柔性 Text**
                // （不是 Spacer），中文被压到一字一行 ⇒ 看起来像"标签被遮挡"。
                // 同一个形状在 `ImportView.swift` 的标签区（注释里记着"原本是 HStack…竖排单字"）和网格卡
                // 的 `FlowLayout` 各修过一次，这是第三处。修法照抄已验证的那份配方。
                FlowLayout(spacing: DesignTokens.Spacing.tight) {
                    ForEach(segment.semanticTypes.prefix(3), id: \.self) { type in
                        SemanticTypeTag(type: type)
                    }
                    PositionTypeTag(type: segment.positionType)
                    QualityBadge(score: segment.qualityScore)
                    SourceBadge(source: segment.source)
                }

                SegmentDubCompactControls(segment: segment)

                Text(segment.text)
                    .font(DesignTokens.Typography.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)

                // 边界微调：激活/选中才挂载；固定高度槽位保证行高在两态下不变
                // （旧实现这里「无 else 直接不挂」，hover 会增高整行，列表模式滚动估算同样失真）。
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if isHoverActive || isSelected {
                        BoundaryAdjustRow(segment: segment, viewModel: viewModel)
                    }
                }
                .frame(height: SegmentLibraryMetrics.boundaryRowHeight)
            }
            // ⚠️ 这一行是"整行铺满列表列"的**唯一**承担者，别当死码删掉。
            // 旧版靠标签行里那颗 `Spacer()` 顺带把行撑满（它同时兼任"把质量分推到最右"），
            // 我把标签行换成 FlowLayout 时删了那颗 Spacer ⇒ 行退化成按内容收宽，
            // 只有选中时（出现宽的边界微调行）才铺满 —— 真机读数："选中才会铺满"。
            // 现在把"铺满"写成显式声明，不再让 Spacer 兼职。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChecked
                      ? Color.accentColor.opacity(0.10)
                      : isSelected
                        ? Color.accentColor.opacity(0.06)
                        : isHovering
                          ? Color(.controlBackgroundColor).opacity(0.8)
                          : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isChecked ? Color.accentColor : isSelected ? Color.accentColor.opacity(0.5) : DesignTokens.Palette.border,
                        lineWidth: isChecked ? 2 : 1)
        )
        // 两层 hover：底色即时、BoundaryAdjustRow 等重子树延迟激活（滚动中不挂载）
        .hoverState(isHovering: $isHovering, isActive: $isHoverActive)
        // ⇧+点击 = 范围多选（Finder 同款）；普通点击 = 单个切换
        .onTapGesture {
            if isSelectionMode {
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.extendSelection(to: segment)
                } else {
                    viewModel.toggleSelection(segment)
                }
            } else {
                viewModel.selectedSegment = segment
            }
        }
    }
}

// MARK: - 列表行的紧凑配音入口

/// 列表行里的两颗胶囊：字幕处理（Menu 三档）+ 字幕字号（弹层）。
///
/// ⚠️ 为什么不直接把网格卡那块 `SegmentDubControls` 搬进来：行内文字列实测只有 147pt
/// （列表列 339pt − `.padding(10)`×2 − 播放器 160pt − `Spacing.normal` 12），
/// 而三颗胶囊按理想宽需要 ≈184pt ⇒ 搬进来就会在行内复现"中文被压成竖排"那同一类塌陷。
/// 这里改成单颗胶囊 + Menu：宽度可控，且与"行=快扫、卡=精修"的分工一致。
///
/// 写盘走的是与卡片**同一套**模型桥接（`Segment.subtitleTreatment` / `setSubtitleFontRatio`）
/// 与同一对批量函数（`SegmentCard.apply*ToAllSegments`），所以两处改的是同一份真相、
/// 撤销账也只有一份。
private struct SegmentDubCompactControls: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext
    @State private var showFontPopover = false

    private var treatment: SubtitleTreatment { segment.subtitleTreatment }
    private var isLocked: Bool { segment.isVoiceLocked }

    var body: some View {
        // 与标签行同一条纪律：用 FlowLayout 换行，不用裸 HStack。
        // 两颗胶囊按理想宽 ≈153pt > 文字列 147pt，裸 HStack 会压字或溢出到右侧面板上。
        FlowLayout(spacing: DesignTokens.Spacing.tight) {
            Menu {
                ForEach(SubtitleTreatment.allCases) { t in
                    Button {
                        segment.subtitleTreatment = t
                        try? modelContext.save()
                    } label: {
                        if t == treatment {
                            Label(t.displayName, systemImage: "checkmark")
                        } else {
                            Text(t.displayName)
                        }
                    }
                }
                if treatment.needsMask {
                    Divider()
                    Button("遮挡区应用到所有分镜") {
                        SegmentCard.applyMaskToAllSegments(of: segment, in: modelContext)
                    }
                }
            } label: {
                pill("字幕处理：\(treatment.displayName)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isLocked)
            .help(isLocked
                  ? "这一档已「保留原声」，不参与改写/配音，字幕处理对它无意义；要改请先在网格卡取消保留原声。"
                  : "在哪一步生效：所有走配音渲染的导出（方案配音导出、多选→批量导出）。普通混剪导出、单分镜批量导出不处理字幕区。")

            Button { showFontPopover = true } label: {
                pill(String(format: "字号 %.1f%%", SubtitleFontSize.clamp(segment.subtitleFontRatio) * 100))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isLocked)
            .popover(isPresented: $showFontPopover, arrowEdge: .bottom) {
                SubtitleFontSizePopover(
                    fontRatio: Binding(
                        get: { segment.subtitleFontRatio },
                        set: { segment.setSubtitleFontRatio($0); modelContext.safeSave() }
                    ),
                    isPresented: $showFontPopover,
                    onApplyToAll: {
                        SegmentCard.applyFontSizeToAllSegments(of: segment, in: modelContext)
                    })
            }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.microRegular)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - 质量分徽章

struct QualityBadge: View {
    let score: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(DesignTokens.Typography.microRegular)
            Text(String(format: "%.1f", score))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(badgeColor)
        // 与 SemanticTypeTag 同一条纪律：窄容器里宁可截断，不许压成竖排（见那里的 ⚠️ 注释）
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.1))
        .clipShape(Capsule())
    }

    private var badgeColor: Color {
        if score >= 9.0 { return .green }
        if score >= 8.0 { return .blue }
        if score >= 7.0 { return .orange }
        return .red
    }
}

// MARK: - 语义类型标签

struct SemanticTypeTag: View {
    let type: SemanticType

    var body: some View {
        Text(type.rawValue)
            .font(DesignTokens.Typography.micro)
            // ⚠️ 标签自己声明"绝不换行"：宿主给窄了就截断，而不是压成一字一行的竖排。
            // 光靠宿主用 FlowLayout 守不住 —— 这三个标签组件被网格卡/列表行/抽屉/方案详情共用，
            // 少一处声明就复发一次（列表行就是第三处）。
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Self.color(for: type).opacity(0.12))
            .foregroundStyle(Self.color(for: type))
            .clipShape(Capsule())
    }

    static func color(for type: SemanticType) -> Color {
        switch type {
        case .hook: return .red
        case .painPoint: return .orange
        case .solution: return .blue
        case .results: return .green
        case .socialProof: return .purple
        case .priceAnchor: return .yellow
        case .promotion: return .pink
        case .callToAction: return .mint
        case .productPositioning: return .teal
        case .usageEducation: return .indigo
        case .transition: return .gray
        }
    }
}

// MARK: - 位置类型标签

struct PositionTypeTag: View {
    let type: PositionType

    var body: some View {
        Text(type.rawValue)
            .font(DesignTokens.Typography.micro)
            .foregroundStyle(.secondary)
            // 同 SemanticTypeTag：窄容器里宁可截断，不许压成竖排
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
            .clipShape(Capsule())
    }
}

// MARK: - 筛选芯片

struct FilterChip: View {
    let label: String
    let color: Color
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    private var isEmpty: Bool { count == 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? color : color.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(color.opacity(isSelected ? 0.20 : 0.12))
                    )
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(isSelected ? 0.15 : 0.06))
            .foregroundStyle(isSelected ? color : color.opacity(0.85))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(isSelected ? 0.4 : 0.15), lineWidth: 1)
            )
            .opacity(isEmpty ? 0.35 : 1.0)
            .saturation(isEmpty ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 边界微调行

struct BoundaryAdjustRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    private enum TimeField: Hashable {
        case start, end
    }

    @State private var startText: String = ""
    @State private var endText: String = ""
    @FocusState private var focusedField: TimeField?

    private var fps: Double { segment.video?.fps ?? 30 }
    private func timecode(_ frame: Int) -> String { FrameTime.timecode(frame: frame, fps: fps) }

    var body: some View {
        HStack(spacing: 6) {
            // IN 时间组
            HStack(spacing: 1) {
                adjustButton(systemName: "minus", accessibilityLabel: "入点提前") {
                    viewModel.adjustStartFrame(for: segment, by: -1)
                }
                TextField("", text: $startText)
                    .font(DesignTokens.Typography.microMonoStrong)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .start ? .primary : .secondary)
                    .focused($focusedField, equals: .start)
                    .onSubmit { commitStart() }
                    .frame(width: 44, height: 16)
                    .background(focusedField == .start ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                adjustButton(systemName: "plus", accessibilityLabel: "入点延后") {
                    viewModel.adjustStartFrame(for: segment, by: 1)
                }
            }

            // OUT 时间组
            HStack(spacing: 1) {
                adjustButton(systemName: "minus", accessibilityLabel: "出点提前") {
                    viewModel.adjustEndFrame(for: segment, by: -1)
                }
                TextField("", text: $endText)
                    .font(DesignTokens.Typography.microMonoStrong)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(focusedField == .end ? .primary : .secondary)
                    .focused($focusedField, equals: .end)
                    .onSubmit { commitEnd() }
                    .frame(width: 44, height: 16)
                    .background(focusedField == .end ? Color.accentColor.opacity(0.08) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                adjustButton(systemName: "plus", accessibilityLabel: "出点延后") {
                    viewModel.adjustEndFrame(for: segment, by: 1)
                }
            }

            Spacer(minLength: 0)

            // 类型编辑 + 删除
            Menu {
                ForEach(SemanticType.allCases) { type in
                    Button {
                        viewModel.toggleSemanticType(for: segment, type: type)
                    } label: {
                        HStack {
                            Text(type.rawValue)
                            if segment.semanticTypes.contains(type) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                ForEach(PositionType.allCases) { type in
                    Button {
                        viewModel.updatePositionType(for: segment, to: type)
                    } label: {
                        HStack {
                            Text(type.rawValue)
                            if segment.positionType == type {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 18)
                    .background(.quaternary.opacity(DesignTokens.Palette.Alpha.strong))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("更多操作")
            .fixedSize()
        }
        .onChange(of: focusedField) { oldField, newField in
            // 进入编辑显示帧号（便于精确输入）；离开时提交并恢复时间码显示
            if newField == .start { startText = "\(segment.startFrame)" }
            if newField == .end { endText = "\(segment.endFrame)" }
            if oldField == .start { commitStart() }
            if oldField == .end { commitEnd() }
        }
        .onAppear {
            startText = timecode(segment.startFrame)
            endText = timecode(segment.endFrame)
        }
        .onChange(of: segment.startFrame) { _, newVal in
            if focusedField != .start { startText = timecode(newVal) }
        }
        .onChange(of: segment.endFrame) { _, newVal in
            if focusedField != .end { endText = timecode(newVal) }
        }
    }

    /// 提交开始帧（输入框输入的是帧号整数）
    private func commitStart() {
        guard let f = Int(startText.trimmingCharacters(in: .whitespaces)), f >= 0 else {
            startText = timecode(segment.startFrame)
            return
        }
        if f != segment.startFrame {
            viewModel.setStartFrame(for: segment, to: f)
        }
        startText = timecode(segment.startFrame)
    }

    /// 提交结束帧（输入框输入的是帧号整数）
    private func commitEnd() {
        guard let f = Int(endText.trimmingCharacters(in: .whitespaces)), f > 0 else {
            endText = timecode(segment.endFrame)
            return
        }
        if f != segment.endFrame {
            viewModel.setEndFrame(for: segment, to: f)
        }
        endText = timecode(segment.endFrame)
    }

    private func adjustButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                // ⚠️ 尺寸必须保持 14×14：这一行只在 hover 时出现，而卡片宽度由最宽的子视图决定。
                // 一旦把按钮放大（曾试过 18×18），这行会变宽 → 悬停瞬间把整张卡片撑宽 →
                // 网格重排 → 卡片左右跳动、画面移出播放框。字号 10pt 在 14×14 里留白足够，不必放大容器。
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: DesignTokens.Corner.style))
                // 让整个 14×14 方块（含透明区域）都可点，而不是只有图标笔画可点。
                // 不用放大 frame —— 放大会撑宽这一行进而撑宽整张卡片，悬停时造成网格跳动。
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.secondary.opacity(0.1), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
