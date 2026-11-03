import Foundation
import Testing

@testable import SunCut

// ============================================================================
// WD · whisper.cpp JSON 里那颗空镜证据的解码（C 块证据层）
//
// ## 〔已证伪〕本文件 2026-10-26 整体重写
//
// 旧版喂的是我自己写的 JSON —— 键名 `no_speech_prob` / `avg_logprob` /
// `compression_ratio_prob` 是**照着"whisper 应该有这些"编的**（它们属于 Python
// openai-whisper 的形态，whisper.cpp 根本不吐）。那就成了"拿我编的输入测我编的解析器"：
// 阳性腿恒真、零取证力，却报着绿。
//
// 现在所有夹具**逐字取自包内二进制的真实输出**（真跑取证，三份样本键名册一致）：
//   MixCut/Resources/bin/whisper -m MixCut/Resources/bin/ggml-large-v3.bin -f X.wav \
//     -l zh --output-json-full -of out            # 与 ASRService.runWhisperCppProcess 同一串参数
//   产物留在 .scratch/c-block-evidence/out_{tone,digital_silence,speech}.json
//   实测键名册：段级 = ['offsets','text','timestamps','tokens']
//               token 级 = ['id','offsets','p','t_dtw','text','timestamps']
//
// ## 为什么两腿都要
//
// 只验"有键读得到"会漏掉真正的风险：**旧库/旧 JSON 没有这颗键**。
// 本仓实测过 —— 给已落盘的 Decodable 结构加**非 Optional** 字段，即使带默认值也会 keyNotFound。
//   · 负腿（缺键不炸）防"改坏类型 ⇒ 老数据全解不出"；
//   · 阳性腿（有键读得到）防"字段名拼错 ⇒ 永远 nil、负腿照样绿"。
// 少一条就是恒真。两条合起来才把 Optional 这个约束钉住。
// ============================================================================

@Suite("WD · whisper 空镜证据解码")
struct WhisperEvidenceDecodeTests {

    /// **逐字**取自 out_tone.json 的 `transcription` 数组（2s 纯正弦 → 幻觉「字幕志愿者 杨茜茜」）。
    /// 没重排、没剪键 —— `offsets`/`id`/`t_dtw` 是本仓解码结构**没声明**的键，
    /// 留着它们让这份夹具顺带证掉"上游多给键不会炸解码"。
    private static let realToneJSON = """
    {"transcription":[{"timestamps":{"from":"00:00:00,000","to":"00:00:02,000"},"offsets":{"from":0,"to":2000},"text":"字幕志愿者 杨茜茜","tokens":[{"text":"[_BEG_]","timestamps":{"from":"00:00:00,000","to":"00:00:00,000"},"offsets":{"from":0,"to":0},"id":50365,"p":0.887278,"t_dtw":-1},{"text":"字","timestamps":{"from":"00:00:00,000","to":"00:00:00,280"},"offsets":{"from":0,"to":280},"id":22381,"p":0.0124856,"t_dtw":-1},{"text":"幕","timestamps":{"from":"00:00:00,280","to":"00:00:00,560"},"offsets":{"from":280,"to":560},"id":40211,"p":0.999153,"t_dtw":-1},{"text":"志","timestamps":{"from":"00:00:00,560","to":"00:00:00,840"},"offsets":{"from":560,"to":840},"id":44700,"p":0.487335,"t_dtw":-1},{"text":"愿","timestamps":{"from":"00:00:00,840","to":"00:00:01,690"},"offsets":{"from":840,"to":1690},"id":4820,"p":0.998039,"t_dtw":-1},{"text":"者","timestamps":{"from":"00:00:01,690","to":"00:00:01,990"},"offsets":{"from":1990,"to":1990},"id":12444,"p":0.999474,"t_dtw":-1},{"text":" ","timestamps":{"from":"00:00:01,990","to":"00:00:01,990"},"offsets":{"from":1990,"to":1990},"id":220,"p":0.946752,"t_dtw":-1},{"text":"杨","timestamps":{"from":"00:00:01,990","to":"00:00:01,990"},"offsets":{"from":1990,"to":1990},"id":4422,"p":0.823502,"t_dtw":-1},{"text":"茜","timestamps":{"from":"00:00:01,990","to":"00:00:01,990"},"offsets":{"from":1990,"to":1990},"id":27395,"p":0.462627,"t_dtw":-1},{"text":"茜","timestamps":{"from":"00:00:01,990","to":"00:00:01,990"},"offsets":{"from":1990,"to":1990},"id":27395,"p":0.999488,"t_dtw":-1},{"text":"[_TT_100]","timestamps":{"from":"00:00:02,000","to":"00:00:02,000"},"offsets":{"from":2000,"to":2000},"id":50465,"p":0.48315,"t_dtw":-1}]}]}
    """

