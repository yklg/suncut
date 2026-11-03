import Foundation
import SwiftData
import Testing
@testable import SunCut

// ============================================================================
// FJ · 「交回 → 投影 → join」这段接缝的**真实往返**（计划 2026-10-22 笔 J2：TC-J2 / TC-J3）
//
// ## 为什么这组测试存在
// 混剪族 123 条判据全在纯函数层（`Tests/MixCutCoreTests/`），而 App 腿里 **0 条**混剪判据
// —— 于是"候选 ↔ 库行"这颗键错位时没有任何一条判据会红：真机 50 条全被摘掉，1306 条判据
// 照样全绿（日志见计划 2026-10-22 第二节）。Core 的 JOIN 族证的是"给定这张表，判定对不对"；
// 这两条证的是"这张表在真库里**真拿得回来**"——缺的正是这一格。
//
// ## 两条腿各压一条分支（只压一条 = 半条通路，评审 S3 抓的就是这个）
//   · TC-J2 走 `importOrLink` 的**去重命中支**：真机那 59 条全走这条，而它原本只把名字
//     交回来、把行 id 丢掉 —— 就是这次缺陷的直接成因。夹具还故意把库里那行的名字做成与
//     这颗文件**不同**（同内容不同名）：任何"按名字反查"的写法在这条腿上必红。
//   · TC-J3 走**新建整片段支**（日常主用法：从没导入过的文件）。需要 ffmpeg 现造一块
//     1 秒真源 —— 因为 `commitWholeVideo` 吃 `video.duration`，而 duration 只能由
//     AVFoundation 从真容器里读到；拿假字节造不出"覆盖整片的段"。
//
// ## 台架前提与边界
//   · 自建**内存容器**（`isStoredInMemoryOnly`），绝不打开用户的库（本仓
//     `check_live_store_guards.sh` 那条纪律的同源做法）；
//   · 落盘支会往 `FileHelper.appSupportDirectory` 拷文件 ⇒ 用 DEBUG 的
//     `MIXCUT_DEBUG_APP_SUPPORT_ROOT` 把数据根指到本用例自己的临时目录，**不碰用户真目录**；
//   · 取不到 ffmpeg 就**红**，不跳过（同 `ExportCanvasReadbackTests` 的口径：判据没跑起来
//     不算通过）。
//
// ## 非空洞性
//   · 把仅关联支那句交回删掉 ⇒ TC-J2 的 `report.ingested.count == 1` 当场红（T-31 也在同一形状上红）；
//   · 把 `rowShapes` 改回按 `video.localPath` 挑行 ⇒ 两条腿的 `hitCount == 1` 都红；
//   · 这两条都由 `.scratch/fm_mutate_stepJ.py` 的 K9/K10 实跑取证，不写在这里当声明用。
// ============================================================================

// MARK: - 台架

/// 每条用例自己一颗内存容器：`ModelContext` 不跨用例共享（同 `ExportCanvasReadbackTests`
/// 立的那条"每例自己 new"的规矩，理由一样 —— 共享会在并行跑时互相踩状态）。
private func fjContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: AppSchemaV1.self)
    return try ModelContainer(for: schema, configurations: [
        ModelConfiguration(isStoredInMemoryOnly: true)
    ])
}

/// 本用例自己的临时目录，同时充当被重定向的数据根；跑完删。
private func fjScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fj-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // FileHelper.swift:21 的 DEBUG 钩子：把拷贝落盘与缩略图都关在这颗目录里。
    setenv("MIXCUT_DEBUG_APP_SUPPORT_ROOT",
           dir.appendingPathComponent("appsupport", isDirectory: true).path, 1)
    return dir
}

private func fjWrite(_ url: URL, _ bytes: Int) throws {
    try Data(bytes: [UInt8](repeating: 0x5A, count: bytes), count: bytes).write(to: url)
}

@MainActor
private func fjSeeding(_ context: ModelContext, category: String) throws -> Project {
    let project = Project(name: category)
    context.insert(project)
    return project
}

