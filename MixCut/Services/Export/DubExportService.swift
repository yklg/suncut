import Foundation

/// 单分镜导出规格（值类型，可跨 actor 传递）。
struct DubSegmentSpec: Sendable {
    let videoPath: String
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let captionLines: [CaptionLine]   // 逐句字幕（相对分镜起点秒）；空=不烧字幕
    let hasHardSubtitle: Bool
    let maskStyleRaw: String
    let maskRect: SubtitleMaskRect
    let isVoiceLocked: Bool
    let dubAudioPath: String?      // 配音段 m4a；锁定/回退段为 nil
    let freezePadFrames: Int
    let trailingSilence: Double
    let bgmAudioPath: String?      // 配音镜头的 BGM 源（整轨 bgm.wav）；nil = 不混 BGM
    /// 该分镜自己的字幕字号比例（逐分镜独立，不再读全局设置）
    let subtitleFontRatio: Double
    /// 全局 BGM 模式：原声段改用整轨纯人声 wav（原视频 stems/vocals.wav）；nil = 常规模式
    let vocalsAudioPath: String?
    /// 人声切片窗（**原视频时间轴**，秒）。替换画面段也用原视频时间——替换片音轨本取自原视频同窗口。
    let vocalsStart: Double
    let vocalsEnd: Double

    init(videoPath: String, startFrame: Int, endFrame: Int, fps: Double,
         captionLines: [CaptionLine], hasHardSubtitle: Bool, maskStyleRaw: String,
         maskRect: SubtitleMaskRect, isVoiceLocked: Bool, dubAudioPath: String?,
         freezePadFrames: Int, trailingSilence: Double, bgmAudioPath: String?,
         subtitleFontRatio: Double,
         vocalsAudioPath: String? = nil, vocalsStart: Double = 0, vocalsEnd: Double = 0) {
        self.videoPath = videoPath; self.startFrame = startFrame; self.endFrame = endFrame
        self.fps = fps; self.captionLines = captionLines; self.hasHardSubtitle = hasHardSubtitle
        self.maskStyleRaw = maskStyleRaw; self.maskRect = maskRect; self.isVoiceLocked = isVoiceLocked
        self.dubAudioPath = dubAudioPath; self.freezePadFrames = freezePadFrames
        self.trailingSilence = trailingSilence; self.bgmAudioPath = bgmAudioPath
        self.subtitleFontRatio = subtitleFontRatio
        self.vocalsAudioPath = vocalsAudioPath; self.vocalsStart = vocalsStart; self.vocalsEnd = vocalsEnd
    }
}

/// 全局 BGM 铺底参数（导出时用户在导出页选中的 BGM）。
struct GlobalBGMSpec: Sendable {
    let audioPath: String
    /// BGM 音量 0…1（UI 默认 0.6）
    let volume: Double
}

/// 配音导出输入（整条成片）。
struct DubExportInput: Sendable {
    let segments: [DubSegmentSpec]
    let maxWidth: Int
    let maxHeight: Int

    /// dubOnly 策略下阻塞导出的单个槽位（带定位与人话原因；绝不回退原声）。
    struct Blocker: Sendable {
        let position: Int          // 槽位序号（从 1 起）
        let segmentLabel: String   // 分镜编号（seg_xxx）
        let reason: String
    }

    /// 导出输入构建错误（全部带可展示的人话描述）。
    enum BuildError: LocalizedError {
        case noOrderedSegments
        case allPicturesMissing
        case missingVocals(videoName: String)
        case dubOnlyBlocked([Blocker])

        var errorDescription: String? {
            switch self {
            case .noOrderedSegments:
                return "方案中没有可导出的分镜"
            case .allPicturesMissing:
                return "所有分镜的画面文件都缺失，无法导出（素材可能已被移动或删除）"
            case .missingVocals(let name):
                return "全局 BGM 模式缺少「\(name)」的纯人声音轨（vocals.wav），无法导出"
            case .dubOnlyBlocked(let blockers):
                let shown = blockers.prefix(8).map {
                    "第 \($0.position) 段（\($0.segmentLabel)）：\($0.reason)"
                }.joined(separator: "；")
                let more = blockers.count > 8 ? " 等 \(blockers.count) 段" : ""
                return "全新配音策略下以下分镜未就绪：\(shown)\(more)。请先在方案详情逐段生成配音后再导出（不会回退原声）"
            }
        }
    }

