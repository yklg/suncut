import Foundation

/// 逐段重听（自建分镜 / 逐段覆盖台词）这条路的**结果分类**（计划 §3.4，红线 R4/R5/R8）。
/// 计划写的是"六档"，实现出来是**七档**（`engineFailed` 与 `bothEnginesFailed` 不能合并，理由见那一条）。
///
/// 为什么住在核心层：六档的**判定**是纯的（给文本、给现值、给决策结论就能分类），
/// 而"跑哪台引擎、切什么格式"是引擎细节。分类留在 App 门面里就等于没测（可测面 = 下沉深度）。
public enum SegmentTranscribeOutcome: String, CaseIterable, Sendable {
    /// 认到字、内容与现台词不同 ⇒ 已写
    case replaced
    /// 认到了，但与现台词逐字相同 ⇒ **不写、来源也不刷**（R-e：内容没真变就不算一次变更）
    case unchanged
    /// 引擎跑成功但一个字也没认出来 ⇒ 原台词一字不动
    case emptyAudio
    /// 决策表就拒绝 ⇒ **引擎根本没跑**（没 Key / 本地不就绪 / 能力线不允许）
    case refused
    /// `auto` 下首选引擎失败、回落另一条也失败 ⇒ 两条路线都跑过了，都不通
    case bothEnginesFailed
    /// **只有一条腿**可跑（显式偏好，或 auto 但第二条腿压根没试）时那条路线失败
    ///
    /// 为什么不复用 `bothEnginesFailed`：用户把引擎设成"本地"、本机 whisper 挂了，
    /// 弹一句"两个引擎都失败"是假话 —— 另一个根本没试，而真实原因（模型没下 / GPU 崩）会被这句话盖掉。
    /// 这是写分类时才暴露出来的第六档不够用的形状，已回写计划 §8.6。
    case engineFailed

    /// 批次在第 k 段被取消（第 k+1 段不启动）
    case cancelled
}

/// 音频格式由**引擎**决定，不由调用方决定（红线 R5）。
public enum SegmentAudioFormat: String, Sendable {
    case pcm     // 云端 paraformer 走 WebSocket 流式，喂裸 s16le
    case wav     // 本机 whisper.cpp 要容器（16k 单声道 pcm_s16le）
}

public struct TranscribeAttempt: Equatable, Sendable {
    /// **实际跑了的那台引擎**。来源档位必须跟着它走：回落发生时文本是第二条腿认出来的，
    /// 记成首选那台就是假话（TC-80 抓的就是这个）。
    public let engine: ASREngine?
    /// 这一趟有没有真的跑到引擎
    public let ran: Bool
    /// 跑成功了吗（抛错/超时 = false）
    public let succeeded: Bool
    /// 认出来的文本（未成功时为 nil）
    public let text: String?

    public init(engine: ASREngine?, ran: Bool, succeeded: Bool, text: String?) {
        self.engine = engine
        self.ran = ran
        self.succeeded = succeeded
        self.text = text
    }

    /// 没跑（决策拒绝）
    public static var notRun: TranscribeAttempt { TranscribeAttempt(engine: nil, ran: false, succeeded: false, text: nil) }
    /// 跑了并拿到文本
    public static func ok(_ text: String, via engine: ASREngine) -> TranscribeAttempt {
        TranscribeAttempt(engine: engine, ran: true, succeeded: true, text: text)
    }
    /// 跑了但失败
    public static func failed(via engine: ASREngine) -> TranscribeAttempt {
        TranscribeAttempt(engine: engine, ran: true, succeeded: false, text: nil)
    }
}

public enum SegmentTranscribeRule {

    /// 引擎 → 音频格式（R5）。调用方**没有**格式参数：少一个能填错的口子。
    public static func format(for engine: ASREngine) -> SegmentAudioFormat {
        switch engine {
        case .cloud: return .pcm
        case .local: return .wav
        }
    }

