import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// 语速固定与空镜识别 —— 两条**今天就能编译**的缺陷钉（计划 §6.1 T13 / T19）
//
// 为什么放一个文件：这两条不是新功能的验收判据，而是**现存缺陷的证据**，
// 用的全是既有符号，所以能在 A/C 块动笔之前就跑红 —— 它们同时充当
// 「修复前失败输出」那一条闭环证据（SKILL Step 4 ⑦）。
//
// 口径照本仓 `TombstoneReadGuardTests` 的 G08b/G15b：**strict-xfail**。
// 生产码修好之后，`withKnownIssue` 会因为「不再有问题」而**自己变红** ⇒ 逼一次摘标，
// 不许留下一条默默变绿的死判据。
//
// 摘标之后各条的自然归属：T13 → `SegmentTranscribeRuleTests`（该文件当前有未提交改动，
// 故先集中在此，不并进去搅动别人的工作现场）；T19 → `SentenceTimingAlignerTests`。
//
// ## 为什么 T10（偏短不得被误拒）不在这个文件里
//
// 它要钉的是"两态超字闸"的放行面，而那颗闸还不存在 —— 对一个不存在的接口写断言，
// 只能写成恒真或写成对 `SpeechDuration.atempoFactor` 现有语义的否定（那是它自己的契约，
// 不是缺陷）。⇒ 等闸落地后随 T7 一起写。
// ============================================================================

// MARK: - T13 · 空镜不得被计成"识别失败"而停掉整批

@Suite("RP · 空镜不是识别失败（T13）")
struct EmptyLensNotAFailureTests {

    /// 一条视频里连续三段都是**空镜**（B-roll，本来就没人说话）⇒ 引擎"成功但没认出字"，
    /// 分类落到 `.emptyAudio`。
    ///
    /// 现存缺陷：`SegmentBatchPolicy.tally` 把 `.emptyAudio` 计进 `failed`，
    /// 而 `consecutiveFailureLimit == 3` ⇒ **连续三段 B-roll 就会把整批逐段重听提前停掉**，
    /// 后面真有口播的段再也拿不到字。用户反馈的"空镜被误打标"是同一条链的上半段，
    /// 这是它的下半段。
    ///
    /// 期望（本钉现在必红）：空镜是**正确答案**，不是失败；它该有自己的终态档，
    /// 既不计 failed、也不触发停批。
    /// 〔已摘标 2026-10-26〕本条原是红钉，C 块把 `.emptyAudio` 从 `failed` 桶里摘出来后
    /// 它自己变红（strict-xfail 的设计效果），现改为**正向断言**。
    /// 摘标同时留下这条历史：`consecutiveFailureLimit` 只该为"引擎坏了"服务，
    /// 而"这段本来就没声音"是空镜的正确答案 —— 把两者混计数，会让连续 3 段 B-roll
    /// 提前停掉整批逐段重听，后面真有口播的段再也拿不到字。
    @Test("RP-13a 连续三段空镜不得把整批判成'识别失败到上限'")
    func emptyLensMustNotStopTheBatch() {
        let outcomes: [SegmentTranscribeOutcome] = [.emptyAudio, .emptyAudio, .emptyAudio]
        let t = SegmentBatchPolicy.tally(outcomes)
        #expect(t.failed == 0, "空镜被计成 \(t.failed) 段失败")
        #expect(t.emptyAudio == 3, "空镜必须单列可上报，实得 \(t.emptyAudio)")
        let stop = SegmentBatchPolicy.shouldStop(consecutiveFailures: t.failed, cancelled: false)
        #expect(stop == .continueBatch, "整批被停：\(stop)")
        // 与生产停批循环同源：那里用的是 countsAsBatchFailure，不是 gotText
        for o in outcomes {
            #expect(!SegmentTranscribeRule.countsAsBatchFailure(o), "\(o) 不该推进连续失败计数")
        }
    }

    /// 反向对照：这条钉**不是恒真**。若有人把 `.emptyAudio` 从 `failed` 里摘出去，
    /// 上一转会因"不再有问题"自己变红 ⇒ 逼摘标；而真·引擎失败必须仍然计 failed、仍然停批。
    @Test("RP-13b 反向对照：真引擎失败仍须计 failed 并触发停批（防 RP-13a 被'全放行'糊过）")
    func realEngineFailureStillCounts() {
        let outcomes: [SegmentTranscribeOutcome] = [.engineFailed, .engineFailed, .bothEnginesFailed]
        let t = SegmentBatchPolicy.tally(outcomes)
        #expect(t.failed == 3, "真失败被漏计 ⇒ 有人把 failed 整档放宽了：\(t)")
        let stop = SegmentBatchPolicy.shouldStop(consecutiveFailures: t.failed, cancelled: false)
        #expect(stop == .tooManyConsecutiveFailures(3), "真失败没触发停批：\(stop)")
    }

