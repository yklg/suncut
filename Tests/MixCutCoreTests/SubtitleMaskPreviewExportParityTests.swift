import Testing
import Foundation
@testable import MixCutCore

/// 预览 plan ↔ 导出 ffmpeg 滤镜串的**同画布对账**。
///
/// 这是"预览 = 导出"的结构性防线：两边各写一套渲染，若没有这条判据，
/// 本次修复只是把两套渲染者变成三套。画布统一取 1080×1920（预览 plan 传
/// `maxShortSide: 1080`），坐标逐数比较；半径按导出 Int 半径与预览分数半径的关系比较。
@Suite("SubtitleMaskPreviewExportParity")
struct SubtitleMaskPreviewExportParityTests {
    private let canvasW = 1080
    private let canvasH = 1920

    private func graph(_ mode: SubtitleMaskMode,
                       mask: SubtitleMaskRect) -> (graph: DubSegmentGraph, px: PixelRect) {
        let px = PixelRect.from(mask, outputWidth: canvasW, outputHeight: canvasH)
        let g = DubSegmentGraphBuilder.build(
            mode: mode, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: canvasW, outputHeight: canvasH,
            maskPixel: px, captions: [], keepOriginalAudio: false,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0)
        return (g, px)
    }

    private func plan(_ mask: SubtitleMaskRect, mode: SubtitleMaskMode)
        -> SubtitleMaskPreviewPlan? {
        SubtitleMaskPreviewPlan.make(
            sourceSize: CGSize(width: Double(canvasW), height: Double(canvasH)),
            maskRect: mask, mode: mode, maxShortSide: canvasW)
    }

