import Foundation
import SwiftData
import Testing
@testable import SunCut

// ============================================================================
// V-1 / V-3 · 概览投影在**真容器**里的剪枝往返（计划 2026-10-23 笔 V2）
//
// 为什么要有这组：Core 的 `OverviewProjectionPruneTests` 证的是「给一份值行，摘掉 id
// 之后两颗数对不对」；这一组证的是「VM 真的把值行装进投影、删视频后真的只剪投影不 fetch，
// 且存活项目的两颗出口（`displayableSegments` / `displayableSegmentCount`）不含已删段」。
// 缺了这格，"纯剪"与"出口不许在死对象上被调用"都只有源码形状，没有真库读数。
//
// 台架：每条用例自己一颗**内存容器**（`isStoredInMemoryOnly`），绝不打开用户活库。
// 不碰 ffmpeg / 文件系统 —— 本组只压 SwiftData 关系与投影。
// ============================================================================

@MainActor
private func ovContainer() throws -> ModelContainer {
    try ModelContainer(for: Schema(versionedSchema: AppSchemaV1.self),
                       configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
}

@MainActor
private func ovSegment(_ index: String, of video: Video, internalWholeClip: Bool = false) -> Segment {
    let segment = Segment(segmentIndex: index,
                          startTime: 0,
                          endTime: 1,
                          text: "台词",
                          semanticTypes: [.transition],
                          positionType: .middle)
    segment.mixInternalWholeClip = internalWholeClip
    segment.video = video
    return segment
}

@MainActor
private func ovVideo(_ name: String, userUploaded: Bool = false) -> Video {
    let video = Video(name: name, localPath: "/tmp/\(name)")
    video.duration = 10
    video.width = 1080
    video.height = 1920
    video.isUserUploaded = userUploaded
    return video
}

@Test("V-1/V-3 概览投影：删视频后只剪投影，卡片与计数自洽；存活项目出口不含已删段")
@MainActor
func overviewProjectionPrunesWithoutFetching() throws {
    let container = try ovContainer()
    let context = container.mainContext

    let project = Project(name: "投影项目")
    context.insert(project)

    let cardVideo = ovVideo("卡片素材.mp4")
    let selfBuilt = ovVideo("自建分镜.mp4", userUploaded: true)
    context.insert(cardVideo)
    context.insert(selfBuilt)
    ProjectVideo.associate(project: project, video: cardVideo, in: context)
    ProjectVideo.associate(project: project, video: selfBuilt, in: context)

    let visibleA = ovSegment("seg_001", of: cardVideo)
    let visibleB = ovSegment("seg_002", of: cardVideo)
    let internalC = ovSegment("seg_003", of: cardVideo, internalWholeClip: true)
    let selfBuiltA = ovSegment("seg_004", of: selfBuilt)
    context.insert(visibleA)
    context.insert(visibleB)
    context.insert(internalC)
    context.insert(selfBuiltA)
    try context.save()

    let vm = ProjectViewModel()
    vm.setModelContext(context)
    vm.refreshOverviewSnapshot(for: project)

    // 卡片只装成片视频；自建分镜视频不进卡片，但它的分镜计入「分镜」统计。
    #expect(vm.overviewSnapshot.rows.count == 1)
    #expect(vm.overviewSnapshot.rows.first?.id == cardVideo.id)
    #expect(vm.overviewSnapshot.rows.first?.visibleSegmentCount == 2,
            "混剪补建的内部整片段不许进卡片读数")
    #expect(vm.overviewSnapshot.videoCount == 1)
    #expect(vm.overviewSnapshot.segmentCount == 3,
            "2 条可见段 + 1 条自建分镜段；内部整片段不计")

    // 删一颗自建分镜视频：只该减分镜数，视频卡数不动。
    let selfBuiltID = selfBuilt.id
    let selfBuiltSegmentID = selfBuiltA.id
    context.delete(selfBuilt)
    try context.save()
    vm.pruneDeletedOverviewVideos([selfBuiltID])

    #expect(vm.overviewSnapshot.videoCount == 1)
    #expect(vm.overviewSnapshot.segmentCount == 2)
    #expect(!vm.overviewSnapshot.countRows.contains { $0.id == selfBuiltID })
    #expect(!vm.overviewSnapshot.rows.contains { $0.id == selfBuiltID })

    // 存活项目的两颗唯一出口：既不含已删段，也不让已删段参与计数。
    let liveSegmentIDs = Set(project.displayableSegments.map(\.id))
    #expect(!liveSegmentIDs.contains(selfBuiltSegmentID))
    #expect(project.displayableSegmentCount == 2)
    #expect(project.displayableSegments.allSatisfy { !$0.mixInternalWholeClip })
}

@Test("V-1 删项目后概览投影整体清空，不留上一个项目的数字")
@MainActor
func overviewProjectionClearsWhenSelectedProjectIsDeleted() throws {
    let container = try ovContainer()
    let context = container.mainContext
    let project = Project(name: "将被删")
    context.insert(project)
    let video = ovVideo("素材.mp4")
    context.insert(video)
    ProjectVideo.associate(project: project, video: video, in: context)
    let segment = ovSegment("seg_001", of: video)
    context.insert(segment)
    try context.save()

    let vm = ProjectViewModel()
    vm.setModelContext(context)
    vm.selectedProject = project
    vm.refreshOverviewSnapshot(for: project)
    #expect(vm.overviewSnapshot.rows.count == 1)

    let projectID = project.id
    context.delete(project)
    try context.save()
    vm.pruneDeletedProjects([projectID])

    #expect(vm.overviewSnapshot.rows.isEmpty)
    #expect(vm.overviewSnapshot.videoCount == 0)
    #expect(vm.overviewSnapshot.segmentCount == 0)
}
