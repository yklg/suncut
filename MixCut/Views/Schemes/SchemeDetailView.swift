import SwiftUI
import SwiftData

struct SchemeDetailView: View {
    let scheme: MixScheme
    @Bindable var viewModel: SchemeViewModel
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    @Environment(\.modelContext) private var modelContext

    @State private var drawerOperation: SegmentPickerDrawer.Operation?

    /// 脚本方案的只读投影（经冻结 ScriptDocument 反查）；原片方案为 nil。
    @State private var scriptDraft: ScriptExportDraft?

    /// 脚本成片配音生成（独立 VM 实例；忙碌经 DubbingJobRegistry.shared 与素材库/MCP 跨实例互斥）。
    @State private var dubVM = DubbingViewModel()
    /// 整方案配音任务运行态（驱动就绪行动区；真实忙碌源是 registry，本值仅刷新 UI）。
    @State private var scriptDubRunning = false
    /// 计费确认弹窗（展示段数/音色；单段重试不弹）。
    @State private var showScriptDubConfirm = false

    /// 是否为 dubOnly 脚本方案（配音行动区与单卡行只对它呈现）。
    private var isScriptDubOnly: Bool {
        !scheme.audioTrackPolicy.allowsOriginalFallback
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.generous) {
                    schemeHeader

                    Divider()

                    narrativeStructureBar

                    Divider()

                    storyboardView

                    // 策略说明
                    if let reasoning = scheme.strategyReasoning, !reasoning.isEmpty {
                        infoSection(title: "策略说明", icon: "lightbulb", text: reasoning)
                    }

                    // 差异化说明
                    if let diff = scheme.differentiation, !diff.isEmpty {
                        infoSection(title: "差异化", icon: "arrow.triangle.branch", text: diff)
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)

            // 抽屉项目走标识符优先：只取 scheme.project 边目标的 persistentModelID（不 fault backing），
            // 从活 fetch 项目构建索引解析；项目已真删（悬空边）⇒ 抽屉整体收起
            // —— 2026-10-04 SIGTRAP 的防护；`.live` 探针两信号在此相位全假，不可用。
            if let op = drawerOperation, let project = drawerProject {
                Divider()
                SegmentPickerDrawer(
                    project: project,
                    scheme: scheme,
                    schemeVM: viewModel,
                    operation: op,
                    onPick: { segment in handlePick(segment, operation: op) },
                    onClose: { drawerOperation = nil }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .animation(DesignTokens.Motion.transition, value: drawerOperation)
        .task(id: scheme.live?.id) {
            cleanupStaleDubs()
            scriptDraft = ScriptExportAssembly.draft(for: scheme, context: modelContext)
        }
    }

    /// 清理废弃的旧克隆变体：架构为「只克隆原声」，每个视频当前仅一个有效克隆声 ID
    /// （`video.clonedVoiceId`）。voiceId 不等于当前 ID 的 SegmentDub 是历史残留。
    ///
    /// ⚠️ **只删没有音频的空壳记录**。原先这里会连音频文件一起删，是严重的静默数据丢失：
    /// - 换 API Key 会触发重克隆并换掉 `clonedVoiceId`，于是**之前所有生成好的配音**都变成"voiceId 不一致"
    /// - 而 `Segment.effectiveDubVariants` 并不按 voiceId 过滤，这些配音其实还能正常用、也还在被方案引用
    /// - 结果是：用户仅仅点开一个方案详情，跨所有项目的付费配音成果就被无声抹掉，且不可撤销
    ///
    /// 现在的口径：有音频文件的一律保留（大不了留着不用），只回收确实没东西可丢的空记录。
    private func cleanupStaleDubs() {
        var changed = false
        var keptCount = 0
        // 本方案里被显式选中的配音 id：这些一旦删掉，selectedSegmentDubId 会变成悬空 UUID，
        // 该方案会静默退回原声，而用户几乎不可能察觉。
        let referencedDubIDs = Set(scheme.schemeSegments.compactMap { $0.selectedSegmentDubId })

        for ss in scheme.orderedSegments {
            guard let seg = ss.segment, let current = seg.video?.clonedVoiceId else { continue }
            for d in seg.segmentDubs where d.voiceId != current {
                // 脚本成片配音（含 voiceId 暂为空的未绑定壳）属方案级资产，
                // 不适用「视频旧克隆音色残留」清理——只能由删方案 Reap 回收。
                // 豁免它们避免打开方案详情时把待生成载体悄悄删掉。
                if ScriptDubReap.scriptProvenanceRaws.contains(d.textProvenanceRaw) {
                    keptCount += 1
                    continue
                }
                // 有音频文件 → 保留，绝不删用户的付费成果
                let hasAudio = d.audioFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                if hasAudio { keptCount += 1; continue }
                // 正被方案引用 → 保留。
                // ⚠️ 这里必须真的查 selectedSegmentDubId。`audioFilePath == nil` 也可能只是
                // `updateVariantText` 改文案后清空了旧音频、正在等重新合成的中间态，删掉就把选择丢了。
                if referencedDubIDs.contains(d.id) { keptCount += 1; continue }
                modelContext.delete(d)
                changed = true
            }
        }
        if keptCount > 0 {
            MixLog.info("[SchemeDetail] 保留 \(keptCount) 条旧音色的配音（有音频，不清理）")
        }
        if changed { modelContext.safeSave() }
    }

    /// 抽屉绑定项目（标识符优先）：从活 fetch 项目构建解边索引，
    /// 解析 scheme.project 边的 persistentModelID；悬空 ⇒ nil（抽屉收起，不 fault 死 backing）。
    private var drawerProject: Project? {
        let projects = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        var index = LiveModelIDIndex()
        index.insert(projects, id: \.id)
        guard let projectID = index.uuid(for: scheme.project) else { return nil }
        return projects.first { $0.id == projectID }
    }

    private func handlePick(_ segment: Segment, operation: SegmentPickerDrawer.Operation) {
        switch operation {
        case .insert(let position):
            if viewModel.insertSegment(segment, at: position, in: scheme) {
                ToastCenter.shared.show("已插入到 #\(position)", icon: "checkmark.circle.fill", style: .success)
                // ⚠️ 插入点必须后移一格。抽屉插入后不关闭（方便连续挑几个），
                // 但 position 是常量：不后移的话，选 A 落到 #3、再选 B 又落到 #3 并把 A 顶到 #4，
                // 最终顺序变成 B、A —— 与用户点选顺序正好相反。
                drawerOperation = .insert(position: position + 1)
            }
        case .replace(let schemeSegmentID, _):
            if let schemeSeg = scheme.schemeSegments.first(where: { $0.id == schemeSegmentID }) {
                if viewModel.replaceSegment(schemeSeg, with: segment, in: scheme) {
                    ToastCenter.shared.show("已替换 #\(schemeSeg.position)", icon: "checkmark.circle.fill", style: .success)
                    // 替换是一次性操作：完成即收起抽屉。
                    // 不收起的话，用户再点一个就把刚换上去的又换掉了。
                    drawerOperation = nil
                }
            }
        }
    }

    // MARK: - 方案头部

    private var schemeHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
            HStack(alignment: .firstTextBaseline) {
                Text(scheme.name)
                    .font(.system(size: 20, weight: .semibold))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scheme.name, forType: .string)
                    ToastCenter.shared.show("方案名已复制", icon: "doc.on.doc.fill")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("复制方案名")
                .accessibilityLabel("复制方案名")

                Spacer()
                // 统计数值统一用 metric 令牌：原来是 24pt `.light`，既违反"字重只用
                // regular/medium/semibold/bold"的规范，浅色底上对比度也过低。
                Text(String(format: "%.1f", scheme.totalDuration))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.primary)
                +
                Text("s")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }

