import Foundation
import Testing
import AppKit
import ImageIO
import CoreGraphics
@testable import SunCut

/// 真实导出腿的 LogoOverlay 判据：合成灰底 + 纯色角标，独立 ffprobe/抽帧取样。
/// 所有 spawn ffmpeg 的用例都走 `withFFmpegBench`；suite 自身 `.serialized`。
@Suite("LogoOverlay · App 真渲染", .serialized)
struct LogoOverlayExportTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logo-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func requireBinaries(_ ffmpeg: FFmpegRunner) async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = dir.appendingPathComponent("probe.mp4").path
        do {
            try await ffmpeg.run(arguments: [
                "-y", "-v", "error",
                "-f", "lavfi", "-i", "testsrc=size=64x64:rate=30:duration=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", probe,
            ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
        } catch {
            Issue.record("宿主 App 包内 ffmpeg 不可用，本组判据没有在测东西：\(error)")
            throw error
        }
    }

    private func synthesizeSource(_ ffmpeg: FFmpegRunner, to path: String) async throws {
        try await ffmpeg.run(arguments: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=gray:size=720x1280:rate=30:duration=5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
            "-shortest",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            "-metadata", "location=+31.2304+121.4737/",
            "-metadata", "creation_time=2020-01-01T00:00:00Z",
            path,
        ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
    }

    private func synthesizeSolidPNG(_ ffmpeg: FFmpegRunner, color: String,
                                    width: Int, height: Int, to path: String) async throws {
        try await ffmpeg.run(arguments: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=\(color):size=\(width)x\(height)",
            "-frames:v", "1", path,
        ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
    }

    private func measure(_ ffmpeg: FFmpegRunner, _ path: String) async throws -> [String: String] {
        let out = try await ffmpeg.runProbe(arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,sample_aspect_ratio",
            "-of", "default=noprint_wrappers=1", path,
        ])
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let i = line.firstIndex(of: "=") else { continue }
            kv[String(line[..<i])] = String(line[line.index(after: i)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return kv
    }

    private func metadataTags(_ ffmpeg: FFmpegRunner, _ path: String) async throws -> String {
        try await ffmpeg.runProbe(arguments: [
            "-v", "error", "-show_entries", "format_tags",
            "-of", "default=noprint_wrappers=1", path,
        ])
    }

    private struct Pixel: Equatable {
        let r: Int, g: Int, b: Int
        var isGray: Bool { abs(r - g) < 30 && abs(g - b) < 30 }
        var isRed: Bool { r > 150 && g < 120 && b < 120 }
        var isBlue: Bool { b > 150 && r < 120 && g < 120 }
    }

    private func pixel(_ ffmpeg: FFmpegRunner, path: String, time: Double,
                       x: Int, y: Int, dir: URL) async throws -> Pixel {
        // 包内 ffmpeg 8.1 的 `crop=1:1:x:y` 会报 width/height 0（2026-10-23 实测），
        // 所以先抽整帧，再用 CGImage.cropping 取 1×1；坐标原点同为左上。
        let frame = dir.appendingPathComponent("frame-\(time)-\(x)-\(y).png").path
        try await ffmpeg.run(arguments: [
            "-y", "-v", "error", "-ss", String(format: "%.3f", time), "-i", path,
            "-frames:v", "1", "-update", "1", frame,
        ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: frame) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            throw ExportError.encodingFailed("抽帧/裁点失败：\(frame) @ (\(x),\(y))")
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { throw ExportError.encodingFailed("像素读取失败：\(frame)") }
        return Pixel(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
    }

    private func makeInput(source: String) -> DubExportInput {
        let spec = DubSegmentSpec(
            videoPath: source, startFrame: 0, endFrame: 150, fps: 30,
            captionLines: [], hasHardSubtitle: false, maskStyleRaw: "",
            maskRect: .defaultBottomBand, isVoiceLocked: true, dubAudioPath: nil,
            freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil,
            subtitleFontRatio: 0.05, fillPieces: [])
        return DubExportInput(segments: [spec], maxWidth: 720, maxHeight: 1280)
    }

    private func config(tier: DeliveryTier = .p720) -> ExportConfig {
        var config = ExportConfig()
        config.deliveryTarget = .unrestricted
        config.resolution = tier
        config.codec = .h264
        config.quality = .high
        return config
    }

    @Test("K 预设真渲染：画布 720×1280、两角标像素命中、矩形外控制点为灰、元数据被清")
    func kPresetReallyBurns() async throws {
        try await withFFmpegBench("logoOverlayKPresetReallyBurns") {
            let ffmpeg = FFmpegRunner()
            try await requireBinaries(ffmpeg)
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }

            let src = dir.appendingPathComponent("src.mp4").path
            let out = dir.appendingPathComponent("out.mp4").path
            let controlOut = dir.appendingPathComponent("control.mp4").path
            try await synthesizeSource(ffmpeg, to: src)

            let logoURL = dir.appendingPathComponent("logo-red.png")
            let titleURL = dir.appendingPathComponent("title-blue.png")
            try await synthesizeSolidPNG(ffmpeg, color: "red", width: 256, height: 78, to: logoURL.path)
            try await synthesizeSolidPNG(ffmpeg, color: "blue", width: 1384, height: 814, to: titleURL.path)

            let logoImport = try LogoOverlayAssetStore.importPNG(from: logoURL)
            let titleImport = try LogoOverlayAssetStore.importPNG(from: titleURL)
            #expect(logoImport.pixelWidth == 256 && logoImport.pixelHeight == 78)
            #expect(titleImport.pixelWidth == 1384 && titleImport.pixelHeight == 814)
            #expect(logoImport.warning != nil, "无 alpha 的 PNG 必须出警告，不能静默")

            let logoConfig = LogoOverlayConfig(
                enabled: true,
                layers: [
                    LogoOverlayLayer(file: logoImport.file, widthPct: 0.55, anchor: .topLeft),
                    LogoOverlayLayer(file: titleImport.file, widthPct: 0.33, anchor: .bottomRight),
                ],
                rightMarginPct: 0.026, bottomMarginPct: 0.147)

            let input = makeInput(source: src)
            try await DubExportService().export(
                input: input, outputPath: out, config: config(), globalBGM: nil,
                logo: logoConfig, stripMetadata: true)

            let m = try await measure(ffmpeg, out)
            #expect(m["width"] == "720" && m["height"] == "1280")
            #expect(m["sample_aspect_ratio"] == "1:1")

            // 首帧/中段/末帧都取：证明这是全片静态层，不是只闪一下
            for time in [0.5, 2.5, 4.5] {
                let logo = try await pixel(ffmpeg, path: out, time: time, x: 198, y: 61, dir: dir)
                let title = try await pixel(ffmpeg, path: out, time: time, x: 582, y: 1022, dir: dir)
                #expect(logo.isRed, "t=\(time) logo 中心 \(logo) 不是红色")
                #expect(title.isBlue, "t=\(time) 文字中心 \(title) 不是蓝色")
            }
            let control = try await pixel(ffmpeg, path: out, time: 2.5, x: 360, y: 640, dir: dir)
            #expect(control.isGray, "矩形外控制点 \(control) 不是灰底")

            let tags = try await metadataTags(ffmpeg, out)
            #expect(!tags.contains("location"), "stripMetadata=true 仍带 location：\(tags)")
            #expect(!tags.contains("creation_time"), "stripMetadata=true 仍带 creation_time：\(tags)")

            // 负对照：同源不传 logo，两个采样点必须回到灰
            let sourceTags = try await metadataTags(ffmpeg, src)
            #expect(sourceTags.contains("location") || sourceTags.contains("creation_time"),
                    "合成源本身没有元数据，stripMetadata 判据没有对照：\(sourceTags)")
            try await DubExportService().export(
                input: input, outputPath: controlOut, config: config(), globalBGM: nil,
                logo: nil, stripMetadata: false)
            let controlLogo = try await pixel(ffmpeg, path: controlOut, time: 2.5, x: 198, y: 61, dir: dir)
            let controlTitle = try await pixel(ffmpeg, path: controlOut, time: 2.5, x: 582, y: 1022, dir: dir)
            #expect(controlLogo.isGray, "不传 logo 的负对照在 logo 点不是灰：\(controlLogo)")
            #expect(controlTitle.isGray, "不传 logo 的负对照在文字点不是灰：\(controlTitle)")
            let controlTags = try await metadataTags(ffmpeg, controlOut)
            // 当前导出链本来就不会把源的全局 tags 带到成片；stripMetadata 是"必然清"的硬保证，
            // 不是"唯一清"的开关。所以只验两条产物都不带敏感标签，不把 false 分支伪造成保留。
            #expect(!controlTags.contains("location"))
            #expect(!controlTags.contains("creation_time"))
        }
    }

    @Test("K 预设 @1080×1920：画布与两角标像素仍正确")
    func kPreset1080ReallyBurns() async throws {
        try await withFFmpegBench("logoOverlayKPreset1080") {
            let ffmpeg = FFmpegRunner()
            try await requireBinaries(ffmpeg)
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }

            let src = dir.appendingPathComponent("src1080.mp4").path
            let out = dir.appendingPathComponent("out1080.mp4").path
            try await ffmpeg.run(arguments: [
                "-y", "-v", "error",
                "-f", "lavfi", "-i", "color=c=gray:size=1080x1920:rate=30:duration=5",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=5",
                "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", src,
            ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)

            let logoURL = dir.appendingPathComponent("logo1080.png")
            let titleURL = dir.appendingPathComponent("title1080.png")
            try await synthesizeSolidPNG(ffmpeg, color: "red", width: 256, height: 78, to: logoURL.path)
            try await synthesizeSolidPNG(ffmpeg, color: "blue", width: 1384, height: 814, to: titleURL.path)
            let logoImport = try LogoOverlayAssetStore.importPNG(from: logoURL)
            let titleImport = try LogoOverlayAssetStore.importPNG(from: titleURL)

            let logoConfig = LogoOverlayConfig(
                enabled: true,
                layers: [
                    LogoOverlayLayer(file: logoImport.file, widthPct: 0.55, anchor: .topLeft),
                    LogoOverlayLayer(file: titleImport.file, widthPct: 0.33, anchor: .bottomRight),
                ],
                rightMarginPct: 0.026, bottomMarginPct: 0.147)
            let spec = DubSegmentSpec(
                videoPath: src, startFrame: 0, endFrame: 150, fps: 30,
                captionLines: [], hasHardSubtitle: false, maskStyleRaw: "",
                maskRect: .defaultBottomBand, isVoiceLocked: true, dubAudioPath: nil,
                freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil,
                subtitleFontRatio: 0.05, fillPieces: [])
            let input = DubExportInput(segments: [spec], maxWidth: 1080, maxHeight: 1920)
            try await DubExportService().export(
                input: input, outputPath: out, config: config(tier: .p1080), globalBGM: nil,
                logo: logoConfig, stripMetadata: true)

            let m = try await measure(ffmpeg, out)
            #expect(m["width"] == "1080" && m["height"] == "1920")
            let logo = try await pixel(ffmpeg, path: out, time: 2.5, x: 297, y: 91, dir: dir)
            let title = try await pixel(ffmpeg, path: out, time: 2.5, x: 874, y: 1533, dir: dir)
            let control = try await pixel(ffmpeg, path: out, time: 2.5, x: 540, y: 960, dir: dir)
            #expect(logo.isRed, "1080 logo 中心 \(logo) 不是红色")
            #expect(title.isBlue, "1080 文字中心 \(title) 不是蓝色")
            #expect(control.isGray, "1080 控制点 \(control) 不是灰底")
        }
    }

    @Test("HDR 前置：PQ/HLG 标签被识别，SDR 不误报")
    func hdrPreflight() async throws {
        try await withFFmpegBench("logoOverlayHDRPreflight") {
            let ffmpeg = FFmpegRunner()
            try await requireBinaries(ffmpeg)
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let sdr = dir.appendingPathComponent("sdr.mp4").path
            let hdr = dir.appendingPathComponent("hdr.mp4").path
            try await ffmpeg.run(arguments: [
                "-y", "-v", "error",
                "-f", "lavfi", "-i", "testsrc=size=64x64:rate=30:duration=1",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", sdr,
            ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
            try await ffmpeg.run(arguments: [
                "-y", "-v", "error",
                "-f", "lavfi", "-i", "testsrc=size=64x64:rate=30:duration=1",
                "-vf", "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
                "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-an", hdr,
            ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)

            #expect(await DubExportService.firstHDRSource(paths: [hdr, sdr]) == hdr)
            #expect(await DubExportService.firstHDRSource(paths: [sdr]) == nil)
        }
    }
}
