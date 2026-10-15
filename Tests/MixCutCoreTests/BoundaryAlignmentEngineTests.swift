import Testing
@testable import MixCutCore

/// 边界对齐引擎测试
///
/// 覆盖核心诉求：**切点不许劈开一句台词**（窗内有句尾就吸句尾，§AF 改的优先级）；
/// 没人收尾话时才让强切镜决定落点。以及安全约束（限幅/递增/最小时长）、按帧量化。
struct BoundaryAlignmentEngineTests {

    // 默认 fps 设大一点（100），让量化几乎不影响断言里的精确小数；
    // 单独的量化测试用真实 fps。
    private let cfg = BoundaryAlignConfig()

    // MARK: - 强切镜（只在窗内没有句子收尾时刻时才决定落点）

    @Test("强切镜在搜索窗内 → 吸附到切镜点")
    func snapsToStrongSceneCut() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.2, strength: 0.8)],
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(abs(result[0] - 5.2) < 0.01)
    }

    @Test("弱画面变化（强度低于阈值）→ 不吸附，保留语义切点")
    func weakSceneDoesNotSnap() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.2, strength: 0.2)], // < 0.4 阈值
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .original)
        #expect(abs(result[0].aligned - 5.0) < 0.01)
    }

    @Test("强切镜超出搜索窗 → 不吸附")
    func strongSceneOutOfRangeDoesNotSnap() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 6.0, strength: 0.9)], // 距离 1.0s > 0.5s 窗
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor != .scene)
    }

    @Test("多个强切镜 → 吸附到最近的那个")
    func snapsToNearestStrongScene() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0],
            scenes: [
                SceneCut(time: 4.7, strength: 0.6),
                SceneCut(time: 5.3, strength: 0.9),
            ],
            silences: [],
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(abs(result[0] - 4.7) < 0.01) // 4.7 距 5.0 更近
    }

    // MARK: - 优先级（§AF：句子结束优先，切点不许劈开一句台词）

    @Test("窗内有句子结束时，连强切镜也不能把它让给画面切换点")
    func sentenceBeatsStrongScene() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.15, strength: 0.7)],
            silences: [],
            sentences: [SentenceSpan(start: 3.0, end: 4.9)],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .sentence, "切点落在句中 = 一句话被劈开，这正是重听那条腿的成因")
        #expect(abs(result[0].aligned - 4.9) < 0.01)
    }

    @Test("那段附近没人收尾话时，才让强切镜决定落点（空镜该听画面）")
    func sceneDecidesWhenNoSentenceEndNearby() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 5.2, strength: 0.9)],
            silences: [],
            sentences: [SentenceSpan(start: 0.5, end: 1.0)],   // 最近的句尾距 4.0s，远超 0.8s 窗
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .scene)
        #expect(abs(result[0].aligned - 5.2) < 0.01)
    }

    @Test("落点是句子结束时，它一定是某个句子的收尾时刻（不是「差不多在句边」）")
    func landedOnSentenceEndIsReallyASentenceEnd() {
        let ends = [2.4, 4.85, 7.1, 11.6]
        let sentences = ends.map { SentenceSpan(start: $0 - 1.5, end: $0) }
        for b in stride(from: 1.0, through: 12.0, by: 0.25) {
            let d = BoundaryAlignmentEngine.decide(
                boundaries: [Double(b)], scenes: [], silences: [],
                sentences: sentences, duration: 20, fps: 100
            )[0]
            if d.anchor == .sentence {
                #expect(ends.contains(where: { abs($0 - d.aligned) < 0.0001 }),
                        "边界 \(b) 声称吸到句尾，实际落在 \(d.aligned)")
            }
        }
    }

    @Test("无强切镜时吸附到句子结束")
    func snapsToSentenceEndWhenNoScene() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [],
            silences: [],
            sentences: [SentenceSpan(start: 3.0, end: 4.85)],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .sentence)
        #expect(abs(result[0].aligned - 4.85) < 0.01)
    }

    @Test("句子结束优先于静音")
    func sentenceBeatsSilence() {
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [],
            silences: [SilenceGap(start: 5.1, end: 5.3)],
            sentences: [SentenceSpan(start: 3.0, end: 4.9)],
            duration: 100, fps: 100
        )
        #expect(result[0].anchor == .sentence)
    }

    // MARK: - 静音

    @Test("边界落在静音段内 → 移到静音中点")
    func snapsToSilenceMidpointWhenInside() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0],
            scenes: [],
            silences: [SilenceGap(start: 4.8, end: 5.4)], // 中点 5.1
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(abs(result[0] - 5.1) < 0.01)
    }

    // MARK: - 安全约束

    @Test("吸附偏移超过 maxBoundaryShift → 回退原切点")
    func revertsWhenShiftTooLarge() {
        var c = BoundaryAlignConfig()
        c.maxBoundaryShift = 0.3
        c.sceneSearchRange = 2.0 // 放大窗让强切镜被选中，再被约束回退
        let result = BoundaryAlignmentEngine.decide(
            boundaries: [5.0],
            scenes: [SceneCut(time: 6.0, strength: 0.9)], // 偏移 1.0 > 0.3
            silences: [],
            sentences: [],
            duration: 100, fps: 100, config: c
        )
        #expect(result[0].anchor == .original)
        #expect(abs(result[0].aligned - 5.0) < 0.01)
    }

    @Test("边界保持严格递增")
    func keepsBoundariesIncreasing() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.0, 5.2, 8.0],
            // 让前两个都吸到同一个静音中点，制造非递增，验证约束修正
            scenes: [],
            silences: [SilenceGap(start: 5.0, end: 5.2)], // 中点 5.1
            sentences: [],
            duration: 100, fps: 100
        )
        #expect(result[0] < result[1])
        #expect(result[1] < result[2])
    }

    @Test("空边界 → 空结果")
    func emptyBoundaries() {
        let result = BoundaryAlignmentEngine.align(
            boundaries: [], scenes: [], silences: [], sentences: [],
            duration: 100, fps: 30
        )
        #expect(result.isEmpty)
    }

    // MARK: - 按帧量化

    @Test("最终边界吸到帧栅格")
    func quantizesToFrameGrid() {
        // fps=25 → 帧间隔 0.04s。原切点 5.013 应量化到最近帧 5.00 或 5.04
        let result = BoundaryAlignmentEngine.align(
            boundaries: [5.013],
            scenes: [], silences: [], sentences: [],
            duration: 100, fps: 25
        )
        let frameIndex = (result[0] * 25).rounded()
        #expect(abs(result[0] * 25 - frameIndex) < 0.001) // 落在整数帧上
    }

    @Test("TC-BA-01 真实句尾序列 + 模型提案：每个落点都是一句的收尾时刻（跨段残句 = 0）")
    func alignedBoundariesNeverSplitASentence() {
        // §AF 改优先级的**现场级**主张：切点不许落在句中，于是"逐段重听补台词"这件事不再必需。
        // 12 句口播、句尾每 4s 一个；5 个提案边界都落在某句尾 ±0.8s 窗内（真实现场就是这个形状）。
        let ends: [Double] = stride(from: 4.0, through: 44.0, by: 4.0).map { $0 }
        let sentences = ends.map { SentenceSpan(start: $0 - 3.2, end: $0) }
        // 再加一颗**会劈开句子**的强切镜：7.35 落在句子 [4.8, 8.0] 内部、强度 0.9、
        // 距提案 7.5 只有 0.15s（在 0.5s 的切镜窗内），而句尾 8.0 距 7.5 有 0.5s（也在 0.8s 句尾窗内）。
        // 旧优先级（强切镜在前）会选 7.35 ⇒ 这句话被劈开；新优先级必须选 8.0。
        // 没有这颗，本条用例在优先级倒回去时照样绿 —— 那叫测了个寂寞。
        let scenes = [SceneCut(time: 7.35, strength: 0.9)]
        let proposals: [Double] = [4.35, 7.5, 15.6, 20.1, 28.4, 36.2]

        let aligned = BoundaryAlignmentEngine.align(boundaries: proposals, scenes: scenes,
                                                    silences: [], sentences: sentences,
                                                    duration: 60, fps: 100)
        #expect(aligned.count == proposals.count)
        let tol = 0.005
        for b in aligned {
            #expect(ends.contains { abs($0 - b) <= tol },
                    "边界 \(b) 不是任何一句的收尾时刻 ⇒ 一句话会被切成两段，逐段重听那条腿就又是必需的")
        }
        // 直接断"没有句子被劈开"（比上面那条更贴近用户看到的现象）
        for s in sentences {
            for b in aligned where b > s.start + tol && b < s.end - tol {
                Issue.record("边界 \(b) 落在句子 [\(s.start), \(s.end)] 内部")
            }
        }
    }
}
