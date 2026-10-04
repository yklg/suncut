// MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift
//
// 片段属性区：选中分镜后挂在 Inspector 变体池下方。
// 展示与编辑分离的承接点——卡片只展示，所有片段级编辑（边界/字幕/原声/分类）住这里。
import SwiftUI
import SwiftData

// MARK: - 装配

struct SegmentPropertiesContent: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    var body: some View {
        VStack(spacing: 8) {
            TranscriptSection(segment: segment)
            BoundarySection(segment: segment, viewModel: viewModel)
            SubtitleSection(segment: segment)
            VoiceLockSection(segment: segment)
            CategorySection(segment: segment)
        }
    }
}

// MARK: - ⓪ 台词原文

/// 台词原文编辑（由卡片内联迁入；Inspector 单实例，按需展开）。
private struct TranscriptSection: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext
    @State private var draft: String = ""
    @FocusState private var focused: Bool
    @State private var didLoad = false

    var body: some View {
        CollapsibleInspectorSection(icon: "text.quote", title: "台词原文") {
            VStack(alignment: .leading, spacing: 7) {
                TextEditor(text: $draft)
                    .font(DesignTokens.Typography.caption)
                    .lineSpacing(3)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .frame(height: 96)
                    .background(Color(.textBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .onAppear {
                        guard !didLoad else { return }
                        draft = segment.text
                        didLoad = true
                    }
                HStack(spacing: 8) {
                    Button {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != segment.text {
                            segment.setText(trimmed, source: .manualEdit)
                            try? modelContext.save()
                            ToastCenter.shared.show("台词已更新",
                                                    icon: "checkmark.circle.fill")
                        }
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    .controlSize(.small)
                    Button {
                        draft = segment.text
                    } label: {
                        Label("还原", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    Spacer()
                    Text("⌘↩ 保存")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }
            }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != segment.text {
                    segment.setText(trimmed, source: .manualEdit)
                    try? modelContext.save()
                }
                return .handled
            }
        }
    }
}

// MARK: - 折叠分区壳

/// Inspector 折叠分区：标题行 + 内容；不适用的内容由调用方置灰而非隐藏（位置稳定）。
struct CollapsibleInspectorSection<Content: View>: View {
    let icon: String
    let title: String
    var defaultExpanded: Bool = true
    @ViewBuilder let content: Content
    @State private var expanded: Bool

    init(icon: String, title: String, defaultExpanded: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.defaultExpanded = defaultExpanded
        self.content = content()
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(DesignTokens.Typography.labelStrong)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            }
            .padding(.vertical, 7)

            if expanded {
                content
                    .padding(.bottom, 9)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - ① 边界微调

private struct BoundarySection: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    var body: some View {
        CollapsibleInspectorSection(icon: "film", title: "边界微调") {
            BoundaryAdjustRow(segment: segment, viewModel: viewModel)
        }
    }
}

/// 边界微调编辑器（由卡片迁入；Inspector 宽度充裕，纵向两行布局）。
struct BoundaryAdjustRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    private enum TimeField: Hashable { case start, end }

    @State private var startText: String = ""
    @State private var endText: String = ""
    @FocusState private var focusedField: TimeField?

    private var fps: Double { segment.video?.fps ?? 30 }
    private func timecode(_ frame: Int) -> String { FrameTime.timecode(frame: frame, fps: fps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group(label: "入", text: $startText, focus: .start) {
                viewModel.adjustStartFrame(for: segment, by: -1)
            } onPlus: {
                viewModel.adjustStartFrame(for: segment, by: 1)
            }
            group(label: "出", text: $endText, focus: .end) {
                viewModel.adjustEndFrame(for: segment, by: -1)
            } onPlus: {
                viewModel.adjustEndFrame(for: segment, by: 1)
            }
            Text("逐帧精确；调整后自动重切台词、重生成封面并预览（1 帧 ≈ 0.03 秒）")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: focusedField) { oldField, newField in
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

    @ViewBuilder
    private func group(label: String,
                       text: Binding<String>,
                       focus: TimeField,
                       onMinus: @escaping () -> Void,
                       onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary)
                .frame(width: BoundaryAdjustLayout.labelWidth)
            adjustButton(systemName: "minus", accessibilityLabel: "\(label)点提前", action: onMinus)
            TextField("", text: text)
                .font(DesignTokens.Typography.microMonoStrong)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .foregroundStyle(focusedField == focus ? .primary : .secondary)
                .focused($focusedField, equals: focus)
                .frame(width: BoundaryAdjustLayout.timeFieldWidth, height: 16)
                .background(focusedField == focus ? Color.accentColor.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            adjustButton(systemName: "plus", accessibilityLabel: "\(label)点延后", action: onPlus)
            Spacer(minLength: 0)
        }
    }

    private func commitStart() {
        guard let f = Int(startText.trimmingCharacters(in: .whitespaces)), f >= 0 else {
            startText = timecode(segment.startFrame)
            return
        }
        if f != segment.startFrame { viewModel.setStartFrame(for: segment, to: f) }
        startText = timecode(segment.startFrame)
    }

    private func commitEnd() {
        guard let f = Int(endText.trimmingCharacters(in: .whitespaces)), f > 0 else {
            endText = timecode(segment.endFrame)
            return
        }
        if f != segment.endFrame { viewModel.setEndFrame(for: segment, to: f) }
        endText = timecode(segment.endFrame)
    }

    private func adjustButton(systemName: String, accessibilityLabel: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DesignTokens.Typography.microEmphasis)
                .foregroundStyle(.secondary)
                .frame(width: BoundaryAdjustLayout.adjustButtonWidth,
                       height: BoundaryAdjustLayout.adjustButtonWidth)
                .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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

// MARK: - ② 字幕处理

private struct SubtitleSection: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext
    @State private var showFontPopover = false

    private var isLocked: Bool { segment.isVoiceLocked }

    var body: some View {
        CollapsibleInspectorSection(icon: "captions.bubble", title: "字幕处理") {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(SubtitleTreatment.allCases) { t in
                    treatmentChip(t)
                }
            }
            // 不适用（保留原声）时置灰，不移除（位置稳定）
            .disabled(isLocked)
            .opacity(isLocked ? 0.4 : 1)

            if segment.subtitleTreatment.needsMask {
                Button {
                    SegmentBatchActions.applyMaskToAllSegments(of: segment, in: modelContext)
                } label: {
                    Label("遮挡区应用到所有分镜", systemImage: "square.on.square")
                        .font(DesignTokens.Typography.microRegular)
                }
                .buttonStyle(.plain)
                .disabled(isLocked)
                .foregroundStyle(isLocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }

            Button { showFontPopover = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "textformat.size")
                        .font(DesignTokens.Typography.micro)
                    Text("字幕字号 \(String(format: "%.1f%%", SubtitleFontSize.clamp(segment.subtitleFontRatio) * 100))")
                        .font(DesignTokens.Typography.micro)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(isLocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .popover(isPresented: $showFontPopover, arrowEdge: .bottom) {
                SubtitleFontSizePopover(
                    fontRatio: Binding(
                        get: { segment.subtitleFontRatio },
                        set: { segment.setSubtitleFontRatio($0); modelContext.safeSave() }
                    ),
                    isPresented: $showFontPopover,
                    onApplyToAll: {
                        SegmentBatchActions.applyFontSizeToAllSegments(of: segment,
                                                                       in: modelContext)
                    })
            }

            Text("仅在配音渲染导出时生效（普通混剪导出不处理）")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.tertiary)
        }
    }

    private func treatmentChip(_ t: SubtitleTreatment) -> some View {
        let on = t == segment.subtitleTreatment
        return Text(t.displayName)
            .font(.system(size: 10, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.1)))
            .contentShape(Capsule())
            .onTapGesture {
                segment.subtitleTreatment = t
                try? modelContext.save()
            }
    }
}

// MARK: - ③ 保留原声

private struct VoiceLockSection: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        CollapsibleInspectorSection(icon: "lock.fill", title: "保留原声",
                                   defaultExpanded: false) {
            InlineSwitch(
                isOn: segment.isVoiceLocked,
                label: "保留原声",
                systemImage: "lock.fill",
                help: "明星出镜口播等不可替换的镜头，勾选后不参与改写/配音"
            ) {
                segment.isVoiceLocked.toggle()
                try? modelContext.save()
            }
        }
    }
}

// MARK: - ④ 分类

private struct CategorySection: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        CollapsibleInspectorSection(icon: "tag", title: "分类",
                                   defaultExpanded: false) {
            Menu {
                Section("语义类型") {
                    ForEach(SemanticType.allCases) { type in
                        Button {
                            var types = segment.semanticTypes
                            if let idx = types.firstIndex(of: type) {
                                types.remove(at: idx)
                            } else {
                                types.append(type)
                            }
                            segment.semanticTypes = types
                            try? modelContext.save()
                        } label: {
                            Label(type.rawValue,
                                  systemImage: segment.semanticTypes.contains(type) ? "checkmark" : "")
                        }
                    }
                }
                Section("位置") {
                    ForEach(PositionType.allCases) { type in
                        Button {
                            segment.positionType = type
                            try? modelContext.save()
                        } label: {
                            Label(type.rawValue,
                                  systemImage: segment.positionType == type ? "checkmark" : "")
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text("语义 / 位置")
                        .font(DesignTokens.Typography.microRegular)
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
    }
}

// MARK: - 批量动作（纯模型动作，单一真源）

@MainActor
enum SegmentBatchActions {

    /// 把当前分镜的字幕字号应用到**同一视频**的所有分镜（覆盖前快照 + 可撤销 Toast）。
    static func applyFontSizeToAllSegments(of source: Segment, in context: ModelContext) {
        guard let video = source.video else { return }
        let ratio = SubtitleFontSize.clamp(source.subtitleFontRatio)
        let targets = video.segments.filter { $0.id != source.id }
        guard !targets.isEmpty else {
            ToastCenter.shared.show("这个视频只有一个分镜，无需应用",
                                    icon: "info.circle.fill", style: .info)
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
            var restored = 0
            for item in snapshot where !item.seg.isDroppedFromContext {
                item.seg.subtitleFontRatio = item.ratio
                restored += 1
            }
            context.safeSave()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原字幕字号"
                                    : "已还原 \(restored) 个分镜的字号（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }

    /// 把当前分镜的遮挡设置应用到同一视频的所有分镜（批量覆盖，可撤销）。
    static func applyMaskToAllSegments(of source: Segment, in context: ModelContext) {
        guard let video = source.video else { return }
        let rect = source.maskRect
        let style = source.maskStyle
        let hasSub = source.hasHardSubtitle

        let targets = video.segments.filter { $0.id != source.id }
        guard !targets.isEmpty else {
            ToastCenter.shared.show("这个视频只有一个分镜，无需应用",
                                    icon: "info.circle.fill", style: .info)
            return
        }

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
            var restored = 0
            for item in snapshot where !item.seg.isDroppedFromContext {
                item.seg.hasHardSubtitle = item.hasSub
                item.seg.maskRect = item.rect
                item.seg.maskStyle = item.style
                restored += 1
            }
            try? context.save()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原遮挡设置"
                                    : "已还原 \(restored) 个分镜的遮挡（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }
}

// MARK: - 自绘基础控件（由 SegmentDubControls.swift 迁入，唯一定义，禁复制第二份）

/// 自绘开关，替代 `Toggle(.switch)`；点击/键盘/读屏三条都自接。
struct InlineSwitch: View {
    let isOn: Bool
    let label: String
    let systemImage: String
    let help: String
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
            Capsule()
                .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 26, height: 14)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .focusable()
        .onKeyPress(.space, phases: .down) { _ in
            onToggle()
            return .handled
        }
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
    }
}

/// 自绘按钮，替代 borderless/plain Button；点击、空格与读屏自接。
struct InlineTapLabel<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .focusable()
            .onKeyPress(.space, phases: .down) { _ in
                action()
                return .handled
            }
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
