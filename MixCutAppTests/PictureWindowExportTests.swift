import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// PWE · 画面窗口在**导出建输入**这一段的真实行为（B 块 ③）
//
// ## 为什么必须有这一组
//
// B-2 把超字闸的基准从"分镜时长"换成"画面可续容量"之后，"窗口比分镜长"这种数据
// 第一次成为可能 —— 而落地前**没有任何一条判据跑过它**：Core 那 19 格测的是派生函数，
// 它们看不见 `DubExportService` 到底把什么数字塞进了 spec 的每一段。
//
// ## 一条被本组判据反过来救掉的缺陷（2026-11-05）
//
// 第一版 BR-4 断言的是"段1 接长到 [0,200) 与段2 的 [100,200) 各自独立、互不影响" ——
// 那不是正确行为，那是**同一段源画面在成片里连播两遍**。一条源视频会被切成多个分镜
// （导入即切分，本产品的常态），所以"往源片后面续帧"的天花板通常不是源片末尾，
// 而是**下一格分镜的脸**。现在由 `Segment.nextSameSourceStartFrame` 供这个上界，
// 生成侧与导出侧共用（Core 侧 PW-18／PW-19 钉，这里 BR-4／BR-4b 钉）。
//
// ## 台架与边界
//   · 自建**内存容器**，绝不打开用户的库；每条用例自己 new 一颗；
//   · `pweGraph` 必须把 `ModelContainer` 一起交回调用方并显式续命 —— 内存容器一释放，
//     它撑着的 `ModelContext` 与所有 @Model 对象全部失效，症状是"每条用例都失败、
//     却看不出为什么"（对象看着还在，Swift 也不报错）。本文件第一版就栽在这里。
//   · BR-1…BR-4b、BR-6 **不 spawn** ffmpeg：建输入只查文件存在性
//     （`FileHelper.isMaterialFilePresent`），时长读库里的字段而不是实测 ⇒ 假字节文件就够，
//     因此不需要进 `withFFmpegBench`。
//   · 只有 BR-5 真渲染 ⇒ 整条 body 包在 `withFFmpegBench` 里（跨 suite 串行闸）。
//   · BR-5 刻意**不设** `MIXCUT_DEBUG_APP_SUPPORT_ROOT`：那颗变量是进程级的，而 Swift Testing
//     跨 suite 并行 —— 用例跑动期间全进程碰 `FileHelper` 的判据都会被指到本用例的临时目录，
//     `defer` 还原只治退出之后。实测一次设它红 14 条，红的全是隔壁文件。
//
// ## 非空洞性
//   · 导出若仍按 `ep.endFrame`（分镜原区间）裁 ⇒ BR-1、BR-5 当场红（KA 刀实跑取证）；
//   · "装不下"改成静默缩短或不拦 ⇒ BR-2、BR-4 红；
//   · 窗口无条件外扩 ⇒ BR-3 红（专防 BR-1 恒真）；
//   · 天花板忽略同素材兄弟分镜 ⇒ BR-4/BR-4b 红。
// ============================================================================

private func pweScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pwe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func pweFile(_ dir: URL, name: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)   // 只过存在性检查，不是真容器
    return url.path
}

private func pweDuration(_ ff: FFmpegRunner, _ path: String) async throws -> Double {
    let out = try await ff.runProbe(arguments: ["-v", "error", "-show_entries", "format=duration",
                                               "-of", "csv=p=0", path])
    guard let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw CocoaError(.fileReadCorruptFile)   // 量不到＝台架坏了：红给它看，不许当跳过
    }
    return d
}

/// 量**某一条流**的时长（`v:0` / `a:0`）。
///
/// 为什么容器时长不够用：配音是 8s，就算画面只到 6s，容器时长照样报 8s ——
/// 那种读数证明不了空镜有没有真播进去（BR-10 要的正是这一格）。量不到照样抛，
/// 不许把"读不出来"当成"通过"。
private func pweStreamDuration(_ ff: FFmpegRunner, _ path: String, stream: String) async throws -> Double {
    let out = try await ff.runProbe(arguments: ["-v", "error", "-select_streams", stream,
                                               "-show_entries", "stream=duration",
                                               "-of", "csv=p=0", path])
    guard let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return d
}

