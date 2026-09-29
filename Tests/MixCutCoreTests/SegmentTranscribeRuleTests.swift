import Foundation
import Testing
@testable import MixCutCore

/// `SegmentTranscribeRule` + `SegmentBatchPolicy` 的契约测试（计划 §10.4 组 3 的门面半边，TC-78…TC-81 + TC-112）
///
/// 钉住的规则（一般规则 R-d/R-g/R-h 的可测部分）：
/// - R-d **不无条件覆盖**：`outcome != .replaced` 时 `textToWrite == nil` 且 `source == nil`
///   —— 落笔与否**只有 `TextProvenance` 一个说了算**，门面不许自己判空
/// - R5 **格式由引擎决定**：两引擎两种格式，且调用方没有格式参数可填
/// - R-g **纯函数边界**：以下用例全部由入参构造，无存储、无文件
/// - 计数诚实：`refused`（配置问题）不得被并进"识别失败"里报成质量问题
///
/// ⚠️ TC-82（每个分支后的临时文件不残留）**不在这份单测里**：门面在 App 侧、真跑 ffmpeg/whisper 子进程，
/// `Package.swift` 的 test target 碰不到 `MixCut/`。那一条只能在运行期用临时目录清点来验，见计划 §8.6 记账。
/// 同理 R4 的"三处实现收敛"是守卫判据（TC-83），也不是单测。

@Suite("SegmentTranscribeRule：结果分类与不覆盖纪律")
struct SegmentTranscribeRuleTests {

    private let localReady = LocalASRState(usable: true, tier: "large-v3")
    private let current = "你们说人参果不好吃的"

    /// 走通到某一档分类的公共入口（默认：偏好本地、本地就绪）
    ///
    /// `via` 是**实际跑了的那台引擎**（决策给的是"该走哪台"，回落时两者可以不同 —— TC-80 钉的就是这个区别）。
    private func verdict(_ text: String?,
                         currentText: String? = nil,
                         preference: ASRPreference = .local,
                         hasCloudKey: Bool = false,
                         via: ASREngine = .local,
                         primaryRan: Bool = true,
                         primaryOK: Bool = true,
                         fallback: TranscribeAttempt? = nil,
                         cancelled: Bool = false,
                         decision: EngineDecision? = nil) -> SegmentTranscribeVerdict {
        let dec = decision ?? ASREngineDecision.decide(purpose: .segmentTextRetake,
                                                        preference: preference,
                                                        hasCloudKey: hasCloudKey,
                                                        local: localReady)
        let primary: TranscribeAttempt
        if !primaryRan { primary = .notRun }
        else if primaryOK { primary = .ok(text ?? "", via: via) }
        else { primary = .failed(via: via) }
        return SegmentTranscribeRule.classify(currentText: currentText ?? current,
                                              currentSource: .unknownLegacy,
                                              decision: dec,
                                              primary: primary,
                                              fallback: fallback,
                                              cancelled: cancelled)
    }

    // MARK: TC-78 每一档的后置条件

    @Test("TC-78 除 replaced 外，每一档都不许给出要写的文本与新来源（R-d 的后置条件形式）")
    func everyNonReplacedOutcomeWritesNothing() {
        let cases: [(String, SegmentTranscribeVerdict)] = [
            ("unchanged", verdict(current)),
            ("emptyAudio", verdict("   \n ")),
            ("refused(决策就拒)", verdict("任意", decision: .refused(reason: "没 Key"))),
            ("refused(引擎没跑)", verdict("任意", primaryRan: false)),
            ("engineFailed", verdict(nil, primaryOK: false, fallback: nil)),
            ("bothEnginesFailed", verdict(nil, primaryOK: false, fallback: .failed(via: .local))),
            ("cancelled", verdict("新的一句", cancelled: true)),
        ]
        for (name, v) in cases {
            #expect(v.outcome != .replaced, "\(name)：分类结果本身就该不是 replaced")
            #expect(v.textToWrite == nil, "\(name) 却给了 textToWrite=\(String(describing: v.textToWrite))，调用方会照写不误")
            #expect(v.source == nil, "\(name) 却给了来源 \(String(describing: v.source))，来源会被无声刷掉")
        }

        // 正向对照（防空判据恒真）：真该写的那一档必须两样都给
        let replaced = verdict("人参果很好")
        #expect(replaced.outcome == .replaced)
        #expect(replaced.textToWrite == "人参果很好")
        #expect(replaced.source == .segmentLocal)
    }

    // MARK: TC-79 空识别不是成功