    /// 引擎 → 台词来源档位（写库时记哪台引擎认的）。
    public static func source(for engine: ASREngine) -> TranscriptSource {
        switch engine {
        case .cloud: return .segmentCloud
        case .local: return .segmentLocal
        }
    }

    /// 结果分类 + 要不要落笔。
    ///
    /// `currentText` / `currentSource` 是分镜**当前**那两个值，由调用方取好传进来 ——
    /// 判"要不要写"必须拿真来源当基准，传个占位来源进去就是自欺。
    /// 返回的 `textToWrite` 只在 `.replaced` 时非空，且**已经过 `TextProvenance` 那一道 trim**；
    /// 调用方拿到就 `setText(result.textToWrite!, source: result.source!)`，自己不再判断空、不再 trim。
    public static func classify(currentText: String,
                                currentSource: TranscriptSource,
                                decision: EngineDecision,
                                primary: TranscribeAttempt,
                                fallback: TranscribeAttempt?,
                                cancelled: Bool) -> SegmentTranscribeVerdict {
        if cancelled { return SegmentTranscribeVerdict(outcome: .cancelled, source: nil, textToWrite: nil) }
        guard case .use = decision else {
            return SegmentTranscribeVerdict(outcome: .refused, source: nil, textToWrite: nil)
        }
        if !primary.ran {
            return SegmentTranscribeVerdict(outcome: .refused, source: nil, textToWrite: nil)
        }

        // 首选失败：只有拿到了"第二条腿"才算两引擎都失败；没第二条腿就如实报那一条挂了
        if !primary.succeeded {
            guard let fallback, fallback.ran else {
                return SegmentTranscribeVerdict(outcome: .engineFailed, source: nil, textToWrite: nil)
            }
            if !fallback.succeeded {
                return SegmentTranscribeVerdict(outcome: .bothEnginesFailed, source: nil, textToWrite: nil)
            }
            return classifyText(engine: fallback.engine ?? primary.engine,
                                currentText: currentText, currentSource: currentSource,
                                text: fallback.text)
        }
        return classifyText(engine: primary.engine, currentText: currentText,
                            currentSource: currentSource, text: primary.text)
    }

    private static func classifyText(engine: ASREngine?,
                                     currentText: String,
                                     currentSource: TranscriptSource,
                                     text: String?) -> SegmentTranscribeVerdict {
        // 引擎未知就不许编一个来源出来
        guard let engine else {
            return SegmentTranscribeVerdict(outcome: .engineFailed, source: nil, textToWrite: nil)
        }
        let writingSource = source(for: engine)
        let update = TextProvenance.resolve(current: currentText,
                                            currentSource: currentSource,
                                            incoming: text ?? "",
                                            writer: writingSource)
        guard update.shouldWrite, let next = update.textToWrite else {
            // 空识别 ⇒ emptyAudio；内容其实相同 ⇒ unchanged。两者都不落笔，但**必须能分辨**：
            // 前者要提示"这段没声音"，后者是正常结果（重听同一段本来就该常常 unchanged）。
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return SegmentTranscribeVerdict(outcome: trimmed.isEmpty ? .emptyAudio : .unchanged,
                                            source: nil, textToWrite: nil)
        }
        return SegmentTranscribeVerdict(outcome: .replaced, source: writingSource, textToWrite: next)
    }

    /// 是不是"拿到过有效文本"的档位（只有 `replaced` 与 `unchanged`）。
    /// 上层计数、Toast、保存都问这一个函数，不许各判各的 `outcome == .replaced`。
    public static func gotText(_ outcome: SegmentTranscribeOutcome) -> Bool {
        outcome == .replaced || outcome == .unchanged
    }