    /// 对照组：out_speech.json（6.4s 真口播，转写正确）。
    /// ⚠️ 这份**剪过**：每颗 token 只留解码器声明的 `text`+`p` 两颗键。
    /// "多键不炸"由上面那份逐字全文覆盖，这里只负责真口播的黄金值。
    private static let realSpeechJSON = """
    {"transcription":[{"text":"今天天气不错,这件衣服的版型非常显瘦,大家可以看到细节。","timestamps":{"from":"00:00:00,000","to":"00:00:06,360"},"tokens":[{"text":"[_BEG_]","p":0.97627},{"text":"今天","p":0.995887},{"text":"天","p":0.99988},{"text":"气","p":0.999051},{"text":"不","p":0.999592},{"text":"错","p":0.999931},{"text":",","p":0.903962},{"text":"这","p":0.956337},{"text":"件","p":0.999949},{"text":"衣","p":0.999571},{"text":"服","p":0.999924},{"text":"的","p":0.999935},{"text":"版","p":0.984363},{"text":"型","p":0.933969},{"text":"非常","p":0.99946},{"text":"显","p":0.979331},{"text":"瘦","p":0.999834},{"text":",","p":0.976171},{"text":"大家","p":0.936147},{"text":"可以","p":0.999868},{"text":"看到","p":0.999788},{"text":"细","p":0.999834},{"text":"节","p":0.999792},{"text":"。","p":0.952897},{"text":"[_TT_318]","p":0.458792}]}]}
    """

    /// 负腿夹具：把真 JSON 里所有 `"p":数值` 剪掉，模拟"引擎没给逐 token 概率"。
    /// 用**派生自真实夹具**的方式造，而不是另写一份假 JSON —— 保证只有这一处差异。
    private static func withoutProbabilityKeys(_ json: String) -> String {
        // 逐 token 概率键与其后的逗号一起删，不留 `"p":,` 这种非法残留
        // 真输出里 p 恒在 t_dtw 之前，所以每条都带尾逗号，正则一起吃掉不会留悬空逗号；
        // 万一形态变了，下面的 toks.count 与解码本身会当场炸出来，不会静默空跑。
        json.replacingOccurrences(of: "\"p\":-?[0-9]+(\\.[0-9]+)?([eE]-?[0-9]+)?,?",
                                 with: "", options: .regularExpression)
    }

    private static func decode(_ json: String) throws -> WhisperCppOutput {
        try JSONDecoder().decode(WhisperCppOutput.self, from: Data(json.utf8))
    }

    // MARK: 阳性腿

    @Test("WD-1 包内二进制的真 JSON 必须解得动，且既有字段不丢")
    func realPayloadDecodes() throws {
        let out = try Self.decode(Self.realToneJSON)
        let seg = try #require(out.transcription.first)
        #expect(out.transcription.count == 1)
        #expect(seg.text == "字幕志愿者 杨茜茜", "文本变了 ⇒ 上游键名册或解码结构漂了")
        #expect(seg.timestamps?.to == "00:00:02,000", "时间戳没读到 ⇒ 下游所有窗口派生会拿到 0")
        #expect(seg.tokens?.count == 11, "真 JSON 是 11 颗 token（含 [_BEG_] 与 [_TT_100]）")
        // 解码结构没声明 offsets / id / t_dtw —— 上游多给键不许炸
    }

    @Test("WD-2 逐 token 概率必须真读得到（防键名拼错后永远 nil、负腿照样绿）")
    func tokenProbabilityIsRead() throws {
        let seg = try #require(Self.decode(Self.realToneJSON).transcription.first)
        let toks = try #require(seg.tokens)
        #expect(toks[0].p == 0.887278, "[_BEG_] 的 p 没读到 ⇒ 键名或类型不对")
        #expect(toks[1].p == 0.0124856, "幻觉首字「字」的 p 没读到 —— 这颗正是整条证据的关键")
        #expect(toks.last?.p == 0.48315)
        // 既有字段不能因为加了新字段而丢
        #expect(toks[1].text == "字")
        #expect(toks[1].timestamps?.to == "00:00:00,280")
    }

