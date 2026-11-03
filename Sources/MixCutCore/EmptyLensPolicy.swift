import Foundation

// ============================================================================
// 空镜判定（C 块）—— 纯决策，住在 Core
// 计划真源：~/.qoder-cn/plans/mossy-sea-elk.md §二 C 块
//
// ## 要修的是什么
//
// 空镜（纯画面、没人说话，只有环境杂音）会被 Whisper **幻觉**出台词，而自动打标的判据
// 只看「文本非空」（`ImportViewModel.swift:552` 的 `!seg.text.isEmpty`，完全不吃音频）
// ⇒ 幻觉文本被当成真台词、进而被误打语义标签。
//
// ## 〔已证伪〕原先的概率层前提，2026-10-26 实测推倒
//
// 原设计写的是吃 whisper.cpp 的段级 `no_speech_prob` / `avg_logprob` /
// `compression_ratio_prob` 三颗键。**这三颗键在本仓包内的二进制输出的 JSON 里不存在。**
// 取证（不是读码推断，是真跑）：
//   MixCut/Resources/bin/whisper -m …/ggml-large-v3.bin -f X.wav -l zh
//     --output-json-full -of out          # 与 ASRService.runWhisperCppProcess 同一串参数
// 三份样本的段级键名册**完全一致**，只有 `['offsets','text','timestamps','tokens']`：
//   - 2s 纯正弦音      → 幻觉「字幕志愿者 杨茜茜」
//   - 2s 数字零静音    → 幻觉「优优独播剧场——YoYo Television Series Exclusive」
//   - 6.4s 真口播(对照组) → 转写正确
// 那三颗键是 **Python openai-whisper** 的 JSON 形态（见本文件 `ASRService` 里
// `parsePythonWhisperOutput` 的样例注释），被错记到了 whisper.cpp 头上。
//
// ## 实测真正被丢掉的是**逐 token 概率** `tokens[].p`
//
// token 级键名册实测为 `['id','offsets','p','t_dtw','text','timestamps']`，
// 而解析器的 `Token` 结构体原先只声明 `text` + `timestamps` ⇒ `p` 一直在这份 JSON 里、
// 被 JSONDecoder 静默丢弃。接住它零新增进程、零命令行改动
// （⚠️ **不许动 whisper 参数**：`ASRService.swift:547` 有事故注释 ——
// 上次加 `-ml 60 + -sow + --word-thold` 把长上下文识别能力打坏、大量识别错误，已回退）。
//
// ## 关键：概率层**单独定不了罪**（这是量出来的，不是调研听来的）
//
// 剔除特殊标记后（口径**同** `ASRService.cleanWhisperToken`：`[_BEG_]`/`[_TT_*]` 与纯空白 token
// 都不算数 —— 正弦音样本里那颗 `" "`(p=0.947) 会被它剔掉，所以 Swift 口径是 8 颗而不是 9 颗）：
//   样本                mean p        min p       p<0.2 占比
//   真口播（对照）        0.9832814     0.903962    0/23
//   正弦音幻觉           0.7227630     0.0124856   1/8
//   数字零静音幻觉        0.9238839     0.0162185   1/13
// ⇒ **mean p 不能定罪**：最强的那条幻觉（0.9238839）和真口播（0.9832814）只差 0.06，
//   而真口播里一个生僻词/英文品牌 token 就会把 min p 拉低。
//   早前联网调研说的"静音段幻觉是高置信度输出"在本地被复现了，本文件的判定规则
//   因此**只许让音频层定罪**，概率层降级为留痕与回测取样点。
//   判据里的黄金值由 EL-7 逐位复现，"不能定罪"这条由 EL-2／EL-3／EL-11 钉住。
//
// ## 音频层这一轮能接上多少（也是实测/实查，不是设想）
//
// - `silencedetect`：**导入主链上已经在跑**（`SceneDetectionService.detectSilence`，
//   `-30dB / 0.3s`，由 `analyzeLocally` 产出 `VideoLocalAnalysis.silencePeriods`），
//   但结果只喂给边界吸附和 AI prompt，**整段区间从未按分镜窗口消费过、也没落库**。
//   ⇒ 本文件给的是纯派生函数（区间 × 窗口求交集），不新增任何一次探测。
// - 数值 RMS 电平：**接不上**。`FFmpegRunner.probePureDigitalSilence` 只返回 Bool
//   （数字被丢），且唯一活调用点在导出侧 `concat` 里 —— 导入期根本没有这颗数据。
//   ⇒ 所以 signals 里没有 `rmsLevelDb` 字段；要它就得新探测，本轮不做。
// - 自建分镜路径（`ImportViewModel.importSelfSegments`）**不调 `analyzeLocally`**
//   ⇒ 那条路径上 silencePeriods 不存在，只能拿到概率层 ⇒ 按本文件规则恒为
//   `undetermined`（＝不拦）。这是范围事实，不是漏接。
// ============================================================================

