import SwiftUI
import AppKit

struct LogoOverlayPanel: View {
    @Bindable var logoVM: LogoOverlayViewModel
    let project: Project
    let projectVM: ProjectViewModel
    let schemes: [MixScheme]
    let config: ExportConfig

    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                Text("品牌角标")
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("套用褚橙 K 档") {
                    logoVM.applyKPreset()
                    save()
                }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.microRegular)
            }

            Toggle("导出时叠加品牌角标", isOn: enabledBinding)
                .font(DesignTokens.Typography.label)

            HStack(alignment: .top, spacing: DesignTokens.Spacing.generous) {
                VStack(spacing: DesignTokens.Spacing.compact) {
                    slotRow(.topLeft, title: "头像（左上）", range: 0.20...0.70)
                    slotRow(.bottomRight, title: "文字（右下）", range: 0.15...0.50)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                previewCard
            }

            if let warning = logoVM.warning {
                label(warning, icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if let errorText {
                label(errorText, icon: "xmark.octagon.fill", color: .red)
            }
            if logoVM.config.enabled, !logoVM.isReadyForExport {
                label(logoVM.preflightProblem() ?? "品牌角标配置不完整",
                      icon: "exclamationmark.triangle.fill", color: .red)
            }
            if logoVM.previewLayout.overlapsCaptionMask {
                label("角标可能压到字幕遮挡区，请用真帧复核", icon: "text.bubble", color: .orange)
            }

            Text("图片会复制到全局 logo 库并自动裁掉透明边；同一张图跨项目复用。导出时清除元数据。")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .onDisappear { save() }
        .onAppear { logoVM.preparePreview(schemes: schemes, tier: config.resolution) }
        .onChange(of: schemes.map(\.id)) { _, _ in
            logoVM.preparePreview(schemes: schemes, tier: config.resolution)
        }
        .onChange(of: config.resolution) { _, _ in
            logoVM.preparePreview(schemes: schemes, tier: config.resolution)
        }
    }

    // MARK: - 槽位

    private func slotRow(_ anchor: LogoOverlayAnchor,
                         title: String,
                         range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Text(title)
                    .font(DesignTokens.Typography.label)
                Spacer()
                if let layer = logoVM.layer(for: anchor),
                   let image = LogoOverlayAssetStore.nsImage(file: layer.file) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 28)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Text("未选择")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.tertiary)
                }
                Button("选择图片") { pickImage(for: anchor) }
                    .buttonStyle(.borderless)
                    .font(DesignTokens.Typography.microRegular)
                if logoVM.layer(for: anchor) != nil {
                    Button("清除") {
                        logoVM.clear(anchor)
                        save()
                    }
                    .buttonStyle(.borderless)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: DesignTokens.Spacing.normal) {
                Text("宽度")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                Slider(value: widthBinding(anchor), in: range) { editing in
                    if !editing { save() }
                }
                Text("\(Int((logoVM.width(for: anchor) * 100).rounded()))%")
                    .font(DesignTokens.Typography.microRounded)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 预览

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let canvas = previewCanvasForLayout
                let layout = logoVM.previewLayout
                let scale = geo.size.width / CGFloat(canvas.width)
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let thumb = logoVM.previewThumbnailPath.flatMap({ NSImage(contentsOfFile: $0) }) {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    ForEach(Array(layout.items.enumerated()), id: \.offset) { _, item in
                        if let image = LogoOverlayAssetStore.nsImage(file: item.layer.file) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: CGFloat(item.rect.width) * scale,
                                       height: CGFloat(item.rect.height) * scale)
                                .position(x: (CGFloat(item.rect.x) + CGFloat(item.rect.width) / 2) * scale,
                                          y: (CGFloat(item.rect.y) + CGFloat(item.rect.height) / 2) * scale)
                        }
                    }
                    Rectangle()
                        .fill(Color.red.opacity(0.85))
                        .frame(height: 1)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.87)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .aspectRatio(CGFloat(previewCanvasForLayout.width) / CGFloat(previewCanvasForLayout.height),
                         contentMode: .fit)
            .frame(width: 210)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("布局预览 · 其它方案按各自画布缩放；颜色/字幕以真帧为准")
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(width: 210, alignment: .leading)
        }
    }

    // MARK: - 绑定与动作

    private var enabledBinding: Binding<Bool> {
        Binding(get: { logoVM.config.enabled },
                set: { logoVM.setEnabled($0); save() })
    }

    private func widthBinding(_ anchor: LogoOverlayAnchor) -> Binding<Double> {
        Binding(get: { logoVM.width(for: anchor) },
                set: { logoVM.setWidth($0, for: anchor) })
    }

    private func save() {
        logoVM.save(project: project, projectVM: projectVM)
    }

    private func pickImage(for anchor: LogoOverlayAnchor) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png]
        panel.prompt = "选择 PNG"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try logoVM.importImage(url, into: anchor)
                    errorText = nil
                    save()
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func label(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            Image(systemName: icon)
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(color)
            Text(text)
                .font(DesignTokens.Typography.microRegular)
                .foregroundStyle(color)
                .lineLimit(2)
            Spacer()
        }
    }

    // MARK: - 预览几何

    /// 只读 ViewModel 的派生画布；关系遍历已收口在 `preparePreview`（tombstone 守卫）。
    private var previewCanvasForLayout: DeliveryCanvas {
        logoVM.previewCanvas ?? DeliveryCanvas.size(tier: config.resolution,
                                                    sourceMaxWidth: 1080,
                                                    sourceMaxHeight: 1920)
    }
}