    // MARK: 负腿

    @Test("WD-3 缺 p 键的 JSON 必须照样解得出，且读成 nil 而非崩")
    func payloadWithoutProbabilityKeys() throws {
        let stripped = Self.withoutProbabilityKeys(Self.realToneJSON)
        // 夹具自证：确实没有概率键了，否则这条负腿是空跑的
        #expect(!stripped.contains("\"p\":"), "剪键没生效 ⇒ 负腿其实在测阳性输入")
        let seg = try #require(Self.decode(stripped).transcription.first)
        let toks = try #require(seg.tokens)
        #expect(toks.count == 11, "剪键把 JSON 剪坏了 ⇒ token 数对不上")
        #expect(toks.allSatisfy { $0.p == nil }, "缺键却读出了值 ⇒ p 不是 Optional")
        #expect(seg.text == "字幕志愿者 杨茜茜", "缺证据不影响既有识别链路：文本要照旧")
        // 缺证据 ⇒ 概率层全 nil，**不是** 0
        let signals = ASRService.probabilityLayer(fromCppTokens: toks)
        #expect(signals == EmptyLensSignals(), "缺 p 键被填成了 0 ⇒ '引擎没说'被伪装成'引擎说很确信'")
    }

    // MARK: 接线（剔除口径 + 算术）

