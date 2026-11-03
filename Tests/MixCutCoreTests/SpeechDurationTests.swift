import Testing
import Foundation
@testable import MixCutCore

@Test func duration_zeroCharactersIsZero() {
    #expect(SpeechDuration.estimate(characterCount: 0) == 0)
}

@Test func duration_positiveCharactersEstimated() {
    // 100 字 ÷ 4.3 ≈ 23.26 秒
    let d = SpeechDuration.estimate(characterCount: 100)
    #expect(d > 23 && d < 24)
}

@Test func spokenCount_excludesWhitespaceAndNewlines() {
    // 「你好 世界\n」= 4 个有效字（标点保留、空白与换行剔除）
    #expect(SpeechDuration.spokenCharacterCount("你好 世界\n") == 4)
}

@Test func estimatedSeconds_honoursCalibratedCps() {
    // 43 字：常速 4.3 字/秒 ⇒ 10s；按 8.6 字/秒的快口 ⇒ 5s
    let text = String(repeating: "字", count: 43)
    #expect(abs(SpeechDuration.estimatedSeconds(for: text) - 10) < 0.01)
    #expect(abs(SpeechDuration.estimatedSeconds(for: text, charsPerSecond: 8.6) - 5) < 0.01)
}

@Test func estimatedSeconds_nonPositiveCpsFallsBackInsteadOfDividingByZero() {
    // 反向对照：坏 cps 不许除出 inf / NaN 冒充"估算值"
    let text = String(repeating: "字", count: 43)
    for bad in [0.0, -1.0, Double.nan, Double.infinity] {
        #expect(abs(SpeechDuration.estimatedSeconds(for: text, charsPerSecond: bad) - 10) < 0.01,
                "cps=\(bad) 应回落常速档得 10s")
    }
}