/// 对象图：1 条源视频 + 若干分镜（**区间显式给**，"下一格贴不贴"正是这些判据的主题）
/// + 每格一个已生成的配音 + 可选的窗口起点手改覆盖。
@MainActor
private func pweGraph(videoPath: String, dubPaths: [String], videoDuration: Double,
                      ranges: [(start: Double, end: Double)], dubDurations: [Double],
                      startOverrides: [Int?] = [],
                      width: Int, height: Int,
                      slotTag: SemanticType? = nil,
                      projectMainVideo: Bool = false,
                      broll: [(path: String, duration: Double, start: Double, end: Double, fps: Double)] = []) throws -> (MixScheme, ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let fps = 25.0

    let video = Video(name: "PWE-临时视频", localPath: videoPath)
    video.duration = videoDuration
    video.fps = fps
    video.width = width
    video.height = height
    ctx.insert(video)

    let scheme = MixScheme(name: "PWE-临时方案")
    ctx.insert(scheme)

    for (i, range) in ranges.enumerated() {
        let segment = Segment(segmentIndex: String(format: "seg_%03d", i + 1),
                              startTime: range.start, endTime: range.end,
                              text: "原台词 \(i)",
                              semanticTypes: slotTag.map { [.painPoint, $0] } ?? [.painPoint],
                              positionType: i == 0 ? .opening : .middle)
        segment.startFrame = FrameTime.frame(seconds: range.start, fps: fps)
        segment.endFrame = FrameTime.frame(seconds: range.end, fps: fps)
        segment.video = video
        ctx.insert(segment)

        let dub = SegmentDub(segment: segment, voiceId: "v1", voiceProvider: "cosyvoice",
                             textVariantIndex: 0, rewrittenText: "改写台词 \(i)")
        dub.audioDuration = dubDurations[i]
        dub.audioFilePath = dubPaths[i]
        dub.alignmentPolicy = .fixedRate
        ctx.insert(dub)
        segment.segmentDubs.append(dub)

        let slot = SchemeSegment(position: i + 1)
        ctx.insert(slot)
        slot.scheme = scheme
        slot.segment = segment
        slot.selectedSegmentDubId = dub.id
        if i < startOverrides.count { slot.windowStartOverrideFrame = startOverrides[i] }
    }

    // 空镜供给：**另起一条素材**挂进同一个项目，且不进方案（方案内已用的段不许当供给）。
    // 挂项目一律走 `ProjectVideo.associate`（幂等入口），裸 insert 会造出重复挂载行。
    if !broll.isEmpty || projectMainVideo {
        let project = Project(name: "PWE-临时项目")
        ctx.insert(project)
        _ = ProjectVideo.associate(project: project, video: video, in: ctx)
        for (i, b) in broll.enumerated() {
            let bVideo = Video(name: "PWE-空镜\(i)", localPath: b.path)
            bVideo.duration = b.duration
            bVideo.fps = b.fps
            bVideo.width = width
            bVideo.height = height
            ctx.insert(bVideo)
            _ = ProjectVideo.associate(project: project, video: bVideo, in: ctx)

            let bSeg = Segment(segmentIndex: String(format: "brl_%03d", i + 1),
                               startTime: b.start, endTime: b.end,
                               text: "", semanticTypes: [.emptyShot], positionType: .middle)
            bSeg.startFrame = FrameTime.frame(seconds: b.start, fps: b.fps)
            bSeg.endFrame = FrameTime.frame(seconds: b.end, fps: b.fps)
            bSeg.video = bVideo
            ctx.insert(bSeg)
        }
        scheme.project = project
    }
    try ctx.save()
    // ⚠️ 容器跟着对象一起交回：内存版 ModelContainer 一释放，它撑着的一切就空了。
    return (scheme, container)
}

