import Foundation
import Testing
@testable import MixCutCore

/// `PlaybackActivationPolicy` 真值表与 `PlaybackActivationGate` 事件序列契约测试。
///
/// 钉住的规则：
/// - ensureActive 幂等：对当前已激活的同一分镜不产生新播放信号；
/// - restart 恒产生新播放信号（边界微调预览、定格后重播）；
/// - active 状态与判定由 Gate 单点持有，事件序列中「播放信号数」精确可推。
struct PlaybackActivationPolicyTests {

    let idA = UUID()
    let idB = UUID()

    // MARK: - Policy 无状态判定真值表（6）

    @Test("ensureActive：无激活 → 放行")
    func ensureWithNoActiveEmits() {
        #expect(PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: nil, requestID: idA, intent: .ensureActive))
    }

    @Test("ensureActive：激活的是别的分镜 → 放行")
    func ensureWithDifferentActiveEmits() {
        #expect(PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: idB, requestID: idA, intent: .ensureActive))
    }

    @Test("ensureActive：激活的就是请求分镜 → 不放行（幂等）")
    func ensureWithSameActiveDoesNotEmit() {
        #expect(!PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: idA, requestID: idA, intent: .ensureActive))
    }

    @Test("restart：无激活 → 放行")
    func restartWithNoActiveEmits() {
        #expect(PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: nil, requestID: idA, intent: .restart))
    }

    @Test("restart：激活的是别的分镜 → 放行")
    func restartWithDifferentActiveEmits() {
        #expect(PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: idB, requestID: idA, intent: .restart))
    }

    @Test("restart：激活的就是请求分镜 → 仍放行（强制重播）")
    func restartWithSameActiveEmits() {
        #expect(PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: idA, requestID: idA, intent: .restart))
    }

    // MARK: - Gate 事件序列（5，竞态直接形状）

    /// 复现本次 bug：点击播放后，hover 延迟任务到期再次 ensure 同一分镜。
    @Test("序列：ensure A → ensure A 只产生 1 个信号（点击/hover 竞态去重）")
    func sequenceDuplicateEnsureProducesSingleSignal() {
        var gate = PlaybackActivationGate()
        var signals = 0
        if gate.request(segmentID: idA, intent: .ensureActive) { signals += 1 }
        if gate.request(segmentID: idA, intent: .ensureActive) { signals += 1 }
        #expect(signals == 1)
        #expect(gate.activeSegmentID == idA)
    }

    @Test("序列：ensure A → restart A 产生 2 个信号（同分镜强制重播）")
    func sequenceEnsureThenRestartSameProducesTwoSignals() {
        var gate = PlaybackActivationGate()
        var signals = 0
        if gate.request(segmentID: idA, intent: .ensureActive) { signals += 1 }
        if gate.request(segmentID: idA, intent: .restart) { signals += 1 }
        #expect(signals == 2)
        #expect(gate.activeSegmentID == idA)
    }

    @Test("序列：ensure A → ensure B → ensure A 产生 3 个信号（跨分镜来回切换）")
    func sequenceSwitchingSegmentsProducesThreeSignals() {
        var gate = PlaybackActivationGate()
        var signals = 0
        for (id, intent) in [(idA, PlaybackActivationIntent.ensureActive),
                             (idB, .ensureActive),
                             (idA, .ensureActive)] {
            if gate.request(segmentID: id, intent: intent) { signals += 1 }
        }
        #expect(signals == 3)
        #expect(gate.activeSegmentID == idA)
    }

    @Test("序列：ensure A → clear → ensure A 产生 2 个信号（停止后重新激活）")
    func sequenceClearThenReactivateProducesTwoSignals() {
        var gate = PlaybackActivationGate()
        var signals = 0
        if gate.request(segmentID: idA, intent: .ensureActive) { signals += 1 }
        gate.clear()
        #expect(gate.activeSegmentID == nil)
        if gate.request(segmentID: idA, intent: .ensureActive) { signals += 1 }
        #expect(signals == 2)
        #expect(gate.activeSegmentID == idA)
    }

    @Test("序列：ensure A → restart B → ensure B 只产生 2 个信号（restart 迁移 active 归属）")
    func sequenceRestartMigratesOwnershipThenEnsureDeduped() {
        var gate = PlaybackActivationGate()
        var signals = 0
        if gate.request(segmentID: idA, intent: .ensureActive) { signals += 1 }
        if gate.request(segmentID: idB, intent: .restart) { signals += 1 }
        #expect(gate.activeSegmentID == idB)
        // B 已因 restart 激活，随后的重复 ensure B 必须被吞
        if gate.request(segmentID: idB, intent: .ensureActive) { signals += 1 }
        #expect(signals == 2)
        #expect(gate.activeSegmentID == idB)
    }
}
