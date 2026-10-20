import Foundation

/// 单个导出任务（值类型，可跨 actor 传递）。
enum VariantExportJob: Sendable {
    /// 原版：按帧精确切出，**仍是 h264_videotoolbox 重编码**（不是流复制，见 cutSegment）。
    case original(sourcePath: String, startTime: Double, endTime: Double, fps: Double, fileName: String)
    /// 变体：dub 渲染（含 BGM）。
    case variant(spec: DubSegmentSpec, videoWidth: Int, videoHeight: Int, fileName: String)

    var fileName: String {
        switch self {
        case let .original(_, _, _, _, name): return name
        case let .variant(_, _, _, name): return name
        }
    }
}

/// 导出进度（纯值，不耦合 SwiftData）。
struct VariantExportProgress: Sendable {
    let total: Int
    let completed: Int
    let currentName: String?
    let failed: [(String, String)]   // (文件名, 错误)
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// 从选中分镜解析出导出任务（@MainActor：读 SwiftData）。
enum VariantExportInput {
    @MainActor
    /// 因缺少源视频而**无法导出**的分镜编号。
    ///
    /// `from(segments:)` 对这些分镜是直接 `continue` 跳过的，于是弹窗标题写着"导出 20 个文件"、
    /// 实际只出 18 个，也没人告诉用户少了哪两个。这里单独收集出来，供 UI 如实提示。
    static func skippedSegmentNumbers(segments: [Segment], numberProvider: (Segment) -> Int) -> [Int] {
        segments.filter { $0.video == nil }.map(numberProvider).sorted()
    }

    static func from(segments: [Segment], numberProvider: (Segment) -> Int) -> [VariantExportJob] {
        // 1) 构造展开来源（仅含已生成音频的变体）
        var segByKey: [String: Segment] = [:]
        var dubByKey: [String: SegmentDub] = [:]
        var sources: [SegmentExportSource] = []

        for seg in segments {
            guard let video = seg.video else { continue }
            let key = seg.id.uuidString
            segByKey[key] = seg
            let stem = (video.name as NSString).deletingPathExtension
            // 只填"参与组合"的变体（combinationDubVariants），原版是否参与由 includeOriginal 决定
            let variants: [VariantRef] = seg.combinationDubVariants.map { dub in
                dubByKey[dub.id.uuidString] = dub
                return VariantRef(dubKey: dub.id.uuidString, textVariantIndex: dub.textVariantIndex)
            }
            sources.append(SegmentExportSource(
                segmentKey: key, sequenceNumber: numberProvider(seg),
                videoName: stem, isVoiceLocked: seg.isVoiceLocked,
                includeOriginal: seg.originalParticipatesInCombination, variants: variants))
        }

        // 2) 展开
        let items = SegmentExportExpander.expand(sources)

        // 3) 解析成可执行任务
        var jobs: [VariantExportJob] = []
        for item in items {
            guard let seg = segByKey[item.segmentKey], let video = seg.video else { continue }
            // 走"当前生效画面"（替换版=合成片整段；原版=源视频帧区间）
            let ep = seg.effectivePicture
            let fps = ep.fps > 0 ? ep.fps : 30
            if let dubKey = item.dubKey, let dub = dubByKey[dubKey],
               let audioPath = dub.audioFilePath {
                // BGM 切片源（整轨 bgm.wav），不存在则 nil（回退纯人声）
                let bgmPath: String? = {
                    guard let hash = video.contentHash, !hash.isEmpty else { return nil }
                    let p = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav").path
                    return FileManager.default.fileExists(atPath: p) ? p : nil
                }()
                // 逐句字幕：优先 captionLines；旧数据无对齐 → 整段一条兜底（防丢字幕）
                let capLines: [CaptionLine] = {
                    let lines = dub.captionLines
                    if !lines.isEmpty { return lines }
                    let whole = dub.rewrittenText.isEmpty ? seg.text : dub.rewrittenText
                    return whole.isEmpty ? [] : [CaptionLine(text: whole, start: 0, end: seg.duration)]
                }()
                let spec = DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionLines: capLines, hasHardSubtitle: seg.hasHardSubtitle,
                    maskStyleRaw: seg.maskStyleRaw, maskRect: seg.maskRect, isVoiceLocked: false,
                    dubAudioPath: audioPath, freezePadFrames: dub.freezePadFrames,
                    trailingSilence: dub.trailingSilence, bgmAudioPath: bgmPath,
                    subtitleFontRatio: seg.subtitleFontRatio)
                jobs.append(.variant(spec: spec, videoWidth: video.width, videoHeight: video.height,
                                     fileName: item.fileName))
            } else {
                jobs.append(.original(sourcePath: ep.videoPath, startTime: ep.startTime,
                                      endTime: ep.endTime, fps: fps, fileName: item.fileName))
            }
        }
        return jobs
    }
}