/// 一段音频上能拿到的"有没有人说话"的证据。全部可选 ——
/// 缺证据时必须能区分"没这项数据"与"这项数据说没问题"，不许把缺读成 0。
///
/// `Codable` 是为了让证据能随 `ASRSentence` 落进 `asrSentencesData`（"这段为什么没打标"
/// 必须可追溯、可翻案，只存在内存里＝刷新就没了）。
/// ⚠️ 每个字段**必须保持 Optional**：`asrSentencesData` 是已落盘的 JSON，
/// 给已落盘的 Codable 结构加非 Optional 字段即使带默认值也会 keyNotFound（本仓实测）。
public struct EmptyLensSignals: Codable, Equatable, Hashable, Sendable {

    // ── 概率层（whisper 自己吐的逐 token / 逐词置信度）────────────────────
    // ⚠️ 这四颗**必须成组出现或成组缺失**：只填 mean 不填 count 会让"1 颗 token 的
    // 碎片"和"40 颗 token 的正常句"看着一样可信。

    /// 参与统计的 token 数（已剔除特殊标记）。nil = 该引擎没给逐词概率。
    public var tokenCount: Int?
    /// 逐 token 概率均值。
    public var meanTokenProb: Double?
    /// 逐 token 概率下界（最不确定那颗）。
    public var minTokenProb: Double?
    /// 概率低于 `lowTokenProbCeil` 的 token 占比，0…1。
    public var lowTokenProbFraction: Double?

    // ── 音频层（本仓已在跑的 silencedetect 派生）──────────────────────────

    /// 该窗口内**有声**时长占比（silencePeriods 的补集 ÷ 窗口长度），0…1。
    /// 这是本文件唯一能给出定罪证据的一层。
    public var voicedFraction: Double?

    public init(tokenCount: Int? = nil, meanTokenProb: Double? = nil,
                minTokenProb: Double? = nil, lowTokenProbFraction: Double? = nil,
                voicedFraction: Double? = nil) {
        self.tokenCount = tokenCount
        self.meanTokenProb = meanTokenProb
        self.minTokenProb = minTokenProb
        self.lowTokenProbFraction = lowTokenProbFraction
        self.voicedFraction = voicedFraction
    }

    /// 由**已剔除特殊标记**的逐 token 概率数组算出概率层四颗值。
    ///
    /// 唯一算数口径 —— 两个引擎（whisper.cpp 的 `tokens[].p`、Python whisper 的
    /// `segments[].words[].probability`）都走这里，避免同一族两种算法。
    /// "剔除哪一颗 token"不归本函数，归 `ASRService.cleanWhisperToken`（唯一口径持有者）。
    ///
    /// - Returns: 空数组 / 全非有限值 ⇒ 各概率字段 nil，**不是 0**：
    ///   "引擎没给概率"与"概率都是 0"是两回事，后者是证据、前者是没证据。
    public static func probabilityLayer(from probabilities: [Double]) -> EmptyLensSignals {
        let finite = probabilities.filter { $0.isFinite }
        guard !finite.isEmpty else { return EmptyLensSignals() }
        let sorted = finite.sorted()
        let low = finite.filter { $0 < EmptyLensPolicy.lowTokenProbCeil }.count
        return EmptyLensSignals(
            tokenCount: finite.count,
            meanTokenProb: finite.reduce(0, +) / Double(finite.count),
            minTokenProb: sorted.first,
            lowTokenProbFraction: Double(low) / Double(finite.count))
    }
}

