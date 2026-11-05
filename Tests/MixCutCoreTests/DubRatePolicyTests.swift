import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// 超字闸 / 语速口径 判据（计划 §6.1 T7、T10、T11 的 Core 半段）
//
// 这一批**不需要挂红钉** —— 判据本体就在同一个提交里，写完就该绿。
// 每条都配一把变异刀（改坏判据时必须变红），防的是"因错误原因通过"。
// ============================================================================

// MARK: - T7 · 合成前估算闸的三分界

@Suite("Gate · 合成前估算闸（T7）")
struct DubLengthGatePreCheckTests {

    /// 常速 4.3 字/秒 ⇒ 10 秒画面正好容 43 字。
    private static let text43 = String(repeating: "字", count: 43)
    private static let text44 = String(repeating: "字", count: 44)

    @Test("T7-1 估算恰等画面时长 ⇒ 放行（边界取「不超过」而非「严格小于」）")
    func exactlyFitsPasses() {
        #expect(DubLengthGate.preCheck(text: Self.text43, capacitySeconds: 10) == .pass)
    }

    @Test("T7-2 估算超画面 ⇒ 拒绝，并回显估算值与画面值")
    func overEstimateRejects() {
        let v = DubLengthGate.preCheck(text: Self.text44, capacitySeconds: 10)
        guard case .reject(.estimateOver(let est, let pic)) = v else {
            Issue.record("超字应报 estimateOver，实得 \(v)")
            return
        }
        #expect(pic == 10)
        #expect(est > 10 && est < 10.5, "44 字 ÷ 4.3 应约 10.23s，实得 \(est)")
    }

    /// T10：偏短在固定语速下是**无害**的（残差交 trailingSilence）。
    /// 被删掉的旧判据 `atempoFactor` 恰恰会在这里返回 nil（factor 0.465 < 0.5 ⇒ "须重写"），
    /// 这条判据就是防止那个误伤被抄回来。
    @Test("T10 偏短不得被误拒（旧 atempoFactor 的 0.5 下界不许抄回来）")
    func shortTextMustNotBeRejected() {
        let short = String(repeating: "字", count: 10)      // ≈2.33s，画面 10s
        #expect(DubLengthGate.preCheck(text: short, capacitySeconds: 10) == .pass,
                "偏短被拒 ⇒ 有人把旧的 0.5 下界搬进了新闸")
        // 反向对照：短到接近零也放行（闸只管长度上限，不管"太短"）
        #expect(DubLengthGate.preCheck(text: "一个字", capacitySeconds: 10) == .pass)
    }

    @Test("T7-3 空文本与纯空白不判超字（交上游'没词就别合成'处理）")
    func emptyTextIsNotAnOverflow() {
        for t in ["", "   ", "\n\t "] {
            #expect(DubLengthGate.preCheck(text: t, capacitySeconds: 10) == .pass,
                    "空文本被当成超字：\(t.debugDescription)")
        }
    }

    @Test("T7-4 画面时长缺失/非正 ⇒ 判不可决并按拒绝处理，不许放行")
    func unknownPictureDurationRejects() {
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            let v = DubLengthGate.preCheck(text: Self.text43, capacitySeconds: bad)
            #expect(v == .reject(.undecidable), "picture=\(bad) 应拒，实得 \(v)")
        }
    }

    @Test("T7-5 变异刀：闸的上限被放宽到 2 倍时本套件必须变红")
    func mutationKnife_gateIsNotTheOldRange() {
        // 旧判据放行 factor 到 2.0 ⇒ 86 字（≈20s）塞 10s 画面也过。
        // 这条钉死：新闸必须拒掉它。若有人把上限改回 2.0，本转会红。
        let doubled = String(repeating: "字", count: 86)
        #expect(DubLengthGate.preCheck(text: doubled, capacitySeconds: 10) != .pass,
                "86 字塞 10s 画面被放行 ⇒ 闸退回了旧的 0.5–2.0 区间")
    }

    @Test("B2-1 放宽的是**基准**不是阈值：同一句文案，续得到就放行、续不到照旧拒")
    func wideningIsOnCapacityNotOnTheLimit() {
        // text43 ≈ 43 字 ÷ 4.3 字/秒 ≈ 10s（未校准档），画面只有 6s。
        // 旧口径（基准=分镜画面时长）必拒；B-2 之后：
        //   · 画面往后还能续 4s（源片末尾在 10s 处）⇒ 放行 —— 这就是 B 块给用户的收益
        //   · 源片已到末尾、续无可续（容量 == 画面 == 6s）⇒ 仍拒 —— 证明放的是"能续多长"，
        //     不是把 1.0 倍这个上限放宽了。两格的唯一差别只有 capacitySeconds 这一个入参。
        let overShot = DubLengthGate.preCheck(text: Self.text43, capacitySeconds: 10)
        #expect(overShot == .pass,
                "画面可续到 10s 却仍被拒 ⇒ B-2 的基准没接上，用户还得为几帧改短台词")
        let noRoom = DubLengthGate.preCheck(text: Self.text43, capacitySeconds: 6)
        #expect(noRoom != .pass,
                "续无可续还被放行 ⇒ 阈值被真的放宽了，那会产出一批装不下的配音")
        // 载荷回显的必须是容量，否则屏上会显示一个用户没见过的数
        if case .reject(.estimateOver(let est, let cap)) = noRoom {
            #expect(cap == 6 && est > 6, "回显值不对：est=\(est) cap=\(cap)")
        } else {
            Issue.record("应报 estimateOver，实得 \(noRoom)")
        }
    }
}

