import SwiftUI
import UniformTypeIdentifiers

/// 用于让右侧台词面板高度匹配左侧
private struct LeftPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ImportView: View {
    let project: Project
    @Bindable var importVM: ImportViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var isDragTargeted = false
    /// 批量删除的二次确认（只在多选模式下由工具栏的「删除」唤起）
    @State private var showBatchDeleteConfirm = false
    @State private var showingFilePicker = false
    /// 导入任务句柄，用于「停止导入」取消
    @State private var importTask: Task<Void, Never>?
    /// 本批导入新视频的默认素材来源（与「上传自建分镜」入口分别记忆，互不污染）
    @AppStorage("importDefaultSourceRaw") private var batchSourceRaw: String = SegmentSource.curated.rawValue
    /// 「显示丢失素材」开关：打开后源文件已不存在的卡回到网格里，但不可播放 ——
    /// 显示占位 + 完整路径 + 「重新检查」，因为找回文件需要的是路径，而播放只会失败。
    /// 与上面那颗同族同位置：这是**界面偏好**，不落库。
    @AppStorage("importShowsMissingVideos") private var showsMissingVideos = false

    /// 本页视频播放设备的唯一协调器：所有成片卡片共享，同一时刻只允许一个播放。
    @State private var playbackCoordinator = PlaybackCoordinator()

    private var batchSource: SegmentSource { SegmentSource(persisted: batchSourceRaw) }