    /// 现存缺陷的第二半：`shouldAutoRetake` 见文本空就判"该重听" ⇒ 被误判的空镜每次重跑
    /// 分析都**再听一遍、再幻觉一次**（逐段重听实测比整片贵 2.9 倍）。
    /// 这一转今天也红，因为它期望"空镜不该重听"。
    @Test("RP-13c 空镜段不得每次重跑都再听一遍")
    func emptyLensMustNotBeRetaken() {
        // 前置事实：今天"空文本 + 整片切片来源"= 判该重听。
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice),
                "前置事实变了：shouldAutoRetake 对空文本不再默认重听 ⇒ 本钉需重读")

        withKnownIssue("空文本一律判「该重听」，但空镜的空是**正确答案**不是漏切 ⇒ 每次重跑分析都对同一段 B-roll 再听一遍、再幻觉一次。C 块终态档落地后此转应红着逼摘标。见计划 §四 二阶效应第 1 行") {
            // 期望：区分得出来"没人说话"⇒ 不重听。今天没有这个输入维度，故必红。
            let isSilentBRoll = true
            let shouldRetake = SegmentRetakeRule.shouldAutoRetake(currentText: "",
                                                                  currentSource: .fullVideoSlice)
            #expect(!(shouldRetake && isSilentBRoll), "空镜被排进了逐段重听队列")
        }
    }
}

// MARK: - T19 · 配音比画面长时，字幕不得被画面时长砍掉

@Suite("RP · 字幕窗不得被画面时长砍尾（T19）")
struct CaptionWindowSingleBasisTests {

    /// **本条原为红钉，A 块接线后改了口径**（2026-10-25）：超字闸已保证新口径下
    /// `audioDuration ≤ 画面时长 + 容差`，于是"配音比画面长一大截"在 `.fixedRate` 链上
    /// **不可达** ⇒ 原来那句"末句该跟到音频末尾"钉的是一个进不去的分支，留着等于钉了个空。
    ///
    /// 真实不变量比那句更弱也更准：**字幕铺满「音频与画面中较短的那个」**。
    /// 实测反例（我自己第一版就被它打了）：`audio=5.02, picture=5` 在闸的 0.05s 容差内会放行，
    /// 但字幕裁剪发生在 5s ⇒ 末句差 0.02s 到不了音频末尾。那 50ms 是容差的代价，已知且可接受。
    ///
    /// 哪天放宽了闸（比如 B 块把画面窗口做出来之后），这条会先红，提醒"裁剪保护易主了"。
    @Test("RP-19a 凡超字闸放行的输入，字幕必然铺满 min(音频, 画面)")
    func gateBoundIsWhatProtectsCaptions() {
        let text = "第一句话。第二句话。第三句话。"

        // 三组"闸会放行"的输入：短于画面、恰等、容差内略超
        let cases: [(audio: Double, picture: Double)] = [(3, 5), (5, 5), (5.02, 5)]
        for c in cases {
            #expect(DubLengthGate.postCheck(audioSeconds: c.audio, pictureSeconds: c.picture) == .pass,
                    "前置不成立：(\(c.audio), \(c.picture)) 竟被闸拒了 ⇒ 本条的推理链断了")
            let lines = SentenceTimingAligner.align(text: text, words: [],
                                                    audioDuration: c.audio,
                                                    segmentDuration: c.picture)
            let end = lines.last?.end ?? 0
            let floor = min(c.audio, c.picture)
            #expect(end >= floor - 1e-6,
                    "audio=\(c.audio) picture=\(c.picture)：末句只到 \(end)，没铺满 \(floor)")
            #expect(end <= c.picture + 1e-6,
                    "audio=\(c.audio) picture=\(c.picture)：字幕越过画面时长 \(c.picture) 到 \(end)")
            // 音频不长于画面时必须严格跟到音频末尾；超出时允许差在闸的容差内
            #expect(abs(end - floor) < 1e-6,
                    "audio=\(c.audio) picture=\(c.picture)：末句 \(end) 与 \(floor) 不该有偏差")
        }

        // 反向对照：超出闸容差的那组会被拒，且它才是真正触发"字幕比口播短一大截"的输入
        #expect(DubLengthGate.postCheck(audioSeconds: 8, pictureSeconds: 5) != .pass,
                "前置不成立：(8,5) 竟被闸放行")
        let clipped = SentenceTimingAligner.align(text: text, words: [],
                                                  audioDuration: 8, segmentDuration: 5)
        #expect(abs((clipped.last?.end ?? 0) - 5) < 1e-6,
                "裁剪行为变了 ⇒ 上面那组的推理需要重读")
    }

    /// 反向对照：音频**不长于**画面时，现有 clamp 行为是正确的，不得被一起放宽掉
    /// （否则"修 T19"会顺手把越界保护也拆了）。
    @Test("RP-19b 反向对照：音频短于画面时字幕仍须落在画面内（防修过头）")
    func shortAudioStaysInsidePicture() {
        let lines = SentenceTimingAligner.align(text: "第一句话。第二句话。", words: [],
                                                audioDuration: 3, segmentDuration: 5)
        #expect((lines.last?.end ?? 0) <= 5 + 1e-6, "字幕越过了画面时长 ⇒ 越界保护被拆了")
        #expect((lines.last?.end ?? 0) <= 3 + 1e-6,
                "字幕跑过了音频末尾 ⇒ 比例分配算错")
    }
}
