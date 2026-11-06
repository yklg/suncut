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
        // alignment 必须显式给：默认 .center 会让"内容左缩进 + 1px 导轨"没有确定基线。
        VStack(alignment: .leading, spacing: 10) {
            TranscriptSection(segment: segment)
            BoundarySection(segment: segment, viewModel: viewModel)
            SubtitleSection(segment: segment)
            VoiceLockSection(segment: segment)
            CategorySection(segment: segment, viewModel: viewModel)
        }
    }
}

// MARK: - ⓪ 台词原文

/// 台词原文编辑（由卡片内联迁入；Inspector 单实例，按需展开）。
///
/// 草稿契约由 ``InspectorDraftMirror`` 承担：宿主以 `.id(segment.id)` 绑定身份，
/// 切分镜必走 onAppear 重新 reset；同一分镜内模型值被外部流程（边界微调重切、
/// 重新识别）原地更新时，仅当用户没动过草稿才采纳，脏草稿保留交保存/还原收口。
private struct TranscriptSection: View {
    let segment: Segment
    @Environment(\.modelContext) private var modelContext
    @State private var mirror = InspectorDraftMirror()
    @FocusState private var focused: Bool

    var body: some View {
        CollapsibleInspectorSection(icon: "text.quote", title: "台词原文") {
            VStack(alignment: .leading, spacing: 7) {
                TextEditor(text: Binding(get: { mirror.draft },
                                         set: { mirror.edit($0) }))
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
                    .onAppear { mirror.reset(to: segment.text) }
                    // 外部原地更新（边界微调重切台词等）：干净草稿跟随，脏草稿不被吞
                    .onChange(of: segment.text) { _, newText in
                        mirror.adoptExternal(newText)
                    }
                HStack(spacing: 8) {
                    Button {
                        save()
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    .controlSize(.small)
                    Button {
                        mirror.reset(to: segment.text)
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
                save()
                return .handled
            }
        }
    }

    private func save() {
        let trimmed = mirror.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != segment.text else {
            // 与模型一致（如只敲了空白）：仅对齐镜像，不落库
            mirror.didCommit(trimmed)
            return
        }
        segment.setText(trimmed, source: .manualEdit)
        try? modelContext.save()
        mirror.didCommit(trimmed)
        ToastCenter.shared.show("台词已更新",
                                icon: "checkmark.circle.fill")
    }
}

// MARK: - 折叠分区壳

/// Inspector 折叠分区：标题行 + 可选的标题行回显槽 + 内容。
/// 不适用的内容由调用方置灰而非隐藏（位置稳定）。
///
/// `Trailing` 这一槽的存在理由：分类标签的"已命中"必须在**收起态**也看得见，
/// 而收起态只有标题行是常驻的。回显只读、不接手势 —— 点按仍归标题行，
/// 否则父子两层会抢同一个 tap。
struct CollapsibleInspectorSection<Content: View, Trailing: View>: View {
    let icon: String
    let title: String
    var defaultExpanded: Bool = true
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content
    @State private var expanded: Bool

    init(icon: String, title: String, defaultExpanded: Bool = true,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.defaultExpanded = defaultExpanded
        self.trailing = trailing()
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
                Spacer(minLength: 6)
                trailing
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            }
            .padding(.vertical, 8)

            if expanded {
                content
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }
}

extension CollapsibleInspectorSection where Trailing == EmptyView {
    /// 没有回显槽的调用点走这颗便利 init（泛型参数没法从默认实参推出来）。
    init(icon: String, title: String, defaultExpanded: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(icon: icon, title: title, defaultExpanded: defaultExpanded,
                  trailing: { EmptyView() }, content: content)
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
///
/// 时间码文本框与台词框共用 ``InspectorDraftMirror`` 契约：宿主 `.id(segment.id)`
/// 保证切实体重新装载；同实体帧被 ±按钮等外部改动时，未聚焦/未手改的镜像跟随，
/// 手输中的内容不被覆盖。
struct BoundaryAdjustRow: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    private enum TimeField: Hashable { case start, end }

    @State private var startMirror = InspectorDraftMirror()
    @State private var endMirror = InspectorDraftMirror()
    @FocusState private var focusedField: TimeField?

    private var fps: Double { segment.video?.fps ?? 30 }
    private func timecode(_ frame: Int) -> String { FrameTime.timecode(frame: frame, fps: fps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            group(label: "入", focus: .start,
                  text: Binding(get: { startMirror.draft }, set: { startMirror.edit($0) })) {
                viewModel.adjustStartFrame(for: segment, by: -1)
            } onPlus: {
                viewModel.adjustStartFrame(for: segment, by: 1)
            }
            group(label: "出", focus: .end,
                  text: Binding(get: { endMirror.draft }, set: { endMirror.edit($0) })) {
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
            // 进入编辑：装载裸帧号供直接输入
            if newField == .start { startMirror.reset(to: "\(segment.startFrame)") }
            if newField == .end { endMirror.reset(to: "\(segment.endFrame)") }
            // 离开编辑：提交手输
            if oldField == .start { commitStart() }
            if oldField == .end { commitEnd() }
        }
        .onAppear {
            startMirror.reset(to: timecode(segment.startFrame))
            endMirror.reset(to: timecode(segment.endFrame))
        }
        .onChange(of: segment.startFrame) { _, newVal in
            if focusedField != .start { startMirror.adoptExternal(timecode(newVal)) }
        }
        .onChange(of: segment.endFrame) { _, newVal in
            if focusedField != .end { endMirror.adoptExternal(timecode(newVal)) }
        }
        // 兜底：手输时间码未及失焦就切实体（旧子树随即销毁）。commit 内有等值 guard，
        // 未改动/非法输入都不会触发 setStartFrame 的保存、缩略图重生与播放副作用链。
        .onDisappear {
            if focusedField == .start { commitStart() }
            if focusedField == .end { commitEnd() }
        }
    }

    @ViewBuilder
    private func group(label: String,
                       focus: TimeField,
                       text: Binding<String>,
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
        guard let f = Int(startMirror.draft.trimmingCharacters(in: .whitespaces)), f >= 0 else {
            startMirror.reset(to: timecode(segment.startFrame))
            return
        }
        if f != segment.startFrame { viewModel.setStartFrame(for: segment, to: f) }
        startMirror.reset(to: timecode(segment.startFrame))
    }

    private func commitEnd() {
        guard let f = Int(endMirror.draft.trimmingCharacters(in: .whitespaces)), f > 0 else {
            endMirror.reset(to: timecode(segment.endFrame))
            return
        }
        if f != segment.endFrame { viewModel.setEndFrame(for: segment, to: f) }
        endMirror.reset(to: timecode(segment.endFrame))
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

struct CategorySection: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel

    var body: some View {
        CollapsibleInspectorSection(icon: "tag", title: "分类",
                                    defaultExpanded: false,
                                    trailing: { CategoryEcho(segment: segment) }) {
            SegmentCategoryEditor(segment: segment, viewModel: viewModel)
        }
    }
}

/// 收起态的「已命中」回显：铺几颗由 `CategoryEchoBudget` 的算术决定，其余折成「+N」。
///
/// ⚠️ 两颗标签都住在标题行那个刚性 `HStack` 里（不是 FlowLayout），所以**调用点各自带
/// `.lineLimit(1)`** —— 这是 `TagRowContainerGuardTests` 认的第二半边逃生口；摘掉它就会在
/// 窄容器里压成一字一行的竖排（那个坑已在卡片、列表行、抽屉上各复发过一次）。
/// "看不全"由「+N」补齐，不靠截断。
struct CategoryEcho: View {
    let segment: Segment

    var body: some View {
        let slice = CategoryEchoBudget.slice(segment.semanticTypes)
        HStack(spacing: 3) {
            if slice.shown.isEmpty {
                // 空态也得有读数：没有胶囊时用户分不清"这段没标签"和"回显没渲染出来"。
                // 措辞用「无标签」不用「未分类」—— 后者是顶部筛选条的**素材来源**维度，会撞车。
                echoChip("无标签", emphasis: false)
            } else {
                ForEach(slice.shown) { type in
                    SemanticTypeTag(type: type).lineLimit(1)
                }
                if slice.overflow > 0 {
                    echoChip("+\(slice.overflow)", emphasis: true)
                }
            }
            PositionTypeTag(type: segment.positionType).lineLimit(1)
        }
    }

    private func echoChip(_ text: String, emphasis: Bool) -> some View {
        Text(text)
            .font(emphasis ? DesignTokens.Typography.microBold : DesignTokens.Typography.micro)
            // 两支都得是 Color：`Color.tertiary` 不存在，而三元里混 ShapeStyle 会类型不洽。
            .foregroundStyle(emphasis ? Color.secondary : Color.secondary.opacity(0.65))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.secondary.opacity(DesignTokens.Palette.Alpha.subtle))
            .clipShape(Capsule())
    }
}

/// 展开态的分类编辑器：**行内 chip 面板**，不是下拉菜单。
///
/// 为什么把那颗 `Menu` 整颗换掉（三个症状在这里一次收口，不是换皮）：
/// ① 菜单项的选中态原先只靠 `Label(systemImage: 命中 ? "checkmark" : "")` 表达 —— macOS 上
///    `Menu` 里的 `Button` 没有选择语义，空串还不是合法 symbol 名，逐列量过用户截图：12 项零勾选。
/// ② 这颗分区是 ScrollView 的最后一行，而 `SwiftUI.Menu` 没有指定弹出方向的 API ⇒
///    弹层被窗口下沿裁掉那一格在菜单上无解。
/// ③ 菜单 label 行与分区标题行同形（都是「文字 + 图标 + 右箭头」），只差 2pt 字号 ⇒
///    屏幕上「保留原声 / 分类 / 语义·位置」看着像三个平级功能，就是用户说的「挤」。
/// 行内面板让命中态**不用点开就可见**，层级改由缩进 + 导轨承担。
struct SegmentCategoryEditor: View {
    let segment: Segment
    @Bindable var viewModel: SegmentLibraryViewModel
    /// 「空镜」那颗的二次确认臂。宿主整棵子树以 `.id(segment.id)` 绑定身份
    /// （见 `SegmentLibraryView` 的实体身份契约），所以切实镜会自动复位，不用手动清。
    @State private var emptyShotArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("语义类型 · 可多选（再点取消）")
            FlowLayout(spacing: 4) {
                ForEach(SemanticType.allCases) { type in
                    SelectableChip(label: type.rawValue,
                                   color: SemanticTypeTag.color(for: type),
                                   isOn: segment.semanticTypes.contains(type)) {
                        toggle(type)
                    }
                }
            }
            groupLabel("位置 · 单选（点即切换）")
            FlowLayout(spacing: 4) {
                ForEach(PositionType.allCases) { position in
                    PositionChoiceChip(label: position.rawValue,
                                       isOn: segment.positionType == position) {
                        viewModel.updatePositionType(for: segment, to: position)
                    }
                }
            }
        }
        // 层级交给几何：左缩进 + 1px 导轨把"这块属于上面那颗标题"写成空间包含关系。
        // ⚠️ 只作用于本分区内部，**不做全局缩进** —— 全局 +20 会让边界微调的实际可用宽
        // 从 312 掉到 292，而 `BoundaryAdjustLayout` 的契约仍报 312 ⇒ 判据绿、屏上塌。
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.35))
                .frame(width: 1)
                .padding(.vertical, 2)
        }
    }

