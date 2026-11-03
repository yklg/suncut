import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// EL · 空镜判定（C 块 Core 判据）
//
// 这一批只测**纯决策**。它不改变任何行为 —— `EmptyLensPolicy.gateOpen` 目前为 false，
// 按计划 §五 的纪律要先在真素材上只读回测再开。所以本文件证的是"闸一旦开，
// 它判得对"，不是"已经在拦了"。这个区别必须写清楚，否则会有人以为 ② 已经修好了。
//
// ## 〔已证伪〕本文件 2026-10-26 整体重写
//
// 旧版 EL-1/EL-3/EL-5/EL-7 建立在段级 `no_speech_prob` / `avg_logprob` 与数值 RMS 上，
// 那些字段**在本仓包内 whisper.cpp 的 JSON 里不存在**（段级键名册实测只有
// `['offsets','text','timestamps','tokens']`；`probePureDigitalSilence` 只返回 Bool
// 且唯一活调用点在导出侧）。旧判据是"拿我编的输入测我编的规则"——恒真、无取证力。
// 现在每条都改吃实测真存在的量：逐 token `p` 与 silencedetect 区间派生的有声占比。
//
// 黄金值来源（可复跑）：
//   MixCut/Resources/bin/whisper -m …/ggml-large-v3.bin -f X.wav -l zh \
//     --output-json-full -of out            # 与 ASRService.runWhisperCppProcess 同一串参数
//   X = 2s 正弦音 / 2s 数字零静音 / 6.4s 真口播（对照组），产物在 .scratch/c-block-evidence/
// ============================================================================

@Suite("EL · 空镜判定口径")
struct EmptyLensPolicyTests {

    // ── 实测黄金值（剔除特殊标记后的逐 token 概率统计，逐位取自包内二进制的三份 JSON）──
    // tone（2s 纯正弦，幻觉出「字幕志愿者 杨茜茜」）
    private static let toneHallucination = EmptyLensSignals(
        tokenCount: 8, meanTokenProb: 0.7227629500000001, minTokenProb: 0.0124856,
        lowTokenProbFraction: 0.125)
    // 数字零静音（幻觉出「优优独播剧场——YoYo Television Series Exclusive」）
    private static let silenceHallucination = EmptyLensSignals(
        tokenCount: 13, meanTokenProb: 0.9238838846153844, minTokenProb: 0.0162185,
        lowTokenProbFraction: 1.0 / 13.0)
    // 对照组：6.4s 真口播，转写正确
    private static let realSpeech = EmptyLensSignals(
        tokenCount: 23, meanTokenProb: 0.9832814347826084, minTokenProb: 0.903962,
        lowTokenProbFraction: 0.0)

    // MARK: EL-1 定罪腿（音频层）

