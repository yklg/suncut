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
//   因此**概率层不参与定罪**（定罪只许能量层与套话名单层），概率字段留作痕迹与回测取样点。
//   判据里的黄金值由 EL-7 逐位复现，"不能定罪"这条由 EL-2／EL-3 钉住。
//   ⚠️ 另一条被实测**否掉**的候选是"字数密度层"（认出的字太少就算空镜）：他库内
//   `过渡/14.mp4` 的「请不吝点赞 订阅 转发 打赏」密度 2.06 字/秒，而三条已知真口播素材是
//   1.84–6.52 字/秒 —— 区间重叠，密度分不开。这一条 2026-11-04 回测结论，别再造这一层。
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
//   ⇒ 那条路径上 silencePeriods 不存在，能量层拿不到证据。但套话名单层**只看文本**，
//   所以那条路径不是全盲：命中名单的段照样判空镜，没命中的才是 `undetermined`（＝不拦）。
//   这是范围事实，不是漏接。
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

/// 定罪依据 —— **必须带出来**，不能只给一个布尔。
/// 「留痕可翻案」要求屏上和库里都能回答"这段凭什么被判空镜"，而两条腿的置信度与代价不同：
/// 安静窗口是硬证据（音频里没有声音），命中套话是模式证据（音频可能有声音、只是内容固定）。
public enum EmptyLensBasis: Codable, Equatable, Sendable {
    /// 窗口内有声占比 ≤ `voicedFractionCeil`
    case silentWindow
    /// 整段文本逐字命中 `knownHallucinationPhrases` 里某条 whisper 固定幻觉
    case knownPhrase(String)
}

public enum EmptyLensVerdict: Codable, Equatable, Sendable {
    /// 证据足够认定"这段没人说话" ⇒ 不打语义标签、台词留痕、记 `basis` 供翻案
    case emptyLens(EmptyLensBasis)
    /// 有说话的证据 ⇒ 走既有链路
    case hasSpeech
    /// 证据不足 ⇒ **按 hasSpeech 处理**（保守：宁可留一条错标，不可静默丢掉一条真口播）
    case undetermined

    /// 给日志与屏上的短标签（`basis` 的原文要另读，别把套话整句塞进列名）
    public var label: String {
        switch self {
        case .emptyLens(.silentWindow): return "emptyLens:silent"
        case .emptyLens(.knownPhrase):  return "emptyLens:phrase"
        case .hasSpeech:                return "hasSpeech"
        case .undetermined:             return "undetermined"
        }
    }

    /// 只给"是不是空镜"，不带依据 —— 供只关心结论的调用方（判定别在这一层分叉）
    public var isEmptyLens: Bool {
        if case .emptyLens = self { return true }
        return false
    }
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

    /// 有声占比上界：一段里几乎全是静音/杂音 ⇒ 定罪证据之一。
    /// 与 `SceneDetectionService.detectSilence` 的 `-30dB / 0.3s` 口径配套。
    ///
    /// **0.20 是回测定出来的，不是拍的**（2026-11-04，他的真库 `~/Desktop/褚橙` 全 108 条 +
    /// 分层抽 22 条逐段跑识别，台架逐位复现过 App 的读数）：
    /// - 整片分布是**双峰**的：100/108 条 ≥0.90、4 条 0.70–0.90、4 条 <0.15，
    ///   **0.15–0.70 之间一条都没有** ⇒ 这条线只能落在两峰之间的空档里，0.20 在档内。
    /// - 抬到 0.20 共拦 44/277 段，来源只有 4 条素材：`file_v3_…mov`(整片 0.082)、
    ///   `李巍/卖点/12（吃）.mp4`(0.095)、`李巍/过渡/11.mp4`(0.080，**用户确认没人说话**)、
    ///   `李巍/过渡/4.0.mp4`(0.000) ⇒ **零已知误杀**。
    /// - 为什么不是留在 0.05：0.05 会漏掉 `file_v3` 那段占比 0.160 的窗口 —— 它 11.5 秒里
    ///   只有 1.8 秒冒声，whisper 就认出一个置信 2.8% 的「鸡」字，正是要拦的形状。
    /// - 为什么不再往上抬：0.25 与 0.20 抓的是同一批段，多出来的 3 段仍出自这 4 条；
    ///   而线越高越靠近"说话中间有长停顿"的真口播 —— 库里**目前还没有这种样本**，
    ///   所以再抬就是没有依据的冒险。
    public static let voicedFractionCeil: Double = 0.20