@Test("TC-J2 去重命中支：库里已有同内容、名字不同 ⇒ 交回的就是那一行，join 命中")
@MainActor
func dedupHitBranchReturnsTheExistingRowID() async throws {
    let dir = try fjScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let container = try fjContainer()
    let context = container.mainContext

    let file = dir.appendingPathComponent("同款素材.mp4")
    try fjWrite(file, 4096)
    guard let hash = ClipIngestService.computeFileHash(path: file.path) else {
        Issue.record("校验和算不出来 ⇒ 夹具失效（这条不成立时下面全无从判断）"); return
    }

    // 库里先躺着"第一次引入这份内容时"的那一行：名字与这颗文件**不同**，且已有一条覆盖整片的段。
    let project = try fjSeeding(context, category: "卖点")
    let existing = Video(name: "钩子A.mp4", localPath: "/nowhere/钩子A.mp4")
    existing.contentHash = hash
    existing.duration = 12
    existing.status = .imported
    context.insert(existing)
    _ = ProjectVideo.associate(project: project, video: existing, in: context)
    let wholeClip = SegmentCommitter().commitWholeVideo(for: existing, source: .selfShot,
                                                        context: context)
    try context.save()

    let hooks = ClipIngestHooks()
    let report = await ClipIngestService.importClips(urls: [file], to: project, source: .selfShot,
                                                     context: context, committer: SegmentCommitter(),
                                                     ffmpeg: FFmpegRunner(), hooks: hooks)
    #expect(report.failed.isEmpty, "去重命中支不该失败：\(report.failed.map(\.reason))")
    #expect(report.linkedExistingNames.count == 1,
            "没走成去重命中支（应 1 实 \(report.linkedExistingNames.count)）⇒ 这条腿换分支了")
    #expect(report.ingested.count == 1,
            "这一支原本把行 id 丢掉只留名字 —— 真机 50 条全摘就是这么来的")
    #expect(report.ingested.first?.sourcePath == file.path)
    #expect(report.ingested.first?.videoID == existing.id,
            "交回的必须是库里那一行，不是新造一行（同内容重复成行会击穿会话内不回放）")

    let candidate = FolderMixCandidate(identityKey: file.path, category: "卖点",
                                       name: file.lastPathComponent, path: file.path,
                                       duration: 12, byteSize: 4096)
    let outcome = FolderMixLibraryJoin.resolve(
        candidatesByCategory: ["卖点": [candidate]],
        ingested: report.ingested,
        shapes: FolderMixViewModel().rowShapes(for: report.ingested, context: context,
                               missingIDs: []),
        failureCodeBySourcePath: [:])
    #expect(candidate.name != existing.name, "夹具前提：两侧名字确实不同（按名字反查必红）")
    #expect(outcome.hitCount == 1,
            "接缝没打通：没找到 \(outcome.notIngestedCount) 条、无整片段 \(outcome.noWholeClipCount) 条")
    #expect(outcome.segmentIDByKey[candidate.identityKey] == wholeClip.id,
            "键→段 id 必须落在真那条整片段上，否则建方案那头会报「已经不在素材库里」")
}

@Test("P-2 母体导入不被静默判成已分析：混剪补建整片段后 status 仍 .imported，importOrLink 返回 needsAnalysis=true")
@MainActor
func mixCarrierStillNeedsParentAnalysis() async throws {
    let dir = try fjScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let container = try fjContainer()
    let context = container.mainContext

    let file = dir.appendingPathComponent("同款素材.mp4")
    try fjWrite(file, 4096)
    guard let hash = ClipIngestService.computeFileHash(path: file.path) else {
        Issue.record("校验和算不出来 ⇒ 夹具失效"); return
    }

    let project = try fjSeeding(context, category: "卖点")
    let existing = Video(name: "钩子A.mp4", localPath: "/nowhere/钩子A.mp4")
    existing.contentHash = hash
    existing.duration = 12
    existing.status = .imported
    context.insert(existing)
    _ = ProjectVideo.associate(project: project, video: existing, in: context)
    _ = SegmentCommitter().commitWholeVideo(for: existing, source: .selfShot, context: context)
    try context.save()

    let (video, needsAnalysis) = try await ClipIngestService.importOrLink(
        url: file, to: project, source: .selfShot, context: context,
        hooks: ClipIngestHooks(), ffmpeg: FFmpegRunner())

    #expect(video.id == existing.id)
    #expect(video.status == .imported,
            "混剪入库的载体必须停在 .imported ⇒ 母体链才会重新分析（P-2）")
    #expect(needsAnalysis,
            "已有整片段不代表母体链分析过 ⇒ needsAnalysis 必须为 true，否则阶段 2 被静默跳过")
}

