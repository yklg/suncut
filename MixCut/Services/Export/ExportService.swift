import Foundation

/// 导出配置
struct ExportConfig {
    /// 交付目标：决定用哪张平台证据表闸这次导出。缺省千川 —— 本产品的产物就是投放素材。
    var deliveryTarget: DeliveryTargetID = .qianchuanVertical
    var resolution: ExportResolution = .original
    var codec: ExportCodec = .h264Hardware    // 默认硬件加速：5-10× 速度
    var quality: ExportQuality = .high

    /// 档位与尺寸常量已下沉 `MixCutCore.DeliveryTier` / `DeliveryCanvas`（2026-10-19）。
    ///
    /// 原先这里是第二份抄本（`.p1080 → "scale=-2:1080"` 等），且 `scaleFilter` 全仓零引用
    /// —— 一份没人用的尺寸抄本，正是"改一处忘五处"能长期存活的原因，一并删除。
    ///
    /// 旧 `case p480 = "480p"` 已整档删除：480 宽的精确 9:16 高是 853.33，
    /// 整数上永远凑不出合规画布，旧实现写死 (480, 854) 算出来是 240:427。
    typealias ExportResolution = DeliveryTier

    enum ExportCodec: String, CaseIterable, Identifiable {
        case h264Hardware = "H.264（硬件加速・推荐）"
        case h265Hardware = "H.265 / HEVC（硬件加速）"
        case h264 = "H.264（CPU 软件编码・最佳画质）"
        case h265 = "H.265 / HEVC（CPU 软件编码）"

        var id: String { rawValue }

        var ffmpegCodec: String {
            switch self {
            case .h264:         return "libx264"
            case .h265:         return "libx265"
            case .h264Hardware: return "h264_videotoolbox"
            case .h265Hardware: return "hevc_videotoolbox"
            }
        }

        /// 是否使用 Apple VideoToolbox 硬件编码（M 系列 Media Engine / Intel Quick Sync）
        var isHardware: Bool {
            switch self {
            case .h264Hardware, .h265Hardware: return true
            case .h264, .h265:                 return false
            }
        }
    }

    enum ExportQuality: String, CaseIterable, Identifiable {
        case low = "低质量（文件小）"
        case medium = "中等质量"
        case high = "高质量"
        case lossless = "无损"

        var id: String { rawValue }

        /// 软件编码用的 CRF 值（H.265 同等视觉质量 CRF 更高）
        func crf(for codec: ExportCodec = .h264) -> Int {
            switch (self, codec) {
            case (.low, .h264), (.low, .h264Hardware):     return 28
            case (.low, .h265), (.low, .h265Hardware):     return 30
            case (.medium, .h264), (.medium, .h264Hardware): return 23
            case (.medium, .h265), (.medium, .h265Hardware): return 26
            case (.high, .h264), (.high, .h264Hardware):   return 18
            case (.high, .h265), (.high, .h265Hardware):   return 22
            case (.lossless, _):                            return 0
            }
        }

        /// 硬件编码用的目标比特率（kbps，按 1080p 估算；FFmpeg 会按实际分辨率扩缩）
        /// VideoToolbox 不支持 CRF，用比特率控质量。
        func videoBitrateKbps(for codec: ExportCodec) -> Int {
            switch (self, codec) {
            case (.low, .h264Hardware):    return 3_000
            case (.medium, .h264Hardware): return 6_000
            case (.high, .h264Hardware):   return 10_000
            case (.low, .h265Hardware):    return 1_800
            case (.medium, .h265Hardware): return 3_500
            case (.high, .h265Hardware):   return 6_500
            case (.lossless, _):           return 50_000   // 硬件不支持真无损，给极高比特率近似
            default:                        return 8_000
            }
        }
    }