    @Test("EL-1 只有音频层能定罪：有声占比达上界 ⇒ 判空镜")
    func voicedFractionConvicts() {
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: EmptyLensPolicy.voicedFractionCeil))
                == .emptyLens, "恰等上界必须算（边界取 <=）")
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: EmptyLensPolicy.voicedFractionCeil + 0.01))
                == .hasSpeech)
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: 0.0)) == .emptyLens)
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: 1.0)) == .hasSpeech)
    }

    @Test("EL-2 概率层单独存在时**永不**判空镜（实测数字静音幻觉 mean=0.924，与真口播只差 0.06）")
    func probabilityLayerAloneNeverConvicts() {
        for s in [Self.toneHallucination, Self.silenceHallucination, Self.realSpeech] {
            #expect(EmptyLensPolicy.verdict(s) != .emptyLens,
                    "概率层被升格成定罪层了 —— 这条一旦变红说明有人给 verdict 加了概率分支，而实测幻觉的 mean p 能高到 0.9238839，会误杀真口播")
        }
        // 极端值也不许定罪：这条防的是"把 min 或 lowFraction 单独拿去当空镜证据"
        let extreme = EmptyLensSignals(tokenCount: 40, meanTokenProb: 0.01,
                                       minTokenProb: 0.0, lowTokenProbFraction: 1.0)
        #expect(EmptyLensPolicy.verdict(extreme) == .hasSpeech,
                "全片最低置信度也不等于没人说话 —— 一个生僻词/英文品牌 token 就能把置信度打下来")
    }

    @Test("EL-3 音频层定罪优先，且概率层不能把结论翻回来")
    func audioLayerWinsOverProbability() {
        let silentWithConfidentHallucination = EmptyLensSignals(
            tokenCount: Self.silenceHallucination.tokenCount,
            meanTokenProb: Self.silenceHallucination.meanTokenProb,
            minTokenProb: Self.silenceHallucination.minTokenProb,
            lowTokenProbFraction: Self.silenceHallucination.lowTokenProbFraction,
            voicedFraction: 0.0)
        #expect(EmptyLensPolicy.verdict(silentWithConfidentHallucination) == .emptyLens,
                "两条证据同时具备时不判空镜 ⇒ 判定顺序写反了")

        let voicedButUncertain = EmptyLensSignals(
            tokenCount: Self.toneHallucination.tokenCount,
            meanTokenProb: Self.toneHallucination.meanTokenProb,
            minTokenProb: Self.toneHallucination.minTokenProb,
            lowTokenProbFraction: Self.toneHallucination.lowTokenProbFraction,
            voicedFraction: 0.6)
        #expect(EmptyLensPolicy.verdict(voicedButUncertain) == .hasSpeech,
                "音频层说六成时间有人说话却因为概率低被判空镜 ⇒ 概率层越权")
    }

    // MARK: EL-4 三态

    @Test("EL-4 证据不足 ⇒ undetermined，且不得被读成空镜")
    func noEvidenceIsNotEmptyLens() {
        #expect(EmptyLensPolicy.verdict(.init()) == .undetermined,
                "什么证据都没有 ⇒ 必须报'判不了'，不许蒙一个档")
        // undetermined 绝不能触发拦截：宁可留一条错标，不可静默丢掉一条真口播
        #expect(!EmptyLensPolicy.shouldSuppressTagging(.undetermined))
    }

    @Test("EL-5 缺证据 ≠ 证据说没事：Optional 的三态必须保住")
    func missingIsNotZero() {
        // meanTokenProb = nil（引擎没给逐词概率）与 = 0.0（给了、且低到 0）是两回事。
        // 若把缺读成 0，下面的 undetermined 会变 hasSpeech —— 看着一样，实际是丢了一个信号。
        #expect(EmptyLensPolicy.verdict(.init()) == .undetermined)
        #expect(EmptyLensPolicy.verdict(.init(meanTokenProb: 0.0)) == .hasSpeech)
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: .nan)) == .undetermined,
                "NaN 被当成'占比很低'⇒ 判了空镜：非有限值必须一律不落档")
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: .infinity)) == .undetermined)
    }

    @Test("EL-6 概率层四颗值必须成组出现，不许半填")
    func probabilityGroupIsAllOrNothing() {
        // 唯一生产者是 probabilityLayer ⇒ 有值时四颗必须同时有，缺证据时必须四颗同时缺。
        // 半填会让 verdict 的"看到过证据"判断依赖具体哪一颗，而那不是设计。
        let full = EmptyLensSignals.probabilityLayer(from: [0.9, 0.2, 0.05])
        #expect(full.tokenCount != nil && full.meanTokenProb != nil
                && full.minTokenProb != nil && full.lowTokenProbFraction != nil,
                "只填出一部分 ⇒ 四颗值不再是同一份证据，判定会随哪颗先被读到而变")
        // 空输入必须给"全 nil"，而不是"count=0、其余 0"
        let empty = EmptyLensSignals.probabilityLayer(from: [])
        #expect(empty.tokenCount == nil, "空数组被填成了 count=0 ⇒ 下游会把'没概率数据'当'有 0 颗 token'")
        #expect(empty.meanTokenProb == nil && empty.minTokenProb == nil
                && empty.lowTokenProbFraction == nil)
        #expect(empty == EmptyLensSignals(), "空输入产出的不是全 nil 那条 ⇒ 与'没证据'的基准态不一致")
        // 全非有限 ⇒ 同样算没证据
        let junk = EmptyLensSignals.probabilityLayer(from: [.nan, .infinity, -.infinity])
        #expect(junk.tokenCount == nil, "非有限的概率被计入 ⇒ mean 变 NaN、判定方向乱")
        // 混入非有限值时，分母只许数有限的那几颗
        let mixed = EmptyLensSignals.probabilityLayer(from: [0.5, .nan, 0.7])
        #expect(mixed.tokenCount == 2, "非有限值占了一个分母 ⇒ mean 被稀释")
        #expect(abs((mixed.meanTokenProb ?? 0) - 0.6) < 1e-9)
        #expect(mixed.minTokenProb == 0.5, "NaN 参与了取最小 ⇒ Swift 的 min 会把 NaN 排在前头")
    }

    // MARK: EL-7 算术口径

    @Test("EL-7 probabilityLayer 复现包内二进制真跑出来的三组黄金值")
    func probabilityLayerMatchesMeasuredValues() {
        // 逐颗 p 逐字取自 .scratch/c-block-evidence/out_{tone,digital_silence,speech}.json，
        // 已按 cleanWhisperToken 口径剔除特殊标记（[_BEG_]/[_TT_*]）与纯空白 token。
        let tone = EmptyLensSignals.probabilityLayer(
            from: [0.0124856, 0.999153, 0.487335, 0.998039, 0.999474, 0.823502, 0.462627, 0.999488])
        #expect(tone.tokenCount == 8)
        #expect(abs((tone.meanTokenProb ?? 0) - 0.7227629500000001) < 1e-12,
                "mean 与手算/实测不符 ⇒ 分母口径变了（是否含被剔除的 token）")
        #expect(tone.minTokenProb == 0.0124856, "min 不是最不确定那颗 ⇒ 取错了聚合方向")
        #expect(tone.lowTokenProbFraction == 0.125, "占比不是 1/8 ⇒ 低置信计数口径变了")

        let speech = EmptyLensSignals.probabilityLayer(
            from: [0.995887, 0.99988, 0.999051, 0.999592, 0.999931, 0.903962, 0.956337, 0.999949,
                   0.999571, 0.999924, 0.999935, 0.984363, 0.933969, 0.99946, 0.979331, 0.999834,
                   0.976171, 0.936147, 0.999868, 0.999788, 0.999834, 0.999792, 0.952897])
        #expect(speech.tokenCount == 23)
        #expect(abs((speech.meanTokenProb ?? 0) - 0.9832814347826084) < 1e-12)
        #expect(speech.minTokenProb == 0.903962,
                "对照组真口播的 min 都不足 0.9 ⇒ 若幻觉样本低于它，两者的分离度已不存在")
        #expect(speech.lowTokenProbFraction == 0.0,
                "真口播对照组被判出了低置信 token ⇒ 阈值或计数口径漂了")

        let silence = EmptyLensSignals.probabilityLayer(
            from: [0.0162185, 0.999947, 0.999905, 0.999418, 0.999929, 0.999338, 0.999007, 0.999026,
                   0.999634, 0.999716, 0.998652, 0.999832, 0.999868])
        #expect(silence.tokenCount == 13)
        #expect(abs((silence.meanTokenProb ?? 0) - 0.9238838846153844) < 1e-12,
                "数字零静音幻觉的 mean 变了 ⇒ 上游 whisper 版本/模型换了，本文件的实测表要重取")
        #expect(silence.lowTokenProbFraction == 1.0 / 13.0, "低置信占比不是 1/13 ⇒ 计数口径变了")
    }

    @Test("EL-8 一条窗口压在多段上时按 token 数加权，不许'取第一条'或'取最可信那条'")
    func aggregateIsTokenWeightedNotPickOne() {
        let weak = EmptyLensSignals(tokenCount: 2, meanTokenProb: 0.1,
                                    minTokenProb: 0.01, lowTokenProbFraction: 0.5)
        let strong = EmptyLensSignals(tokenCount: 18, meanTokenProb: 0.99,
                                      minTokenProb: 0.9, lowTokenProbFraction: 0.0)
        let merged = EmptyLensPolicy.aggregateProbabilityLayer([weak, strong])
        #expect(merged.tokenCount == 20)
        // (0.1*2 + 0.99*18) / 20 = 0.901
        #expect(abs((merged.meanTokenProb ?? 0) - 0.901) < 1e-9,
                "mean 不是 token 数加权 ⇒ 大概取成了两段的算术平均(0.545)或第一条(0.1)")
        #expect(merged.minTokenProb == 0.01,
                "min 没取各段最小 ⇒ 窗口里最不确定那段悄悄消失了，定罪方向会偏松")
        // (0.5*2 + 0.0*18) / 20 = 0.05
        #expect(abs((merged.lowTokenProbFraction ?? 0) - 0.05) < 1e-9)

        // 负腿：加权结果必须与"取最可信那条"不同，否则本判据抓不到那条捷径
        #expect(abs((merged.meanTokenProb ?? 0) - 0.99) > 0.01)
        // 全缺概率 ⇒ 全 nil，不许出现 0
        #expect(EmptyLensPolicy.aggregateProbabilityLayer([EmptyLensSignals(), EmptyLensSignals()])
                == EmptyLensSignals())
        // count 为 0 的畸形输入不得进分母（会 NaN / 除零）
        #expect(EmptyLensPolicy.aggregateProbabilityLayer(
                    [EmptyLensSignals(tokenCount: 0, meanTokenProb: 0.5)]) == EmptyLensSignals())
    }

    // MARK: EL-9 音频层派生（区间 × 窗口）

    @Test("EL-9 有声占比由静音区间派生，重叠区间必须先合并否则占比能算出负数")
    func voicedFractionDerivation() {
        func vf(_ ws: Double, _ we: Double, _ iv: [(Double, Double)]) -> Double? {
            EmptyLensPolicy.voicedFraction(windowStart: ws, windowEnd: we, silentIntervals: iv)
        }
        // 窗口 [0,10]，静音 [0,4] ⇒ 有声 0.6
        #expect(abs((vf(0, 10, [(0, 4)]) ?? -1) - 0.6) < 1e-9)
        // 整窗静音 ⇒ 0（定罪）
        #expect(vf(0, 10, [(-3, 13)]) == 0.0, "区间越界没裁剪 ⇒ 占比算成负数")
        // 无任何静音 ⇒ 1
        #expect(vf(0, 10, []) == 1.0)
        // 重叠不合并会 Σ>窗口长度：[0,6]+[3,9] 实际并集 [0,9] ⇒ 有声 0.1
        #expect(abs((vf(0, 10, [(0, 6), (3, 9)]) ?? -1) - 0.1) < 1e-9,
                "重叠区间被直接相加 ⇒ 静音时长算成 15s、占比翻负、判定方向倒过来")
        // 乱序 / 倒序区间：倒序按 min/max 归一后**保留**（(5,4)→(4,5)，静音共 1+1+2=4s ⇒ 0.6）
        #expect(abs((vf(0, 10, [(7, 9), (0, 1), (5, 4)]) ?? -1) - 0.6) < 1e-9,
                "不是 0.6 ⇒ 倒序区间的口径变了（归一↔丢弃两种口径的读数差 0.1，必须显式表态）")
        // 非有限区间丢弃，不得污染占比
        #expect(abs((vf(0, 10, [(0, 4), (.nan, 9)]) ?? -1) - 0.6) < 1e-9,
                "NaN 区间被计入 ⇒ 合并逻辑没挡非有限值")
        // 窗口本身不合法 ⇒ nil（没证据），**不是** 0（＝判空镜）
        #expect(vf(10, 10, [(0, 5)]) == nil, "零长窗口被算出占比 ⇒ 会被当成'占比≤上界'误判空镜")
        #expect(vf(12, 10, []) == nil)
        #expect(vf(.nan, 10, []) == nil)
        // 越出窗口之外的静音不得计入
        #expect(vf(0, 10, [(20, 30)]) == 1.0, "窗口外的静音被算进来了")
    }

    // MARK: EL-10 闸

    @Test("EL-10 闸关着时一律不拦（当前状态，防「以为已经修好了」）")
    func gateIsClosedUntilBacktested() {
        #expect(!EmptyLensPolicy.gateOpen,
                "闸被开了 —— 开之前必须先在他的真分镜上只读回测并摊开每条原值（计划 §五 第 3 项）")
        #expect(!EmptyLensPolicy.shouldSuppressTagging(.emptyLens),
                "闸关着却能拦 ⇒ gateOpen 这颗开关是假的")
    }

    @Test("EL-11 已知漏口钉成可执行：整窗只有概率层时放行（自建分镜路径的真实形态）")
    func knownHoleStaysDocumented() {
        // 自建分镜路径不调 analyzeLocally ⇒ 拿不到 silencePeriods ⇒ 只有概率层 ⇒ 恒放行。
        // 这条不是"希望如此"，是范围事实；它变红意味着有人给那条路径接上了音频层探测，
        // 那时应连同 EmptyLensPolicy 文件头的"范围事实"一起改，而不是让这条悄悄绿过去。
        #expect(EmptyLensPolicy.verdict(Self.silenceHallucination) == .hasSpeech,
                "若这条变红，说明概率层又能单独定罪了 —— 那需要第三层（已知套话黑名单／字数÷时长比），而那一层用户本轮未选（计划 §五 第 3 项）")
    }
}