    @Test("WD-4 真 JSON 走完「剔除特殊 token → 算概率层」必须复现手算黄金值")
    func wiringReproducesGoldenValues() throws {
        let seg = try #require(Self.decode(Self.realToneJSON).transcription.first)
        let s = ASRService.probabilityLayer(fromCppTokens: seg.tokens)
        // 11 颗里要剔掉 [_BEG_]、[_TT_100] 和那颗纯空白 " " ⇒ 8 颗
        #expect(s.tokenCount == 8,
                "颗数不是 8 ⇒ 剔除口径漂了（少剔一颗特殊标记或把纯空白当成有效 token）")
        #expect(abs((s.meanTokenProb ?? 0) - 0.7227629500000001) < 1e-12)
        #expect(s.minTokenProb == 0.0124856)
        #expect(s.lowTokenProbFraction == 0.125)
    }

    @Test("WD-5 对照组（真口播）走同一条接线，黄金值必须与两条幻觉分得开")
    func controlGroupRealSpeech() throws {
        let seg = try #require(Self.decode(Self.realSpeechJSON).transcription.first)
        let s = ASRService.probabilityLayer(fromCppTokens: seg.tokens)
        #expect(s.tokenCount == 23, "25 颗剔掉 [_BEG_]/[_TT_318] 应为 23（标点 , 和 。 要留下）")
        #expect(abs((s.meanTokenProb ?? 0) - 0.9832814347826084) < 1e-12)
        #expect(s.minTokenProb == 0.903962)
        #expect(s.lowTokenProbFraction == 0.0,
                "真口播被判出低置信 token ⇒ 阈值漂了，概率层连对照组分不开")

        // 分离度断言：这条是"概率层为什么只能留痕、不能定罪"的可执行版本
        let toneSeg = try #require(Self.decode(Self.realToneJSON).transcription.first)
        let tone = ASRService.probabilityLayer(fromCppTokens: toneSeg.tokens)
        #expect((tone.meanTokenProb ?? 0) < (s.meanTokenProb ?? 0),
                "幻觉的 mean 反超真口播 ⇒ 上游行为变了，实测表与阈值都要重取")
        #expect((s.minTokenProb ?? 0) > EmptyLensPolicy.lowTokenProbCeil)
    }

    @Test("WD-6 接出来的证据喂进判定器：概率层单独存在时一律不定罪，配上音频层才定")
    func evidenceFeedsThePolicy() throws {
        let toneSeg = try #require(Self.decode(Self.realToneJSON).transcription.first)
        let toneSignals = ASRService.probabilityLayer(fromCppTokens: toneSeg.tokens)
        // 旧版这条期望 `.emptyLens` —— 那是拿编造的 0.93 no_speech_prob 喂出来的假结论。
        // 现在实测的真证据只允许给 hasSpeech：概率层单独不能定罪（EL-2 从规则侧钉，这条从真实数据侧钉）。
        #expect(EmptyLensPolicy.verdict(toneSignals) == .hasSpeech,
                "真·幻觉样本的概率层竟能定罪 ⇒ verdict 里被加了概率分支")
        // 同一条证据 + 导入期派生出的有声占比 ⇒ 才判得出空镜
        var withAudio = toneSignals
        withAudio.voicedFraction = 0.0
        #expect(EmptyLensPolicy.verdict(withAudio) == .emptyLens,
                "音频层给到 0 占比还不判空镜 ⇒ C 块的定罪腿断了")
        // 但闸还关着：本轮只记录证据，不改变行为
        #expect(!EmptyLensPolicy.shouldSuppressTagging(.emptyLens))
    }

    // MARK: 另一条引擎分支（族，不是副本）

    @Test("WD-7 python-whisper 分支的逐词概率汇到同一处算术口径")
    func pythonBranchSharesTheMetric() throws {
        // 形态不同（segments[].words[].probability）、语义同族 ⇒ 不许各写一套均值。
        // 夹具取自本文件头注释里 parsePythonWhisperOutput 的样例形状（python 侧非本机主分支，
        // 由 detectWhisperType 现场裁定；这里证的是"接线通、口径同"，不是上游真值）。
        let json = """
        {"text":"错过就涨回六十九块九","language":"zh","segments":[
        {"start":0.0,"end":4.0,"text":"错过就涨回六十九块九","words":[
        {"word":"错","start":0.1,"end":0.4,"probability":0.15},
        {"word":"过","start":0.4,"end":0.7,"probability":0.9},
        {"word":" ","start":0.7,"end":0.75,"probability":0.99},
        {"word":"[_BEG_]","start":0.75,"end":0.8,"probability":0.99}]}]}
        """
        let out = try JSONDecoder().decode(PythonWhisperOutput.self, from: Data(json.utf8))
        let seg = try #require(out.segments.first)
        let s = ASRService.probabilityLayer(fromPythonWords: seg.words)
        // 4 颗里剔掉纯空白与 [_BEG_] ⇒ 2 颗；(0.15+0.9)/2 = 0.525
        #expect(s.tokenCount == 2, "剔除口径没和 cpp 分支共用 ⇒ 同一族两种算法")
        #expect(s.meanTokenProb == 0.525)
        #expect(s.minTokenProb == 0.15)
        #expect(s.lowTokenProbFraction == 0.5,
                "0.15 低于下界 0.2、0.9 不低于 ⇒ 占比应是 1/2；不是就说明比较方向或阈值漂了")
        #expect(s == EmptyLensSignals.probabilityLayer(from: [0.15, 0.9]),
                "两个分支的结果与统一口径不一致 ⇒ 分支里混进了自己的算术")
    }

    @Test("WD-8 持久化往返：证据要能随 ASRSentence 落进 asrSentencesData 再读回来")
    func evidenceSurvivesPersistence() throws {
        let seg = try #require(Self.decode(Self.realToneJSON).transcription.first)
        let sentence = ASRSentence(text: "字幕志愿者 杨茜茜", start: 0, end: 2,
                                  emptyLensSignals: ASRService.probabilityLayer(fromCppTokens: seg.tokens))
        let data = try JSONEncoder().encode(sentence)
        let back = try JSONDecoder().decode(ASRSentence.self, from: data)
        #expect(back.emptyLensSignals?.tokenCount == 8,
                "落库再读回来证据就没了 ⇒ '这段为什么没打标'无法追溯，翻案入口是空的")
        #expect(back.emptyLensSignals == sentence.emptyLensSignals)

        // 负腿：旧库里的 asrSentencesData 没有这颗键 ⇒ 必须解得动、读成 nil（不是崩、不是 0）
        let legacy = try JSONDecoder().decode(ASRSentence.self,
                                            from: Data("{\"text\":\"老数据\",\"start\":1.0,\"end\":2.5}".utf8))
        #expect(legacy.text == "老数据")
        #expect(legacy.emptyLensSignals == nil, "旧 JSON 缺键被读成空 signals ⇒ 缺证据与有证据混档")
    }
}