// MARK: - 合成后实测闸

@Suite("Gate · 合成后实测闸")
struct DubLengthGatePostCheckTests {

    @Test("实测超画面 ⇒ 拒绝并回显两个原值")
    func measuredOverRejects() {
        let v = DubLengthGate.postCheck(audioSeconds: 8, capacitySeconds: 5)
        guard case .reject(.measuredOver(let audio, let pic)) = v else {
            Issue.record("应报 measuredOver，实得 \(v)"); return
        }
        #expect(audio == 8 && pic == 5)
    }

    @Test("容差内放行（半帧噪声不该算超字）")
    func withinTolerancePasses() {
        let tol = DubLengthGate.measuredToleranceSeconds
        #expect(DubLengthGate.postCheck(audioSeconds: 5 + tol * 0.5, capacitySeconds: 5) == .pass)
        #expect(DubLengthGate.postCheck(audioSeconds: 5, capacitySeconds: 5) == .pass)
    }

    @Test("超出容差即拒 —— 反向对照：容差不许被放宽成无上限")
    func beyondToleranceRejects() {
        let tol = DubLengthGate.measuredToleranceSeconds
        #expect(DubLengthGate.postCheck(audioSeconds: 5 + tol * 2, capacitySeconds: 5) != .pass,
                "超容差被放行 ⇒ 实测闸形同虚设")
    }

    @Test("音频时长非法（0 / 负 / NaN）⇒ 判不可决，不许读成'很短所以没事'")
    func badAudioDurationIsUndecidable() {
        for bad in [0.0, -3.0, Double.nan, Double.infinity] {
            #expect(DubLengthGate.postCheck(audioSeconds: bad, capacitySeconds: 5) == .reject(.undecidable),
                    "audio=\(bad) 应判不可决")
        }
    }
}

// MARK: - T11 · 口径枚举的缺省与兜底

@Suite("Policy · 对齐口径的缺省档（T11 Core 半段）")
struct DubAlignmentPolicyTests {

    @Test("T11-1 raw 值互不相同，且 AllCases 齐全（防加档漏写）")
    func rawValuesAreInjective() {
        let raws = DubAlignmentPolicy.allCases.map(\.rawValue)
        #expect(Set(raws).count == DubAlignmentPolicy.allCases.count,
                "raw 值有重复：\(raws)")
        #expect(DubAlignmentPolicy.allCases.count == 3,
                "档位数量变了（\(DubAlignmentPolicy.allCases.count)）⇒ 同步检查导出与面板的 switch")
    }

    @Test("T11-2 认不出的 raw 一律落 .unknownLegacy，绝不落进 .fixedRate")
    func unknownRawNeverBecomesFixedRate() {
        for junk in ["", "fixedrate", "FIXED", "legacy", "1"] {
            #expect(DubAlignmentPolicy(rawValue: junk) == nil,
                    "junk=\(junk.debugDescription) 竟被解析成 \(String(describing: DubAlignmentPolicy(rawValue: junk)))")
        }
        // 门面侧的兜底档必须是 unknownLegacy —— 这一条把"默认值冒充数据"钉死（同 TC-92b 口径）
        #expect(DubAlignmentPolicy(rawValue: "whatever") ?? .unknownLegacy == .unknownLegacy)
    }

    @Test("T11-3 只有 fixedRate 承诺不变速；另两档必须按落库值复现")
    func onlyFixedRateIgnoresStoredAtempo() {
        #expect(DubAlignmentPolicy.fixedRate != DubAlignmentPolicy.unknownLegacy)
        #expect(DubAlignmentPolicy.fixedRate != DubAlignmentPolicy.legacyStretch)
    }
}

