import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// 播放态遮挡预览的时间轴渲染者：把 `SubtitleMaskPreviewPlan` 逐帧画进 AVPlayer 的视频帧。
///
/// 为什么需要它：静止缩略图上的 SwiftUI 覆盖层取不到 `AVPlayerLayer` 的帧，播放态此前
/// 没有任何遮挡渲染者（见 `SegmentLibraryView.maskTreatmentPreview` 的历史注释）。
/// 这里用 `AVVideoComposition` + 自定义 `AVVideoCompositing` 补上「时间轴」这一维，
/// 语义（颜色/半径/落位）全部从 Core 的 `SubtitleMaskPreviewPlan` 读，不另算一份。

// MARK: - 可热更新的配置

/// 遮挡参数的热更新盒：拖遮挡框/切样式时只改这里，不重建 composition。
/// `NSLock` 保护 —— 合成器在 AVFoundation 的后台队列读，UI 在主线程写。
final class SubtitleMaskPreviewConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: SubtitleMaskPreviewPlan

    init(_ plan: SubtitleMaskPreviewPlan) { self.plan = plan }

    var current: SubtitleMaskPreviewPlan {
        lock.lock()
        defer { lock.unlock() }
        return plan
    }

    func update(_ newPlan: SubtitleMaskPreviewPlan) {
        lock.lock()
        plan = newPlan
        lock.unlock()
    }
}

// MARK: - 构建期常量

struct SubtitleMaskPreviewSource: Sendable {
    let naturalSize: CGSize
    /// 已按 `preferredTransform` 摆正后的尺寸（`SubtitleMaskPreviewPlan` 用）。
    let orientedSize: CGSize
    let preferredTransform: CGAffineTransform
    let trackID: CMPersistentTrackID
    let frameDuration: CMTime
}

struct SubtitleMaskPreviewBuild {
    let videoComposition: AVVideoComposition
    let configBox: SubtitleMaskPreviewConfig
    let source: SubtitleMaskPreviewSource
    let plan: SubtitleMaskPreviewPlan
}

// MARK: - 指令

/// 自定义合成器由 AVFoundation `init()` 自建，构造参数传不进去 ⇒ 构建期常量挂在指令上，
/// 合成器从 `request.videoCompositionInstruction` 取；可变量走 `configBox`。
final class SubtitleMaskPreviewInstruction: NSObject,
                                            AVVideoCompositionInstructionProtocol,
                                            @unchecked Sendable {
    let timeRange: CMTimeRange
    let source: SubtitleMaskPreviewSource
    let configBox: SubtitleMaskPreviewConfig

    var enablePostProcessing: Bool { false }
    var containsTweening: Bool { false }
    var requiredSourceTrackIDs: [NSValue]? {
        [NSNumber(value: source.trackID)]
    }
    var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    init(timeRange: CMTimeRange,
         source: SubtitleMaskPreviewSource,
         configBox: SubtitleMaskPreviewConfig) {
        self.timeRange = timeRange
        self.source = source
        self.configBox = configBox
        super.init()
    }
}

// MARK: - 合成器

final class SubtitleMaskPreviewCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// CI 的 context 线程安全；软件/GPU 由系统挑。每帧只有一块 540 短边的画布。
    private static let context = CIContext(options: [.cacheIntermediates: false])

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction
                as? SubtitleMaskPreviewInstruction else {
            request.finish(with: Self.error(code: -1, "缺少遮挡预览指令"))
            return
        }
        guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.source.trackID) else {
            request.finish(with: Self.error(code: -2, "取不到源帧"))
            return
        }
        let plan = instruction.configBox.current
        let source = CIImage(cvPixelBuffer: sourceBuffer)
        let oriented = SubtitleMaskPreviewRenderer.oriented(
            source,
            preferredTransform: instruction.source.preferredTransform,
            naturalSize: instruction.source.naturalSize)
        let rendered = SubtitleMaskPreviewRenderer.render(source: oriented, plan: plan)

        guard let output = request.renderContext.newPixelBuffer() else {
            // 新 buffer 拿不到时回源帧（社区同款回退）：宁可少一层遮挡，也不能丢帧。
            request.finish(withComposedVideoFrame: sourceBuffer)
            return
        }
        Self.context.render(rendered, to: output,
                            bounds: CGRect(x: 0, y: 0,
                                           width: plan.canvasWidth, height: plan.canvasHeight),
                            colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "SubtitleMaskPreview", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - 工厂

enum SubtitleMaskPreviewCompositionFactory {
    enum BuildError: LocalizedError {
        case noVideoTrack
        case invalidPlan
        case invalidComposition

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "源文件没有可用的视频轨"
            case .invalidPlan: return "源尺寸非法，无法生成遮挡预览画布"
            case .invalidComposition: return "遮挡预览合成未通过 AVFoundation 校验"
            }
        }
    }

    /// 为一条本地视频构建「整段 9:16 画布 + 遮挡」的播放合成。
    ///
    /// - 只读加载 track 的尺寸/方向/帧时长；失败抛出原因（调用方负责可见提示与退回原播放）。
    /// - `maxShortSide` 默认 540：卡片只有 200pt 宽，原尺寸逐帧处理是白烧 CPU。
    static func make(videoURL: URL,
                     maskRect: SubtitleMaskRect,
                     mode: SubtitleMaskMode,
                     maxShortSide: Int = SubtitleMaskPreviewPlan.defaultMaxShortSide)
        async throws -> SubtitleMaskPreviewBuild {
        guard mode != .none else { throw BuildError.invalidPlan }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var enabled: AVAssetTrack?
        for track in tracks {
            if try await track.load(.isEnabled) { enabled = track; break }
        }
        guard let track = enabled ?? tracks.first else { throw BuildError.noVideoTrack }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let minFrameDuration = try await track.load(.minFrameDuration)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.seconds > 0 else { throw BuildError.invalidComposition }

        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard let plan = SubtitleMaskPreviewPlan.make(
            sourceSize: orientedSize, maskRect: maskRect,
            mode: mode, maxShortSide: maxShortSide) else {
            throw BuildError.invalidPlan
        }

        let frameDuration: CMTime = (minFrameDuration.isValid && minFrameDuration.seconds > 0)
            ? minFrameDuration
            : CMTime(value: 1, timescale: 30)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        let source = SubtitleMaskPreviewSource(
            naturalSize: naturalSize,
            orientedSize: orientedSize,
            preferredTransform: transform,
            trackID: track.trackID,
            frameDuration: frameDuration)
        let box = SubtitleMaskPreviewConfig(plan)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: plan.canvasWidth, height: plan.canvasHeight)
        composition.frameDuration = frameDuration
        composition.customVideoCompositorClass = SubtitleMaskPreviewCompositor.self
        composition.instructions = [
            SubtitleMaskPreviewInstruction(timeRange: timeRange, source: source, configBox: box)
        ]

        if #available(macOS 15.0, *) {
            guard composition.isValid(for: [track],
                                      assetDuration: duration,
                                      timeRange: timeRange,
                                      validationDelegate: nil) else {
                throw BuildError.invalidComposition
            }
        }

        return SubtitleMaskPreviewBuild(videoComposition: composition,
                                        configBox: box,
                                        source: source,
                                        plan: plan)
    }
}

// MARK: - 失败提示（本会话只弹一次）

@MainActor
enum SubtitleMaskPreviewFailureNotice {
    private static var shown = false

    /// 构建失败必须可见：只写日志等于让「播放态没有遮挡」这个原症状无提示复活。
    static func showOnce() {
        guard !shown else { return }
        shown = true
        ToastCenter.shared.show("遮挡预览暂不可用（不影响导出）",
                                icon: "exclamationmark.triangle.fill",
                                style: .warning)
    }
}