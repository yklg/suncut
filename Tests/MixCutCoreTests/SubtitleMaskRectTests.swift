import Testing
import Foundation
@testable import MixCutCore

@Test("默认底部带状区位置正确")
func defaultBottomBand() {
    let r = SubtitleMaskRect.defaultBottomBand
    #expect(r.x == 0.0)
    #expect(r.y == 0.80)
    #expect(r.width == 1.0)
    #expect(r.height == 0.12)
}

@Test("clamped 把越界分量拉回画面内")
func clampedKeepsInside() {
    let r = SubtitleMaskRect(x: -0.2, y: 0.95, width: 1.5, height: 0.3).clamped()
    #expect(r.x >= 0.0 && r.x <= 1.0)
    #expect(r.y >= 0.0 && r.y <= 1.0)
    #expect(r.x + r.width <= 1.0 + 1e-9)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("clamped 保证最小高度不塌缩")
func clampedMinHeight() {
    let r = SubtitleMaskRect(x: 0, y: 0.5, width: 1.0, height: 0.0).clamped()
    #expect(r.height >= 0.02)
}

@Test("movedBy 平移后仍在画面内")
func movedByClamps() {
    let r = SubtitleMaskRect.defaultBottomBand.movedBy(dy: 0.5)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("resizedBy 增高后底边不出界")
func resizedByClamps() {
    let r = SubtitleMaskRect(x: 0, y: 0.9, width: 1, height: 0.05).resizedBy(dHeight: 0.5)
    #expect(r.y + r.height <= 1.0 + 1e-9)
}

@Test("pixelRect 按画面尺寸换算")
func pixelRectScales() {
    let p = SubtitleMaskRect(x: 0.1, y: 0.5, width: 0.8, height: 0.1)
        .pixelRect(width: 1080, height: 1920)
    #expect(p.x == 108)
    #expect(p.y == 960)
    #expect(p.width == 864)
    #expect(abs(p.height - 192) < 1e-6)
}

// MARK: - 遮挡带最小高度 = 该分镜自己的字幕块高

/// 三档合法字号（`SubtitleFontSize` 的 min/default/max，App 层的枚举这里不引，值抄注释）。
private let legalFontRatios: [Double] = [0.030, 0.055, 0.085]

@Test("字幕块高下限按字号算，数值钉死")
func captionFloorValues() {
    // 1080×1920 基准上的单行字幕块：82px / 120px / 165.72px
    #expect(abs(SubtitleMaskRect.minimumHeight(fontRatio: 0.030) - 82.0 / 1920.0) < 1e-9)
    #expect(abs(SubtitleMaskRect.minimumHeight(fontRatio: 0.055) - 120.0 / 1920.0) < 1e-9)
    #expect(abs(SubtitleMaskRect.minimumHeight(fontRatio: 0.085) - 165.72 / 1920.0) < 1e-9)
}

@Test("字号越大要求的最小带高越高（下限不是常量）")
func captionFloorGrowsWithFont() {
    let small = SubtitleMaskRect.minimumHeight(fontRatio: 0.030)
    let mid = SubtitleMaskRect.minimumHeight(fontRatio: 0.055)
    let large = SubtitleMaskRect.minimumHeight(fontRatio: 0.085)
    #expect(small < mid && mid < large)
}

@Test("矮带被抬到字幕块高度，不传下限则维持原绝对下限（参数承重）")
func shortBandLiftedToCaptionFloor() {
    let floor55 = SubtitleMaskRect.minimumHeight(fontRatio: 0.055)   // 120/1920 = 0.0625
    #expect(abs(floor55 - 0.0625) < 1e-9)

    // 传了下限：0.02 的矮带被抬到 0.0625
    let lifted = SubtitleMaskRect(x: 0, y: 0.85, width: 1.0, height: 0.02)
        .clamped(minHeight: floor55)
    #expect(abs(lifted.height - 0.0625) < 1e-9)

    // 反向对照：默认参数下同样的矮带只有绝对下限 0.02 —— 说明抬高是这条参数做的，不是恒真
    let untouched = SubtitleMaskRect(x: 0, y: 0.85, width: 1.0, height: 0.02).clamped()
    #expect(abs(untouched.height - 0.02) < 1e-9)
}

@Test("拖拽两条手势都吃这条下限（不许只在松手时才生效）")
func dragGesturesCarryTheFloor() {
    let floor55 = SubtitleMaskRect.minimumHeight(fontRatio: 0.055)   // 0.0625
    #expect(abs(floor55 - 0.0625) < 1e-9)

    // 调高手柄：一路往上缩，缩到 0.0625 就停住；同一条位移不传下限会塌到 0.02
    let band = SubtitleMaskRect(x: 0, y: 0.80, width: 1.0, height: 0.12)
    #expect(abs(band.resizedBy(dHeight: -0.9, minHeight: floor55).height - 0.0625) < 1e-9)
    #expect(abs(band.resizedBy(dHeight: -0.9).height - 0.02) < 1e-9)

    // 整体平移不改高度，但下限必须一路带着：矮带被平移后仍是 0.0625，不传下限就是 0.02
    let short = SubtitleMaskRect(x: 0, y: 0.85, width: 1.0, height: 0.02)
    #expect(abs(short.movedBy(dy: -0.05, minHeight: floor55).height - 0.0625) < 1e-9)
    #expect(abs(short.movedBy(dy: -0.05).height - 0.02) < 1e-9)
    // 而它自己的高度不会被平移改小（下限只抬不压）
    #expect(abs(band.movedBy(dy: -0.9, minHeight: floor55).height - 0.12) < 1e-9)
}

@Test("默认底部带（0.12）在每一档合法字号下都不被这条下限改动")
func defaultBandUnaffectedAtEveryLegalRatio() {
    // 改动不能碰已写盘的常用状态：否则"什么都没做"也会把全库的带抬高
    for ratio in legalFontRatios {
        let r = SubtitleMaskRect.defaultBottomBand.clamped(
            minHeight: SubtitleMaskRect.minimumHeight(fontRatio: ratio))
        #expect(r == SubtitleMaskRect.defaultBottomBand, "字号 \(ratio) 时默认带被改写了")
    }
}

/// 下限与真实渲染的关系：这是让 `CaptionRenderer.singleLineHeightFactor = 1.40` 不腐烂的那条。
///
/// 两个方向都要断：带必须**盖得住**渲染出来的字幕（下限 ≥ 实际块高），
/// 又不能高得离谱（差 ≤ 2px）—— 只断一边就挡不住把系数改成 1.0 或 3.0。
@Test("下限与 CaptionRenderer 真实渲染的单行字幕块高度对齐")
func captionFloorTracksRenderedCaption() throws {
    let canonicalHeight = 1920.0
    for ratio in legalFontRatios {
        let fontSize = CGFloat(1080.0 * ratio)
        // 画布给到 2000px 宽，保证这五个字不折行 —— 要量的就是"一行"
        let img = try CaptionRenderer.render(text: "这里是字幕",
                                             canvasWidth: 2000,
                                             withBackdrop: true,
                                             fontSize: fontSize)
        let floorPx = SubtitleMaskRect.minimumHeight(fontRatio: ratio) * canonicalHeight
        #expect(floorPx >= Double(img.pixelHeight),
                "字号 \(ratio)：带下限 \(floorPx)px 盖不住 \(img.pixelHeight)px 的字幕块")
        #expect(floorPx - Double(img.pixelHeight) <= 2.0,
                "字号 \(ratio)：带下限比字幕块高 \(floorPx - Double(img.pixelHeight))px，超出取整抖动")
    }
}
