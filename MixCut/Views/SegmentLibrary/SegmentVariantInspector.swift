import SwiftUI

/// 右侧变体池矩阵：行 = 改写版（0..K-1），列 = 选定音色，格 = 按需配音（生成 / 试听 / 重生成）。
struct SegmentVariantInspector<PropertiesContent: View>: View {
    let segment: Segment
    @Bindable var dubVM: DubbingViewModel
    /// 当前是否持久选中（驱动关闭按钮显隐；Inspector 不持有素材库 VM）
    let isPinned: Bool
    /// 头部关闭回调
    let onClose: () -> Void
    /// 停止改写请求上抛到页面顶层（确认弹窗统一在 SegmentLibraryView）
    let onStopRequest: (UUID) -> Void
    /// 调用方注入的片段属性内容（Inspector 不反向认识 SegmentLibraryViewModel）
    @ViewBuilder let propertiesContent: PropertiesContent
    @Environment(\.modelContext) private var modelContext

    // 改写版台词行内编辑
    @State private var editingVariant: Int? = nil
    @State private var draftText = ""
    @State private var variantPendingDelete: Int? = nil
    @State private var captionEditDub: SegmentDub? = nil
    @FocusState private var editorFocused: Bool
    /// 视频尚未克隆时，单分镜改写的计费确认弹窗
    @State private var showCloneCostConfirm = false

    // 注：改写/配音任务句柄统一归 DubbingViewModel 的视频级注册表（DubbingJobRegistry）。
    // 切换分镜会以 .id(segment.id) 重建本子树，但作业生命周期独立于本视图，不再被连带取消；
    // 停止只走显式「停止」按钮、素材删除广播、换项目三个锚点。

    private func variantLetter(_ t: Int) -> String { String(Character(UnicodeScalar(65 + t)!)) }

    private var voices: [String] { segment.video?.selectedVoiceIds ?? [] }
    /// 实际已存在的改写版下标（升序），按它渲染变体卡片，数量随设置自适应。
    private var presentVariantIndices: [Int] {
        Array(Set(segment.segmentDubs.map { $0.textVariantIndex })).sorted()
    }
    private func voiceName(_ id: String) -> String {
        if id == segment.video?.clonedVoiceId { return "原声克隆" }
        return VoiceCatalog.displayName(id: id)
    }
    private func dub(textVariant t: Int, voiceId v: String) -> SegmentDub? {
        segment.segmentDubs.first { $0.textVariantIndex == t && $0.voiceId == v }
    }

    /// 用于**展示**某改写版的那条记录。
    ///
    /// ⚠️ 必须和导出走同一真源。原先卡片硬绑 `voices.first`（= 当前 clonedVoiceId），
    /// 而导出走的 `effectiveDubVariants` 并不按 voiceId 过滤。
    /// 于是换过一次 API Key 触发重克隆后：老变体的 voiceId 还是旧的 →
    /// 检查器里台词显示「（无文本）」、音色格显示「—」，看着像空的、也没法试听，
    /// **但导出时它照样会被用上** —— 所见与所得完全对不上。
    private func displayDub(_ t: Int) -> SegmentDub? {
        effectiveDub(t)
            ?? dub(textVariant: t, voiceId: voices.first ?? "")
            ?? segment.segmentDubs.first { $0.textVariantIndex == t }
    }
    /// 该改写版参与组合用的"有效变体"（已生成音频、去重后那条）
    private func effectiveDub(_ t: Int) -> SegmentDub? {
        segment.effectiveDubVariants.first { $0.textVariantIndex == t }
    }
    private func f(_ x: Double) -> String { String(format: "%.1f", x) }

