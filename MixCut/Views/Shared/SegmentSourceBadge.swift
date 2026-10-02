import SwiftUI

/// 素材来源的**唯一**视觉口径（抽屉芯片 / 素材库卡片 badge / 列表行 badge 三处共用）。
/// 业务枚举在 MixCutCore（不能引 SwiftUI），颜色映射放本文件；
/// 新增第五种来源时 SegmentSourceTests S5 会变红，回到这里补色即可。
extension SegmentSource {
    /// 徽章底色（淡）与强调色（深/实）成对使用
    var badgeFill: Color {
        switch self {
        case .selfShot: Color(red: 0.06, green: 0.72, blue: 0.48).opacity(0.12)
        case .curated: Color(red: 1.0, green: 0.49, blue: 0.0).opacity(0.12)
        case .aiGenerated: Color(red: 0.49, green: 0.25, blue: 0.87).opacity(0.12)
        case .unclassified: Color.gray.opacity(0.12)
        }
    }

    var badgeText: Color {
        switch self {
        case .selfShot: Color(red: 0.05, green: 0.55, blue: 0.38)
        case .curated: Color(red: 0.82, green: 0.37, blue: 0.0)
        case .aiGenerated: Color(red: 0.43, green: 0.20, blue: 0.76)
        case .unclassified: .secondary
        }
    }

    /// 芯片上的小圆点颜色（同时也是素材库 FilterChip 的饱和色）
    var dotColor: Color {
        switch self {
        case .selfShot: Color(red: 0.06, green: 0.72, blue: 0.48)
        case .curated: Color(red: 1.0, green: 0.49, blue: 0.0)
        case .aiGenerated: Color(red: 0.49, green: 0.25, blue: 0.87)
        case .unclassified: .gray
        }
    }
}

/// 素材库工具栏的「来源」筛选芯片组（复用 FilterChip 视觉语言）。
/// 横向排列由调用方包进 ScrollView/HStack；选中同一颗再点一次取消（回全部）。
struct SourceFilterChips: View {
    @Binding var filter: SegmentFilter
    let counts: [SegmentSource: Int]
    let onChange: () -> Void

    private static let chipsOrder: [SegmentSource] = [.selfShot, .curated, .aiGenerated, .unclassified]

    var body: some View {
        HStack(spacing: 6) {
            FilterChip(label: "全部来源", color: Color.accentColor,
                       count: counts.values.reduce(0, +),
                       isSelected: filter.source == nil) {
                filter.source = nil
                onChange()
            }
            ForEach(Self.chipsOrder, id: \.rawValue) { source in
                FilterChip(label: source.displayName,
                           color: source.dotColor,
                           count: counts[source] ?? 0,
                           isSelected: filter.source == source) {
                    filter.source = (filter.source == source) ? nil : source
                    onChange()
                }
            }
        }
    }
}

/// 小胶囊来源标签
struct SourceBadge: View {
    let source: SegmentSource

    var body: some View {
        Text(source.displayName)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(source.badgeFill))
            .foregroundStyle(source.badgeText)
            .lineLimit(1)
            .fixedSize()
    }
}
