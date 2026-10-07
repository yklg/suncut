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

@Test func duration_whitespaceExcludedFromCount() {
    let factor = SpeechDuration.atempoFactor(for: "你好 世界\n", slotDuration: 2)
    // 4 个有效字 ÷ 4.3 ≈ 0.93s，槽 2s → factor ≈ 0.465 < 0.5 → nil（须重写）
    #expect(factor == nil)
}

@Test func duration_atempoWithinRangeReturned() {
    // 让文案时长 ≈ 槽位时长：43 字 ≈ 10s，槽 10s → factor ≈ 1.0
    let text = String(repeating: "字", count: 43)
    let factor = SpeechDuration.atempoFactor(for: text, slotDuration: 10)
    #expect(factor != nil)
    #expect(abs(factor! - 1.0) < 0.01)
}

@Test func duration_atempoBeyondRangeReturnsNil() {
    // 200 字 ≈ 46.5s 塞进 2s 槽 → factor ≈ 23，远超 2.0
    let text = String(repeating: "字", count: 200)
    #expect(SpeechDuration.atempoFactor(for: text, slotDuration: 2) == nil)
}

@Test func duration_invalidSlotReturnsNil() {
    #expect(SpeechDuration.atempoFactor(for: "任意文案", slotDuration: 0) == nil)
}