    /// 提示基准 = 原分镜台词字数。比原台词多很多才算「偏多」（阈值：+20% 且至少 +5 字）。
    private var origCharCount: Int { segment.text.count }
    private func isTooMany(_ count: Int) -> Bool {
        origCharCount > 0 && count > origCharCount + max(5, Int(Double(origCharCount) * 0.2))
    }
    /// 比原台词少很多（阈值：少于原台词一半）→ 配音可能短于画面、末尾留白。
    private func isTooFew(_ count: Int) -> Bool {
        origCharCount > 0 && count < max(2, origCharCount / 2)
    }

    /// 过期原因（空数组 = 未过期）。界面上那句提示必须说得出是**哪一维**变了：
    /// "原台词变了"和"改写版变了"用户要做的动作不一样（重听 vs 重配）。
    private func staleReasons(_ dub: SegmentDub) -> [StalenessReason] {
        guard dub.audioFilePath != nil else { return [] }
        let snap = DubSnapshot(recordedStartFrame: dub.generatedForStartFrame,
                               recordedEndFrame: dub.generatedForEndFrame,
                               recordedTextHash: dub.generatedForTextHash,
                               recordedSourceTextHash: dub.generatedForSourceTextHash)
        // 与 MCP 侧同一个聚合入口：两处若各拼各的，第三处必漏（计划 §3.3③）
        if case .stale(let reasons) = DubStaleness.checkAll(snapshot: snap,
                                                            currentStartFrame: segment.startFrame,
                                                            currentEndFrame: segment.endFrame,
                                                            currentRewrittenTextHash: DubStaleness.textHash(of: dub.rewrittenText),
                                                            currentSourceTextHash: DubStaleness.textHash(of: segment.text)) {
            return reasons
        }
        return []
    }