/// 只走到"建导出输入"，不渲染。假字节文件就够（见文件头作用面）。
/// `broll` 非空 = 在项目里另挂若干条「空镜」素材（不进方案），用来测差额承接。
@MainActor
private func pweSpecs(videoDuration: Double, ranges: [(start: Double, end: Double)],
                      dubDurations: [Double], startOverrides: [Int?] = [],
                      slotTag: SemanticType? = nil,
                      broll: [(duration: Double, start: Double, end: Double, fps: Double)] = [],
                      dir: URL) throws -> [DubSegmentSpec] {
    let src = try pweFile(dir, name: "src.mov")
    let dubs = try dubDurations.indices.map { try pweFile(dir, name: "dub\($0).m4a") }
    let paths = try broll.indices.map { try pweFile(dir, name: "broll\($0).mov") }
    let (scheme, container) = try pweGraph(videoPath: src, dubPaths: dubs,
                                           videoDuration: videoDuration, ranges: ranges,
                                           dubDurations: dubDurations, startOverrides: startOverrides,
                                           width: 1080, height: 1920, slotTag: slotTag,
                                           broll: zip(broll, paths).map { b, p in
                                            (path: p, duration: b.duration, start: b.start,
                                             end: b.end, fps: b.fps)
                                           })
    let specs = try DubExportInput.from(scheme: scheme).segments
    withExtendedLifetime(container) {}     // 显式续命：别在 from() 前后被释放
    return specs
}

@Suite("PWE · 窗口进导出输入")
struct PictureWindowExportTests {

