import Foundation

public enum LogoOverlayAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft
    case bottomRight
}

public struct LogoOverlayLayer: Codable, Equatable, Sendable {
    /// 全局 logo 库里的文件名（内容哈希）；只允许 basename，防止配置串把路径带出库目录。
    public var file: String
    /// 可见宽 / 画布宽。图片入库前已裁掉透明边，所以这里量的是墨迹宽度。
    public var widthPct: Double
    public var anchor: LogoOverlayAnchor

    public init(file: String, widthPct: Double, anchor: LogoOverlayAnchor) {
        self.file = file
        self.widthPct = widthPct
        self.anchor = anchor
    }
}

public struct LogoOverlayConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxLayers = 2

    public var version: Int
    public var enabled: Bool
    public var layers: [LogoOverlayLayer]
    public var rightMarginPct: Double
    public var bottomMarginPct: Double

    public init(version: Int = LogoOverlayConfig.currentVersion,
                enabled: Bool = false,
                layers: [LogoOverlayLayer] = [],
                rightMarginPct: Double = 0.026,
                bottomMarginPct: Double = 0.13) {
        self.version = version
        self.enabled = enabled
        self.layers = layers
        self.rightMarginPct = rightMarginPct
        self.bottomMarginPct = bottomMarginPct
    }

    public static let genericDefault = LogoOverlayConfig()

    private struct RawLayer: Decodable {
        let file: String?
        let widthPct: Double?
        let anchor: String?
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabled, layers, rightMarginPct, bottomMarginPct
    }

    /// 逐键 decodeIfPresent：未来加字段时旧配置不会整份变 nil；
    /// 单层坏数据只丢那一层，不连坐整份配置。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let rawLayers = try c.decodeIfPresent([RawLayer].self, forKey: .layers) ?? []
        layers = rawLayers.compactMap { raw in
            guard let file = raw.file,
                  let widthPct = raw.widthPct,
                  let anchorRaw = raw.anchor,
                  let anchor = LogoOverlayAnchor(rawValue: anchorRaw) else { return nil }
            return LogoOverlayLayer(file: file, widthPct: widthPct, anchor: anchor)
        }
        rightMarginPct = try c.decodeIfPresent(Double.self, forKey: .rightMarginPct) ?? 0.026
        bottomMarginPct = try c.decodeIfPresent(Double.self, forKey: .bottomMarginPct) ?? 0.13
    }

    /// 钳制到可执行范围；未知 anchor / 不安全文件名在解码阶段已丢，这里再兜一次。
    public func normalized() -> LogoOverlayConfig {
        var copy = self
        copy.version = Self.currentVersion
        copy.layers = Array(layers.prefix(Self.maxLayers)).compactMap { layer in
            guard Self.isSafeFileName(layer.file),
                  layer.widthPct.isFinite,
                  layer.widthPct > 0 else { return nil }
            var l = layer
            l.widthPct = min(max(l.widthPct, 0.01), 1.0)
            return l
        }
        copy.rightMarginPct = min(max(rightMarginPct.isFinite ? rightMarginPct : 0.026, 0), 0.5)
        copy.bottomMarginPct = min(max(bottomMarginPct.isFinite ? bottomMarginPct : 0.13, 0), 0.5)
        return copy
    }

    public static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

public enum LogoOverlayCoder {
    public static func decode(_ raw: String?) -> LogoOverlayConfig? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let decoded = try? JSONDecoder().decode(LogoOverlayConfig.self, from: data) else { return nil }
        guard decoded.version == LogoOverlayConfig.currentVersion else { return nil }
        return decoded.normalized()
    }

    public static func encode(_ config: LogoOverlayConfig) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config.normalized()) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// RGBA 字节里的 alpha 墨迹包围盒。全透明返回 nil；阈值是严格大于。