    private func isStale(_ dub: SegmentDub) -> Bool {
        !staleReasons(dub).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // 统一 ScrollView：变体内容 + 片段属性同栏滚动
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    variantContent
                    Divider().padding(.vertical, 2)
                    propertiesContent
                }
                .padding(14)
            }
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        // 任务不再挂在本子树：切分镜/关检查器不取消在跑的改写（视频级作业，进度见浮层）。
        .sheet(item: $captionEditDub) { d in
            CaptionTimingEditorSheet(dub: d, dubVM: dubVM)
        }
        .confirmationDialog("删除改写版？",
                            isPresented: Binding(get: { variantPendingDelete != nil },
                                                 set: { if !$0 { variantPendingDelete = nil } }),
                            presenting: variantPendingDelete) { t in
            Button("删除「改写版 \(variantLetter(t))」", role: .destructive) {
                dubVM.deleteVariant(segment, textVariantIndex: t, context: modelContext)
                if editingVariant == t { editingVariant = nil }
                variantPendingDelete = nil
            }
            Button("取消", role: .cancel) { variantPendingDelete = nil }
        } message: { t in
            Text("将删除「改写版 \(variantLetter(t))」的台词与配音，不可恢复。")
        }
        // 单分镜改写、视频尚未克隆 → 先确认计费（demucs 分离 + 音色注册）
        .confirmationDialog("该视频还没克隆原声",
                            isPresented: $showCloneCostConfirm) {
            Button("开始克隆并改写（按次计费）") {
                proceedSingleRewrite()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("改写本分镜会先自动分离人声并注册克隆音色（按次计费，耗时较长），再改写台词并生成配音。克隆音色之后全视频复用。")
        }
    }

    // MARK: - 单分镜改写（确认策略按「视频是否已克隆」，空状态与 matrix 共用）

    /// 入口：未克隆先弹计费确认；已克隆（小额）直接执行。
    private func runSingleRewrite() {
        if (segment.video?.clonedVoiceId ?? "").isEmpty {
            showCloneCostConfirm = true
        } else {
            proceedSingleRewrite()
        }
    }

    /// 实际执行：single 作用域走统一管线（句柄由 VM 注册表持有，切换分镜不取消）。
    private func proceedSingleRewrite() {
        guard let video = segment.video else { return }
        dubVM.startRewriteTask(
            video: video,
            targets: [segment],
            presentation: DubScopePresentationMapper.presentation(for: .single),
            context: modelContext)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("配音变体池").font(.headline)
            }
            Text("分镜 #\(segment.segmentIndex) · 时长 \(String(format: "%.1f", segment.duration))s")
                .font(.caption).foregroundStyle(.secondary)
            if !segment.isVoiceLocked {
                HStack(spacing: DesignTokens.Spacing.compact) {
                    Toggle(isOn: Binding(
                        get: { segment.originalParticipatesInCombination },
                        set: { segment.originalParticipatesInCombination = $0; try? modelContext.save() }
                    )) { Text("原版参与组合").font(.caption2) }
                    .toggleStyle(.checkbox)
                    .help("勾选后原版参与导出排列组合；与各改写版的「参与组合」共同决定组合数")
                    Spacer()
                    Text("参与 \(segment.combinationSlotCount) 档")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // 关闭按钮浮在头部右上角；仅持久（pinned）态可见可用，hover 临时态移走即自动收起
        .overlay(alignment: .topTrailing) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(10)
            .opacity(isPinned ? 1 : 0)
            .allowsHitTesting(isPinned)
            .accessibilityLabel("收起配音变体池")
            .help("收起配音变体池")
        }
    }

    // MARK: - 变体内容（统一 ScrollView 内部；三分支）

    @ViewBuilder
    private var variantContent: some View {
        if segment.isVoiceLocked {
            lockBlock
        } else if segment.segmentDubs.isEmpty {
            emptyVariantsBlock
        } else {
            variantsBlock
        }
    }

    /// 锁定态：固定高度区块（ScrollView 内不用 Spacer 撑高）
    private var lockBlock: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 26)).foregroundStyle(.orange)
            Text("保留原声\n（明星出镜锁定，不参与配音）")
                .font(.callout).foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        .padding(DesignTokens.Padding.page)
    }

    /// 空变体态：固定高度区块，内容居中
    private var emptyVariantsBlock: some View {
        VStack(spacing: 13) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("该分镜还没有配音变体")
                .font(.callout).foregroundStyle(.secondary)

            // 忙碌门与 rewriteBar 同源：作业进行中（含 MCP 等其他入口发起）
            // 不再显示可点 CTA，避免重复点击被静默拦截时像「按钮失灵」。
            if dubVM.isBusy(videoID: segment.video?.id), let vid = segment.video?.id {
                DubbingRegularProgress(videoID: vid, vm: dubVM) { onStopRequest(vid) }
            } else {
                Button {
                    runSingleRewrite()
                } label: {
                    Label("一键改写本分镜", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("自动克隆原声 → 改写本分镜台词 → 生成配音；视频未克隆时会先请你确认计费")

                addManualVariantButton
            }

            Text("要一次处理整个视频，用上方「一键改写台词」（视频标题行右侧）")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .padding(.horizontal, 4)
    }

    /// 已存在变体：rewriteBar + 各版卡片 + 手动新增（原 matrix 内容，去掉内层 ScrollView）
    private var variantsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            rewriteBar
            ForEach(presentVariantIndices, id: \.self) { t in
                versionCard(t)
            }
            addManualVariantButton
        }
    }

    /// 手动新增一版：自己写台词 → 自动用克隆原声配音。
    @ViewBuilder
    private var addManualVariantButton: some View {
        if !dubVM.isBusy(videoID: segment.video?.id) {
            Button {
                dubVM.startManualVariantTask(for: segment, context: modelContext) { newIndex in
                    draftText = ""
                    editingVariant = newIndex
                    editorFocused = true
                }
            } label: {
                Label("手动添加一版（自己写台词）", systemImage: "plus.circle")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("新增一个空白改写版，自己填台词，保存后自动用克隆原声生成配音")
        }
    }

    /// 单分镜「重新改写」入口（改完原台词后用）。
    private var rewriteBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dubVM.isBusy(videoID: segment.video?.id) {
                if let vid = segment.video?.id {
                    DubbingRegularProgress(videoID: vid, vm: dubVM) { onStopRequest(vid) }
                }
            } else {
                Button {
                    // 改走统一入口（single）；未克隆时由 runSingleRewrite 先确认计费
                    runSingleRewrite()
                } label: {
                    Label("重新改写本分镜", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("基于当前原台词，重出 \(dubVM.variantCount) 套改写版并重新生成配音")
            }
            Text("改了原台词后，点此用新原文重写本分镜")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 单个改写版卡片

    private func versionCard(_ t: Int) -> some View {
        let text = displayDub(t)?.rewrittenText ?? ""
        let editing = editingVariant == t
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("改写版 \(Character(UnicodeScalar(65 + t)!))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)          // 胶囊里的短标签，压成竖排会整个坏掉
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                charHint(count: editing ? draftText.count : text.count)
                // 参与导出组合勾选（仅该版已生成音频时显示；锁定原声时禁用）
                if let ed = effectiveDub(t) {
                    Toggle(isOn: Binding(
                        get: { ed.participatesInCombination },
                        set: { ed.participatesInCombination = $0; try? modelContext.save() }
                    )) {
                        Text("参与组合").font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(segment.isVoiceLocked)
                    .help(segment.isVoiceLocked ? "已锁原声，不参与组合" : "勾选后此改写版参与导出排列组合")

                    if ed.audioFilePath != nil {
                        Button { captionEditDub = ed } label: {
                            Image(systemName: "captions.bubble")
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .accessibilityLabel("编辑字幕时间")
                        .help("逐句字幕时间：让烧录字幕按配音每句实际说到的时间逐句出现")
                    }
                }
                Spacer()
                if editing {
                    Button { editingVariant = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("取消编辑").help("取消")
                    Button { saveEditedVariant(t) } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }.buttonStyle(.borderless).foregroundStyle(.green).accessibilityLabel("保存台词").help("保存并重新生成配音（⌘↩）")
                } else if !dubVM.isBusy(videoID: segment.video?.id) {
                    Button {
                        draftText = text
                        editingVariant = t
                        editorFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("编辑台词").help("编辑这版台词")
                    Button {
                        variantPendingDelete = t
                    } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).foregroundStyle(.red).accessibilityLabel("删除该版本").help("删除这版（台词+配音）")
                }
            }

            if editing {
                TextEditor(text: $draftText)
                    .font(.callout)
                    .frame(height: 80)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { saveEditedVariant(t); return .handled }
                        return .ignored
                    }
            } else {
                Text(text.isEmpty ? "（无文本）" : text)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            variantAudioWarning(t)

            // 音色格：每列一个音色
            HStack(spacing: DesignTokens.Spacing.compact) {
                ForEach(voices, id: \.self) { v in
                    cell(textVariant: t, voiceId: v)
                }
            }
        }
        .padding(DesignTokens.Spacing.normal)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator, lineWidth: 0.5))
    }

    /// 字数提示（基准=原分镜台词）：仅在比原台词「多很多」红字、「少很多」橙字；其余灰字不打扰。
    /// ⚠️ 短计数加 lineLimit(1)（同一行里右边那句长文案是贪心的，会把 "N字" 挤成竖排单字）；
    /// 那两句长警示**故意不加** —— 它们是解释性正文，截断等于把"为什么要精简"整句吞掉。
    @ViewBuilder
    private func charHint(count: Int) -> some View {
        let many = isTooMany(count)
        let few = isTooFew(count)
        HStack(spacing: 3) {
            Text("\(count)字").font(.caption2.monospacedDigit())
                .lineLimit(1)
                .foregroundStyle(many ? AnyShapeStyle(Color.red)
                                 : few ? AnyShapeStyle(Color.orange)
                                 : AnyShapeStyle(.tertiary))
            if origCharCount > 0 {
                if many {
                    Text("· 比原台词(\(origCharCount)字)多很多，配音会明显加速，建议精简")
                        .font(.caption2).foregroundStyle(.red)
                } else if few {
                    Text("· 比原台词(\(origCharCount)字)少很多，末尾会留白，建议加字")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("/ 原\(origCharCount)字").font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 生成后时长警告（只有两种）：① 字数比原片多很多→红字；② 配音确实短于画面（留白）→橙字。
    /// 台词多但仍被 atempo 加速塞进画面属正常，不报「超时」。
    @ViewBuilder
    private func variantAudioWarning(_ t: Int) -> some View {
        if let d = displayDub(t),
           d.audioFilePath != nil, d.audioDuration > 0 {
            let target = segment.duration
            let count = d.rewrittenText.count
            if isTooMany(count) {
                warnLabel("台词比原片(\(origCharCount)字)多 \(count - origCharCount) 字，配音已大幅加速，建议精简",
                          .red, "exclamationmark.triangle.fill")
            } else if target - d.audioDuration > 0.5 {
                warnLabel("配音比画面短 \(f(target - d.audioDuration))s，末尾留白，建议加字",
                          .orange, "exclamationmark.circle.fill")
            }
        }
    }

    private func warnLabel(_ text: String, _ color: Color, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveEditedVariant(_ t: Int) {
        let newText = draftText
        editingVariant = nil
        editorFocused = false
        Task { await dubVM.updateVariantText(segment: segment, textVariantIndex: t,
                                              newText: newText, context: modelContext) }
    }

    // MARK: - 单格（音色 × 改写版）

    @ViewBuilder
    private func cell(textVariant t: Int, voiceId v: String) -> some View {
        let d = dub(textVariant: t, voiceId: v)
        VStack(spacing: 5) {
            Text(voiceName(v))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let d, dubVM.busyDubIDs.contains(d.id) {
                ProgressView().controlSize(.small)
            } else if let d, d.audioFilePath != nil {
                generatedControls(d)
            } else if let d {
                Button {
                    dubVM.startDubAudioTask(for: d, context: modelContext)
                } label: {
                    Label("生成", systemImage: "waveform").font(.caption2)
                }
                .buttonStyle(.bordered).controlSize(.mini).tint(.accentColor)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 已生成音频：▶ 播放/⏹ 停止 + ↻ 重新生成（过期标橙）+ 对齐后时长
    private func generatedControls(_ d: SegmentDub) -> some View {
        let playing = dubVM.playingDubID == d.id
        let reasons = staleReasons(d)
        let stale = !reasons.isEmpty
        // 对齐后音频时长与分镜时长的偏差：≤0.2s 视为贴合（绿），否则橙（会拉长/留白）
        let target = segment.duration
        let drift = abs(d.audioDuration - target)
        let aligned = d.audioDuration <= 0 || drift <= 0.2
        return VStack(spacing: 3) {
            HStack(spacing: 10) {
                Button {
                    dubVM.playDub(d)
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(playing ? .red : (stale ? .orange : .green))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(playing ? "停止试听" : "试听配音")
                .help(playing ? "停止" : "试听这条配音")

                Button {
                    dubVM.startDubAudioTask(for: d, context: modelContext)
                } label: {
                    Image(systemName: stale ? "exclamationmark.arrow.circlepath" : "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(stale ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("重新配音")
                .help(stale ? "已过期：\(reasons.map(\.userText).joined(separator: "、"))，点重新生成" : "重新生成")
            }
            if d.audioDuration > 0 {
                Text(String(format: "%.1fs", d.audioDuration))
                    .font(DesignTokens.Typography.microMono)
                    .foregroundStyle(aligned ? .green : .orange)
                    .help("配音时长 \(String(format: "%.1f", d.audioDuration))s / 分镜 \(String(format: "%.1f", target))s")
            }
        }
    }
}
