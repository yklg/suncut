import Foundation
import Testing
@testable import MixCutCore

/// 连贯性校验。核心主张：**能不依赖模型自觉判出来的那几条，就不许只写在 prompt 里**；
/// 反过来同样成立 —— 判据只能是事实，"多少秒算跳"这种主观线一旦进判据就会把正常产出点名。
///
/// 现场动因：`generateNarrativeVariants` 的 prompt 要求模型"自检后只输出连贯的"，而程序侧只有
/// `isValidVariant`（判条数/重复/候选归属）—— 模型说自检过了就没人再查。
@Suite("方案连贯性 NarrativeContinuity")
struct NarrativeContinuityTests {

    private func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02d", n))!
    }

    /// 一条素材里的分镜：在原片 `at` 秒、长 `dur` 秒
    private func piece(_ n: Int, src: String = "video:A", at: Double, dur: Double) -> SegmentDescriptor {
        SegmentDescriptor(id: uuid(n), tags: [], text: "t\(n)", duration: dur, quality: 1,
                          sourceKey: src, startSeconds: at)
    }

    private func pools(_ groups: [[SegmentDescriptor]]) -> [[SegmentDescriptor]] { groups }

    @Test("TC-N01 同素材内台词先后被排反 ⇒ 判死（正是用户抱怨的那一条）")
    func detectsInvertedNarration() {
        let a = piece(1, at: 10, dur: 4)      // 原片 10-14s 的话
        let b = piece(2, at: 4, dur: 4)       // 原片 4-8s 的话被排到后面
        let ids = [a.id, b.id]
        let found = NarrativeContinuity.issues(ids, pools: pools([[a], [b]]))
        #expect(found == [.invertedOrder(pairIndex: 0, sourceKey: "video:A")], "实际：\(found)")
    }

    @Test("TC-N02 同素材画面重叠 ⇒ 判死，并把重叠秒数报出来")
    func detectsOverlappingFrames() {
        let a = piece(1, at: 0, dur: 10)      // 0-10s
        let b = piece(2, at: 7, dur: 5)       // 7-12s ⇒ 与上一条重叠 3s（顺序没反）
        let found = NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]]))
        #expect(found.contains(.overlappingFrames(pairIndex: 0, sourceKey: "video:A", seconds: 3.0)),
                "实际：\(found)")
        #expect(!found.contains(.invertedOrder(pairIndex: 0, sourceKey: "video:A")))
    }

    @Test("TC-N03 同素材跳空不算缺陷：混剪就是从一条素材里挑着用，「跳」是常态")
    func sourceJumpIsNotADefect() {
        // 这条替代原先的 sourceJump 判据。撤掉它的依据是一手读数而不是我的看法：
        // 真机一批方案生成里该告警报了 62 条，跳空中位数 26.6s、最大 87.0s ——
        // 一条把绝大多数正常产出都点名的规则没有信息量（计划 §AB）。
        let a = piece(1, at: 0, dur: 2)       // 0-2s
        let b = piece(2, at: 9, dur: 2)       // 9-11s ⇒ 中间在原片里跳掉 7s
        let found = NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]]))
        #expect(found.isEmpty, "跳空不该再被当成问题：\(found)")
    }

    @Test("TC-N04 阈值来自配置：重叠容忍收到 0.01s，同一条输入立刻算成重叠")
    func thresholdComesFromConfig() {
        let a = piece(1, at: 0, dur: 10)
        let b = piece(2, at: 9.95, dur: 5)     // 只交 0.05s：默认容忍下不算重复画面
        #expect(NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]])).isEmpty)
        let tight = ContinuityConfig(overlapToleranceSeconds: 0.01)
        let found = NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]]), in: tight)
        #expect(found.count == 1, "实际：\(found)")
    }

    @Test("TC-N05 跨素材相邻一律不判：换画面是必然的，没有客观连续性")
    func crossSourcePairsAreNeverJudged() {
        let a = piece(1, src: "video:A", at: 100, dur: 3)
        let b = piece(2, src: "video:B", at: 0, dur: 3)
        #expect(NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]])).isEmpty)
    }

    @Test("TC-N06 拿不到来源的分镜用「永不与人相同」的键 ⇒ 不许被误当成同素材")
    func detachedSegmentsNeverMatchEachOther() {
        let a = piece(1, src: "detached:X", at: 10, dur: 3)
        let b = piece(2, src: "detached:Y", at: 4, dur: 3)
        #expect(NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]])).isEmpty)
    }

    @Test("TC-N07 顺序、时长、区间都正常 ⇒ 一条问题都没有（判据不许见谁判谁）")
    func healthySequenceIsSilent() {
        let a = piece(1, at: 0, dur: 3)
        let b = piece(2, at: 3, dur: 3)
        let c = piece(3, at: 6.5, dur: 3)     // 中间只隔 0.5s：段与段之间有间隙是常态，不判
        let seq = [a, b, c]
        let ids = seq.map(\.id)
        #expect(NarrativeContinuity.issues(ids, pools: pools([[a], [b], [c]])).isEmpty)
    }

    @Test("TC-N08 id 不在候选里 ⇒ 连贯性不插手（结构层已拒，不重复判、也不因缺料而放行）")
    func unknownIDsAreLeftToTheStructureGate() {
        let a = piece(1, at: 10, dur: 3)
        let ghost = uuid(99)
        let found = NarrativeContinuity.issues([a.id, ghost], pools: pools([[a], []]))
        #expect(found.isEmpty, "结构问题不该由这一层报：\(found)")
        // 而结构层确实会拒它：这条测试保证"两道门"没有缝
        #expect(!NarrativeStructureEngine.isValidVariant([a.id, ghost], pools: pools([[a], []])))
    }

    @Test("TC-N09 同一次相邻对可以同时报两条事实：排反与重叠互不吞掉，且判不出第三条")
    func bothFactsReportedForOnePair() {
        let a = piece(1, at: 20, dur: 2)      // 原片 20-22s
        let b = piece(2, at: 0, dur: 30)      // 0-30s：既把先说的话排到后，又把 a 的画面整个盖住
        let ids = [a.id, b.id]
        let found = NarrativeContinuity.issues(ids, pools: pools([[a], [b]]))
        #expect(found.contains(.invertedOrder(pairIndex: 0, sourceKey: "video:A")))
        #expect(found.contains(.overlappingFrames(pairIndex: 0, sourceKey: "video:A", seconds: 2.0)))
        #expect(found.count == 2, "判据只剩两条事实性的，不许再多判出第三条：\(found)")
    }

    @Test("TC-N11 两条入口（pools+ids 与 已排序序列）必须给同一答案 —— 判据只有一份")
    func bothEntryPointsAgree() {
        let a = piece(1, at: 10, dur: 4)
        let b = piece(2, at: 4, dur: 4)
        let c = piece(3, src: "video:B", at: 0, dur: 3)
        let byPools = NarrativeContinuity.issues([a.id, b.id, c.id], pools: pools([[a], [b], [c]]))
        let byOrder = NarrativeContinuity.issues(inOrder: [a, b, c])
        #expect(byPools == byOrder, "两条路分家了：\(byPools) vs \(byOrder)")
        #expect(byPools.contains(.invertedOrder(pairIndex: 0, sourceKey: "video:A")))
    }

    @Test("TC-N12 空序列与单条序列都不许崩，也不许凭空造问题")
    func degenerateSequencesAreSilent() {
        let a = piece(1, at: 0, dur: 3)
        #expect(NarrativeContinuity.issues(inOrder: []).isEmpty)
        #expect(NarrativeContinuity.issues(inOrder: [a]).isEmpty)
    }

    @Test("TC-N10 一句话人话：位置从 1 开始数给用户看，别把内部下标 0 甩给用户")
    func descriptionsUseHumanPositions() {
        let a = piece(1, at: 10, dur: 4)
        let b = piece(2, at: 4, dur: 4)
        let issue = ContinuityIssue.invertedOrder(pairIndex: 0, sourceKey: "video:A")
        #expect(issue.describe().contains("第 1-2 条"),
                "实际：\(issue.describe())")
        #expect(!NarrativeContinuity.issues([a.id, b.id], pools: pools([[a], [b]])).isEmpty)
    }
}