    /// 子标签：**不放图标、不放箭头**。「可折叠」的签名重新只属于分区标题行。
    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.captionStrong)
            .foregroundStyle(.secondary)
    }

    private func toggle(_ type: SemanticType) {
        if SemanticType.confirmationNeededForEmptyShot(on: segment, adding: type),
           !emptyShotArmed {
            ToastCenter.shared.show(SemanticType.emptyShotWarningMessage,
                                    icon: "exclamationmark.triangle.fill", style: .warning)
            emptyShotArmed = true
            return
        }
        emptyShotArmed = false
        viewModel.toggleSemanticType(for: segment, type: type)
    }
}

/// 可多选的标签 chip。视觉口径取自 `FilterChip` 的**选中态**（加粗 + 0.15 底 + 0.4 描边）。
///
/// ⚠️ 刻意**不改写 `FilterChip` 来复用**：那颗正被顶部 12 颗语义筛选 chip 与来源筛选条挂着，
/// 而它「计数为 0 就减淡去饱和」是筛选条的既有产品语义 —— 标签编辑没有 count 这个概念，
/// 合一颗会把它一起拖下水。重复的只有几行样式常量，不构成"同一行为写两遍"。
struct SelectableChip: View {
    let label: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(color.opacity(isOn ? 0.15 : 0.06))
                .foregroundStyle(isOn ? color : color.opacity(0.85))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(color.opacity(isOn ? 0.4 : 0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 位置那颗：中性灰胶囊 + 左侧打点。与语义的"色胶囊点亮"是两套可分辨的语言 ——
/// 多值再点一次是**取消**、单值再点一次是**换一颗**，后果不同就得长得不一样。
/// 这里 `circle` / `checkmark` 都是合法 symbol 名，与被量测证伪的"空串当图标"不是一回事。
struct PositionChoiceChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(isOn ? Color.primary.opacity(0.7)
                                          : Color.secondary.opacity(0.45))
                Text(label)
                    .font(.system(size: 11, weight: isOn ? .semibold : .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(isOn ? 0.22 : 0.10))
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(isOn ? 0.40 : 0.15),
                                      lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 批量动作（纯模型动作，单一真源）

@MainActor
enum SegmentBatchActions {

    /// 能量层补标：**只跑 silencedetect**（本地 ffmpeg，不跑 whisper ⇒ 不花钱、不改台词）。
    ///
    /// 为什么必须单独一条：能量层判出的空镜段，文本常常**非空也不是套话**
    /// （whisper 在纯音乐上幻觉出「Zither Harp」那类）。只认名单层的那颗补标够不着它，
    /// 而它恰恰是最该拿来垫差间的画面 —— 补了标签却进不了池（读侧闸要三道证据之一）就是白补。
    ///
    /// 两道判断各用一颗：定罪阈值走 `EmptyLensPolicy.energyConvicts`（与拦打标同一个数），
    /// 而"要不要写标签"仍归 `shouldSuppressTagging`（关闸的日子里这条腿也不许动标签）。
    /// 返回 (新探测的视频数, 新打标的段数)。撤销只回滚标签；探测到的**证据留着**
    ///（证据没有"错"可言，下次不必再跑一遍 ffmpeg）。
    static func applyEmptyLensEnergyBackfill(in segments: [Segment], in context: ModelContext) async
        -> (probed: Int, tagged: Int) {
        let scene = SceneDetectionService()
        var byVideo: [ObjectIdentifier: Video] = [:]
        for seg in segments { if let v = seg.video { byVideo[ObjectIdentifier(v)] = v } }

        // 一个视频只探测一次；已有证据的直接复用（含"探测过且全程有声"那份空数组 —— 与没探测过是两件事）
        var probed = 0
        for video in byVideo.values.sorted(by: { $0.name < $1.name }) where video.silenceWindowsRaw == nil {
            guard !video.localPath.isEmpty else { continue }
            if let found = try? await scene.detectSilence(in: video.localPath) {
                video.setSilenceWindows(found.map { SilenceWindow(start: $0.start, end: $0.end) })
                probed += 1
            }
        }
        context.safeSave()

        var targets: [Segment] = []
        for seg in segments where !seg.semanticTypes.contains(.emptyShot) {
            guard let video = seg.video, let windows = video.silenceWindows else { continue }
            let voiced = EmptyLensPolicy.voicedFraction(windowStart: seg.startTime,
                                                        windowEnd: seg.endTime, silentWindows: windows)
            if EmptyLensPolicy.energyConvicts(voicedFraction: voiced),
               EmptyLensPolicy.shouldSuppressTagging(.emptyLens(.silentWindow)) {
                targets.append(seg)
            }
        }
        guard !targets.isEmpty else { return (probed, 0) }

        let snapshot: [(seg: Segment, types: [SemanticType])] = targets.map { ($0, $0.semanticTypes) }
        for seg in targets { seg.semanticTypes = [.emptyShot] }
        context.safeSave()
        MixLog.info("[空镜补标] 能量层：新探测 \(probed) 个视频、补标 \(targets.count) 段（只跑静音探测，未跑 whisper）")

        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已按静音占比补标 \(targets.count) 个分镜为「空镜」（新探测 \(probed) 个视频）",
            actionTitle: "撤销空镜补标",
            seconds: 5
        ) {
            for item in snapshot where !item.seg.isDroppedFromContext { item.seg.semanticTypes = item.types }
            context.safeSave()
            ToastCenter.shared.show("已还原空镜补标（探测到的静音证据保留）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
        return (probed, targets.count)
    }

    /// 把当前分镜的字幕字号应用到**同一视频**的所有分镜（覆盖前快照 + 可撤销 Toast）。
    static func applyFontSizeToAllSegments(of source: Segment, in context: ModelContext) {
        guard let video = source.video else { return }
        let ratio = SubtitleFontSize.clamp(source.subtitleFontRatio)
        let targets = video.displayableSegments.filter { $0.id != source.id }
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

    /// 旧库补标「空镜」的**命中集**（纯读，不改任何东西）。
    ///
    /// 只用已存的段台词判套话名单，**不重听** —— 能量层要的是 silencedetect 的产物，
    /// 旧库没存那份证据（`ASRSentence.emptyLensSignals` 是这一轮才加的字段，历史值为 nil），
    /// 要抬能量层只能重跑 ASR。所以这条能走通的腿只有名单层，覆盖面也仅限 whisper 套话那一类。
    /// 干跑与实改必须吃同一颗（UI 先报数再落库，防"屏上一个数、库里另一个数"）。
    ///
    /// 定义域由调用方传 `viewModel.segments`（VM 里那份**未筛选**全集，取自
    /// `video.displayableSegments` 唯一出口）：视图自己读 `project.displayableSegments`
    /// 会新增一处 G08 裸读，而且等于把"已经算过一遍的取数"再算一遍。
    static func emptyLensBackfillHits(in segments: [Segment]) -> [Segment] {
        segments.filter { seg in
            !seg.semanticTypes.contains(.emptyShot)
                && EmptyLensPolicy.phraseOnlyConvicts(seg.text)
        }
    }

    /// 执行补标：覆盖前快照 + 5 秒撤销（与「批量字号 / 批量遮挡」同一条形状）。
    ///
    /// ⚠️ 这是全仓第三处会写「空镜」标签的地方（另两处见 `ImportViewModel.applyEmptyLensGate`
    /// 与自建分镜路径）。三处都必须只从 `EmptyLensPolicy` 拿判断，不许在这里另写名单。
    static func applyEmptyLensBackfill(in segments: [Segment], in context: ModelContext) {
        let targets = emptyLensBackfillHits(in: segments)
        guard !targets.isEmpty else {
            ToastCenter.shared.show("没有按已存文本判得出「空镜」的分镜（名单层没命中）",
                                    icon: "info.circle.fill", style: .info)
            return
        }
        let snapshot: [(seg: Segment, types: [SemanticType])] =
            targets.map { ($0, $0.semanticTypes) }
        for seg in targets { seg.semanticTypes = [.emptyShot] }
        context.safeSave()
        MixLog.info("[空镜补标] 定义域 \(segments.count) 段，命中 \(targets.count) 段（只用已存文本，未重听）")

        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已把 \(targets.count) 个分镜补标为「空镜」（没重听音频）",
            actionTitle: "撤销补标空镜",
            seconds: 5
        ) {
            var restored = 0
            for item in snapshot where !item.seg.isDroppedFromContext {
                item.seg.semanticTypes = item.types
                restored += 1
            }
            context.safeSave()
            ToastCenter.shared.show(restored == snapshot.count
                                    ? "已还原空镜补标"
                                    : "已还原 \(restored) 个分镜的标签（其余已被删除）",
                                    icon: "arrow.uturn.backward", style: .info)
        }
    }

    /// 把当前分镜的遮挡设置应用到同一视频的所有分镜（批量覆盖，可撤销）。
    static func applyMaskToAllSegments(of source: Segment, in context: ModelContext) {
        guard let video = source.video else { return }
        let rect = source.maskRect
        let style = source.maskStyle
        let hasSub = source.hasHardSubtitle

        let targets = video.displayableSegments.filter { $0.id != source.id }
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