public enum EmptyLensVerdict: String, Equatable, Sendable {
    /// 证据足够认定"这段没人说话" ⇒ 台词不写、不打语义标签、记为 `.emptyLens` 终态档
    case emptyLens
    /// 有说话的证据 ⇒ 走既有链路
    case hasSpeech
    /// 证据不足 ⇒ **按 hasSpeech 处理**（保守：宁可留一条错标，不可静默丢掉一条真口播）
    case undetermined
}

public enum EmptyLensPolicy {

    // ── 阈值 ────────────────────────────────────────────────────────────
    // 全部命名并集中在此，**开闸前必须先在他的真素材上只读回测**（本仓既有纪律）。
    // 下面每个数都标了来源；没有来源的不许写成"看起来合理"的值。

    /// 算 `lowTokenProbFraction` 时"算低置信"的下界。
    /// 来源：本次三对照实测的分界区间 —— 真口播 p<0.2 占比 0%，两条幻觉 8%/11%，
    /// 0.2 落在两者之间。⚠️ **每类样本 n=1**，此数只用于**留痕取样**，不参与定罪，
    /// 所以未经大样本回测是可接受的；一旦有人想把它升格成定罪阈值，必须先回测。
    public static let lowTokenProbCeil: Double = 0.2

    /// 有声占比上界：一段里几乎全是静音/杂音 ⇒ **唯一的定罪证据**。
    /// 与 `SceneDetectionService.detectSilence` 的 `-30dB / 0.3s` 口径配套。
    /// ⚠️ 未经回测；开闸前须在他的真分镜上摊开每条原值。
    public static let voicedFractionCeil: Double = 0.05

    // ── 音频层派生（纯函数，不新增探测）──────────────────────────────────

    /// 把整片静音区间（绝对时间轴，秒）与某个分镜窗口求交，得到窗口内**有声**占比。
    ///
    /// 口径：`1 − Σ(窗口 ∩ 每段静音) / 窗口长度`。重叠静音区间会先按起点排序合并，
    /// 否则上游若给出区间重叠的数据，占比能算出 >1。
    /// 窗口非正 / 不有限 ⇒ nil（＝这项证据缺失），不许当成"占比 0 ⇒ 判空镜"。
    /// 输入区间：非有限的**丢弃**；`end < start` 的**按 min/max 归一后保留**（不是丢弃）——
    /// 倒序多半是上游把两颗值写反，丢弃会让一段真静音凭空消失、占比偏松，归一才是无损修法。
    public static func voicedFraction(windowStart: Double, windowEnd: Double,
                                      silentIntervals: [(start: Double, end: Double)]) -> Double? {
        guard windowStart.isFinite, windowEnd.isFinite, windowEnd > windowStart else { return nil }
        let length = windowEnd - windowStart

        let clipped = silentIntervals.compactMap { iv -> (Double, Double)? in
            guard iv.start.isFinite, iv.end.isFinite else { return nil }
            let a = max(windowStart, min(iv.start, iv.end))
            let b = min(windowEnd, max(iv.start, iv.end))
            return b > a ? (a, b) : nil
        }
        guard !clipped.isEmpty else { return 1.0 }

        // 合并重叠：不合并的话 Σ交集 可超过窗口长度 ⇒ 占比变负、判定方向翻掉
        let sorted = clipped.sorted { $0.0 < $1.0 }
        var mergedStart = sorted[0].0
        var mergedEnd = sorted[0].1
        var silentTotal = 0.0
        for iv in sorted.dropFirst() {
            if iv.0 > mergedEnd {
                silentTotal += mergedEnd - mergedStart
                mergedStart = iv.0
                mergedEnd = iv.1
            } else {
                mergedEnd = max(mergedEnd, iv.1)
            }
        }
        silentTotal += mergedEnd - mergedStart

        return 1.0 - min(1.0, max(0.0, silentTotal / length))
    }

