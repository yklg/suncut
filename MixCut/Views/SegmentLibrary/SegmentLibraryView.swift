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
    /// 待确认停止的视频作业（标题行/检查器/浮层三个停止入口共用一个确认弹窗）
    @State private var pendingStopVideoID: UUID?
    /// 搜索防抖任务句柄：新按键到来时取消上一个，避免每敲一个字就全量重算。
    @State private var searchDebounceTask: Task<Void, Never>?
    /// 字幕烧录字号（全局设置，与卡片预览、导出共用同一 UserDefaults 键）
    /// ⚠️ 这是本视图**私有**的 ImportViewModel，与 ContentView 那个不是同一实例；
    ///    .task 里那句 setModelContext 是给它注上下文的**唯一一处**，删不得（自建分镜上传/拆分都走它）。
    @State private var importVM = ImportViewModel()
    /// 滚动内容实测宽（背景 GeometryReader 间接测量），驱动网格列数与固定卡宽
    @State private var libraryWidth: CGFloat = 0
    /// Inspector 未展开时的内容区宽（门禁判定基准：模拟 inspector 展开后列数是否改变）
    @State private var unconstrainedWidth: CGFloat = 0
    @Environment(\.modelContext) private var modelContext

    /// 三个停止入口统一走这里：只弹确认，确认后才取消（避免手滑中断付费任务）。
    private func requestStopJob(_ videoID: UUID) {
        pendingStopVideoID = videoID
    }

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
            // 换项目：旧项目的视频级配音作业不再属于当前界面，静默全部停止（不提示、不报错）。
            // 必须放在闭包最前面：句柄在注册表中独立于视图存活，不随本页身份变化自动取消。
            dubVM.cancelAllJobs(reason: .projectSwitch)
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
                // R2 · grid 隔离：选中变化引起的宽度/列数重排不做逐帧动画，
                // grid 只在最终态布局一次（消除多相位插值掉帧）。
                .animation(nil, value: viewModel.selectedSegment?.id)

                if let seg = viewModel.selectedSegment {
                    Divider()
                    SegmentVariantInspector(
                        segment: seg,
                        dubVM: dubVM,
                        isPinned: seg.id == viewModel.pinnedSegmentID,
                        onClose: { viewModel.clearPinned() },
                        onStopRequest: { requestStopJob($0) }
                    ) {
                        SegmentPropertiesContent(segment: seg, viewModel: viewModel)
                    }
                    // ⚠️ 实体身份契约：inspector 整棵子树（含台词草稿/边界时间码/改写版行内编辑等
                    // 所有分镜作用域 @State）的视图身份必须与选中分镜绑定。缺了它，切换分镜时
                    // SwiftUI 复用同一视图实例、@State 原样保留，台词原文会永远停在第一个分镜。
                    // 有 InspectorSegmentIdentityGuardTests 守卫，删除前先读那条测试。
                    .id(seg.id)
                    // R2 · 仅对 inspector 做 120ms opacity 动画（内容快速淡出，无宽度/子树插值）
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: viewModel.selectedSegment?.id)
                }
            }
        }
        // 常驻作业浮层：切换素材、滚动、分组标题被 Lazy 回收都不影响进度可见性与停止入口。
        .overlay(alignment: .bottom) {
            DubbingJobsOverlay(vm: dubVM) { requestStopJob($0) }
                // 检查器展开时浮层避开右侧 340pt 栏；收起时在主区底部居中。
                .padding(.trailing, viewModel.selectedSegment == nil ? 0 : 340)
        }
        .navigationTitle("分镜素材库")
        // 停止改写确认（三个入口共用 pendingStopVideoID）
        .confirmationDialog("停止改写？",
                            isPresented: Binding(
                                get: { pendingStopVideoID != nil },
                                set: { if !$0 { pendingStopVideoID = nil } }),
                            presenting: pendingStopVideoID) { videoID in
            Button("停止", role: .destructive) {
                dubVM.cancelJobs(for: videoID, reason: .userStop)
                pendingStopVideoID = nil
            }
            Button("继续等待", role: .cancel) { pendingStopVideoID = nil }
        } message: { _ in
            Text("已完成的改写台词与配音会保留；正在进行的这一步将立即中断（已发起的 API 调用按次计费，无法退回）。")
        }
        // ⚠️ 配音错误的 alert 必须挂在**页面顶层**。
        // 原先它挂在 DubSettingsBar 里，而那个组件只在「普通视频」分组标题行渲染，
        // 外层还是 LazyVStack —— 于是两种情况下报错完全看不到：
        //   ① 项目只有「自建分镜」（该分支不渲染 DubSettingsBar）
        //   ② 分组标题被滚出可视区，Lazy 容器把宿主回收掉
        // 结果就是配音失败后界面只是转一圈然后恢复原样，用户完全不知道发生了什么。
        .alert("配音", isPresented: Binding(
            get: { dubVM.errorState != nil },
            set: { if !$0 { dubVM.errorState = nil } }
        )) {
            // 缺凭证时提供跳设置入口；按钮由 errorState.kind 派生，无影子状态。
            if dubVM.errorState?.kind == .missingCredential {
                Button("去设置配置") {
                    NotificationCenter.default.post(name: .mixCutShowSettings, object: nil)
                }
            }
            Button("知道了", role: .cancel) { dubVM.errorState = nil }
        } message: {
            Text(dubVM.errorState?.message ?? "")
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
        InspectorPresentationGating.columnCount(
            available: Double(libraryWidth),
            minCardWidth: Double(SegmentLibraryMetrics.gridMinCardWidth),
            spacing: Double(DesignTokens.Spacing.normal))
    }

    private var cardWidth: CGFloat {
        guard libraryWidth > 0 else { return SegmentLibraryMetrics.gridMinCardWidth }
        let cols = CGFloat(gridColumnCount)
        let spacing = DesignTokens.Spacing.normal
        return floor((libraryWidth - (cols - 1) * spacing) / cols)
    }

    private var libraryRows: [LibraryRow] {
        let refs = viewModel.groupedSegments.map {
            LibraryGroupRef(id: $0.id, segmentIDs: $0.visibleSegments.map(\.id))
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
                // Inspector 关闭状态下记录满宽；关闭后区域回弹会再次触发回调
                if viewModel.selectedSegment == nil {
                    if abs(width - unconstrainedWidth) > 0.5 { unconstrainedWidth = width }
                    let allows = InspectorPresentationGating.hoverAutoSelectionAllows(
                        available: Double(width),
                        minCardWidth: Double(SegmentLibraryMetrics.gridMinCardWidth),
                        spacing: Double(DesignTokens.Spacing.normal))
                    viewModel.setHoverSelectionAllowed(allows)
                }
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

    /// 分组标题行的渲染门：载体视频已被 `context.delete` 摘除时不渲染。
    ///
    /// 剪枝拦不住这一层 —— 变更通知先到、投影剪枝后到，「正在被移除的视图自己」必然还会重算一次
    /// body（本仓 `ImportView` 的卡片早已踩过同一个时序）。判据真源见 `PersistentModel.isDroppedFromContext`。
    @ViewBuilder
    private func sectionHeader(_ group: VideoSegmentGroup) -> some View {
        if group.video?.isDroppedFromContext == true {
            Color.clear.frame(height: 0)
        } else {
            sectionHeaderContent(group)
        }
    }

    /// 分组标题行（自建分镜聚合组 vs 普通视频分组）
    private func sectionHeaderContent(_ group: VideoSegmentGroup) -> some View {
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
                    Text("\(group.visibleSegments.count) 个分镜 · 我上传的")
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
                    Text("\(group.visibleSegments.count) 个分镜 · \(String(format: "%.0f", video.duration))s")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 视频专属「配音」栏（自建分镜组由多个载体视频组成，不显示视频级批量栏，逐卡各自配音）
                // 放进分组标题行：这些控件作用于「这个视频」，单独占一行浮在右侧看不出归属。
                // 作用域以本视频分镜为定义域解析，跨视频勾选经交集剔除；targets 稳定排序。
                //
                // ⚠️ 定义域**只吃 VM 的未筛选全域投影，绝不吃 `video.segments`**：
                // 后者每次布局都要 fault 一次 SwiftData 关系数组，而库里已真删的分镜可能还挂在这个
                // 内存对象上 —— 2026-10-03 那次 EXC_BREAKPOINT（SIGTRAP）就崩在这一行，
                // 且它落在 LazyVStack 的 measure 热路径上，滚动/重绘随时触发。
                // 口径 = 未筛选全域（与 `video_no` 编号同源），不是 `group.visibleSegments`：
                // 用筛选结果当定义域会让批量范围悄悄缩窄，而文案仍写着「本视频 N 个分镜」。
                let domain = viewModel.unfilteredSegmentsByGroupID[group.id] ?? group.visibleSegments
                let scope = DubRewriteScopeResolver.resolve(
                    domainIDs: Set(domain.map(\.id)),
                    isSelectionMode: viewModel.isSelectionMode,
                    selectedSegmentIDs: viewModel.selectedSegmentIDs,
                    singleSegmentID: viewModel.selectedSegment?.id)
                let mapped: [Segment] = {
                    guard let ids = scope.targetIDs else { return domain }
                    return ids.compactMap { viewModel.segmentByID[$0] }
                }()
                let targets = DubTargetOrdering.ordered(mapped) {
                    ($0.startTime, $0.startFrame)
                }
                DubSettingsBar(video: video,
                               videoSegments: domain,
                               dubVM: dubVM,
                               scope: scope,
                               targets: targets,
                               presentation: DubScopePresentationMapper.presentation(for: scope.kind),
                               onStopRequest: { requestStopJob($0) })
            }
        }
        .padding(.horizontal, 4)
    }

    /// 一行卡片（网格模式 1...N 个、固定等宽；列表模式恒 1 个、铺满）。
    ///
    /// 性能关键（沿袭旧实现）：父视图一次性算好 isChecked / sequenceNumber 等 props 下发，
    /// 卡片 Equatable + .equatable() 后，选中变化只重绘对应卡片。模型按 id 从 VM 字典回查，
    /// 禁止强解（重认台词/删除撤销等异步回写可能让行投影与字典短暂跨相位）。
    ///
    /// `liveSegment(_:)` 是卡片侧的渲染门：分镜已被 `context.delete` 摘除就不再进 body，
    /// 否则 `SegmentCard` 里任何一次持久属性读取都会命中 SwiftData 的已删对象断言。
    @ViewBuilder
    private func cardsRow(groupID: UUID, segmentIDs: [UUID]) -> some View {
        let selectionMode = viewModel.isSelectionMode
        let selectedIDs = viewModel.selectedSegmentIDs
        let selectedSegID = viewModel.selectedSegment?.id
        let numMap = viewModel.numberByVideo[groupID] ?? [:]

        if viewModel.isGridView {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.normal) {
                ForEach(segmentIDs, id: \.self) { segmentID in
                    if let segment = liveSegment(segmentID) {
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
        } else if let segment = segmentIDs.first.flatMap(liveSegment) {
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

    /// 从 VM 投影回查分镜，并挡掉「图已经不认它」的那一批。
    /// 判据走 `ModelContextExtension` 的 `live` 门（与跨 to-one 边同一处真源），别再在这里各写一遍。
    private func liveSegment(_ id: UUID) -> Segment? {
        viewModel.segmentByID[id]?.live
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
    /// hover 停留多久才激活重子树（播放器完整态/AVPlayer、Inspector 临时选中）。
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
        // 两层 hover：底色即时反馈；延迟激活驱动播放与 Inspector 临时选中。
        // 惯性滚动中卡片从指针下穿过，停留不足激活延时，重子树全程不挂载。
        .hoverState(isHovering: $isHovering, isActive: $isHoverActive)
        .onChange(of: isHoverActive) { _, active in
            guard !isSelectionMode, viewModel.hoverSelectionAllowed else { return }
            viewModel.setHoveredSegmentID(active ? segment.id : nil)
        }
        // ⇧+点击 = 范围多选（Finder 同款）；普通点击 = 钉住选中（Inspector 持久展开）
        .onTapGesture {
            if isSelectionMode {
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.extendSelection(to: segment)
                } else {
                    viewModel.toggleSelection(segment)
                }
            } else {
                viewModel.pin(segment)
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
                // 台词编辑已迁入 Inspector「台词原文」分区；点击即钉住并展示
                viewModel.pin(segment)
            } label: {
                Label("编辑台词", systemImage: "square.and.pencil")
            }

            // 重新识别台词：与头部旧入口同一逻辑，入口统一进右键菜单
            Button {
                Task { await viewModel.reextractTranscript(segment, context: modelContext) }
            } label: {
                Label("重新识别台词", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.busyASRSegmentIDs.contains(segment.id))

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
                    // 就地替换画面：自绘切换（仅当存在替换画面时显示），原画面 ↔ 替换画面。
                    // 不用 Button：常驻单元不挂 AppKit 宿主（瘦化守卫同款规则）。
                    if segment.replacedPictureVideoPath != nil {
                        HStack(spacing: 3) {
                            // ⚠️ 交换语义图标（非 arrow.triangle.2.circlepath 的重试语义）
                            Image(systemName: "rectangle.2.swap")
                            Text(segment.pictureShowsReplaced ? "替换画面" : "原画面")
                        }
                        .font(DesignTokens.Typography.microEmphasis)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(segment.pictureShowsReplaced
                            ? Color.green.opacity(0.75) : Color.black.opacity(0.6)))
                        .contentShape(Capsule())
                        .onTapGesture {
                            segment.pictureShowsReplaced.toggle()
                            try? modelContext.save()
                        }
                        .padding(6)
                        .help("在原画面与 AI 替换画面之间切换")
                        .accessibilityElement()
                        .accessibilityLabel("切换原画面与替换画面")
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
        }
        .padding(8)
    }

    // MARK: - 右侧台词面板的头部行（纯展示，动作在右键菜单）
    //
    // 头部只承载标签，降级档位（各档包含什么、顺序）由 MixCutCore 的
    // `SegmentHeaderLayout.tiers` 单一声明，这里按 kind 映射渲染：
    // 宽度测量交给 ViewThatFits，顺序契约与视图解耦。
    //
    // 历史上「编辑/重认」按钮曾放在 ViewThatFits 候选内部，因测量缓存时序连续三轮被裁。
    // 现动作入口统一进卡片右键菜单（编辑已有、重认同入口），头部不含动作变量，
    // 裁切缺陷在结构上不可能复发。

    /// 按标签种类渲染对应内容（沿用各档原有字号/色阶）。
    @ViewBuilder
    private func headerLabelContent(_ kind: SegmentHeaderLabelKind) -> some View {
        switch kind {
        case .icon:
            Image(systemName: "text.quote")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary)
        case .title:
            Text("台词")
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .wordCount:
            Text("\(segment.text.count)字")
                .font(DesignTokens.Typography.microMono)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        case .provenance:
            // 台词来源。旧数据显示「旧数据·未记录来源」，用中性色：
            // 它是「没记过」，不是「坏了」。
            Text(TextProvenance.displayLabel(of: segment.textSource))
                .font(DesignTokens.Typography.microMono)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// 由 tiers 驱动的头部（ViewThatFits 逐档试放）。
    private var transcriptHeader: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(SegmentHeaderLayout.tiers.enumerated()), id: \.offset) { _, kinds in
                HStack(spacing: DesignTokens.Spacing.tight) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                        headerLabelContent(kind)
                    }
                }
                // 各档按理想宽上报：ViewThatFits 才能在放不下时正确降到下一档。
                // 末档 [.icon] 仅 12pt，任何真实面板都放得下（兜底）。
                .fixedSize()
            }
        }
        // 任何降级档下悬停都能看到完整「字数·来源」
        .help("台词 \(segment.text.count)字 · \(TextProvenance.displayLabel(of: segment.textSource))")
    }

    // MARK: - 右侧台词面板
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部纯展示：四档降级由 transcriptHeader（tiers 驱动）内部完成
            transcriptHeader
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if segment.text.isEmpty {
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

// MARK: - 分镜原地播放器（hover 播放 + 点击播放，全局唯一播放，原始比例）

struct SegmentInlinePlayer: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel
    /// 可选：选中配音变体的音频路径。非 nil 时播放静音视频原声、同步播此变体音轨（方案预览用）。
    var dubAudioPath: String? = nil

    /// 播放模式（单一状态，取代 isPlaying/isFrozen 两布尔；paused 语义不再额外打标）。
    /// 非法组合（如 paused+frozen）不可表达；视图呈现、点击行为全部从 mode 派生。
    enum SegmentPlaybackMode: Equatable {
        case idle       // 缩略图态
        case playing    // 播放中
        case paused     // 播放中被手动暂停（player 保留，再点继续）
        case frozen     // 自然播完定格最后一帧
    }

    @State private var player: AVPlayer?
    @State private var dubPlayer: AVAudioPlayer?
    @State private var bgmPlayer: AVAudioPlayer?   // 变体预览时叠加的分离背景音乐
    @State private var mode: SegmentPlaybackMode = .idle
    @State private var timeObserver: Any?
    @State private var endNotifObserver: NSObjectProtocol?  // 到达 forwardPlaybackEndTime / 视频自然播完 → 定格
    @State private var currentTime: Double = 0
    /// 播放起始的首帧覆盖：新 AVPlayerView 出首帧前会黑一帧，
    /// 用同画面缩略图盖住；固定 300ms 后揭盖（覆盖帧与首帧同画面，何时揭都零跳变）。
    @State private var coverFirstFrame = false
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
            if mode == .idle && !isHoverActive {
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
                    .overlay(alignment: .center) {
                        // 静态态整区可点播放（R1 实测检查点：先验证点击不触发父级选中）
                        playbackTapButton
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
                if mode != .idle { stopPlayback() }
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
        // play() 会把 mode 置 .playing，body 随即切到 playerUI。
        .onChange(of: viewModel.playingSegmentID) { _, newID in
            if newID != segment.id && mode != .idle {
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
            if mode != .idle, let player {
                PlayerRepresentable(player: player)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)   // F11/F12: 横屏视频在 9:16 容器内留黑边，不裁切
            } else {
                thumbnailView
            }

            // 首帧覆盖：盖住新 AVPlayerView 出画前的黑帧（同画面缩略图，300ms 后揭）
            if coverFirstFrame {
                thumbnailView
                    .allowsHitTesting(false)
            }

            // hover 激活但尚未播放（idle）：显示「播放」引导
            if isHoverActive && mode == .idle {
                Color.black.opacity(0.15)
                Image(systemName: "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }

            // 手动暂停 / 定格：中央显示播放图标（再点续播/重播）
            if mode == .paused || mode == .frozen {
                Color.black.opacity(0.18)
                Image(systemName: mode == .paused ? "play.fill" : "play.circle.fill")
                    .font(.system(size: mode == .paused ? 20 : 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }

            if mode == .playing {
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

            // 点击层：整区响应播放/暂停（最上层；R1：点击由本 Button 消费，不冒泡到卡片选中）
            playbackTapButton
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

    /// 整区点击播放/暂停的透明按钮（静态态与 playerUI 共用）。
    private var playbackTapButton: some View {
        Button {
            togglePlayback()
        } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .playing ? "暂停" : "播放")
    }

    /// 点击行为：按 mode 派生，无新布尔。
    private func togglePlayback() {
        switch mode {
        case .idle:
            // 首次播放：幂等激活（hover 已激活同 ID 时 Gate 会去重）
            viewModel.requestPlay(segment: segment)
        case .frozen:
            // 定格后重播：必须强制——active 仍是本 ID，ensureActive 会被 Gate 吞掉
            viewModel.requestPlay(segment: segment, intent: .restart)
        case .playing:
            // 手动暂停：av 与 dub/bgm 同步暂停但不销毁，再点续播
            player?.pause()
            dubPlayer?.pause()
            bgmPlayer?.pause()
            mode = .paused
        case .paused:
            player?.play()
            dubPlayer?.play()
            bgmPlayer?.play()
            mode = .playing
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

        // 首帧覆盖就位（盖住 AVPlayerView 出画前的黑帧）
        coverFirstFrame = true

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
        mode = .playing

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

        // 固定 300ms 揭盖：覆盖帧与首帧同画面，无需精确同步首帧事件。
        // 不持有 Task 句柄——停止路径统一以 coverFirstFrame 复位为准。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            coverFirstFrame = false
        }
    }

    /// 播放到分镜结尾：暂停并定格在分镜最后一帧（endTime 前半帧），不回缩略图。
    /// 便于肉眼确认最后一帧是否已串入下一个镜头（验证 endTime 边界是否切晚了）。
    private func freezeAtLastFrame(endTime: Double) {
        guard mode != .frozen else { return }   // 防重入：forwardPlaybackEndTime 到点与自然播完通知可能都触发
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
        mode = .frozen
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
        mode = .idle
        currentTime = 0
        // 首帧覆盖不残留（hover 离开/点新分镜/切项目/onDisappear 全经此路径）
        coverFirstFrame = false
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

                Text(segment.text)
                    .font(DesignTokens.Typography.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
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
        // 两层 hover：底色即时；延迟激活驱动「Inspector 临时选中」（编辑已迁入 Inspector）
        .hoverState(isHovering: $isHovering, isActive: $isHoverActive)
        .onChange(of: isHoverActive) { _, active in
            guard !isSelectionMode, viewModel.hoverSelectionAllowed else { return }
            viewModel.setHoveredSegmentID(active ? segment.id : nil)
        }
        // ⇧+点击 = 范围多选（Finder 同款）；普通点击 = 钉住选中
        .onTapGesture {
            if isSelectionMode {
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.extendSelection(to: segment)
                } else {
                    viewModel.toggleSelection(segment)
                }
            } else {
                viewModel.pin(segment)
            }
        }
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