    /// 该不该计入"连续失败"从而提前停批。
    ///
    /// ⚠️ 这颗与 `gotText` **故意不是一回事**，分开是修一个真实存在的误判：
    /// `consecutiveFailureLimit` 存在的理由是"引擎坏了就别再逐段烧钱烧时间"，
    /// 而 `.emptyAudio` 的含义是**引擎跑完了、也确实一个字没有** —— 那是空镜（B-roll、
    /// 纯环境音）的**正确答案**，不是引擎故障。把它计成失败会导致：
    ///   一条视频里连续 3 段空镜 ⇒ 整批逐段重听被 `tooManyConsecutiveFailures` 提前停掉
    ///   ⇒ **后面真有口播的段再也拿不到字**。空镜越多的素材（带货实拍里很常见）越容易撞上。
    /// 实测读数见 `SegmentTranscribeRuleTests` 的 TC-AR-1。
    /// 只有真故障（`.engineFailed` / `.bothEnginesFailed`）才该停批；
    /// `.refused`（决策就没让跑）与 `.cancelled` 另有各自的上报通道，都不算故障。
    public static func countsAsBatchFailure(_ outcome: SegmentTranscribeOutcome) -> Bool {
        outcome == .engineFailed || outcome == .bothEnginesFailed
    }
}

/// 分类结论（含要不要落笔、落什么）。
public struct SegmentTranscribeVerdict: Equatable, Sendable {
    public let outcome: SegmentTranscribeOutcome
    /// 落笔时应记的来源；`outcome != .replaced` 时为 nil（**不写就不动来源**）
    public let source: TranscriptSource?
    /// 落笔的内容（已过 trim）；`outcome != .replaced` 时为 nil
    public let textToWrite: String?

    public init(outcome: SegmentTranscribeOutcome, source: TranscriptSource?, textToWrite: String?) {
        self.outcome = outcome
        self.source = source
        self.textToWrite = textToWrite
    }
}

/// 整批逐段重听的**停止规则**（计划 §3.4：连续 K 段失败即止 + 每段间查取消）。
/// 纯的：给已经发生的失败数与上限，回答该不该停。取消位由调用方（它才有那个状态）传进来。
public enum SegmentBatchPolicy {

    public enum BatchStop: Equatable, Sendable {
        case continueBatch
        case cancelled
        case tooManyConsecutiveFailures(Int)
    }

    /// - 连续失败数从 0 起算（拿到一次有效文本就归零）
    /// - 上限来自 `ASRPolicy.consecutiveFailureLimit`，不在这里写死
    public static func shouldStop(consecutiveFailures: Int, cancelled: Bool,
                                  limit: Int = ASRPolicy.consecutiveFailureLimit) -> BatchStop {
        if cancelled { return .cancelled }
        if limit > 0, consecutiveFailures >= limit { return .tooManyConsecutiveFailures(consecutiveFailures) }
        return .continueBatch
    }

    /// 失败段数怎么数：**只有引擎真故障算失败**。
    ///
    /// `.emptyAudio` 从前被算进 `failed`，那是错的（理由见 `countsAsBatchFailure`）——
    /// 现在单列一档，因为它既不是"拿到字"也不是"引擎坏了"，
    /// 而"这段没声音"这个信息本身要能上报给用户（空镜识别正是要用它）。
    /// 取消与拒绝仍各自单报，否则"没配 Key"会被报成"N 段识别失败"，
    /// 把配置问题伪装成识别质量问题。
    public static func tally(_ outcomes: [SegmentTranscribeOutcome])
        -> (gotText: Int, failed: Int, emptyAudio: Int, refused: Int, cancelled: Int) {
        var got = 0, failed = 0, empty = 0, refused = 0, cancelled = 0
        for outcome in outcomes {
            switch outcome {
            case .replaced, .unchanged: got += 1
            case .emptyAudio: empty += 1
            case .bothEnginesFailed, .engineFailed: failed += 1
            case .refused: refused += 1
            case .cancelled: cancelled += 1
            }
        }
        return (got, failed, empty, refused, cancelled)
    }
}

// MARK: - 逐段重听的风格锚与能力表（计划 v8；宽窗裁回那套已整块删除，见 §13）

/// 一台引擎在"逐段重听"上的能力。
public struct RetakeCapability: Equatable, Sendable {
    /// 能不能吃文字上下文（`--prompt`）⇒ 决定这一趟带不带简体风格锚
    public let contextPrompt: Bool

