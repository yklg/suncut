import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// BGC · 生成侧容量与导出侧兑现（跨接缝不变式，B 块差额承接）
//
// ## 为什么必须有这一组
//
// PW-12 钉的是"生成侧超字闸放行 ⇒ 导出侧装得下"这条跨接缝不变式，吃的是**画面可续容量**。
// 这一轮把容量加了第二截（可插空镜），于是那条不变式多了一个新的破坏方式：
// 生成侧若只看本槽的池子，就会对**每一格**都许诺整个池子 —— 而空镜的纪律是每片至多用一次。
// 症状是：两条文案都放行、都花了 TTS 钱，导出时后一条被拦。
// 所以这组判据必须**两侧同跑**：先用 `DubbingViewModel.brollSecondsAvailable` 算容量并过闸，
// 再真的建一遍导出输入（`DubExportInput.from`）看兑现不兑现。
//
// ## 台架
//   · 自建内存容器 + `/tmp` 假字节素材（建输入只查存在性，不 spawn ffmpeg ⇒ 不需要 bench 闸）；
//   · 空镜供给一律挂在**另一条源视频**上且不进方案（进方案的那条会被"本片已用"筛掉 —— BGC-5 专门钉）。
// ============================================================================

private func bgcScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bgc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func bgcFile(_ dir: URL, _ name: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
    return url.path
}

/// 图：若干条源视频，每条按 `cuts` 切成**紧贴**的分镜（⇒ 除最后一段外都"续无可续"），
/// 每格绑一条指定时长的配音（nil = 不绑），外加一条项目内的「空镜」供给。
@MainActor
private func bgcGraph(dir: URL,
                     sources: [(duration: Double, cuts: [Double])],
                     dubSeconds: [Double?],
                     brollSeconds: Double?,
                     bindBrollToScheme: Bool = false) throws -> (MixScheme, ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let fps = 25.0
    let project = Project(name: "BGC-项目")
    ctx.insert(project)
    let scheme = MixScheme(name: "BGC-方案")
    ctx.insert(scheme)
    scheme.project = project

    var slots: [SchemeSegment] = []
    var segNo = 0
    for (si, src) in sources.enumerated() {
        let video = Video(name: "BGC-源\(si)", localPath: try bgcFile(dir, "src\(si).mov"))
        video.duration = src.duration
        video.fps = fps
        video.width = 1080
        video.height = 1920
        ctx.insert(video)
        _ = ProjectVideo.associate(project: project, video: video, in: ctx)

        var cursor = 0.0
        for end in src.cuts {
            segNo += 1
            let seg = Segment(segmentIndex: String(format: "seg_%03d", segNo),
                              startTime: cursor, endTime: end,
                              text: "台词 \(segNo)", semanticTypes: [.painPoint],
                              positionType: segNo == 1 ? .opening : .middle)
            seg.startFrame = FrameTime.frame(seconds: cursor, fps: fps)
            seg.endFrame = FrameTime.frame(seconds: end, fps: fps)
            seg.video = video
            ctx.insert(seg)

            if segNo <= dubSeconds.count, let secs = dubSeconds[segNo - 1] {
                let dub = SegmentDub(segment: seg, voiceId: "v1", voiceProvider: "cosyvoice",
                                     textVariantIndex: 0, rewrittenText: "改写 \(segNo)")
                dub.audioDuration = secs
                dub.audioFilePath = try bgcFile(dir, "dub\(segNo).m4a")
                dub.alignmentPolicy = .fixedRate
                ctx.insert(dub)
                seg.segmentDubs.append(dub)

                let slot = SchemeSegment(position: segNo)
                ctx.insert(slot)
                slot.scheme = scheme
                slot.segment = seg
                slot.selectedSegmentDubId = dub.id
                slots.append(slot)
            } else {
                let slot = SchemeSegment(position: segNo)
                ctx.insert(slot)
                slot.scheme = scheme
                slot.segment = seg
                slots.append(slot)
            }
            cursor = end
        }
    }

    // 空镜供给：另起一条源视频，**不进方案**（除非调用方故意要试"本片已用"那条筛）
    if let bs = brollSeconds {
        let bVideo = Video(name: "BGC-空镜源", localPath: try bgcFile(dir, "broll.mov"))
        bVideo.duration = bs
        bVideo.fps = fps
        bVideo.width = 1080
        bVideo.height = 1920
        ctx.insert(bVideo)
        _ = ProjectVideo.associate(project: project, video: bVideo, in: ctx)
        let bSeg = Segment(segmentIndex: "brl_001", startTime: 0, endTime: bs,
                           text: "", semanticTypes: [.emptyShot], positionType: .middle)
        bSeg.startFrame = 0
        bSeg.endFrame = FrameTime.frame(seconds: bs, fps: fps)
        bSeg.video = bVideo
        ctx.insert(bSeg)
        if bindBrollToScheme {
            let extra = SchemeSegment(position: slots.count + 1)
            ctx.insert(extra)
            extra.scheme = scheme
            extra.segment = bSeg
        }
    }
    try ctx.save()
    return (scheme, container)
}