    @Test("TC-79 引擎跑成功但一个字没认出来 ⇒ emptyAudio，原句不动")
    func emptyRecognitionIsNotSuccess() {
        let v = verdict("")
        #expect(v.outcome == .emptyAudio)
        #expect(v.textToWrite == nil)

        // 与 unchanged 必须分得开：前者要提示"这段没声音"，后者是正常结果
        let same = verdict(current)
        #expect(same.outcome == .unchanged)
        #expect(SegmentTranscribeRule.gotText(same.outcome), "unchanged 也是拿到了字")
        #expect(!SegmentTranscribeRule.gotText(v.outcome), "emptyAudio 不算拿到字")
    }

    // MARK: TC-80 两条腿 vs 只有一条腿

    @Test("TC-80 回落也只失败 ⇒ bothEnginesFailed；没有第二条腿 ⇒ engineFailed（两档必须分得开）")
    func singleLegFailureIsNotBothEngines() {
        // auto + 有 Key ⇒ 决策给云端；云端挂了才试本地这条腿
        let both = verdict(nil, preference: .auto, hasCloudKey: true, via: .cloud,
                           primaryOK: false, fallback: .failed(via: .local))
        #expect(both.outcome == .bothEnginesFailed)
        #expect(both.textToWrite == nil, "回落标记为真也不许写文本")

        // 用户显式选了本地 ⇒ 只有一条腿。报"两个引擎都失败"是假话（另一个根本没试）
        let single = verdict(nil, primaryOK: false, fallback: nil)
        #expect(single.outcome == .engineFailed)
        #expect(single.outcome != both.outcome, "两档合并成一句话，真实原因会被伪装")

        // 第二条腿成功 ⇒ 文本来自回落那条，来源也必须记**实际跑的那台**（不是决策首选那台）
        let saved = verdict(nil, preference: .auto, hasCloudKey: true, via: .cloud,
                            primaryOK: false, fallback: .ok("人参果很好", via: .local))
        #expect(saved.outcome == .replaced)
        #expect(saved.textToWrite == "人参果很好")
        #expect(saved.source == .segmentLocal,
                "来源记成了决策首选那台 = 库里写着云端、字其实是本机认的；实际 \(String(describing: saved.source))")
    }

    // MARK: TC-81 取消优先

    @Test("TC-81 取消发生在这一段 ⇒ cancelled，且优先于'其实认到了字'")
    func cancellationWinsOverEverything() {
        let v = verdict("人参果很好", cancelled: true)
        #expect(v.outcome == .cancelled)
        #expect(v.textToWrite == nil, "已取消还给出文本，调用方就会把字写进去")
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: 0, cancelled: true) == .cancelled)
    }

    // MARK: TC-112 格式与来源由引擎决定（R5）

    @Test("TC-112 两引擎两种格式、两个来源档；云端永远不是 wav、本地永远不是 pcm")
    func formatAndSourceAreDecidedByEngine() {
        #expect(SegmentTranscribeRule.format(for: .cloud) == .pcm)
        #expect(SegmentTranscribeRule.format(for: .local) == .wav)
        #expect(SegmentTranscribeRule.source(for: .cloud) == .segmentCloud)
        #expect(SegmentTranscribeRule.source(for: .local) == .segmentLocal)

        // 两两互不相同：合并成同一个值就等于不记引擎
        #expect(SegmentTranscribeRule.format(for: .cloud) != SegmentTranscribeRule.format(for: .local))
        let sources: [TranscriptSource] = [.cloud, .local].map(SegmentTranscribeRule.source(for:))
        #expect(Set(sources).count == 2)
        #expect(!sources.contains(.unknownLegacy), "拿'未记录'当引擎结论 = 默认值冒充数据")
    }

    // MARK: TC-113 批次停止规则与计数诚实

    @Test("TC-113 连续失败到上限才停；拿到一次有效文本就归零；refused 不并进'识别失败'")
    func batchStopRuleAndHonestTally() {
        let limit = ASRPolicy.consecutiveFailureLimit
        #expect(limit > 0, "上限为 0 会让第一批第一段就停")
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: limit - 1, cancelled: false) == .continueBatch)
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: limit, cancelled: false)
                == .tooManyConsecutiveFailures(limit))

        let t = SegmentBatchPolicy.tally([.replaced, .unchanged, .emptyAudio,
                                          .engineFailed, .bothEnginesFailed, .refused, .cancelled])
        #expect(t.gotText == 2, "replaced/unchanged 才是拿到字")
        #expect(t.failed == 3, "空识别 + 两条失败档算识别失败；实际 \(t.failed)")
        #expect(t.refused == 1, "没配 Key 这类配置问题必须单列，否则被报成'N 段识别失败'")
        #expect(t.cancelled == 1)
        #expect(t.gotText + t.failed + t.refused + t.cancelled == 7, "有档被漏计 = 批次总数对不上")
    }
}
