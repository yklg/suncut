import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// BDE · 空镜承接的**整片真出**（一条真成片，不是滤镜串断言）
//
// ## 为什么要有这一条
//
// BF 那批判的是纯函数，BR 那批判的是"建输入"这一段，BR-10 只渲了**一个槽位**。
// 用户问的是"能不能你帮我测试"——他要的是有一条能打开来看的片子，且证明：
//   ① 差额那几秒真的是**另一段画面**，不是把末帧冻在那儿（本仓明确拒过定格补尾）；
//   ② 多槽位 concat 在有插入画面时仍然成立（每个槽位的 `-i` 序号会因插入而整体后移）；
//   ③ 交付时长闸读的是"窗口 + 空镜"，不是只读窗口。
//
// ## 判据的实算依据（2026-11-05 现测，同一支 ffmpeg）
//   · 主素材 `testsrc` 1080x1920：YAVG ≈ 125.9 / 124.6（@5.0s / @1.0s）
//   · 空镜 `smptebars`：YAVG ≈ 96.5
//   ⇒ 两者相差约 29 个点，阈值取中间偏空镜侧：**接稳在 <110，主素材在 >115**。
//   若链子写错成"克隆末帧"，t=7s 读到的是主素材末帧（≈126）⇒ 当场红。
//
// ## 台架与边界
//   · 全程自建**内存容器**与 `/tmp` 素材，绝不碰用户的库；
//   · 产物 mp4 落在仓库 `.scratch/broll-demo/`（gitignored）并**保留**，
//     这样用户可以直接双击看；其余中间文件随临时目录清理；
//   · 会 spawn ffmpeg ⇒ 整条 body 进 `withFFmpegBench`。
// ============================================================================

/// 帧亮度均值（YAVG）—— 由 `signalstats,metadata=print:file=-` 打到 stdout。
///
/// ⚠️ 走 `run`（ffmpeg）而不是 `runProbe`：后者是 **ffprobe**，不认 `-vf/-frames:v`，
/// 拿它跑滤镜串会得到 exit 1（本轮第一次就是这么红的）。
private func bdeYavg(_ ff: FFmpegRunner, _ source: String, at seconds: Double) async throws -> Double {
    let data = try await ff.run(arguments: ["-v", "error", "-ss", String(format: "%.3f", seconds),
                                           "-i", source, "-map", "0:v:0", "-an",
                                           "-frames:v", "1", "-vf",
                                           "signalstats,metadata=print:file=-", "-f", "null", "-"],
                                timeoutSeconds: 120)
    let out = String(data: data, encoding: .utf8) ?? ""
    guard let found = out.range(of: "YAVG="),
          let value = Double(out[found.upperBound...].prefix(while: { !$0.isNewline && $0 != " " })) else {
        throw CocoaError(.fileReadCorruptFile)   // 读不到数 = 台架坏了，红给它看
    }
    return value
}

@Suite("BDE · 空镜承接整片真出", .serialized)
struct BrollDemoFilmTests {

