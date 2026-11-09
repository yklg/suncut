import Foundation
import Testing
import AVFoundation
import CoreGraphics

// ⚠️ module 名是 SunCut（App target 的 PRODUCT_NAME）。
@testable import SunCut

/// 播放态遮挡合成的整腿判据：真建 `AVVideoComposition`，用 `AVAssetImageGenerator` 取帧读像素。
///
/// 核心那条是「整段生效」：同一颗夹具在 t=0.2 / 1.0 / 1.6 三个时间点都必须有遮挡 ——
/// 直接钉住本次缺陷（修复前遮挡只存在于静止缩略图那一帧）。
/// 夹具用 AVAssetWriter 现造，不 spawn ffmpeg，也不碰用户素材库。
struct SubtitleMaskPlaybackCompositionTests {

    // MARK: - 夹具

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mask-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 纯色视频，可带 preferredTransform（旋转夹具）。
    private func makeVideo(at url: URL, width: Int, height: Int, seconds: Double = 2.0,
                           transform: CGAffineTransform = .identity,
                           color: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writer }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let frames = max(1, Int(seconds * Double(fps)))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pixelBuffer: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            }
            if pixelBuffer == nil {
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &pixelBuffer)
            }
            guard let buffer = pixelBuffer else { throw FixtureError.pixelBuffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * bytesPerRow)
                        .assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let p = row.advanced(by: x * 4)
                        p[0] = color.b
                        p[1] = color.g
                        p[2] = color.r
                        p[3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? FixtureError.append
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writer }
    }

    private enum FixtureError: Error {
        case writer, pixelBuffer, append
    }

    // MARK: - 取帧 / 读像素

    private func frame(_ url: URL, at seconds: Double,
                       composition: AVVideoComposition?) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.videoComposition = composition
        let result = try await generator.image(
            at: CMTime(seconds: seconds, preferredTimescale: 600))
        return result.image
    }

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

    private func expectColor(_ got: (r: Int, g: Int, b: Int),
                             _ want: (r: Int, g: Int, b: Int),
                             tolerance: Int = 5,
                             _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(got.r - want.r) <= tolerance
                && abs(got.g - want.g) <= tolerance
                && abs(got.b - want.b) <= tolerance,
                "\(label)：期望 \(want)，实得 \(got)", sourceLocation: sourceLocation)
    }

    // MARK: - 判据

    @Test("整段生效：t=0.2 / 1.0 / 1.6 三帧带内都是 1A1A1A（不是只有一帧）")
    func maskCoversWholeTimeline() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("src.mp4")
        try await makeVideo(at: url, width: 540, height: 960)

        let build = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .solid)
        // 540×960 画布上默认带：y=768、高 115、中心 (270, 825)
        #expect(build.plan.maskPixelRect == PixelRect(x: 0, y: 768, width: 540, height: 115))

        for time in [0.2, 1.0, 1.6] {
            let image = try await frame(url, at: time, composition: build.videoComposition)
            expectColor(try pixel(image, 270, 825), (26, 26, 26), "t=\(time) 带内")
            expectColor(try pixel(image, 270, 400), (255, 255, 255), "t=\(time) 带外")
        }

        // 阳性对照：不挂 composition 的同一夹具，带内必须是白色（证明判据不是恒绿）
        let control = try await frame(url, at: 1.0, composition: nil)
        expectColor(try pixel(control, 270, 825), (255, 255, 255), "无合成对照")
    }

    @Test("横屏源：输出 9:16 画布，遮挡带落在 pad 黑边里也上色")
    func landscapePadIsMasked() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("landscape.mp4")
        try await makeVideo(at: url, width: 960, height: 540)

        let build = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .solid)
        #expect(build.videoComposition.renderSize == CGSize(width: 540, height: 960))
        // 画面 fit 后占 y≈328..632；默认带 y=768..883 全在底部黑边里
        let image = try await frame(url, at: 1.0, composition: build.videoComposition)
        expectColor(try pixel(image, 270, 480), (255, 255, 255), "画面中心")
        expectColor(try pixel(image, 270, 20), (0, 0, 0), "顶部黑边")
        expectColor(try pixel(image, 270, 825), (26, 26, 26), "黑边里的遮挡带")
    }

    @Test("旋转源：preferredTransform 在合成器里被应用（未旋转会露出画面）")
    func rotatedSourceIsOriented() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rotated.mp4")
        // 540×960 竖帧带 90° cw 旋转 ⇒ 摆正后是 960×540 横帧
        try await makeVideo(at: url, width: 540, height: 960,
                            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 960, ty: 0))

        let build = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .solid)
        let image = try await frame(url, at: 1.0, composition: build.videoComposition)
        // 摆正后内容只占中间 540×303.75；顶部 y=100 必须是 pad 黑。
        // 若方向没应用，原始 540×960 竖帧会填满画布，这一点是白色。
        expectColor(try pixel(image, 270, 100), (0, 0, 0), "顶部 pad（方向是否被应用）")
        expectColor(try pixel(image, 270, 480), (255, 255, 255), "摆正后的画面")
        expectColor(try pixel(image, 270, 825), (26, 26, 26), "遮挡带")
    }

    @Test("合成器契约：renderSize / frameDuration / 指令覆盖全片 / 校验通过")
    func compositionContract() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("contract.mp4")
        try await makeVideo(at: url, width: 540, height: 960, seconds: 2.0)

        let build = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .solid)
        let composition = build.videoComposition
        #expect(composition.renderSize == CGSize(width: 540, height: 960))
        #expect(abs(composition.frameDuration.seconds - 1.0 / 30.0) < 0.001)
        #expect(composition.instructions.count == 1)
        #expect(abs(composition.instructions[0].timeRange.duration.seconds - 2.0) < 0.1)
        #expect(composition.customVideoCompositorClass == SubtitleMaskPreviewCompositor.self)
        #expect(build.plan.blurRadius == 0, "solid 不该有糊半径")
        #expect(build.source.orientedSize == CGSize(width: 540, height: 960))
    }

    @Test("重复构建不炸；.none 直接拒绝")
    func repeatedBuildsAndNoneMode() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("repeat.mp4")
        try await makeVideo(at: url, width: 540, height: 960, seconds: 1.0)

        let first = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .solid)
        let second = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .blur)
        #expect(first.videoComposition !== second.videoComposition)

        await #expect(throws: (any Error).self) {
            _ = try await SubtitleMaskPreviewCompositionFactory.make(
                videoURL: url, maskRect: .defaultBottomBand, mode: .none)
        }
    }

    @Test("配置盒热更新：下一帧读新矩形；并发读写不崩")
    func configBoxHotUpdate() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hot.mp4")
        try await makeVideo(at: url, width: 540, height: 960, seconds: 1.0)

        let build = try await SubtitleMaskPreviewCompositionFactory.make(
            videoURL: url, maskRect: .defaultBottomBand, mode: .solid)
        let newMask = SubtitleMaskRect(x: 0, y: 0.4, width: 1, height: 0.12)
        let newPlan = try #require(SubtitleMaskPreviewPlan.make(
            sourceSize: build.source.orientedSize, maskRect: newMask, mode: .solid))
        build.configBox.update(newPlan)
        #expect(build.configBox.current.maskPixelRect == newPlan.maskPixelRect)

        // 读写并发：合成器在后台读、UI 在主线程写
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i.isMultiple(of: 2) {
                build.configBox.update(newPlan)
            } else {
                _ = build.configBox.current
            }
        }
    }
}