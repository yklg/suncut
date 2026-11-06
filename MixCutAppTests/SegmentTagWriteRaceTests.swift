import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// RACE · 「打标进行中改标签」这条竞态的真实形状
//
// ## 为什么这一组长这样，而不是一台"并发模拟器"
//
// 计划里 TC-TAG-21 原本挂着"预期未定"。查清之后（2026-11-06）三件事被纠正：
//
// ① **它不是数据竞争**。所有写者都在 `@MainActor` 上（`ImportViewModel:85`、
//    `SegmentLibraryViewModel:28`），用户那次 `toggleSemanticType` 自身同步不可分。
//    真实形态是**跨 await 点的丢更新（lost update）**：机器腿"await 之前读文本、
//    await 之后整数组覆盖标签"，覆盖前不重读、不比对、无 busy/序号检查。
//
// ② **「重新识别台词」不写标签**（`reextractTranscript` 只 `setText`）。
//    我此前把它当成覆盖腿，归错了人。真正的覆盖腿是它之后紧跟的 `applyEmptyLensGate`
//    （逐段重听跑完才走到，是全部路径里最长的 await 窗口），以及自建分镜上传的
//    `ImportViewModel:553` —— 那颗上传按钮就长在分镜素材库页面上，半成品卡当场可点。
//
// ③ **机器腿今天无法在不联网的前提下被调用**（`applyEmptyLensGate` 是 private、
//    `importSelfSegments` 的回写内联在网络循环里）。所以这里**不假装跑了一次真并发**：
//    跑不了的东西不许写成"已验证"。
//
// ## 这一组钉的两件事
//
// - TC-RACE-1：**不变量**（与修复方向无关，修完仍须成立）—— 同一个 mainContext 里，
//   语义标签的可见值恒等于**最后一次 setter 写入**；`DecodedCache` 既不吞用户腿也不吞机器腿；
//   绕开 setter 的裸写下次 get 必须自愈。这条把"损失来自哪里"钉死：只可能来自**覆盖语义**，
//   不可能来自"读到脏值" ⇒ 任何"给缓存加失效"的修法都是错方向。
// - TC-RACE-2：**可达前提**（特征化基线，将来加了门禁它必须变红）—— 处理中的视频，
//   它的段照样出现在 `vm.segments` 里、照样被写入口接受。
// ============================================================================

private let raceFps = 25.0

@MainActor
private func raceWorld(status: VideoStatus) throws
    -> (Project, Video, Segment, ModelContext, ModelContainer, SegmentLibraryViewModel) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let project = Project(name: "RACE-项目")
    ctx.insert(project)
    let video = Video(name: "RACE-源", localPath: "/tmp/race-fake.mov")
    video.duration = 20
    video.fps = raceFps
    video.width = 1080
    video.height = 1920
    video.status = status
    video.isUserUploaded = true
    ctx.insert(video)
    _ = ProjectVideo.associate(project: project, video: video, in: ctx)

    let seg = Segment(segmentIndex: "seg_001", startTime: 0, endTime: 2,
                      text: "这颗橙子汁水多到离谱", semanticTypes: [.hook],
                      positionType: .opening)
    seg.startFrame = 0
    seg.endFrame = FrameTime.frame(seconds: 2, fps: raceFps)
    seg.video = video
    ctx.insert(seg)
    try ctx.save()

    let vm = SegmentLibraryViewModel()
    vm.setModelContext(ctx)
    vm.segments = [seg]
    vm.applyFilter()
    return (project, video, seg, ctx, container, vm)
}

@Suite("RACE · 打标进行中改标签", .serialized)
struct SegmentTagWriteRaceTests {

    @Test("TC-RACE-1 不变量：可见值恒等于最后一次 setter 写入，缓存不吞任何一次写")
    @MainActor
    func lastWriterWinsAndCacheNeverSwallows() throws {
        let w = try raceWorld(status: .analyzing)
        defer { withExtendedLifetime(w) {} }
        let seg = w.2

        // 先把缓存焐热 —— 这正是生产里每次 tap 前的必然形态
        // （`recomputeAllDerived` 会无条件遍历全库读 `semanticTypes`，G2 的起因描述就是它）。
        #expect(seg.semanticTypes == [.hook], "夹具前提：初始应是单颗 .hook")

        // ① 用户腿（走 VM 唯一写入口）
        w.5.toggleSemanticType(for: seg, type: .painPoint)
        #expect(seg.semanticTypes == [.hook, .painPoint],
                "用户腿那次写被缓存吞掉了：实得 \(seg.semanticTypes.map(\.rawValue))")