    var body: some View {
        // 本模块不挂骨架屏：正文实时读 `project.videos`（SwiftData 的 Observation 就是权威源），
        // 原先的 SkeletonView 唯一的副作用就是每次换模块白闪一帧。
        mainContent
            .task(id: project.id) {
                // 跨项目串选的门：importVM 挂在 ContentView 上**跨页长活**，选择集是全局 video id。
                // 不换掉的话，在 A 项目勾 3 条再切到 B 项目点「删除」会删到 A 的素材上。
                // 判据 UG-G12 钉住这一句（它在 .task body 内必须在，摘掉必红）。
                importVM.setVideoSelectionMode(false)
                let t0 = Date()
                let thumbPaths = project.videos.compactMap(\.thumbnailPath)
                ThumbnailCache.shared.prewarm(paths: thumbPaths, for: project.id)
                // 磁盘对账搭在**同一颗** .task 上：不新开任务、不做 LaunchStep（启动期算出的
                // 集合没有承接者，而加一颗 step 要同步的门单已排到十六条）。节流在 store 里，
                // 分镜库那边的同一颗 `.task(id:)` 再调一次也不会重扫。
                await MaterialAvailabilityStore.shared.refresh(for: project)
                MixLog.info("[Perf] Import: \(Int(Date().timeIntervalSince(t0) * 1000))ms / videos=\(project.videos.count)")
            }
            .confirmationDialog(
                "删除选中的 \(importVM.selectedVideoIDs.count) 个视频？",
                isPresented: $showBatchDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除 \(importVM.selectedVideoIDs.count) 个", role: .destructive) {
                    importVM.deleteSelectedVideos(in: project,
                                                  visibleOrder: numberedVideos.map(\.video))
                }
                Button("取消", role: .cancel) { }
            } message: {
                // 数字与两档引用数都来自 VM 的实数函数；这句里的「编号会整体前移」不是客套，
                // video_no 是 Agent 的寻址契约（ProjectVideoDedup.swift:53-59 自述）。
                Text(batchDeleteConfirmMessage)
            }
            .background(
                // 隐藏快捷键：ESC 退出多选；⌘A 全选；⌘D 反选；⌘0 清空。
                // 逐字对齐 `SegmentLibraryView.swift:221-246` 那套透明 Button 写法（仓里不留第三套）。
                // 关键在**只在多选态存在**：非多选时这四颗按键根本不在响应链里，
                // 所以页内文本框的 ⌘A「全选文本」不会被抢 —— 凭印象常挂快捷键会撞掉它。
                Group {
                    if importVM.isVideoSelectionMode {
                        Button("") {
                            withAnimation(DesignTokens.Motion.hover) {
                                importVM.setVideoSelectionMode(false)
                            }
                        }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)

                        Button("") { importVM.selectAllVisibleVideos(numberedVideos.map(\.video)) }
                            .keyboardShortcut("a", modifiers: .command)
                            .opacity(0)

                        Button("") { importVM.invertVisibleVideoSelection(numberedVideos.map(\.video)) }
                            .keyboardShortcut("d", modifiers: .command)
                            .opacity(0)

                        Button("") { importVM.clearVideoSelection() }
                            .keyboardShortcut("0", modifiers: .command)
                            .opacity(0)
                    }
                }
            )
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if importVM.isProcessing {
                processingBanner
            }

            ScrollView {
                VStack(spacing: DesignTokens.Spacing.spacious) {
                    importSourceBar
                    importDropZone

                    errorBanner

                    if project.videos.contains(where: { !$0.isUserUploaded }) {
                        videoListSection
                    }
                }
                .padding(DesignTokens.Padding.page)
            }
        }
        .navigationTitle("素材导入")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: ImportViewModel.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                var accessedURLs: [URL] = []
                for url in urls {
                    if url.startAccessingSecurityScopedResource() {
                        accessedURLs.append(url)
                    }
                }
                let videoURLs = accessedURLs.filter { isVideoFile($0) }
                guard !videoURLs.isEmpty else {
                    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
                    return
                }
                importTask = Task {
                    await importVM.importVideos(urls: videoURLs, to: project,
                                                defaultSource: batchSource)
                    for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
                }
            case .failure(let error):
                importVM.errorMessage = "选择文件失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 批级来源选择
    /// 拖入/选择文件立即按此来源导入；混批时可导入后在已导入卡片或素材库逐条改。
    private var importSourceBar: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            Text("素材来源")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)
            Picker("", selection: $batchSourceRaw) {
                Text("自拍（公司原创拍摄）").tag(SegmentSource.selfShot.rawValue)
                Text("搬运（他人视频）").tag(SegmentSource.curated.rawValue)
                Text("AI生产（AI 工具生成）").tag(SegmentSource.aiGenerated.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .labelsHidden()
            .disabled(importVM.isProcessing)
            Spacer()
            Text("本批新视频按此归类，单条可之后修改")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 处理进度
    private var processingBanner: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(importVM.phase.rawValue)
                    .font(DesignTokens.Typography.captionEmphasis)
                Text(importVM.progressDescription)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: importVM.progress)
                .frame(width: 120)
            // 以前想中止导入，唯一办法是把素材删掉 —— 用户得先毁掉自己的文件才能停下来。
            // 「停止导入」只中断后续分析，已导入的素材原样保留。
            Button("停止导入") {
                importTask?.cancel()
                importTask = nil
                importVM.markCancelledByUser()
            }
            .controlSize(.small)
            .help("停止后续分析，已导入的素材会保留")
        }
        .padding(DesignTokens.Spacing.normal)
        .background(Color.accentColor.opacity(DesignTokens.Palette.Alpha.subtle))
    }

    // MARK: - 拖拽导入区域
    private var importDropZone: some View {
        VStack(spacing: DesignTokens.Spacing.comfortable) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 48))
                .foregroundStyle(isDragTargeted ? Color.accentColor : Color.secondary)
                .scaleEffect(isDragTargeted ? 1.15 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isDragTargeted)
            Text(isDragTargeted ? "松开手即可导入" : "拖拽视频文件到此处")
                .font(DesignTokens.Typography.title)
                .foregroundStyle(isDragTargeted ? Color.accentColor : Color.primary)
            Text("支持 MP4, MOV, AVI 格式")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)
            Button("选择文件") {
                showingFilePicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isDragTargeted ? Color.accentColor.opacity(0.08) : .clear)
                )
        )
        .animation(DesignTokens.Motion.transition, value: isDragTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            var accessedURLs: [URL] = []
            var securedURLs: [URL] = []
            for url in urls {
                if url.startAccessingSecurityScopedResource() {
                    securedURLs.append(url)
                }
                accessedURLs.append(url)
            }
            let videoURLs = accessedURLs.filter { isVideoFile($0) }
            guard !videoURLs.isEmpty else {
                for url in securedURLs { url.stopAccessingSecurityScopedResource() }
                return false
            }
            importTask = Task {
                await importVM.importVideos(urls: videoURLs, to: project,
                                            defaultSource: batchSource)
                for url in securedURLs { url.stopAccessingSecurityScopedResource() }
            }
            return true
        } isTargeted: { targeted in
            isDragTargeted = targeted
        }
    }

    /// 素材可用性结果：全链路只有 `MaterialAvailabilityStore.shared` 一个持有者，视图**只读不回写**。
    private var availability: MaterialAvailabilityStore { MaterialAvailabilityStore.shared }

    /// 视频编号：与素材库卡片 #、Agent（MCP）的 video_no 同一套规则。
    /// 规则真源在 `Project.videoNoByVideoID` / `Project.associatedVideos`，此处只做展示过滤。
    private var numberedVideos: [(no: Int, video: Video)] {
        let numbers = project.videoNoByVideoID
        return project.associatedVideos
            .filter { !$0.isUserUploaded }
            .compactMap { video in
                guard let no = numbers[video.id] else { return nil }
                return (no: no, video: video)
            }
            .sorted { $0.no < $1.no }
            // 丢失项的过滤**只加在链尾**：编号在过滤之前就已按真源算完，藏掉几张卡不会让
            // 剩下的卡改号（video_no 是 Agent 的寻址契约，见 `ProjectVideoDedup.swift:53-59`）。
            // 若把过滤加到 `associatedVideos` 那一层，重排出来的号就与库里的那套分家了。
            .filter { showsMissingVideos || !availability.missingVideoIDs.contains($0.video.id) }
    }

    // MARK: - 已导入视频列表（网格并排）
    private var videoListSection: some View {
        let videos = numberedVideos   // 成片视频（自建分镜不在导入页/成片列表出现，只在分镜库）
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.comfortable) {
            HStack {
                Text("已导入视频")
                    .font(DesignTokens.Typography.bodyEmphasis)
                Spacer()
                Text("显示 \(videos.count) 个视频")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                // 藏起来的丢失项必须在这一行就出声：只写「显示 N 个」而不说另外 M 个没显示，
                // 用户会以为素材被删了 —— 而这恰恰是我们**没有**删它的那种状态。
                if hiddenMissingCount > 0 {
                    Text("另有 \(hiddenMissingCount) 个素材文件已丢失")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .fixedSize()
                }
                Button(importVM.isVideoSelectionMode ? "退出多选" : "多选") {
                    importVM.setVideoSelectionMode(!importVM.isVideoSelectionMode)
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(importVM.isVideoSelectionMode ? .primary : .secondary)
            }
            missingMaterialControls
            if importVM.isVideoSelectionMode {
                videoBatchActionBar(videos: videos)
            }

            // 每张卡片固定宽度约 400px (190*2 + 分隔线 + padding)，可并排
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 440))], alignment: .leading, spacing: DesignTokens.Spacing.comfortable) {
                ForEach(videos, id: \.video.id) { item in
                    let video = item.video
                    ImportedVideoCard(video: video, onDelete: {
                        importVM.deleteVideo(video, from: project)
                    }, onRetryAI: {
                        ToastCenter.shared.show("重新分析中…", icon: "arrow.clockwise", style: .info)
                        Task {
                            await importVM.retryAIAnalysis(for: video, in: project)
                        }
                    }, onRetryASR: {
                        ToastCenter.shared.show("重新识别语音…", icon: "waveform", style: .info)
                        Task {
                            await importVM.retryASR(for: video, in: project)
                        }
                    }, onReidentify: {
                        Task { await importVM.reidentifyWholeVideo(video, context: modelContext) }
                    }, isReidentifying: importVM.reidentifyingVideoIDs.contains(video.id),
                       reidentifyProgress: importVM.reidentifyProgress[video.id].map { "\($0.done + 1)/\($0.total)" },
                       playbackCoordinator: playbackCoordinator,
                       isSelectionMode: importVM.isVideoSelectionMode,
                       isChecked: importVM.selectedVideoIDs.contains(video.id),
                       isMissing: availability.missingVideoIDs.contains(video.id),
                       onRecheckMissing: {
                           Task { await availability.refresh(for: project, force: true) }
                       })
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 只在多选模式接管点击：否则会把"点卡片播放"抢掉（那是零行为变更的红线）
                        guard importVM.isVideoSelectionMode else { return }
                        // ⇧+点击做范围连选，锚点与顺序都按"界面上看到的这份"取（Finder 同款手感）。
                        // 读 NSApp.currentEvent 而不是再造一套手势：SwiftUI 的 onTapGesture 不给事件对象，
                        // 而 macOS 上这就是点击当下修饰键的权威来源。
                        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                            importVM.extendVideoSelection(to: video, visibleOrder: numberedVideos.map(\.video))
                        } else {
                            importVM.toggleVideoSelection(video)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // 视频编号徽章：与 Agent 指令里的 video_no 同一套编号（「1 号视频」即此号）
                        Text("\(item.no) 号")
                            .font(DesignTokens.Typography.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: - 丢失素材：出声与找回路径
    //
    // 三档状态各说一句人话，一句都不许省：**有丢失**（可以藏、可以显示、可以真删记录）、
    // **查不了**（degraded，"我查不了"必须显示成"查不了"，不许伪装成"没丢"也不许伪装成"丢了"）、
    // **有记录未参与判定**（路径不在当前素材目录内，多半是品牌迁移没走完）。

    /// 当前被藏起来的丢失项条数（开关打开后就没有"藏起来"这一说了）。
    private var hiddenMissingCount: Int { showsMissingVideos ? 0 : availability.missingVideoIDs.count }

    /// 界面上看得见的丢失卡，按渲染顺序。「全选丢失项」的定义域 —— 只在这份里选，
    /// 与 Core 作用域判定的"可见集合"同口径，越界那道门才不会反过来拒掉自己。
    private var missingVisibleVideos: [Video] {
        numberedVideos.filter { availability.missingVideoIDs.contains($0.video.id) }.map(\.video)
    }

    @ViewBuilder
    private var missingMaterialControls: some View {
        if let warning = availability.warning {
            InlineBanner(style: .warning, message: warning,
                         onRetry: { Task { await availability.refresh(for: project, force: true) } })
        }
        if !availability.missingVideoIDs.isEmpty || availability.excludedRecords > 0 {
            HStack(spacing: DesignTokens.Spacing.normal) {
                if !availability.missingVideoIDs.isEmpty {
                    Toggle("显示丢失的 \(availability.missingVideoIDs.count) 个（不可播放）",
                           isOn: $showsMissingVideos)
                        .font(DesignTokens.Typography.caption)
                        .lineLimit(1)
                        .fixedSize()
                    Button("重新检查") {
                        Task { await availability.refresh(for: project, force: true) }
                    }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    if showsMissingVideos {
                        // 找回路径的终点：确认文件真的救不回来了，就把记录一起清掉。
                        // 走的是批 2/3 那条唯一咽喉 ⇒ 天然带二次确认与 5 秒撤销。
                        Button("全选丢失项") { importVM.selectMissingVideos(missingVisibleVideos) }
                            .buttonStyle(.plain)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if availability.excludedRecords > 0 {
                    Text("\(availability.excludedRecords) 条记录的路径不在当前素材目录内，未参与判定")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer()
            }
        }
    }

    // MARK: - 批量删除（多选工具栏 + 二次确认）
    //
    // 结构、文案与控件顺序对齐分镜侧那份（`SegmentLibraryView` 的 batchActionBar）——
    // 仓里已有两份批量范式就是债，第三份只会让"哪套是对的"变成每次都要重问的问题。

    /// 多选工具栏：数字全部来自 VM 的实数函数，不在这里自己数一遍（两套计数必然分家）。
    private func videoBatchActionBar(videos: [(no: Int, video: Video)]) -> some View {
        let order = videos.map(\.video)
        let chosen = importVM.selectedVideoIDs.count
        return HStack(spacing: DesignTokens.Spacing.comfortable) {
            Text("已选 \(chosen) 个 · 总时长 \(Int(importVM.selectedVideoTotalDuration(in: project))) 秒")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                // 分镜侧那条血注释照抄：中文长行不换行也不截断，否则工具栏会把数字吃进第二行
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Button("全选") { importVM.selectAllVisibleVideos(order) }
            Button("反选") { importVM.invertVisibleVideoSelection(order) }
            Button("清空") { importVM.clearVideoSelection() }
            Button("删除 \(chosen) 个", role: .destructive) { showBatchDeleteConfirm = true }
                .disabled(chosen == 0)
        }
        // 刻意用 .plain：默认按钮样式会把禁用项减淡，分镜侧记着这条 —— 减淡会让人以为
        // "没有删除这个入口"，而它只是暂时不可点。
        .buttonStyle(.plain)
    }

    /// 二次确认的正文：两档引用数 + 「编号会整体前移」+「文件仍在，24 小时后才回收」，一句都不能少。
    ///
    /// ⚠️ 「显示丢失素材 → 全选丢失项 → 删除」是本方案里**唯一**合法的"真删记录"入口，
    /// 所以这句必须把不可逆的两件事说全：记录与分镜会一起删、老 video_no 会被后面的素材顶上来。
    private var batchDeleteConfirmMessage: String {
        let totals = importVM.videoDeletionTotals(in: project, visibleOrder: numberedVideos.map(\.video))
        var lines: [String] = []
        if totals.localOnlyCount > 0 {
            lines.append("仅本项目使用 \(totals.localOnlyCount) 个：连记录与 \(totals.segmentsDeleted) 个分镜一起删（5 秒内可撤销）")
        }
        if totals.stillReferencedCount > 0 {
            lines.append("还被其它项目引用 \(totals.stillReferencedCount) 个：只解除本项目关联，记录与分镜都保留")
        }
        if totals.unresolvableCount > 0 {
            // 计数诚实：取不到关联的那几条既删不了也不该被算进上面任何一档 ⇒ 必须点名，不许静默少掉
            lines.append("另有 \(totals.unresolvableCount) 个取不到本项目关联行，本次不会处理")
        }
        lines.append("删除后**后续视频编号会整体前移**；磁盘文件不会被删，24 小时后才由回收站处理")
        return lines.joined(separator: "；")
    }

    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mp4", "mov", "avi", "m4v", "mkv"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 错误提示 banner（显示在视频列表上方）
    @ViewBuilder
    private var errorBanner: some View {
        if let error = importVM.errorMessage, !error.isEmpty {
            InlineBanner(style: .warning, message: error) {
                withAnimation(DesignTokens.Motion.transition) {
                    importVM.errorMessage = nil
                }
            }
        }
    }
}

// MARK: - 视频卡片（左右等宽：左视频+信息 | 右台词可滚动）
struct ImportedVideoCard: View {
    let video: Video
    var onDelete: (() -> Void)?
    var onRetryAI: (() -> Void)?
    var onRetryASR: (() -> Void)?
    var onReidentify: (() -> Void)?
    var isReidentifying: Bool = false
    /// 逐段重认的可见进度（形如 `3/17`）；nil = 没在跑这一步
    var reidentifyProgress: String? = nil
    /// 播放设备协调器（所有卡片共享同一实例以实现唯一播放）
    var playbackCoordinator: PlaybackCoordinator? = nil
    /// 批量删除的多选态。⚠️ 必须走 props：直接读 `importVM.selectedVideoIDs` 会让任意一次
    /// 勾选把整页卡片重绘一遍（分镜侧同条裁定）。
    var isSelectionMode: Bool = false
    var isChecked: Bool = false
    /// 源文件已不存在（对账结果由视图传入，同上两条的 props 裁定）。
    /// true 时**不实例化 `InlineVideoPlayer`**：播一个不在的文件只会换来一条事后归因的失败，
    /// 而这一栏此刻该给的是**完整路径** —— 那是用户把文件放回原处唯一需要的东西。
    var isMissing: Bool = false
    var onRecheckMissing: (() -> Void)? = nil

    private let panelWidth: CGFloat = 190

    @State private var showDeleteConfirm = false
    @State private var isRetrying = false
    @State private var leftHeight: CGFloat = 300
    /// 缓存格式化后的句子列表，避免 body 重绘时反复重建 TranscriptionResult
    @State private var cachedSentences: [(index: Int, text: String, time: String)] = []
    @State private var cachedIsASRAbnormal: Bool = false

    private var videoAspectRatio: CGFloat {
        guard video.width > 0, video.height > 0 else { return 9.0 / 16.0 }
        return CGFloat(video.width) / CGFloat(video.height)
    }

    private var isProcessing: Bool {
        switch video.status {
        case .queued, .detectingScenes, .transcribing, .analyzing: return true
        default: return false
        }
    }

    /// 用 ASR 时间戳数据构建语义句子
    private var formattedSentences: [(index: Int, text: String, time: String)] {
        let words = video.asrWords
        let transcript = video.transcript ?? ""

        // 优先用 Whisper 原生句子 + words 构建
        if !words.isEmpty || !video.asrSentences.isEmpty {
            let result = TranscriptionResult(
                text: transcript,
                words: words,
                rawSentences: video.asrSentences,
                language: "zh",
                duration: video.duration
            )
            let sentences = result.sentences
            guard !sentences.isEmpty else { return [] }
            return sentences.enumerated().map { i, s in
                let timeStr = String(format: "%d:%02d", Int(s.startTime) / 60, Int(s.startTime) % 60)
                return (index: i + 1, text: s.text, time: timeStr)
            }
        }

        guard !transcript.isEmpty else { return [] }
        var sentences: [String] = []
        var current = ""
        for char in transcript {
            current.append(char)
            if "。！？.!?".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences.enumerated().map { (index: $0.offset + 1, text: $0.element, time: "") }
    }

    /// 是否有可用的 ASR 时间戳（决定复制结果是否带时间码、Toast 文案如何措辞）
    private var hasASRTimecode: Bool {
        !video.asrWords.isEmpty || !video.asrSentences.isEmpty
    }

    /// 一键复制用的「带起止时间」全文台词（ASR 风格：每行 `[起 - 止] 文本`）。
    /// 有时间戳数据时输出 `[0:00.0 - 0:02.3] 句子`；无时间戳（纯 transcript 兜底）时
    /// 只输出每句一行的纯文本，避免给出错误的 0:00 时间。
    private var transcriptWithTimeForCopy: String {
        if hasASRTimecode {
            let result = TranscriptionResult(
                text: video.transcript ?? "",
                words: video.asrWords,
                rawSentences: video.asrSentences,
                language: "zh",
                duration: video.duration
            )
            let lines = result.sentences.map { s in
                "[\(Self.copyTimeLabel(s.startTime)) - \(Self.copyTimeLabel(s.endTime))] \(s.text)"
            }
            return lines.joined(separator: "\n")
        }

        // 兜底：仅有纯文本，无时间戳 → 复用界面分句逻辑，每句一行
        return cachedSentences.map(\.text).joined(separator: "\n")
    }

    /// 把全文台词写入系统剪贴板并弹 Toast。按钮与右键菜单共用，避免逻辑重复。
    private func copyTranscript() {
        let text = transcriptWithTimeForCopy
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let suffix = hasASRTimecode ? "（含时间码）" : ""
        ToastCenter.shared.show("已复制 \(cachedSentences.count) 句台词\(suffix)", icon: "doc.on.doc.fill")
    }

    /// 复制台词用的时间格式：`分:秒.十分位`（如 `0:02.3`、`1:05.8`）。
    /// 注：`%04.1f` 的宽度 4 = 两位整数 + 小数点 + 一位小数（即 `SS.S`），printf 自带四舍五入。
    private static func copyTimeLabel(_ t: Double) -> String {
        let total = max(0, t)
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    /// 检测 ASR 输出粒度是否异常（基于 cachedSentences）
    private func computeIsASRAbnormal(_ sentences: [(index: Int, text: String, time: String)]) -> Bool {
        guard video.status == .completed else { return false }
        guard !sentences.isEmpty else { return false }
        if sentences.count == 1 && video.duration > 8.0 { return true }
        return sentences.contains { $0.text.count > 50 }
    }

    /// 刷新缓存（在 onAppear / video 关键字段变化时调用）
    private func refreshSentenceCache() {
        cachedSentences = formattedSentences
        cachedIsASRAbnormal = computeIsASRAbnormal(cachedSentences)
    }

    var body: some View {
        // 删除视频时，@Observable 的 Video 被 context.delete 后仍会向「正在被移除的本卡片」
        // 发出变更通知，触发 body 重算；此时读 video.status 等持久属性会命中 SwiftData
        // 已删除对象断言（EXC_BREAKPOINT）。故先判断对象是否已从上下文摘除，已删则不渲染。
        if video.isDroppedFromContext {
            Color.clear.frame(width: 0, height: 0)
        } else {
            cardBody
                .overlay(alignment: .topTrailing) {
                    if isSelectionMode {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                            .background(.thinMaterial, in: Circle())
                            .padding(8)
                            .allowsHitTesting(false)   // 点卡片的活交给父层的手势，圈只做显示
                    }
                }
        }
    }

    private var cardBody: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧：视频 + 信息（自然高度，决定整体高度）
            leftPanel
                .frame(width: panelWidth)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: LeftPanelHeightKey.self, value: geo.size.height)
                    }
                )

            // 分隔线
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .padding(.vertical, 12)

            // 右侧：台词（等宽等高，内部滚动）
            rightPanel
                .frame(width: panelWidth, height: leftHeight, alignment: .top)
                .clipped()
        }
        .onPreferenceChange(LeftPanelHeightKey.self) { leftHeight = $0 }
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.large, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(video.name, forType: .string)
                ToastCenter.shared.show("文件名已复制", icon: "doc.on.doc.fill")
            } label: {
                Label("复制文件名", systemImage: "doc.on.doc")
            }

            if !cachedSentences.isEmpty {
                Button {
                    copyTranscript()
                } label: {
                    Label(hasASRTimecode ? "复制台词（含时间码）" : "复制台词", systemImage: "text.quote")
                }
            }

            Button {
                // 先问可用性：对一个已经不在的文件"在 Finder 中显示"是一条静默失败
                //（系统什么都不做，也不报错），用户只会以为按钮坏了。
                guard FileHelper.isMaterialFilePresent(path: video.localPath) else {
                    ToastCenter.shared.show(
                        MissingMaterialCopy.fullMessage(fileName: video.name),
                        icon: "exclamationmark.triangle.fill", style: .warning)
                    return
                }
                let url = URL(fileURLWithPath: video.localPath)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除视频", systemImage: "trash")
            }
        }
        .onChange(of: video.status) { _, newStatus in
            if newStatus != .analyzing { isRetrying = false }
            refreshSentenceCache()
        }
        .onChange(of: video.transcript) { _, _ in
            refreshSentenceCache()
        }
        .task {
            refreshSentenceCache()
        }
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                // Toast（含「撤销」按钮）由 deleteVideo 内部弹出，这里不要再弹一个把它覆盖掉
                onDelete?()
            }
        } message: {
            Text("将删除「\(video.name)」及其全部分镜数据。删除后 5 秒内可点「撤销」找回。")
        }
    }

    // MARK: - 左侧面板

    /// 丢失素材的左栏：不实例化播放器，把**完整路径**摊在屏上（可选中复制），
    /// 再给一个「重新检查」—— 用户把文件放回原处之后，这一颗就是唯一的自愈通道。
    private var missingMaterialPanel: some View {
        VStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text(MissingMaterialCopy.fullMessage(fileName: video.name))
                .font(DesignTokens.Typography.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text(video.localPath)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Button("重新检查") { onRecheckMissing?() }
                .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.normal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.05))
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            // 视频播放器
            ZStack {
                if isMissing {
                    missingMaterialPanel
                } else if !isProcessing && video.status != .failed {
                    InlineVideoPlayer(
                        videoPath: video.localPath,
                        thumbnailPath: video.thumbnailPath,
                        aspectRatio: videoAspectRatio,
                        playbackID: video.id.uuidString,
                        coordinator: playbackCoordinator
                    )
                } else {
                    thumbnailOrPlaceholder
                }

                if isProcessing {
                    Color.black.opacity(0.55)
                    VStack(spacing: DesignTokens.Spacing.compact) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                        Text(processingLabel)
                            .font(DesignTokens.Typography.captionEmphasis)
                            .foregroundStyle(.white)
                    }
                }

                if video.status == .failed {
                    Color.red.opacity(0.4)
                    VStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                        Text("处理失败")
                            .font(DesignTokens.Typography.captionEmphasis)
                    }
                    .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 文件名（可鼠标选中复制；自适应高度，完整显示）
            SelectableLabel(text: video.name, fontSize: 11, weight: .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(video.name)

            // 元数据
            HStack(spacing: 6) {
                if video.duration > 0 {
                    Label(formatDuration(video.duration), systemImage: "clock")
                }
                if video.width > 0 {
                    Label(video.resolution, systemImage: "rectangle.on.rectangle")
                }
            }
            .font(DesignTokens.Typography.microRegular)
            .foregroundStyle(.secondary)

            // 流水线
            pipelineRow

            // 状态 + 操作
            HStack(spacing: DesignTokens.Spacing.tight) {
                VideoStatusBadge(status: video.status)
                Spacer()

                // 白名单：只在「孤立 imported（未排队也未在跑）」或「明确 failed」时显示重试按钮
                // 防御性约束 — 即使未来 isProcessing 实现被改坏，queued/processing 状态也绝不会出按钮
                let canShowRetry = (video.status == .imported || video.status == .failed)
                                   && video.segments.isEmpty
                                   && !isRetrying
                                   && !isProcessing
                if canShowRetry {
                    Button {
                        isRetrying = true
                        onRetryAI?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text(video.errorMessage != nil ? "重试" : "AI分析")
                        }
                        .font(DesignTokens.Typography.microEmphasis)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }

                if isRetrying {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        ProgressView().controlSize(.mini)
                        Text("分析中…")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.blue)
                    }
                }
            }

            // 错误信息
            if let errorMsg = video.errorMessage, !errorMsg.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.orange)
                        Text(errorMsg)
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .textSelection(.enabled)
                    }
                }
            }

            // 分镜规划留痕（F5）：规则改写过这条素材的切分，就必须在卡片上看得见 ——
            // 否则「AI 本来切成 8 段、被并成 3 段」会看起来像软件漏切。
            // 文案自带原因与两个数，芯片放不下时由 .help 给全文（沿用仓里既有的 .help 用法）。
            if let note = video.segmentationGuardNote, !note.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: note.hasPrefix("整片保留") ? "rectangle.split.1x2.fill"
                                                                : "arrow.triangle.merge")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.teal)
                    Text(note)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .help(note)
            }

            // 分镜标签
            if !video.segments.isEmpty {
                segmentTags
            }
        }
        .padding(10)
    }

    // MARK: - 右侧面板（台词，可滚动）
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ⚠️ lineLimit(1)：与素材库卡片台词头部行同一类缺陷的保险。这一处面板宽是写死的
            // （`panelWidth`），今天不塌；只加 lineLimit、不加 fixedSize —— 后者会把行顶出被裁的容器。
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                Text("台词")
                    .font(DesignTokens.Typography.microEmphasis)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let transcript = video.transcript, !transcript.isEmpty {
                    Text("\(transcript.count)字")
                        .font(DesignTokens.Typography.microMono)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                // 一键复制全部台词（带起止时间，ASR 风格）
                if !cachedSentences.isEmpty {
                    Button {
                        copyTranscript()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                                .font(DesignTokens.Typography.microBold)
                            Text("复制台词")
                                .font(DesignTokens.Typography.micro)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("复制全部台词（含起止时间）")
                }

                // ASR 异常时显示「重新识别」入口
                if cachedIsASRAbnormal, let onRetryASR {
                    Button {
                        onRetryASR()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise")
                                .font(DesignTokens.Typography.microBold)
                            // 全 App 统一措辞：失败后重跑一律叫「重试」，不再混用「重做」
                            Text("重试")
                                .font(DesignTokens.Typography.micro)
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("ASR 分句异常，点击重新识别")
                }

                // 阿里重识别整片入口（图标按钮，避免文字换行）
                if let onReidentify {
                    Button(action: onReidentify) {
                        Group {
                            if isReidentifying {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(DesignTokens.Typography.microBold)
                            }
                        }
                        .foregroundStyle(.purple)
                        .frame(width: 20, height: 18)
                        .background(.purple.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(isReidentifying)
                    .help("逐分镜重认台词：用哪台引擎由「设置 › 台词重听引擎」与决策表定（不改分镜边界）")
                    .accessibilityLabel("重新识别台词")

                    // 逐段重认是串行的，一段几秒、整批能到一两分钟 —— 没有 k/n 就只看到一个转圈，
                    // 分不清"在跑"和"卡住了"（计划 §6 判据）。
                    if let progress = reidentifyProgress {
                        Text("逐段重听 \(progress)")
                            .font(DesignTokens.Typography.microMono)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityLabel("逐段重听进度 \(progress)")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 异常提示条
            if cachedIsASRAbnormal {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.orange)
                    Text("分句较粗，可点击右上「重做」或下方「拆分」")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.06))
            }

            if cachedSentences.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(DesignTokens.Typography.headline)
                        .foregroundStyle(.tertiary)
                    Text("暂无台词")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // LazyVStack 自带懒加载，屏幕外的台词行不会同步实例化 NSTextField，
                    // 性能足够；不再需要折叠到 8 句的额外保护
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(cachedSentences, id: \.index) { item in
                            EditableSentenceRow(
                                time: item.time.isEmpty ? "\(item.index)" : item.time,
                                text: item.text,
                                sentenceIndex: item.index - 1,
                                video: video,
                                allowSplit: cachedIsASRAbnormal
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: - 缩略图（命中缓存直出，未命中后台解码后淡入）
    @ViewBuilder
    private var thumbnailOrPlaceholder: some View {
        AsyncCachedImage(
            path: video.thumbnailPath,
            placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
            },
            imageContent: { image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
            }
        )
    }

    private var processingLabel: String {
        switch video.status {
        case .queued: return "等待中…"
        case .detectingScenes: return "1/3 视频分析中..."
        case .transcribing: return "2/3 语音识别中..."
        case .analyzing: return "3/3 AI 分析中..."
        default: return ""
        }
    }

    // MARK: - 处理流水线
    private var pipelineRow: some View {
        HStack(spacing: 2) {
            pipelineChip(
                label: "视频",
                isDone: video.status != .imported && video.status != .queued && video.status != .detectingScenes,
                isActive: video.status == .detectingScenes
            )
            Image(systemName: "chevron.right")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary.opacity(0.4))
            pipelineChip(
                label: "ASR",
                isDone: !(video.transcript ?? "").isEmpty,
                isActive: video.status == .transcribing
            )
            Image(systemName: "chevron.right")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary.opacity(0.4))
            pipelineChip(
                label: "AI",
                isDone: video.status == .completed,
                isActive: video.status == .analyzing
            )
        }
    }

    private func pipelineChip(label: String, isDone: Bool, isActive: Bool) -> some View {
        HStack(spacing: 2) {
            if isActive {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(isDone ? Color.green : Color.secondary.opacity(0.3))
            }
            Text(label)
                .font(.system(size: 10, weight: isDone || isActive ? .bold : .regular))
                .foregroundStyle(isDone || isActive ? Color.primary : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(isDone ? Color.green.opacity(0.06) : isActive ? Color.orange.opacity(0.06) : Color.clear)
        .clipShape(Capsule())
    }

    // MARK: - 分镜标签
    private var segmentTags: some View {
        var typeCounts: [SemanticType: Int] = [:]
        for seg in video.segments {
            for t in seg.semanticTypes { typeCounts[t, default: 0] += 1 }
        }
        let sorted = typeCounts.sorted { $0.value > $1.value }

        // ⚠️ 这里原本是 HStack：卡片文字列只有 ~200pt 宽，5 个标签塞不下时 SwiftUI 会把每个
        // Text 压到最窄，导致「效果展示」被换行成**竖排单字**，非常难看。
        // 改用 FlowLayout 自动换行，并给每个标签 lineLimit(1) + fixedSize 明确"宁可换行、不许压扁"。
        return FlowLayout(spacing: DesignTokens.Spacing.tight) {
            ForEach(sorted.prefix(5), id: \.key) { type, count in
                HStack(spacing: 2) {
                    Text(type.rawValue)
                        .font(DesignTokens.Typography.micro)
                    if count > 1 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(SemanticTypeTag.color(for: type).opacity(DesignTokens.Palette.Alpha.light))
                .foregroundStyle(SemanticTypeTag.color(for: type))
                .clipShape(Capsule())
            }

            if sorted.count > 5 {
                Text("+\(sorted.count - 5)")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 可编辑台词行
struct EditableSentenceRow: View {
    let time: String
    let text: String
    let sentenceIndex: Int
    let video: Video
    var allowSplit: Bool = false   // ASR 异常时由父视图传 true，显示「拆分」按钮

    @Environment(\.modelContext) private var modelContext
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(time)
                .font(DesignTokens.Typography.microMonoStrong)
                .foregroundStyle(.secondary.opacity(0.4))
                .frame(width: 40, alignment: .trailing)
                .lineLimit(1)
                .monospacedDigit()
                .padding(.trailing, 4)

            // 点击即可编辑，文字随时可选中复制（AppKit NSTextField 原生能力）
            EditableSentenceField(text: text, fontSize: 11) { newValue in
                commitEdit(newValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if allowSplit && text.count >= 8 && (isHovered || text.count > 30) {
                Button {
                    splitSentence()
                } label: {
                    Image(systemName: "scissors")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.blue.opacity(0.7))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help("从中点拆分为两句")
                .accessibilityLabel("拆分句子")
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
    }

    private func commitEdit(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != text else { return }

        // 更新 ASR 句子数据
        var sentences = video.asrSentences
        if sentenceIndex >= 0 && sentenceIndex < sentences.count {
            sentences[sentenceIndex].text = trimmed
            video.asrSentences = sentences
        }

        // 同步更新 transcript
        let allText = sentences.map(\.text).joined(separator: " ")
        video.transcript = allText

        modelContext.safeSave()
    }

    /// 把当前句子从字符中点（优先标点附近）拆成两句
    private func splitSentence() {
        var sentences = video.asrSentences
        guard sentenceIndex >= 0, sentenceIndex < sentences.count else { return }

        let current = sentences[sentenceIndex]
        guard current.text.count >= 6 else { return }

        // 找拆分点：优先在中点附近找标点，没有就用中点
        let midIdx = current.text.count / 2
        let chars = Array(current.text)
        let punct: Set<Character> = ["，", "。", "！", "？", "、", "；", "：", ",", ".", "!", "?", ";", ":"]

        var splitAt = midIdx
        // 在 [midIdx - 6, midIdx + 6] 范围内找最近标点
        for offset in 0..<min(6, midIdx) {
            if midIdx + offset < chars.count, punct.contains(chars[midIdx + offset]) {
                splitAt = midIdx + offset + 1; break
            }
            if midIdx - offset > 0, punct.contains(chars[midIdx - offset]) {
                splitAt = midIdx - offset + 1; break
            }
        }
        splitAt = max(1, min(chars.count - 1, splitAt))

        let firstText = String(chars[0..<splitAt]).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = String(chars[splitAt..<chars.count]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstText.isEmpty, !secondText.isEmpty else { return }

        // 时间按字数比例分配
        let totalDur = current.end - current.start
        let firstRatio = Double(firstText.count) / Double(firstText.count + secondText.count)
        let midTime = current.start + totalDur * firstRatio

        let first = ASRSentence(text: firstText, start: current.start, end: midTime)
        let second = ASRSentence(text: secondText, start: midTime, end: current.end)

        sentences.remove(at: sentenceIndex)
        sentences.insert(second, at: sentenceIndex)
        sentences.insert(first, at: sentenceIndex)
        video.asrSentences = sentences

        let allText = sentences.map(\.text).joined(separator: " ")
        video.transcript = allText
        modelContext.safeSave()
    }
}

// MARK: - 可编辑 + 可选中复制的台词字段（AppKit NSTextField，不依赖 SwiftUI @FocusState）
struct EditableSentenceField: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let onCommit: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.stringValue = text
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize)
        field.textColor = NSColor.labelColor.withAlphaComponent(0.85)
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        // 外部文本变化且当前不在编辑时才同步，避免打断用户输入
        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let measured = nsView.cell?.cellSize(forBounds: bounds).height ?? (fontSize + 6)
        return CGSize(width: width, height: ceil(max(measured, fontSize + 6)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var isEditing = false

        init(onCommit: @escaping (String) -> Void) {
            self.onCommit = onCommit
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            guard let field = obj.object as? NSTextField else { return }
            onCommit(field.stringValue)
        }
    }
}

// MARK: - 状态徽章
struct VideoStatusBadge: View {
    let status: VideoStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: statusIcon)
            Text(statusText)
        }
        .font(DesignTokens.Typography.microBold)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.12))
        .foregroundStyle(statusColor)
        .clipShape(Capsule())
    }

    private var statusIcon: String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .imported: return "arrow.down.circle.fill"
        case .queued: return "hourglass"
        default: return "gearshape.2.fill"
        }
    }

    private var statusText: String {
        switch status {
        case .imported: return "已导入"
        case .queued: return "等待中"
        case .detectingScenes: return "检测镜头"
        case .transcribing: return "语音识别"
        case .analyzing: return "分析中"
        case .completed: return "处理完成"
        case .failed: return "失败"
        }
    }

    private var statusColor: Color {
        switch status {
        case .imported: return .gray
        case .queued: return .blue
        case .detectingScenes, .transcribing, .analyzing: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - 可鼠标选中复制的标签（NSTextField 包装，自适应高度完整显示）
struct SelectableLabel: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let weight: NSFont.Weight

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0          // 不限行数，完整显示
        field.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        field.textColor = .labelColor
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    }

    /// 按 SwiftUI 给定的宽度精确计算多行文本所需高度
    /// 用 cellSize(forBounds:) 纯计算，不调 invalidateIntrinsicContentSize（会触发无限布局循环）
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 180
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let measured = nsView.cell?.cellSize(forBounds: bounds).height ?? (fontSize + 4)
        return CGSize(width: width, height: ceil(max(measured, fontSize + 4)))
    }
}