/// 变体感知批量导出：原版走 `cutSegment`（重编码、**不带 scale**），变体走 dub 渲染。
///
/// 两条腿**都不许静默出规格外的交付件**，但收法不同（这是刻意的，别改成一样）：
/// · 变体：算出目标画布 → 前置闸 → 渲染 → 回读（见 `DubExportService.exportSingleSegment`）；
/// · 原版：**不缩放**（"原版"就是源片原样，加 scale 会把这个名字变成谎话）⇒ 前置闸判这颗文件
///   自己的宽高＋切片时长，不合就**整条不导**，切完再回读一次（`deliverOriginal`）。
/// 历史：原版腿曾是台账 §六-2 的漏口 #7（绕过全部尺寸决策），2026-10-20 按"只拦不改"收口。
actor VariantBatchExportService {
    private let ffmpeg: FFmpegRunner
    private let dubExport: DubExportService

    init(ffmpeg: FFmpegRunner = FFmpegRunner(), dubExport: DubExportService = DubExportService()) {
        self.ffmpeg = ffmpeg
        self.dubExport = dubExport
    }

    func exportAll(
        jobs: [VariantExportJob],
        outputDirectory: URL,
        config: ExportConfig = ExportConfig(),
        onProgress: @Sendable @MainActor (VariantExportProgress) -> Void
    ) async -> (succeeded: Int, failed: [(String, String)]) {
        var succeeded = 0
        var failed: [(String, String)] = []
        var usedNames: Set<String> = []
        let total = jobs.count

        for (idx, job) in jobs.enumerated() {
            // 取消检查放在**每个任务开始前**。原先只在任务跑完后检查，
            // 用户点了取消还要再等一整条视频编码完，而且那条被 SIGTERM 打断的还会被记成「失败」。
            if Task.isCancelled { break }

            await onProgress(VariantExportProgress(total: total, completed: idx,
                                                   currentName: job.fileName, failed: failed))
            let outURL = Self.uniqueDestination(directory: outputDirectory,
                                                preferredName: job.fileName, usedInBatch: &usedNames)
            do {
                switch job {
                case let .original(sourcePath, startTime, endTime, fps, _):
                    try await deliverOriginal(sourcePath: sourcePath, start: startTime, end: endTime,
                                              fps: fps, to: outURL.path, config: config)
                case let .variant(spec, w, h, _):
                    try await dubExport.exportSingleSegment(spec: spec, videoWidth: w, videoHeight: h,
                                                            outputPath: outURL.path, config: config)
                }
                succeeded += 1
            } catch {
                // ⚠️ 必须删掉半成品。取消时 ffmpeg 收到 SIGTERM 会优雅收尾、把 moov atom 写完，
                // 于是用户目录里留下一个**双击能正常播放、但内容只有一半**的 mp4 ——
                // 看不出异常，直到发出去才发现播一半就断了。
                // outURL 由 uniqueDestination 生成，必然是本次导出新建的文件，删除是安全的。
                try? FileManager.default.removeItem(at: outURL)

                if Task.isCancelled {
                    MixLog.info("[BatchExport] 已取消，清理半成品：\(outURL.lastPathComponent)")
                    break   // 用户主动取消，不计为失败
                }
                failed.append((job.fileName, FriendlyError.reason(for: error)))
                MixLog.error("变体导出失败 \(job.fileName): \(error)")
            }
        }

        await onProgress(VariantExportProgress(total: total, completed: succeeded + failed.count,
                                               currentName: nil, failed: failed))
        return (succeeded, failed)
    }

    /// 原版这条腿：**切之前先按交付目标校验，切完再回读一次落盘宽高**。
    ///
    /// 为什么是"只拦不改"：`cutSegment` 不带 scale，产物尺寸就是这颗文件自己的尺寸 ——
    /// 而"原版"这个词的意思就是"按源片原样"，给它加缩放等于把这个名字变成谎话。
    /// 所以这里判的是**实际会出片的那颗文件**，不合规格就一条不导（进失败清单，原因由 Core 的
    /// 闸口给出），而不是把它缩成合规。
    ///
    /// 为什么现读而不是取 `video.width/height`：「当前生效画面」可能是**合成过的中间片**
    /// （见 `effectivePicture`，分镜编辑后尺寸与源视频并不必然相同）⇒ 判错一份数字等于闸白挂。
    ///
    /// 读不到宽高即整条失败：「没读到」不能当成"合格"（与整方案导出那条腿同规）。
    private func deliverOriginal(sourcePath: String, start: Double, end: Double, fps: Double,
                                 to outputPath: String, config: ExportConfig) async throws {
        let spec = config.deliveryTarget.spec
        guard let planned = await ffmpeg.probeCanvasSize(path: sourcePath) else {
            throw ExportError.canvasUnverifiable(sourcePath)
        }
        if let blocked = DeliveryGate.rejectionMessage(for: spec,
                                                       width: planned.width,
                                                       height: planned.height) {
            throw ExportError.deliveryBlocked(blocked)
        }
        if let blocked = DeliveryGate.durationRejectionMessage(for: spec,
                                                               seconds: max(0, end - start)) {
            throw ExportError.deliveryBlocked(blocked)
        }

        try await ffmpeg.cutSegment(from: sourcePath, start: start, end: end, fps: fps, to: outputPath)

        // 后置回读：这条腿此前**零回读** —— 计划与落盘分叉时，只有拿到文件的人才会发现。
        guard let landed = await ffmpeg.probeCanvasSize(path: outputPath) else {
            throw ExportError.canvasUnverifiable(outputPath)
        }
        if landed != planned {
            throw ExportError.canvasMismatch(planned: "\(planned.width)×\(planned.height)",
                                             actual: "\(landed.width)×\(landed.height)")
        }
    }

    /// 同名冲突 → 加 (1)(2)（与 BatchSegmentExportService 同策略）。
    private static func uniqueDestination(directory: URL, preferredName: String,
                                          usedInBatch: inout Set<String>) -> URL {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            usedInBatch.contains(name) || fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        var candidate = preferredName
        if !exists(candidate) { usedInBatch.insert(candidate); return directory.appendingPathComponent(candidate) }
        let url = URL(fileURLWithPath: preferredName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1
        while exists(candidate) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
            if counter > 9999 { break }
        }
        usedInBatch.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