            // Step 7 收口之一：本会话内有分镜被真删时，方案详情头部要显式说"少了 N 段"，
            // 而不是等用户去选素材抽屉里发现卡片变少了。
            // 数字来自 `SchemeViewModel.prunedCountByScheme`（归属在 VM 只有一份）；
            // 这里**不许**自己数 `scheme.schemeSegments` —— 视图层裸读模型关系正是
            // 本案那一族 SIGTRAP 的形状（`TombstoneReadGuardTests` G08b 钉着那道门）。
            if let dropped = viewModel.prunedCountByScheme[scheme.id], dropped > 0 {
                HStack(spacing: DesignTokens.Spacing.tight) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Palette.Status.warning)
                    Text("该方案有 \(dropped) 段素材已不存在，成片会少这几段（导出时也会逐条报出）")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Palette.Status.warning)
                    Spacer()
                }
            }

            if !scheme.schemeDescription.isEmpty {
                Text(scheme.schemeDescription)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            HStack(spacing: DesignTokens.Spacing.compact) {
                // 左：信息标签
                InfoChip(icon: "paintpalette", text: scheme.style)
                InfoChip(icon: "person.2", text: scheme.targetAudience)
                InfoChip(icon: "film.stack", text: "\(scheme.segmentCount) 分镜")
                if let scriptDraft {
                    InfoChip(icon: scriptDraft.direction == .reverse
                             ? "arrow.left.to.line" : "text.cursor",
                             text: scriptDraft.direction == .reverse ? "逆向文案" : "产品脚本")
                }
                // 弹簧：声音策略 + 导出脚本固定右侧同一行（不换行；窄窗口压缩左侧）。
                Spacer(minLength: 8)
                if scheme.audioTrackPolicy != .keepOriginal {
                    InfoChip(icon: "waveform", text: scheme.audioTrackPolicy.displayLabel)
                }
                if let scriptDraft {
                    scriptExportMenu(scriptDraft)
                }
            }
            .lineLimit(1)

            if !scheme.narrativeStructure.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.arrow.left")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.blue)
                    Text(scheme.narrativeStructure)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    /// 脚本方案的「导出 .txt/.md」菜单（内容为冻结脚本的只读投影）。
    private func scriptExportMenu(_ draft: ScriptExportDraft) -> some View {
        Menu {
            ForEach(ScriptTextExportFormat.allCases, id: \.self) { format in
                Button(format.displayLabel) {
                    ScriptExportAssembly.saveViaPanel(draft, format: format)
                }
            }
        } label: {
            Label("导出脚本", systemImage: "square.and.arrow.up")
                .font(DesignTokens.Typography.micro)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("把冻结的脚本（含标签与引用出处）导出为文本文件")
    }

    // MARK: - 叙事结构条

    private var narrativeStructureBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("叙事结构")
                .font(DesignTokens.Typography.labelEmphasis)
                .foregroundStyle(.secondary)

            // 叙事结构条：横向条形分布，节点不多但用 LazyHStack 保持懒加载一致性
            // ⚠️ 性能：`scheme.totalDuration` 是 O(分镜数) 的 reduce。写在 ForEach 体内会变成
            // O(n²)，且窗口宽度一变就整体重跑。这里提到循环外，只算一次。
            let totalDuration = max(scheme.totalDuration, 1)
            GeometryReader { geo in
                LazyHStack(spacing: 2) {
                    ForEach(scheme.orderedSegments) { schemeSeg in
                        if let segment = schemeSeg.segment {
                            let width = max(30, geo.size.width * (segment.duration / totalDuration))
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SemanticTypeTag.color(for: segment.semanticTypes.first ?? .transition))
                                .frame(width: width)
                                .overlay {
                                    Text(segment.semanticTypes.map(\.rawValue).joined(separator: "/"))
                                        .font(DesignTokens.Typography.micro)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .padding(.horizontal, 2)
                                }
                                .help("\(segment.semanticTypes.map(\.rawValue).joined(separator: "/")) - \(String(format: "%.1fs", segment.duration))")
                        }
                    }
                }
            }
            .frame(height: 28)

            // 图例
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(usedTypes, id: \.self) { type in
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Circle()
                                .fill(SemanticTypeTag.color(for: type))
                                .frame(width: 6, height: 6)
                            Text(type.rawValue)
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Storyboard 视图

    private var storyboardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: DesignTokens.Spacing.compact) {
                Text("分镜序列")
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(.secondary)
                Spacer()
                combinationHint
            }

            ScrollView(.horizontal, showsIndicators: true) {
                // LazyHStack：横向懒加载，屏幕外的 StoryboardCard 不同步实例化
                LazyHStack(alignment: .top, spacing: 0) {
                    InsertGapButton { drawerOperation = .insert(position: 1) }

                    ForEach(Array(scheme.orderedSegments.enumerated()), id: \.element.id) { idx, schemeSeg in
                        StoryboardCard(
                            schemeSeg: schemeSeg,
                            segmentLibraryVM: segmentLibraryVM,
                            canDelete: scheme.schemeSegments.count > 1,
                            isDubOnlyScript: isScriptDubOnly,
                            project: drawerProject,
                            dubVM: dubVM,
                            onGenerateScriptDub: { force in
                                Task { await dubVM.generateScriptDub(
                                    for: schemeSeg, scheme: scheme,
                                    project: drawerProject, context: modelContext,
                                    forceRegenerate: force) }
                            },
                            onDelete: { viewModel.removeSegment(schemeSeg, from: scheme) },
                            onReplace: {
                                let originalTypes = schemeSeg.segment?.semanticTypes ?? []
                                drawerOperation = .replace(schemeSegmentID: schemeSeg.id, originalSemantic: originalTypes)
                            }
                        )

                        InsertGapButton { drawerOperation = .insert(position: idx + 2) }
                    }
                }
                .padding(.bottom, 4)
                // 强制最小高度，避免 LazyHStack 被压缩
                .frame(minHeight: 380)
            }
            .frame(height: 400)
        }
    }

    /// 每镜可选项数（锁定=1，否则 原声+各改写=1+变体数），乘积=此方案导出可生成的变体组合数。
    private var slotFactors: [Int] {
        scheme.orderedSegments.map { ss in
            guard let seg = ss.segment else { return 1 }
            return seg.combinationSlotCount   // 与导出笛卡尔积一致（含参与过滤/兜底/锁定）
        }
    }

    /// 「此方案可生成 N 个变体组合（3×1×3×3）」提示。
    /// keepOriginal 策略：展示配音变体笛卡尔积；dubOnly 脚本方案：组合恒为 1，
    /// 改展示逐槽新配音就绪度（缺配音时导出会结构化报错，绝不回退原声）。
    @ViewBuilder
    private var combinationHint: some View {
        if !scheme.audioTrackPolicy.allowsOriginalFallback {
            dubOnlyReadinessHint
        } else {
            let factors = slotFactors
            let total = factors.reduce(1, *)
            if total <= 1 {
                Label("暂无配音变体，导出为原声", systemImage: "waveform.slash")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
            } else {
                Label("可生成 \(total) 个变体组合（\(factors.map(String.init).joined(separator: "×"))）",
                      systemImage: "square.grid.3x3.fill")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.tint)
                    .help("此方案每个分镜可用「原声/改写A/改写B…」，全部排列组合共 \(total) 种；锁定原声的分镜计为 ×1。导出时按当前选定的一种组合输出一条视频。")
            }
        }
    }

    /// dubOnly 就绪行动区：未配置引导 / 待生成一键 / 进行中停止 / 完成态。
    /// 就绪读数取 DubbingVM 单一投影（与导出 blockers 同源）；@Bindable dubVM 驱动进度刷新。
    @ViewBuilder
    private var dubOnlyReadinessHint: some View {
        let status = dubVM.scriptDubbingReadiness(for: scheme)
        let configured = VoicePreferences.globalDefaultChoice != nil
            || VoiceChoiceCoder.decode(drawerProject?.preferredVoiceChoiceRaw) != nil
        let busy = scriptBusy

        HStack(spacing: 9) {
            Image(systemName: busy ? "waveform" : (status.allReady ? "checkmark.circle.fill" : "waveform.badge.exclamationmark"))
                .font(DesignTokens.Typography.body)
                .foregroundStyle(status.allReady ? .green : (configured ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 1) {
                if status.allReady {
                    Text("全新配音已就绪（\(status.ready)/\(status.total) 段）· 导出不使用原声")
                        .font(DesignTokens.Typography.micro).foregroundStyle(.green)
                } else if busy {
                    Text("正在合成全新配音（\(status.ready)/\(status.total) 段）…")
                        .font(DesignTokens.Typography.micro).foregroundStyle(.blue)
                } else if configured {
                    Text("全新配音 \(status.ready)/\(status.total) 段已生成 · 使用全局/项目音色合成，不回退原声")
                        .font(DesignTokens.Typography.micro).foregroundStyle(.orange)
                } else {
                    Text("尚未配置配音音色 · 请到「设置 → 配音」选择全局音色后生成")
                        .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy {
                Button {
                    stopScriptDubs()
                } label: {
                    Label("停止", systemImage: "stop.circle").font(DesignTokens.Typography.micro)
                }
                .buttonStyle(.borderless).controlSize(.small)
            } else if !status.allReady && !configured {
                // 未配置音色：直接给「去设置配置」入口，而不是把生成按钮置灰让人找。
                Button {
                    NotificationCenter.default.post(name: .mixCutShowSettings, object: nil)
                } label: {
                    Label("去设置配置音色", systemImage: "gearshape")
                        .font(DesignTokens.Typography.micro)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else if !status.allReady {
                Button {
                    showScriptDubConfirm = true
                } label: {
                    Label("生成全部新配音（\(max(0, status.total - status.ready)) 段）",
                          systemImage: "waveform")
                        .font(DesignTokens.Typography.micro)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!configured)
                .help(configured ? "用全局/项目音色逐段合成，无需克隆原声" : "请先在设置中选择全局音色")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(status.allReady ? .green.opacity(0.08)
                      : (configured ? .orange.opacity(0.08) : .secondary.opacity(0.06)))
        )
        .confirmationDialog("生成全新配音？", isPresented: $showScriptDubConfirm) {
            Button("开始（按次计费）") { Task { await runGenerateAll() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将用当前音色为 \(max(0, status.total - status.ready)) 个分镜合成语音（仅 TTS 合成，不克隆原声、不改写文案）。按次计费，可随时停止。")
        }
        // 配音错误统一上浮
        .alert("配音生成未完成", isPresented: Binding(
            get: { dubVM.errorState != nil },
            set: { if !$0 { dubVM.errorState = nil } })) {
            if dubVM.errorState?.kind == .missingCredential {
                Button("去设置配置") {
                    NotificationCenter.default.post(name: .mixCutShowSettings, object: nil)
                }
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(dubVM.errorState?.message ?? "")
        }
    }

    /// 方案是否有配音作业在跑（VM 投影；视图不直接读关系链）。
    private var scriptBusy: Bool {
        dubVM.isScriptSchemeBusy(scheme)
    }

    private func runGenerateAll() async {
        scriptDubRunning = true
        _ = await dubVM.generateScriptDubs(for: scheme, project: drawerProject, context: modelContext)
        scriptDubRunning = false
        try? modelContext.save()
    }

    private func stopScriptDubs() {
        dubVM.cancelScriptSchemeJobs(scheme)
    }

    // MARK: - 辅助

    private func infoSection(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(DesignTokens.Spacing.normal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(DesignTokens.Palette.Alpha.medium))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var usedTypes: [SemanticType] {
        let types = scheme.orderedSegments.flatMap { $0.segment?.semanticTypes ?? [] }
        return Array(Set(types)).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Storyboard 卡片

struct StoryboardCard: View {
    let schemeSeg: SchemeSegment
    @Bindable var segmentLibraryVM: SegmentLibraryViewModel
    let canDelete: Bool
    /// 脚本成片 dubOnly：卡片底部显示「生成新配音」行；普通方案不显示。
    var isDubOnlyScript: Bool = false
    /// 所属项目（供项目级音色覆盖；nil=只看全局默认）。
    var project: Project?
    /// 卡片不持有方案对象；配音生成/重生成由父视图经闭包执行（force=true=强制重合成）。
    var dubVM: DubbingViewModel?
    var onGenerateScriptDub: ((Bool) -> Void)?
    let onDelete: () -> Void
    let onReplace: () -> Void
    @State private var isHovering = false
    /// M1b：dubOnly 段卡的段级音色选择器。
    @State private var showSlotVoicePicker = false
    @Environment(\.modelContext) private var modelContext

    private let cardWidth: CGFloat = 150

    /// 该槽当前选定的配音变体（仅在有效变体中查找；未选/选不到 → nil = 原声默认）

    private var chosenDub: SegmentDub? {
        guard let id = schemeSeg.selectedSegmentDubId else { return nil }
        return schemeSeg.segment?.effectiveDubVariants.first { $0.id == id }
    }
    /// 改写版字母：0→A、1→B…
    private func variantLetter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    // MARK: 脚本成片单卡配音行（态全部取自 VM 投影，视图不读关系链）

    @ViewBuilder
    private func scriptDubRow(for segment: Segment) -> some View {
        let st = dubVM?.scriptSlotState(schemeSeg, project: project) ?? .missing
        VStack(alignment: .leading, spacing: 5) {
            switch st {
            case .ready:
                HStack(spacing: 6) {
                    Label("已生成", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.green)
                    Spacer()
                    if let dub = chosenDub {
                        Button { dubVM?.playDub(dub) } label: {
                            Image(systemName: "play.circle.fill")
                        }.buttonStyle(.borderless).controlSize(.small)
                        Button {
                            onGenerateScriptDub?(true)
                        } label: {
                            Image(systemName: "arrow.clockwise.circle")
                        }.buttonStyle(.borderless).controlSize(.small).help("重新生成本段配音（按次计费）")
                    }
                }
            case .staleVoice:
                // M1b：已有旧音色音频，但本段已改用其它音色——旧音频保留可听，明示需点生成才换声，不自动计费。
                HStack(spacing: 6) {
                    Label("音色已改，点生成生效", systemImage: "speaker.wave.2.bubble")
                        .font(.system(size: 9.5)).foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    if let dub = chosenDub {
                        Button { dubVM?.playDub(dub) } label: {
                            Image(systemName: "play.circle.fill")
                        }.buttonStyle(.borderless).controlSize(.small)
                        .help("试听当前音频（旧音色）")
                    }
                }
                Button {
                    onGenerateScriptDub?(true)
                } label: {
                    Label("按新音色生成", systemImage: "waveform")
                        .font(.system(size: 10.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("按本段选定的音色重新合成（按次计费）")
            case .busy:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("合成中…").font(.system(size: 10)).foregroundStyle(.blue)
                }
            case .pending, .missing:
                Button {
                    onGenerateScriptDub?(false)
                } label: {
                    Label("生成配音", systemImage: "waveform")
                        .font(.system(size: 10.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("用本段选定音色合成新配音（不克隆、不改文案）")
            }
        }
        .padding(.top, 4)
    }

    /// dubOnly 段卡左下角的音色 chip（替代普通方案的「原声/改写」角标——dubOnly 无原声回退）。
    /// 点击弹中立 VoicePickerSheet 设段级覆盖；当前音色名经 VM 投影，零视图跨边读。
    @ViewBuilder
    private func scriptVoiceChip(for segment: Segment) -> some View {
        let choice = dubVM?.resolvedScriptChoice(for: schemeSeg, project: project)
        Button {
            showSlotVoicePicker = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                Text(choice.map { VoiceCatalog.displayName(id: $0.voiceID) } ?? "未配置音色")
                    .font(.system(size: 10))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help("本段配音音色（点击改用其它音色；只影响新生成，不改动已有音频）")
        .accessibilityLabel("本段配音音色")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            if let segment = schemeSeg.segment {
                // 视频播放器 + 序号叠加 + 配音角标叠加 + hover 操作按钮
                // 用 .overlay 而非 ZStack，避免 ZStack propose 不传递 height 导致 SegmentInlinePlayer 塌缩
                // 视频与下方文字统一内边距（由卡片外层 .padding(6) 提供），避免满宽视频与内缩文字「错位白边」
                SegmentInlinePlayer(
                    segment: segment,
                    viewModel: segmentLibraryVM,
                    dubAudioPath: segment.isVoiceLocked ? nil : chosenDub?.audioFilePath
                )
                    .frame(width: cardWidth - 12, height: (cardWidth - 12) * 16.0 / 9.0)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("#\(schemeSeg.position)")
                            .font(DesignTokens.Typography.microMetric)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(4)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isHovering {
                            HStack(spacing: DesignTokens.Spacing.tight) {
                                cardActionButton(icon: "arrow.triangle.2.circlepath",
                                                 help: "替换",
                                                 action: onReplace)
                                cardActionButton(icon: "trash.fill",
                                                 help: canDelete ? "删除" : "方案至少保留 1 个分镜",
                                                 action: canDelete ? onDelete : {},
                                                 disabled: !canDelete)
                            }
                            .padding(4)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        // 配音角标从正文搬进画面左下角：浅底压在明暗不可控的视频帧上会糊，故用与 #序号 同族的深底。
                        // M1b：dubOnly 无原声回退，挂段音色 chip（可改选）；普通方案保留原声/改写 Menu。
                        if isDubOnlyScript {
                            scriptVoiceChip(for: segment)
                                .padding(4)
                        } else {
                            dubBadge(for: segment)
                                .padding(4)
                        }
                    }

                VStack(alignment: .leading, spacing: 5) {
                    // 类型标签 —— 与素材库卡片/列表行同一条纪律：用 FlowLayout 换行，
                    // 不用裸 HStack（窄容器里 HStack 会把中文标签压成一字一行的竖排）
                    FlowLayout(spacing: 3) {
                        ForEach(segment.semanticTypes.prefix(2), id: \.self) { type in
                            SemanticTypeTag(type: type)
                        }
                        if segment.semanticTypes.count > 2 {
                            Text("+\(segment.semanticTypes.count - 2)")
                                .font(DesignTokens.Typography.micro)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 台词（hover 显示完整）
                    Text(segment.text)
                        .font(DesignTokens.Typography.microRegular)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(2)
                        .help(segment.text)

                    // 紧凑时间调整
                    StoryboardTimeRow(segment: segment, viewModel: segmentLibraryVM)

                    // 脚本成片：逐段新配音行（普通方案不显示）。
                    if isDubOnlyScript {
                        scriptDubRow(for: segment)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Text("#\(schemeSeg.position)")
                        .font(DesignTokens.Typography.microMetric)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.bodyLarge)
                        .foregroundStyle(.orange)
                    Text("分镜数据缺失")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                }
                .frame(width: cardWidth - 12, height: 80)
            }
        }
        .padding(6)
        .frame(width: cardWidth)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering
                      ? Color(.controlBackgroundColor).opacity(0.9)
                      : Color(.controlBackgroundColor).opacity(0.5))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.secondary.opacity(isHovering ? 0.15 : 0.06), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("替换为...", action: onReplace)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        }
        .sheet(isPresented: $showSlotVoicePicker) {
            // 中立弹窗：只回调音色；写入经 DubbingVM 收口；「使用」不触发生成。
            VoicePickerSheet(
                title: "本段配音音色",
                contextLine: "仅作用于这一段（第 \(schemeSeg.position) 段）；清除后跟随项目/全局默认",
                current: dubVM?.resolvedScriptChoice(for: schemeSeg, project: project),
                allowsClear: true,
                clearLabel: "跟随项目/全局默认",
                onPick: { choice in
                    dubVM?.setScriptSlotVoiceOverride(
                        raw: choice.map { VoiceChoiceCoder.encode($0) },
                        schemeSeg: schemeSeg,
                        context: modelContext)
                    showSlotVoicePicker = false
                },
                onClose: { showSlotVoicePicker = false })
        }
    }

    @ViewBuilder
    private func dubBadge(for segment: Segment) -> some View {
        if segment.isVoiceLocked {
            // 锁定分镜：只播原声，不可切换
            Label("原声（锁定）", systemImage: "lock.fill")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.55)))
        } else {
            // M1b：变体枚举走 VM 的 R3 纯值投影（当前音色 dub＞克隆＞先到），视图零关系裸读。
            let variants = dubVM?.effectiveSlotVariants(for: schemeSeg, project: project) ?? []
            if variants.isEmpty {
                // 尚无任何已生成的改写版 → 仅原声，无可选
                Label("原声", systemImage: "waveform")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            } else {
                // 非锁定：永远是下拉，默认「原声」，可切到任一已生成变体
                let chosen = chosenDub        // nil = 原声
                Menu {
                    Button {
                        schemeSeg.selectedSegmentDubId = nil
                        try? modelContext.save()
                    } label: {
                        Text("原声" + (chosen == nil ? "  ✓" : ""))
                    }
                    Divider()
                    ForEach(variants) { v in
                        Button {
                            schemeSeg.selectedSegmentDubId = v.dubID
                            try? modelContext.save()
                        } label: {
                            Text("改写\(variantLetter(v.variantIndex))" + (v.dubID == chosen?.id ? "  ✓" : ""))
                        }
                    }
                } label: {
                    Label(chosen == nil ? "原声" : "改写\(variantLetter(chosen!.textVariantIndex)) 配音",
                          systemImage: "waveform")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(chosen == nil ? Color.white : Color.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func cardActionButton(icon: String,
                                  help: String,
                                  action: @escaping () -> Void,
                                  disabled: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(disabled ? .gray.opacity(0.4) : .black.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - 分镜序列专用时间调整行

struct StoryboardTimeRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    private var fps: Double { segment.video?.fps ?? 30 }

    var body: some View {
        // 上下两行（始/止），每行「标签 + − + 时码(弹性) + +」，最小 ~101px，稳放进 138px 卡片，绝不溢出
        VStack(spacing: 3) {
            adjustRow(label: "始",
                      frame: segment.startFrame,
                      onMinus: { viewModel.adjustStartFrame(for: segment, by: -1) },
                      onPlus: { viewModel.adjustStartFrame(for: segment, by: 1) })
            adjustRow(label: "止",
                      frame: segment.endFrame,
                      onMinus: { viewModel.adjustEndFrame(for: segment, by: -1) },
                      onPlus: { viewModel.adjustEndFrame(for: segment, by: 1) })
        }
        .frame(maxWidth: .infinity)
    }

    private func adjustRow(label: String,
                           frame: Int,
                           onMinus: @escaping () -> Void,
                           onPlus: @escaping () -> Void) -> some View {
        // VoiceOver 用「起始/结束」而不是单字「始/止」，读起来更清楚
        let spoken = label == "始" ? "起始时间" : "结束时间"
        return HStack(spacing: 3) {
            Text(label)
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.tertiary)
            miniAdjustButton(icon: "minus", accessibilityLabel: "\(spoken)提前", action: onMinus)
            Text(FrameTime.timecode(frame: frame, fps: fps))
                .font(DesignTokens.Typography.microMonoStrong)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            miniAdjustButton(icon: "plus", accessibilityLabel: "\(spoken)延后", action: onPlus)
        }
    }

    private func miniAdjustButton(icon: String,
                                  accessibilityLabel: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - 信息芯片

struct InfoChip: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            Image(systemName: icon)
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(DesignTokens.Typography.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
        .clipShape(Capsule())
    }
}
