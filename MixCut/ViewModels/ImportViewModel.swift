import Foundation
import SwiftData
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

/// 导入阶段
enum ImportPhase: String {
    case idle = "等待导入"
    case copying = "复制文件中"
    case extractingMetadata = "提取元数据"
    case generatingThumbnail = "生成缩略图"
    case detectingScenes = "检测镜头"
    case transcribing = "语音识别"
    case analyzing = "AI 语义分析"
    case optimizing = "优化边界"
    case completed = "完成"
    case failed = "失败"
}

/// 一次导入调用的结构化结果（给 Agent/MCP 用；UI 路径忽略返回值）
struct ImportReport: Sendable {
    var importedVideoIDs: [UUID] = []
    var importedNames: [String] = []
    var linkedExistingNames: [String] = []
    var skippedDuplicateNames: [String] = []
    var failed: [FailedItem] = []
    /// 整体中止原因（全部重复 / 磁盘不足 / 上下文缺失 / 用户停止），nil 表示正常走完
    var abortMessage: String?

    struct FailedItem: Sendable {
        let name: String
        let reason: String
    }
}

/// 视频导入及分析 ViewModel
@MainActor
@Observable
final class ImportViewModel {
    var phase: ImportPhase = .idle
    var progress: Double = 0
    var progressDescription: String = ""
    var isProcessing = false
    var errorMessage: String?

    /// 已取消的视频 ID（删除视频时加入，用于跳过后续处理）
    private var cancelledVideoIDs: Set<UUID> = []

    /// 本批导入新视频的默认来源（importVideos 入口写入，importOrLinkVideo 读取）
    private var pendingBatchSource: SegmentSource = .curated

    private var modelContext: ModelContext?
    private let ffmpeg = FFmpegRunner()

    /// 正在重认台词的视频（控制卡片 loading）。
    var reidentifyingVideoIDs: Set<UUID> = []
    /// 逐段重认的可见进度 `已完成/总数`（计划 §6：逐段阶段必须看得到 k/n，不能只显示"转圈"）。
    var reidentifyProgress: [UUID: (done: Int, total: Int)] = [:]

    private let sceneDetection = SceneDetectionService()
    private let asrService = ASRService()
    private let aiAnalysis = AIAnalysisService()
    /// `Segment` 的唯一生产者。边界吸附与搬字实现都在它里面，不再由本 VM 持有。
    private let segmentCommitter = SegmentCommitter()

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 用户主动停止导入。
    ///
    /// ⚠️ 这里**只做提示**，不直接改 isProcessing/phase —— 因为后台流程可能正跑在某一步，
    /// 随后会把这些状态又写回"运行中"，造成"点了停止却还在转"的假象。
    /// 真正的收尾统一由 `importVideos` 内部的取消检查点走 `finishAsCancelled` 完成。
    func markCancelledByUser() {
        progressDescription = "正在停止…"
        ToastCenter.shared.show("正在停止导入，已完成的素材会保留", icon: "stop.circle.fill", style: .info)
    }

    /// 取消后的统一收尾：把状态收回闲置态，项目回到可用状态。
    private func finishAsCancelled(project: Project, context: ModelContext) {
        project.status = .ready
        project.updatedAt = Date()
        context.safeSave()
        isProcessing = false
        phase = .idle
        progress = 0
        progressDescription = ""
        MixLog.info("[Import] 用户停止导入，已完成部分保留")
        ToastCenter.shared.show("已停止导入，已完成的素材已保留", icon: "stop.circle.fill", style: .info)
    }