@Test("TC-J3 新建整片段支：从没导入过的文件 ⇒ 拷盘、建段、交回、join 命中一气过")
@MainActor
func freshFileGoesThroughCopyCommitAndResolves() async throws {
    let dir = try fjScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let container = try fjContainer()
    let context = container.mainContext

    // 真源：lavfi testsrc 1 秒。假字节过不了 AVFoundation，也就建不出"覆盖整片的段"。
    let ffmpeg = FFmpegRunner()
    let source = dir.appendingPathComponent("钩子新.mp4")
    do {
        try await ffmpeg.run(arguments: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", source.path,
        ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
    } catch {
        Issue.record("造不出合成源（ffmpeg 不可用？）⇒ 这条腿没跑起来，不算通过：\(error)")
        return
    }

    let project = try fjSeeding(context, category: "爆点")
    let hooks = ClipIngestHooks()
    let report = await ClipIngestService.importClips(urls: [source], to: project, source: .selfShot,
                                                     context: context, committer: SegmentCommitter(),
                                                     ffmpeg: FFmpegRunner(), hooks: hooks)
    #expect(report.failed.isEmpty, "新建支失败：\(report.failed.map(\.reason))")
    #expect(report.importedVideoIDs.count == 1, "没走成新建支（应 1 实 \(report.importedVideoIDs.count)）")
    #expect(report.ingested.count == 1, "新建支也必须交回对应关系 —— 两支都记，才是完整通路")

    let stored = (try? context.fetch(FetchDescriptor<Video>())) ?? []
    guard let video = stored.first else {
        Issue.record("库里没落进行 ⇒ 后面的断言全是空中楼阁"); return
    }
    #expect(abs(video.duration - 1.0) < 0.5,
            "AVFoundation 没读到时长（\(video.duration)）⇒ 整片段形状判据无法成立")
    #expect(video.name == source.lastPathComponent)
    // 拷贝落地的库内路径**不是**源路径 —— 正是上一版那颗键永远对不上的原因
    #expect(video.localPath != source.path)
    #expect(report.ingested.first?.videoID == video.id)

    let candidate = FolderMixCandidate(identityKey: source.path, category: "爆点",
                                       name: source.lastPathComponent, path: source.path,
                                       duration: video.duration, byteSize: nil)
    let outcome = FolderMixLibraryJoin.resolve(
        candidatesByCategory: ["爆点": [candidate]],
        ingested: report.ingested,
        shapes: FolderMixViewModel().rowShapes(for: report.ingested, context: context,
                               missingIDs: []),
        failureCodeBySourcePath: [:])
    #expect(outcome.hitCount == 1,
            "新建支的接缝没打通：无整片段 \(outcome.noWholeClipCount)、没找到 \(outcome.notIngestedCount)")
    #expect(outcome.segmentIDByKey[candidate.identityKey] == video.segments.first?.id)
}

@Test("JOIN-23 可用性读数：数据根不在 ⇒ degraded 为真且缺失集保证为空（不许伪装成没丢）")
@MainActor
func availabilityReadingDegradesWhenRootMissing() async throws {
    // 只证那颗读数本身的两条契约（degraded ⇒ missingIDs 空），因为"整批不建"那一档在 generate() 里，
    // 而它的源码形态由门 T-32 腿 D 钉住 —— 这里把两条分工写明白，不留"看起来测过了"的错觉。
    let ghost = FileManager.default.temporaryDirectory
        .appendingPathComponent("fj-ghost-\(UUID().uuidString)", isDirectory: true)
    setenv("MIXCUT_DEBUG_APP_SUPPORT_ROOT",
           ghost.appendingPathComponent("appsupport", isDirectory: true).path, 1)
    defer { setenv("MIXCUT_DEBUG_APP_SUPPORT_ROOT", "", 1) }

    let container = try fjContainer()
    let context = container.mainContext
    let video = Video(name: "不存在.mp4", localPath: "/nowhere/不存在.mp4")
    video.duration = 12
    video.status = .imported
    context.insert(video)
    try context.save()

    let row = FolderMixIngestedRow(sourcePath: "/Users/x/素材/卖点/不存在.mp4", videoID: video.id)
    let reading = FolderMixViewModel().availabilityReading(for: [row], context: context)
    #expect(reading.degraded, "素材根目录不存在却不报降级 ⇒ 判据瞎了还会照建方案")
    #expect(reading.missingIDs.isEmpty, "degraded 时那颗契约明令 missingIDs 为空（既不判在也不判缺）")

    let shapes = FolderMixViewModel().rowShapes(for: [row], context: context,
                                                missingIDs: reading.missingIDs)
    #expect(shapes[video.id]?.filePresent == true,
            "降级那轮不许把任何一条标成缺失 —— 伪装成丢了同样是错")
}