    @Test("BDE-1 真出一条 11 秒成片：差额那 2 秒真的是空镜画面")
    @MainActor
    func realFilmWithInsertedBroll() async throws {
        try await withFFmpegBench("BDE-1 空镜承接整片真出") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bde-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let ff = FFmpegRunner()

            // 素材：主 A = testsrc 6s（故意只 6s ⇒ 4 秒分镜 + 8 秒配音必然差 2 秒）
            //       主 B = testsrc2 3s（第二格，无差额，专门验 concat 与输入序号后移）
            //       空镜 = smptebars 4s（项目里唯一一条「空镜」）
            let mainA = dir.appendingPathComponent("mainA.mp4").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "testsrc=size=1080x1920:rate=25:duration=6",
                "-pix_fmt", "yuv420p", "-y", mainA], timeoutSeconds: 300)
            let mainB = dir.appendingPathComponent("mainB.mp4").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "testsrc2=size=1080x1920:rate=25:duration=3",
                "-pix_fmt", "yuv420p", "-y", mainB], timeoutSeconds: 300)
            let bars = dir.appendingPathComponent("bars.mp4").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "smptebars=size=1080x1920:rate=25:duration=4",
                "-pix_fmt", "yuv420p", "-y", bars], timeoutSeconds: 300)
            // 配音：8s / 3s 的正弦，音频长度与画面无关 ⇒ 时长闸只能靠"窗口+空镜"对上
            let dubA = dir.appendingPathComponent("dubA.m4a").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "sine=frequency=660:sample_rate=44100:duration=8",
                "-c:a", "aac", "-b:a", "96k", "-y", dubA], timeoutSeconds: 300)
            let dubB = dir.appendingPathComponent("dubB.m4a").path
            try await ff.run(arguments: ["-f", "lavfi",
                "-i", "sine=frequency=880:sample_rate=44100:duration=3",
                "-c:a", "aac", "-b:a", "96k", "-y", dubB], timeoutSeconds: 300)

            let (scheme, container) = try bdeGraph(mainA: mainA, mainB: mainB, bars: bars,
                                                  dubA: dubA, dubB: dubB)
            defer { withExtendedLifetime(container) {} }

            let input = try DubExportInput.from(scheme: scheme)
            // 建输入这一层的形状：第一格插了一片空镜，第二格没有
            #expect(input.segments[0].fillPieces.count == 1,
                    "差额格没排到空镜 ⇒ 后面渲出来的 8 秒画面里那 2 秒不知道是什么")
            #expect(input.segments[1].fillPieces.isEmpty,
                    "不缺画面的格子也被垫了空镜 ⇒ 成片凭空多一段无关画面")

            let out = dir.appendingPathComponent("成片-空镜承接.mp4")
            var config = ExportConfig()
            config.resolution = .p1080
            try await DubExportService().export(input: input, outputPath: out.path, config: config)

            // ① 视频流必须跟着配音走满：9.0s（6+3，没插空镜）↔ 11.0s（插了）分得开
            let videoSeconds = try await bdeStreamDuration(ff, out.path, stream: "v:0")
            #expect(videoSeconds > 10.6 && videoSeconds < 11.6,
                    "视频流 \(String(format: "%.2f", videoSeconds))s ⇒ 空镜没接进整片（9.0 = 没插，>11.6 = 多垫）")
            let audioSeconds = try await bdeStreamDuration(ff, out.path, stream: "a:0")
            #expect(audioSeconds > 10.4 && audioSeconds < 11.6,
                    "音频 \(String(format: "%.2f", audioSeconds))s 与画面不同步 ⇒ 交付时长闸口径又分叉了")

            // ③ 整片必须**能完整解码**且帧数齐 —— 时长对、画面也对，但流本身破了同样是废片
            //    （千川直接拒收；这一格是把"只量时长"的弱判据补成硬判据的那一步）
            let vErrors = try await bdeDecodeErrors(ff, out.path)
            #expect(vErrors.isEmpty, "成片视频流解码报错：\(vErrors.prefix(3).joined(separator: " / ")) ⇒ 文件本身是坏的，时长对也没用")
            let frames = try await bdeFrameCount(ff, out.path)
            #expect(frames >= 265 && frames <= 285, "解码到 \(frames) 帧，期望 ≈277（11.1s@25fps）⇒ 流被截断")
            #expect(frames > 0, "一帧都没解出来 = 台架坏了，不是产品问题")

            // ④ 单槽渲染同一份 spec（把 concat 那一步摘掉，坏了就知道坏在哪一层）
            let single = dir.appendingPathComponent("槽1-单片.mp4")
            try await DubExportService().exportSingleSegment(spec: input.segments[0],
                                                             videoWidth: 1080, videoHeight: 1920,
                                                             outputPath: single.path, config: config)
            let singleErrors = try await bdeDecodeErrors(ff, single.path)
            #expect(singleErrors.isEmpty, "单槽片就坏 ⇒ 坏在多段画面这一步；单槽干净而整片坏 ⇒ 坏在 concat")

            // ⑤ 三处取样：本格主素材 / 差额段（必须是空镜）/ 第二格主素材
            let at3 = try await bdeYavg(ff, out.path, at: 3.0)
            let at7 = try await bdeYavg(ff, out.path, at: 7.0)
            let at95 = try await bdeYavg(ff, out.path, at: 9.5)
            #expect(at3 > 115, "t=3s 读到 YAVG \(at3) ⇒ 第一格连自己的主素材都没播（实算参考：testsrc≈125.9）")
            #expect(at7 < 110,
                    "t=7s 读到 YAVG \(at7) ⇒ 差额那 2 秒不是空镜画面（空镜 smptebars≈96.5，克隆末帧会读到 ≈126，正是本仓明确拒掉的那一支）")
            #expect(at95 > 115,
                    "t=9.5s 读到 YAVG \(at95) ⇒ 插入空镜把第二格的输入序号带偏了（concat 后移那一族）")

            // 产物搬到仓库 `.scratch/broll-demo/`（纯复制，不经 ffmpeg）留给人双击核对画面
            let kept = try bdeKeepForReview(out, single)
            print("BDE-1 产物（可直接双击看）：\(kept.joined(separator: " , "))")
        }
    }
}

