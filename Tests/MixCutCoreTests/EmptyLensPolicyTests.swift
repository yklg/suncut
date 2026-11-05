import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// EL · 空镜判定（C 块 Core 判据）
//
// ## 2026-11-04 开闸那一轮改了什么
//
// `gateOpen` 由 false 翻成 true，定罪腿由一条变两条（能量 + 已知套话名单），
// `verdict` 多了一个**必填**入参 `text`（名单层没有它就没有输入，可选参数等于让新调用点
// 随手选一边）。本文件因此整体重编：EL-10 从"证明闸还关着"改成"证明闸开着且只开那一格"，
// EL-11 从"自建分镜恒不拦"改成"名单层补上了它的一半"，新增 EL-12…EL-18 钉名单层的
// 命中形状、误杀防线与已知漏口。
//
// 读数出处全在 `EmptyLensPolicy` 的注释里（108 条整库分布 + 22 条分层 277 段拦截表 +
// 用户对 4 条的人工确认），本文件的每条判据都吃那些**实测字符串**，不自己编样本。
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

    /// 他库内真实出现过的四条固定幻觉（出处见 EmptyLensPolicy 名单注释）
    private static let knownPhrases: [String] = [
        "优优独播剧场——YoYo Television Series Exclusive",
        "请不吝点赞 订阅 转发 打赏",
        "字幕由 Amara.org 社区提供",
        "字幕志愿者 杨茜茜",
    ]

    // MARK: EL-1／EL-3 能量层

    @Test("EL-1 能量层定罪：有声占比达上界 ⇒ 判空镜（上界已由回测定在 0.20）")
    func voicedFractionConvicts() {
        #expect(EmptyLensPolicy.voicedFractionCeil == 0.20,
                "上界被改回拍脑袋的值 —— 0.20 的出处是全库 108 条的双峰分布（0.15–0.70 一条没有），改数须重跑回测")
        let v = EmptyLensPolicy.voicedFractionCeil
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: v), text: "随便说点什么")
                == .emptyLens(.silentWindow), "恰等上界必须算（边界取 <=）")
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: v + 0.01), text: "随便说点什么")
                == .hasSpeech)
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: 0.0), text: "随便说点什么")
                == .emptyLens(.silentWindow))
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: 1.0), text: "随便说点什么") == .hasSpeech)
    }

    @Test("EL-2 概率层单独存在时**永不**判空镜（实测数字静音幻觉 mean=0.924，与真口播只差 0.06）")
    func probabilityLayerAloneNeverConvicts() {
        for s in [Self.toneHallucination, Self.silenceHallucination, Self.realSpeech] {
            // text 传空串：这条判的是"只有概率层时会不会自己定罪"，名单层必须不参与
            #expect(EmptyLensPolicy.verdict(s, text: "").isEmptyLens == false,
                    "概率层被升格成定罪层了 —— 这条一旦变红说明有人给 verdict 加了概率分支，而实测幻觉的 mean p 能高到 0.9238839，会误杀真口播")
        }
        let extreme = EmptyLensSignals(tokenCount: 40, meanTokenProb: 0.01,
                                       minTokenProb: 0.0, lowTokenProbFraction: 1.0)
        #expect(EmptyLensPolicy.verdict(extreme, text: "") == .hasSpeech,
                "全片最低置信度也不等于没人说话 —— 一个生僻词/英文品牌 token 就能把置信度打下来")
    }

    @Test("EL-3 两条腿同时命中时依据记能量层（silentWindow 比'文本像套话'更难反驳）")
    func bothLegsHitReportsEnergyFirst() {
        let both = EmptyLensSignals(voicedFraction: 0.0)
        #expect(EmptyLensPolicy.verdict(both, text: Self.knownPhrases[0]) == .emptyLens(.silentWindow),
                "依据记成了 knownPhrase ⇒ 翻案时看不到'这段连声音都没有'这条硬证据，顺序是设计不是随手写的")
    }

    // MARK: EL-4／EL-5 三态

    @Test("EL-4 证据不足 ⇒ undetermined，且不得被读成空镜")
    func noEvidenceIsNotEmptyLens() {
        #expect(EmptyLensPolicy.verdict(.init(), text: "随便说点什么") == .undetermined,
                "什么证据都没有 ⇒ 必须报'判不了'，不许蒙一个档")
        #expect(!EmptyLensPolicy.shouldSuppressTagging(.undetermined))
    }

    @Test("EL-5 缺证据 ≠ 证据说没事：Optional 的三态必须保住")
    func missingIsNotZero() {
        #expect(EmptyLensPolicy.verdict(.init(meanTokenProb: 0.0), text: "随便说点什么") == .hasSpeech)
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: .nan), text: "随便说点什么") == .undetermined,
                "NaN 被当成'占比很低'⇒ 判了空镜：非有限值必须一律不落档")
        #expect(EmptyLensPolicy.verdict(.init(voicedFraction: .infinity), text: "随便说点什么") == .undetermined)
    }

    // MARK: EL-6／EL-7／EL-8 算术口径

    @Test("EL-6 概率层四颗值必须成组出现，不许半填")
    func probabilityGroupIsAllOrNothing() {
        let full = EmptyLensSignals.probabilityLayer(from: [0.9, 0.2, 0.05])
        #expect(full.tokenCount != nil && full.meanTokenProb != nil
                && full.minTokenProb != nil && full.lowTokenProbFraction != nil,
                "只填出一部分 ⇒ 四颗值不再是同一份证据，判定会随哪颗先被读到而变")
        let empty = EmptyLensSignals.probabilityLayer(from: [])
        #expect(empty.tokenCount == nil, "空数组被填成了 count=0 ⇒ 下游会把'没概率数据'当'有 0 颗 token'")
        #expect(empty == EmptyLensSignals(), "空输入产出的不是全 nil 那条 ⇒ 与'没证据'的基准态不一致")
        let junk = EmptyLensSignals.probabilityLayer(from: [.nan, .infinity, -.infinity])
        #expect(junk.tokenCount == nil, "非有限的概率被计入 ⇒ mean 变 NaN、判定方向乱")
        let mixed = EmptyLensSignals.probabilityLayer(from: [0.5, .nan, 0.7])
        #expect(mixed.tokenCount == 2, "非有限值占了一个分母 ⇒ mean 被稀释")
        #expect(abs((mixed.meanTokenProb ?? 0) - 0.6) < 1e-9)
        #expect(mixed.minTokenProb == 0.5, "NaN 参与了取最小 ⇒ Swift 的 min 会把 NaN 排在前头")
    }

    @Test("EL-7 probabilityLayer 复现包内二进制真跑出来的三组黄金值")
    func probabilityLayerMatchesMeasuredValues() {
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
        #expect(speech.minTokenProb == 0.903962)
        #expect(speech.lowTokenProbFraction == 0.0, "真口播对照组被判出了低置信 token ⇒ 阈值或计数口径漂了")

        let silence = EmptyLensSignals.probabilityLayer(
            from: [0.0162185, 0.999947, 0.999905, 0.999418, 0.999929, 0.999338, 0.999007, 0.999026,
                   0.999634, 0.999716, 0.998652, 0.999832, 0.999868])
        #expect(silence.tokenCount == 13)
        #expect(abs((silence.meanTokenProb ?? 0) - 0.9238838846153844) < 1e-12,
                "数字零静音幻觉的 mean 变了 ⇒ 上游 whisper 版本/模型换了，本文件的实测表要重取")
        #expect(silence.lowTokenProbFraction == 1.0 / 13.0)
    }

    @Test("EL-8 一条窗口压在多段上时按 token 数加权，不许'取第一条'或'取最可信那条'")
    func aggregateIsTokenWeightedNotPickOne() {
        let weak = EmptyLensSignals(tokenCount: 2, meanTokenProb: 0.1,
                                    minTokenProb: 0.01, lowTokenProbFraction: 0.5)
        let strong = EmptyLensSignals(tokenCount: 18, meanTokenProb: 0.99,
                                      minTokenProb: 0.9, lowTokenProbFraction: 0.0)
        let merged = EmptyLensPolicy.aggregateProbabilityLayer([weak, strong])
        #expect(merged.tokenCount == 20)
        #expect(abs((merged.meanTokenProb ?? 0) - 0.901) < 1e-9,
                "mean 不是 token 数加权 ⇒ 大概取成了两段的算术平均(0.545)或第一条(0.1)")
        #expect(merged.minTokenProb == 0.01, "min 没取各段最小 ⇒ 窗口里最不确定那段悄悄消失了")
        #expect(abs((merged.lowTokenProbFraction ?? 0) - 0.05) < 1e-9)
        #expect(abs((merged.meanTokenProb ?? 0) - 0.99) > 0.01, "加权结果与'取最可信那条'一样 ⇒ 本判据抓不到那条捷径")
        #expect(EmptyLensPolicy.aggregateProbabilityLayer([EmptyLensSignals(), EmptyLensSignals()])
                == EmptyLensSignals())
        #expect(EmptyLensPolicy.aggregateProbabilityLayer(
                    [EmptyLensSignals(tokenCount: 0, meanTokenProb: 0.5)]) == EmptyLensSignals())
    }

    @Test("EL-9 有声占比由静音区间派生，重叠区间必须先合并否则占比能算出负数")
    func voicedFractionDerivation() {
        func vf(_ ws: Double, _ we: Double, _ iv: [(Double, Double)]) -> Double? {
            EmptyLensPolicy.voicedFraction(windowStart: ws, windowEnd: we, silentIntervals: iv)
        }
        #expect(abs((vf(0, 10, [(0, 4)]) ?? -1) - 0.6) < 1e-9)
        #expect(vf(0, 10, [(-3, 13)]) == 0.0, "区间越界没裁剪 ⇒ 占比算成负数")
        #expect(vf(0, 10, []) == 1.0)
        #expect(abs((vf(0, 10, [(0, 6), (3, 9)]) ?? -1) - 0.1) < 1e-9,
                "重叠区间被直接相加 ⇒ 静音时长算成 15s、占比翻负、判定方向倒过来")
        #expect(abs((vf(0, 10, [(7, 9), (0, 1), (5, 4)]) ?? -1) - 0.6) < 1e-9,
                "不是 0.6 ⇒ 倒序区间的口径变了（归一↔丢弃两种口径的读数差 0.1，必须显式表态）")
        #expect(abs((vf(0, 10, [(0, 4), (.nan, 9)]) ?? -1) - 0.6) < 1e-9, "NaN 区间被计入 ⇒ 合并逻辑没挡非有限值")
        #expect(vf(10, 10, [(0, 5)]) == nil, "零长窗口被算出占比 ⇒ 会被当成'占比≤上界'误判空镜")
        #expect(vf(12, 10, []) == nil)
        #expect(vf(.nan, 10, []) == nil)
        #expect(vf(0, 10, [(20, 30)]) == 1.0, "窗口外的静音被算进来了")
    }

    // MARK: EL-10／EL-11 闸的状态与范围

    @Test("EL-10 闸已开，且只开'拦打标'这一格")
    func gateIsOpenAndScoped() {
        #expect(EmptyLensPolicy.gateOpen,
                "闸被关回去了 —— 2026-11-04 的回测已经做完（108 条分布 + 22 条拦截表 + 4 条人工确认），关闸等于把已定的判据退回'只记录'，②空镜误打标会原样复发")
        // 开的那一格：判成空镜 ⇒ 不写语义标签
        #expect(EmptyLensPolicy.shouldSuppressTagging(.emptyLens(.silentWindow)))
        #expect(EmptyLensPolicy.shouldSuppressTagging(.emptyLens(.knownPhrase("x"))))
        // 没开的两格：hasSpeech 与 undetermined 一律放行（保守：宁可留错标，不可丢真口播）
        #expect(!EmptyLensPolicy.shouldSuppressTagging(.hasSpeech))
        #expect(!EmptyLensPolicy.shouldSuppressTagging(.undetermined))
        // ⚠️ 这颗开关**不管**逐段重听 —— 重听的终态档是另一个入参（M1，2026-11-05 落地）。
        //    两向都钉住，谁也不许顺手改谁：没判空镜的空段照旧要听，判了空镜才免听。
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false),
                "空镜闸顺手把逐段重听也改了 ⇒ 打标与重听混进一颗开关，将来摘标时会漏掉另一半")
        #expect(!SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: true),
                "终态档失效：被判空镜的段每次重跑都再听一遍、再幻觉一次")
    }

    @Test("EL-11 自建分镜路径（拿不到静音区间）被名单层补了一半")
    func selfSegmentPathIsNotFullyBlind() {
        // 那条路径不调 analyzeLocally ⇒ 能量层没有输入。但它有文本 ⇒ 名单层能定罪。
        let noSilenceData = Self.silenceHallucination
        #expect(EmptyLensPolicy.verdict(noSilenceData, text: Self.knownPhrases[0])
                == .emptyLens(.knownPhrase(Self.knownPhrases[0])),
                "名单层在自建分镜路径上失效 ⇒ 那条路径的误打标会整批复发，而它是最容易撞的（用户自己上传的素材）")
        // 未命中名单的仍不拦 —— 这是范围事实，别读成"已解决"
        #expect(EmptyLensPolicy.verdict(noSilenceData, text: "这颗橙子特别甜") == .hasSpeech)
        #expect(EmptyLensPolicy.verdict(EmptyLensSignals(tokenCount: 4, meanTokenProb: 0.9,
                                                        minTokenProb: 0.8, lowTokenProbFraction: 0.0),
                                       text: "嗯") == .hasSpeech)
        #expect(EmptyLensPolicy.verdict(EmptyLensSignals(), text: "嗯") == .undetermined,
                "什么证据都没有却判出别的档 ⇒ 三态被人动了")
    }

    // MARK: EL-12…EL-15 名单层

    @Test("EL-12 四条实测套话必须逐条命中，且依据里带上原文")
    func knownPhrasesHitWithEvidence() {
        for phrase in Self.knownPhrases {
            let v = EmptyLensPolicy.verdict(.init(voicedFraction: 1.0), text: phrase)
            #expect(v == .emptyLens(.knownPhrase(phrase)),
                    "名单里这条不命中了 ⇒ 归一化口径或匹配方向变了；出处：他库内 过渡/14、过渡/11、辅助卖点/17、过渡/4.0 与两枚探针")
        }
        // 名单本身也要能被审计：四条都要有，少一条就是有人删了没记账
        #expect(Set(EmptyLensPolicy.knownHallucinationPhrases) == Set(Self.knownPhrases),
                "名单内容与回测出处不一致 ⇒ 加条要带出处，删条要同轮改这条判据")
    }

    @Test("EL-13 误杀防线：真口播里出现套话**不得**命中（只许前缀，不许子串）")
    func blacklistIsPrefixNotSubstring() {
        let realNarration = [
            "大家先点个赞，我马上开始介绍",
            "这颗橙子你尝过就知道，点赞的人都回购了",
            "转发给你妈，她肯定爱喝",
            // 最要紧的一条：直播话术里真的会整句念出这套话，只是在句子中间。
            // 前缀匹配放过它，子串匹配会把它当幻觉拦掉 —— 这把刀实测过（K1），
            // 少了这条样本，"前缀退化成子串"没人看得见。
            "欢迎来到直播间，请不吝点赞 订阅 转发 打赏，我们马上开始",
        ]
        for line in realNarration {
            #expect(EmptyLensPolicy.knownHallucinationHit(line) == nil,
                    "真口播被名单误杀了 ⇒ 匹配从'前缀'退化成'子串'了：带货话术里满是点赞/转发/关注")
        }
        // 正向对照：同一句话只要**以**套话开头就该命中，证明上面那些 nil 是方向对的、不是匹配坏了
        #expect(EmptyLensPolicy.knownHallucinationHit("请不吝点赞 订阅 转发 打赏，谢谢观看") != nil,
                "以套话开头的整段也不命中 ⇒ 匹配根本没生效，上面那些 nil 全是假绿")
    }

    @Test("EL-14 归一化与锚比对共用同一处实现，标点/空格/全半角都不影响命中")
    func normalizationIsShared() {
        let spaced = "请不吝点赞  订阅 转发,打赏！"
        #expect(EmptyLensPolicy.knownHallucinationHit(spaced) != nil,
                "标点或空格一变就漏 ⇒ 名单层自己写了一份归一化，没复用 contentStream 这一处真源")
        let dash = "优优独播剧场-YoYoTelevisionSeriesExclusive"
        #expect(EmptyLensPolicy.knownHallucinationHit(dash) != nil, "破折号形态不同就漏，同上")
        // 归一化口径必须与锚比对同源：两处答案不一致时，同一条文本会一处判命中一处判不命中
        #expect(SegmentRetakeRule.contentStream(spaced)
                == SegmentRetakeRule.contentStream("请不吝点赞订阅转发打赏"),
                "contentStream 的过滤面变了 ⇒ 名单命中与锚零交集两条判据会各自漂移")
    }

    @Test("EL-15 名单条目要有长度下限：卫生检查＋下限真有牙齿")
    func shortPhrasesCannotSwallowRealSpeech() {
        // ①现名单卫生：每条归一化后都要 ≥8 颗，短条目根本没资格当锚
        #expect(EmptyLensPolicy.shortlistedPhraseViolations.isEmpty,
                "名单里混进了没资格当锚的短条目 ⇒ 前缀匹配会吞掉大量真口播")
        // ②下限这道逻辑单独验：同一颗短锚，8 颗下限时不许命中，把下限降到 1 必须命中。
        //   只测①的话，把代码里的 8 改成 1 没人会红（K2 实测存活过）—— 第二条才是刀。
        let blocked = EmptyLensPolicy.knownHallucinationHit("嗯嗯今天真好吃", phrases: ["嗯"], minAnchorCount: 8)
        let allowed = EmptyLensPolicy.knownHallucinationHit("嗯嗯今天真好吃", phrases: ["嗯"], minAnchorCount: 1)
        #expect(blocked == nil, "短锚在 8 颗下限下仍然命中 ⇒ 下限没生效，「嗯」这类高频字会拦掉海量真口播")
        #expect(allowed == "嗯", "把下限降到 1 都不命中 ⇒ 注入缝是死的，上面那条 nil 只是匹配本身坏了")
        // ③生产默认值本身也要钉住：②传的是显式参数，改默认值它抓不到
        #expect(EmptyLensPolicy.minPhraseAnchorCount == 8,
                "锚下限被改了 ⇒ ①②两条都是拿显式参数测的，默认值漂了没人看见；改数要连判据一起改")
    }

    @Test("EL-17 BGM 空镜全靠名单层：能量层说'一直在响'时不得提前收口")
    func blacklistGetsItsTurnAfterEnergySaysSpeech() {
        // 他库里 100/108 条整片占比 ≥0.90 —— 带配乐的空镜在能量层上是隐身的。
        // 若把顺序写成"能量层有值就立刻返回"，名单层对这些素材永远没有机会，②会原地复发。
        let bgmOnly = EmptyLensSignals(tokenCount: 27, meanTokenProb: 0.87, minTokenProb: 0.33,
                                       lowTokenProbFraction: 0.0, voicedFraction: 1.0)
        #expect(EmptyLensPolicy.verdict(bgmOnly, text: "请不吝点赞 订阅 转发 打赏")
                == .emptyLens(.knownPhrase("请不吝点赞 订阅 转发 打赏")),
                "能量层给了 hasSpeech 就直接返回 ⇒ 名单层被短路，占多数的 BGM 空镜一条也拦不住")
    }

    @Test("EL-18 已知漏口钉住：纯音乐被转写成非套话内容时**不判空镜**，别当已解决")
    func knownHoleStaysDocumented() {
        // 出处：李巍/辅助卖点/19.mp4 —— 用户确认没人说话，whisper 把乐器声认成「Zither Harp」，
        // 整片占比 1.000。能量层看不见，名单也没有这一条（加了就是过拟合到单条素材）。
        let instrumental = EmptyLensSignals(tokenCount: 4, meanTokenProb: 0.744, minTokenProb: 0.5,
                                            lowTokenProbFraction: 0.0, voicedFraction: 1.0)
        #expect(EmptyLensPolicy.verdict(instrumental, text: "Zither Harp") == .hasSpeech,
                "若这条变红，说明已经接上了人声/伴奏分离或语义层 —— 那要连文件头'拦不住什么'一起改，不许让这条悄悄绿过去")
        #expect(EmptyLensPolicy.verdict(instrumental, text: "你的眼中只有我") == .hasSpeech,
                "带歌词的音乐同理：那是真声音内容，只是不是商品口播")
    }

    // MARK: EL-16 概率层的取样点仍在

    @Test("EL-16 判定不吃概率层，但概率层字段仍完整算出（开闸后它只剩留痕一个用途）")
    func probabilityStillComputedForAudit() {
        let s = EmptyLensSignals.probabilityLayer(from: [0.5, 0.9, 0.1])
        #expect(s.tokenCount == 3 && s.minTokenProb == 0.1 && s.meanTokenProb == (0.5 + 0.9 + 0.1) / 3)
        // 定罪不看它：把 mean 推到极端也不改变结论（EL-2 是规则侧，这条是数据侧）
        #expect(EmptyLensPolicy.verdict(s, text: "正常的一句话").isEmptyLens == false)
    }
}
