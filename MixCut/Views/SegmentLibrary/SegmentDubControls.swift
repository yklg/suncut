// MixCut/Views/SegmentLibrary/SegmentDubControls.swift
import SwiftUI

/// 分镜卡片上的配音相关控件。无持久化逻辑，动作经 binding/闭包上抛。
///
/// ⚠️ 这里的开关与两个入口**故意不用 `Toggle`/`Button`**，而是自绘（`InlineSwitch`/`InlineTapLabel`）。
/// 依据是 2026-10-02 的滚动掉帧归因（Debug 与 Release 两个口径同一把尺子）：滚动窗口里
/// **40.5% 的主线程样本栈中有 `PlatformViewHost`/`NSHostingView`**、32.5% 在 `NSView` 布局、
/// 11.9% 在响应者链/命中遍历 —— 代价按"每卡存在多少颗 AppKit 宿主视图"计，而卡片有几十张。
/// 别"顺手改回原生控件"：那等于把这几十颗宿主视图请回来。要改请先复测同一把尺子。
struct SegmentDubControls: View {
    @Binding var isVoiceLocked: Bool
    @Binding var treatment: SubtitleTreatment
    let onApplyMaskToAll: () -> Void
    /// 本分镜自己的烧录字幕字号（逐分镜独立，不是全局设置）
    @Binding var fontRatio: Double
    /// 把当前字号套用到**本视频**的所有分镜（与「遮挡区应用到所有分镜」同作用域）
    let onApplyFontSizeToAll: () -> Void

    /// 就地调整字号的弹层
    @State private var showFontSizePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineSwitch(isOn: isVoiceLocked,
                         label: "保留原声",
                         systemImage: "lock.fill",
                         help: "明星出镜口播等不可替换的镜头，勾选后不参与改写/配音") {
                isVoiceLocked.toggle()
            }

            // 保留原声的分镜不重配也不烧新字幕，字幕处理对其无意义
            if !isVoiceLocked {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "captions.bubble")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)
                        Text("字幕处理")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 5) {
                        ForEach(SubtitleTreatment.allCases) { t in
                            treatmentChip(t)
                        }
                    }
                }
                // ⚠️ tooltip 必须自己说清"在哪一步才看得见"。以前只解释三种模式是什么，
                // 结果用户选完在界面上找不到任何变化，把它当成坏掉的开关报上来 ——
                // 因为这个设置真的**只在配音渲染的导出里**生效，普通混剪导出既不烧字幕也不遮挡。
                .help("""
                      在哪一步生效：所有走配音渲染的导出（方案配音导出、多选→批量导出）。
                      普通混剪导出、单分镜批量导出不处理字幕区。
                      直接烧录=不处理背景直接烧新字幕；模糊虚化=把字幕区域糊掉再烧（不管有没有旧字幕都可用）；纯色遮挡=深色条盖住该区域再烧。
                      卡片上的静止帧就是按这个效果预览的；点播放之后画面是原素材，只剩描边手柄。
                      """)

                if treatment.needsMask {
                    InlineTapLabel(help: "把当前遮挡区套用到本视频的所有分镜",
                                   action: onApplyMaskToAll) {
                        Label("遮挡区应用到所有分镜", systemImage: "square.on.square")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.secondary)
                    }
                }

                // ⚠️ 字幕字号是**本分镜自己的**（不是全局设置）。弹层内容仍每卡一份挂在按钮上，
                // 但它只在展开时才真正建出来 —— 实测 888 次求值合计 6.1ms/20s，不承重。
                // 承重的是按钮本身那颗宿主视图，所以下面换成 `InlineTapLabel`。
                InlineTapLabel(
                    help: "调整这个分镜的字幕烧录字号。需要统一时，可在弹层里应用到本视频所有分镜。",
                    action: { showFontSizePopover = true }
                ) {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "textformat.size")
                            .font(DesignTokens.Typography.micro)
                        Text("字幕字号 \(String(format: "%.1f%%", SubtitleFontSize.clamp(fontRatio) * 100))")
                            .font(DesignTokens.Typography.micro)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                }
                .popover(isPresented: $showFontSizePopover, arrowEdge: .bottom) {
                    SubtitleFontSizePopover(fontRatio: $fontRatio,
                                            isPresented: $showFontSizePopover,
                                            onApplyToAll: onApplyFontSizeToAll)
                }
            }
        }
    }

    /// 字幕处理胶囊选项（选中=主题色填充，未选=浅灰），与卡片标签风格统一
    private func treatmentChip(_ t: SubtitleTreatment) -> some View {
        let on = (t == treatment)
        return Text(t.displayName)
            .font(.system(size: 10, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.1)))
            .contentShape(Capsule())
            .onTapGesture { treatment = t }
    }
}

/// 字幕字号弹层：滑条 + 「应用到本视频所有分镜」。
///
/// ⚠️ 卡片与列表行共用这一份。里面那句作用域说明（"只影响这一个分镜"）和"应用到本视频"
/// 的语义只准有一处定义 —— 抄第二份就会出现"卡上写的作用域与行上写的不一样"。
struct SubtitleFontSizePopover: View {
    @Binding var fontRatio: Double
    @Binding var isPresented: Bool
    let onApplyToAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.compact) {
            Text("字幕字号")
                .font(DesignTokens.Typography.labelEmphasis)
            Text("只影响这一个分镜")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Spacing.compact) {
                Text("小").font(DesignTokens.Typography.micro).foregroundStyle(.tertiary)
                Slider(value: $fontRatio,
                       in: SubtitleFontSize.minRatio...SubtitleFontSize.maxRatio)
                    .frame(width: 180)
                Text("大").font(DesignTokens.Typography.micro).foregroundStyle(.tertiary)
                Text(String(format: "%.1f%%", SubtitleFontSize.clamp(fontRatio) * 100))
                    .font(DesignTokens.Typography.caption)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            Text("拖动时上方画面里的示例字幕会实时变化，可与原视频字幕比大小。")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 300, alignment: .leading)

            Divider()

            Button {
                onApplyToAll()
                isPresented = false
            } label: {
                Label("应用到本视频所有分镜", systemImage: "square.on.square")
            }
            .controlSize(.small)
        }
        .padding(DesignTokens.Spacing.comfortable)
    }
}

// MARK: - 自绘控件（不用 AppKit 宿主视图）

/// 自绘开关，替代 `Toggle(.switch)`。外观对齐 mini 号开关；点击/键盘/读屏三条都得自己接回来，
/// 少一条就是静默的功能缺失（以前原生控件是白送的）。
private struct InlineSwitch: View {
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

/// 自绘按钮，替代 `Button(.plain)`/`Button(.borderless)`。同样接回点击、空格与读屏。
private struct InlineTapLabel<Content: View>: View {
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