    public init(contextPrompt: Bool) { self.contextPrompt = contextPrompt }

    /// false = 最保守：不带锚。未登记的引擎落到这里，由 TC-120 变红点名。
    public static let none = RetakeCapability(contextPrompt: false)
}

public enum SegmentRetakeRule {

    /// 引擎能力表（唯一真源）。将来引入第三台引擎时只加一行，不改 switch。
    public static let capabilities: [ASREngine: RetakeCapability] = [
        .local: RetakeCapability(contextPrompt: true),
        .cloud: RetakeCapability(contextPrompt: false),
    ]

    public static func capability(for engine: ASREngine) -> RetakeCapability {
        capabilities[engine] ?? .none
    }

    /// 该引擎这次重听带不带简体风格锚。
    /// 锚跟着**实际跑的那台**走：auto 下云端失败回落本地时，第二腿是本地 ⇒ 必须带锚。
    public static func styleAnchor(for engine: ASREngine) -> String? {
        capability(for: engine).contextPrompt ? ASRPolicy.retakeStyleAnchor : nil
    }

    /// 自动链（导入、重跑分析）里，这一段值不值得再让引擎听一遍。
    ///
    /// 默认答案是**不值得**：边界已经只落在句子收尾时刻（`BoundaryAlignmentEngine` 的优先级，
    /// 计划 §AF），段台词就是从整片听写里切下来的完整句子；再听一遍是同一台模型拿**更少**的上下文
    /// 把同一句话重新错一次 —— §Q-4 实测逐段比整片贵 2.9 倍、逐字一致只有 3/12。
    /// 只有两种情形仍要补认，且都跟"整片那句话到底切到没切到"有关：
    /// ① 一个字也没切到（空段）；② 台词不是整片切片来的（来源在说谎的边缘：旧数据、
    ///    模型建议文本兜底、手改、重听过的），这时候整片口径帮不上忙，必须真听。
    /// 手动那颗「逐段重听」按钮**不走这里** —— 用户点名要重听就整条都听。
    public static func shouldAutoRetake(currentText: String,
                                        currentSource: TranscriptSource) -> Bool {
        if currentSource != .fullVideoSlice { return true }
        return currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 锚与业务文本是否零交集：共享任一长度 ≥2 的连续汉字片段即判为**有**交集。
    /// 单字重合（"的""一"）太常见，按单字判会天天误报，所以取二字组。
    // known-dead: 只有测试调用者（TC-115 用它钉锚的性质）。将来加第二颗锚时应由门面在启动期自检调用。
    public static func anchorIsContentFree(against sample: String) -> Bool {
        let anchor = Array(hanziStream(ASRPolicy.retakeStyleAnchor))
        guard anchor.count >= 2 else { return true }
        var anchorGrams = Set<String>()
        for i in 0...(anchor.count - 2) { anchorGrams.insert(String(anchor[i..<(i + 2)])) }
        let sample = Array(hanziStream(sample))
        guard sample.count >= 2 else { return true }
        for i in 0...(sample.count - 2) where anchorGrams.contains(String(sample[i..<(i + 2)])) {
            return false
        }
        return true
    }

    /// 识别结果里是否混进了锚的片段（`--prompt` 被当识别结果回吐）。
    /// 单测与运行期探针共用这一份实现（守卫 G26 守它只有一处定义）。
    public static func containsAnchorEcho(_ text: String, anchor: String) -> Bool {
        let window = 6
        let needle = Array(hanziStream(anchor))
        let hay = hanziStream(text)
        guard needle.count >= window, !hay.isEmpty else { return false }
        for i in 0...(needle.count - window) {
            if hay.contains(String(needle[i..<(i + window)])) { return true }
        }
        return false
    }

    // MARK: - 私有小工具

    /// 只留汉字与字母数字（标点/空白在 whisper 输出里位置不定，参与比对会假阳/假阴）。
    private static func hanziStream(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        })
    }
}