/// 两个槽位 + 一条空镜供给，全在内存容器里。
@MainActor
private func bdeGraph(mainA: String, mainB: String, bars: String,
                      dubA: String, dubB: String) throws -> (MixScheme, ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let fps = 25.0

    let project = Project(name: "BDE-临时项目")
    ctx.insert(project)
    let scheme = MixScheme(name: "BDE-临时成片")
    ctx.insert(scheme)
    scheme.project = project

    func makeVideo(_ name: String, _ path: String, _ duration: Double) -> Video {
        let v = Video(name: name, localPath: path)
        v.duration = duration
        v.fps = fps
        v.width = 1080
        v.height = 1920
        ctx.insert(v)
        _ = ProjectVideo.associate(project: project, video: v, in: ctx)
        return v
    }

    // 槽位 1：主 A [0,4) + 8 秒配音 ⇒ 差 2 秒，只能靠空镜
    let videoA = makeVideo("BDE-主A", mainA, 6)
    let segA = Segment(segmentIndex: "seg_001", startTime: 0, endTime: 4,
                       text: "第一段台词", semanticTypes: [.painPoint], positionType: .opening)
    segA.startFrame = 0
    segA.endFrame = 100
    segA.video = videoA
    ctx.insert(segA)
    // 槽位 2：主 B [0,3) + 3 秒配音 ⇒ 不缺画面
    let videoB = makeVideo("BDE-主B", mainB, 3)
    let segB = Segment(segmentIndex: "seg_002", startTime: 0, endTime: 3,
                       text: "第二段台词", semanticTypes: [.solution], positionType: .middle)
    segB.startFrame = 0
    segB.endFrame = 75
    segB.video = videoB
    ctx.insert(segB)

    // 空镜供给：挂在同一个项目，但**不进方案**
    let barsVideo = makeVideo("BDE-空镜", bars, 4)
    let segBars = Segment(segmentIndex: "brl_001", startTime: 0, endTime: 4,
                          text: "", semanticTypes: [.emptyShot], positionType: .middle)
    segBars.startFrame = 0
    segBars.endFrame = 100
    segBars.video = barsVideo
    ctx.insert(segBars)

    for (i, pair) in [(segA, dubA, 8.0), (segB, dubB, 3.0)].enumerated() {
        let dub = SegmentDub(segment: pair.0, voiceId: "v1", voiceProvider: "cosyvoice",
                             textVariantIndex: 0, rewrittenText: "改写台词 \(i)")
        dub.audioDuration = pair.2
        dub.audioFilePath = pair.1
        dub.alignmentPolicy = .fixedRate
        ctx.insert(dub)
        pair.0.segmentDubs.append(dub)

        let slot = SchemeSegment(position: i + 1)
        ctx.insert(slot)
        slot.scheme = scheme
        slot.segment = pair.0
        slot.selectedSegmentDubId = dub.id
    }
    try ctx.save()
    return (scheme, container)
}

/// 把成片与单槽片**复制**到仓库 `.scratch/broll-demo/`（gitignored）留给人核对画面。
///
/// 为什么不在那里直接生成：`-movflags +faststart` 要在目标文件上搬数据，
/// 而本仓 `export()` 有"目标已存在且不是本次创建的就不删"的纪律 —— 上一轮的同名文件会
/// 与新内容混在一起（实测出现过两个 moov、样本表指向元数据区，症状是"插空镜把流写坏了"，
/// 其实是被复用的路径害的）。所以渲染一律写进自己的临时目录，最后只做纯复制。
@MainActor
private func bdeKeepForReview(_ files: URL...) throws -> [String] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent(".scratch/broll-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var kept: [String] = []
    for src in files {
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        kept.append(dst.path)
    }
    return kept
}

/// 量某一条流的时长（读不到就抛，不许把"量不到"当"通过"）。
private func bdeStreamDuration(_ ff: FFmpegRunner, _ path: String, stream: String) async throws -> Double {
    let out = try await ff.runProbe(arguments: ["-v", "error", "-select_streams", stream,
                                               "-show_entries", "stream=duration",
                                               "-of", "csv=p=0", path])
    guard let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return d
}

/// 整条解码一遍（真实播放器就是这么读这个文件的），返回解码错误文本（空 = 干净）。
///
/// `-xerror` 让 ffmpeg 遇到第一个解码错误就非 0 退出；`FFmpegRunner.run` 抛出的
/// `executionFailed` 里带 stderr ⇒ 错误原文能直接进判据消息（本轮就是靠它读到 cabac 崩在哪）。
/// 为什么必须有这一格：**时长与画面颜色都对的成片，流本身仍可能是坏的**（上一版只量时长，
/// 恰好对这种坏法全绿 —— 千川会直接拒收）。
private func bdeDecodeErrors(_ ff: FFmpegRunner, _ path: String) async throws -> [String] {
    do {
        _ = try await ff.run(arguments: ["-v", "error", "-xerror", "-i", path,
                                        "-map", "0:v:0", "-an", "-f", "null", "-"],
                             timeoutSeconds: 300)
        return []
    } catch {
        return [String(describing: error)]
    }
}

/// 实解出来的视频帧数（`-count_frames` 会真的解码一遍，不是读容器元数据）。
private func bdeFrameCount(_ ff: FFmpegRunner, _ path: String) async throws -> Int {
    let out = try await ff.runProbe(arguments: ["-v", "error", "-select_streams", "v:0",
                                               "-count_frames", "-show_entries", "stream=nb_read_frames",
                                               "-of", "csv=p=0", path])
    guard let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return n
}