@Suite("BGC · 生成侧容量与导出兑现", .serialized)
struct BrollGateCapacityTests {

    /// 一格"续无可续"的中间格：画面 4s、池子给 2s ⇒ 容量该是 6s，且导出真能接住 6s 的配音。
    @Test("BGC-1 跨接缝不变式：闸按新容量放行 ⇒ 导出侧必须真垫得满")
    @MainActor
    func gatePassIsHonoredByExport() throws {
        let dir = try bgcScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 源片 8s 切成 [0,4)+[4,8) 紧贴 ⇒ 第 1 格往后续帧的天花板就是第 2 格的起点（余量 0）
        let (scheme, c) = try bgcGraph(dir: dir, sources: [(8, [4, 8])],
                                      dubSeconds: [nil, nil], brollSeconds: 2.0)
        defer { withExtendedLifetime(c) {} }
        let firstSlot = try #require(scheme.orderedSegments.first)
        let seg = try #require(firstSlot.segment)

        let cap = PictureWindowPolicy.capacitySeconds(
            pictureStartFrame: seg.startFrame, pictureEndFrame: seg.endFrame,
            pictureIsReplaced: false, sourceDurationSeconds: 8, fps: 25,
            siblingStartFrame: seg.nextSameSourceStartFrame)
        #expect(cap == 4.0, "中间格可续容量本该只有画面自己的 4s（下一格紧贴）")
        let budget = DubbingViewModel.brollSecondsAvailable(for: seg, candidateAudioSeconds: 6.0)
        #expect(budget >= 1.95 && budget <= 2.05,
                "池子 2s ⇒ 本格预算该是 2s（实得 \(budget)）；加不出来这截，长文案仍在花钱前被拒")

        // 闸按 picture+budget 放行 6s
        let verdict = DubLengthGate.postCheck(audioSeconds: 6.0, capacitySeconds: cap + budget)
        #expect(verdict == .pass, "画面 4s + 空镜 2s 恰好接得住 6s ⇒ 闸却拒就是没把承接算进容量")