    // ── 第二层：whisper 的固定幻觉套话 ────────────────────────────────────
    // 为什么必须有这一层（也是回测定出来的）：**带 BGM 的空镜在能量层上是隐身的** ——
    // 音乐一直响 ⇒ 占比 1.000。而他库里这类素材占绝大多数（100/108 条 ≥0.90）。
    // 更糟的是这类幻觉的**字数密度和真口播重叠**：`李巍/过渡/14.mp4` 认出
    // 「请不吝点赞 订阅 转发 打赏」= 2.06 字/秒，而三条已知真口播素材是 1.84–6.52 字/秒
    // ⇒ 所以"字数太少就是空镜"这条判据被实测**否掉**，不建；改用固定套话名单。
    //
    // 名单里的每一条都有**出处**（在他的真库里出现次数或我的复现样本），不许往里加猜的：
    // 这些字符串是 whisper 训练数据里"静音/纯音乐段的标配答案"，可枚举且稳定。

    /// 已实测复现的 whisper 固定幻觉文本。**只加有出处的，一条都不许多**。
    public static let knownHallucinationPhrases: [String] = [
        // 中文静音幻觉的头号常客。本仓两次独立复现：2s 数字零静音探针 + 他库内 2 条素材
        "优优独播剧场——YoYo Television Series Exclusive",   // 4.0.mp4、辅助卖点/17.mp4
        // 他截图里抱怨的那一句。李巍/过渡/14.mp4 整片占比 1.000（一直在响），全靠这条拦住
        "请不吝点赞 订阅 转发 打赏",
        // 外语字幕组水印式幻觉。李巍/过渡/11.mp4（用户确认没人说话）
        "字幕由 Amara.org 社区提供",
        // 2s 纯正弦音探针复现出来的另一条标配
        "字幕志愿者 杨茜茜",
    ]

    /// 整段文本是否就是某条已知套话（**归一化后前缀匹配**，不是子串）。
    ///
    /// 归一化复用 `SegmentRetakeRule.contentStream`（只留汉字与字母数字）⇒ 空格、逗号、
    /// 全半角破折号都不影响命中；whisper 同一句话在不同素材里标点位置不同，不做归一化就漏。
    ///
    /// ⚠️ 为什么是"前缀"而不是"子串"：子串会把真口播「大家先点个赞，别急着划走」也判成空镜 ——
    /// 那是**误杀真话**。前缀只放过"整段开头就是这套话"的文本，也就是幻觉的典型形状；
    /// 代价是"前半句真话＋后半句套话"这种混合段拦不住（保守方向，可接受）。
    /// 代价还有另一头：真口播若恰好以这套话开头会被误杀 ⇒ 留痕可翻案，且命中原文会记进 basis。
    ///
    /// 名单条目当锚时的最短长度（归一化后）。
    /// 「嗯」「好的」这类高频短句一旦进名单，前缀匹配会吞掉海量真口播 ⇒ 它们没资格当锚。
    /// ⚠️ 这个数同时被默认参数、卫生检查与判据 EL-15 引用；改它要连那三处一起想清楚。
    public static let minPhraseAnchorCount: Int = 8

    /// - Returns: 命中的那条名单原文（进日志与库里当翻案依据），未命中 nil。
    ///
    /// 注入缝（`phrases` / `minAnchorCount`）只为判据而存在，**默认值就是生产值**：
    /// 生效条件 —— 不传参时与生产路径逐字同一条；拦不住什么 —— 生产代码不许传自定义名单，
    /// 那会造出第二套判定（本仓的规矩是一条判据一个真源）；最坏代价 —— 名字被误用，
    /// 但两条判据（EL-13 的前缀/子串、EL-15 的短条目下限）都靠这两个参数才有对照物，
    /// 没有它们这两条是恒绿的（2026-11-04 变异实测：把前缀改成子串、把 8 改成 1，
    /// 原判据一批都没红）。
    public static func knownHallucinationHit(_ text: String,
                                             phrases: [String] = knownHallucinationPhrases,
                                             minAnchorCount: Int = minPhraseAnchorCount) -> String? {
        let needle = SegmentRetakeRule.contentStream(text)
        guard !needle.isEmpty else { return nil }
        for phrase in phrases {
            let hay = SegmentRetakeRule.contentStream(phrase)
            // 名单条目本身要够长才准当锚：短到几个字的条目会前缀命中大量真口播
            guard hay.count >= minAnchorCount else { continue }
            if needle.hasPrefix(hay) { return phrase }
        }
        return nil
    }

