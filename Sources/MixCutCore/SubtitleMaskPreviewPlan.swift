import Foundation
import CoreGraphics

/// 播放态遮挡预览的几何计划（纯值，不依赖 AVFoundation）。
///
/// 与导出同序：源画面先按 `preferredTransform` 摆正，再 aspect-fit + 居中 pad 到 9:16 画布，
/// 最后在画布像素空间套 `maskPixelRect` —— 与 ffmpeg 的
/// `scale=…:force_original_aspect_ratio=decrease,pad=…` 同一条链。
///
/// 落位共用 `PixelRect.from` 的取整规则；半径共用 `SubtitleMaskMode.scaledBlurRadius`。
/// 这两句是"预览 = 导出"的结构性保证，不要在别处再写一份。
public struct SubtitleMaskPreviewPlan: Equatable, Sendable {
    /// 恒 9:16；短边 = min(源短边, 上限) 且取偶（不放大）。
    public let canvasWidth: Int
    public let canvasHeight: Int
    /// 已按 `preferredTransform` 摆正后的源尺寸。
    public let sourceSize: CGSize
    /// 画布像素、左上原点 —— 与导出滤镜串的 `crop/drawbox` 同一空间。
    public let maskPixelRect: PixelRect
    /// 画布像素；非 blur 档为 0。
    public let blurRadius: Double
    public let renderSpec: SubtitleMaskRenderSpec

    /// 540 短边 ≈ 卡片 200pt @2x 的 1.35 倍，够锐且把 CI 每帧成本压在 0.5MP 级。
    public static let defaultMaxShortSide = 540

    /// 源画面在画布里的落位（左上原点，画布像素）。
    /// 导出是 fit + 居中 pad，这里同一公式；渲染器与测试都读它，避免第二份 fit 计算。
    public var sourceRectInCanvas: CGRect {
        let sw = sourceSize.width, sh = sourceSize.height
        guard sw > 0, sh > 0, canvasWidth > 0, canvasHeight > 0 else { return .zero }
        let scale = min(CGFloat(canvasWidth) / sw, CGFloat(canvasHeight) / sh)
        let w = sw * scale
        let h = sh * scale
        return CGRect(x: (CGFloat(canvasWidth) - w) / 2,
                      y: (CGFloat(canvasHeight) - h) / 2,
                      width: w, height: h)
    }

    /// - Returns: 源尺寸非法（0 / 负数 / 非有限）或上限 < 2 时返回 nil，由调用方决定降级方式。
    public static func make(sourceSize: CGSize,
                            maskRect: SubtitleMaskRect,
                            mode: SubtitleMaskMode,
                            maxShortSide: Int = defaultMaxShortSide) -> SubtitleMaskPreviewPlan? {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              maxShortSide >= 2 else { return nil }

        // 短边向下取偶：奇数源不把一列像素丢到画布外；上限封顶避免 4K 源逐帧处理。
        let rawShort = min(Int(min(sourceSize.width, sourceSize.height).rounded(.down)),
                           maxShortSide)
        let short = max(2, rawShort - (rawShort % 2))
        let rawLong = Int((Double(short) * 16.0 / 9.0).rounded())
        let long = max(2, rawLong + (rawLong % 2))

        let mask = PixelRect.from(maskRect, outputWidth: short, outputHeight: long)
        let radius = mode.scaledBlurRadius(canvasWidth: CGFloat(short),
                                           cropWidth: CGFloat(mask.width),
                                           cropHeight: CGFloat(mask.height))
        return SubtitleMaskPreviewPlan(canvasWidth: short, canvasHeight: long,
                                       sourceSize: sourceSize,
                                       maskPixelRect: mask,
                                       blurRadius: Double(radius),
                                       renderSpec: mode.renderSpec)
    }
}