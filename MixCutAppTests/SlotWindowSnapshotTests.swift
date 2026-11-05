import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// SN · 槽位画面窗口投影（B 块 ①；对应测试覆盖方案 §6 的 P0/P1 那批）
//
// ## 为什么这批测试必须存在
//
// 窗口的派生口径住在 `PictureWindowPolicy`（PW-1…PW-19 已钉），导出侧的落地住在
// `PictureWindowExportTests`（BR-1…BR-6 已钉）。中间那层——**把派生量翻译成视图可直接
// 渲染的值**——原本没有任何判据：谁都能在视图里再算一遍，算错了没人红。
// 这批就是把"翻译层"钉住，同时用 SN-12 钉住"只有一个写入口"。
//
// ## 台架与边界
//   · 自建**内存容器**，绝不打开用户的库；容器与对象一起留在用例作用域内
//     （内存容器一释放，它撑着的上下文就空了 —— 这个坑本轮已踩过一次）；
//   · `hasDub` 的语义是"这一槽绑定了配音且落过音频路径"，**不查文件是否存在**：
//     文件缺失由导出侧的 `chosenDubHasAudio` 裁决，投影不做 IO（值型投影不许有副作用）；
//   · 不 spawn 任何进程 ⇒ 不需要 `withFFmpegBench`。
// ============================================================================

private func snScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 一颗最小槽位图：1 视频 + n 段 + 可选配音 + 可选方案与「空镜」供给。
/// 返回 (vm, slots, segments, scheme, project, container)。
@MainActor
private func snGraph(fps: Double = 25,
                     videoDuration: Double = 60,
                     ranges: [(start: Double, end: Double)] = [(0, 4)],
                     dubSeconds: [Double?] = [nil],
                     broll: [(fps: Double, start: Double, end: Double)] = [],
                     dir: URL) throws -> (SchemeViewModel, [SchemeSegment], [Segment], MixScheme, Project?, ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext

    let video = Video(name: "SN-临时视频", localPath: dir.appendingPathComponent("src.mov").path)
    video.duration = videoDuration
    video.fps = fps
    video.width = 1080
    video.height = 1920
    ctx.insert(video)

    let scheme = MixScheme(name: "SN-临时方案")
    ctx.insert(scheme)

    var segs: [Segment] = []
    var slots: [SchemeSegment] = []
    for (i, range) in ranges.enumerated() {
        let segment = Segment(segmentIndex: String(format: "seg_%03d", i + 1),
                              startTime: range.start, endTime: range.end,
                              text: "原台词 \(i)", semanticTypes: [.painPoint],
                              positionType: i == 0 ? .opening : .middle)
        segment.startFrame = FrameTime.frame(seconds: range.start, fps: fps)
        segment.endFrame = FrameTime.frame(seconds: range.end, fps: fps)
        segment.video = video
        ctx.insert(segment)
        segs.append(segment)

        let slot = SchemeSegment(position: i + 1)
        ctx.insert(slot)
        slot.segment = segment
        slot.scheme = scheme
        slots.append(slot)

        if i < dubSeconds.count, let secs = dubSeconds[i] {
            let dub = SegmentDub(segment: segment, voiceId: "v1", voiceProvider: "cosyvoice",
                                 textVariantIndex: 0, rewrittenText: "改写台词 \(i)")
            dub.audioDuration = secs
            dub.audioFilePath = dir.appendingPathComponent("dub\(i).m4a").path
            dub.alignmentPolicy = .fixedRate
            ctx.insert(dub)
            segment.segmentDubs.append(dub)
            slot.selectedSegmentDubId = dub.id
        }
    }

    // 「空镜」供给：**另起一条素材**挂进同一个项目（不进方案），用来测差额承接
    var project: Project? = nil
    if !broll.isEmpty {
        let p = Project(name: "SN-临时项目")
        ctx.insert(p)
        _ = ProjectVideo.associate(project: p, video: video, in: ctx)
        for (i, b) in broll.enumerated() {
            let bVideo = Video(name: "SN-空镜\(i)",
                               localPath: dir.appendingPathComponent("broll\(i).mov").path)
            bVideo.duration = 20
            bVideo.fps = b.fps
            bVideo.width = 1080
            bVideo.height = 1920
            ctx.insert(bVideo)
            _ = ProjectVideo.associate(project: p, video: bVideo, in: ctx)
            let bSeg = Segment(segmentIndex: String(format: "brl_%03d", i + 1),
                               startTime: b.start, endTime: b.end,
                               text: "", semanticTypes: [.emptyShot], positionType: .middle)
            bSeg.startFrame = FrameTime.frame(seconds: b.start, fps: b.fps)
            bSeg.endFrame = FrameTime.frame(seconds: b.end, fps: b.fps)
            bSeg.video = bVideo
            ctx.insert(bSeg)
        }
        scheme.project = p
        project = p
    }
    try ctx.save()
    return (SchemeViewModel(), slots, segs, scheme, project, container)
}

@Suite("SN · 槽位窗口投影")
struct SlotWindowSnapshotTests {