    /// 用户可读的质量说明（含码率/CRF + 文件大小估算）
    /// 在 UI 下方显示，让用户知道选择对应的画质和文件大小
    var qualityHint: String {
        if codec.isHardware {
            let kbps = quality.videoBitrateKbps(for: codec)
            let mbps = Double(kbps) / 1000.0
            let mbpsStr = mbps >= 10 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps)
            // 30 秒视频文件大小估算 = bitrate × duration / 8
            let sizeMB = mbps * 30 / 8
            let sizeStr = sizeMB >= 10 ? String(format: "%.0f", sizeMB) : String(format: "%.1f", sizeMB)
            return "目标码率 \(mbpsStr) Mbps（1080p 基准）· 30 秒视频约 \(sizeStr) MB"
        } else {
            let crf = quality.crf(for: codec)
            let approxMbps: String
            // CRF 与视觉等效码率的经验对照（H.264 1080p）
            switch (codec, quality) {
            case (.h264, .low):    approxMbps = "约 2-4 Mbps"
            case (.h264, .medium): approxMbps = "约 5-8 Mbps"
            case (.h264, .high):   approxMbps = "约 12-20 Mbps"
            case (.h264, .lossless): approxMbps = "无损（极大文件）"
            case (.h265, .low):    approxMbps = "约 1-2 Mbps"
            case (.h265, .medium): approxMbps = "约 2-4 Mbps"
            case (.h265, .high):   approxMbps = "约 6-12 Mbps"
            case (.h265, .lossless): approxMbps = "无损（极大文件）"
            default:               approxMbps = ""
            }
            return "CRF \(crf)（数值越小画质越好）· 实际码率 \(approxMbps)"
        }
    }
}

extension ExportConfig {

    /// 从落盘的四串 rawValue 还原本次导出配置 —— **唯一**的还原处。
    ///
    /// 缺省值只有属性初值那四行这一份：读不认识的值（枚举改过名、或有人手改过 defaults）
    /// 就保持初值，这里不再另写一张缺省表 —— 否则"面板显示的缺省"和"导出的缺省"会分叉。
    /// 面板那四颗 `@AppStorage` 的初值也一律从 `ExportConfig()` 现取（见 `ExportView`）。
    init(deliveryTargetRaw: String, resolutionRaw: String,
         codecRaw: String, qualityRaw: String) {
        let base = ExportConfig()
        self.init(deliveryTarget: DeliveryTargetID(persisted: deliveryTargetRaw,
                                                   fallback: base.deliveryTarget),
                  resolution: DeliveryTier(persisted: resolutionRaw,
                                           fallback: base.resolution),
                  codec: ExportCodec(persisted: codecRaw, fallback: base.codec),
                  quality: ExportQuality(persisted: qualityRaw, fallback: base.quality))
    }
}

/// 导出进度
struct ExportProgress: Sendable {
    let phase: Phase
    let progress: Double    // 0.0 - 1.0
    let description: String

    enum Phase: Sendable {
        case cutting        // 裁切片段
        case concatenating  // 拼接
        case encoding       // 编码
        case completed      // 完成
        case failed         // 失败
    }
}

/// 导出任务的输入数据（值类型，可安全跨 actor 传递）
struct ExportInput: Sendable {
    let segments: [(path: String, start: Double, end: Double)]
    let maxWidth: Int
    let maxHeight: Int

