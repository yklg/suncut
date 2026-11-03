import Foundation
import Observation

/// 导出面板的 logo 角标状态：读/写都收口在 ProjectViewModel.setProjectLogoOverlay。
@MainActor
@Observable
final class LogoOverlayViewModel {
    private(set) var config: LogoOverlayConfig = .genericDefault
    private(set) var warning: String?
    private(set) var pixelSizes: [String: (width: Int, height: Int)] = [:]
    private(set) var previewCanvas: DeliveryCanvas?
    private(set) var previewThumbnailPath: String?
    private(set) var previewMask: PixelRect?

    private var slotWidths: [LogoOverlayAnchor: Double] = [.topLeft: 0.20, .bottomRight: 0.30]

    func load(project: Project) {
        config = LogoOverlayCoder.decode(project.logoOverlayRaw) ?? .genericDefault
        warning = nil
        for layer in config.layers {
            slotWidths[layer.anchor] = layer.widthPct
        }
        refreshSizes()
    }

    func refreshSizes() {
        var sizes: [String: (width: Int, height: Int)] = [:]
        for layer in config.layers {
            if let size = LogoOverlayAssetStore.pixelSize(file: layer.file) {
                sizes[layer.file] = size
            }
        }
        pixelSizes = sizes
    }

    /// 预览只在 ViewModel 里读 SwiftData 关系；View 只消费派生标量（tombstone 守卫）。
    func preparePreview(schemes: [MixScheme], tier: DeliveryTier) {
        var maxW = 0, maxH = 0
        var thumb: String?
        var mask: SubtitleMaskRect?
        for scheme in schemes {
            for ss in scheme.orderedSegments {
                guard let seg = ss.segment, let video = seg.video else { continue }
                maxW = max(maxW, video.width)
                maxH = max(maxH, video.height)
                if thumb == nil { thumb = seg.thumbnailPath }
                if mask == nil { mask = seg.maskRect }
            }
        }
        let canvas = DeliveryCanvas.size(tier: tier, sourceMaxWidth: maxW, sourceMaxHeight: maxH)
        previewCanvas = canvas
        previewThumbnailPath = thumb
        previewMask = mask.map {
            PixelRect.from($0, outputWidth: canvas.width, outputHeight: canvas.height)
        }
    }

    var previewLayout: LogoOverlayLayout {
        guard let canvas = previewCanvas else {
            return LogoOverlayLayout(items: [], overlapsCaptionMask: false)
        }
        return LogoOverlayLayout.compute(
            canvasWidth: canvas.width, canvasHeight: canvas.height,
            layers: config.layers, imageSizes: pixelSizes,
            rightMarginPct: config.rightMarginPct,
            bottomMarginPct: config.bottomMarginPct,
            avoidRect: previewMask)
    }

    func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
    }

    func setWidth(_ pct: Double, for anchor: LogoOverlayAnchor) {
        slotWidths[anchor] = pct
        if let index = index(for: anchor) {
            config.layers[index].widthPct = pct
        }
    }

    func applyKPreset() {
        config.rightMarginPct = LogoOverlayPresets.kRightMarginPct
        config.bottomMarginPct = LogoOverlayPresets.kBottomMarginPct
        slotWidths[.topLeft] = LogoOverlayPresets.kTopWidth
        slotWidths[.bottomRight] = LogoOverlayPresets.kBottomWidth
        for index in config.layers.indices {
            config.layers[index].widthPct = config.layers[index].anchor == .topLeft
                ? LogoOverlayPresets.kTopWidth
                : LogoOverlayPresets.kBottomWidth
        }
    }

    func importImage(_ url: URL, into anchor: LogoOverlayAnchor) throws {
        let result = try LogoOverlayAssetStore.importPNG(from: url)
        warning = result.warning
        let layer = LogoOverlayLayer(file: result.file,
                                     widthPct: slotWidths[anchor] ?? 0.20,
                                     anchor: anchor)
        if let index = index(for: anchor) {
            config.layers[index] = layer
        } else {
            config.layers.append(layer)
            config.layers.sort { anchorOrder($0.anchor) < anchorOrder($1.anchor) }
        }
        refreshSizes()
    }

    func clear(_ anchor: LogoOverlayAnchor) {
        config.layers.removeAll { $0.anchor == anchor }
        refreshSizes()
    }

    func layer(for anchor: LogoOverlayAnchor) -> LogoOverlayLayer? {
        config.layers.first { $0.anchor == anchor }
    }

    func width(for anchor: LogoOverlayAnchor) -> Double {
        layer(for: anchor)?.widthPct ?? slotWidths[anchor] ?? 0.20
    }

    func save(project: Project, projectVM: ProjectViewModel) {
        projectVM.setProjectLogoOverlay(raw: LogoOverlayCoder.encode(config), project: project)
    }

    /// 开启但没图/图丢了 → 导出前必须拦住；关闭时永远返回 nil。
    /// 用像素探测代替裸 fileExists，避免新增一处"裸问文件"站点。
    func preflightProblem() -> String? {
        guard config.enabled else { return nil }
        guard !config.layers.isEmpty else { return "品牌角标已开启，但还没选择图片" }
        for layer in config.layers {
            guard LogoOverlayAssetStore.pixelSize(file: layer.file) != nil else {
                return "logo 库里的「\(layer.file)」不见了，请重新选择图片"
            }
        }
        return nil
    }

    var isReadyForExport: Bool { preflightProblem() == nil }

    private func index(for anchor: LogoOverlayAnchor) -> Int? {
        config.layers.firstIndex { $0.anchor == anchor }
    }

    private func anchorOrder(_ anchor: LogoOverlayAnchor) -> Int {
        anchor == .topLeft ? 0 : 1
    }
}
