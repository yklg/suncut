import Foundation

/// 硬字幕遮挡矩形，归一化坐标（0~1，原点左上），与分辨率无关。
public struct SubtitleMaskRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 9:16 竖屏常见底部字幕带
    public static let defaultBottomBand = SubtitleMaskRect(x: 0.0, y: 0.80, width: 1.0, height: 0.12)

    /// 与字号无关的绝对下限，避免拖塌缩成 0（宽度一直用它；高度只作为兜底，见 `minimumHeight`）
    public static let minSize = 0.02

    /// 遮挡带的**最小高度**（归一化），跟着**该分镜自己的字号**算，而不是钉一个死常量。
    ///
    /// 为什么要有这条：下限原本是死的 0.02（1080×1920 上 38px），而同一档字号烧出来的字幕块
    /// 在 1920 高上就有 ~119px ⇒ 用户完全能把带拖到"盖不住字幕"。那种盖子在卡片上看是
    /// "已经开了纯色遮挡"，导出出来原字幕还在、只是底下多了条矮黑条 —— 中间没有任何提示。
    ///
    /// 尺子读 `CaptionRenderer.singleLineBlockHeight`，与导出侧渲染字幕 PNG 是**同一处定义**
    /// （留白常量、行高系数都在那边），所以这不是第二份真相；两者的关系由
    /// `SubtitleMaskRectTests.captionFloorTracksRenderedCaption` 钉住。
    ///
    /// 按 1080×1920 基准换算：字号是"相对**画面宽**的比例"，块高随宽走，而归一化除的是**高**，
    /// 所以必须固定一个基准比例，否则同一个字号在 4:3 与 9:16 上会算出不同的下限。
    ///
    /// ⚠️ 这条下限**不**替代 `SubtitleMaskRenderSpec.clampedRadius`：窄成片（如 480 宽）上字幕块
    /// 只有 73px，仍低于 boxblur 要求的 80px 短边，那条钳位还在。
    public static func minimumHeight(fontRatio: Double,
                                     canonicalWidth: Int = 1080,
                                     canonicalHeight: Int = 1920) -> Double {
        guard canonicalWidth > 0, canonicalHeight > 0 else { return minSize }
        let fontSize = CGFloat(Double(canonicalWidth) * fontRatio)
        let block = Double(CaptionRenderer.singleLineBlockHeight(fontSize: fontSize))
        return min(max(block / Double(canonicalHeight), minSize), 1.0)
    }

    /// 把矩形钳制进 [0,1] 画面，并保证不出界、不塌缩。
    /// `minHeight` 是**高度**下限（默认只有绝对下限）；需要"盖得住本分镜字幕"时传
    /// `minimumHeight(fontRatio:)`，写入侧的调用者（`Segment.maskRect`）就是这么做，
    /// 这样拖拽、MCP、"应用到本视频所有分镜"、撤销四条写路径共用同一个闸口。
    public func clamped(minHeight: Double = minSize) -> SubtitleMaskRect {
        let w = min(max(width, Self.minSize), 1.0)
        let h = min(max(height, min(max(minHeight, Self.minSize), 1.0)), 1.0)
        let cx = min(max(x, 0.0), 1.0 - w)
        let cy = min(max(y, 0.0), 1.0 - h)
        return SubtitleMaskRect(x: cx, y: cy, width: w, height: h)
    }

    /// 上下平移后钳制
    public func movedBy(dy: Double, minHeight: Double = minSize) -> SubtitleMaskRect {
        SubtitleMaskRect(x: x, y: y + dy, width: width, height: height).clamped(minHeight: minHeight)
    }

    /// 改高度后钳制（底边不出界）
    public func resizedBy(dHeight: Double, minHeight: Double = minSize) -> SubtitleMaskRect {
        SubtitleMaskRect(x: x, y: y, width: width, height: height + dHeight).clamped(minHeight: minHeight)
    }

    /// 换算成像素矩形
    public func pixelRect(width pxW: Double, height pxH: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        (x * pxW, y * pxH, width * pxW, height * pxH)
    }
}
