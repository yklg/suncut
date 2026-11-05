import Foundation
import Testing
@testable import MixCutCore

/// `SegmentRetakeRule` 的契约测试（计划 v5 起，**v8 删宽窗后只剩"风格锚 + 引擎能力表"这一族**）。
///
/// 守护的是一般规则（计划 §10.1）：
/// - R-b **同源**：同一引擎的锚 / 能力 / 格式 / 来源档必须是同一个答案
/// - **锚只钉风格、不含业务词**（E2 实测邻居台词当 prompt 会把对的词写坏）
/// - 能力表**完备**：引擎清单里每台都有表项，缺项即红（将来加第三台时不会静默走默认值）
///
/// ⚠️ 每条判据都配了**正向对照**：只断言"应该为真"而不验"错的样子会红"，就是恒真判据。
///
/// 这里曾有 24 条守**宽窗**（取窗计划、按时间戳裁回、覆盖率阈值、接缝容差、clip 相对→绝对秒的偏移）。
/// 2026-09-29 随那套实现整块删除：两遍实测净收益为负，换引擎这条路也已收档（另立计划 §13）。
/// 改前原文留档：`.scratch/before-widen-removal/old-full-SegmentRetakeRuleTests.swift`。
///
/// 门面级的"回落腿也带锚"（TC-125）在核心层只能测到它的**依据**（锚只由实际跑的引擎决定），
/// 真正跑两条腿在 App 侧，`Package.swift` 的 test target 碰不到 —— 那半边靠运行期探针（计划 §4）。

@Suite("SegmentRetakeRule：风格锚与引擎能力表")
struct SegmentRetakeRuleTests {

    private let anchor = ASRPolicy.retakeStyleAnchor

    // MARK: TC-114 锚只给带得动它的引擎

