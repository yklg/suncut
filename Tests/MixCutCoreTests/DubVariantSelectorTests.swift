import Foundation
import Testing
@testable import MixCutCore

/// DubVariantSelector R3 去重真值表（EV-1 ~ EV-8）+ staleVoice 判定（EV-9 ~ EV-12）。
struct DubVariantSelectorTests {

    private let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let idC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    private let voiceA = "voice_preset_A"
    private let voiceB = "voice_preset_B"
    private let cloneVoice = "video_clone_x"

    private func v(_ id: UUID, _ index: Int, _ voice: String, audio: Bool = true) -> DubVariantValue {
        .init(dubID: id, variantIndex: index, voiceID: voice, hasAudio: audio)
    }

    @Test func EV1_audioShellsAreExcluded() {
        let result = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA, audio: false), v(idB, 1, voiceB, audio: false)],
            preferredVoiceID: voiceA, videoCloneVoiceID: nil)
        #expect(result.isEmpty)
    }

    @Test func EV2_cloneWinsWithoutPreference_legacyBehavior() {
        // 同改写版：先到的预置 A vs 后到的克隆；无 preferred 时克隆胜出（M1a 旧口径）。
        let result = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA), v(idB, 0, cloneVoice)],
            preferredVoiceID: nil, videoCloneVoiceID: cloneVoice)
        #expect(result.map(\.dubID) == [idB])
    }

    @Test func EV3_noPreferenceNoClone_firstWins() {
        let result = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA), v(idB, 0, voiceB)],
            preferredVoiceID: nil, videoCloneVoiceID: nil)
        #expect(result.map(\.dubID) == [idA])
    }

    @Test func EV4_switchVoiceAToB_preferredBWins_regardlessOfOrder() {
        // 事故核心：A 先在、B 后生成，preferred=B 必须让 B 胜出，哪怕 A 排在前面。
        let result1 = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA), v(idB, 0, voiceB)],
            preferredVoiceID: voiceB, videoCloneVoiceID: cloneVoice)
        #expect(result1.map(\.dubID) == [idB])

        // 反序同样胜出（规则只认 voiceID，不认数组顺序）。
        let result2 = DubVariantSelector.effective(
            variants: [v(idB, 0, voiceB), v(idA, 0, voiceA)],
            preferredVoiceID: voiceB, videoCloneVoiceID: cloneVoice)
        #expect(result2.map(\.dubID) == [idB])
    }

    @Test func EV5_preferredMisses_fallsBackToClone() {
        let result = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA), v(idB, 0, cloneVoice)],
            preferredVoiceID: "voice_not_in_pool", videoCloneVoiceID: cloneVoice)
        #expect(result.map(\.dubID) == [idB])
    }

    @Test func EV6_preferredAndCloneBothMiss_firstWins() {
        let result = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA), v(idB, 0, voiceB)],
            preferredVoiceID: "missing", videoCloneVoiceID: "also_missing")
        #expect(result.map(\.dubID) == [idA])
    }

    @Test func EV7_multipleIndicesDedupedIndependentlyAndSorted() {
        let result = DubVariantSelector.effective(
            variants: [
                v(idA, 1, voiceA), v(idB, 1, voiceB),
                v(idC, 0, cloneVoice),
            ],
            preferredVoiceID: voiceB, videoCloneVoiceID: cloneVoice)
        #expect(result.map(\.dubID) == [idC, idB])   // variantIndex 0 → 1 升序
        #expect(result.map(\.variantIndex) == [0, 1])
    }

    @Test func EV8_emptyPreferenceStringsAreTreatedAsNil() {
        let result = DubVariantSelector.effective(
            variants: [v(idA, 0, voiceA), v(idB, 0, voiceB)],
            preferredVoiceID: "", videoCloneVoiceID: "")
        #expect(result.map(\.dubID) == [idA])
    }

    // MARK: staleVoice

    @Test func EV9_stale_whenVoicesDiffer() {
        #expect(DubVariantSelector.isStale(boundVoiceID: voiceA, resolvedVoiceID: voiceB))
    }

    @Test func EV10_notStale_whenVoicesEqual() {
        #expect(!DubVariantSelector.isStale(boundVoiceID: voiceA, resolvedVoiceID: voiceA))
    }

    @Test func EV11_notStale_whenEitherSideMissing() {
        #expect(!DubVariantSelector.isStale(boundVoiceID: nil, resolvedVoiceID: voiceB))
        #expect(!DubVariantSelector.isStale(boundVoiceID: voiceA, resolvedVoiceID: nil))
        #expect(!DubVariantSelector.isStale(boundVoiceID: "  ", resolvedVoiceID: voiceB))
    }

    @Test func EV12_staleComparesTrimmedButRequiresRealDifference() {
        #expect(!DubVariantSelector.isStale(boundVoiceID: " voiceA ", resolvedVoiceID: "voiceA"))
        #expect(DubVariantSelector.isStale(boundVoiceID: "voiceA ", resolvedVoiceID: " voiceB"))
    }
}
