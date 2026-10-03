// MixCut/Views/SegmentLibrary/SubtitleFontSizePopover.swift
//
// 字幕字号弹层：滑条 + 「应用到本视频所有分镜」。
// 由 SegmentPropertiesSection 的字幕分区弹出；卡片与列表共用此唯一弹层。
import SwiftUI

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