    /// 从 MixScheme 提取导出数据（必须在 @MainActor 上调用）
    @MainActor
    static func from(scheme: MixScheme) -> ExportInput? {
        let orderedSegments = scheme.orderedSegments
        guard !orderedSegments.isEmpty else { return nil }

        var segments: [(path: String, start: Double, end: Double)] = []
        var maxWidth = 0
        var maxHeight = 0
        for schemeSeg in orderedSegments {
            guard let segment = schemeSeg.segment,
                  let video = segment.video else { continue }
            // 走"当前生效画面"（替换版=合成片整段；原版=源视频帧区间）
            let ep = segment.effectivePicture
            guard !ep.videoPath.isEmpty, FileHelper.isMaterialFilePresent(path: ep.videoPath) else { continue }
            segments.append((path: ep.videoPath, start: ep.startTime, end: ep.endTime))
            maxWidth = max(maxWidth, video.width)
            maxHeight = max(maxHeight, video.height)
        }
        guard !segments.isEmpty else { return nil }
        return ExportInput(segments: segments, maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

/// 视频导出服务
actor ExportService {

    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    /// 导出混剪方案为 MP4
    /// 导出一条成片。
    ///
    /// ⚠️ 失败/取消时**必须删掉半成品**：ffmpeg 收到 SIGTERM 会优雅收尾、把 moov atom 写完，
    /// 于是输出目录里会留下一个**双击能正常播放、但内容只有一半**的 mp4。
    /// 用户看不出异常，直到把它发出去才发现播一半就断了 —— 这是最坏的一种失败方式。
    func export(
        input: ExportInput,
        outputPath: String,
        config: ExportConfig = ExportConfig(),
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws {
        // ⚠️ 只能清理**本次导出自己创建**的文件。
        // 若目标路径上本来就有文件（重导同名方案、文件名撞车），而本次导出在早期就失败
        // （源素材缺失 / 磁盘满 / ffmpeg 起不来），无条件删除会把用户原有的好文件一起毁掉。
        let existedBefore = FileManager.default.fileExists(atPath: outputPath)
        do {
            try await performExport(input: input, outputPath: outputPath, config: config, onProgress: onProgress)
        } catch {
            // 删除截断的半成品，避免用户拿到"看起来正常"的坏文件
            if !existedBefore, FileManager.default.fileExists(atPath: outputPath) {
                try? FileManager.default.removeItem(atPath: outputPath)
                MixLog.info("[Export] 导出中断，已清理半成品: \(outputPath)")
            } else if existedBefore {
                MixLog.info("[Export] 导出中断，目标路径原本就有文件，保留不动: \(outputPath)")
            }
            throw error
        }
    }

    private func performExport(
        input: ExportInput,
        outputPath: String,
        config: ExportConfig = ExportConfig(),
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws {
        let segmentInfos = input.segments
        let maxWidth = input.maxWidth
        let maxHeight = input.maxHeight

        // 输出画布尺寸：唯一真源在 `MixCutCore.DeliveryCanvas`。
        // 这里原先是同一规则的第二份抄本（含一条 `maxWidth > maxHeight` 的横屏分支，
        // 与 DubExportService 那份并不一致）—— 两份"重复实现"行为不同，就是重复的代价。
        let canvas = DeliveryCanvas.size(tier: config.resolution,
                                         sourceMaxWidth: maxWidth,
                                         sourceMaxHeight: maxHeight)
        if let blocked = DeliveryGate.rejectionMessage(for: config.deliveryTarget.spec,
                                                       width: canvas.width,
                                                       height: canvas.height) {
            throw ExportError.deliveryBlocked(blocked)
        }
        let resolution = canvas.filterString

        // 时长闸：面板原文第四条校验「4s≤时长≤300s」。整方案导出确定是交付件，所以硬拦。
        // 与尺寸闸分开判，因为没有证据说明平台先查哪一条（见 DeliverySpec.verdict 的注释）。
        let totalSeconds = segmentInfos.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        if let blocked = DeliveryGate.durationRejectionMessage(for: config.deliveryTarget.spec,
                                                               seconds: totalSeconds) {
            throw ExportError.deliveryBlocked(blocked)
        }

        onProgress?(ExportProgress(
            phase: .encoding,
            progress: 0.05,
            description: "正在编码拼接 \(segmentInfos.count) 个片段..."
        ))

        try await ffmpeg.concat(
            segments: segmentInfos,
            outputPath: outputPath,
            resolution: resolution,
            crf: config.quality.crf(for: config.codec),
            codec: config.codec.ffmpegCodec,
            isHardware: config.codec.isHardware,
            videoBitrateKbps: config.quality.videoBitrateKbps(for: config.codec),
            onProgress: { ffmpegProgress in
                onProgress?(ExportProgress(
                    phase: .encoding,
                    progress: 0.05 + ffmpegProgress.percentage * 0.9,
                    description: "正在编码... \(Int(ffmpegProgress.percentage * 100))%"
                ))
            }
        )

        // 后置回读：证明"计划画布"真的等于"落盘画布"。
        //
        // 为什么必须有这一步：2026-10-19 整批 41 条成片被千川拒收，而导出全程零信号 ——
        // 这条腿此前只回读 `start_time` 与 `duration`，**从不回读宽高**。计划值与实际值
        // 一旦分叉（档位算错、滤镜被改、编码器自行降采样），只有拿到文件的人才会发现。
        // 探测失败同样算失败：拿不到证据不等于证据是好的。
        let actual = await ffmpeg.probeCanvasSize(path: outputPath)
        guard let actual else {
            throw ExportError.canvasUnverifiable(outputPath)
        }
        if actual != canvas {
            throw ExportError.canvasMismatch(
                planned: "\(canvas.width)×\(canvas.height)",
                actual: "\(actual.width)×\(actual.height)")
        }

        onProgress?(ExportProgress(
            phase: .completed,
            progress: 1.0,
            description: "导出完成"
        ))
    }
}

/// 导出目标目录的预检。
///
/// 不做预检的话，目录不可写或磁盘不够时，每条视频都要完整跑一遍 ffmpeg 才失败，
/// 20 条任务全跑完才在结果页列出 20 条同样的错误 —— 既浪费几十分钟，
/// 报错也淹没在一堆重复条目里。选目录的当下就该说清楚。
enum ExportDestination {

    /// 校验目录可用；有问题返回**人话说明**，没问题返回 nil。
    /// - Parameter estimatedBytes: 本次导出预计占用的字节数（可选，传了才做空间检查）。
    static func validate(directory: URL, estimatedBytes: Int64? = nil) -> String? {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return "选择的位置不存在或不是文件夹，请重新选择。"
        }
        guard fm.isWritableFile(atPath: directory.path) else {
            return "没有写入「\(directory.lastPathComponent)」的权限。请换一个目录（例如「桌面」或「下载」），或在「系统设置 → 隐私与安全性 → 文件与文件夹」里授予 \(Brand.displayName) 访问权限。"
        }

        if let estimatedBytes, estimatedBytes > 0 {
            let available = (try? directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage) ?? nil
            if let available, available < estimatedBytes {
                let need = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
                let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "磁盘空间可能不足：本次导出预计需要约 \(need)，该磁盘当前可用 \(have)。请清理磁盘或换一个磁盘上的目录。"
            }
        }
        return nil
    }
}

/// 导出错误
enum ExportError: LocalizedError {
    case noSegments
    case noValidSegments
    case encodingFailed(String)
    case missingVocals(String)
    case deliveryBlocked(String)
    case canvasMismatch(planned: String, actual: String)
    case canvasUnverifiable(String)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "方案中没有任何分镜"
        case .noValidSegments:
            return "方案中没有有效的分镜（可能视频文件不存在）"
        case .encodingFailed(let detail):
            return "编码失败: \(detail)"
        case .missingVocals(let path):
            return "人声分离产物缺失（\((path as NSString).lastPathComponent)），无法去除原 BGM。请重新导出（会自动重新分离）"
        case .deliveryBlocked(let why):
            return why
        case .canvasMismatch(let planned, let actual):
            return "成片实际画布 \(actual) 与计划画布 \(planned) 不符，已丢弃半成品不交付"
        case .canvasUnverifiable(let path):
            return "无法回读成片画布尺寸（\((path as NSString).lastPathComponent)），"
                 + "不能凭「没读到」就当合格；请检查 ffprobe 是否可用后重试"
        }
    }
}