    @Test("BR-1 源片最后一段：配音比它长 ⇒ 画面真的接长")
    @MainActor
    func lastSegmentOfSourceExtends() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 只有一格 [0,4s)，dub 8s，源片 20s ⇒ 后面 16 秒是空地 ⇒ 窗口 [0,200)
        let specs = try pweSpecs(videoDuration: 20, ranges: [(0, 4)], dubDurations: [8.0], dir: dir)
        let spec = try #require(specs.first)
        #expect(spec.startFrame == 0, "起点仍是分镜起点（计划 B 块第 12 条）")
        #expect(spec.endFrame == 200,
                "画面没跟着配音接长 ⇒ B-3a 的窗口没进 spec（分镜原区间只有 100 帧）")
    }

    @Test("BR-2 接满源片末尾仍不足 ⇒ 建输入阶段就抛，且把差额与天花板都报出来")
    @MainActor
    func shortfallThrowsBeforeRendering() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 分镜 [0,4s)、dub 8s，源片只有 6s ⇒ 容量 150 帧 < 需求 200 帧 ⇒ 差 50 帧 = 2s
        var thrown: DubExportInput.BuildError?
        do {
            _ = try pweSpecs(videoDuration: 6, ranges: [(0, 4)], dubDurations: [8.0], dir: dir)
        } catch let e as DubExportInput.BuildError { thrown = e }
        catch { Issue.record("抛的不是 BuildError，而是 \(error) ⇒ 归因会跑偏") }
        guard case .undeliverableWindow(let list)? = thrown else {
            Issue.record("装不下却没在建输入阶段拒绝（实得 \(String(describing: thrown))）⇒ 会走到渲染，中途失败留下只有半条内容的 mp4（moov 事故那一类）"); return
        }
        #expect(list.count == 1 && list[0].position == 1, "拒绝清单没点名到那一段：\(list)")
        #expect(list[0].reason.contains("可续画面"), "文案没说是'可续画面'不够：\(list[0].reason)")
        #expect(list[0].reason.contains("2.00"), "差额秒数没报出来（应为 2.00s）：\(list[0].reason)")
        #expect(list[0].reason.contains("6.00"), "没告诉用户画面最多取到几秒（应为 6.00s）：\(list[0].reason)")
    }

    @Test("BR-3 反向对照：配音不比分镜长时窗口必须**不**扩（证 BR-1 不是无条件放大）")
    @MainActor
    func equalLengthDoesNotExtend() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let specs = try pweSpecs(videoDuration: 20, ranges: [(0, 4)], dubDurations: [4.0], dir: dir)
        #expect(specs.first?.endFrame == 100,
                "配音只有 4s 也把画面拉长 ⇒ 窗口成了无条件外扩，会把所有成片都变长")
    }

    @Test("BR-4 下一格紧贴时不许续进它的画面 —— 宁可拒，也不能同一段播两遍")
    @MainActor
    func siblingImmediatelyAfterBlocksExtension() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 段1 [0,4s) 与段2 [4,8s) 紧贴；段1 的 dub 8s ⇒ 可续余量为 0 ⇒ 应拒
        var thrown: DubExportInput.BuildError?
        do {
            _ = try pweSpecs(videoDuration: 60, ranges: [(0, 4), (4, 8)],
                             dubDurations: [8.0, 2.0], dir: dir)
        } catch let e as DubExportInput.BuildError { thrown = e }
        catch { Issue.record("\(error)") }
        guard case .undeliverableWindow(let list)? = thrown else {
            Issue.record("段1 竟被放行 —— 若它接长到 [0,200) 就吃进段2 的 [100,200)，同一段源画面在成片里连播两遍（第一版 BR-4 正是把这个形状当正确断言钉住的）；实得 \(String(describing: thrown))"); return
        }
        #expect(list.count == 1 && list[0].position == 1, "只该拦那一段，实得 \(list)")
    }

    @Test("BR-4b 中间有空档时只续到空档尽头，剩下的如实报差额")
    @MainActor
    func extensionStopsAtSiblingBoundary() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 段1 [0,4s)=100 帧 与段2 [6,10s) 之间只有 2s（50 帧）空地；段1 dub 8s=200 帧
        // ⇒ 上界被段2 卡在 150 帧：可续到 6.00s、仍差 2.00s ⇒ 应拦，且报出来的天花板是 6.00s
        //（不是源片末尾 60s，也不是刚好够用的 8.00s —— 上一版夹具正好凑够，白跑一轮）
        var thrown: DubExportInput.BuildError?
        do {
            _ = try pweSpecs(videoDuration: 60, ranges: [(0, 4), (6, 10)],
                             dubDurations: [8.0, 2.0], dir: dir)
        } catch let e as DubExportInput.BuildError { thrown = e }
        catch { Issue.record("\(error)") }
        guard case .undeliverableWindow(let list)? = thrown else {
            Issue.record("空档只够一半，应该仍被拦；实得 \(String(describing: thrown))"); return
        }
        #expect(list.count == 1 && list[0].position == 1, "只该拦段1，实得 \(list)")
        // 报出来的天花板必须是 6.00s（[0,150)，即下一格的起点）而不是源片末尾 60s
        #expect(list[0].reason.contains("6.00"),
                "可续上界没让位给下一格分镜（应为 6.00s）：\(list[0].reason)")
        #expect(list[0].reason.contains("2.00"), "差额应是 2.00s：\(list[0].reason)")
        #expect(!list[0].reason.contains("60.00"),
                "上界取成了源片末尾 ⇒ 会直接盖住后面的分镜：\(list[0].reason)")
    }

    @Test("BR-6 起点手改覆盖：往前挪整段平移，往后挪被夹回且不改长度")
    @MainActor
    func startOverrideShiftsTheWindowOnlyEarlier() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 单段 [10,14s)（起点 250 帧），dub 4s ⇒ 本就不扩；覆盖 190 ⇒ 起点 190、长度仍 100 帧
        let earlier = try pweSpecs(videoDuration: 60, ranges: [(10, 14)], dubDurations: [4.0],
                                   startOverrides: [190], dir: dir)
        #expect(earlier[0].startFrame == 190 && earlier[0].endFrame == 290,
                "往前挪没生效，或顺手改了画面长度 ⇒ 起点是平移不是缩放")
        // 往后挪（> 分镜起点）⇒ 夹回 250，等于没改
        let later = try pweSpecs(videoDuration: 60, ranges: [(10, 14)], dubDurations: [4.0],
                                 startOverrides: [300], dir: dir)
        #expect(later[0].startFrame == 250 && later[0].endFrame == 350,
                "往后挪被采纳 ⇒ 画面盖进别的区间，成片出现重复段落")
    }

    @Test("BR-5 真渲染：4 秒分镜配 8 秒配音，成片必须接近 8 秒（画面真接长了）")
    @MainActor
    func windowExtendsInTheRealRender() async throws {
        // 会 spawn ffmpeg ⇒ 整条 body 必须进 withFFmpegBench（`.serialized` 只管组内；
        // 本仓实测：漏入闸的症状是红点会移动到隔壁文件、零诊断输出）。
        try await withFFmpegBench("BR-5 窗口接长的真渲染") {
            let dir = try pweScratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            // 这里**不设** `MIXCUT_DEBUG_APP_SUPPORT_ROOT`，理由见文件头（进程级 + 跨 suite 并行）。

            let ff = FFmpegRunner()
            let src = dir.appendingPathComponent("src.mp4").path
            // 20s、1080x1920、带可听音频；只此一格分镜 ⇒ 后面 16 秒是空地，可续
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "testsrc=size=1080x1920:rate=25:duration=20",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=20",
                "-pix_fmt", "yuv420p", "-shortest", "-y", src], timeoutSeconds: 300)
            let dubPath = dir.appendingPathComponent("dub.m4a").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "sine=frequency=660:sample_rate=44100:duration=8",
                "-c:a", "aac", "-b:a", "96k", "-y", dubPath], timeoutSeconds: 300)

            let (scheme, container) = try pweGraph(videoPath: src, dubPaths: [dubPath],
                                                   videoDuration: 20, ranges: [(0, 4)],
                                                   dubDurations: [8.0],
                                                   width: 1080, height: 1920)
            let input = try DubExportInput.from(scheme: scheme)
            #expect(input.segments.first?.endFrame == 200,
                    "进渲染之前窗口就不对 ⇒ 后面量到的时长与 B-3a 无关")

            let out = dir.appendingPathComponent("out.mp4").path
            var config = ExportConfig()
            config.resolution = .p1080
            try await DubExportService().export(input: input, outputPath: out, config: config)
            withExtendedLifetime(container) {}   // 渲染期间容器必须活着

            let measured = try await pweDuration(ff, out)
            // 画面若仍按分镜裁（4s），成片只会有 4 秒量级；接长之后应是 8 秒。
            #expect(measured > 7.4,
                    "成片只有 \(String(format: "%.2f", measured))s ⇒ 画面没接长或配音被截")
            #expect(measured < 8.9,
                    "成片 \(String(format: "%.2f", measured))s 远超配音长度 ⇒ 多出来的是别处补的空挡")
        }
    }

    // MARK: 差额承接（插空镜）—— 2026-11-05 拍的是这一档

    @Test("BR-7 池子够用 ⇒ 不再拦，差额由空镜垫满，时长闸读数含空镜")
    @MainActor
    func brollCoversTheShortfall() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 源片只有 6s ⇒ 画面最多取到 6.00s；配音 8s ⇒ 差 2.00s；空镜 4s 够用
        let specs = try pweSpecs(videoDuration: 6, ranges: [(0, 4)], dubDurations: [8.0],
                                 broll: [(duration: 4, start: 0, end: 4, fps: 25)], dir: dir)
        let s = try #require(specs.first)
        #expect(s.fillPieces.count == 1, "接得满却仍拦/仍不插 ⇒ 承接没接进建输入这一段")
        #expect(s.fillPieces[0].frames == 50, "2.00s@25fps 必须截 50 帧（多一帧都比配音长）")
        #expect(s.fillPieces[0].videoPath.contains("broll0.mov"), "插进去的不是那条空镜素材")
        #expect(abs(s.deliverySeconds - 8.0) < 0.001,
                "交付时长闸读的必须是 画面 6s + 空镜 2s；只算窗口的话 4…300s 那条闸会低估片长变假绿")
    }

    @Test("BR-8 池子不够 ⇒ 仍然拦，且文案说清空镜只垫得起几秒")
    @MainActor
    func insufficientBrollStillBlocks() throws {
        let dir = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 差 2.00s，空镜只有 1.00s ⇒ 不许用半段空镜出一条配音尾巴没垫满的片子
        var thrown: DubExportInput.BuildError?
        do {
            _ = try pweSpecs(videoDuration: 6, ranges: [(0, 4)], dubDurations: [8.0],
                             broll: [(duration: 1, start: 0, end: 1, fps: 25)], dir: dir)
        } catch let e as DubExportInput.BuildError { thrown = e }
        catch { Issue.record("抛的不是 BuildError：\(error)") }
        guard case .undeliverableWindow(let list)? = thrown else {
            Issue.record("空镜不够却放行 ⇒ 会渲出口播播完画面还差的片子"); return
        }
        #expect(list[0].reason.contains("只垫得起 1.00"), "没告诉用户空镜垫了多少：\(list[0].reason)")
        #expect(list[0].reason.contains("可续画面"), "没说清是画面不够：\(list[0].reason)")
    }

    @Test("BR-9 供给侧两条剔除：同源重叠的画面、本片已在用的段，都不许当空镜")
    @MainActor
    func supplySideExclusionsHold() throws {
        // (a) 供给与本格窗口同源重叠 ⇒ 剔掉 ⇒ 池空 ⇒ 仍拦
        let dirA = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dirA) }
        let src = try pweFile(dirA, name: "src.mov")
        let dub = try pweFile(dirA, name: "dub0.m4a")
        let (schemeA, cA) = try pweGraph(videoPath: src, dubPaths: [dub], videoDuration: 6,
                                         ranges: [(0, 4)], dubDurations: [8.0],
                                         width: 1080, height: 1920,
                                         broll: [(path: src, duration: 6, start: 2, end: 4, fps: 25)])
        withExtendedLifetime(cA) {}
        do {
            _ = try DubExportInput.from(scheme: schemeA)
            Issue.record("同一条源视频里窗口已经取到的帧，又被当作空镜插进来 ⇒ 成片里同一段画面播两遍")
        } catch is DubExportInput.BuildError {}

        // (b) 那条「空镜」正是本片在用的分镜 ⇒ 归占用账/在片过滤管，不许自我垫
        let dirB = try pweScratch()
        defer { try? FileManager.default.removeItem(at: dirB) }
        let srcB = try pweFile(dirB, name: "src.mov")
        let dubB = try pweFile(dirB, name: "dub0.m4a")
        let (schemeB, cB) = try pweGraph(videoPath: srcB, dubPaths: [dubB], videoDuration: 6,
                                         ranges: [(0, 4)], dubDurations: [8.0],
                                         width: 1080, height: 1920,
                                         slotTag: .emptyShot, projectMainVideo: true)
        withExtendedLifetime(cB) {}
        do {
            _ = try DubExportInput.from(scheme: schemeB)
            Issue.record("方案里已在用的分镜被当成自己的空镜 ⇒ 同一段画面连播两遍（纪律 2）")
        } catch is DubExportInput.BuildError {}
    }

    @Test("BR-10 真渲染：空镜真的播进成片 —— 视频流跟着配音走满")
    @MainActor
    func brollActuallyRenders() async throws {
        // 会 spawn ffmpeg ⇒ 整条 body 必须进 withFFmpegBench（同 BR-5 的理由）。
        try await withFFmpegBench("BR-10 空镜承接的真渲染") {
            let dir = try pweScratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let ff = FFmpegRunner()
            // 主素材 6s（testsrc），空镜 4s（smptebars）—— 两种图样，视频流长度就是判据
            let src = dir.appendingPathComponent("src.mp4").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "testsrc=size=1080x1920:rate=25:duration=6",
                "-pix_fmt", "yuv420p", "-y", src], timeoutSeconds: 300)
            let brl = dir.appendingPathComponent("broll0.mov").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "smptebars=size=1080x1920:rate=25:duration=4",
                "-pix_fmt", "yuv420p", "-y", brl], timeoutSeconds: 300)
            let dubPath = dir.appendingPathComponent("dub.m4a").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "sine=frequency=660:sample_rate=44100:duration=8",
                "-c:a", "aac", "-b:a", "96k", "-y", dubPath], timeoutSeconds: 300)

            let (scheme, container) = try pweGraph(videoPath: src, dubPaths: [dubPath],
                                                   videoDuration: 6, ranges: [(0, 4)],
                                                   dubDurations: [8.0],
                                                   width: 1080, height: 1920,
                                                   broll: [(path: brl, duration: 4, start: 0, end: 4, fps: 25)])
            let input = try DubExportInput.from(scheme: scheme)
            let out = dir.appendingPathComponent("out.mp4").path
            var config = ExportConfig()
            config.resolution = .p1080
            try await DubExportService().export(input: input, outputPath: out, config: config)
            withExtendedLifetime(container) {}

            // ⚠️ 量**视频流**而不是容器时长：音频本来就是 8s，容器时长量不出画面有没有垫满。
            let videoSeconds = try await pweStreamDuration(ff, out, stream: "v:0")
            #expect(videoSeconds > 7.4,
                    "视频流只有 \(String(format: "%.2f", videoSeconds))s ⇒ 空镜没播进去（源片 6s 就到头了）")
            #expect(videoSeconds < 8.9,
                    "视频流 \(String(format: "%.2f", videoSeconds))s 比配音还长 ⇒ 空镜多垫了")
        }
    }
}