    @Test("SN-01 没配音的槽：hasDub=false，窗口等于画面本身")
    @MainActor
    func noDubIsALegalState() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (vm, slots, segs, _, _, container) = try snGraph(dir: dir)
        let w = try #require(vm.slotWindow(slots[0], segment: segs[0], project: nil))
        withExtendedLifetime(container) {}
        #expect(w.hasDub == false)
        #expect(w.isAuto)
        #expect(w.startFrame == 0 && w.endFrame == 100, "无配音时窗口必须等于分镜原区间")
        #expect(w.lengthSource == .shot)
        #expect(w.shortfallFrames == 0)
        #expect(w.clampedFrom == nil)
    }

    @Test("SN-02／SN-03 长度来源：配音短 ⇒ .shot；配音长 ⇒ .dub 且窗口接到源片末尾")
    @MainActor
    func lengthSourceFollowsTheLongerSide() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (shortVM, shortSlots, shortSegs, _, _, c1) = try snGraph(dubSeconds: [2.0], dir: dir)
        let short = try #require(shortVM.slotWindow(shortSlots[0], segment: shortSegs[0], project: nil))
        withExtendedLifetime(c1) {}
        #expect(short.hasDub)
        #expect(short.lengthSource == .shot, "配音 2s < 画面 4s，长度该由画面决定")
        #expect(short.endFrame == 100)

        let (longVM, longSlots, longSegs, _, _, c2) = try snGraph(dubSeconds: [8.0], dir: dir)
        let long = try #require(longVM.slotWindow(longSlots[0], segment: longSegs[0], project: nil))
        withExtendedLifetime(c2) {}
        #expect(long.lengthSource == .dub)
        #expect(long.endFrame == 200, "8s@25fps=200 帧，单段素材后面是空地，应接到 200")
        #expect(long.ceilingSource == .sourceEnd)
        #expect(long.shortfallFrames == 0)
    }

    @Test("SN-04／SN-05 覆盖口径：往后挪被夹回并回传原值；恰等起点算自动")
    @MainActor
    func overrideClampIsReported() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (vm, slots, segs, _, _, container) = try snGraph(dubSeconds: [4.0], dir: dir)
        defer { withExtendedLifetime(container) {} }

        vm.setWindowStartOverride(slots[0], frame: 50)
        let clamped = try #require(vm.slotWindow(slots[0], segment: segs[0], project: nil))
        #expect(clamped.startFrame == 0, "往后挪必须夹回画面起点")
        #expect(clamped.clampedFrom == 50, "被夹了却不报原值 ⇒ 界面上说不清'你填的不作数'")
        #expect(clamped.isAuto == false)

        vm.setWindowStartOverride(slots[0], frame: 0)
        let equal = try #require(vm.slotWindow(slots[0], segment: segs[0], project: nil))
        #expect(equal.clampedFrom == nil, "恰等起点不算被夹")
        #expect(equal.isAuto, "填了与自动相同的值，应视为自动")
    }

    @Test("SN-06 天花板来源：紧贴下一格时改报 .nextSegment，且差额立刻出现")
    @MainActor
    func ceilingSourceSwitchesToNeighbour() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 段1 [0,4s)，段2 [4,8s) 紧贴；段1 配音 8s ⇒ 可续余量 0
        let (vm, slots, segs, _, _, container) = try snGraph(ranges: [(0, 4), (4, 8)],
                                                       dubSeconds: [8.0, 2.0], dir: dir)
        let w = try #require(vm.slotWindow(slots[0], segment: segs[0], project: nil))
        withExtendedLifetime(container) {}
        #expect(w.ceilingSource == .nextSegment, "紧贴下一格时天花板不是源片末尾")
        #expect(w.roomFrames == 0)
        #expect(w.shortfallFrames > 0, "装不下必须在投影里就能看到")
        #expect(w.endFrame == 100, "不许续进下一格的画面")
    }

    @Test("SN-07 差额按容差折算：恰等容差报 0，超一帧才报")
    @MainActor
    func shortfallIsToleranceAdjusted() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 段1 [0,4s)=100 帧，段2 从 4.16s=104 帧起 ⇒ 天花板 104（余 4 帧）
        // 配音 4.16s=104 帧 ⇒ 零差额；4.20s=105 ⇒ 差 1 帧 = 容差 ⇒ 报 0；4.24s=106 ⇒ 差 2 ⇒ 报 2
        let cases: [(Double, Int)] = [(4.16, 0), (4.20, 0), (4.24, 2)]
        for (dubSecs, expected) in cases {
            let (vm, slots, segs, _, _, container) = try snGraph(ranges: [(0, 4), (4.16, 8)],
                                                           dubSeconds: [dubSecs, 2.0], dir: dir)
            let w = try #require(vm.slotWindow(slots[0], segment: segs[0], project: nil))
            withExtendedLifetime(container) {}
            #expect(w.shortfallFrames == expected,
                    "配音 \(dubSecs)s 的差额应为 \(expected) 帧，实得 \(w.shortfallFrames)")
        }
    }

    @Test("SN-09 前提不成立 ⇒ nil（不猜、不灰显）")
    @MainActor
    func badPrerequisitesYieldNil() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (vm, slots, segs, _, _, container) = try snGraph(fps: 0, dubSeconds: [4.0], dir: dir)
        withExtendedLifetime(container) {}
        #expect(vm.slotWindow(slots[0], segment: segs[0], project: nil) == nil, "fps 非正还给投影 ⇒ 会把 0 当帧率算出垃圾")
    }

    @Test("SN-15 步进口径：往前 1 帧落覆盖；走回自动起点存 nil；不许越过该格起点")
    @MainActor
    func steppingNeverPassesTheShotStart() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (vm, slots, segs, _, _, container) = try snGraph(ranges: [(2, 6)], dubSeconds: [4.0], dir: dir)
        defer { withExtendedLifetime(container) {} }

        vm.stepWindowStart(slots[0], segment: segs[0], project: nil, by: -1)
        #expect(slots[0].windowStartOverrideFrame == 49, "往前一帧应落成显式覆盖（自动起点 2s@25fps=50）")
        let moved = try #require(vm.slotWindow(slots[0], segment: segs[0], project: nil))
        #expect(moved.startFrame == 49)
        #expect(moved.isAuto == false)

        vm.stepWindowStart(slots[0], segment: segs[0], project: nil, by: 1)
        #expect(slots[0].windowStartOverrideFrame == nil,
                "走回自动起点应存 nil，而不是一个与自动等价的数（否则'自动'永远关不掉）")

        vm.stepWindowStart(slots[0], segment: segs[0], project: nil, by: 1)
        #expect(slots[0].windowStartOverrideFrame == nil, "往后不许越过该格起点（会盖进下一格画面）")
    }

    @Test("SN-12 写口唯一：全仓只有 setWindowStartOverride 一处写 windowStartOverrideFrame")
    @MainActor
    func singleWriteSite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var hits: [String] = []
        let en = FileManager.default.enumerator(at: root.appendingPathComponent("MixCut"),
                                                includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])
        while let obj = en?.nextObject() {
            guard let url = obj as? URL, url.pathExtension == "swift" else { continue }
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in src.components(separatedBy: "\n").enumerated() {
                let s = line.trimmingCharacters(in: .whitespaces)
                // 只认**赋值**：`windowStartOverrideFrame == nil` 这种比较也以 "=" 开头，
                // 用子串判会把它算成写点（第一版本判据就是这么假红的）。
                guard !s.hasPrefix("//"),
                      s.range(of: #"windowStartOverrideFrame\s*=(?!=)"#, options: .regularExpression) != nil
                else { continue }
                hits.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(hits.count == 1,
                "窗口起点的写点应只有 VM 那一处，实得 \(hits) ⇒ 视图直接改字段会让'唯一写入口'变成纸面约定")
    }

    @Test("SN-16 差额由空镜垫满：投影报垫了几秒、接得住")
    @MainActor
    func brollCoversInProjection() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 主素材 6s ⇒ 画面最多取到 6.00s；配音 8s ⇒ 差 2.00s；项目里有一条 4s 的空镜
        let (vm, slots, segs, _, project, container) = try snGraph(
            videoDuration: 6, dubSeconds: [8.0], broll: [(fps: 25, start: 0, end: 4)], dir: dir)
        defer { withExtendedLifetime(container) {} }
        let w = try #require(vm.slotWindow(slots[0], segment: segs[0], project: project))
        #expect(w.shortfallFrames == 50, "2.00s@25fps 的差额必须是 50 帧")
        #expect(abs(w.brollSeconds - 2.0) < 0.001, "投影要能说清垫了几秒 —— 界面只能据它写文案")
        #expect(w.shortfallCovered, "池子够却报接不住 ⇒ 卡片会一直挂着「导出会被拦」这句谎话")
    }

    @Test("SN-17 反向对照：整条投影共用一本占用账，池子只够第一格时第二格必须报接不住")
    @MainActor
    func planSharesOneConsumptionLedger() throws {
        let dir = try snScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 两格各差 2.00s，项目里只有**一条** 2s 的空镜 ⇒ 只许第一格接得住
        let (vm, slots, segs, scheme, project, container) = try snGraph(
            videoDuration: 6, ranges: [(0, 4), (0, 4)], dubSeconds: [8.0, 8.0],
            broll: [(fps: 25, start: 0, end: 2)], dir: dir)
        defer { withExtendedLifetime(container) {} }
        let plan = vm.slotWindowPlan(for: scheme, project: project)
        let first = try #require(plan[slots[0].id])
        let second = try #require(plan[slots[1].id])
        #expect(first.shortfallCovered && abs(first.brollSeconds - 2.0) < 0.001)
        #expect(!second.shortfallCovered && second.brollSeconds == 0,
                "每格各自许诺整个池子 ⇒ 卡上显示接得住、导出却拦下来（两处口径分叉）")
        // 单格那颗不知道占用账，必须与整条那颗不同 —— 这条差异本身就是界面必须用 plan 的理由
        let single = try #require(vm.slotWindow(slots[1], segment: segs[1], project: project))
        #expect(single.shortfallCovered && !second.shortfallCovered,
                "单格投影与整条投影读数一样 ⇒ 占用账没生效，两处会给出同一个谎")
    }
}
