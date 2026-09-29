import Foundation

/// 逐段重听的**唯一出口**（红线 R4）。
///
/// 以前"给一个分镜重认台词"这件事在仓库里有三份各写各的实现（两处 VM 循环 + 拆分后补认），
/// 三处都**硬编码云端**、都把空识别当成功、都没有超时与取消纪律。收敛到这一个门面后：
/// - 用哪台引擎只问 `ASREngineDecision`（界面/能力面/这里同一个答案）
/// - **格式由引擎决定**（R5：调用方没有格式参数可填）
/// - 判空与"要不要落笔"由核心层 `SegmentTranscribeRule` 定，门面只跑腿
/// - 临时文件每个分支都清（R-h），失败原因带得上界面
actor SegmentTranscriber {

    static let shared = SegmentTranscriber()

    private let localEngine = ASRService()
    private let cloudEngine = QwenASRClient()
    private let ffmpeg = FFmpegRunner()

    /// 一条逐段重听请求。全是**纯值**：门面不碰 SwiftData，`Segment` 留在调用方那边写。
    struct Request: Sendable {
        let videoPath: String
        let segmentIndex: String
        let startSeconds: Double
        let endSeconds: Double
        /// 该段当前台词与来源 —— 判"要不要落笔"必须拿真值当基准
        let currentText: String
        let currentSource: TranscriptSource
    }

    struct Result: Sendable {
        let outcome: SegmentTranscribeOutcome
        /// **实际跑的**那台（回落时是第二条腿）；没跑成则 nil
        let engine: ASREngine?
        let tier: String?
        let rootKind: ModelRoot?
        let format: SegmentAudioFormat?
        let elapsed: TimeInterval
        let fallbackUsed: Bool
        /// 失败/拒绝的用户可读原因
        let reason: String?
        /// 仅 `.replaced` 时非空
        let textToWrite: String?
        let sourceToWrite: TranscriptSource?
        /// 这一趟有没有带简体风格锚（短窗防繁简漂移）。跟着**实际跑的那台**走
        let anchorUsed: Bool

        var gotText: Bool { SegmentTranscribeRule.gotText(outcome) }
    }

    // MARK: - 入口

    func transcribe(_ request: Request, purpose: ASRPurpose = .segmentTextRetake) async -> Result {
        let started = Date()
        let report = ASRService.modelReport()
        let decision = ASREngineDecision.decide(purpose: purpose,
                                                preference: ASRSettings.storedPreference,
                                                hasCloudKey: ASRSettings.hasCloudKey,
                                                local: LocalASRState(usable: report.usable,
                                                                    tier: report.selectedTier))
        let preference = ASRSettings.storedPreference ?? ASRPolicy.defaultPreference

        guard case .use(let chosen, _) = decision else {
            let verdict = SegmentTranscribeRule.classify(
                currentText: request.currentText, currentSource: request.currentSource,
                decision: decision, primary: .notRun, fallback: nil, cancelled: false)
            return finish(verdict: verdict, engine: nil, report: report, format: nil,
                          fallbackUsed: false, reason: decisionReason(decision),
                          anchorUsed: false,
                          elapsed: Date().timeIntervalSince(started))
        }

        // 第一条腿
        var primary = await run(chosen, request: request)
        var usedEngine = chosen
        var fallbackUsed = false
        let primaryReason = primary.failureReason

        // 只有 auto 才有第二条腿：显式偏好失败就如实失败，不静默改路线（与 TC-77 同一条纪律）
        if !primary.attempt.succeeded, preference == .auto,
           let other = Self.theOtherLeg(then: chosen), Self.legAvailable(other) {
            MixLog.error("[ASR] \(request.segmentIndex) 首选 \(chosen.rawValue) 失败，改试 \(other.rawValue)")
            let second = await run(other, request: request)
            fallbackUsed = true
            if second.attempt.succeeded {
                primary = second
                usedEngine = other
            }
            // 两条都挂：保留第一条的错因（那才是用户配的那条路线的真实问题）
        }

        let verdict = SegmentTranscribeRule.classify(
            currentText: request.currentText,
            currentSource: request.currentSource,
            decision: decision,
            primary: primary.attempt,
            fallback: nil,
            cancelled: Task.isCancelled)
        return finish(verdict: verdict, engine: usedEngine, report: report,
                      format: SegmentTranscribeRule.format(for: usedEngine),
                      fallbackUsed: fallbackUsed, reason: primaryReason,
                      anchorUsed: primary.anchorUsed,
                      elapsed: Date().timeIntervalSince(started))
    }

    private static func theOtherLeg(then engine: ASREngine) -> ASREngine? {
        switch engine {
        case .cloud: return .local
        case .local: return .cloud
        }
    }

    private static func legAvailable(_ engine: ASREngine) -> Bool {
        switch engine {
        case .cloud: return ASRSettings.hasCloudKey
        case .local: return ASRService.modelReport().usable && ASRService.findWhisperBinaryStatic() != nil
        }
    }

    // MARK: - 一条腿：切音频（格式由引擎定）→ 送引擎

    private struct LegResult {
        let attempt: TranscribeAttempt
        let failureReason: String?
        /// 这一腿实际带没带锚（回落时以真正跑通那一条为准）
        let anchorUsed: Bool
    }

    private func run(_ engine: ASREngine, request: Request) async -> LegResult {
        let format = SegmentTranscribeRule.format(for: engine)
        let anchor = SegmentRetakeRule.styleAnchor(for: engine)

        let ext = format == .pcm ? "pcm" : "wav"
        let audioURL = FileHelper.tempDirectory
            .appendingPathComponent("segasr-\(UUID().uuidString).\(ext)")
        // ⚠️ defer 在第一次 fallible 操作之前注册：任何分支（含抛错、取消）都不许留临时文件（R-h）
        defer { try? FileManager.default.removeItem(at: audioURL) }

        func failure(_ reason: String?) -> LegResult {
            LegResult(attempt: TranscribeAttempt(engine: engine, ran: true, succeeded: false, text: nil),
                      failureReason: reason, anchorUsed: anchor != nil)
        }

        do {
            switch format {
            case .pcm:
                try await ffmpeg.extractSegmentPCM(from: request.videoPath, start: request.startSeconds,
                                                   end: request.endSeconds, to: audioURL.path)
            case .wav:
                try await ffmpeg.extractSegmentAudio(from: request.videoPath, start: request.startSeconds,
                                                     end: request.endSeconds, to: audioURL.path)
            }
        } catch {
            let reason = FriendlyError.reason(for: error)
            MixLog.error("[ASR] \(request.segmentIndex) 切音频失败(\(engine.rawValue)): \(reason)")
            return failure("切取这段音频失败：\(reason)")
        }

        do {
            let text: String
            switch engine {
            case .cloud:
                text = try await Self.withCloudTimeout(seconds: ASRPolicy.perSegmentTimeoutSeconds) { [cloudEngine] in
                    try await cloudEngine.transcribe(pcmPath: audioURL.path)
                }
            case .local:
                // 本机这条不设门面级超时：whisper 子进程自己已有 600s/3600s 上限，
                // 外面再套一层只会把"慢但成功"变成"被杀且留下孤儿进程"。
                let result = try await localEngine.transcribeAudioFile(path: audioURL.path, prompt: anchor)
                // 锚被回吐 ⇒ 按**这一腿失败**处理，不新开一档：
                // 说"没识别出文字"是假话（识别出来了，只是不可信），说"失败"才是真的。
                if let anchor, SegmentRetakeRule.containsAnchorEcho(result.text, anchor: anchor) {
                    MixLog.error("[ASR] \(request.segmentIndex) 结果里混进了风格锚，按失败处理")
                    return failure("识别结果混入了提示文本，已拒绝采用（这段台词保持原样）")
                }
                text = result.text
            }
            return LegResult(attempt: .ok(text, via: engine), failureReason: nil,
                             anchorUsed: anchor != nil)
        } catch is CancellationError {
            return failure("已取消")
        } catch {
            let reason = FriendlyError.reason(for: error)
            MixLog.error("[ASR] \(request.segmentIndex) 识别失败(\(engine.rawValue)): \(reason)")
            return failure(reason)
        }
    }

    /// 云端 WebSocket 卡住会永久占住整批 —— 这一档超时只加在网络腿上。
    private static func withCloudTimeout<T: Sendable>(seconds: Double,
                                                      _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ASRError.recognitionFailed
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - 组装结果

    private func finish(verdict: SegmentTranscribeVerdict, engine: ASREngine?,
                        report: ModelReport, format: SegmentAudioFormat?, fallbackUsed: Bool,
                        reason: String?, anchorUsed: Bool,
                        elapsed: TimeInterval) -> Result {
        let isLocal = engine == .local
        return Result(outcome: verdict.outcome,
                      engine: engine,
                      tier: isLocal ? report.selectedTier : nil,
                      rootKind: isLocal ? report.selected?.root : nil,
                      format: format,
                      elapsed: elapsed,
                      fallbackUsed: fallbackUsed,
                      reason: reason ?? verdictReason(verdict.outcome),
                      textToWrite: verdict.textToWrite,
                      sourceToWrite: verdict.source,
                      anchorUsed: anchorUsed)
    }

    private func decisionReason(_ decision: EngineDecision) -> String? {
        if case .refused(let reason) = decision { return reason }
        return nil
    }

    /// 没跑成的分类档也要有一句人话（调用方直接进 Toast，不许自己编）。
    private func verdictReason(_ outcome: SegmentTranscribeOutcome) -> String? {
        switch outcome {
        case .emptyAudio: return "这段音频没有识别出任何文字（可能是纯画面、纯音乐或人声太轻）"
        case .cancelled: return "已取消"
        case .replaced, .unchanged: return nil
        case .refused, .engineFailed, .bothEnginesFailed: return nil   // 由 decisionReason / 引擎错因给
        }
    }
}