        // 真建一遍导出输入：必须不抛，且真的插了一片 2s 空镜
        let bound = try bgcGraph(dir: dir, sources: [(8, [4, 8])], dubSeconds: [6.0, nil], brollSeconds: 2.0)
        let input = try DubExportInput.from(scheme: bound.0)
        #expect(input.segments[0].fillPieces.count == 1 && input.segments[0].fillPieces[0].frames == 50,
                "闸放行了却没垫空镜 ⇒ 成片里那 2 秒是空的")
        withExtendedLifetime(bound.1) {}
    }

    /// 这一格是"续无可续"的中间格，但**没有配音要垫** ⇒ 预算 0 也不该报错（不影响别的格）。
    @Test("BGC-2 反向对照：候选时长不超画面时预算为 0（不白占池子）")
    @MainActor
    func noNeedMeansNoBudget() throws {
        let dir = try bgcScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (scheme, c) = try bgcGraph(dir: dir, sources: [(8, [4, 8])],
                                      dubSeconds: [nil, nil], brollSeconds: 2.0)
        defer { withExtendedLifetime(c) {} }
        let seg = try #require(scheme.orderedSegments.first?.segment)
        #expect(DubbingViewModel.brollSecondsAvailable(for: seg, candidateAudioSeconds: 3.5) == 0,
                "配音比画面还短却要占池子 ⇒ 后面真缺画面的那格会凭空少料")
    }

    /// 池子只有一条 2s：先绑定的一格把它占走后，另一格必须**一分钱都拿不到**。
    @Test("BGC-3 同一池子不许对两格分别许诺（否则两条都花钱、导出拦一条）")
    @MainActor
    func secondSlotGetsNothingAfterFirstIsBound() throws {
        let dir = try bgcScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 两条源视频各切 [0,4)+[4,8) ⇒ 第 1、3 格都是续无可续的中间格，各自都可能要 2s
        let freebie = try bgcGraph(dir: dir, sources: [(8, [4, 8]), (8, [4, 8])],
                                  dubSeconds: [nil, nil, nil, nil], brollSeconds: 2.0)
        let slot1Seg = try #require(freebie.0.orderedSegments[0].segment)
        let slot3Seg = try #require(freebie.0.orderedSegments[2].segment)
        // 两格都还没绑配音时，各自单问一次都能拿到 2s（此刻谁也没占）
        #expect(DubbingViewModel.brollSecondsAvailable(for: slot1Seg, candidateAudioSeconds: 6.0) >= 1.95)
        withExtendedLifetime(freebie.1) {}

        // 现在把第 1 格的 6s 配音**绑上**（= 钱已花），再问第 3 格：该一分钱都拿不到
        let bound = try bgcGraph(dir: dir, sources: [(8, [4, 8]), (8, [4, 8])],
                                dubSeconds: [6.0, nil, nil, nil], brollSeconds: 2.0)
        let slot3 = try #require(bound.0.orderedSegments[2].segment)
        let got = DubbingViewModel.brollSecondsAvailable(for: slot3, candidateAudioSeconds: 6.0)
        #expect(got == 0,
                "第 1 格已把唯一一条空镜占走，第 3 格却还拿到 \(got) ⇒ 闸会放行一条导出接不住的长文案")
        withExtendedLifetime(bound.1) {}
    }

    @Test("BGC-4 分镜不属于任何方案 ⇒ 预算 0（没有槽位顺序可言，不猜）")
    @MainActor
    func orphanSegmentGetsNoBudget() throws {
        let dir = try bgcScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let container = try ModelContainer(
            for: Schema(versionedSchema: AppSchemaV1.self),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let video = Video(name: "BGC-孤儿源", localPath: try bgcFile(dir, "orphan.mov"))
        video.duration = 8
        video.fps = 25
        ctx.insert(video)
        let seg = Segment(segmentIndex: "seg_900", startTime: 0, endTime: 4,
                          text: "孤儿", semanticTypes: [.painPoint], positionType: .opening)
        seg.startFrame = 0
        seg.endFrame = 100
        seg.video = video
        ctx.insert(seg)
        #expect(DubbingViewModel.brollSecondsAvailable(for: seg, candidateAudioSeconds: 6.0) == 0)
    }

    @Test("BGC-5 空镜段已经在方案里用着 ⇒ 不许再当自己的池子")
    @MainActor
    func inSchemeSegmentIsNotSupply() throws {
        let dir = try bgcScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // bindBrollToScheme=true：那条「空镜」分镜同时是本方案的一格 ⇒ 本片已用，筛掉
        let (scheme, c) = try bgcGraph(dir: dir, sources: [(8, [4, 8])],
                                      dubSeconds: [nil, nil], brollSeconds: 2.0,
                                      bindBrollToScheme: true)
        defer { withExtendedLifetime(c) {} }
        let seg = try #require(scheme.orderedSegments.first?.segment)
        #expect(DubbingViewModel.brollSecondsAvailable(for: seg, candidateAudioSeconds: 6.0) == 0,
                "拿已经在成片里播着的那段当空镜 ⇒ 同一段画面播两遍（纪律 2）")
    }

    @Test("BGC-6 项目里没有「空镜」标签时退化成 B-2 的口径（画面可续就是全部）")
    @MainActor
    func emptyPoolDegradesToPictureOnly() throws {
        let dir = try bgcScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (scheme, c) = try bgcGraph(dir: dir, sources: [(8, [4, 8])],
                                      dubSeconds: [nil, nil], brollSeconds: nil)
        defer { withExtendedLifetime(c) {} }
        let seg = try #require(scheme.orderedSegments.first?.segment)
        #expect(DubbingViewModel.brollSecondsAvailable(for: seg, candidateAudioSeconds: 8.0) == 0,
                "没有空镜却凭空给出预算 ⇒ 老素材上一切照旧，这条腿不该有任何新承诺")
    }
}