public enum AlphaBounds {
    public static func boundingBox(width: Int,
                                   height: Int,
                                   rgba: [UInt8],
                                   alphaThreshold: UInt8 = 16) -> PixelRect? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                if rgba[row + x * 4 + 3] > alphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

public struct LogoOverlayLayout: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let layer: LogoOverlayLayer
        public let rect: PixelRect
    }

    public let items: [Item]
    public let overlapsCaptionMask: Bool

    public init(items: [Item], overlapsCaptionMask: Bool) {
        self.items = items
        self.overlapsCaptionMask = overlapsCaptionMask
    }

    /// 纯几何：预览与导出共用同一份矩形。坐标是数值，不用 `W-w/H-h` 表达式。
    public static func compute(canvasWidth: Int,
                               canvasHeight: Int,
                               layers: [LogoOverlayLayer],
                               imageSizes: [String: (width: Int, height: Int)],
                               rightMarginPct: Double = 0.026,
                               bottomMarginPct: Double = 0.13,
                               avoidRect: PixelRect? = nil) -> LogoOverlayLayout {
        guard canvasWidth > 0, canvasHeight > 0 else {
            return LogoOverlayLayout(items: [], overlapsCaptionMask: false)
        }
        let right = max(0, Int((Double(canvasWidth) * rightMarginPct).rounded()))
        let bottom = max(0, Int((Double(canvasHeight) * bottomMarginPct).rounded()))
        var items: [Item] = []
        var overlaps = false

        for layer in layers.prefix(LogoOverlayConfig.maxLayers) {
            guard let size = imageSizes[layer.file], size.width > 0, size.height > 0 else { continue }
            var w = max(2, Int((Double(canvasWidth) * layer.widthPct).rounded()))
            if w % 2 != 0 { w += 1 }
            w = min(w, canvasWidth)
            var h = max(2, Int((Double(w) * Double(size.height) / Double(size.width)).rounded()))
            if h % 2 != 0 { h += 1 }
            h = min(h, canvasHeight)

            let x = layer.anchor == .bottomRight ? max(0, canvasWidth - w - right) : 0
            let y = layer.anchor == .bottomRight ? max(0, canvasHeight - h - bottom) : 0
            let rect = PixelRect(x: x, y: y, width: w, height: h)
            if let avoidRect, intersects(rect, avoidRect) { overlaps = true }
            items.append(Item(layer: layer, rect: rect))
        }
        return LogoOverlayLayout(items: items, overlapsCaptionMask: overlaps)
    }

    private static func intersects(_ a: PixelRect, _ b: PixelRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width
            && a.y < b.y + b.height && b.y < a.y + a.height
    }
}

public struct LogoOverlayStage: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public let inputIndex: Int
        public let rect: PixelRect

        public init(inputIndex: Int, rect: PixelRect) {
            self.inputIndex = inputIndex
            self.rect = rect
        }
    }

    public let layers: [Layer]

    public init(layers: [Layer]) {
        self.layers = layers
    }
}

public enum LogoOverlayGraph {
    /// 把 logo 链接在既有视频链之后；最终标签仍由调用方指定（`DubSegmentGraph` 恒为 vout）。
    @discardableResult
    public static func append(to parts: inout [String],
                              stage: LogoOverlayStage,
                              from inputLabel: String,
                              to outputLabel: String) -> String {
        guard !stage.layers.isEmpty else { return inputLabel }
        var previous = inputLabel
        for (i, layer) in stage.layers.enumerated() {
            let logoLabel = "logo\(i)"
            let next = (i == stage.layers.count - 1) ? outputLabel : "logoStep\(i)"
            parts.append(
                "[\(layer.inputIndex):v]format=rgba," +
                "scale=\(layer.rect.width):\(layer.rect.height):flags=lanczos," +
                "setsar=1[\(logoLabel)]"
            )
            parts.append("[\(previous)][\(logoLabel)]overlay=\(layer.rect.x):\(layer.rect.y)[\(next)]")
            previous = next
        }
        return outputLabel
    }
}