    /// 把同一时间窗上**多条** whisper 段的概率层合成一条。
    ///
    /// 为什么需要：分镜窗口和 whisper 自己切的段不对齐（whisper 默认 30s 大段，
    /// 见 `ASRService.swift:547` 那段"不用 -ml 强制切段"的决定），一个分镜常压在 1~2 条上。
    /// 口径：mean 按 token 数加权；min 取各 min 的最小；lowFraction 按 token 数加权。
    /// ⚠️ 不许"取第一条"或"取最大 mean" —— 那会让窗口里最不可信的那段悄悄消失。
    /// 全部缺概率 ⇒ 各概率字段 nil（保持"没证据"与"证据说没事"的区分）。
    public static func aggregateProbabilityLayer(_ parts: [EmptyLensSignals]) -> EmptyLensSignals {
        let present = parts.filter { ($0.tokenCount ?? 0) > 0 }
        guard !present.isEmpty else { return EmptyLensSignals() }
        let totalTokens = present.reduce(0) { $0 + ($1.tokenCount ?? 0) }
        guard totalTokens > 0 else { return EmptyLensSignals() }
        let weightedMean = present.reduce(0.0) { $0 + ($1.meanTokenProb ?? 0) * Double($1.tokenCount ?? 0) }
            / Double(totalTokens)
        let weightedLow = present.reduce(0.0) { $0 + ($1.lowTokenProbFraction ?? 0) * Double($1.tokenCount ?? 0) }
            / Double(totalTokens)
        return EmptyLensSignals(
            tokenCount: totalTokens,
            meanTokenProb: weightedMean,
            minTokenProb: present.compactMap(\.minTokenProb).min(),
            lowTokenProbFraction: weightedLow)
    }

    // ── 判定 ────────────────────────────────────────────────────────────

    /// 只读判定，**不产生副作用**。
    ///
    /// 生效条件：**只有音频层能判 `.emptyLens`**（`voicedFraction ≤ voicedFractionCeil`）。
    /// 概率层单独存在时最多给出 `hasSpeech` / `undetermined`。
    ///
    /// 为什么概率层不定罪：实测数字静音幻觉的 mean p = 0.924，与真口播的 0.983 只差
    /// 0.06（见文件头三对照表）。拿它定罪＝每天误杀真口播。
    ///
    /// 拦不住什么：
    /// 1. 一段里"半句有人说话、半句是杂音"—— 要靠逐段音频重听，不在此列；
    /// 2. 自建分镜路径没有 silencePeriods（见文件头"范围事实"）⇒ 恒 `undetermined`；
    /// 3. 已知套话黑名单 / 字数÷时长比异常这两层，用户本轮**未选**（见计划 §五 第 3 项）。
    ///
    /// 最坏代价：真口播被误判成空镜 ⇒ 该段不打标（不是丢数据，台词留痕可翻案）。
    public static func verdict(_ s: EmptyLensSignals) -> EmptyLensVerdict {
        if let v = s.voicedFraction, v.isFinite {
            return v <= voicedFractionCeil ? .emptyLens : .hasSpeech
        }
        // 概率层走到这里只贡献"我看到过证据"这件事，绝不单独定罪。
        // ⚠️ 口径是"四颗里任意一颗给了有限值"，不是只看 tokenCount：
        //    只看 count 会让手填的 mean=0.0（无 count）被读成"没证据"⇒ undetermined，
        //    把"引擎说了点什么"和"引擎什么都没说"混成一档。
        let sawProbability = [s.tokenCount.map { Double($0) }, s.meanTokenProb,
                              s.minTokenProb, s.lowTokenProbFraction]
            .contains { if case .some(let v) = $0, v.isFinite { return true } else { return false } }
        return sawProbability ? .hasSpeech : .undetermined
    }

    /// 该结论要不要**拦下打标**。
    ///
    /// ⚠️ 这是整块唯一的"拦/不拦"开关。默认**关**（`gateOpen = false`）——
    /// 按计划 §五 的纪律，先在他的真分镜上只读回测、摊开每条原值，再决定开。
    /// 开闸前本函数恒返回 false，于是 C 块只**记录**证据、不改变行为。
    public static let gateOpen: Bool = false

    public static func shouldSuppressTagging(_ v: EmptyLensVerdict) -> Bool {
        gateOpen && v == .emptyLens
    }
}