// ── 笔 K2 · 甲-隐 的三条 App 腿（JOIN-24 / 25 / 26）──────────────────────────
//
// 为什么必须打在真容器上：这三条测的是「交回 → 补建 → 投影 → join」整段接缝，
// 纯函数那侧（JOIN-0…22）证不了"补建真的落进库里那一行并且带上了标记"。

@MainActor
private func fjSeededWithStoryboard(context: ModelContext, category: String,
                                    localPath: String, duration: Double,
                                    contentHash: String) throws -> (Project, Video) {
    let project = try fjSeeding(context, category: category)
    let video = Video(name: "钩子A.mp4", localPath: localPath)
    // 去重命中靠这颗校验和（实读 `ClipIngestService.findExistingVideo(hash:)`）——
    // 不设它就等于测「新建支」而不是「补建支」，第一次跑就是这么假红的。
    video.contentHash = contentHash
    video.duration = duration
    video.fps = 30
    video.status = .imported
    context.insert(video)
    _ = ProjectVideo.associate(project: project, video: video, in: context)
    // 当年按分镜导入的形状：一条**不覆盖全片**的段（0..duration/3）
    let part = Segment(segmentIndex: "seg_001", startTime: 0, endTime: duration / 3,
                       text: "老台词", semanticTypes: [], positionType: .opening)
    part.video = video
    part.setFrameRange(startFrame: 0, endFrame: Int(duration / 3 * 30), fps: 30)
    context.insert(part)
    try context.save()
    return (project, video)
}

@Test("JOIN-24 去重命中 + 有分镜段 + 无整片段 + 文件在 ⇒ 补建一条内部整片段，join 从档 B 转命中")
@MainActor
func dedupHitBackfillsInternalWholeClip() async throws {
    let dir = try fjScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let container = try fjContainer()
    let context = container.mainContext
    let file = dir.appendingPathComponent("同款素材.mp4")
    try fjWrite(file, 4096)

    // 库里那一行必须真的在盘上（否则守门②会拦下补建，那是 JOIN-26 那条腿）
    let copy = FileHelper.globalVideoDirectoryForReading.appendingPathComponent("present.mp4")
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try fjWrite(copy, 4096)

    let (project, existing) = try fjSeededWithStoryboard(context: context, category: "卖点",
                                                         localPath: copy.path, duration: 12,
                                                         contentHash: try #require(ClipIngestService.computeFileHash(path: file.path)))
    #expect(existing.segments.count == 1, "夹具前提：这行只有一条不覆盖全片的段")

    let report = await ClipIngestService.importClips(urls: [file], to: project, source: .selfShot,
                                                     context: context, committer: SegmentCommitter(),
                                                     ffmpeg: FFmpegRunner(), hooks: ClipIngestHooks())
    #expect(report.failed.isEmpty, "\(report.failed.map(\.reason))")
    #expect(report.internalWholeClipBuilt == 1,
            "没补建（实得 \(report.internalWholeClipBuilt)）⇒ 甲-隐 这一支被打掉，75% 的主力素材还是用不了")
    try context.save()
    let built = existing.segments.first { $0.mixInternalWholeClip }
    #expect(built != nil, "补出来的那条没带内部段标记 ⇒ 它会直接混进用户的分镜素材库")
    #expect(built.map { WholeClipShape.isWholeClip(
              segments: [WholeClipSegmentShape(startTime: $0.startTime, endTime: $0.endTime)],
              videoDuration: existing.duration) } == true,
            "补出来的那条没覆盖全片 ⇒ 混剪照样拿不到整片")
    #expect(existing.displayableSegments.count == 1,
            "分镜素材库该只看见用户那一条（可显示数实得 \(existing.displayableSegments.count)）")

    let candidate = FolderMixCandidate(identityKey: file.path, category: "卖点",
                                       name: file.lastPathComponent, path: file.path,
                                       duration: 12, byteSize: 4096)
    let vm = FolderMixViewModel()
    let outcome = FolderMixLibraryJoin.resolve(
        candidatesByCategory: ["卖点": [candidate]], ingested: report.ingested,
        shapes: vm.rowShapes(for: report.ingested, context: context,
                             missingIDs: vm.availabilityReading(for: report.ingested, context: context).missingIDs),
        failureCodeBySourcePath: [:])
    #expect(outcome.hitCount == 1 && outcome.noWholeClipCount == 0,
            "补建后仍报档 B ⇒ 接缝没打通（没找到 \(outcome.notIngestedCount)）")
}

