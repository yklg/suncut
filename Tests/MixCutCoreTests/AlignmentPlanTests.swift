import Testing
@testable import MixCutCore

@Suite("AudioAligner 对齐阶梯（旧口径：配音被变速塞进画面）")
struct AlignmentPlanTests {
    private func approx(_ a: Double, _ b: Double, _ tol: Double = 0.02) -> Bool { abs(a - b) < tol }

    @Test("完全相等 → 不变速、不补帧、不留静音")
    func exact() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.5, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 0)
        #expect(p.trailingSilence == 0)
    }

    @Test("微长(0.1s) → 压缩到正好画面，绝不补帧延长")
    func slightlyLonger() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.6, fps: 30)
        #expect(approx(p.atempoFactor, 3.6 / 3.5))   // 1.0286，压回画面
        #expect(p.freezePadFrames == 0)              // 永不靠定格延长画面
        #expect(approx(p.trailingSilence, 0))
    }

    @Test("微短(≤0.15s) → 不变速，末尾留静音")
    func slightlyShorter() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.4, fps: 30)
        #expect(p.atempoFactor == 1.0)
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0.1))
    }

    @Test("中等偏长 → atempo 压缩到画面，无补帧无静音")
    func atempoAbsorbs() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 3.76, fps: 30)
        #expect(approx(p.atempoFactor, 3.76 / 3.5))  // 1.074
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0))
    }

    @Test("大幅偏长 → atempo 压缩到正好画面（不再定格补帧）")
    func tooLongCompressedToFit() {
        let p = AudioAligner.plan(targetDuration: 3.5, audioDuration: 5.0, fps: 30)
        #expect(approx(p.atempoFactor, 5.0 / 3.5))   // 1.4286
        #expect(p.freezePadFrames == 0)              // 画面绝不延长
        #expect(approx(p.trailingSilence, 0))        // 压到正好，无空挡
    }

    @Test("极端超长(>2× 画面) → atempo 无封顶压到正好画面，绝不溢出")
    func extremeOverflowUncapped() {
        let p = AudioAligner.plan(targetDuration: 2.0, audioDuration: 5.0, fps: 30)
        #expect(approx(p.atempoFactor, 2.5))         // 5.0/2.0，不再封顶
        #expect(p.freezePadFrames == 0)
        #expect(p.trailingSilence == 0)              // 压到正好 = 画面
    }

    @Test("过短，atempo 封底 0.8 仍短 → 末尾留静音")
    func tooShortSilence() {
        let p = AudioAligner.plan(targetDuration: 5.0, audioDuration: 3.0, fps: 30)
        #expect(p.atempoFactor == 0.8)
        // 变速后 3.0/0.8=3.75，残差 -1.25 → 留静音 1.25
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 1.25))
    }

    @Test("14% 偏短(克隆常见) → atempo 在区间内拉满，无空挡")
    func shortFilledByWiderAtempo() {
        // 原 7.3s 画面、配音 6.3s（约短 14%）：raw=6.3/7.3=0.863 ∈ [0.8,1] → 拉满无静音
        let p = AudioAligner.plan(targetDuration: 7.3, audioDuration: 6.3, fps: 30)
        #expect(approx(p.atempoFactor, 0.863))
        #expect(p.freezePadFrames == 0)
        #expect(approx(p.trailingSilence, 0))
    }

    @Test("非法输入 → 安全默认")
    func guards() {
        let p = AudioAligner.plan(targetDuration: 0, audioDuration: 3, fps: 30)
        #expect(p == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
    }
}

// ============================================================================
// 新口径（A 块）：`.fixedRate` 一律不变速。
// 旧套件那句「配音绝不超过画面」的括号已改成"旧口径"—— 新口径下这句话不再成立，
// 保证它的是 DubLengthGate（超字一律拒），不是这里。
// ============================================================================

