import Testing
import Foundation
@testable import MixCutCore

// MARK: - AudioTrackPolicy

@Test func audioTrackPolicy_rawValueRoundTrips() {
    for policy in AudioTrackPolicy.allCases {
        #expect(AudioTrackPolicy(rawValue: policy.rawValue) == policy)
    }
}

@Test func audioTrackPolicy_onlyKeepOriginalAllowsFallback() {
    #expect(AudioTrackPolicy.keepOriginal.allowsOriginalFallback)
    #expect(!AudioTrackPolicy.dubOnly.allowsOriginalFallback)
    #expect(!AudioTrackPolicy.dubWithSeparatedBGM.allowsOriginalFallback)
}

@Test func audioTrackPolicy_eachCaseHasDisplayLabel() {
    for policy in AudioTrackPolicy.allCases {
        #expect(!policy.displayLabel.isEmpty)
    }
}

// MARK: - ScriptGroundingGate（M4 逆向豁免门）

@Test func groundingGate_forwardRequiresEvidence_reverseExempt() {
    #expect(ScriptGroundingGate.requiresExternalEvidence(.forward))
    #expect(!ScriptGroundingGate.requiresExternalEvidence(.reverse))
}

@Test func groundingGate_reverseExemptCoversTypicalCommercialWithNumbers() {
    // 逆向带货文案含数字/型号：无资料可引是结构必然，豁免门外不应被 grounding 拦。
    let requiresEvidence = ScriptGroundingGate.requiresExternalEvidence(.reverse)
    #expect(!requiresEvidence)
    // 同文案在正向仍必须能被 grounding 判为无依据（门不能反向漏）。
    let report = GroundingChecker.check(
        text: "今天只要 99 元，通过 ISO9001 认证",
        sources: [])
    #expect(!report.isGrounded)
    #expect(report.unsupportedFacts.contains("99"))
}

// MARK: - DubOnlyExportPolicy

@Test func dubOnlyPolicy_allBoundYieldsSingleCombo() {
    let a = UUID(), b = UUID()
    let combo = DubOnlyExportPolicy.singleComboChoices(orderedSelectedDubIDs: [a, b])
    #expect(combo?[0] == a)
    #expect(combo?[1] == b)
    #expect(combo?.count == 2)
}

@Test func dubOnlyPolicy_anyUnboundIsNotExportable() {
    let a = UUID()
    #expect(DubOnlyExportPolicy.singleComboChoices(orderedSelectedDubIDs: [a, nil]) == nil)
    #expect(DubOnlyExportPolicy.singleComboChoices(orderedSelectedDubIDs: [nil, nil]) == nil)
    #expect(DubOnlyExportPolicy.singleComboChoices(orderedSelectedDubIDs: []) == nil)
}

@Test func dubOnlyPolicy_unboundPositionsAreOneBasedAndLocated() {
    let a = UUID()
    #expect(DubOnlyExportPolicy.unboundPositions([a, nil, a, nil]) == [2, 4])
    #expect(DubOnlyExportPolicy.unboundPositions([a, a]).isEmpty)
}

// MARK: - ScriptMatchRepair（W3 真删回退判据）

@Test func matchRepair_returnsScenesWhoseBoundSegmentWasDeleted() {
    let s1 = UUID(), s2 = UUID(), s3 = UUID()
    let segA = UUID(), segB = UUID()
    let affected = ScriptMatchRepair.affectedSceneIDs(
        sceneToSegment: [s1: segA, s2: segB, s3: segA],
        deletedSegmentIDs: [segA])
    #expect(affected == [s1, s3])
}

@Test func matchRepair_noOverlapYieldsEmpty() {
    let affected = ScriptMatchRepair.affectedSceneIDs(
        sceneToSegment: [UUID(): UUID()],
        deletedSegmentIDs: [UUID()])
    #expect(affected.isEmpty)
}

@Test func matchRepair_emptyInputsAreSafe() {
    #expect(ScriptMatchRepair.affectedSceneIDs(sceneToSegment: [:], deletedSegmentIDs: [UUID()]).isEmpty)
    #expect(ScriptMatchRepair.affectedSceneIDs(
        sceneToSegment: [UUID(): UUID()], deletedSegmentIDs: []).isEmpty)
}