@Test("JOIN-25 同一行重扫两次 ⇒ 只补一条，不许叠第二片（幂等钉住 D19 那条纪律）")
@MainActor
func backfillIsIdempotentAcrossRescans() async throws {
    let dir = try fjScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let container = try fjContainer()
    let context = container.mainContext
    let file = dir.appendingPathComponent("同款素材.mp4")
    try fjWrite(file, 4096)
    let copy = FileHelper.globalVideoDirectoryForReading.appendingPathComponent("present2.mp4")
    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try fjWrite(copy, 4096)

    let (project, existing) = try fjSeededWithStoryboard(context: context, category: "卖点",
                                                         localPath: copy.path, duration: 12,
                                                         contentHash: try #require(ClipIngestService.computeFileHash(path: file.path)))
    let first = await ClipIngestService.importClips(urls: [file], to: project, source: .selfShot,
                                                    context: context, committer: SegmentCommitter(),
                                                    ffmpeg: FFmpegRunner(), hooks: ClipIngestHooks())
    try context.save()
    let afterFirst = existing.segments.count
    #expect(first.internalWholeClipBuilt == 1, "第一趟该补一条（实得 \(first.internalWholeClipBuilt)）")

    let second = await ClipIngestService.importClips(urls: [file], to: project, source: .selfShot,
                                                     context: context, committer: SegmentCommitter(),
                                                     ffmpeg: FFmpegRunner(), hooks: ClipIngestHooks())
    try context.save()
    #expect(second.internalWholeClipBuilt == 0,
            "第二趟又补了一条 ⇒ 混剪会出现同一素材的两个副本（W 族那条幂等纪律被打穿）")
    #expect(existing.segments.count == afterFirst,
            "段数从 \(afterFirst) 涨到 \(existing.segments.count)")
}

@Test("JOIN-26 库里那行的文件不在盘上 ⇒ 绝不补建（坏不许被提前伪装成可用）")
@MainActor
func missingCopyNeverGetsBackfilled() async throws {
    let dir = try fjScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let container = try fjContainer()
    let context = container.mainContext
    let file = dir.appendingPathComponent("同款素材.mp4")
    try fjWrite(file, 4096)

    // 库内路径指向一个不存在的文件（就是真机那 163 行的形状）
    let (project, existing) = try fjSeededWithStoryboard(context: context, category: "卖点",
                                                         localPath: FileHelper.globalVideoDirectoryForReading
                                                            .appendingPathComponent("gone/绝对不存在.mp4").path,
                                                         duration: 12,
                                                         contentHash: try #require(ClipIngestService.computeFileHash(path: file.path)))
    let report = await ClipIngestService.importClips(urls: [file], to: project, source: .selfShot,
                                                     context: context, committer: SegmentCommitter(),
                                                     ffmpeg: FFmpegRunner(), hooks: ClipIngestHooks())
    #expect(report.failed.isEmpty, "\(report.failed.map(\.reason))")
    #expect(report.internalWholeClipBuilt == 0,
            "给一条指向空文件的行补出段 = 把导出期的坏提前伪装成可用")
    try context.save()
    #expect(existing.segments.count == 1, "段数被偷偷涨了：实得 \(existing.segments.count)")

    let vm = FolderMixViewModel()
    let reading = vm.availabilityReading(for: report.ingested, context: context)
    let candidate = FolderMixCandidate(identityKey: file.path, category: "卖点",
                                       name: file.lastPathComponent, path: file.path,
                                       duration: 12, byteSize: 4096)
    let outcome = FolderMixLibraryJoin.resolve(
        candidatesByCategory: ["卖点": [candidate]], ingested: report.ingested,
        shapes: vm.rowShapes(for: report.ingested, context: context, missingIDs: reading.missingIDs),
        failureCodeBySourcePath: [:])
    if reading.degraded {
        // 数据根本身不可读 ⇒ 这一档报"查不了"（JOIN-23 那档），不许报成缺失
        #expect(reading.missingIDs.isEmpty, "degraded 时那颗契约明令缺失集为空")
    } else {
        #expect(outcome.resolution[candidate.identityKey]?.failureCode == .materialMissing,
                "文件不在盘上却没报 materialMissing ⇒ 归因又飘回『缺个段』")
    }
}
