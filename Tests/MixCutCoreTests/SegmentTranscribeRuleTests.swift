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
        // 〔C 块重定口径〕`.emptyAudio` 不再并进 failed：它的含义是"引擎跑完了、也确实一个字没有"
        // ⇒ 那是空镜的正确答案，不是引擎故障。混在一起会让连续 3 段空镜提前停掉整批
        // （后面真有口播的段再也拿不到字），而停批上限存在的理由只是"引擎坏了别继续烧钱"。
        #expect(t.failed == 2, "只有两条引擎故障档算识别失败；实际 \(t.failed)")
        #expect(t.emptyAudio == 1, "空识别必须单列 —— '这段没声音'本身就是要报给用户的信息")
        #expect(t.refused == 1, "没配 Key 这类配置问题必须单列，否则被报成'N 段识别失败'")
        #expect(t.cancelled == 1)
        #expect(t.gotText + t.failed + t.emptyAudio + t.refused + t.cancelled == 7,
                "有档被漏计 = 批次总数对不上")
    }

    @Test("TC-SB-03 自动链跳过的段不产生 outcome ⇒ tally 的分母只算真跑过的（§AF 的语义边界）")
    func skippedSegmentsDoNotPolluteBatchTally() {
        let sliced = "秋冬一到嘴就干，这果子咬一口全是水。"
        // 判定本身：整片切片 + 非空 ⇒ 不必再听；空段 / 来源不是整片切片 ⇒ 必须听
        #expect(!SegmentRetakeRule.shouldAutoRetake(currentText: sliced, currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false))
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false))
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: sliced, currentSource: .unknownLegacy,
                                                   isEmptyLensSettled: false))

        // 计数诚实：跳过的段一条 outcome 都不该有，否则"7 段全跳过"会被报成"7 段拿到字"
        let seven = Array(repeating: sliced, count: 7)
        var ranSliced: [SegmentTranscribeOutcome] = []
        var ranLegacy: [SegmentTranscribeOutcome] = []
        for text in seven {
            if SegmentRetakeRule.shouldAutoRetake(currentText: text, currentSource: .fullVideoSlice,
                                                  isEmptyLensSettled: false) {
                ranSliced.append(.replaced)
            }
            if SegmentRetakeRule.shouldAutoRetake(currentText: text, currentSource: .unknownLegacy,
                                                  isEmptyLensSettled: false) {
                ranLegacy.append(.replaced)
            }
        }
        #expect(ranSliced.isEmpty, "整片切片来源可信 ⇒ 自动链一段都不该跑")
        #expect(SegmentBatchPolicy.tally(ranSliced).gotText == 0)
        #expect(ranLegacy.count == 7, "来源在说谎的边缘（旧数据兜底）必须全跑，一条都不许省")
        let t = SegmentBatchPolicy.tally(ranLegacy)
        #expect(t.gotText == 7 && t.failed == 0 && t.refused == 0 && t.cancelled == 0)
    }

    /// M1 空镜终态档：机器判定"这段没人说话"之后，空文本就是**结论**而不是缺口。
    /// 四条腿都要有 —— 只钉"空镜不重听"这一条，它会退化成一颗恒真的开关。
    @Test("TC-SB-03b 空镜终态档：空文本+已判空镜 ⇒ 不重听；其余三种组合仍按原口径")
    func emptyLensIsTerminalState() {
        // ① 终态生效：不再逐段重听（§Q-4 实测逐段比整片贵 2.9 倍）
        #expect(!SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: true),
                "空镜每次重跑都再听一遍、再幻觉一次 —— RP-13c 钉的就是这件事")
        // ② 反向对照：同一段没被打上「空镜」⇒ 仍然要听（证明①靠的是这颗入参，不是空段被整体放行）
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false))
        // ③ 标签不许顺手放过"来源在说谎"那一档：错切的句子否则再也修不回来
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "秋冬一到嘴就干",
                                                   currentSource: .unknownLegacy,
                                                   isEmptyLensSettled: true),
                "空镜标签压过了来源可信度这一判据 ⇒ 兜底文本永远没机会被重听纠正")
        // ④ 全空白（只有换行/空格）等同空文本 ⇒ 也算终态
        #expect(!SegmentRetakeRule.shouldAutoRetake(currentText: "  \n\t ",
                                                   currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: true))
    }

    // MARK: TC-SB-01 停止规则的边界档（TC-113 只测了 limit-1 / limit 两点）

    @Test("TC-SB-01 上限的其余边界：取消永远优先于上限；limit ≤ 0 不许把批次锁死；停下时报实际失败数")
    func stopRuleBoundaryGates() {
        let limit = ASRPolicy.consecutiveFailureLimit
        // 取消与已达上限同时成立 ⇒ 报 cancelled。「用户中止」和「质量崩了」是两句话，
        // 先后顺序写反 = 把用户主动停止报成"N 段连续失败已中止"。
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: limit, cancelled: true) == .cancelled)
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: limit + 99, cancelled: true) == .cancelled)
        // 配置退化成 0 或负数 ⇒ `limit > 0` 那半短路必须生效，否则第一段失败就停 = 整条功能锁死
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: 0, cancelled: false, limit: 0) == .continueBatch)
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: 999, cancelled: false, limit: 0) == .continueBatch)
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: 999, cancelled: false, limit: -1) == .continueBatch)
        // 调用方算出负数（不该发生）⇒ 也不能变成"停"
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: -5, cancelled: false) == .continueBatch)
        // 极端档 limit = 1：第一段失败即停，且带的是**实际**失败数而不是上限值
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: 1, cancelled: false, limit: 1)
                == .tooManyConsecutiveFailures(1))
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: 7, cancelled: false, limit: 3)
                == .tooManyConsecutiveFailures(7),
                "文案要说「连续失败 7 段」，报成上限 3 = 谎报")
        // 默认档自证：现网用的不是上面这些极端值
        #expect(SegmentBatchPolicy.shouldStop(consecutiveFailures: limit - 1, cancelled: false) == .continueBatch)
    }

    // MARK: TC-SB-02 计数守恒（穷举七档 × 不均分布，期望值由输入算出）

    @Test("TC-SB-02 tally 求和守恒：任意档任意条数，四桶之和恒等于条数；分桶口径与 gotText() 同源")
    func tallyConservesCountAcrossAllOutcomes() {
        // 空批：五个桶全 0（"0 段拿到字"与"没跑"不能混）
        let empty = SegmentBatchPolicy.tally([])
        #expect(empty.gotText == 0 && empty.failed == 0 && empty.emptyAudio == 0
                && empty.refused == 0 && empty.cancelled == 0)

        let all = SegmentTranscribeOutcome.allCases
        // 穷举不变量走全表，不自己造随机源（`SplitMix64` 的真源在 `Sources/MixCutCore/FolderMixPicker.swift`，
        // 抄一份 = 第二份真源；见 WhisperModelCatalogTests.swift:38 的同一条裁定）
        #expect(all.count == 7, "档位表变了：本条的穷举覆盖要跟着补，tally 的 switch 也得跟着改")

        // 每档单独一条：求和恒 1，且"算不算拿到字"必须与 gotText() 同一口径
        for outcome in all {
            let one = SegmentBatchPolicy.tally([outcome])
            #expect(one.gotText + one.failed + one.emptyAudio + one.refused + one.cancelled == 1,
                    "\(outcome) 漏计或被双计")
            #expect((one.gotText == 1) == SegmentTranscribeRule.gotText(outcome),
                    "\(outcome)：tally 的分桶与 gotText() 分家 = 两套真源")
            // 停批口径也必须与 tally 同源：failed 桶 == countsAsBatchFailure 的档集。
            // 两边分家就是"Toast 说 3 段失败、循环却按另一套数停批"的形状。
            #expect((one.failed == 1) == SegmentTranscribeRule.countsAsBatchFailure(outcome),
                    "\(outcome)：tally 的 failed 桶与停批判据分家 = 两套真源")
            #expect((one.refused == 1) == (outcome == .refused),
                    "\(outcome)：配置问题被并进识别失败 = 把没配 Key 报成质量差")
            #expect((one.cancelled == 1) == (outcome == .cancelled))
        }

        // 不均分布：第 k 档出现 k+1 次 ⇒ 期望值由**输入自己分桶**算出，不看函数输出
        // （分桶口径写在这里，是从各档的文档语义来的；tally 若把某档放错桶，两边就对不上）
        var mixed: [SegmentTranscribeOutcome] = []
        for (k, outcome) in all.enumerated() {
            mixed.append(contentsOf: Array(repeating: outcome, count: k + 1))
        }
        let gotSet: Set<SegmentTranscribeOutcome> = [.replaced, .unchanged]
        // 〔C 块重定口径〕`.emptyAudio` 从 failedSet 移到 emptySet：
        // 引擎跑完、确实没字 = 空镜的正确答案，不是故障（详见 SegmentTranscribeRule.countsAsBatchFailure）
        let failedSet: Set<SegmentTranscribeOutcome> = [.bothEnginesFailed, .engineFailed]
        let emptySet: Set<SegmentTranscribeOutcome> = [.emptyAudio]
        let t = SegmentBatchPolicy.tally(mixed)
        #expect(t.gotText == mixed.filter { gotSet.contains($0) }.count)
        #expect(t.failed == mixed.filter { failedSet.contains($0) }.count)
        #expect(t.emptyAudio == mixed.filter { emptySet.contains($0) }.count)
        #expect(t.refused == mixed.filter { $0 == .refused }.count)
        #expect(t.cancelled == mixed.filter { $0 == .cancelled }.count)
        #expect(t.gotText + t.failed + t.emptyAudio + t.refused + t.cancelled == mixed.count,
                "有档被漏计 = 批次总数对不上（Toast 会说谎）")
        // 夹具非空洞性：不均分布真的不均（每档条数各不相同），否则上面几条退化成"全都相等"
        #expect(mixed.count == 28 && Set(mixed).count == all.count)
    }
}
