import SwiftUI

/// 紧凑分镜卡片（用于抽屉/选择器场景）
/// 包含缩略图、语义类型标签、台词预览、时长
struct SegmentCardCompact: View {
    let segment: Segment
    let isDisabled: Bool          // true 时整卡片置灰禁用
    let disabledReason: String?   // 置灰原因 tooltip
    let onTap: () -> Void

    @State private var isHovering = false

    private let cardWidth: CGFloat = 140
    // 信息流广告 9:16 手机端比例（见 CLAUDE.md）
    private var imageHeight: CGFloat { cardWidth * 16.0 / 9.0 }

    var body: some View {
        Button(action: { if !isDisabled { onTap() } }) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                ZStack(alignment: .topLeading) {
                    thumbnail
                    if isDisabled {
                        Image(systemName: "nosign")
                            .font(DesignTokens.Typography.bodyLarge)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                            .padding(4)
                    }
                }
                .frame(width: cardWidth, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                semanticTags

                Text(segment.text.isEmpty ? "—" : segment.text)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)

                Text(String(format: "%.1fs", segment.duration))
                    .font(DesignTokens.Typography.microMono)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: cardWidth)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering && !isDisabled
                          ? Color(.controlBackgroundColor).opacity(0.95)
                          : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.secondary.opacity(isHovering ? 0.18 : 0.06), lineWidth: 1)
            )
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            if !isDisabled {
                isHovering = hovering
            }
        }
        .help(isDisabled ? (disabledReason ?? "已禁用") : segment.text)
    }

    /// 语义类型标签行（semanticTypes 只解码一次，避免同一卡片 body 内 3 次 JSON 解码）
    ///
    /// ⚠️ 用 `FlowLayout` 而不是裸 `HStack`：窄容器里 HStack 压的是柔性 Text，中文会变成一字一行的竖排
    /// （素材库列表行就是这么坏的，见 `SegmentLibraryView` 的标签行注释）。这里只放 2 颗标签，
    /// 今天量不出问题，但契约要一致 —— 否则守卫只能靠"我记得每一处"。
    private var semanticTags: some View {
        let types = segment.semanticTypes
        return FlowLayout(spacing: 3) {
            ForEach(Array(types.prefix(2)), id: \.self) { type in
                SemanticTypeTag(type: type)
            }
            if types.count > 2 {
                Text("+\(types.count - 2)")
                    .font(DesignTokens.Typography.microRegular)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        // 异步缩略图：命中缓存直出；未命中后台降采样解码、淡入（见 AsyncCachedImage 契约）。
        AsyncCachedImage(
            path: segment.effectivePicture.thumbnailPath,
            placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    )
            },
            imageContent: { image in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        )
    }
}