    /// 从某方案解析出导出输入（必须在 @MainActor 调用）。
    /// - Parameter combo: 每槽选定的变体 dubId（与 orderedSegments 对齐，nil=原声）。
    ///   传 nil 时退回按 SchemeSegment.selectedSegmentDubId 取定（单条/预览一致）。
    /// - Parameter useVocalsOnly: 全局 BGM 模式——原声段改用纯人声切片、配音段不混原分离 BGM。
    ///   keepOriginal 策略下任一分镜缺 vocals.wav 即抛错（预检阶段已保证分离成功）；
    ///   dubOnly 方案没有原声段，不要求 vocals。
    ///
    /// 声音策略（M4 接线，唯一依据 = `scheme.audioTrackPolicy`）：
    /// - `keepOriginal`：逐段「有配音用配音、无配音回退原声」（历史行为不变）；
    /// - `dubOnly`（产品脚本成片）：每槽必须使用物化时绑定的新配音且音频已生成，
    ///   不看分镜的 isVoiceLocked 标记；任一槽未就绪 → 抛 `dubOnlyBlocked`（带定位），
    ///   **绝不静默回退原声**（策略即承诺：画面静音 + 全新配音）。
    @MainActor
    static func from(scheme: MixScheme, combo: [UUID?]? = nil, useVocalsOnly: Bool = false) throws -> DubExportInput {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { throw BuildError.noOrderedSegments }

        let dubOnly = !scheme.audioTrackPolicy.allowsOriginalFallback
        var specs: [DubSegmentSpec] = []
        var maxW = 0, maxH = 0
        var blockers: [Blocker] = []

        for (idx, schemeSeg) in ordered.enumerated() {
            let position = idx + 1
            let segLabel = schemeSeg.segment?.segmentIndex ?? "第 \(position) 段"
            guard let segment = schemeSeg.segment,
                  let video = segment.video else {
                if dubOnly {
                    blockers.append(.init(position: position, segmentLabel: segLabel, reason: "分镜数据缺失"))
                }
                continue
            }
            // 走"当前生效画面"：替换版=合成片整段(0..frameCount)；原版=源视频帧区间。音频/字幕仍属分镜本身。
            let ep = segment.effectivePicture
            guard !ep.videoPath.isEmpty, FileHelper.isMaterialFilePresent(path: ep.videoPath) else {
                if dubOnly {
                    // 措辞并入唯一真源（此前是第四套自造说法「画面文件缺失」）；通道不动，仍进 blockers 列表。
                    blockers.append(.init(position: position, segmentLabel: segLabel,
                                          reason: MissingMaterialCopy.shortLabel))
                }
                continue
            }

            let fps = ep.fps > 0 ? ep.fps : 30
            maxW = max(maxW, video.width)
            maxH = max(maxH, video.height)

            // 该槽选定的变体：combo 指定优先，否则用 selectedSegmentDubId；nil 或找不到 → 原声
            let chosenId: UUID? = combo != nil ? (idx < combo!.count ? combo![idx] : nil)
                                               : schemeSeg.selectedSegmentDubId
            let chosen: SegmentDub? = chosenId.flatMap { dubId in
                segment.effectiveDubVariants.first { $0.id == dubId }
                // 注意：dubOnly 下不能用 effectiveDubVariants（它只含已有音频的变体）
                // 做"有没有绑定"的判定——未生成音频时需要给出精确原因而非"未选择配音"，
                // 因此绑定存在性在下面单独查全量 segmentDubs。
            }
            let chosenDubHasAudio: Bool = {
                guard let path = chosen?.audioFilePath else { return false }
                return FileManager.default.fileExists(atPath: path)
            }()

            // MARK: dubOnly：每槽唯选新配音，缺即记阻塞原因，绝不回退原声
            if dubOnly {
                // 先查"是否绑定了配音"（含尚无音频的空壳，用于区分两种未就绪原因）。
                let boundDub: SegmentDub? = chosenId.flatMap { dubId in
                    segment.segmentDubs.first { $0.id == dubId }
                }
                guard chosenId != nil, boundDub != nil else {
                    blockers.append(.init(position: position, segmentLabel: segLabel, reason: "未选择配音"))
                    continue
                }
                guard chosenDubHasAudio, let dub = chosen, let audioPath = dub.audioFilePath else {
                    blockers.append(.init(position: position, segmentLabel: segLabel,
                                          reason: "配音尚未生成，请先在方案详情生成配音"))
                    continue
                }
                specs.append(makeDubSpec(
                    segment: segment, ep: ep, fps: fps, video: video, dub: dub, audioPath: audioPath,
                    useVocalsOnly: useVocalsOnly))
                continue
            }

            // 全局 BGM 模式（仅 keepOriginal）：原声段必须能拿到纯人声源，缺一即整条不可导。
            var vocalsPath: String? = nil
            if useVocalsOnly {
                guard let vp = Self.vocalsPath(for: video) else {
                    MixLog.error("[Export] 全局 BGM 模式缺少 vocals.wav：\(video.name)")
                    throw BuildError.missingVocals(videoName: video.name)
                }
                vocalsPath = vp
            }

            if segment.isVoiceLocked || chosen == nil {
                specs.append(DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionLines: [], hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil,
                    subtitleFontRatio: segment.subtitleFontRatio,
                    vocalsAudioPath: vocalsPath, vocalsStart: segment.startTime, vocalsEnd: segment.endTime))
            } else if chosenDubHasAudio, let dub = chosen, let audioPath = dub.audioFilePath {
                specs.append(makeDubSpec(
                    segment: segment, ep: ep, fps: fps, video: video, dub: dub, audioPath: audioPath,
                    useVocalsOnly: useVocalsOnly))
            } else {
                // 非锁定但无已生成配音 → 回退保留原声原字幕，保证导出不中断
                MixLog.info("分镜 \(segment.segmentIndex) 无已生成配音，回退原声导出")
                // 故意写死 hasHardSubtitle: false：回退段不重配也不烧新字幕，
                // 因此不能遮挡旧硬字幕（否则会把要保留的原字幕也遮掉）。勿改回 segment.hasHardSubtitle。
                specs.append(DubSegmentSpec(
                    videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
                    fps: fps, captionLines: [], hasHardSubtitle: false, maskStyleRaw: segment.maskStyleRaw,
                    maskRect: segment.maskRect, isVoiceLocked: true, dubAudioPath: nil,
                    freezePadFrames: 0, trailingSilence: 0, bgmAudioPath: nil,
                    subtitleFontRatio: segment.subtitleFontRatio,
                    vocalsAudioPath: vocalsPath, vocalsStart: segment.startTime, vocalsEnd: segment.endTime))
            }
        }