// MARK: - 语速值域与校准

@Suite("Policy · 语速值域与实测校准")
struct DubRateLimitsTests {

    @Test("clamp 收在 CosyVoice 合法区间，且与 SpeechRatePlanner 同源")
    func clampMatchesEngineRange() {
        #expect(DubRateLimits.rateMin == SpeechRatePlanner.rateMin)
        #expect(DubRateLimits.rateMax == SpeechRatePlanner.rateMax)
        #expect(DubRateLimits.clamp(0.1) == DubRateLimits.rateMin)
        #expect(DubRateLimits.clamp(9) == DubRateLimits.rateMax)
        #expect(DubRateLimits.clamp(1.2) == 1.2)
    }

    @Test("非有限值回落 1.0，不许把 NaN 发给引擎")
    func nonFiniteFallsBackToOne() {
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(DubRateLimits.clamp(bad) == 1.0, "clamp(\(bad)) 没回落 1.0")
        }
    }

    @Test("未校准时字/秒取常速经验值，且与 SpeechDuration 同源")
    func fallbackCpsIsSingleSourced() {
        #expect(DubVoiceCalibration.fallbackCharsPerSecond == SpeechDuration.charactersPerSecond)
        #expect(DubVoiceCalibration().charsPerSecond == SpeechDuration.charactersPerSecond)
    }

    @Test("实测回校：43 字念 10s ⇒ 4.3 字/秒；坏输入返回 nil 而非 0")
    func calibrateFromMeasurement() {
        let text = String(repeating: "字", count: 43)
        let got = DubVoiceCalibration.calibrate(text: text, measuredAudioSeconds: 10)
        #expect(got != nil && abs(got! - 4.3) < 0.01, "实得 \(String(describing: got))")

        for bad in [0.0, -1.0, Double.nan] {
            #expect(DubVoiceCalibration.calibrate(text: text, measuredAudioSeconds: bad) == nil,
                    "坏时长 \(bad) 竟校准出一个数")
        }
        #expect(DubVoiceCalibration.calibrate(text: "", measuredAudioSeconds: 5) == nil,
                "零字文本不该产出一个字/秒")
    }

    @Test("校准档改变估算：同一稿字，快口估得更短")
    func calibrationAffectsEstimate() {
        let text = String(repeating: "字", count: 43)
        let slow = DubVoiceCalibration().estimatedSeconds(for: text)
        let fast = DubVoiceCalibration(charsPerSecond: 8.6).estimatedSeconds(for: text)
        #expect(abs(slow - 10) < 0.01 && abs(fast - 5) < 0.01, "slow=\(slow) fast=\(fast)")
        // 闸要吃这颗档：同一稿字，用快口档就不该被拒
        #expect(DubLengthGate.preCheck(text: text, capacitySeconds: 10,
                                      calibration: DubVoiceCalibration(charsPerSecond: 8.6)) == .pass)
    }
}

// MARK: - 拒绝文案

@Suite("Gate · 拒绝原因的可读文案")
struct DubLengthRejectedTests {

    @Test("三档拒绝各有非空文案，且都指向'改短台词'而不是'变速'")
    func messagesPointAtRewriteNotRetempo() {
        let cases: [DubLengthGate.Rejection] = [
            .estimateOver(estimatedSeconds: 12.3, capacitySeconds: 10),
            .measuredOver(audioSeconds: 11.1, capacitySeconds: 10),
            .undecidable,
        ]
        for c in cases {
            let msg = DubLengthRejected(c).description
            #expect(!msg.isEmpty, "\(c) 文案为空")
            #expect(!msg.contains("变速") && !msg.contains("atempo"),
                    "文案把用户往变速上指：\(msg)")
        }
        #expect(DubLengthRejected(.estimateOver(estimatedSeconds: 12.3, capacitySeconds: 10))
                    .description.contains("12.3"))
    }
}
