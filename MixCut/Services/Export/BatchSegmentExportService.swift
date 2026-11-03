import Foundation

/// 单个分镜的导出任务
struct BatchExportItem: Sendable, Identifiable {
    let id: UUID
    let sourcePath: String        // 源视频路径
    let sourceVideoName: String   // 不含扩展名的视频名
    let startTime: Double
    let endTime: Double
    let sequenceNumber: Int        // 分镜在所属视频内的编号（1-based）
    var fps: Double = 0            // 帧率：>0 时按帧精确切，0 退回按秒

    /// 默认文件名：{编号}_{原视频名}.mp4
    var fileName: String {
        "\(sequenceNumber)_\(sourceVideoName).mp4"
    }

    var duration: Double { endTime - startTime }
}

/// 单个分镜的导出进度
struct SegmentBatchExportProgress: Sendable {
    let totalCount: Int
    let completedCount: Int
    let currentItem: BatchExportItem?
    let currentItemProgress: Double   // 0...1
    let failedItems: [(BatchExportItem, String)]   // 失败的（item, 错误信息）

    var totalProgress: Double {
        guard totalCount > 0 else { return 0 }
        return (Double(completedCount) + currentItemProgress) / Double(totalCount)
    }
}

/// 批量分镜导出服务
///
/// 每个分镜按 start/end 切出独立 MP4。
///
/// ⚠️ 这里**不是流复制**（本文件此前写的是「用流复制（-c copy）方式…无重编码，画质无损」，
/// 那是假的）：`FFmpegRunner.cutSegment` 用的是 `-c:v h264_videotoolbox -b:v 8000k`，
/// 方法体内 `-c copy` 出现 **0 次**。实测（2026-10-19，同一条 20s 1080×1920 源）：
/// 真流复制 0.10s，`cutSegment` 3.84s / 4.57s —— 差约 40 倍，且是**有损重编码**。
/// 报耗时或报画质时别再用「流复制」那个说法。
actor BatchSegmentExportService {
    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    /// 执行批量导出
    /// - Parameters:
    ///   - items: 待导出的分镜列表
    ///   - outputDirectory: 输出目录（绝对路径）
    ///   - spec: 本次导出的交付口径。**必填**：MCP 的 `export_segments` 与整方案导出同规，
    ///     缺省由工具入口解析成 `qianchuanVertical`，不许在服务里再藏一份默认值。
    ///   - onProgress: 进度回调（@MainActor，回主线程刷 UI）
    /// - Returns: (成功数, 失败列表)
    func exportAll(
        items: [BatchExportItem],
        outputDirectory: URL,
        spec: DeliverySpec,
        onProgress: @Sendable @MainActor (SegmentBatchExportProgress) -> Void
    ) async -> (succeeded: Int, failed: [(BatchExportItem, String)]) {
        var succeeded = 0
        var failed: [(BatchExportItem, String)] = []
        let total = items.count

        // 用一个 set 跟踪已用过的文件名，避免本批次内同名冲突
        var usedNames: Set<String> = []

        for (idx, item) in items.enumerated() {
            // 进度：开始当前 item
            await onProgress(SegmentBatchExportProgress(
                totalCount: total,
                completedCount: idx,
                currentItem: item,
                currentItemProgress: 0,
                failedItems: failed
            ))

            // 处理同名冲突：磁盘上 / 本批次内 已存在 → 加 (1) (2)
            let outputURL = Self.uniqueDestination(
                directory: outputDirectory,
                preferredName: item.fileName,
                usedInBatch: &usedNames
            )

            do {
                // 切前两条闸：宽度/比例/分辨率区间 + 时长区间。
                // `cutSegment` 不带 scale ⇒ 产物尺寸就是源片尺寸；这条腿只能「只拦不改」。
                guard let planned = await ffmpeg.probeCanvasSize(path: item.sourcePath) else {
                    throw ExportError.canvasUnverifiable(item.sourcePath)
                }
                if let blocked = DeliveryGate.rejectionMessage(for: spec,
                                                              width: planned.width,
                                                              height: planned.height) {
                    throw ExportError.deliveryBlocked(blocked)
                }
                if let blocked = DeliveryGate.durationRejectionMessage(for: spec,
                                                                      seconds: max(0, item.duration)) {
                    throw ExportError.deliveryBlocked(blocked)
                }

                try await ffmpeg.cutSegment(
                    from: item.sourcePath,
                    start: item.startTime,
                    end: item.endTime,
                    fps: item.fps,
                    to: outputURL.path
                )

                // 切后回读：这条腿此前零回读 —— 计划与落盘分叉时，只有拿到文件的人才会发现。
                guard let landed = await ffmpeg.probeCanvasSize(path: outputURL.path) else {
                    throw ExportError.canvasUnverifiable(outputURL.path)
                }
                if landed != planned {
                    throw ExportError.canvasMismatch(planned: "\(planned.width)×\(planned.height)",
                                                     actual: "\(landed.width)×\(landed.height)")
                }
                succeeded += 1
            } catch {
                // 失败/半成品一律删掉，不把「双击能播、内容却是半条」的文件留在用户目录。
                try? FileManager.default.removeItem(at: outputURL)
                failed.append((item, FriendlyError.reason(for: error)))
                MixLog.error("批量导出失败 \(item.fileName): \(error)")
            }

            // 进度：当前 item 完成
            await onProgress(SegmentBatchExportProgress(
                totalCount: total,
                completedCount: idx + 1,
                currentItem: idx + 1 < total ? items[idx + 1] : nil,
                currentItemProgress: 0,
                failedItems: failed
            ))

            // 让出主线程，确保 UI 能更新
            try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms
            if Task.isCancelled { break }
        }

        return (succeeded, failed)
    }

    /// 生成唯一文件名：磁盘已有 或 本批次内已用 → 加 (1) (2)
    private static func uniqueDestination(
        directory: URL,
        preferredName: String,
        usedInBatch: inout Set<String>
    ) -> URL {
        let fileManager = FileManager.default
        var candidate = preferredName

        func exists(_ name: String) -> Bool {
            if usedInBatch.contains(name) { return true }
            return fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        if !exists(candidate) {
            usedInBatch.insert(candidate)
            return directory.appendingPathComponent(candidate)
        }

        // 分离扩展名
        let url = URL(fileURLWithPath: preferredName)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var counter = 1
        while exists(candidate) {
            candidate = ext.isEmpty
                ? "\(stem) (\(counter))"
                : "\(stem) (\(counter)).\(ext)"
            counter += 1
            if counter > 9999 { break }   // 防御无限循环
        }
        usedInBatch.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