    /// 名单条目卫生检查：每条归一化后都必须 ≥ `minPhraseAnchorCount` 颗，否则它没资格当锚。
    /// 判据 EL-15 用它 —— 只测"短条目不生效"是不够的，那把下限改成 1 也照样绿。
    public static var shortlistedPhraseViolations: [String] {
        knownHallucinationPhrases
            .map { ($0, SegmentRetakeRule.contentStream($0).count) }
            .filter { $0.1 < minPhraseAnchorCount }
            .map { "\($0.0)（归一化后只有 \($0.1) 颗）" }
    }


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

    /// 只读判定，**不产生副作用**。两条腿**并联**，任一给出强证据即判空镜。
    ///
    /// 顺序有意：**先能量、后名单**。两者同时命中时（例：`李巍/过渡/4.0.mp4` 整片零有声
    /// 且文本正是「优优独播剧场——YoYo…」），库里记 `silentWindow` —— "连声音都没有"
    /// 比"文本长得像套话"更难反驳，翻案时该先看它。
    ///
    /// ⚠️ 名单层必须排在能量层的 `hasSpeech` **之前**判：带 BGM 的空镜能量层会说"一直在响"
    /// （占比 1.000），若能量层先给出 hasSpeech 就 return，名单层永远没有机会 ——
    /// 而那正是他库里 100/108 条素材的形状。
    ///
    /// 概率层（`tokens[].p`）**不参与定罪**：实测数字静音幻觉的 mean p = 0.9238839，
    /// 与真口播的 0.9832814 只差 0.06（见文件头三对照表）；拿它定罪＝每天误杀真口播。
    ///
    /// 拦不住什么（都有实测出处，不是设想）：
    /// 1. **纯音乐、且转写结果不是名单里的固定套话** —— 例：`李巍/辅助卖点/19.mp4` 用户确认
    ///    没人说话，whisper 把乐器声认成「Zither Harp」，能量层看不见、名单也没有这一条。
    ///    要拦只能靠人声/伴奏分离的能量比（本仓有 demucs，但对未分离的素材是新探测）
    ///    或语义层判"像不像卖货话术"（花钱）。两条都没选，先记为已知漏口。
    /// 2. 一段里"半句有人说话、半句是杂音"—— 要靠逐段音频重听，不在此列。
    /// 3. 真口播若恰好以名单里的套话开头会被误杀 ⇒ 命中原文记进 `basis`，台词留痕可翻案。
    ///
    /// 最坏代价：真口播被误判成空镜 ⇒ 该段不打语义标签（不是丢数据，文本与依据都还在）。
    public static func verdict(_ s: EmptyLensSignals, text: String) -> EmptyLensVerdict {
        if let v = s.voicedFraction, v.isFinite, v <= voicedFractionCeil {
            return .emptyLens(.silentWindow)
        }
        if let phrase = knownHallucinationHit(text) {
            return .emptyLens(.knownPhrase(phrase))
        }
        if let v = s.voicedFraction, v.isFinite {
            return .hasSpeech
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

    /// 只用**已存文本**判的空镜口径（能量层没有输入时的唯一一条腿）。
    ///
    /// 为什么要单独一颗：`verdict(EmptyLensSignals(), text:)` 这个"零信号 + 名单层"的组合
    /// 有两个调用方 —— 自建分镜路径（拿不到静音区间）与旧库补标（不重听）。
    /// 两边各写一遍 `EmptyLensSignals()`，将来有人改信号默认值就会只改到一边。
    public static func phraseOnlyVerdict(_ text: String) -> EmptyLensVerdict {
        verdict(EmptyLensSignals(), text: text)
    }

    /// 只看文本能不能定罪成空镜（名单层单腿）。
    ///
    /// 两个消费者必须同一颗：① 旧库补标的命中集；② 自动链上"这段值不值得再听一遍"的免听依据
    /// （重跑分析会删旧段重建 ⇒ 标签还不存在，只能现判文本）。各写一遍就会漂。
    ///
    /// ⚠️ 与 `BrollPolicy.acceptsAsSupply` **不是重复**，别顺手合并：那颗刻意**不带** `gateOpen`
    ///（拦打标的开关不该决定"已有画面能不能用"，关闸会静默清空插片池），而这里两件事都该受开关管 ——
    /// 补标是在写标签、免听是"要不要花钱再听"，开关关着的日子里两者都不许动。
    /// 名单规则本身只有一处真源：`phraseOnlyVerdict`。
    public static func phraseOnlyConvicts(_ text: String) -> Bool {
        shouldSuppressTagging(phraseOnlyVerdict(text))
    }

    /// 该结论要不要**拦下打标**。
    ///
    /// **2026-11-04 开闸**（原来写死 false，纪律是"先在他的真素材上只读回测再开"）：
    /// 回测已完成 —— 全库 108 条的占比双峰、分层 22 条 277 段的拦截表、
    /// 以及用户对 4 条样本的人工确认（`过渡/14`、`过渡/11`、`辅助卖点/17`、`辅助卖点/19` 均无人说话），
    /// 读数与依据逐条记在上面的 `voicedFractionCeil` 与名单注释里，不是"看起来合理"。
    ///
    /// 开闸的确切范围：**只有 `verdict == .emptyLens` 的段不写语义标签**；
    /// 台词文本、命中依据（哪条腿／哪句套话）、逐 token 证据一律保留 ⇒ 可翻案。
    /// `undetermined` 与 `hasSpeech` 走原链路，行为与开闸前完全一致。
    ///
    /// ⚠️ 这颗开关**只管打标**，不管逐段重听：重听的终态档在
    /// `SegmentRetakeRule.shouldAutoRetake(isEmptyLensSettled:)`（M1，2026-11-05 落地），
    /// 它吃的真源就是这里写下的「空镜」标签 —— 同一件事、一处写入、两处读取。
    /// 别把两件事记成一颗开关：摘掉标签会同时恢复打标与重听，那是刻意设计（人不认可机器判断时
    /// 该有的行为），不是这里漏了什么。
    public static let gateOpen: Bool = true

    public static func shouldSuppressTagging(_ v: EmptyLensVerdict) -> Bool {
        gateOpen && v.isEmptyLens
    }
}


// MARK: - AI 可指派语义标签的唯一名册

/// AI 面（prompt 正文、MCP 工具描述、归一化表）允许出现的语义标签名册 —— **唯一真源**。
///
/// ## 为什么住在 Core、而且是字符串
///
/// `AgentToolCatalog` 与 `SlotRetrievalIntent` 都在 `Sources/MixCutCore`，**看不见** App 层的
/// `SemanticType` 枚举；而 Core 侧本来就用 rawValue 字符串表达标签（见 `NarrativeModels`）。
/// 所以派生方向只能是 Core → App：App 层的 `SemanticType.aiAssignableTypes` 从这里生成。
/// 反过来（把枚举抬进 Core）要动 schema 与 36 条手工 pbxproj 引用，不是这一轮该付的账。
///
/// ## 为什么刻意不含「空镜」
///
/// 「空镜」是机器结论（本文件 `EmptyLensPolicy` 是唯一写入方）：模型只拿到文本，看幻觉文本
/// 是看不出静音的，让它可选等于给它一条凭文本编造静音结论的口子。`EmptyLensTagBoundaryTests`
/// 的 ETB-2 钉的就是这件事。
///
/// ## ⚠️ 这颗文件不许加进 `EmptyLensTagBoundaryTests.tagBearingFiles`
///
/// 那颗守卫的判据是"文本里出现『空镜』二字就算违规"，而本文件（和这颗名册的注释）必须写出
/// 那颗标签的名字才能解释**为什么排除它**。加进去会让 ETB-2 当场红，且红的是解释而不是违规。
/// 名册的完整性由 `SemanticRosterTests` 的 SR-1~SR-4 负责，不归 ETB 管。
public enum SemanticRoster {

    /// 11 类 AI 可指派标签。顺序沿用历史名册，改顺序会改 prompt 里的呈现次序。
    public static let aiAssignable: [String] = [
        "噱头引入", "痛点", "产品方案", "效果展示", "信任背书", "价格对比",
        "活动福利", "行动号召", "产品定位", "产品使用教育", "过渡",
    ]

    /// 位置名册（与 App 层 `PositionType` 的 rawValue 一一对应）。
    public static let positions: [String] = ["开头", "中间", "结尾"]

    /// 给 MCP 工具描述用的斜杠分隔串。
    public static var slashList: String { aiAssignable.joined(separator: "/") }

    /// 给 prompt 正文用的带引号顿号串：`"噱头引入"、"痛点"…`
    public static var promptList: String {
        aiAssignable.map { "\"\($0)\"" }.joined(separator: "、")
    }

    /// 位置的同一条串，给 MCP 描述用。
    public static var positionSlashList: String { positions.joined(separator: "/") }
}
