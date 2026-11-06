import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// BFK · 旧库补标「空镜」（只用已存文本，不重听）
//
// ## 为什么要有这一组
//
// 「空镜」标签原本**只在导入时写**（`ImportViewModel` 那两处出口）⇒ 这一轮之前入库的素材
// 一段都没有这个标签。后果是两条已经落地的能力在真库里永远轮不到：
//   ① 差额承接的空镜池是空的 ⇒ 中间格偏长文案仍会被拦；
//   ② M1 终态档吃不到 ⇒ 空段继续每次重跑都逐段重听。
// 补标这颗就是给这两条上"料"的入口。它只用已存的段文本判名单层，**不重听音频**
//（能量层要的是 silencedetect 的产物，历史数据没存 ⇒ 想抬能量层只能重跑 ASR，那是另一笔钱）。
//
// ## 台架
//   · 自建内存容器，绝不碰用户的库；
//   · 撤销走的是 `PendingDeletionCenter` 这枚进程级单例 ⇒ 套件 `.serialized`，
//     并在用例末尾 `flushNow()` 收尾，别把 ticket 漏给隔壁文件。
// ============================================================================

private func bfkScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bfk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func bfkFile(_ dir: URL, _ name: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
    return url.path
}

/// 一条项目 + 若干分镜（文本显式给，标签一律先按"语义标签"打上，好验证补标是**改**标签）。
@MainActor
private func bfkProject(dir: URL, texts: [String]) throws -> (Project, [Segment], ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let project = Project(name: "BFK-项目")
    ctx.insert(project)
    let video = Video(name: "BFK-源", localPath: try bfkFile(dir, "src.mov"))
    video.duration = 20
    video.fps = 25
    video.width = 1080
    video.height = 1920
    ctx.insert(video)
    _ = ProjectVideo.associate(project: project, video: video, in: ctx)

    var segs: [Segment] = []
    for (i, text) in texts.enumerated() {
        let seg = Segment(segmentIndex: String(format: "seg_%03d", i + 1),
                          startTime: Double(i) * 2, endTime: Double(i) * 2 + 2,
                          text: text, semanticTypes: [.painPoint],
                          positionType: i == 0 ? .opening : .middle)
        seg.startFrame = FrameTime.frame(seconds: Double(i) * 2, fps: 25)
        seg.endFrame = FrameTime.frame(seconds: Double(i) * 2 + 2, fps: 25)
        seg.video = video
        ctx.insert(seg)
        segs.append(seg)
    }
    try ctx.save()
    return (project, segs, container)
}

@Suite("BFK · 旧库补标空镜", .serialized)
struct EmptyLensBackfillTests {

    /// 名单层的第一条（whisper 中文静音幻觉头号常客）—— 从真源取，不在这里抄字符串。
    private var phrase: String { EmptyLensPolicy.knownHallucinationPhrases[0] }
    private let realSpeech = "秋冬一到嘴就干，这颗橙子汁水多到离谱"

    @Test("BFK-1 命中套话名单的老段 ⇒ 进命中集，执行后标签改为「空镜」")
    @MainActor
    func hitIsApplied() throws {
        let dir = try bfkScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (project, segs, c) = try bfkProject(dir: dir, texts: [phrase, realSpeech])
        defer { withExtendedLifetime(c) {} }

        let hits = SegmentBatchActions.emptyLensBackfillHits(in: project.displayableSegments)
        #expect(hits.count == 1 && hits[0].id == segs[0].id,
                "命中集没点名到那条套话段（实得 \(hits.map(\.segmentIndex))）")

