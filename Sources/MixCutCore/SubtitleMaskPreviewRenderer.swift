import Foundation
import CoreGraphics
import CoreImage

/// 播放态遮挡预览的 Core Image 渲线：方向归一 → fit+pad 到 9:16 画布 → 套遮挡。
///
/// 语义全部来自 `SubtitleMaskRenderSpec` / `SubtitleMaskPreviewPlan`，这里只做像素运算：
/// 颜色、半径、落位都不在本文里另算。导出侧由 ffmpeg 承担同一语义（`DubSegmentGraphBuilder`）。
public enum SubtitleMaskPreviewRenderer {

    /// 把 AVFoundation 的 `preferredTransform` 应用到 CIImage。
    ///
    /// AVFoundation 的变换定义在**左上原点、y 向下**的帧坐标；CI 是左下原点、y 向上。
    /// 用垂直翻转做共轭：`ciT = F ∘ T ∘ F`（F 是 y 翻转，且 F⁻¹ = F）。
    /// 结果 extent 归一到 (0,0)，下游 fit 不需要再处理负原点。
    public static func oriented(_ image: CIImage,
                                preferredTransform: CGAffineTransform,
                                naturalSize: CGSize) -> CIImage {
        let origin = image.extent.origin
        let base = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let h = naturalSize.height
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let ciTransform = flip
            .concatenating(preferredTransform)
            .concatenating(flip.inverted())
        let transformed = base.transformed(by: ciTransform)
        let extent = transformed.extent
        return transformed.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// 源画面 aspect-fit 进 9:16 画布，空处填黑（与导出的 `scale + pad` 同序）。
    public static func canvasImage(from source: CIImage,
                                   plan: SubtitleMaskPreviewPlan) -> CIImage {
        let canvasRect = CGRect(x: 0, y: 0,
                                width: plan.canvasWidth, height: plan.canvasHeight)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: canvasRect)
        let extent = source.extent
        let target = plan.sourceRectInCanvas
        guard extent.width > 0, extent.height > 0,
              target.width > 0, target.height > 0 else { return black }

        let normalized = source.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: target.width / extent.width,
                                  y: target.height / extent.height))
        // sourceRectInCanvas 是左上原点；CI 是左下原点 ⇒ 这里翻一次 y。
        let ciY = CGFloat(plan.canvasHeight) - target.origin.y - target.height
        let placed = scaled.transformed(
            by: CGAffineTransform(translationX: target.origin.x, y: ciY))
        return placed.composited(over: black).cropped(to: canvasRect)
    }

    /// 在画布上套遮挡。模糊沿用导出"裁出带内 → 糊 → 贴回"的顺序。
    public static func applyMask(to canvas: CIImage,
                                 plan: SubtitleMaskPreviewPlan) -> CIImage {
        let canvasRect = CGRect(x: 0, y: 0,
                                width: plan.canvasWidth, height: plan.canvasHeight)
        let mask = plan.maskPixelRect
        let ciRect = CGRect(x: CGFloat(mask.x),
                            y: CGFloat(plan.canvasHeight - mask.y - mask.height),
                            width: CGFloat(mask.width),
                            height: CGFloat(mask.height))
        switch plan.renderSpec {
        case .passthrough:
            return canvas

        case .fill(let hex, let alpha):
            let fill = CIImage(color: ciColor(hex: hex, alpha: alpha)).cropped(to: ciRect)
            return fill.composited(over: canvas).cropped(to: canvasRect)

        case .blur(_, _):
            guard plan.blurRadius > 0 else { return canvas }
            // 先 clampedToExtent 再糊：否则带的上下沿会吃到 CI 的边缘复制，出现一条假毛边。
            let blurred = canvas.cropped(to: ciRect)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: plan.blurRadius])
                .cropped(to: ciRect)
            return blurred.composited(over: canvas).cropped(to: canvasRect)
        }
    }

    public static func render(source: CIImage,
                              plan: SubtitleMaskPreviewPlan) -> CIImage {
        applyMask(to: canvasImage(from: source, plan: plan), plan: plan)
    }

    /// 表里的 hex 是 ffmpeg `drawbox` 的取值口径（6 位，无 #）。解析失败退回黑底同 alpha ——
    /// 与 SwiftUI 预览的 `maskFillColor` 同一降级方向：错得看得见，不静默画成另一种颜色。
    private static func ciColor(hex: String, alpha: Double) -> CIColor {
        guard hex.count == 6, let packed = UInt32(hex, radix: 16) else {
            return CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(alpha))
        }
        return CIColor(red: CGFloat((packed >> 16) & 0xFF) / 255.0,
                       green: CGFloat((packed >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(packed & 0xFF) / 255.0,
                       alpha: CGFloat(alpha))
    }
}