    /// 导入视频文件列表（全局去重 + 共享引用）
    @discardableResult
    /// - Parameter defaultSource: 本批新视频的默认素材来源（写在 Video 上，切出的分镜继承）。
    ///   全局去重命中的**已有视频不覆写**其来源与 ownerProject（导入事实归首次导入所有）。
    func importVideos(urls: [URL], to project: Project,
                      defaultSource: SegmentSource = .curated) async -> ImportReport {
        var report = ImportReport()
        isProcessing = true
        errorMessage = nil
        pendingBatchSource = defaultSource

        // 去重：检查该视频是否已在当前项目中
        var dedupedURLs: [URL] = []
        var skippedNames: [String] = []

        for url in urls {
            if isDuplicate(url: url, in: project) {
                skippedNames.append(url.lastPathComponent)
                report.skippedDuplicateNames.append(url.lastPathComponent)
            } else {
                dedupedURLs.append(url)
            }
        }

        if !skippedNames.isEmpty {
            let skippedList = skippedNames.joined(separator: "、")
            if dedupedURLs.isEmpty {
                errorMessage = "所有视频均已导入过：\(skippedList)"
                isProcessing = false
                phase = .completed
                progress = 1.0
                report.abortMessage = errorMessage
                return report
            } else {
                errorMessage = "已跳过重复视频：\(skippedList)"
            }
        }

        // 检查磁盘可用空间
        let totalFileSize = dedupedURLs.compactMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        }.reduce(0, +)
        let requiredSpace = totalFileSize * 2
        if let availableSpace = try? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           availableSpace < requiredSpace {
            let needed = ByteCountFormatter.string(fromByteCount: requiredSpace, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
            errorMessage = "磁盘空间不足：需要约 \(needed)，当前可用 \(available)"
            isProcessing = false
            report.abortMessage = errorMessage
            return report
        }

        guard let context = modelContext else {
            report.abortMessage = "内部错误：modelContext 未注入"
            return report
        }

        project.status = .importing
        context.safeSave()

        // ========== 阶段 1：快速创建/关联视频实体 ==========
        var videosToAnalyze: [Video] = []
        for (index, url) in dedupedURLs.enumerated() {
            // 用户点了「停止导入」：立刻停手，已导入的保留（停止 ≠ 删除）
            if Task.isCancelled {
                finishAsCancelled(project: project, context: context)
                report.abortMessage = "用户停止导入"
                return report
            }
            progressDescription = "导入第 \(index + 1)/\(dedupedURLs.count) 个视频..."
            progress = Double(index) / Double(dedupedURLs.count) * 0.2

            do {
                let (video, needsAnalysis) = try await importOrLinkVideo(url: url, to: project)
                if needsAnalysis {
                    videosToAnalyze.append(video)
                    report.importedVideoIDs.append(video.id)
                    report.importedNames.append(video.name)
                } else {
                    MixLog.info(" 视频已存在且已分析，直接关联: \(video.name)")
                    report.linkedExistingNames.append(video.name)
                }
            } catch {
                let prevError = errorMessage.map { $0 + "\n" } ?? ""
                errorMessage = prevError + "导入 \(url.lastPathComponent) 失败: \(FriendlyError.reason(for: error))"
                report.failed.append(.init(name: url.lastPathComponent, reason: FriendlyError.reason(for: error)))
            }
        }

        // ========== 阶段 2：并行执行视频分析 ==========
        if !videosToAnalyze.isEmpty {
            project.status = .analyzing
            // 先把所有待分析视频标为「等待中」，否则排在 maxConcurrency 之后的视频
            // status 仍是 .imported，UI 会显示成「孤立未分析」并出现错误的「AI 分析」按钮
            // analyzeVideo 入口第一步会把 status 覆盖为 .detectingScenes
            for v in videosToAnalyze {
                v.status = .queued
            }
            context.safeSave()

            let totalVideos = videosToAnalyze.count
            var completedCount = 0
            // 使用 ConcurrencyPolicy 而非硬编码，自动按 Apple Silicon Media Engine 数适配
            let maxConcurrency = min(ConcurrencyPolicy.maxAnalyzeConcurrency(), totalVideos)

            progressDescription = "并行分析 \(totalVideos) 个视频（\(maxConcurrency) 路并发）..."

            await withTaskGroup(of: Void.self) { group in
                var videoIterator = videosToAnalyze.makeIterator()
                var runningCount = 0

                while !Task.isCancelled, runningCount < maxConcurrency, let video = videoIterator.next() {
                    runningCount += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.analyzeVideo(video)
                        } catch is CancellationError {
                            // 用户删除视频，跳过
                        } catch {
                            await self.handleAnalyzeFailure(video: video, error: error)
                        }
                    }
                }

                for await _ in group {
                    if Task.isCancelled { break }   // 已停止：不再补新任务，让已在跑的自然收尾
                    completedCount += 1
                    progress = 0.2 + Double(completedCount) / Double(totalVideos) * 0.8
                    progressDescription = "已完成 \(completedCount)/\(totalVideos) 个视频分析"

                    if let nextVideo = videoIterator.next() {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            do {
                                try await self.analyzeVideo(nextVideo)
                            } catch is CancellationError {
                                // 用户删除视频，跳过
                            } catch {
                                await self.handleAnalyzeFailure(video: nextVideo, error: error)
                            }
                        }
                    }
                }
            }
        }

        if Task.isCancelled {
            finishAsCancelled(project: project, context: context)
            report.abortMessage = "用户停止导入"
            return report
        }

        project.status = .ready
        project.updatedAt = Date()
        context.safeSave()

        phase = .completed
        progress = 1.0
        isProcessing = false

        let totalDone = videosToAnalyze.count
        if totalDone > 0 {
            ToastCenter.shared.show("已分析完成 \(totalDone) 个视频", icon: "checkmark.seal.fill", style: .success)
        }
        return report
    }

    /// 仅重新跑 ASR（用于 ASR 输出粒度异常时用户主动触发）
    /// 重做完后会自动连带重做 AI 分析（因为 sentence 变了 → AI 切分也要变）
    func retryASR(for video: Video, in project: Project) async {
        guard let context = modelContext else { return }
        MixLog.info("retryASR 被调用: video=\(video.name)")

        // 清空旧的 ASR 数据 → analyzeVideo 流程中 retryAIAnalysis 会重新识别
        video.transcript = ""
        video.asrWords = []
        video.asrSentences = []
        video.clearASRRun()

        // 清空旧分镜（避免 UI 卡在中间态）
        // ⚠️ 必须先 Array(...) 快照再迭代 delete，直接迭代 to-many 关系会行为未定义
        // Segment.schemeSegments 已设 @Relationship(.cascade)，删 Segment 时 SchemeSegment 自动级联删
        for oldSeg in Array(video.segments) {
            context.delete(oldSeg)
        }
        video.status = .transcribing
        video.errorMessage = nil
        errorMessage = nil
        context.safeSave()

        // 跑完整重试链
        await retryAIAnalysis(for: video, in: project)
    }

    /// 重试 AI 分析
    func retryAIAnalysis(for video: Video, in project: Project) async {
        MixLog.info("retryAIAnalysis 被调用: video=\(video.name)")
        guard let context = modelContext else {
            MixLog.error("modelContext 为 nil！无法重试")
            return
        }
        video.status = .analyzing
        video.errorMessage = nil
        errorMessage = nil
        context.safeSave()

        let asrText = video.transcript ?? ""
        let asrWords = video.asrWords

        let asr: TranscriptionResult
        if asrText.isEmpty && asrWords.isEmpty {
            MixLog.info(" ASR 数据为空，重新执行语音识别...")
            phase = .transcribing
            video.status = .transcribing
            context.safeSave()
            do {
                asr = try await asrService.transcribe(videoPath: video.localPath)
                video.transcript = asr.text
                video.asrWords = asr.words
                video.asrSentences = asr.rawSentences
                // 整片听写恒本机（能力线 R6）；档位按同一张探测表报，不在这里写死
                video.recordASRRun(engine: .local, tier: ASRService.modelReport().selectedTier)
                context.safeSave()
            } catch {
                MixLog.error(" ASR 失败: \(error)")
                video.errorMessage = "语音识别失败: \(FriendlyError.reason(for: error))"
                video.status = .imported
                context.safeSave()
                isProcessing = false
                phase = .idle
                return
            }
        } else {
            asr = TranscriptionResult(
                text: asrText,
                words: asrWords,
                rawSentences: video.asrSentences,
                language: "zh",
                duration: video.duration
            )
        }

        phase = .detectingScenes
        var localAnalysis: VideoLocalAnalysis
        do {
            localAnalysis = try await sceneDetection.analyzeLocally(
                videoPath: video.localPath,
                duration: video.duration,
                fps: video.fps > 0 ? video.fps : 30
            )
        } catch {
            localAnalysis = VideoLocalAnalysis(
                sceneBoundaries: [], silencePeriods: [], iframePositions: [],
                videoDuration: video.duration, fps: video.fps > 0 ? video.fps : 30
            )
        }

        phase = .analyzing
        video.status = .analyzing
        context.safeSave()

        // 与首跑共用同一个分镜重建入口；差异只剩「重跑要先删旧分镜」这一条真实存在的。
        // 终态与收尾仍由这里落：重跑失败退回 .imported（此刻旧分镜还在，可再试）。
        do {
            let rebuild = try await rebuildSegments(
                video,
                asr: asr,
                localAnalysis: localAnalysis,
                context: context,
                clearsExistingSegments: true
            )
            switch rebuild {
            case .success:
                video.status = .completed
                video.errorMessage = nil
            case .aiFailed(let error):
                video.errorMessage = "AI 分析失败: \(FriendlyError.reason(for: error))"
                video.status = .imported
                context.safeSave()
                isProcessing = false
                phase = .idle
                return
            }
        } catch {
            // 重跑链以前没有取消检查（W1.5 补）。这里旧分镜尚未删 —— 检查点在删除之前 ——
            // 所以退回 .imported 就是如实状态：素材可用、分镜还是上一版那批。
            MixLog.info(" 重跑已取消: video=\(video.name)")
            video.status = .imported
            context.safeSave()
            isProcessing = false
            phase = .idle
            return
        }

        context.safeSave()
        phase = .completed
        isProcessing = false
    }

    // MARK: - 核心导入逻辑

    /// 导入或关联视频：先查全局是否已有同一视频，有则直接关联，无则创建新的
    /// 返回 (video, needsAnalysis) — needsAnalysis=false 表示已有完整分析数据
    private func importOrLinkVideo(url: URL, to project: Project) async throws -> (Video, Bool) {
        guard let context = modelContext else {
            throw NSError(domain: Brand.bundleID, code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未就绪"])
        }

        phase = .copying

        // 先计算文件 hash
        let hash = Self.computeFileHash(path: url.path)

        // 查找全局是否已有同 hash 的视频
        if let hash, let existingVideo = findExistingVideo(hash: hash, context: context) {
            // 已有此视频：幂等挂到本项目（同一素材第二次进来不产生第二行关联）
            ProjectVideo.associate(project: project, video: existingVideo, in: context)
            context.safeSave()
            MixLog.info(" 全局已有视频「\(existingVideo.name)」(hash=\(hash.prefix(8))...)，直接关联到项目")

            let needsAnalysis = existingVideo.status != .completed || existingVideo.segments.isEmpty
            return (existingVideo, needsAnalysis)
        }

        // 全局没有，创建新的
        let destURL: URL
        if let hash {
            destURL = try FileHelper.copyVideoToGlobal(from: url, contentHash: hash)
        } else {
            // hash 计算失败（极端情况），用 UUID 作为目录名
            destURL = try FileHelper.copyVideoToGlobal(from: url, contentHash: UUID().uuidString)
        }

        let video = Video(name: url.lastPathComponent, localPath: destURL.path)
        video.status = .imported
        video.contentHash = hash
        // 导入事实：首次导入所在项目 + 本批选定来源。命中去重复用的已有视频在上面的分支直接返回，
        // 不会走到这里，因此这两个事实字段不存在被覆写的路径。
        video.ownerProject = project
        video.defaultSourceRaw = pendingBatchSource.rawValue
        context.insert(video)

        // 创建 ProjectVideo 关联（幂等入口）
        ProjectVideo.associate(project: project, video: video, in: context)
        context.safeSave()

        // 提取元数据（失败不阻塞）
        do {
            try await extractMetadata(for: video, at: destURL)
        } catch {
            video.errorMessage = "元数据提取失败: \(FriendlyError.reason(for: error))"
        }

        // 生成视频缩略图（失败不阻塞）
        do {
            try await generateVideoThumbnail(for: video)
        } catch {
            MixLog.error("缩略图生成失败: video=\(video.name), error=\(error)")
        }

        context.safeSave()
        return (video, true)
    }

    /// 自建分镜单条时长上限（秒）。改这一个常量即可，文案会跟着走。
    static let selfSegmentMaxDuration: Double = 30

    /// 自建分镜载体视频 id 注册表（UserDefaults，schema 外持久化）。
    /// isUserUploaded 只存在 SwiftData 列里的话，误启动旧版本 App（schema 无此字段）会触发
    /// Core Data 降级迁移删列，新版再启动重建列时所有行归零（2026-07-28 实际发生）。
    /// 创建时同步记到这里，启动时由 MixCutApp.restoreSelfBuiltFlags 恢复。
    static let selfBuiltRegistryKey = "selfBuiltVideoIDs_v1"

    static func registerSelfBuiltVideo(_ id: UUID) {
        let ids = UserDefaults.standard.stringArray(forKey: selfBuiltRegistryKey) ?? []
        guard !ids.contains(id.uuidString) else { return }
        UserDefaults.standard.set(ids + [id.uuidString], forKey: selfBuiltRegistryKey)
    }

    /// 上传自建分镜：每个文件 = 一个分镜（不切分），只做 ASR 台词提取 + AI 只打标。
    /// 处理态用载体视频的 status 驱动占位卡（transcribing/analyzing/completed）。见 PRD/TRD 05。
    /// - Parameter source: 用户在上传面板选定的素材来源（自拍/搬运/AI），写入载体视频与单分镜
    func importSelfSegments(urls: [URL], into project: Project,
                             source: SegmentSource = .curated,
                             onUpdate: @escaping @MainActor () -> Void = {}) async {
        guard let context = modelContext else { return }
        var skippedLong: [String] = []
        var skippedDup = 0
        // ⚠️ 以下两类失败以前是静默 `continue`，文件会**凭空消失**、用户毫无解释。
        var failedUnreadable: [String] = []   // 读不出时长：文件损坏 / 格式不支持
        var failedCopy: [String] = []         // 落盘失败：磁盘满 / 无权限 / 外接盘拔出
        for url in urls {
            // 1) 时长校验（上限见 selfSegmentMaxDuration）
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration))?.seconds ?? 0
            guard dur > 0 else { failedUnreadable.append(url.lastPathComponent); continue }
            guard dur <= Self.selfSegmentMaxDuration else { skippedLong.append(url.lastPathComponent); continue }

            // 2) 去重
            let hash = Self.computeFileHash(path: url.path)
            if let hash, findExistingVideo(hash: hash, context: context) != nil { skippedDup += 1; continue }

            // 3) 落盘 + 建载体视频（打「自建」标记；status 作处理态）
            guard let destURL = try? FileHelper.copyVideoToGlobal(from: url, contentHash: hash ?? UUID().uuidString) else {
                failedCopy.append(url.lastPathComponent)
                continue
            }
            let video = Video(name: url.lastPathComponent, localPath: destURL.path)
            video.contentHash = hash
            video.isUserUploaded = true
            // 自建分镜同样记录导入事实（首次导入项目 + 用户选定来源）
            video.ownerProject = project
            video.defaultSourceRaw = source.rawValue
            Self.registerSelfBuiltVideo(video.id)
            video.status = .transcribing
            context.insert(video)
            ProjectVideo.associate(project: project, video: video, in: context)
            context.safeSave()

            // 4) 元数据 + 整片首帧缩略图（失败不阻塞）
            try? await extractMetadata(for: video, at: destURL)
            try? await generateVideoThumbnail(for: video)

            // 5) 建「覆盖整片」的分镜
            let seg = segmentCommitter.commitWholeVideo(for: video, source: source, context: context)
            context.safeSave()
            onUpdate()   // 占位卡「识别中…」出现

            // 6) ASR 台词（whisper 整片；失败留空，可后续手填/重识别）
            if let asr = try? await asrService.transcribe(videoPath: destURL.path) {
                // 自建分镜文件：这段的台词是"整听用户自己上传的那个文件"得来的，
                // 不标成 fullVideoSlice（那是母体整片切出来的），否则来源会说谎。
                seg.setText(asr.text, source: .uploadedClip)
                context.safeSave()
            }

            // 7) AI 只打标（不切分）；失败给默认「过渡」
            video.status = .analyzing
            context.safeSave()
            onUpdate()   // 占位卡切「打标中…」
            if !seg.text.isEmpty, let tags = try? await aiAnalysis.tagSingleSegment(text: seg.text) {
                seg.semanticTypes = tags.types
                seg.positionType = tags.position
                seg.keywords = tags.keywords
            } else if seg.semanticTypes.isEmpty {
                seg.semanticTypes = [.transition]
            }

            // 8) 就绪
            video.status = .completed
            context.safeSave()
            onUpdate()   // 占位卡转正常分镜卡
        }
        if !skippedLong.isEmpty {
            ToastCenter.shared.show("\(skippedLong.count) 个文件超过 \(Int(Self.selfSegmentMaxDuration)) 秒已跳过", icon: "exclamationmark.triangle.fill")
        }
        if skippedDup > 0 {
            ToastCenter.shared.show("\(skippedDup) 个已存在，已跳过", icon: "info.circle.fill")
        }
        // 真失败必须出声，且说明原因与下一步——不能让文件无声无息地消失
        if !failedUnreadable.isEmpty {
            ToastCenter.shared.show("\(failedUnreadable.count) 个文件无法读取（已损坏或格式不支持），未导入：\(failedUnreadable.prefix(3).joined(separator: "、"))",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
        }
        if !failedCopy.isEmpty {
            ToastCenter.shared.show("\(failedCopy.count) 个文件保存失败（磁盘空间不足或无写入权限），未导入：\(failedCopy.prefix(3).joined(separator: "、"))",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
        }
    }

    /// 执行视频分析（场景检测 + ASR + AI 分析 + 边界优化）
    private func analyzeVideo(_ video: Video) async throws {
        guard let context = modelContext else { return }

        try checkCancelled(video)

        // Step 1: 本地视频分析
        video.status = .detectingScenes
        context.safeSave()
        phase = .detectingScenes

        var localAnalysis = VideoLocalAnalysis(
            sceneBoundaries: [], silencePeriods: [], iframePositions: [],
            videoDuration: video.duration, fps: video.fps > 0 ? video.fps : 30
        )
        do {
            localAnalysis = try await sceneDetection.analyzeLocally(
                videoPath: video.localPath,
                duration: video.duration,
                fps: video.fps > 0 ? video.fps : 30
            )
        } catch {
            video.errorMessage = (video.errorMessage ?? "") + "\n本地分析失败: \(FriendlyError.reason(for: error))"
        }

        try checkCancelled(video)

        // Step 2: ASR 语音识别
        phase = .transcribing
        video.status = .transcribing
        context.safeSave()

        var asr: TranscriptionResult = .empty()
        var asrRan = false
        do {
            asr = try await asrService.transcribe(videoPath: video.localPath)
            asrRan = true
        } catch {
            let detail = "\(error)"
            MixLog.error("ASR 异常: \(detail)")
            video.errorMessage = (video.errorMessage ?? "") + "\n语音识别失败: \(FriendlyError.reason(for: error))"
        }

        video.transcript = asr.text
        video.asrWords = asr.words
        video.asrSentences = asr.rawSentences
        // 来源只在**引擎真的跑完了**之后记：失败时上面落的是空文本，把它标成"large-v3 跑过"
        // 就又是一次假就绪。空文本但跑成功的情形（纯音乐片）照实记，那是引擎的真实结论。
        if asrRan {
            video.recordASRRun(engine: .local, tier: ASRService.modelReport().selectedTier)
        } else {
            video.clearASRRun()
        }
        context.safeSave()

        try checkCancelled(video)

        // Step 3: AI 语义分析
        phase = .analyzing
        video.status = .analyzing
        context.safeSave()

        let activeProvider = KeychainHelper.activeProvider
        MixLog.info(" AI 分析开始: provider=\(activeProvider.displayName)")

        // Step 4+5: 边界优化 + 创建分镜 —— 与「重跑分析」共用同一个重建入口
        let rebuild = try await rebuildSegments(
            video,
            asr: asr,
            localAnalysis: localAnalysis,
            context: context,
            clearsExistingSegments: false
        )

        switch rebuild {
        case .success:
            video.status = .completed
        case .aiFailed(let error):
            // 终态只在这里落：入口不碰 status。首跑此刻没有旧分镜可退，如实标失败。
            let errMsg = error.localizedDescription
            if errMsg.contains("API Key") || errMsg.contains("api") || errMsg.contains("key") || errMsg.contains("未配置") {
                video.errorMessage = (video.errorMessage ?? "") + "\nAI 分析跳过：请先在「设置」中配置 API Key"
            } else {
                video.errorMessage = (video.errorMessage ?? "") + "\nAI 分析失败: \(errMsg)"
            }
            // 取消优先于失败：AI 挂掉时若用户已按停止，这里仍要抛出去（保持收口前的顺序）
            try checkCancelled(video)
            video.status = .failed
            video.errorMessage = (video.errorMessage ?? "") + "\nAI 分析未产出有效结果"
        }

        context.safeSave()
        MixLog.info(" 分析完成: video=\(video.name), status=\(video.status)")
    }

    /// 分镜重建的结果。失败终态不在这里表达 —— 两条链的终态本来就不该相同（见下）。
    private enum SegmentRebuildOutcome {
        case success
        case aiFailed(Error)
    }

    /// 分镜重建的**单一入口**：AI 取分区 → 取消检查 →（可选）删旧分镜 → 落库 → 逐段重认台词 → 缩略图。
    ///
    /// 为什么要收成这一个：首跑与「重跑分析」此前各有一份这段拷贝，规则只能逐点插、漏一处就分叉
    /// （W1 把建段收进 `SegmentCommitter` 后，控制流仍是两份）。收口时我核过六处差异，其中两处是
    /// **假差异**：新建 `AIAnalysisService()` 与复用 `self.aiAnalysis` 在取 Key 上等价（不注入 provider
    /// 时每次调用都走 `AIProviderManager.currentProvider()`），且两条链失败后都不跑后续步骤。
    /// 真差异只有一条，做成入参 `clearsExistingSegments`。
    ///
    /// 本入口**不写 `video.status`**，也不管 `isProcessing`/`phase` 的收尾值：
    /// 首跑此刻没有旧分镜可退，失败要如实标 `.failed`；重跑此刻旧分镜还在（删除点在取消检查之后），
    /// 退回 `.imported` 才是"素材可用、可再试"的真话。收尾同理 —— `phase` 是 VM 级共享单值，
    /// 多视频并行时谁收尾都会盖掉别人的阶段显示，归属留在各链自己。
    private func rebuildSegments(
        _ video: Video,
        asr: TranscriptionResult,
        localAnalysis: VideoLocalAnalysis,
        context: ModelContext,
        clearsExistingSegments: Bool
    ) async throws -> SegmentRebuildOutcome {
        phase = .analyzing
        let planConfig = SegmentationPlanSettings.current

        // 整片保留必须问在调模型之前 —— 它省的就是这次付费调用。
        // 单段覆盖全片时也不必再跑逐段重认：那等于把整片音频再听一遍，内容一模一样。
        if SegmentationPlanner.shouldKeepWholeVideo(duration: video.duration,
                                                   sentenceCount: asr.sentences.count,
                                                   in: planConfig) {
            try checkCancelled(video)
            if clearsExistingSegments {
                context.delete(video.segments)   // 快照由 API 保证（见 ModelContextExtension）
            }
            let whole = segmentCommitter.commitWholeVideo(
                for: video, source: video.defaultSource, context: context
            )
            if !asr.text.isEmpty {
                // 段范围就是全片，所以「整片听写后按时间切到这一段」这个来源描述依然成立
                whole.setText(asr.text, source: .fullVideoSlice)
            }
            video.aiOriginalSegmentCount = nil
            video.segmentationGuardNote = String(
                format: "整片保留：%.1fs / %d 句，未调用模型切分",
                video.duration, asr.sentences.count
            )
            await generateSegmentThumbnails(segments: video.segments, videoPath: video.localPath)
            MixLog.info(" 整片保留: video=\(video.name), \(video.segmentationGuardNote ?? "")")
            return .success
        }

        let analysisResult: AISegmentationResult
        do {
            analysisResult = try await aiAnalysis.analyzeVideo(
                videoId: video.name,
                transcript: asr,
                sceneBoundaries: localAnalysis.sceneBoundaries,
                localAnalysis: localAnalysis,
                planConfig: planConfig
            )
        } catch {
            return .aiFailed(error)
        }

        // 取消检查必须早于删旧分镜：否则中途停止会留下「旧段已删、新段未建」的空洞。
        try checkCancelled(video)

        phase = .optimizing
        if clearsExistingSegments {
            context.delete(video.segments)   // 快照由 API 保证（见 ModelContextExtension）
        }

        let commit = segmentCommitter.commitAIPartition(
            from: analysisResult,
            asr: asr,
            localAnalysis: localAnalysis,
            video: video,
            context: context,
            planConfig: planConfig
        )
        // 留痕只在真改写过时写；没改写就别留一串"无"占位
        video.aiOriginalSegmentCount = commit.appliedRules.isEmpty ? nil : commit.aiSegmentCount
        video.segmentationGuardNote = commit.appliedRules.isEmpty
            ? nil
            : "\(commit.appliedRules.map(\.displayName).joined(separator: "、"))："
                + "模型返回 \(commit.aiSegmentCount) 段 → 落库 \(commit.committedCount) 段"
        // 改写过素材形状就必须**出日志**，不能只进库字段：整份历史日志里 grep「过碎」零命中
        // （计划 §AD 实测），意味着这条规则哪怕天天在跑也没有任何一处能看见，取证只能开 sqlite3 读列。
        if let note = video.segmentationGuardNote {
            MixLog.info(" 分镜规划改写: video=\(video.name), \(note)")
        }

        // 台词以「逐分镜各自切音频独立 ASR」为准覆盖：整片流式 ASR 绝对时间戳会漂移、
        // 按整片时间戳切出的分镜台词会错位；单段短音频 ASR 永远准。边界已由本地场景/静音+AI 定好，
        // 这里只重识别各分镜台词（失败段保留 commitAIPartition 给的原文/AI 文本）。
        phase = .transcribing
        await autoReidentifySegments(video, context: context)

        await generateSegmentThumbnails(
            segments: video.segments,
            videoPath: video.localPath
        )

        return .success
    }

    // MARK: - 视频删除（解除关联 vs 真删除）

    /// 一次视频删除的单位。
    ///
    /// `referenceCountBefore` **必须在摘关联之前算好并塞进值类型**：`Video.referenceCount` 读的就是
    /// `projectVideos`，而下一步动的正是它 —— 事后再问只会得到已经被摘掉的数（批 3 的二次确认文案
    /// 「仅本项目使用 A 个 / 还被其它项目引用 C 个」吃的就是这两颗数）。
    private struct VideoDeletionUnit {
        let video: Video
        let pendingPVs: [ProjectVideo]
        let referenceCountBefore: Int
    }

    /// 视频删除的**唯一咽喉**：一批一次登记，宽限期共用一枚 ticket。
    ///
    /// ⚠️ 全文件只准有这一处向中心登记（数量被判据钉死：`scripts/check_undo_guards.sh` 的 UG-G10
    /// 恰好 1 处；这句说明里刻意不写出那颗调用的原文，否则按字面计数的探针会被注释本身绊倒）。
    /// 为什么不是"循环调单条删除"：中心同一时刻只挂一枚 ticket，登记新的一枚前会把前一枚当场
    /// `settle`，而 settle 对 deletion 类就是**即刻真删**（`PendingDeletionCenter.swift:79-95/134-138`）
    /// ⇒ 循环 N 次等于前 N−1 条根本没有宽限期，界面上还只看得到最后一枚浮条。
    /// Core 侧的机械证明见 `UndoGraceMachineTests` 的 TC-UG-15。
    private func scheduleVideoDeletion(_ videos: [Video], in project: Project) {
        guard modelContext != nil else { return }

        var units: [VideoDeletionUnit] = []
        for video in videos {
            let videoID = video.id
            cancelledVideoIDs.insert(videoID)                 // 立即取消该视频的后台处理（删除意图）
            let pvsToHide = project.projectVideos.filter { $0.video?.id == videoID }
            let referenceCountBefore = video.projectVideos.count   // 快照：必须早于下面那次 removeAll
            // 界面隐藏：从 project.projectVideos 摘除该视频的关联（ImportView 读 project.videos）。
            // pv 对象此刻不删，到 commit 时再真删。
            let pvIDs = Set(pvsToHide.map(\.id))
            project.projectVideos.removeAll { pvIDs.contains($0.id) }
            units.append(VideoDeletionUnit(video: video, pendingPVs: pvsToHide,
                                           referenceCountBefore: referenceCountBefore))
        }
        guard !units.isEmpty else { return }

        PendingDeletionCenter.shared.schedule(
            message: units.count == 1 ? "已删除视频" : "已删除 \(units.count) 个视频",
            commit: { [weak self] in
                guard let self else { return GraphChange() }
                return self.commitVideoDeletion(units).change
            },
            undo: { [weak self] in
                guard let self else { return }
                // 逐颗撤取消标记：漏掉则撤销回来的素材**永久停在"已导入"**（方案 §撤销三件事 ②）
                for unit in units { self.cancelledVideoIDs.remove(unit.video.id) }
                // 回填关联必须带 present 去重 —— 不去重会在同一项目内造出同一视频的两条关联，
                // 那正是本仓崩溃族的脏数据形状（方案 §撤销三件事 ①）
                let present = Set(project.projectVideos.map(\.id))
                for pv in units.flatMap({ $0.pendingPVs }) where !present.contains(pv.id) {
                    project.projectVideos.append(pv)
                }
            }
        )
    }

    /// 从项目中移除视频（解除关联）；仅当视频不被任何项目引用时，才真正删除 Video + Segment（磁盘文件交孤儿 GC）
    ///
    /// 签名不变（`ImportView.swift:232` 是唯一调用方）：批 2 只是把它接进批量咽喉的单元素调用。
    func deleteVideo(_ video: Video, from project: Project) {
        scheduleVideoDeletion([video], in: project)
    }

    /// 真删除（批量）：**逐条顺序一条都不许动** —— 删关联 pv → `safeSave()`（取返回值）→
    /// `video.projectVideos.isEmpty` 才连分镜与视频记录一起删。
    ///
    /// 为什么中间那次 save 既不能合并到循环外、也不能不看结果：隐藏只改了 `project.projectVideos`
    /// 那一侧，pv 的反向数组要等**落盘后**才被 cascade 摘掉；合并或不看 ⇒ `isEmpty` 恒 false ⇒
    /// "无引用才连记录删"这条主判定永久失效，表现是"删了还在"。顺序判据见 UG-G11，
    /// "返回值必须取"见 `VideoDeletionThroatGuardTests` 的 GT-01/GT-02。
    ///
    /// 部分失败语义（方案 P0-2）：某条 save 返回 false ⇒ **立刻停止本批**、把从这条起还没删成功的关联
    /// **当场放回界面**，并如实报「已处理 k 条 / 未删 N−k 条」。
    /// ⚠️ 这里比方案原文多做一步、少依赖一步：方案写的是"undo 只回填未删成功的那部分 pv"，
    /// 但中心的 commit 与 undo **互斥**（`finish`/`settle` 之后闭包表已清，见
    /// `PendingDeletionCenter.swift:122-138`），部分失败发生时 undo 那条路已经走不到了。
    /// 所以在 commit 内当场放回，才是"界面与库不许分叉"这个意图在当前模型下的唯一可达实现。
    private func commitVideoDeletion(_ units: [VideoDeletionUnit])
        -> (fullyDeleted: [Video], change: GraphChange) {
        guard let context = modelContext else { return ([], GraphChange()) }
        var fullyDeleted: [Video] = []
        var change = GraphChange()
        var settled = 0                   // 已落盘处理完的条数（含"仅解除关联"那些）
        var failedAtPVSave: Int? = nil    // 关联删除本身没落盘 ⇒ 这一条起都能放回界面
        var failedAtRecordSave: Int? = nil // 关联已落盘、记录清理没落盘 ⇒ 放回不了，只能说人话

        for (index, unit) in units.enumerated() {
            let video = unit.video
            // 先真删关联 pv：走 `delete(_:)` 这颗 —— 进函数即快照（ModelContextExtension.swift:71-81）。
            // 刻意不用官方 `delete(model:where:)`：那是存储层批量删，不会动内存里已 materialize 的对象，
            // 用在这里只会**制造更多**待读的死对象。
            context.delete(unit.pendingPVs)
            guard debugSaveHolds(stage: "pv"), context.safeSave() else {
                failedAtPVSave = index
                break
            }
            settled += 1
            guard video.projectVideos.isEmpty else {
                MixLog.info(" 视频仍被其它项目引用，仅解除关联: \(video.name)")
                continue
            }
            // 无任何项目引用，删除视频 + 分镜 + SchemeSegment「记录」；磁盘文件交孤儿 GC
            let segmentsToDelete = Array(video.segments)
            // id 必须在 delete 之前收齐：删完再从关系数组里读 `.id` 本身就是一次墓碑读（前案 §3 刀 2）。
            // `ProjectVideo` / `SchemeSegment` 不记：界面里没有握着这两类数组的消费者（见台账 §25）。
            // ⚠️ 也不许 note `.video`：带 video 不带 project 的变更没人接得住（`isPrunable` 判不可剪枝 ⇒
            // 降级无载荷全量重载 ⇒ `loadSegments` 首行 `flushNow()` 同栈递归），判据 UG-G13 钉着这件事。
            change.noteDeleted(Set(segmentsToDelete.map(\.id)), of: .segment)
            for segment in segmentsToDelete {
                context.delete(segment.schemeSegments)
                context.delete(segment)
            }
            context.delete(video)
            guard debugSaveHolds(stage: "record"), context.safeSave() else {
                failedAtRecordSave = index
                break
            }
            MixLog.info(" 视频无引用，已删除记录: \(video.name)")
            fullyDeleted.append(video)
        }

        if failedAtPVSave != nil {
            // 关联删除没落盘 ⇒ 退回未落盘的改动：这批 pv 的删除、以及 `scheduleVideoDeletion` 里
            // 那次把关联摘出 `project.projectVideos` 的隐藏，一起回到动手前的状态（界面与库不分叉）。
            // 刻意不把 `unit.pendingPVs` 再 append 回 project.projectVideos：那些对象已经被
            // `context.delete` 标记删除，塞回关系数组就是一次墓碑读（前案 §3 刀 2 那一族的形状）。
            // ⚠️ 代价要摊开：`rollback()` 是**整个 context 范围**的退回（SwiftData 接口 :399），
            //    此刻若有导入链的未落盘改动，也会被一起退掉。删除的 commit 只发生在宽限期到点 /
            //    切项目 / 退出这三处，撞上导入在写的概率低但不为零 —— 这条留给真机失败注入格验（方案 E2E-02）。
            context.rollback()
            reportPartialDeletion(settled: settled, total: units.count, restored: true)
        } else if failedAtRecordSave != nil {
            // 关联已落盘、视频与分镜记录的清理没落盘。两个动作缺一不可：
            // ① 同样 `rollback()`：退掉的是**这次失败的 save 之后**还挂在 context 里的改动（视频与分镜的
            //    删除）。不退的话它们会一直悬着，被链上别处的 `saveOrWarn` 悄悄落盘 ⇒ 变成"没人申报却已生效"
            //    的删除；已经保存成功的 pv 删除不受影响（rollback 只退上次 save 之后的部分）。
            // ② 如实报状态：库此刻是"关联已解除、记录待清理"，不许假装"已删除 N 个视频"。
            context.rollback()
            reportPartialDeletion(settled: settled, total: units.count, restored: false)
        }
        return (fullyDeleted, change)
    }

    /// DEBUG-only 的落盘失败注入缝（方案 E2E-02 那格的读数点）。
    ///
    /// 为什么要有这颗：批量删除的"部分失败"是批 2 唯一还没被任何自动化覆盖的分支。真造 `safeSave`
    /// 失败在 macOS 上只有占满卷或整根只读两条路，而那两条会顺带弄坏导入、缩略图、日志——测出来的红
    /// 分不清是这条分支坏了还是环境坏了。缝开在咽喉**内部**、只影响本批删除这两次落盘，
    /// 且**默认放行**：不设变量、设错值都照原样跑，注入永远不能变成默认态。
    ///
    /// 守法与 `FileHelper.swift:17-25` 那颗假库开关同族：`#if DEBUG` 包着，Release 编译不进这一支
    /// （判据 GT-05 钉着"在 DEBUG 内"与"默认放行"两件事）。
    ///
    /// 用法：`MIXCUT_DEBUG_FAIL_SAVE=pv`（关联那次落盘必失败，验 `restored=true` 那句）／
    /// `record`（记录清理那次必失败，验 `restored=false` 那句）／`all`（两次都失败）。
    private func debugSaveHolds(stage: String) -> Bool {
        #if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["MIXCUT_DEBUG_FAIL_SAVE"],
              !spec.isEmpty else { return true }
        return spec != "all" && spec != stage
        #else
        return true
        #endif
    }

    /// 部分失败的如实告知（方案 P0-2）：单条时"没删掉"只是这一条，批量会放大成**界面与库分叉且没人说**。
    /// 文案必须给实得数字，不许复用"已删除 N 个视频"那句成功提示。
    private func reportPartialDeletion(settled: Int, total: Int, restored: Bool) {
        let undone = total - settled
        let tail = restored
            ? "未删的 \(undone) 条已放回列表，可直接重试"
            : "未删的 \(undone) 条已解除关联但记录未清理完（关联已落盘，放回不了），请重试或重启后再删"
        ToastCenter.shared.show("视频删除未完成：已处理 \(settled) 条、未删 \(undone) 条；\(tail)",
                                icon: "exclamationmark.triangle.fill", style: .warning, duration: 6)
        MixLog.error("[视频删除] 部分失败：已处理 \(settled) 条 / 本批 \(total) 条，restored=\(restored)")
    }

    /// Agent 立即删除路径：与 `deleteVideo` **同一条咽喉**，只是立即生效、无撤销
    /// （MCP `remove_video` 侧签名与语义都不动，`MCPToolHandlers.swift:494` 仍按 Bool 回 `deletedGlobally`）
    @discardableResult
    func removeVideoImmediately(_ video: Video, from project: Project) -> Bool {
        guard modelContext != nil else { return false }
        cancelledVideoIDs.insert(video.id)
        let pvsToRemove = project.projectVideos.filter { $0.video?.id == video.id }
        let referenceCountBefore = video.projectVideos.count   // 同样必须在摘之前取快照
        let pvIDs = Set(pvsToRemove.map(\.id))
        project.projectVideos.removeAll { pvIDs.contains($0.id) }
        let unit = VideoDeletionUnit(video: video, pendingPVs: pvsToRemove,
                                     referenceCountBefore: referenceCountBefore)
        let outcome = commitVideoDeletion([unit])
        // Agent 链的调用方随后会走 `notifyUIReload()` 的**无载荷**广播（全量重载，比按 id 剪枝更保守），
        // 所以这里交回的台账不必再发一次 —— 但也不能当没发生：全量重载覆盖了同一批 id。
        return !outcome.fullyDeleted.isEmpty
    }

    // MARK: - 视频多选（批量删除的选择态与入口）
    //
    // 状态住在 VM 而不是视图的 @State，依据是仓内既有裁定 `ProjectDataReadiness.swift:5-11`：
    // `ContentView.detailView` 是 `@ViewBuilder switch`，切模块会销毁重建视图实例 ⇒ @State 必丢。
    // 形状逐条对称照抄 `SegmentLibraryViewModel` 的选择态（方案批 3 明令**不参照** ExportView 那套
    // 独立写法 —— 仓里两份批量范式本身就是债，新代码必须先向既有那份对齐）。

    /// 是否处于多选模式
    var isVideoSelectionMode = false
    /// 勾选的视频 id。⚠️ importVM 跨页长活 ⇒ 这是**全局**集合，换项目必须整批复位（判据 UG-G12）
    var selectedVideoIDs: Set<UUID> = []
    /// 勾选先后顺序（`Set` 无序，而 ⇧ 连选、二次确认与浮条文案都要确定性）
    var videoSelectionOrder: [UUID] = []
    /// 最后一次单独勾选的视频 —— ⇧+点击的范围锚点
    private var lastToggledVideoID: UUID?

    /// ⇧+点击的**视觉顺序**：由视图把它正在渲染的那份序列传进来。
    ///
    /// 为什么不是 VM 自己再算一遍编号：`ImportView.numberedVideos`（:203-212）那行
    /// `return project.associatedVideos` 是 G08 名册在册的读取点，在 VM 里抄一份同样的过滤排序会
    /// ① 造出第二份"同一套编号/同一套过滤"的真源（本仓刚为这类事定过判据），
    /// ② 逼一次两张名册整体重生成。所见即所得的语义两种写法一样，但传参只碰一个文件。
    func extendVideoSelection(to video: Video, visibleOrder: [Video]) {
        let ids = visibleOrder.map(\.id)
        guard let anchorID = lastToggledVideoID,
              let anchorIdx = ids.firstIndex(of: anchorID),
              let targetIdx = ids.firstIndex(of: video.id) else {
            toggleVideoSelection(video)
            return
        }
        let range = anchorIdx <= targetIdx ? anchorIdx...targetIdx : targetIdx...anchorIdx
        for id in ids[range] where !selectedVideoIDs.contains(id) {
            selectedVideoIDs.insert(id)
            videoSelectionOrder.append(id)
        }
        // 锚点保持不动，便于反复 ⇧+点击调整范围（分镜侧同款手感）
    }

    func toggleVideoSelection(_ video: Video) {
        if selectedVideoIDs.contains(video.id) {
            selectedVideoIDs.remove(video.id)
            videoSelectionOrder.removeAll { $0 == video.id }
        } else {
            selectedVideoIDs.insert(video.id)
            videoSelectionOrder.append(video.id)
        }
        lastToggledVideoID = video.id
    }

    /// 全选当前**看得见**的卡（定义域由视图传入，理由同 `extendVideoSelection`）
    func selectAllVisibleVideos(_ visibleOrder: [Video]) {
        let ids = visibleOrder.map(\.id)
        selectedVideoIDs = Set(ids)
        videoSelectionOrder = ids
    }

    /// 「全选丢失项」：把选择集**换成**这批丢失的卡，并顺手进入多选模式。
    ///
    /// 这是「真删记录」唯一的批量入口（方案批 4）—— 走这一颗而不是先清空再逐颗 toggle：
    /// 进入多选模式不是装饰，它让二次确认、5 秒撤销、以及「勾选必须在可见集合内」那道越界门
    /// 全都还在这条链上。少了那道门，一键全选就会绕过 Core 的作用域判定。
    func selectMissingVideos(_ missingVisibleOrder: [Video]) {
        setVideoSelectionMode(true)
        let ids = missingVisibleOrder.map(\.id)
        selectedVideoIDs = Set(ids)
        videoSelectionOrder = ids
    }

    func invertVisibleVideoSelection(_ visibleOrder: [Video]) {
        let visible = Set(visibleOrder.map(\.id))
        let next = visible.subtracting(selectedVideoIDs)
        selectedVideoIDs = next
        // 反选后"勾选先后"语义已不成立，按渲染顺序重建即可
        videoSelectionOrder = visibleOrder.map(\.id).filter { next.contains($0) }
    }

    func clearVideoSelection() {
        selectedVideoIDs.removeAll()
        videoSelectionOrder.removeAll()
    }

    /// 进入/退出多选模式（退出时清空已选，与分镜侧一致）
    func setVideoSelectionMode(_ enabled: Bool) {
        isVideoSelectionMode = enabled
        if !enabled {
            selectedVideoIDs.removeAll()
            videoSelectionOrder.removeAll()
            lastToggledVideoID = nil
        }
    }

    /// 已选视频的总时长（秒）。只求和不建数组 —— 多选工具栏常驻，任意重绘都会读它（分镜侧同条纪律）
    func selectedVideoTotalDuration(in project: Project) -> Double {
        project.associatedVideos.reduce(0.0) { acc, video in
            selectedVideoIDs.contains(video.id) ? acc + video.duration : acc
        }
    }

    /// 真删回来时同时剪选中集（对齐 `pruneDeletedSegments`）。
    ///
    /// ⚠️ 与分镜侧的差别要说清，免得后人以为这里漏了：分镜库自己持有一份 `segments` 数组可剪，
    /// 而视频列表是**现读关系**（`project.associatedVideos`），没有数组可剪 —— 本函数只清 id 集合。
    func pruneDeletedVideos(_ deletedVideoIDs: Set<UUID>) {
        guard !deletedVideoIDs.isEmpty else { return }
        selectedVideoIDs.subtract(deletedVideoIDs)
        videoSelectionOrder.removeAll { deletedVideoIDs.contains($0) }
    }

    /// 批量删除当前勾选的视频。
    ///
    /// 三道闸门，缺一不可：
    /// ① 作用域判定走 Core（`VideoDeletionScopeResolver`）—— 勾选中混进不属于"当前可见集合"的 id
    ///    就**整条拒绝**并点名越界的那几个，不做"删我能删的那半"（否则「已删除 N 个视频」就是说谎）；
    /// ② 二次确认在视图侧（要读实数总数，见 `videoDeletionTotals`）；
    /// ③ 真正删除只有一条路：批 2 的咽喉 `scheduleVideoDeletion`（一批 = 一枚 ticket）。
    func deleteSelectedVideos(in project: Project, visibleOrder: [Video]) {
        let associations = associationsByVideo(in: project, for: selectedVideoIDs)
        let scope = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: selectedVideoIDs,
            visibleVideoIDs: Set(visibleOrder.map(\.id)),
            associationsByVideo: associations)
        if scope.isRejected {
            ToastCenter.shared.show(
                "已拒绝批量删除：\(scope.foreignIDs.count) 个勾选不在当前可见列表里（可能来自另一个项目）。"
                + "请重新勾选后再删。",
                icon: "exclamationmark.triangle.fill", style: .warning, duration: 6)
            return
        }
        let videos = scope.deletableUnits.compactMap { unit in
            project.associatedVideos.first { $0.id == unit.videoID }
        }
        guard !videos.isEmpty else { return }
        clearVideoSelection()                       // 撤销三件事之三：清空选择集
        scheduleVideoDeletion(videos, in: project)
    }

    /// 二次确认与浮条要念的实数（两档文案 + 「本次将真删 B 个分镜记录」都说在前面）。
    ///
    /// 引用数**必须在调用删除咽喉之前**算：隐藏步骤摘的正是 `projectVideos`，事后再问必错。
    func videoDeletionTotals(in project: Project, visibleOrder: [Video]) -> VideoDeletionTotals {
        let visible = Set(visibleOrder.map(\.id))
        var entries: [VideoDeletionTotals.Entry] = []
        for video in project.associatedVideos where visible.contains(video.id)
            && selectedVideoIDs.contains(video.id) {
            entries.append(VideoDeletionTotals.Entry(
                referenceCountBefore: video.projectVideos.count,
                associationCountInProject: project.projectVideos.filter { $0.video?.id == video.id }.count,
                segmentCount: video.segments.count))
        }
        let unresolvable = VideoDeletionScopeResolver.resolve(
            selectedVideoIDs: selectedVideoIDs, visibleVideoIDs: visible,
            associationsByVideo: associationsByVideo(in: project, for: selectedVideoIDs)
        ).unresolvableIDs
        let totals = VideoDeletionTotals.tally(entries)
        return VideoDeletionTotals(localOnlyCount: totals.localOnlyCount,
                                   stillReferencedCount: totals.stillReferencedCount,
                                   segmentsDeleted: totals.segmentsDeleted,
                                   unresolvableCount: unresolvable.count)
    }

    /// videoID → 该视频在本项目里的关联行 id（两条脏关联都要收，少一条就删不掉）
    private func associationsByVideo(in project: Project, for videoIDs: Set<UUID>) -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        for pv in project.projectVideos {
            guard let videoID = pv.video?.id, videoIDs.contains(videoID) else { continue }
            result[videoID, default: []].insert(pv.id)
        }
        return result
    }

    // MARK: - 全局视频查找

    /// 查找全局已有的同 hash 视频
    private func findExistingVideo(hash: String, context: ModelContext) -> Video? {
        let descriptor = FetchDescriptor<Video>(
            predicate: #Predicate<Video> { video in
                video.contentHash == hash
            }
        )
        guard let videos = try? context.fetch(descriptor) else { return nil }
        return videos.first
    }

    /// 检测视频是否已在当前项目中
    private func isDuplicate(url: URL, in project: Project) -> Bool {
        let fileName = url.lastPathComponent

        // 先按文件名检查（最快）
        if project.videos.contains(where: { $0.name == fileName }) {
            return true
        }

        // 再按 hash 检查（最准确）
        if let hash = Self.computeFileHash(path: url.path) {
            return project.videos.contains { $0.contentHash == hash }
        }

        return false
    }

    /// 任务组里发生未捕获异常时的兜底：避免视频卡在中间态
    private func handleAnalyzeFailure(video: Video, error: Error) {
        if video.status == .queued || video.status == .detectingScenes || video.status == .transcribing || video.status == .analyzing {
            let detail = error.localizedDescription
            video.errorMessage = (video.errorMessage ?? "") + "\n分析失败: \(detail)"
            video.status = .failed
            modelContext?.safeSave()
            MixLog.error(" 兜底标记失败: video=\(video.name), error=\(detail)")
        }
        let prevError = errorMessage.map { $0 + "\n" } ?? ""
        errorMessage = prevError + "分析 \(video.name) 失败: \(FriendlyError.reason(for: error))"
    }

    private func checkCancelled(_ video: Video) throws {
        if cancelledVideoIDs.contains(video.id) {
            cancelledVideoIDs.remove(video.id)
            throw CancellationError()
        }
    }

    /// 使用 AVFoundation 提取视频元数据
    private func extractMetadata(for video: Video, at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        video.duration = CMTimeGetSeconds(duration)

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformedSize = size.applying(transform)
            video.width = Int(abs(transformedSize.width))
            video.height = Int(abs(transformedSize.height))

            let rate = try await track.load(.nominalFrameRate)
            video.fps = Double(rate)
        }
    }

    /// 为分镜列表生成缩略图（全局目录）
    private func generateSegmentThumbnails(
        segments: [Segment],
        videoPath: String
    ) async {
        let thumbDir = FileHelper.globalThumbnailDirectory

        // IV-13：返回 segment.id 而非数组 index，避免 SwiftData fault 导致 segments 顺序变动时
        // 把缩略图写到错误的 Segment 上（A 的缩略图变成 B 的画面 → 用户感知最强 bug 之一）
        let segmentByID: [UUID: Segment] = Dictionary(
            segments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        await withTaskGroup(of: (UUID, String?).self) { group in
            for segment in segments {
                // 已有缩略图则跳过
                if let existing = segment.thumbnailPath,
                   FileManager.default.fileExists(atPath: existing) {
                    continue
                }
                let segID = segment.id
                // 用「分镜首帧」(startTime + 100ms 偏移避免转场/黑帧) 作为缩略图
                let firstFrameTime = max(0, segment.startTime + 0.1)
                let thumbPath = thumbDir.appendingPathComponent("seg_\(segID.uuidString).jpg").path
                group.addTask { [ffmpeg] in
                    do {
                        try await ffmpeg.generateThumbnail(from: videoPath, at: firstFrameTime, to: thumbPath)
                        return (segID, thumbPath)
                    } catch {
                        return (segID, nil)
                    }
                }
            }

            for await (segID, path) in group {
                if let path, let segment = segmentByID[segID] {
                    segment.thumbnailPath = path
                    // 路径是固定的 seg_<uuid>.jpg：之前若因文件缺失被缓存记为「解码失败」，
                    // 这里必须让它失效，否则新生成的缩略图永远显示不出来。
                    ThumbnailCache.shared.invalidate(path: path)
                }
            }
        }
        modelContext?.safeSave()
    }

    /// 生成视频缩略图（全局目录）
    private func generateVideoThumbnail(for video: Video) async throws {
        let thumbDir = FileHelper.globalThumbnailDirectory
        let thumbPath = thumbDir.appendingPathComponent("\(video.id.uuidString).jpg").path

        try await ffmpeg.generateThumbnail(from: video.localPath, to: thumbPath)
        video.thumbnailPath = thumbPath
    }

    /// 计算文件 SHA-256 哈希
    static func computeFileHash(path: String) -> String? {
        do {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attrs[.size] as? Int64) ?? 0

            var hasher = SHA256()
            hasher.update(data: Data(String(fileSize).utf8))

            let chunkSize = 4 * 1024 * 1024
            let headData = handle.readData(ofLength: chunkSize)
            hasher.update(data: headData)

            if fileSize > Int64(chunkSize * 2) {
                handle.seek(toFileOffset: UInt64(fileSize) - UInt64(chunkSize))
                let tailData = handle.readData(ofLength: chunkSize)
                hasher.update(data: tailData)
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            MixLog.error(" 计算文件哈希失败: \(error)")
            return nil
        }
    }

    /// 支持的视频文件类型
    static var supportedTypes: [UTType] {
        [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
    }

    /// 重识别该视频各分镜台词：**逐分镜各自切音频独立 ASR**（不动分镜边界）。
    /// 不用整片 ASR 切片——实时流式 ASR 的整片绝对时间戳会漂移、导致台词错位；
    /// 单段短音频 ASR 永远准。每个分镜按自己时间范围切音频、各自识别、写回 segment.text。
    func reidentifyWholeVideo(_ video: Video, context: ModelContext) async {
        // 判定问唯一出口（批 5）：这颗此前是自写 `fileExists` + 自造文案，与导出/播放各问各的。
        guard !video.localPath.isEmpty, FileHelper.isMaterialFilePresent(path: video.localPath) else {
            ToastCenter.shared.show(MissingMaterialCopy.fullMessage(fileName: video.name),
                                    icon: "exclamationmark.triangle.fill", style: .warning); return
        }
        guard !reidentifyingVideoIDs.contains(video.id) else { return }
        reidentifyingVideoIDs.insert(video.id)
        defer { reidentifyingVideoIDs.remove(video.id) }

        // 用户点名「逐段重听」⇒ 整条都听，不做沿用判断（那是自动链的省法，不是这里语义）
        let r = await reidentifySegmentTexts(video: video, context: context, auto: false)
        let detail = r.reason.map { "：\($0)" } ?? ""
        if r.stoppedEarly || r.failed > 0 || r.refused > 0 || r.cancelled > 0 {
            // 只报"X 成功 / Y 失败"等于没报——用户既不知道为什么失败，也不知道该怎么办。
            // 分档报数：refused（配置问题）与 failed（识别问题）混在一起会把"没配 Key"伪装成"这片子没声音"。
            var parts = ["台词重认 \(r.gotText) 段拿到字"]
            if r.failed > 0 { parts.append("\(r.failed) 段没拿到字") }
            if r.refused > 0 { parts.append("\(r.refused) 段没跑识别") }
            if r.cancelled > 0 { parts.append("\(r.cancelled) 段被取消") }
            ToastCenter.shared.show("\(parts.joined(separator: "、"))\(detail)",
                                    icon: "exclamationmark.triangle.fill", style: .warning, duration: 8)
        } else {
            ToastCenter.shared.show("已逐分镜重认台词（\(r.gotText) 段）",
                                    icon: "checkmark.circle.fill", style: .success)
        }
    }

    /// 自动链上的逐段重认：**不弹窗**（那时库里还没有"旧台词"可保护，这是红线 R8 的作用域区分），
    /// 但结果必须进日志 —— 两处调用点都忽略返回值，就等于"整批没配 Key、一段也没重认"这件事没人知道。
    private func autoReidentifySegments(_ video: Video, context: ModelContext) async {
        let r = await reidentifySegmentTexts(video: video, context: context, auto: true)
        if r.failed > 0 || r.refused > 0 || r.stoppedEarly {
            let detail = r.reason.map { "：\($0)" } ?? ""
            MixLog.error("[ASR] \(video.name) 自动逐段重认：\(r.gotText) 段拿到字、"
                         + "\(r.failed) 段没字、\(r.refused) 段没跑识别\(detail)")
        }
    }

    /// 逐分镜各自切音频独立重认台词，覆盖 `segment.text`。
    ///
    /// **用哪台引擎由 `SegmentTranscriber` 门面问决策表**（红线 R4/R6）：这里以前硬编码云端，
    /// 而默认偏好是"强制本地"，两处会给出不同答案 —— 收敛到门面后只剩一个答案。
    /// 纪律：串行不并行、每段之间查取消、连续 K 段失败即止（K = `ASRPolicy.consecutiveFailureLimit`）、
    /// 进度可见、失败几段如实报。
    ///
    /// `auto` 必填、没有默认值：`true` = 导入/重跑那条**自动链**，只补该重听的段
    /// （边界已按句子落点 ⇒ 整片切片本来就是完整句子，§AF）；`false` = 用户点名"逐段重听"，整条都听。
    /// 这两件事的代价与语义都不同，写成同一个循环才会出事 —— 给默认值就等于让新调用点随手选一边。
    @discardableResult
    func reidentifySegmentTexts(video: Video, context: ModelContext,
                                auto: Bool) async
        -> (gotText: Int, failed: Int, refused: Int, cancelled: Int, stoppedEarly: Bool, reason: String?) {
        let fps = video.fps > 0 ? video.fps : 30
        let segs = video.segments.sorted { $0.startFrame < $1.startFrame }
        var outcomes: [SegmentTranscribeOutcome] = []
        var firstReason: String?
        var consecutiveFailures = 0
        var stoppedEarly = false
        var carriedOver = 0

        for (index, seg) in segs.enumerated() {
            if cancelledVideoIDs.contains(video.id) {
                outcomes.append(.cancelled)
                stoppedEarly = true
                break
            }
            if auto && !SegmentRetakeRule.shouldAutoRetake(
                currentText: seg.text, currentSource: seg.textSource) {
                carriedOver += 1
                continue
            }
            reidentifyProgress[video.id] = (index, segs.count)

            let result = await SegmentTranscriber.shared.transcribe(SegmentTranscriber.Request(
                videoPath: video.localPath,
                segmentIndex: seg.segmentIndex,
                startSeconds: Double(seg.startFrame) / fps,
                endSeconds: Double(seg.endFrame) / fps,
                currentText: seg.text,
                currentSource: seg.textSource))

            if result.outcome == .cancelled {
                outcomes.append(.cancelled)
                stoppedEarly = true
                break
            }
            if let text = result.textToWrite, let source = result.sourceToWrite {
                seg.setText(text, source: source)
            }
            if !result.gotText, firstReason == nil { firstReason = result.reason }
            outcomes.append(result.outcome)

            consecutiveFailures = result.gotText ? 0 : consecutiveFailures + 1
            if case .tooManyConsecutiveFailures = SegmentBatchPolicy.shouldStop(
                consecutiveFailures: consecutiveFailures, cancelled: false) {
                MixLog.error("[ASR] 连续 \(consecutiveFailures) 段没拿到字，提前停止 \(video.name)")
                stoppedEarly = true
                break
            }
        }
        reidentifyProgress[video.id] = nil
        if auto {
            // 「省了多少」必须出声：这条腿曾是导入里最贵的一段（§Q-1/Q-4），
            // 现在默认只补该补的段 —— 不说出来，谁也看不出这轮到底有没有跳过重听。
            MixLog.info(" 逐段补认: video=\(video.name), 沿用整片切片 \(carriedOver) 段、实际重听 \(outcomes.count) 段")
        }
        // 这一步覆盖整个视频所有分镜的台词，且可能是付费识别的结果，保存失败必须告知
        context.saveOrWarn("重识别的台词")

        let t = SegmentBatchPolicy.tally(outcomes)
        return (t.gotText, t.failed, t.refused, t.cancelled, stoppedEarly, firstReason)
    }

    // MARK: - 分镜拆分（PRD/TRD 06）

    /// 把一个分镜在 `cutFrame` 处拆成前后两段：A 复用原 seg 缩为前段，B 新建后段。
    /// 清空原分镜的衍生物（配音/字幕、画面替换、物理镜头变体），两段各自重抽缩略图 + 阿里重识别台词，
    /// B 继承原语义标签。`onUpdate` 用于刷新分镜库。调用前须保证 `seg.schemeSegments` 为空（拦截见 UI）。
    /// 拆分结果。以前这个方法是 `async` 无返回值且有三处静默 `return`，
    /// 调用方（SplitSegmentSheet）不管成败一律 `dismiss()` —— 用户看到「拆分中…」后弹窗正常关闭，
    /// 但列表毫无变化，完全不知道发生了什么。现在把失败原因带回去，由 UI 如实展示。
    enum SplitOutcome {
        case success
        /// 拆分本体成功，但后续台词重识别失败（台词仍是拆分前的旧内容，需要用户核对）
        case successWithWarning(String)
        case failed(reason: String)
    }

    @discardableResult
    func splitSegment(_ seg: Segment, atFrame cutFrame: Int, onUpdate: @escaping @MainActor () -> Void = {}) async -> SplitOutcome {
        guard let context = modelContext else {
            return .failed(reason: "数据库尚未就绪，请稍后重试。")
        }
        guard let video = seg.video else {
            return .failed(reason: "这个分镜找不到对应的源视频，可能视频已被删除。请重新导入素材。")
        }
        guard seg.schemeSegments.isEmpty else {
            return .failed(reason: "这个分镜已经被混剪方案使用，不能再拆分。请先从方案中移除它，或复制一份再拆。")
        }
        let fps = video.fps > 0 ? video.fps : 30
        let origStart = seg.startFrame
        let origEnd = seg.endFrame
        guard cutFrame > origStart, cutFrame < origEnd else {
            return .failed(reason: "拆分点必须落在分镜内部。当前分镜太短或拆分位置在边缘，无法拆分。")
        }

        // 1) 清空原 seg（将成为 A 段）的衍生物 —— 两段视为全新分镜，不可恢复
        context.delete(seg.segmentDubs)     // cascade 删逐句字幕
        context.delete(seg.physicalShots)   // cascade 删 ShotVariant
        seg.invalidateReplacedPicture()

        // 2) A = 原 seg 缩为 [origStart, cutFrame]
        seg.setFrameRange(startFrame: origStart, endFrame: cutFrame, fps: fps)

        // 3) B = 新建后段 [cutFrame, origEnd]，继承标签
        let b = segmentCommitter.commitSplitRemainder(
            of: seg,
            segmentIndex: "\(seg.segmentIndex)_\(UUID().uuidString.prefix(4))",
            startFrame: cutFrame, endFrame: origEnd, fps: fps,
            context: context
        )
        context.safeSave()
        onUpdate()   // 两段先出现

        // 4) 缩略图各自重生（各自首帧）
        await regenSegmentThumbnail(seg, in: video, fps: fps)
        await regenSegmentThumbnail(b, in: video, fps: fps)
        context.safeSave(); onUpdate()

        // 5) 各自阿里重识别台词（复用单段 ASR 模式）
        let okA = await reASRSegment(seg, in: video, fps: fps)
        let okB = await reASRSegment(b, in: video, fps: fps)
        context.safeSave(); onUpdate()

        // 台词重识别失败时**必须说出来**：拆分本体是成功的，但两段的台词还停留在拆分前的旧内容，
        // 用户如果不知道，会拿着错误台词去配音、去导出。
        if !okA || !okB {
            let which = (!okA && !okB) ? "两段" : (okA ? "后一段" : "前一段")
            return .successWithWarning("拆分已完成，但\(which)的台词重新识别失败，台词仍是拆分前的旧内容。请手动核对并编辑台词。")
        }
        return .success
    }

    /// 重抽某分镜首帧缩略图（拆分后 A/B 各自生成，用 seg.id 命名避免共用）
    private func regenSegmentThumbnail(_ seg: Segment, in video: Video, fps: Double) async {
        let t = Double(seg.startFrame) / fps
        let path = FileHelper.globalThumbnailDirectory
            .appendingPathComponent("seg-\(seg.id.uuidString).jpg").path
        do {
            try await ffmpeg.generateThumbnail(from: video.localPath, at: t, to: path)
            seg.thumbnailPath = path
            // ⚠️ 拆分后 seg.id 不变 → 路径不变但画面已经变了。
            // 不清缓存的话，卡片会一直显示拆分前的旧首帧。
            ThumbnailCache.shared.invalidate(path: path)
        } catch {
            MixLog.error("[Split] 缩略图重生失败 \(seg.segmentIndex): \(error.localizedDescription)")
        }
    }

    /// 对某分镜按自己帧窗切音频 + 阿里 paraformer 重识别台词（失败保留原 text）。
    /// 返回是否成功，供调用方决定要不要提醒用户「台词还是旧的」。
    @discardableResult
    private func reASRSegment(_ seg: Segment, in video: Video, fps: Double) async -> Bool {
        let result = await SegmentTranscriber.shared.transcribe(SegmentTranscriber.Request(
            videoPath: video.localPath,
            segmentIndex: seg.segmentIndex,
            startSeconds: Double(seg.startFrame) / fps,
            endSeconds: Double(seg.endFrame) / fps,
            currentText: seg.text,
            currentSource: seg.textSource))
        if let text = result.textToWrite, let source = result.sourceToWrite {
            seg.setText(text, source: source)
        }
        if !result.gotText {
            MixLog.error("[Split] reASR 未拿到字 \(seg.segmentIndex): \(result.reason ?? result.outcome.rawValue)")
        }
        return result.gotText
    }
}