        SegmentBatchActions.applyEmptyLensBackfill(in: project.displayableSegments, in: c.mainContext)
        #expect(segs[0].semanticTypes == [.emptyShot],
                "补标没落地：\(segs[0].semanticTypes)")
        #expect(segs[1].semanticTypes == [.painPoint], "真口播被顺手改了标签")
        PendingDeletionCenter.shared.flushNow()
    }

    @Test("BFK-2 反向对照：真口播文案不许被补标（防这颗恒真）")
    @MainActor
    func realSpeechIsNotTouched() throws {
        let dir = try bfkScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (project, _, c) = try bfkProject(dir: dir, texts: [realSpeech, "喜欢的快去拍一单"])
        defer { withExtendedLifetime(c) {} }
        #expect(SegmentBatchActions.emptyLensBackfillHits(in: project.displayableSegments).isEmpty,
                "两句正常卖货话术都被判成空镜 ⇒ 补标会把整个库洗成空镜")
    }

    @Test("BFK-3 幂等：补标过一次之后，再跑一次命中集必须为空")
    @MainActor
    func secondRunIsNoOp() throws {
        let dir = try bfkScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (project, _, c) = try bfkProject(dir: dir, texts: [phrase])
        defer { withExtendedLifetime(c) {} }
        SegmentBatchActions.applyEmptyLensBackfill(in: project.displayableSegments, in: c.mainContext)
        #expect(SegmentBatchActions.emptyLensBackfillHits(in: project.displayableSegments).isEmpty,
                "已带「空镜」的段又被算进命中集 ⇒ 重跑会反复覆盖、撤销语义也乱了")
        PendingDeletionCenter.shared.flushNow()
    }

    @Test("BFK-4 干跑报的数 == 实改的数（按钮文案不许吹出一个落不了地的数）")
    @MainActor
    func previewCountMatchesAppliedCount() throws {
        let dir = try bfkScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (project, segs, c) = try bfkProject(dir: dir, texts: [phrase, realSpeech, phrase])
        defer { withExtendedLifetime(c) {} }
        let preview = SegmentBatchActions.emptyLensBackfillHits(in: project.displayableSegments).count
        SegmentBatchActions.applyEmptyLensBackfill(in: project.displayableSegments, in: c.mainContext)
        let changed = segs.filter { $0.semanticTypes == [.emptyShot] }.count
        #expect(preview == changed, "预览 \(preview) 个、实改 \(changed) 个 ⇒ 屏上一个数库里另一个数")
        PendingDeletionCenter.shared.flushNow()
    }

    @Test("BFK-5 撤销还原原来的语义标签")
    @MainActor
    func undoRestoresPreviousTags() throws {
        let dir = try bfkScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let (project, segs, c) = try bfkProject(dir: dir, texts: [phrase])
        defer { withExtendedLifetime(c) {} }
        SegmentBatchActions.applyEmptyLensBackfill(in: project.displayableSegments, in: c.mainContext)
        #expect(segs[0].semanticTypes == [.emptyShot])

        PendingDeletionCenter.shared.undoTapped()
        #expect(segs[0].semanticTypes == [.painPoint],
                "撤销没把原标签还回来（实得 \(segs[0].semanticTypes)）⇒ 批量覆盖类动作不带可信撤销就是裸改")
    }

    @Test("BFK-6 补标这颗不许重听、也不许自己抄一份名单")
    @MainActor
    func backfillNeverReListensAndHasNoSecondRoster() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent(
            "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"), encoding: .utf8)
        let body = src.components(separatedBy: "static func emptyLensBackfillHits")[1]
            // 截到**锚点之后真实存在的下一颗函数**之前。
            // ⚠️ 这里原来写的终止串是「/// 把当前分镜的字幕字号应用到」，而那颗函数在锚点
            // **之前**（:608 vs 锚点 :649）⇒ 终止串在切片里根本不出现，`[0]` 一路吃到文件末尾，
            // 于是这条"只扫补标那颗"的守卫实际扫的是整个文件尾。2026-11-06 换成 :691 的
            // `applyMaskToAllSegments`（确实在锚点之后），并由下面第③腿钉住切片不再是文件尾。
            .components(separatedBy: "/// 把当前分镜的遮挡设置应用到")[0]
        // ③ 切片本身不许退化成"整个文件尾" —— 那等于把扫描面悄悄放宽到全文件。
        #expect(body.count < src.count / 2,
                "BFK-6 的切片吃到了文件尾（body \(body.count) / src \(src.count)）⇒ 终止串又失效了")

        // ① 不许出现任何重听/重新分析的入口：补标的承诺就是"不花钱、不重听"
        for forbidden in ["transcribe", "SegmentTranscriber", "analyzeLocally", "reidentify"] {
            #expect(!body.contains(forbidden),
                    "补标里出现了 \(forbidden) ⇒ 这条腿的承诺是不重听音频，混进重听就变成又贵又慢的那条路")
        }
        // ② 判断只许从 EmptyLensPolicy 出（名单与阈值不许在 App 侧抄第二份）
        #expect(body.contains("EmptyLensPolicy"), "补标没吃 EmptyLensPolicy ⇒ 名单成了第二份真源")
        #expect(!body.contains("优优独播"), "App 侧出现了套话原文 ⇒ 名单被抄了一份，改 Core 不会同步到这里")
    }

    /// 重跑分析会**删旧段重建** ⇒ 那一刻标签还不存在。若免听只认标签，终态档在真实流程里
    /// 一次都不会打中（判据全绿、屏上照旧逐段重听）—— 这两腿就是拦住那种"结构就绪但打不着"。
    @Test("BFK-8 免听依据必须现判名单层，且名单谓词全仓只有一颗")
    @MainActor
    func exemptionJudgesFromTextNotOnlyFromTag() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent(
            "MixCut/ViewModels/ImportViewModel.swift"), encoding: .utf8)
        let call = src.components(separatedBy: "isEmptyLensSettled:")[1]
        #expect(call.contains("phraseOnlyConvicts"),
                "免听只认「空镜」标签 ⇒ 重跑分析（旧段已删、标签还没写回来）那次一颗都打不着")
        // ② 名单层谓词不许在 App 侧被重写一遍（`verdict(EmptyLensSignals()` 就是那份副本的形状）
        #expect(!src.contains("verdict(EmptyLensSignals()"),
                "App 侧自己拼了零信号 + verdict ⇒ 名单层出现第二份真源，Core 一改就分叉")
    }

    @Test("BFK-7 端到端：补标之后，空镜池真的有料、中间格的差额接得住了")
    @MainActor
    func backfillUnblocksTheShortfall() throws {
        let dir = try bfkScratch(); defer { try? FileManager.default.removeItem(at: dir) }
        // 一条源视频切两格紧贴 [0,4)+[4,8) ⇒ 第 1 格续无可续；再放一条**没进方案**的老空镜段
        let container = try ModelContainer(
            for: Schema(versionedSchema: AppSchemaV1.self),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let ctx = container.mainContext
        let project = Project(name: "BFK-端到端")
        ctx.insert(project)
        let scheme = MixScheme(name: "BFK-方案")
        ctx.insert(scheme)
        scheme.project = project
        let video = Video(name: "BFK-源", localPath: try bfkFile(dir, "src.mov"))
        video.duration = 8
        video.fps = 25
        ctx.insert(video)
        _ = ProjectVideo.associate(project: project, video: video, in: ctx)

        func makeSeg(_ index: Int, _ start: Double, _ end: Double, text: String,
                     tags: [SemanticType]) -> Segment {
            let seg = Segment(segmentIndex: String(format: "seg_%03d", index),
                              startTime: start, endTime: end,
                              text: text, semanticTypes: tags,
                              positionType: index == 1 ? .opening : .middle)
            seg.startFrame = FrameTime.frame(seconds: start, fps: 25)
            seg.endFrame = FrameTime.frame(seconds: end, fps: 25)
            seg.video = video
            ctx.insert(seg)
            return seg
        }
        // 方案里的两格（都是真口播）
        let first = makeSeg(1, 0, 4, text: realSpeech, tags: [.painPoint])
        _ = makeSeg(2, 4, 8, text: "果园现摘现发", tags: [.solution])
        // 一条**没进方案**的老素材：文本正好是 whisper 套话 ⇒ 补标前不算空镜
        let orphan = makeSeg(3, 10, 14, text: phrase, tags: [.painPoint])

        var slot1 = SchemeSegment(position: 1)
        ctx.insert(slot1)
        slot1.scheme = scheme
        slot1.segment = first
        let dub = SegmentDub(segment: first, voiceId: "v1", voiceProvider: "cosyvoice",
                             textVariantIndex: 0, rewrittenText: "改写台词")
        dub.audioDuration = 6.0                       // 比 4s 画面长 2s，而续帧天花板就是第 2 格
        dub.audioFilePath = try bfkFile(dir, "dub.m4a")
        dub.alignmentPolicy = .fixedRate
        ctx.insert(dub)
        first.segmentDubs.append(dub)
        slot1.selectedSegmentDubId = dub.id
        try ctx.save()

        let vm = SchemeViewModel()
        // ① 补标前：池子空 ⇒ 这格接不住，C3 该报"导出会被拦"
        #expect(project.brollSupplies.isEmpty, "还没补标就有空镜池 ⇒ 这条链的门槛是标签，不是文本")
        let before = try #require(vm.slotWindow(slot1, segment: first, project: project))
        #expect(before.shortfallFrames == 50 && !before.shortfallCovered)

        // ② 补标 ⇒ 那条老素材进池（供料的段不许是方案自己在用的那两格）
        SegmentBatchActions.applyEmptyLensBackfill(in: project.displayableSegments, in: ctx)
        #expect(orphan.semanticTypes == [.emptyShot])
        #expect(project.brollSupplies.map(\.label) == ["seg_003"],
                "空镜池没只收那条老素材：\(project.brollSupplies.map(\.label))")

        // ③ 补标后同一格：差额被垫满 ⇒ 界面文案该换成"已排空镜"
        let after = try #require(vm.slotWindow(slot1, segment: first, project: project))
        #expect(after.shortfallFrames == 50, "补标不该改变差额本身")
        #expect(after.shortfallCovered && abs(after.brollSeconds - 2.0) < 0.001,
                "有料之后仍报接不住 ⇒ 补标与承接没接上，用户补了标还是导不出")
        PendingDeletionCenter.shared.flushNow()
    }
}
