import Testing
import CoreGraphics
import CoreImage
@testable import MixCutCore

@Suite("SubtitleMaskPreviewRenderer")
struct SubtitleMaskPreviewRendererTests {
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    private func plan(_ w: Double, _ h: Double,
                      mask: SubtitleMaskRect = .defaultBottomBand,
                      mode: SubtitleMaskMode,
                      maxShortSide: Int = 1080) throws -> SubtitleMaskPreviewPlan {
        try #require(SubtitleMaskPreviewPlan.make(
            sourceSize: CGSize(width: w, height: h),
            maskRect: mask, mode: mode, maxShortSide: maxShortSide))
    }

    private func cgImage(_ image: CIImage) throws -> CGImage {
        try #require(Self.context.createCGImage(image, from: image.extent))
    }

    /// 取 CGImage 的一个像素（左上原点，与 `maskPixelRect` 同一坐标习惯）。
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> (r: Int, g: Int, b: Int) {
        let crop = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { raw in
            let ctx = try #require(CGContext(
                data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func assertColor(_ got: (r: Int, g: Int, b: Int),
                             _ want: (r: Int, g: Int, b: Int),
                             tolerance: Int = 3,
                             _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(got.r - want.r) <= tolerance
                && abs(got.g - want.g) <= tolerance
                && abs(got.b - want.b) <= tolerance,
                "\(label)：期望 \(want)，实得 \(got)", sourceLocation: sourceLocation)
    }

    private func solidSource(_ w: Double, _ h: Double,
                             color: CIColor = CIColor(red: 1, green: 0, blue: 0, alpha: 1)) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    // MARK: - solid / dim

    @Test("solid：带内 1A1A1A、带外原色，四条边界各验一点")
    func solidCoversOnlyTheBand() throws {
        let p = try plan(1080, 1920, mode: .solid)
        // 1080×1920 画布上默认带：y=1536、高 230
        #expect(p.maskPixelRect == PixelRect(x: 0, y: 1536, width: 1080, height: 230))
        let out = try cgImage(SubtitleMaskPreviewRenderer.render(
            source: solidSource(1080, 1920), plan: p))
        let ink = (r: 26, g: 26, b: 26), red = (r: 255, g: 0, b: 0)
        assertColor(try pixel(out, 540, 1600), ink, "带内中心")
        assertColor(try pixel(out, 540, 1400), red, "带上沿之外")
        assertColor(try pixel(out, 540, 1535), red, "带上沿前一行")
        assertColor(try pixel(out, 540, 1536), ink, "带上沿第一行")
        assertColor(try pixel(out, 540, 1765), ink, "带下沿最后一行")
        assertColor(try pixel(out, 540, 1766), red, "带下沿后一行")
        assertColor(try pixel(out, 0, 1600), ink, "左边界")
        assertColor(try pixel(out, 1079, 1600), ink, "右边界")
    }

    @Test("dim：带内被半透明黑压暗，带外仍为原色")
    func dimBlendsInsideOnly() throws {
        let p = try plan(1080, 1920, mode: .dim)
        let out = try cgImage(SubtitleMaskPreviewRenderer.render(
            source: solidSource(1080, 1920), plan: p))
        let inside = try pixel(out, 540, 1600)
        assertColor(try pixel(out, 540, 1400), (255, 0, 0), "带外")
        #expect(inside.g <= 2 && inside.b <= 2, "dim 不该引入绿/蓝：\(inside)")
        #expect(inside.r < 230, "带内必须比原色暗：\(inside)")
    }

    // MARK: - blur

    private func checkerboard(_ w: Double, _ h: Double) throws -> CIImage {
        let filter = try #require(CIFilter(name: "CICheckerboardGenerator"))
        filter.setValue(CIVector(x: w / 2, y: h / 2), forKey: "inputCenter")
        filter.setValue(CIColor.white, forKey: "inputColor0")
        filter.setValue(CIColor.black, forKey: "inputColor1")
        filter.setValue(8, forKey: "inputWidth")
        let output = try #require(filter.outputImage)
        return output.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// 一条横线上的相邻像素平均差 —— 高频能量的代理量。棋盘边沿差大，糊过之后变小。
    private func horizontalEnergy(_ image: CGImage, y: Int,
                                  xRange: ClosedRange<Int>) throws -> Double {
        var total = 0
        var count = 0
        for x in xRange.lowerBound..<xRange.upperBound {
            let a = try pixel(image, x, y)
            let b = try pixel(image, x + 1, y)
            total += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
            count += 1
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    @Test("blur：带外逐像素不变（clamp 住了），带内高频能量显著下降")
    func blurOnlyTouchesTheBand() throws {
        let p = try plan(1080, 1920, mode: .blur)
        #expect(p.blurRadius == 20)
        let src = try checkerboard(1080, 1920)
        let canvas = SubtitleMaskPreviewRenderer.canvasImage(from: src, plan: p)
        let masked = SubtitleMaskPreviewRenderer.applyMask(to: canvas, plan: p)
        let before = try cgImage(canvas)
        let after = try cgImage(masked)

        // 带外：同一像素必须逐点相等（不被模糊/合成影响）
        for x in stride(from: 20, through: 1060, by: 40) {
            let a = try pixel(before, x, 700)
            let b = try pixel(after, x, 700)
            assertColor(b, a, tolerance: 1, "带外像素被改动了 x=\(x)")
        }

        let outsideEnergy = try horizontalEnergy(after, y: 700, xRange: 100...900)
        let insideEnergy = try horizontalEnergy(after, y: 1650, xRange: 100...900)
        #expect(outsideEnergy > 20, "夹具本身不是高频纹理（带外能量 \(outsideEnergy)）")
        #expect(insideEnergy < outsideEnergy * 0.5,
                "带内没有被糊开：带外能量 \(outsideEnergy)，带内 \(insideEnergy)")
    }

    // MARK: - canvas / 方向

    @Test("横屏源：上下 pad 黑边，画面居中")
    func landscapeIsPaddedWithBlack() throws {
        let p = try plan(1920, 1080, mode: .solid)
        // 本 helper 用 1080 画布：fit 后画面 1080×607.5，上下各 656.25 pad
        let canvas = try cgImage(SubtitleMaskPreviewRenderer.canvasImage(
            from: solidSource(1920, 1080), plan: p))
        assertColor(try pixel(canvas, 270, 20), (0, 0, 0), "顶部黑边")
        assertColor(try pixel(canvas, 270, 960), (255, 0, 0), "画面中心")
        assertColor(try pixel(canvas, 270, 1800), (0, 0, 0), "底部黑边")
    }

    @Test("9:16 源上的遮挡落位在底部，不是顶部（y 翻转只发生一次）")
    func maskYFlipLandsAtBottom() throws {
        let p = try plan(1080, 1920, mode: .solid)
        let out = try cgImage(SubtitleMaskPreviewRenderer.render(
            source: solidSource(1080, 1920), plan: p))
        assertColor(try pixel(out, 540, 1600), (26, 26, 26), "底部带内")
        assertColor(try pixel(out, 540, 200), (255, 0, 0), "顶部镜像位置")
    }

    // MARK: - 方向归一

    /// 四象限夹具（视觉坐标）：TL 红、TR 绿、BL 蓝、BR 白。
    private func quadrantImage(w: CGFloat, h: CGFloat) -> CIImage {
        let base = CIImage(color: CIColor.black)
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        // CI 是左下原点：视觉上半部分 y ∈ [h/2, h]。
        let parts: [(CGRect, CIColor)] = [
            (CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2), CIColor.red),
            (CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2), CIColor.green),
            (CGRect(x: 0, y: 0, width: w / 2, height: h / 2), CIColor.blue),
            (CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2), CIColor.white),
        ]
        return parts.reduce(base) { acc, part in
            CIImage(color: part.1).cropped(to: part.0).composited(over: acc)
        }
    }

    @Test("方向归一 90° 顺时针：四角映射正确、extent 交换")
    func orientation90CW() throws {
        let natural = CGSize(width: 100, height: 50)
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 50, ty: 0)
        let out = try cgImage(SubtitleMaskPreviewRenderer.oriented(
            quadrantImage(w: 100, h: 50), preferredTransform: t, naturalSize: natural))
        #expect(out.width == 50 && out.height == 100)
        // 90° cw：TL←源 BL(蓝)、TR←源 TL(红)、BL←源 BR(白)、BR←源 TR(绿)
        assertColor(try pixel(out, 2, 2), (0, 0, 255), "TL")
        assertColor(try pixel(out, 47, 2), (255, 0, 0), "TR")
        assertColor(try pixel(out, 2, 97), (255, 255, 255), "BL")
        assertColor(try pixel(out, 47, 97), (0, 255, 0), "BR")
    }

    @Test("方向归一 180°：对角交换")
    func orientation180() throws {
        let natural = CGSize(width: 100, height: 50)
        let t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 100, ty: 50)
        let out = try cgImage(SubtitleMaskPreviewRenderer.oriented(
            quadrantImage(w: 100, h: 50), preferredTransform: t, naturalSize: natural))
        #expect(out.width == 100 && out.height == 50)
        assertColor(try pixel(out, 2, 2), (255, 255, 255), "TL←源 BR")
        assertColor(try pixel(out, 97, 2), (0, 0, 255), "TR←源 BL")
        assertColor(try pixel(out, 2, 47), (0, 255, 0), "BL←源 TR")
        assertColor(try pixel(out, 97, 47), (255, 0, 0), "BR←源 TL")
    }

    @Test("方向归一 90° 逆时针：四角映射正确")
    func orientation90CCW() throws {
        let natural = CGSize(width: 100, height: 50)
        let t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 100)
        let out = try cgImage(SubtitleMaskPreviewRenderer.oriented(
            quadrantImage(w: 100, h: 50), preferredTransform: t, naturalSize: natural))
        #expect(out.width == 50 && out.height == 100)
        assertColor(try pixel(out, 2, 2), (0, 255, 0), "TL←源 TR")
        assertColor(try pixel(out, 47, 2), (255, 255, 255), "TR←源 BR")
        assertColor(try pixel(out, 2, 97), (255, 0, 0), "BL←源 TL")
        assertColor(try pixel(out, 47, 97), (0, 0, 255), "BR←源 BL")
    }
}