    private func ints(_ pattern: String, in text: String) -> [Int]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
        }
    }

    private struct Drawbox: Equatable {
        let x: Int, y: Int, w: Int, h: Int
        let hex: String
        let alpha: Double
    }

    private func drawbox(in text: String) -> Drawbox? {
        let pattern = #"drawbox=x=(\d+):y=(\d+):w=(\d+):h=(\d+):color=0x([0-9A-Fa-f]+)@([0-9.]+):t=fill"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text,
                                    range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        guard let x = Int(group(1)), let y = Int(group(2)),
              let w = Int(group(3)), let h = Int(group(4)),
              let alpha = Double(group(6)) else { return nil }
        return Drawbox(x: x, y: y, w: w, h: h, hex: group(5), alpha: alpha)
    }

    private let masks: [SubtitleMaskRect] = [
        .defaultBottomBand,
        SubtitleMaskRect(x: 0.2, y: 0.8, width: 0.5, height: 0.12),
        SubtitleMaskRect(x: 0, y: 0.5, width: 1, height: 0.02),
    ]

    @Test("blur：crop/overlay/boxblur 坐标与 plan 逐数相等")
    func blurCoordinatesMatch() throws {
        for mask in masks {
            let p = try #require(plan(mask, mode: .blur))
            let (g, px) = graph(.blur, mask: mask)
            #expect(p.maskPixelRect == px, "plan 的矩形与 PixelRect.from 分叉")

            let crop = try #require(ints(#"crop=(\d+):(\d+):(\d+):(\d+)"#, in: g.filterComplex))
            #expect(crop == [px.width, px.height, px.x, px.y],
                    "crop 与 plan 分叉：\(crop) vs \(px)")

            let overlay = try #require(ints(#"overlay=(\d+):(\d+)"#, in: g.filterComplex))
            #expect(overlay == [px.x, px.y], "overlay 落位分叉：\(overlay)")

            let blur = try #require(ints(#"boxblur=(\d+):(\d+)"#, in: g.filterComplex))
            let exportRadius = SubtitleMaskMode.blur.renderSpec
                .clampedRadius(cropWidth: px.width, cropHeight: px.height)
            #expect(blur[0] == exportRadius, "导出半径与 clampedRadius 分叉")
            // 同画布（1080）下预览半径应与导出一致；导出半径是 Int（ffmpeg 要求整数），
            // 预览是分数，钳位边上允许 <1px 的取整差。
            #expect(abs(p.blurRadius - Double(exportRadius)) < 1.0,
                    "半径分叉：plan \(p.blurRadius) vs export \(exportRadius)（mask \(mask)）")
        }
    }

    @Test("solid/dim：drawbox 坐标、hex、alpha 与 plan 的 renderSpec 同源")
    func fillSpecsMatch() throws {
        for mode in [SubtitleMaskMode.solid, .dim] {
            let p = try #require(plan(.defaultBottomBand, mode: mode))
            let (g, px) = graph(mode, mask: .defaultBottomBand)
            let box = try #require(drawbox(in: g.filterComplex), "\(mode) 没产出 drawbox")
            #expect(box.x == px.x && box.y == px.y
                    && box.w == px.width && box.h == px.height,
                    "drawbox 与 plan 分叉：\(box) vs \(px)")
            guard case .fill(let hex, let alpha) = p.renderSpec else {
                Issue.record("\(mode) 的 renderSpec 不是 fill ⇒ 下面的断言是空断言")
                continue
            }
            #expect(box.hex == hex, "\(mode)：串里的颜色不是表里的")
            #expect(abs(box.alpha - alpha) < 1e-9, "\(mode)：串里的 alpha 不是表里的")
        }
    }

    @Test("none：两边都无遮挡（导出 null 透传、plan 无半径）")
    func noneModeParity() throws {
        let p = try #require(plan(.defaultBottomBand, mode: .none))
        let (g, _) = graph(.none, mask: .defaultBottomBand)
        #expect(g.filterComplex.contains("[base]null[masked]"))
        #expect(!g.filterComplex.contains("boxblur"))
        #expect(!g.filterComplex.contains("drawbox"))
        #expect(p.blurRadius == 0)
        #expect(p.renderSpec == .passthrough)
    }

    @Test("半径跨画布：540 预览 = 1080 导出 × 0.5（钳位边允许 <1px）")
    func radiusScalesWithCanvas() throws {
        for mask in masks {
            let preview = try #require(SubtitleMaskPreviewPlan.make(
                sourceSize: CGSize(width: 1080, height: 1920),
                maskRect: mask, mode: .blur))
            let (g, px) = graph(.blur, mask: mask)
            let blur = try #require(ints(#"boxblur=(\d+):(\d+)"#, in: g.filterComplex))
            let exportRadius = Double(blur[0])
            let scale = Double(preview.canvasWidth) / Double(canvasW)
            #expect(abs(preview.blurRadius - exportRadius * scale) < 1.0,
                    "跨画布半径不按比例：preview \(preview.blurRadius) vs \(exportRadius) × \(scale)")
            // 导出用的裁面与预览的裁面必须是同一个归一化矩形
            let previewNormalized = (
                Double(preview.maskPixelRect.x) / Double(preview.canvasWidth),
                Double(preview.maskPixelRect.y) / Double(preview.canvasHeight))
            #expect(abs(previewNormalized.0 - Double(px.x) / Double(canvasW)) < 0.002)
            #expect(abs(previewNormalized.1 - Double(px.y) / Double(canvasH)) < 0.002)
        }
    }

    @Test("阴性对照：换一个 mask，两边的数都跟着变（判据不是恒绿）")
    func negativeControl() throws {
        let a = SubtitleMaskRect(x: 0, y: 0.8, width: 1, height: 0.12)
        let b = SubtitleMaskRect(x: 0.2, y: 0.5, width: 0.5, height: 0.2)
        let pa = try #require(plan(a, mode: .blur))
        let pb = try #require(plan(b, mode: .blur))
        let (ga, _) = graph(.blur, mask: a)
        let (gb, _) = graph(.blur, mask: b)
        let ca = try #require(ints(#"crop=(\d+):(\d+):(\d+):(\d+)"#, in: ga.filterComplex))
        let cb = try #require(ints(#"crop=(\d+):(\d+):(\d+):(\d+)"#, in: gb.filterComplex))
        #expect(ca != cb, "改了 mask 但导出 crop 没变 ⇒ 对账判据在测空气")
        #expect(pa.maskPixelRect != pb.maskPixelRect, "改了 mask 但 plan 没变")
    }
}