@Suite("AudioAligner 新口径 fixedRate（绝不变速）")
struct FixedRateAlignmentTests {

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 0.0001) -> Bool { abs(a - b) < tol }

    @Test("FR-1 配音偏长也不变速：atempo 恒 1.0、不补静音、不定格")
    func longAudioNeverSpeedsUp() {
        let p = AudioAligner.fixedRatePlan(targetDuration: 3.0, audioDuration: 5.0)
        #expect(p.atempoFactor == 1.0, "偏长被变速 ⇒ 语速一致承诺破了")
        #expect(p.freezePadFrames == 0)
        #expect(p.trailingSilence == 0)
    }

    @Test("FR-2 配音偏短只补末尾静音，也不放慢")
    func shortAudioPadsSilenceOnly() {
        let p = AudioAligner.fixedRatePlan(targetDuration: 5.0, audioDuration: 3.0)
        #expect(p.atempoFactor == 1.0, "偏短被放慢 ⇒ 同样是变速")
        #expect(approx(p.trailingSilence, 2.0), "残差该交末尾静音，实得 \(p.trailingSilence)")
        #expect(p.freezePadFrames == 0, "新口径也不许定格补帧")
    }

    @Test("FR-3 短于直接命中阈值（0.15s）时不补静音，避免制造无意义的全零尾")
    func tinyGapStaysEmpty() {
        let p = AudioAligner.fixedRatePlan(targetDuration: 3.0, audioDuration: 2.95)
        #expect(p.trailingSilence == 0, "0.05s 的缝不该补一段静音")
    }

    @Test("FR-4 按口径分派：legacy 与未记录都走旧阶梯，只有 fixedRate 不变速")
    func dispatchHonoursPolicy() {
        let legacy = AudioAligner.plan(targetDuration: 3.0, audioDuration: 5.0, fps: 30,
                                      policy: .legacyStretch)
        #expect(approx(legacy.atempoFactor, 5.0 / 3.0, 0.02),
                "旧口径必须仍然压缩到画面（存量件要能重渲成原样）")
        let unknown = AudioAligner.plan(targetDuration: 3.0, audioDuration: 5.0, fps: 30,
                                       policy: .unknownLegacy)
        #expect(unknown == legacy, "未记录档必须与旧口径同形，不许悄悄换新行为")
        let fixed = AudioAligner.plan(targetDuration: 3.0, audioDuration: 5.0, fps: 30,
                                     policy: .fixedRate)
        #expect(fixed.atempoFactor == 1.0, "fixedRate 竟走了旧阶梯 ⇒ 分派写反")
    }

    @Test("FR-5 非法输入 → 安全默认，不抛不崩")
    func guards() {
        #expect(AudioAligner.fixedRatePlan(targetDuration: 0, audioDuration: 3)
                    == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
        #expect(AudioAligner.fixedRatePlan(targetDuration: 3, audioDuration: 0)
                    == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
        #expect(AudioAligner.fixedRatePlan(targetDuration: .nan, audioDuration: 3)
                    == AlignmentPlan(atempoFactor: 1.0, freezePadFrames: 0, trailingSilence: 0))
    }
}

// ============================================================================
// 语速解析与一致性审计（DubRatePolicy.swift 的另两件）
// ============================================================================

@Suite("Policy · 语速解析与方案内一致性")
struct DubRateResolutionTests {

    @Test("解析顺序：显式 ＞ 视频偏好 ＞ 1.0，且每档都 clamp")
    func resolutionOrder() {
        #expect(DubRateResolution.resolve(explicit: 1.2, videoPreference: 0.8) == 1.2)
        #expect(DubRateResolution.resolve(explicit: nil, videoPreference: 0.8) == 0.8)
        #expect(DubRateResolution.resolve(explicit: nil, videoPreference: nil) == 1.0)
        // 越界值必须被 clamp，不许原样透传
        #expect(DubRateResolution.resolve(explicit: 99, videoPreference: nil) == DubRateLimits.rateMax)
        #expect(DubRateResolution.resolve(explicit: nil, videoPreference: -5) == DubRateLimits.rateMin)
    }

    @Test("一致性判据：混进第二颗语速必须被查出来")
    func uniformityDetectsMixedRates() {
        #expect(DubRateUniformity.check(rates: [1.0, 1.0, 1.0]).isUniform)
        #expect(!DubRateUniformity.check(rates: [1.0, 0.9]).isUniform)
        let v = DubRateUniformity.check(rates: [1.2, 1.0, 1.2])
        #expect(v.distinctRates == [1.0, 1.2], "去重升序应为 [1.0,1.2]，实得 \(v.distinctRates)")
        #expect(v.checkedCount == 3)
        // 空集合：一致，但 checkedCount=0 —— 调用方要能分辨"都一致"与"没配音可查"
        let empty = DubRateUniformity.check(rates: [])
        #expect(empty.isUniform && empty.checkedCount == 0)
    }
}