        // ② 机器腿（逐字照 `ImportViewModel:553` 的语句形状：整数组覆盖，不读现值）
        seg.semanticTypes = [.solution]
        #expect(seg.semanticTypes == [.solution],
                "覆盖后同跳再读不是新值 ⇒ 缓存吞了后写者：实得 \(seg.semanticTypes.map(\.rawValue))")
        #expect(!seg.semanticTypes.contains(.hook),
                "机器腿覆盖后仍留着用户那颗 ⇒ 这条不变式的前提变了，先重读本文件头")

        // ③ 落库的那一份也必须是后写者（不是只在内存里改了个对象）。
        //    ⚠️ 必须先 save 再探针读：裸改模型不写盘，本条第一版就是这么红的
        //    （新 context 读回的是上一次 `safeSave()` 的状态）。真实机器腿末尾都有 save
        //    （`ImportViewModel` 循环收口处），所以这里补上 save 才是同形对照。
        try w.3.save()
        let back = try ModelContext(w.4)
            .fetch(FetchDescriptor<Segment>()).first { $0.id == seg.id }
        #expect(back?.semanticTypes == [.solution],
                "重新 fetch 读回 \(back?.semanticTypes.map(\.rawValue) ?? []) ⇒ 内存与库里不是同一份")

        // ④ 绕开 setter 的裸写（`fixMissingSemanticTypes` 那族）：键失配必须下次 get 自愈。
        //    返回 [.solution] 就意味着 G2 约束 #4 当场破 —— 那正是它存在的理由。
        seg.semanticTypesData = try JSONCoding.encoder.encode([SemanticType.results])
        #expect(seg.semanticTypes == [.results],
                "裸写底层字段后 getter 仍回旧值 ⇒ DecodedCache 的键化短路条件破了：实得 \(seg.semanticTypes.map(\.rawValue))")
    }

    @Test("TC-RACE-2 可达前提：处理中的视频，它的段照样在库列表里、照样被写入口接受")
    @MainActor
    func inFlightVideoSegmentsAreEditableToday() throws {
        // 特征化基线（不是"应该如此"，是"今天如此"）：
        // `Video.displayableSegments` 只滤 `mixInternalWholeClip`，**不按 status 过滤** ⇒
        // 一条还在 .analyzing 的视频，它的半成品段会出现在素材库里，而三个改标签入口
        // （Inspector 行内 chip / 右键「标记类型」/ 工具条批量）都不查任何 busy 状态。
        // 有人加了门禁，这条必须变红 —— 那时把它改成"断言门禁存在"，别删了了事。
        let w = try raceWorld(status: .analyzing)
        defer { withExtendedLifetime(w) {} }
        let seg = w.2

        #expect(w.1.status == .analyzing && w.1.isUserUploaded, "夹具前提：这是一条正在 AI 分析中的自建视频")
        #expect(w.0.displayableSegments.contains { $0.id == seg.id },
                "处理中的段没进 displayableSegments ⇒ 可达性前提不成立，本条要改写")
        #expect(w.5.segments.contains { $0.id == seg.id },
                "处理中的段没进 VM 列表 ⇒ 素材库根本看不到它，那条竞态就不成立")

        // 写入口对它不设防：这一句成功，就是"用户能在机器腿 await 期间改同一颗"的证据。
        let outcome = w.5.toggleSemanticType(for: seg, type: .results)
        #expect(outcome == .added,
                "写入口拒绝了处理中的段 ⇒ 已经有门禁了，本条要从'特征化'改成'断言门禁'")
        #expect(seg.semanticTypes == [.hook, .results],
                "实得 \(seg.semanticTypes.map(\.rawValue))")
    }
}
