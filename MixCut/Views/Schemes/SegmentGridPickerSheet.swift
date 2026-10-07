import SwiftUI

/// 分镜网格选择器（横版弹窗）—— 中立、场景驱动：不引用任何向导/方案 ViewModel。
///
/// 复用 SegmentPickerDrawer 的视觉语言（来源芯片/双列卡片），但：
/// - 数据全部由调用方拍平成 GridPickerSegment / GridPickerFilter / 占用映射传入；
/// - 筛选/占用判定走 Core SegmentGridPicker 纯函数；
/// - 选中未占用卡 → onPick；选中被占卡只能点「移到本段」→ onMove（占用语义由调用方收口）。
/// M5 叙事结构人工选片可直接复用本视图。
struct SegmentGridPickerSheet: View {
    /// 标题与统计
    let title: String
    let totalCount: Int
    let tagMatchedCount: Int
    let occupiedCount: Int

    /// 视频分组 / 当前筛选
    let videoGroups: [GridPickerVideoGroup]
    @Binding var filter: GridPickerFilter

    /// 已按 filter 过滤好的网格数据
    let segments: [GridPickerSegment]
    /// segmentID → 占用信息（不含当前段）
    let occupancy: [UUID: GridPickerOccupancy]

    let onClose: () -> Void
    let onPick: (UUID) -> Void
    let onMove: (UUID) -> Void

    /// 移动确认（本视图内部状态）
    @State private var pendingMove: GridPickerOccupancy?
    /// 来源固定四类（与 SegmentPickerDrawer 一致）
    private let sources: [SegmentSource] = [.selfShot, .curated, .aiGenerated, .unclassified]

    private var selectedVideoID: UUID? { filter.videoID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterRows
            Divider()
            grid
        }
        // 统一弹窗尺寸契约：ideal 620 观感与旧 maxHeight 一致，小宿主可收到 420（消除同型跳动隐患）。
        .sheetContainerFrame(minWidth: 760, idealWidth: 760, maxWidth: 760,
                             minHeight: 420, idealHeight: 620)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("把该分镜移到本段？", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        ), presenting: pendingMove) { occ in
            Button("取消", role: .cancel) { pendingMove = nil }
            Button("移到本段") {
                onMove(occ.segmentID)
                pendingMove = nil
            }
        } message: { occ in
            Text("该分镜当前用于第 \(occ.sceneOrder) 段「\(occ.sceneTag)」。移动后第 \(occ.sceneOrder) 段将回退为未匹配，需要重新选择分镜。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DesignTokens.Typography.bodyEmphasis)
                Text("共 \(totalCount) 个分镜 · 标签匹配 \(tagMatchedCount) 个 · 其他段落已用 \(occupiedCount) 个")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
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

    // MARK: 筛选两行

    private var filterRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Text("视频").font(DesignTokens.Typography.micro).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip(title: "全部 \(totalCount)", on: filter.videoID == nil) {
                            filter.videoID = nil
                        }
                        ForEach(videoGroups) { g in
                            chip(title: "\(g.name) \(g.count)", on: filter.videoID == g.id) {
                                filter.videoID = g.id
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            HStack(spacing: 9) {
                Text("来源").font(DesignTokens.Typography.micro).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
                HStack(spacing: 6) {
                    chip(title: "全部", on: filter.sourceRaw == nil) { filter.sourceRaw = nil }
                    ForEach(sources, id: \.rawValue) { src in
                        chip(title: src.displayName, on: filter.sourceRaw == src.rawValue) {
                            filter.sourceRaw = src.rawValue
                        }
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
                    TextField("搜索台词", text: Binding(
                        get: { filter.searchText },
                        set: { filter.searchText = $0 }))
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.label)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func chip(title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.10)))
                .foregroundStyle(on ? Color.white : Color.primary)
                .fontWeight(on ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }

    // MARK: 网格

    private var grid: some View {
        ScrollView {
            if segments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
                    Text("没有匹配的分镜").font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 11), count: 4),
                          spacing: 11) {
                    ForEach(segments) { seg in
                        PickerGridCard(
                            segment: seg,
                            occupancy: occupancy[seg.id],
                            onPick: { onPick(seg.id) },
                            onMove: { if let occ = occupancy[seg.id] { pendingMove = occ } })
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 选择器单卡：缩略图（左下视频名·seg）+ 标签 + 台词两行 + 时长/来源；
/// 被占用时半透明、禁点，仅「移到本段」可触发。
private struct PickerGridCard: View {
    let segment: GridPickerSegment
    let occupancy: GridPickerOccupancy?
    let onPick: () -> Void
    let onMove: () -> Void

    var body: some View {
        let occupied = occupancy != nil
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                AsyncCachedImage(
                    path: segment.thumbnailPath,
                    placeholder: {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
                    },
                    imageContent: { img in Image(nsImage: img).resizable().scaledToFill() }
                )
                .frame(height: 118)
                .frame(maxWidth: .infinity)
                .clipped()

                if let occ = occupancy {
                    ZStack {
                        Rectangle().fill(.black.opacity(0.28))
                        VStack(spacing: 6) {
                            Label("已用于第 \(occ.sceneOrder) 段", systemImage: "nosign")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.95)))
                                .foregroundStyle(.white)
                            Button("移到本段", action: onMove)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .font(.system(size: 10.5))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // 标签（纯值字符串，经 SemanticType 着色）
                HStack(spacing: 3) {
                    ForEach(Array(segment.tagNames.prefix(2)), id: \.self) { name in
                        tagPill(name)
                    }
                }
                Text(segment.text)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(String(format: "%.1fs", segment.duration))
                        .font(DesignTokens.Typography.microMono)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    SourceRawBadge(raw: segment.sourceRaw)
                }
            }
            .padding(7)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(occupied ? 0.18 : 0.12)))
        .opacity(occupied ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !occupied { onPick() } }
        .help(occupied
              ? "已用于第 \(occupancy?.sceneOrder ?? 0) 段「\(occupancy?.sceneTag ?? "")」"
              : segment.text)
        // 左下角视频名·seg（覆盖在缩略图上）
        .overlay(alignment: .bottomLeading) {
            Text("\(segment.videoName) · \(segment.segmentIndex)")
                .font(.system(size: 9))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    /// 纯值标签着色（SemanticType rawValue → 色，未知灰色）。
    @ViewBuilder
    private func tagPill(_ raw: String) -> some View {
        let type = SemanticType(rawValue: raw)
        Text(raw)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tagColor(type)))
            .foregroundStyle(.white)
    }

    /// SemanticType.colorName → NSColor（App target；与 NarrativeStructureEditor 同口径）。
    private func tagColor(_ type: SemanticType?) -> Color {
        guard let name = type?.colorName else { return .gray }
        let ns: NSColor
        switch name {
        case "red": ns = .systemRed
        case "orange": ns = .systemOrange
        case "blue": ns = .systemBlue
        case "green": ns = .systemGreen
        case "purple": ns = .systemPurple
        case "yellow": ns = .systemYellow
        case "pink": ns = .systemPink
        case "mint": ns = .systemMint
        case "teal": ns = .systemTeal
        case "indigo": ns = .systemIndigo
        default: ns = .systemGray
        }
        return Color(nsColor: ns)
    }
}

/// 来源 raw → 小角标（与 SegmentPickerDrawer 的 SourceBadge 同视觉）。
private struct SourceRawBadge: View {
    let raw: String
    var body: some View {
        let src = SegmentSource(persisted: raw)
        Text(src.displayName)
            .font(.system(size: 9.5))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(src.dotColor.opacity(0.12))
            .foregroundStyle(src.dotColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
