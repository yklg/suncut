import Foundation
import Testing
@testable import MixCutCore

@Suite("DubbingJobCancellation")
struct DubbingJobCancellationTests {

    private let video = UUID()
    private let otherVideo = UUID()
    private let s1 = UUID()
    private let s2 = UUID()
    private let s3 = UUID()

    @Test("video 命中（删项目链）→ 取消")
    func videoHit() {
        #expect(DubbingJobCancellation.shouldCancel(
            videoID: video,
            targetSegmentIDs: [s1, s2],
            deletedVideoIDs: [video],
            deletedSegmentIDs: [s1, s2]))
    }

    @Test("目标分镜全部被删（素材页删视频链，只带 segment）→ 取消")
    func allTargetsDeleted() {
        #expect(DubbingJobCancellation.shouldCancel(
            videoID: video,
            targetSegmentIDs: [s1, s2],
            deletedVideoIDs: [],
            deletedSegmentIDs: [s1, s2, s3]))
    }

    @Test("仅部分目标被删（删单个分镜）→ 不取消整视频作业")
    func partialDeletionKeepsJob() {
        #expect(!DubbingJobCancellation.shouldCancel(
            videoID: video,
            targetSegmentIDs: [s1, s2],
            deletedVideoIDs: [],
            deletedSegmentIDs: [s1]))
    }

    @Test("删除集合与作业完全无干 → 不取消")
    func unrelatedDeletion() {
        #expect(!DubbingJobCancellation.shouldCancel(
            videoID: video,
            targetSegmentIDs: [s1],
            deletedVideoIDs: [otherVideo],
            deletedSegmentIDs: [s2, s3]))
    }

    @Test("空目标集且视频未命中 → 不取消（避免空集合 allSatisfy 真空真）")
    func emptyTargetsWithoutVideoHit() {
        #expect(!DubbingJobCancellation.shouldCancel(
            videoID: video,
            targetSegmentIDs: [],
            deletedVideoIDs: [otherVideo],
            deletedSegmentIDs: [s1]))
    }

    @Test("video 命中且目标为空 → 仍取消（删项目优先级最高）")
    func videoHitWithEmptyTargets() {
        #expect(DubbingJobCancellation.shouldCancel(
            videoID: video,
            targetSegmentIDs: [],
            deletedVideoIDs: [video],
            deletedSegmentIDs: []))
    }
}

@Suite("DubbingPhase / DubbingJobProgress")
struct DubbingPipelineProgressTests {

    @Test("idle：fraction=nil、阶段为准备原声")
    func idleShape() {
        #expect(DubbingJobProgress.idle.fraction == nil)
        #expect(DubbingJobProgress.idle.phase == .prepareClone)
        #expect(DubbingJobProgress.idle.phaseText == "")
    }

    @Test("三阶段中文名非空且顺序固定（UI 展示契约）")
    func phaseDisplayNames() {
        for phase in DubbingPhase.pipelineOrder {
            #expect(!phase.displayName.isEmpty)
        }
        #expect(DubbingPhase.pipelineOrder == [.prepareClone, .rewrite, .synthesize])
        #expect(DubbingPhase.prepareClone.displayName == "准备原声")
        #expect(DubbingPhase.rewrite.displayName == "改写台词")
        #expect(DubbingPhase.synthesize.displayName == "合成配音")
    }
}
