import SwiftUI

/// 产品脚本成片向导（单模态）。结构：setup → structure → matching → review。
/// 全程绑定打开时的项目；模态期间项目切换由宿主 `.task(id:)` 关闭窗口兜底。
struct ScriptWizardView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var vm: ScriptWizardViewModel

    init(project: Project) {
        self.project = project
        _vm = State(initialValue: ScriptWizardViewModel(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // 统一弹窗尺寸契约：大屏 ideal 860×680 观感不变；小窗收到 640×480 不越界（图二修复）。
        .sheetContainerFrame(minWidth: 640, idealWidth: 860, maxWidth: .infinity,
                             minHeight: 480, idealHeight: 680)
        .task(id: project.id) {
            vm.setContext(modelContext)
        }
        // 分镜网格选择器（向导 sheet 之上的二级 sheet）：由 vm.pickerSlotID 驱动。
        .sheet(isPresented: Binding(
            get: { vm.pickerSlotID != nil },
            set: { presented in if !presented { vm.closePicker() } }
        )) {
            if let row = vm.pickerRow {
                SegmentGridPickerSheet(
                    title: "为第 \(row.order) 段「\(row.tag)」选择分镜",
                    totalCount: vm.pickerSegments.count,
                    tagMatchedCount: vm.pickerTagMatchedCount,
                    occupiedCount: vm.pickerOccupancy().count,
                    videoGroups: vm.pickerVideoGroups(),
                    filter: Binding(
                        get: { vm.pickerFilter },
                        set: { vm.pickerFilter = $0 }),
                    segments: vm.filteredPickerSegments(),
                    occupancy: Dictionary(uniqueKeysWithValues: vm.pickerOccupancy().map { ($0.segmentID, $0) }),
                    onClose: { vm.closePicker() },
                    onPick: { vm.pickerSelect($0) },
                    onMove: { vm.pickerMoveSegment($0) })
            }
        }
        .onChange(of: project.id) { _, _ in
            // 模态期间切换项目：直接关闭，禁止跨项目数据污染。
            dismiss()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("产品脚本成片")
                    .font(DesignTokens.Typography.sectionTitle)
                Text(subtitle)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepBadges
            if vm.stage != .finished {
                Button("取消") { vm.cancel(); dismiss() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepBadges: some View {
        HStack(spacing: 6) {
            ForEach(stepLabels, id: \.0) { label, stage in
                let active = vm.stage == stage
                Text(label)
                    .font(DesignTokens.Typography.micro)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(active ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                                in: Capsule())
                    .foregroundStyle(active ? Color.accentColor : .secondary)
            }
        }
    }

    private var stepLabels: [(String, ScriptWizardViewModel.Stage)] {
        [("1 方向", .setup), ("2 结构", .structure), ("3 匹配", .matching), ("4 确认", .review)]
    }

    private var subtitle: String {
        guard let productName = vm.boundProductName else { return project.name }
        return "\(project.name) · \(productName)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch vm.stage {
        case .setup:     setupContent
        case .structure: structureContent
        case .matching:  matchingContent
        case .review:    reviewContent
        case .finished:  finishedContent
        }
    }

    // MARK: Setup

    private var setupContent: some View {
        // 内容可滚 + 固定底栏：小窗收缩时「下一步」恒定贴底可见，不被 Spacer 顶出可视区（图二修复）。
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("选择创作方向")
                        .font(DesignTokens.Typography.labelEmphasis)

                    HStack(spacing: 14) {
                        directionCard(
                            title: "正向：产品资料写脚本",
                            detail: "围绕产品知识库，AI 按分镜标签逐段撰写口播文案",
                            icon: "text.cursor",
                            selected: vm.direction == .forward) {
                                vm.direction = .forward
                            }
                        directionCard(
                            title: "逆向：粘贴文案匹配画面",
                            detail: "粘贴现成文案，自动切段打标签，再匹配对应分镜",
                            icon: "arrow.left.to.line",
                            selected: vm.direction == .reverse) {
                                vm.direction = .reverse
                            }
                    }

                    if vm.direction == .forward {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("结构来源")
                                .font(DesignTokens.Typography.labelEmphasis)
                            Picker("", selection: $vm.structureChoice) {
                                Text("带货模板（可编辑）").tag(ScriptWizardViewModel.StructureChoice.template)
                                Text("AI 自动确定结构").tag(ScriptWizardViewModel.StructureChoice.aiAuto)
                            }
                            .pickerStyle(.radioGroup)
                        }
                    }

                    if let error = vm.errorMessage {
                        Text(error).font(DesignTokens.Typography.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("下一步") { vm.enterStructure() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func directionCard(title: String, detail: String, icon: String,
                               selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(DesignTokens.Typography.cardTitle)
                    Text(detail).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.05) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : DesignTokens.Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Structure

    private var structureContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if vm.direction == .reverse {
                        reverseInput
                    } else {
                        forwardStructureHeader
                    }
                    if !vm.drafts.isEmpty {
                        draftTable
                    }
                    if let error = vm.errorMessage {
                        Text(error).font(DesignTokens.Typography.caption).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            Divider()
            wizardBar(primaryTitle: "开始匹配", primaryEnabled: !vm.drafts.isEmpty) {
                Task { await vm.startMatching() }
            } leading: {
                Button("上一步") { vm.stage = .setup }
            }
        }
    }

    private var reverseInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("粘贴文案（原文将逐字保留，只做切段和标签标注，不改写）")
                .font(DesignTokens.Typography.labelEmphasis)
            TextEditor(text: $vm.pastedText)
                .font(DesignTokens.Typography.body)
                .frame(height: 180)
                .border(DesignTokens.Palette.border)
            HStack {
                Button("开始结构化") { Task { await vm.runReverseStructure() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.pastedText.trimmingCharacters(in: .whitespaces).isEmpty)
                if vm.isBusy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var forwardStructureHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("脚本结构")
                    .font(DesignTokens.Typography.labelEmphasis)
                Text("可调整每段标签与时长，合计 \(String(format: "%.1f", vm.draftsTotalDuration)) 秒")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if vm.structureChoice == .aiAuto {
                Button("重新生成结构") { Task { await vm.generateAIStructure() } }
            }
            Menu("添加段落") {
                ForEach(SemanticType.allCases, id: \.self) { type in
                    Button(type.rawValue) { vm.addDraft(tag: type.rawValue) }
                }
            }
        }
    }

    private var draftTable: some View {
        VStack(spacing: 6) {
            ForEach(vm.drafts) { draft in
                draftRow(draft)
            }
        }
    }

    private func draftRow(_ draft: ScriptStructureDraft) -> some View {
        HStack(spacing: 10) {
            Text("\(draft.order)").font(DesignTokens.Typography.micro)
                .frame(width: 24)
            Menu(draft.tag) {
                ForEach(SemanticType.allCases, id: \.self) { type in
                    Button(type.rawValue) {
                        if let index = vm.drafts.firstIndex(where: { $0.id == draft.id }) {
                            vm.drafts[index].tag = type.rawValue
                        }
                    }
                }
            }
            .frame(width: 130, alignment: .leading)

            if let index = vm.drafts.firstIndex(where: { $0.id == draft.id }) {
                Stepper("\(String(format: "%.1f", draft.duration)) 秒",
                        value: Binding(
                            get: { vm.drafts[index].duration },
                            set: { vm.drafts[index].duration = max(0.5, $0) }),
                        in: 0.5...15, step: 0.5)
                .font(DesignTokens.Typography.micro)
                .frame(width: 150)
            }

            if vm.direction == .reverse, !draft.text.isEmpty {
                Text(draft.text)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(draft.text)   // 表格内单行截断；悬停看原文全文（原文逐字保留）
            }
            Spacer()

            Button { vm.moveDraft(draft, offset: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("上移")
            Button { vm.moveDraft(draft, offset: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("下移")
            Button { vm.removeDraft(draft) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("删除段落")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Matching

    private var matchingContent: some View {
        VStack(spacing: 0) {
            matchingStatusBanner
            if let info = vm.infoMessage, !vm.isBusy, vm.errorMessage == nil {
                banner(info, color: .orange)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(vm.matchRows) { row in
                        MatchRowView(row: row, vm: vm)
                    }
                }
                .padding(20)
            }
            Divider()
            wizardBar(primaryTitle: vm.direction == .forward ? "开始写作" : "下一步",
                      primaryEnabled: vm.matchingReady) {
                Task { await vm.proceedAfterMatching() }
            } leading: {
                Button("返回改结构") { vm.backToStructure() }
            }
        }
    }

    /// 匹配页状态横幅：忙碌（进度条 + 阶段说明）/ 失败（红色原因 + 知道了）互斥；
    /// 固定高度不挤压列表。失败后场景选择仍在，可直接再点「开始写作」重试。
    private var matchingStatusBanner: some View {
        HStack(spacing: 10) {
            if vm.isBusy {
                if case .retrieving(let slot, let total) = vm.flowPhase {
                    ProgressView(value: Double(slot), total: Double(total))
                        .frame(width: 180)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(vm.flowPhase.progressLabel)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let error = vm.errorMessage {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(DesignTokens.Typography.caption)
                Spacer()
                Button("知道了") { vm.dismissError() }
                    .font(DesignTokens.Typography.micro)
            }
        }
        .frame(height: 36)
        .padding(.horizontal, 20)
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(DesignTokens.Typography.caption)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(color.opacity(0.08))
    }

    // MARK: Review

    private var reviewContent: some View {
        VStack(spacing: 0) {
            if let info = vm.infoMessage, !vm.isBusy && vm.errorMessage == nil {
                banner(info, color: .orange)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(vm.matchRows) { row in
                        ReviewSceneCard(row: row, vm: vm)
                    }
                }
                .padding(20)
            }
            Divider()
            VStack(spacing: 8) {
                if !vm.materializeReady, !vm.materializeWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.materializeWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.circle")
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                wizardBar(primaryTitle: "物化为可编辑方案",
                          primaryEnabled: vm.materializeReady) {
                    // 投递顺序写死：先切到混剪方案页，再登记焦点，最后关闭向导。
                    // SchemeListView appear/loadSchemes 后在 loadSchemes 末尾消费焦点。
                    if let scheme = vm.materialize() {
                        NotificationCenter.default.post(name: .mixCutNavigate,
                                                         object: NavigationItem.schemes)
                        NotificationCenter.default.post(name: .mixCutFocusScheme,
                                                         object: scheme.id)
                        dismiss()
                    }
                } leading: {
                    HStack(spacing: 8) {
                        Button("返回匹配") { vm.stage = .matching }
                        scriptExportMenu
                    }
                }
            }
        }
    }

    /// 确认页脚本导出：.txt / .md（NSSavePanel 选位置；内容由 Core ScriptTextExporter 渲染）。
    private var scriptExportMenu: some View {
        Menu {
            ForEach(ScriptTextExportFormat.allCases, id: \.self) { format in
                Button(format.displayLabel) { exportScriptAs(format) }
            }
        } label: {
            Label("导出脚本", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("把当前脚本（含标签与引用出处）导出为文本文件")
    }

    private func exportScriptAs(_ format: ScriptTextExportFormat) {
        guard let draft = vm.exportDraft() else { return }
        ScriptExportAssembly.saveViaPanel(draft, format: format)
    }

    private var finishedContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("脚本已物化为方案").font(DesignTokens.Typography.sectionTitle)
            Text("可在「方案」页查看与生成配音、导出成片")
                .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Shared bar

    private func wizardBar(primaryTitle: String, primaryEnabled: Bool,
                           primary: @escaping () -> Void,
                           leading: () -> some View) -> some View {
        HStack {
            leading()
            Spacer()
            if vm.isBusy {
                ProgressView().controlSize(.small)
                Text(vm.flowPhase.progressLabel)
                    .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            }
            Button(primaryTitle, action: primary)
                .buttonStyle(.borderedProminent)
                .disabled(!primaryEnabled || vm.isBusy)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

// MARK: - Match Row

private struct MatchRowView: View {
    let row: ScriptWizardViewModel.MatchRow
    let vm: ScriptWizardViewModel

    private var isConflict: Bool {
        guard let id = vm.matchedSegmentID(for: row) else { return false }
        return vm.conflictSegmentIDs.contains(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(row.order)").font(DesignTokens.Typography.micro).frame(width: 24)
                Text(row.tag).font(DesignTokens.Typography.label)
                Text("目标 \(String(format: "%.1f", row.targetDuration))s")
                    .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                Spacer()
                statusView
            }

            HStack(spacing: 9) {
                if let segID = vm.matchedSegmentID(for: row) {
                    // 已锁定结果卡：清除 + 视频名/seg/时长（只读结果，挑选在弹窗内）。
                    Button {
                        vm.clearSelection(for: row)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(isConflict ? Color.orange : Color.red)
                    }
                    .buttonStyle(.plain)
                    .help(isConflict ? "该分镜与其他段落冲突，点击清除" : "清除选择")

                    LockedSegmentCard(segmentID: segID, vm: vm, conflicted: isConflict)
                    Spacer()
                    Button("更换分镜") { vm.openPicker(for: row) }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .font(DesignTokens.Typography.micro)
                } else {
                    Text("尚未选择分镜").font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("选择分镜") { vm.openPicker(for: row) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .font(DesignTokens.Typography.micro)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusView: some View {
        switch row.status {
        case .matched:
            Label(isConflict ? "冲突" : "已锁定",
                  systemImage: isConflict ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(isConflict ? Color.orange : Color.green)
        case .multiCandidate:
            Label("待确认", systemImage: "questionmark.circle.fill")
                .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
        case .unmatched:
            Label("未匹配", systemImage: "xmark.circle.fill")
                .font(DesignTokens.Typography.micro).foregroundStyle(.orange)
        }
    }
}

/// 已锁定分镜结果卡（匹配行/确认页共用）：缩略图 + 视频名 + seg·时长。
/// 视频名/编号全部经 VM 解边访问器，视图零跨边读取。
private struct LockedSegmentCard: View {
    let segmentID: UUID
    let vm: ScriptWizardViewModel
    var conflicted: Bool = false
    /// 缩略图路径由 VM 投影（选择器同款 GridPickerSegment）取，避免视图持有模型。
    private var thumbnailPath: String? {
        vm.pickerSegments.first { $0.id == segmentID }?.thumbnailPath
    }
    private var indexLabel: String {
        vm.pickerSegments.first { $0.id == segmentID }?.segmentIndex ?? "—"
    }
    private var durationText: String {
        vm.pickerSegments.first { $0.id == segmentID }
            .map { String(format: "%.1fs", $0.duration) } ?? ""
    }

    var body: some View {
        HStack(spacing: 9) {
            AsyncCachedImage(
                path: thumbnailPath,
                placeholder: {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                        .frame(width: 60, height: 38)
                        .overlay(Image(systemName: "film").font(.system(size: 13)).foregroundStyle(.tertiary))
                },
                imageContent: { img in
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 60, height: 38).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                })
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.videoName(forSegmentID: segmentID))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).frame(maxWidth: 200, alignment: .leading)
                HStack(spacing: 5) {
                    Text(indexLabel).font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(durationText).font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.trailing, 10)
        .background((conflicted ? Color.orange : Color.accentColor).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            (conflicted ? Color.orange : Color.accentColor).opacity(conflicted ? 0.5 : 0.9), lineWidth: 1.5))
        .help(vm.pickerSegments.first { $0.id == segmentID }?.text ?? "")
    }
}

// MARK: - Review Scene Card

private struct ReviewSceneCard: View {
    let row: ScriptWizardViewModel.MatchRow
    let vm: ScriptWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("第 \(row.order) 段").font(DesignTokens.Typography.labelEmphasis)
                Text(row.tag).font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                if let segID = vm.matchedSegmentID(for: row) {
                    Text("匹配 \(vm.videoName(forSegmentID: segID)) · \(vm.matchedSegmentIndexLabel(for: row))")
                        .font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                validationBadges
                Button("重新校验") { vm.revalidate(sceneID: row.id) }
                    .font(DesignTokens.Typography.micro)
            }

            TextEditor(text: Binding(
                get: { row.scene.text },
                set: { row.scene.setText($0) }))
                .font(DesignTokens.Typography.body)
                .frame(height: 86)
                .border(DesignTokens.Palette.border)
                .onChange(of: row.scene.text) { _, _ in
                    // W4 编辑即增量重校验：物化按钮状态实时反映（不手动点按钮也会更新）。
                    vm.noteTextEdited(sceneID: row.id)
                }

            if !row.scene.citationChunkIDs.isEmpty {
                citations
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var validationBadges: some View {
        if let mark = vm.reviewMarks[row.id] {
            if mark.complianceIssues.isEmpty {
                Label("合规", systemImage: "checkmark.seal.fill")
                    .font(DesignTokens.Typography.micro).foregroundStyle(.green)
            } else {
                Label("合规问题", systemImage: "xmark.seal.fill")
                    .font(DesignTokens.Typography.micro).foregroundStyle(.orange)
            }
            if mark.groundingRequired {
                Label(mark.grounding.isGrounded ? "事实有依据" : "有无依据事实",
                      systemImage: mark.grounding.isGrounded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(mark.grounding.isGrounded ? .green : .orange)
            } else {
                // 逆向：文案为用户粘贴原文，事实来源是用户本人，不做资料落地校验。
                Label("用户原文", systemImage: "person.text.rectangle")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var citations: some View {
        HStack(spacing: 6) {
            Text("引用：").font(DesignTokens.Typography.micro).foregroundStyle(.secondary)
            ForEach(row.scene.citationChunkIDs, id: \.self) { chunkID in
                CitationPopoverButton(
                    title: vm.citationTitle(for: chunkID),
                    content: vm.citationContent(for: chunkID))
            }
        }
    }
}

/// 引用片段按钮：点击弹出原文 popover。只接收纯值（标题/正文），
/// 组件不持有模型、不跨边；呈现状态内聚于此（SDK 已移除无 isPresented 的旧 popover 重载）。
private struct CitationPopoverButton: View {
    let title: String
    let content: String
    @State private var showPopover = false

    var body: some View {
        Button(title) {
            showPopover = true
        }
        .font(DesignTokens.Typography.micro)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $showPopover) {
            ScrollView {
                Text(content)
                    .font(DesignTokens.Typography.caption)
                    .frame(width: 380, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
        .help("点击查看引用原文")
    }
}
