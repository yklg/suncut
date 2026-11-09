import Testing
import CoreGraphics
@testable import MixCutCore

@Suite("SubtitleMaskPreviewPlan")
struct SubtitleMaskPreviewPlanTests {
    private func make(_ w: Double, _ h: Double,
                      mode: SubtitleMaskMode = .blur,
                      mask: SubtitleMaskRect = .defaultBottomBand,
                      maxShortSide: Int = SubtitleMaskPreviewPlan.defaultMaxShortSide)
        -> SubtitleMaskPreviewPlan? {
        SubtitleMaskPreviewPlan.make(sourceSize: CGSize(width: w, height: h),
                                     maskRect: mask, mode: mode,
                                     maxShortSide: maxShortSide)
    }

    @Test("四种源比例：画布恒 9:16、偶数、不放大",
          arguments: [(1080.0, 1920.0), (1920.0, 1080.0),
                      (1000.0, 1000.0), (1080.0, 1440.0),
                      (480.0, 854.0), (481.0, 855.0)])
    func canvasIsAlways9x16(w: Double, h: Double) throws {
        let p = try #require(make(w, h))
        #expect(p.canvasWidth % 2 == 0 && p.canvasHeight % 2 == 0)
        let ratio = Double(p.canvasWidth) / Double(p.canvasHeight)
        #expect(abs(ratio - 9.0 / 16.0) < 0.01, "画布不是 9:16：\(p.canvasWidth)×\(p.canvasHeight)")
        #expect(p.canvasWidth <= Int(min(w, h).rounded(.down)),
                "画布短边不能超过源短边（不许放大）：源 \(w)×\(h) → 画布 \(p.canvasWidth)×\(p.canvasHeight)")
    }

    @Test("横屏源：fit 后居中，上下黑边对称")
    func landscapeIsCentered() throws {
        let p = try #require(make(1920, 1080))
        let r = p.sourceRectInCanvas
        #expect(abs(r.width - 540) < 0.001)
        #expect(abs(r.height - 303.75) < 0.001)
        #expect(abs(r.minX) < 0.001)
        #expect(abs(r.minY - (960.0 - 303.75) / 2) < 0.001)
    }

    @Test("超高源：fit 后居中，左右黑边对称")
    func tallSourceIsCentered() throws {
        let p = try #require(make(1080, 2400))
        let r = p.sourceRectInCanvas
        #expect(abs(r.width - 432) < 0.001)
        #expect(abs(r.height - 960) < 0.001)
        #expect(abs(r.minX - 54) < 0.001)
        #expect(abs(r.minY) < 0.001)
    }

    @Test("遮挡矩形与导出共用 PixelRect.from")
    func maskRectMatchesPixelRect() throws {
        let rects = [
            SubtitleMaskRect.defaultBottomBand,
            SubtitleMaskRect(x: 0.2, y: 0.8, width: 0.5, height: 0.12),
            SubtitleMaskRect(x: 0, y: 0, width: 1, height: 1),
        ]
        for rect in rects {
            let p = try #require(make(1080, 1920, mask: rect))
            #expect(p.maskPixelRect == PixelRect.from(rect,
                                                     outputWidth: p.canvasWidth,
                                                     outputHeight: p.canvasHeight))
            #expect(p.maskPixelRect.x >= 0 && p.maskPixelRect.y >= 0)
            #expect(p.maskPixelRect.x + p.maskPixelRect.width <= p.canvasWidth)
            #expect(p.maskPixelRect.y + p.maskPixelRect.height <= p.canvasHeight)
        }
    }

    @Test("半径只来自 scaledBlurRadius：1080 基准下 540 画布 = 10")
    func blurRadiusMatchesSharedHelper() throws {
        let p = try #require(make(1080, 1920))
        let expected = SubtitleMaskMode.blur.scaledBlurRadius(
            canvasWidth: CGFloat(p.canvasWidth),
            cropWidth: CGFloat(p.maskPixelRect.width),
            cropHeight: CGFloat(p.maskPixelRect.height))
        #expect(abs(p.blurRadius - Double(expected)) < 1e-9)
        #expect(abs(p.blurRadius - 10) < 1e-9, "20 × 540/1080 应为 10，实得 \(p.blurRadius)")
    }

    @Test("矮带按裁面高度钳位（4.75 而不是 10）")
    func shortBandClampedByHeight() throws {
        let mask = SubtitleMaskRect(x: 0, y: 0.9, width: 1, height: 0.02)
        let p = try #require(make(1080, 1920, mask: mask))
        #expect(abs(p.blurRadius - 4.75) < 1e-9,
                "0.02 × 960 = 19.2 → 19px，19/4 = 4.75，实得 \(p.blurRadius)")
    }

    @Test("窄带按裁面宽度钳位（5.5 而不是 10）")
    func narrowBandClampedByWidth() throws {
        let mask = SubtitleMaskRect(x: 0.48, y: 0.8, width: 0.04, height: 0.12)
        let p = try #require(make(1080, 1920, mask: mask))
        #expect(abs(p.blurRadius - 5.5) < 1e-9,
                "0.04 × 540 = 21.6 → 22px，22/4 = 5.5，实得 \(p.blurRadius)")
    }

    @Test("非 blur 档半径为 0；none 档保留 passthrough 语义")
    func nonBlurModesHaveZeroRadius() throws {
        for mode in [SubtitleMaskMode.none, .solid, .dim] {
            let p = try #require(make(1080, 1920, mode: mode))
            #expect(p.blurRadius == 0, "\(mode) 不该有糊半径")
        }
        let none = try #require(make(1080, 1920, mode: .none))
        #expect(none.renderSpec == .passthrough)
    }

    @Test("4K 源封顶到 540 短边；不按原尺寸逐帧处理")
    func fourKSourceIsCapped() throws {
        let p = try #require(make(3840, 2160))
        #expect(p.canvasWidth == 540 && p.canvasHeight == 960)
    }

    @Test("非法源尺寸 / 非法上限返回 nil，不产出 0 画布")
    func invalidInputsReturnNil() {
        #expect(make(0, 1920) == nil)
        #expect(make(1080, -1) == nil)
        #expect(make(1080, 1920, maxShortSide: 0) == nil)
        #expect(SubtitleMaskPreviewPlan.make(sourceSize: CGSize(width: CGFloat.nan, height: 100),
                                             maskRect: .defaultBottomBand,
                                             mode: .blur) == nil)
    }
}