        if dubOnly, !blockers.isEmpty {
            throw BuildError.dubOnlyBlocked(blockers.sorted { $0.position < $1.position })
        }
        // keepOriginal 路径：所有段都因画面缺失被跳过（dubOnly 的画面缺失已并入 blockers 抛出）。
        guard !specs.isEmpty else { throw BuildError.allPicturesMissing }
        return DubExportInput(segments: specs, maxWidth: maxW, maxHeight: maxH)
    }

    /// 构造一个配音段规格（dubOnly 与 keepOriginal 的配音路径共用，零分叉）。
    @MainActor
    private static func makeDubSpec(
        segment: Segment, ep: EffectivePicture, fps: Double, video: Video,
        dub: SegmentDub, audioPath: String, useVocalsOnly: Bool
    ) -> DubSegmentSpec {
        // 逐句字幕：优先用对齐好的 captionLines；旧数据无对齐 → 整段一条兜底（等价旧整段烧法，防止老数据丢字幕）
        let capLines: [CaptionLine] = {
            let lines = dub.captionLines
            if !lines.isEmpty { return lines }
            let whole = dub.rewrittenText.isEmpty ? segment.text : dub.rewrittenText
            return whole.isEmpty ? [] : [CaptionLine(text: whole, start: 0, end: segment.duration)]
        }()
        return DubSegmentSpec(
            videoPath: ep.videoPath, startFrame: ep.startFrame, endFrame: ep.endFrame,
            fps: fps, captionLines: capLines, hasHardSubtitle: segment.hasHardSubtitle, maskStyleRaw: segment.maskStyleRaw,
            maskRect: segment.maskRect, isVoiceLocked: false, dubAudioPath: audioPath,
            freezePadFrames: dub.freezePadFrames, trailingSilence: dub.trailingSilence,
            // 全局 BGM 模式下配音段不再混原视频分离 BGM（配音本身就是纯人声，BGM 最后整片统一铺）
            bgmAudioPath: useVocalsOnly ? nil : Self.bgmPath(for: video),
            subtitleFontRatio: segment.subtitleFontRatio)
    }

    // MARK: - 全局 BGM 预检范围

    /// 全局 BGM 模式下需要分离 vocals.wav 的源视频（去重保序）。
    /// 只含 keepOriginal 方案涉及的视频：dubOnly 方案没有原声段、不消费 vocals.wav，
    /// 把其视频纳入分离会白发数分钟 demucs；同视频被两类方案共用时以 keepOriginal 一侧为准。
    @MainActor
    static func videosRequiringVocals(for schemes: [MixScheme]) -> [Video] {
        var involved: [Video] = []
        var seen = Set<UUID>()
        for scheme in schemes where scheme.audioTrackPolicy.allowsOriginalFallback {
            for ss in scheme.orderedSegments {
                guard let video = ss.segment?.video, !seen.contains(video.id) else { continue }
                seen.insert(video.id)
                involved.append(video)
            }
        }
        return involved
    }

    /// 配音段的 BGM 源：demucs 分离出的整轨 bgm.wav（按视频内容哈希定位）；不存在 → nil（不混 BGM）。
    private static func bgmPath(for video: Video) -> String? {
        guard let hash = video.contentHash else { return nil }
        let path = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("bgm.wav").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 原声段的纯人声源：demucs 分离出的整轨 vocals.wav；不存在 → nil。
    /// 调用方（全局 BGM 模式）需已在预检阶段完成分离。
    private static func vocalsPath(for video: Video) -> String? {
        guard let hash = video.contentHash else { return nil }
        let path = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("vocals.wav").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// 把一个方案展开成「全部配音组合」：每个非锁定分镜可选「原声 + 各已生成改写版」，锁定分镜恒原声。
/// 用于导出时按笛卡尔积一次性导出多条视频。
@MainActor
enum SchemeComboPlanner {
    /// 单方案最多展开的组合数（防爆炸）。
    static let maxCombos = 256

    struct Combo: Sendable {
        let choices: [UUID?]     // 每槽选定 dubId（与 orderedSegments 对齐，nil=原声）
        let nameSuffix: String   // 文件名后缀，如 "[原·A·原·B·A]"
    }

    struct Plan {
        let combos: [Combo]
        let feasibleCount: Int   // 理论组合总数（笛卡尔积）
        let truncated: Bool      // feasibleCount > maxCombos（实际只取了前 maxCombos 条）
    }

    /// 理论组合总数（不真正生成；用于 UI 显示「将生成 N 条」）。
    static func feasibleCount(for scheme: MixScheme) -> Int {
        // dubOnly（产品脚本成片）：每槽唯选物化时绑定的新配音，组合恒为一条；
        // 任一槽未绑定 ⇒ 0（导出页会给出「哪些段还没生成配音」的精确提示）。
        if !scheme.audioTrackPolicy.allowsOriginalFallback {
            let ids = scheme.orderedSegments.map(\.selectedSegmentDubId)
            return DubOnlyExportPolicy.singleComboChoices(orderedSelectedDubIDs: ids) == nil ? 0 : 1
        }
        return scheme.orderedSegments.reduce(1) { acc, ss in
            guard let seg = ss.segment else { return acc }
            return acc * seg.combinationSlotCount   // 单一真源（含锁定/兜底/参与过滤）
        }
    }

    static func plan(for scheme: MixScheme) -> Plan {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { return Plan(combos: [], feasibleCount: 0, truncated: false) }

        // dubOnly：不展开「原声/各配音版」笛卡尔积——策略承诺全新配音、绝不回退原声，
        // 每槽唯选 selectedSegmentDubId；缺绑定时 0 组合，由 DubExportInput.from 给出阻塞明细。
        if !scheme.audioTrackPolicy.allowsOriginalFallback {
            let ids = ordered.map(\.selectedSegmentDubId)
            guard DubOnlyExportPolicy.singleComboChoices(orderedSelectedDubIDs: ids) != nil else {
                return Plan(combos: [], feasibleCount: 0, truncated: false)
            }
            return Plan(combos: [Combo(choices: ids, nameSuffix: "全新配音")],
                        feasibleCount: 1, truncated: false)
        }

        let slots: [SlotOptions] = ordered.map { ss in
            guard let seg = ss.segment else { return SlotOptions(isLocked: true, includeOriginal: true, dubIds: []) }
            return SlotOptions(
                isLocked: seg.isVoiceLocked,
                includeOriginal: seg.isVoiceLocked ? true : seg.originalParticipatesInCombination,
                dubIds: seg.isVoiceLocked ? [] : seg.combinationDubVariants.map { $0.id })
        }
        let result = VariantCombinationGenerator.generate(slots: slots, limit: maxCombos)

        let combos: [Combo] = result.combinations.map { choices in
            let parts: [String] = choices.enumerated().map { idx, dubId in
                guard let dubId,
                      idx < ordered.count,
                      let dub = ordered[idx].segment?.effectiveDubVariants.first(where: { $0.id == dubId }) else { return "原" }
                return Self.letter(dub.textVariantIndex)
            }
            return Combo(choices: choices, nameSuffix: "[" + parts.joined(separator: "·") + "]")
        }
        return Plan(combos: combos, feasibleCount: result.feasibleCount, truncated: result.truncated)
    }

    /// 改写版字母：0→A、1→B…
    private static func letter(_ index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }
}

/// 两阶段配音导出：逐分镜中间片 → concat 拼接。现有普通导出 ExportService 不受影响。
actor DubExportService {
    private let ffmpeg: FFmpegRunner

    init(ffmpeg: FFmpegRunner = FFmpegRunner()) {
        self.ffmpeg = ffmpeg
    }

    func export(
        input: DubExportInput,
        outputPath: String,
        config: ExportConfig = ExportConfig(),
        globalBGM: GlobalBGMSpec? = nil,
        onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws {
        guard !input.segments.isEmpty else { throw ExportError.noSegments }
        // 只能清理**本次导出自己创建**的文件：重导同名方案时目标路径上本来就有好文件，
        // 无条件删除会连用户原有的成片一起毁掉（同 `ExportService.export` 那条纪律）。
        let existedBefore = FileManager.default.fileExists(atPath: outputPath)

        // 输出分辨率（9:16，偶数）—— 换算与前置闸的唯一入口见 `Self.canvas`
        let canvas = try Self.canvas(for: config,
                                     sourceMaxWidth: input.maxWidth,
                                     sourceMaxHeight: input.maxHeight)
        let outW = canvas.width, outH = canvas.height

        // 临时工作目录
        let workDir = FileHelper.tempDirectory.appendingPathComponent("dubexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var intermediatePaths: [String] = []
        let total = input.segments.count

        // 阶段一：逐分镜中间片
        for (i, spec) in input.segments.enumerated() {
            onProgress?(ExportProgress(phase: .cutting,
                                       progress: Double(i) / Double(total) * 0.85,
                                       description: "处理分镜 \(i + 1)/\(total)…"))

            let interURL = workDir.appendingPathComponent(String(format: "seg_%03d.mp4", i))
            try await renderSegment(spec: spec, index: i, outW: outW, outH: outH,
                                    workDir: workDir, config: config, outputPath: interURL.path)
            intermediatePaths.append(interURL.path)
        }

        // 阶段二：concat 解复用器无损拼接。选了全局 BGM 时先落中间片，再铺底 BGM 到最终输出。
        onProgress?(ExportProgress(phase: .concatenating, progress: 0.88, description: "拼接成片…"))
        let concatTarget = globalBGM == nil
            ? outputPath
            : workDir.appendingPathComponent("voiced.mp4").path
        try await concatCopy(paths: intermediatePaths, workDir: workDir, outputPath: concatTarget)

        if let bgm = globalBGM {
            onProgress?(ExportProgress(phase: .concatenating, progress: 0.95, description: "铺底背景音乐…"))
            try await mixGlobalBGM(voicedPath: concatTarget, bgm: bgm, outputPath: outputPath)
        }

        // 后置回读：证明"计划画布"真的等于"落盘画布"（与 `ExportService.performExport` 同一条腿）。
        try await assertCanvasMatches(planned: canvas, outputPath: outputPath,
                                      createdItself: !existedBefore)

        onProgress?(ExportProgress(phase: .completed, progress: 1.0, description: "配音导出完成"))
    }

    // MARK: - 单分镜独立导出（分镜库变体导出用）

    /// 渲染单个分镜为独立 mp4。分辨率按本片自身宽高与 config 计算，不与其他片拼接。
    func exportSingleSegment(
        spec: DubSegmentSpec,
        videoWidth: Int,
        videoHeight: Int,
        outputPath: String,
        config: ExportConfig = ExportConfig()
    ) async throws {
        // 单分镜作业：这一段的自身尺寸就是"本批最大尺寸"，`.original` 下等价于整方案那条腿。
        let canvas = try Self.canvas(for: config,
                                     sourceMaxWidth: videoWidth,
                                     sourceMaxHeight: videoHeight)
        let outW = canvas.width, outH = canvas.height
        let workDir = FileHelper.tempDirectory.appendingPathComponent("dubseg-\(UUID().uuidString)")
        let existedBefore = FileManager.default.fileExists(atPath: outputPath)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await renderSegment(spec: spec, index: 0, outW: outW, outH: outH,
                                workDir: workDir, config: config, outputPath: outputPath)
        try await assertCanvasMatches(planned: canvas, outputPath: outputPath,
                                      createdItself: !existedBefore)
    }

    // MARK: - 单分镜中间片

    private func renderSegment(spec: DubSegmentSpec, index: Int, outW: Int, outH: Int,
                               workDir: URL, config: ExportConfig, outputPath: String) async throws {
        let mode: SubtitleMaskMode = spec.isVoiceLocked
            ? .none
            : SubtitleMaskMode.from(hasHardSubtitle: spec.hasHardSubtitle, maskStyleRaw: spec.maskStyleRaw)
        let maskPixel = PixelRect.from(spec.maskRect, outputWidth: outW, outputHeight: outH)

        // 输入按追加顺序编号：input 0 = 源视频，extraInputs 依次为 input 1..N。
        // 逐句字幕：每句一张 PNG，全部先 append（占 input 1..K），dub/bgm 序号随之自动后移。
        var captions: [CaptionOverlay] = []
        var dubAudioInputIndex = 1
        var bgmInputIndex: Int? = nil
        var extraInputs: [String] = []

        let keepOriginalAudio = spec.isVoiceLocked || spec.dubAudioPath == nil

        // 烧录逐句字幕：标点→空格；字号 = 成片宽度 × 该分镜自己的比例。锁定段不烧。
        if !spec.isVoiceLocked, !spec.captionLines.isEmpty {
            let canvasW = max(120, maskPixel.width)      // 字幕画布宽=遮挡区宽（下限 120px 防御逐字竖排）
            // 用**该分镜自己的**字号比例（以前读的是全局设置，界面调了导出却不跟随）
            let fontSize = max(12, Double(outW) * SubtitleFontSize.clamp(spec.subtitleFontRatio))
            // 底衬规则进了表（`SubtitleMaskMode.burnsCaptionBackdrop`），这里不再自己写 `!= .solid` ——
            // 它是 mode 的第三个消费者，散着写就又是两份真相。
            let withBackdrop = mode.burnsCaptionBackdrop
            for (li, line) in spec.captionLines.enumerated() {
                let burnText = CaptionRenderer.stripPunctuation(line.text)
                guard !burnText.isEmpty else { continue }
                let pngURL = workDir.appendingPathComponent(String(format: "cap_%03d_%02d.png", index, li))
                let img = try CaptionRenderer.renderToFile(
                    text: burnText, canvasWidth: canvasW, withBackdrop: withBackdrop,
                    fontSize: fontSize, to: pngURL)
                let origin = CaptionLayout.overlayOrigin(
                    outputWidth: outW, outputHeight: outH, maskRect: spec.maskRect,
                    captionWidth: img.pixelWidth, captionHeight: img.pixelHeight)
                extraInputs.append(pngURL.path)
                captions.append(CaptionOverlay(inputIndex: extraInputs.count, x: origin.x, y: origin.y,
                                               start: line.start, end: line.end))
            }
        }

        if !keepOriginalAudio, let dubPath = spec.dubAudioPath {
            extraInputs.append(dubPath)
            dubAudioInputIndex = extraInputs.count
            if let bgmPath = spec.bgmAudioPath, FileManager.default.fileExists(atPath: bgmPath) {
                extraInputs.append(bgmPath)
                bgmInputIndex = extraInputs.count
            }
        }

        // 全局 BGM 模式：原声段音频改取整轨纯人声切片。
        // 文件缺失 = 结果达不到「去原 BGM」的承诺，直接报错，绝不回退混音原声。
        var vocalsSource: VocalsSource? = nil
        if keepOriginalAudio, let vocPath = spec.vocalsAudioPath {
            guard FileManager.default.fileExists(atPath: vocPath) else {
                throw ExportError.missingVocals(vocPath)
            }
            extraInputs.append(vocPath)
            vocalsSource = VocalsSource(inputIndex: extraInputs.count,
                                        start: spec.vocalsStart, end: spec.vocalsEnd)
        }

        let graph = DubSegmentGraphBuilder.build(
            mode: mode,
            startFrame: spec.startFrame, endFrame: spec.endFrame, fps: spec.fps,
            outputWidth: outW, outputHeight: outH,
            maskPixel: maskPixel,
            captions: captions,
            keepOriginalAudio: keepOriginalAudio,
            dubAudioInputIndex: dubAudioInputIndex,
            freezePadFrames: spec.freezePadFrames,
            trailingSilence: spec.trailingSilence,
            bgmInputIndex: bgmInputIndex,
            vocalsSource: vocalsSource)

        var args: [String] = ["-y", "-i", spec.videoPath]
        for input in extraInputs { args += ["-i", input] }
        args += ["-filter_complex", graph.filterComplex,
                 "-map", graph.videoMapLabel, "-map", graph.audioMapLabel]

        // 统一硬件编码（中间片参数必须一致，阶段二才能 -c copy）。
        // 配音版导出固定走 h264_videotoolbox，故码率按 .h264Hardware 基准取，
        // 忽略 config.codec——否则软件编码档会落到 videoBitrateKbps 的 default(8000k) 与实际 h264 不匹配。
        let bitrate = config.quality.videoBitrateKbps(for: .h264Hardware)
        // -ac 2：强制所有中间片统一为立体声。否则原声段(立体声)与配音段(人声单声道/amix立体声)
        // 声道数不一致，阶段二 concat -c copy 会以首段为准，声道不符的段被播成静音（原声段无声 bug）。
        args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)k", "-maxrate", "\(bitrate * 2)k",
                 "-tag:v", "avc1", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2",
                 "-movflags", "+faststart", outputPath]

        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    // MARK: - 全局 BGM 铺底

    /// 把选中的 BGM 铺到纯口播成片上：视频流直拷（不重编码），音频 = 口播 + BGM 混音。
    /// BGM 短于成片由 -stream_loop 循环补齐，长于成片由滤镜 atrim 截断，结尾 1 秒淡出。
    private func mixGlobalBGM(voicedPath: String, bgm: GlobalBGMSpec, outputPath: String) async throws {
        guard FileManager.default.fileExists(atPath: bgm.audioPath) else {
            throw ExportError.encodingFailed(
                "背景音乐文件不存在：\((bgm.audioPath as NSString).lastPathComponent)，请回「BGM 库」检查")
        }
        let duration = await probeDuration(voicedPath)
        guard duration > 0 else {
            throw ExportError.encodingFailed("无法读取成片时长，背景音乐铺底失败")
        }
        let graph = GlobalBGMMixGraphBuilder.filterComplex(pieceDuration: duration, bgmVolume: bgm.volume)
        let args = ["-y", "-i", voicedPath,
                    "-stream_loop", "-1", "-i", bgm.audioPath,
                    "-filter_complex", graph,
                    "-map", "0:v", "-map", "[aout]",
                    "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2",
                    "-movflags", "+faststart", outputPath]
        _ = try await ffmpeg.run(arguments: args, totalDuration: nil, onProgress: nil)
    }

    /// 读容器时长（秒）；失败返回 0。
    private func probeDuration(_ path: String) async -> Double {
        let out = try? await ffmpeg.runProbe(arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
        return Double((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - 阶段二拼接

    private func concatCopy(paths: [String], workDir: URL, outputPath: String) async throws {
        let listURL = workDir.appendingPathComponent("list.txt")
        let body = paths.map { "file '\($0)'" }.joined(separator: "\n") + "\n"
        try body.write(to: listURL, atomically: true, encoding: .utf8)

        // 阶段二a：concat 无损拼接到临时文件
        let joined = workDir.appendingPathComponent("joined.mp4")
        let concatArgs = ["-y", "-f", "concat", "-safe", "0", "-i", listURL.path,
                          "-c", "copy", "-movflags", "+faststart", joined.path]
        _ = try await ffmpeg.run(arguments: concatArgs, totalDuration: nil, onProgress: nil)

        // 阶段二b：concat 会把首段 AAC 编码 priming 延迟转成视频起始时间偏移（start_time≈0.023s）。
        // 后果：t=0 处无帧 → QuickTime/各平台上传时截「首帧做封面」会得到黑图（实测 AVFoundation
        // 在 t=0 直接报 -11832 取不到帧）。这里把视频起始时间整体平移回 0，封面即为真实首帧。
        let startTime = await probeVideoStartTime(joined.path)
        if startTime > 0.001 {
            let fixArgs = ["-y", "-i", joined.path, "-c", "copy",
                           "-output_ts_offset", String(format: "%.6f", -startTime),
                           "-movflags", "+faststart", outputPath]
            _ = try await ffmpeg.run(arguments: fixArgs, totalDuration: nil, onProgress: nil)
            try? FileManager.default.removeItem(at: joined)
        } else {
            try? FileManager.default.removeItem(atPath: outputPath)
            try FileManager.default.moveItem(at: joined, to: URL(fileURLWithPath: outputPath))
        }
    }

    /// 读取视频流起始时间（秒）；失败返回 0。
    private func probeVideoStartTime(_ path: String) async -> Double {
        let out = try? await ffmpeg.runProbe(arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=start_time", "-of", "csv=p=0", path])
        return Double((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - 分辨率
    //
    // 原先这里有一份 `resolution(config:maxWidth:maxHeight:)`，与 `ExportService.performExport`
    // 里那份是同一规则的两份抄本，且两份并不等价（那份认横屏）。2026-10-19 一并收敛到
    // `MixCutCore.DeliveryCanvas.size` —— 唯一真源，App 侧不再留任何尺寸字面量。

    /// 档位 → 画布，并过导出前闸。整方案与单分镜两条腿共用这一处，
    /// 免得又长出第三份各写各的抄本。
    private static func canvas(for config: ExportConfig,
                               sourceMaxWidth: Int,
                               sourceMaxHeight: Int) throws -> DeliveryCanvas {
        let canvas = DeliveryCanvas.size(tier: config.resolution,
                                         sourceMaxWidth: sourceMaxWidth,
                                         sourceMaxHeight: sourceMaxHeight)
        if let blocked = DeliveryGate.rejectionMessage(for: config.deliveryTarget.spec,
                                                       width: canvas.width,
                                                       height: canvas.height) {
            throw ExportError.deliveryBlocked(blocked)
        }
        return canvas
    }

    /// 回读落盘画布并与计划值比对。读不到 / 不符 ⇒ 抛错。
    ///
    /// 抛错时只有**本次自己创建**的文件才删 —— 一个画布不对的 mp4 留在用户目录里，
    /// 双击能播、看着正常，只有拿到千川才会被发现；"看起来正常"是最坏的失败方式。
    private func assertCanvasMatches(planned: DeliveryCanvas,
                                     outputPath: String,
                                     createdItself: Bool) async throws {
        do {
            guard let actual = await ffmpeg.probeCanvasSize(path: outputPath) else {
                throw ExportError.canvasUnverifiable(outputPath)
            }
            guard actual == planned else {
                throw ExportError.canvasMismatch(planned: planned.filterString,
                                                 actual: "\(actual.width)×\(actual.height)")
            }
        } catch {
            if createdItself { try? FileManager.default.removeItem(atPath: outputPath) }
            throw error
        }
    }
}