    @Test("TC-114 本机腿有锚、云端腿没有；锚文本就是 ASRPolicy 那颗常量")
    func anchorIsEngineDecided() {
        #expect(SegmentRetakeRule.styleAnchor(for: .local) == anchor)
        #expect(!anchor.isEmpty, "锚为空 = 这条修法根本没生效，界面却还是绿的")
        #expect(SegmentRetakeRule.styleAnchor(for: .cloud) == nil,
                "云端 paraformer 没有 prompt 概念，传进去就是假装支持")
    }

    // MARK: TC-115 锚与业务内容零交集

    @Test("TC-115 锚不含任何台词用词；含锚字样的样本必须被判为有交集（正向对照）")
    func anchorSharesNoVocabulary() {
        // 本仓真实素材里出现过的词（E1~E4 那四段）
        for sample in ["秋冬一到嘴就干，这果子咬了一口全是水",
                       "又干又燥的季节，苹果梨都吃腻了",
                       "石林人参果片，云南石林高原",
                       "切开来汁水汪汪，清清甜甜，还带点奶香"] {
            #expect(SegmentRetakeRule.anchorIsContentFree(against: sample),
                    "锚与真实台词共享了二字组 = 邻居式传染通道又开回来了：\(sample)")
        }
        // 正向对照：把锚自己的话当台词喂，必须判为**有**交集
        #expect(!SegmentRetakeRule.anchorIsContentFree(against: "请使用简体中文书写这段话"),
                "判据恒真：连锚自身的文本都没查出来")
    }

    // MARK: TC-120 能力表完备

    @Test("TC-120 每台引擎都在能力表里；将来引入第三台时不会静默走默认值")
    func capabilityTableCoversEveryEngine() {
        for engine in ASREngine.allCases {
            #expect(SegmentRetakeRule.capabilities[engine] != nil,
                    "\(engine) 没登记逐段重听能力，却被默认成'什么都不支持'")
        }
        #expect(Set(SegmentRetakeRule.capabilities.keys) == Set(ASREngine.allCases),
                "能力表里有引擎清单外的条目")
    }

    // MARK: TC-125 回落腿带不带锚，只看实际跑的那台

    @Test("TC-125 锚只由实际跑的引擎决定；与 verdict 记的来源同一台（与 TC-80 同源）")
    func anchorFollowsTheEngineThatActuallyRan() {
        for engine in ASREngine.allCases {
            #expect((SegmentRetakeRule.styleAnchor(for: engine) != nil)
                    == SegmentRetakeRule.capability(for: engine).contextPrompt,
                    "锚与能力表两个答案 = 回落时会出现'记着本地、却没带锚'")
        }
        // 回落成功：实际跑的是本地 ⇒ 该带锚。来源档也必须落在本地那一档
        let verdict = SegmentTranscribeRule.classify(
            currentText: "旧的一句", currentSource: .unknownLegacy,
            decision: .use(.cloud, reason: "auto"),
            primary: .failed(via: .cloud),
            fallback: .ok("秋冬一到嘴就干", via: .local),
            cancelled: false)
        #expect(verdict.source == .segmentLocal)
        if let source = verdict.source {
            let engine: ASREngine = source == .segmentLocal ? .local : .cloud
            #expect(SegmentRetakeRule.styleAnchor(for: engine) != nil,
                    "回落腿是本地却没带锚 = 最容易出繁体的那一次识别没被钉住")
        }
    }

    // MARK: TC-126 锚回吐判据

    @Test("TC-126 结果里混进锚的片段 ⇒ 判为回吐；正常台词不误判")
    func anchorEchoIsDetected() {
        #expect(SegmentRetakeRule.containsAnchorEcho("下面是一段简体中文口语旁白，秋冬一到嘴就干", anchor: anchor),
                "锚被当识别结果回吐却查不出来 = 会把说明文字写进台词库")
        #expect(!SegmentRetakeRule.containsAnchorEcho("秋冬一到嘴就干，这果子咬了一口全是水", anchor: anchor))
        #expect(!SegmentRetakeRule.containsAnchorEcho("", anchor: anchor))
    }

    // MARK: TC-133 三份答案同源（v8 重指：能力表只剩 contextPrompt 一列，判据换成锚↔格式↔来源）

    @Test("TC-133 带锚的那台就是走 wav 与本地来源档的那台；三份答案不互相矛盾")
    func capabilityAgreesWithFormatAndSource() {
        for engine in ASREngine.allCases {
            let capability = SegmentRetakeRule.capability(for: engine)
            let format = SegmentTranscribeRule.format(for: engine)
            let source = SegmentTranscribeRule.source(for: engine)
            #expect(capability.contextPrompt == (format == .wav),
                    "\(engine)：能力表说能不能吃 prompt 一套、格式另一套 = 锚与实参来自两个答案")
            #expect((source == .segmentLocal) == (engine == .local),
                    "\(engine)：来源档与实际引擎错配 = 回落时会上屏假来源")
            #expect((SegmentRetakeRule.styleAnchor(for: engine) != nil) == capability.contextPrompt,
                    "\(engine)：锚的决定与能力表分家")
        }
    }

    @Test("TC-134 自动链只补「整片那边没给出完整句子」的段（判定看来源档、空不空、以及空镜终态）")
    func autoRetakeFillsOnlyWhatTheWholeVideoPassMissed() {
        // 边界已按句子收尾落点 ⇒ 切片就是完整句子，同一台模型再听一遍只是把同一句话重新错一次
        // （§Q-4：逐段比整片贵 2.9 倍、逐字一致仅 3/12）。
        // ⚠️ 第三颗入参 `isEmptyLensSettled`（M1 终态档）在本条一律给 false ——
        //    这里钉的是"来源档 + 空不空"这两档的原口径；终态档那一腿归 TC-SB-03b 与 RP-13c。
        //    标题以前写"只看来源档与空不空"，加了三方判据后那句话就是假话，已同轮改掉。
        #expect(!SegmentRetakeRule.shouldAutoRetake(currentText: "秋冬一到嘴就干",
                                                    currentSource: .fullVideoSlice,
                                                    isEmptyLensSettled: false))
        // 空段 ⇒ 整片一个字也没切到，必须补
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false))
        #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "  \u{3000}\n",
                                                   currentSource: .fullVideoSlice,
                                                   isEmptyLensSettled: false),
                "全角空格与换行也算没字：留着空白冒充「有台词」就等于永远不补")
        // 来源不是整片切片 ⇒ 整片口径帮不上它，一律真听（旧数据、模型兜底文本、手改、重听过的…）
        var checked = 0
        for src in TranscriptSource.allCases where src != .fullVideoSlice {
            #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "有字", currentSource: src,
                                                       isEmptyLensSettled: false),
                    "\(src.rawValue)：这一档的字不是整片切出来的，不许跳过")
            #expect(SegmentRetakeRule.shouldAutoRetake(currentText: "", currentSource: src,
                                                       isEmptyLensSettled: true),
                    "空镜终态档越界了：来源本身在说谎时，免听要把这一档也真听一遍")
            checked += 1
        }
        #expect(checked >= 6, "取样面太窄说明 TranscriptSource 变了而这里没跟上：\(checked)")
    }
}
