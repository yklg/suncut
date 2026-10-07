import SwiftUI

/// 配音音色选择弹窗（中立组件）—— 设置页全局默认 / 项目概览覆盖 / 脚本成片段级改选三处复用。
///
/// 中立纪律（同 SegmentGridPickerSheet / G-S8）：
/// - 不引用任何具体 ViewModel，不持 SwiftData 对象；调用方传入当前 VoiceChoice? 与上下文文案，
///   用户确认后仅经 onPick 回调 `.preset` 或 nil（清除/跟随默认），持久化由各入口 VM 收口；
/// - 筛选走 Core VoiceCatalogFilter 纯函数；「使用该音色」只回调、绝不触发生成（计费在各页生成按钮）；
/// - 「我的复刻」分区本期置灰（M2 提供数据源后长入，VoiceChoice.globalClone 编解码已就绪）。
struct VoicePickerSheet: View {
    /// 弹窗标题（如「全局默认音色」「项目配音音色」「本段配音音色」）。
    let title: String
    /// 标题下的上下文说明（可选；如项目名、作用域说明）。
    let contextLine: String?
    /// 当前已选音色（仅 preset 会在列表高亮；videoClone/globalClone 本期无对应行，不预选）。
    let current: VoiceChoice?
    /// 是否提供「清除/跟随默认」动作。
    let allowsClear: Bool
    /// 清除动作的文案（如「未配置（不自动配音）」「跟随全局默认」）。
    let clearLabel: String?
    /// 确认选择；nil = 用户选择清除/跟随默认。
    let onPick: (VoiceChoice?) -> Void
    /// 取消/关闭（不改任何状态）。
    let onClose: () -> Void

    @State private var selectedTag: VoiceTag?
    @State private var query = ""
    @State private var pickedVoiceID: String?
    @State private var auditionPlayer = VoiceAuditionPlayer.shared

    private let voices = VoiceCatalog.active

    init(title: String,
         contextLine: String? = nil,
         current: VoiceChoice?,
         allowsClear: Bool = false,
         clearLabel: String? = nil,
         onPick: @escaping (VoiceChoice?) -> Void,
         onClose: @escaping () -> Void) {
        self.title = title
        self.contextLine = contextLine
        self.current = current
        self.allowsClear = allowsClear
        self.clearLabel = clearLabel
        self.onPick = onPick
        self.onClose = onClose
        // 仅预置音色在本期列表内；其它身份不预选（复刻列表 M2）。
        if case .preset(let voiceID) = current {
            _pickedVoiceID = State(initialValue: voiceID)
        }
    }

    /// 单选 chip → 标签集合（带货是叠加维度，本期 chip 交互单选；Core 过滤已支持交集，未来可直接放开）。
    private var selectedTags: Set<VoiceTag> {
        selectedTag.map { [$0] } ?? []
    }

    private var filteredVoices: [TTSVoice] {
        VoiceCatalogFilter.filter(voices, selectedTags: selectedTags, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            voiceList
            Divider()
            footer
        }
        // 统一弹窗尺寸契约：ideal 580 固定 → 切 chip 窗口不跳动；min 420 → 小宿主（设置页 sheet）可收缩。
        .sheetContainerFrame(minWidth: 560, idealWidth: 560, maxWidth: 560,
                             minHeight: 420, idealHeight: 580)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onDisappear { VoiceAuditionPlayer.shared.stop() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DesignTokens.Typography.bodyEmphasis)
                if let contextLine, !contextLine.isEmpty {
                    Text(contextLine)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: 筛选

    private var filterBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "全部 \(voices.count)", active: selectedTag == nil) { selectedTag = nil }
                    ForEach([VoiceTag.commerce, .female, .male, .child, .character], id: \.rawValue) { tag in
                        chip(title: tag.displayName, active: selectedTag == tag) {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                TextField("搜索音色名 / 风格", text: $query)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.label)
                Text("点 ▶ 试听固定短句（计一次短文本合成费）")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(active ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 音色列表

    private var voiceList: some View {
        // 列表区独占 header/filter/footer 之外的全部空间：内容多少只影响滚动，不影响外框高度（切 chip 不跳动）。
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredVoices) { voice in
                    voiceRow(voice)
                    if voice.id != filteredVoices.last?.id {
                        Divider().padding(.leading, 44)
                    }
                }
                if filteredVoices.isEmpty {
                    Text("没有符合筛选的音色")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                // M2：我的复刻音色分区（VoiceProfile 数据源就位后启用；globalClone 回调已通）。
                cloneSection
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func voiceRow(_ voice: TTSVoice) -> some View {
        let picked = pickedVoiceID == voice.id
        let auditioning = auditionPlayer.auditioningVoiceID == voice.id
        return Button {
            pickedVoiceID = voice.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(voice.displayName).font(DesignTokens.Typography.labelEmphasis)
                        if voice.tags.contains(.commerce) {
                            Text("带货")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                        }
                    }
                    Text(voice.summary)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                auditionButton(voiceID: voice.id, auditioning: auditioning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(picked ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func auditionButton(voiceID: String, auditioning: Bool) -> some View {
        Button {
            if auditioning {
                auditionPlayer.stop()
            } else {
                auditionPlayer.playPreset(voiceID)
            }
        } label: {
            if auditioning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "play.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(auditioning ? "停止试听" : "试听该音色（固定短句，计一次短文本合成费）")
        .accessibilityLabel(auditioning ? "停止试听" : "试听")
    }

    /// 「我的复刻」置灰分区（M2 开放）。
    private var cloneSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("我的复刻音色").font(DesignTokens.Typography.labelEmphasis)
                Text("上传音频或从视频提取注册复刻音色，将在后续版本开放")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("敬请期待")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(0.6)
        .allowsHitTesting(false)
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 10) {
            if allowsClear, let clearLabel {
                Button(role: .destructive) {
                    onPick(nil)
                } label: {
                    Text(clearLabel)
                        .font(DesignTokens.Typography.label)
                }
                .buttonStyle(.borderless)
                .help("清除后回落到上级默认 / 不自动配音")
            }
            if let error = auditionPlayer.lastError {
                Text(error)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button("取消", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("使用该音色") {
                if let pickedVoiceID {
                    onPick(.preset(voiceID: pickedVoiceID))
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(pickedVoiceID == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
