#if DEBUG
import Foundation
import SwiftData
import SQLite3

/// DEBUG-only 自检入口（环境变量 MIXCUT_SELFTEST=1 触发）。
/// 在真实库上跑通 G2 分镜库变体导出全链路 + G3 组合数学，产出真实文件并写报告。
/// 对正常使用零影响：仅 DEBUG 编译、仅在显式设置环境变量时运行。
enum DebugSelfTest {

    @MainActor
    static func runIfRequested(container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        if env["MIXCUT_SELFTEST_TOMBSTONE"] == "1" {
            runTombstoneMatrix(single: env["MIXCUT_SELFTEST_TOMBSTONE_GRID"].flatMap(Int.init),
                               grid16: env["MIXCUT_SELFTEST_GRID16"])
            return
        }
        if let s = env["MIXCUT_SELFTEST_SHORTREF"], let secs = Double(s) { runShortRef(container: container, refSecs: secs); return }
        if env["MIXCUT_SELFTEST_REGENDUB"] == "1" { runRegenDub(container: container); return }
        if env["MIXCUT_SELFTEST_TTSX"] == "1" { runTTSx(container: container); return }
        if let f = env["MIXCUT_ASRFILE"], !f.isEmpty { runASRFile(path: f); return }
        if env["MIXCUT_SELFTEST_FACADE"] == "1" { runFacade(container: container); return }
        if env["MIXCUT_SELFTEST_REID"] == "1" { runReid(container: container); return }
        if env["MIXCUT_SELFTEST_DRIFT"] == "1" { runDrift(container: container); return }
        if env["MIXCUT_SELFTEST_ASRFULL"] == "1" { runASRFull(container: container); return }
        if env["MIXCUT_SELFTEST_ASR"] == "1" { runASR(container: container); return }
        if env["MIXCUT_SELFTEST_CLEAN"] == "1" { runCleanFanout(container: container); return }
        if env["MIXCUT_SELFTEST_READINESS"] == "1" { runReadiness(container: container); return }
        if let n = env["MIXCUT_SELFTEST_GEN_REAL"], let t = Int(n) { runGenReal(container: container, target: t); return }
        if env["MIXCUT_SELFTEST_VOICEREADY"] == "1" { runVoiceReady(container: container); return }
        if env["MIXCUT_SELFTEST_REWRITE"] == "1" { runRewrite(container: container); return }
        if let n = env["MIXCUT_SELFTEST_GEN"], let target = Int(n) { runGenSchemes(container: container, target: target); return }
        guard env["MIXCUT_SELFTEST"] == "1" else { return }
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_selftest.txt"

        let ctx = container.mainContext
        var lines: [String] = ["# \(Brand.displayName) 自检报告"]

        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()), !videos.isEmpty else {
            write(outPath, ["无视频，跳过"]); return
        }
        // 选变体最多的视频
        let video = videos.max {
            $0.segments.flatMap(\.segmentDubs).count < $1.segments.flatMap(\.segmentDubs).count
        }!
        let segs = video.segments.sorted { $0.segmentIndex < $1.segmentIndex }
        var seq: [UUID: Int] = [:]
        for (i, s) in segs.enumerated() { seq[s.id] = i + 1 }

        lines.append("视频: \(video.name)")
        lines.append("分镜数: \(segs.count)，含音频变体总数: \(segs.flatMap(\.segmentDubs).filter { $0.audioFilePath != nil }.count)")

        // —— G3 组合数学（真实数据，纯逻辑，不落库）——
        lines.append("\n## G3 笛卡尔积组合(每模板≤8)")
        let slots: [SlotOptions] = segs.map { s in
            SlotOptions(isLocked: s.isVoiceLocked,
                        includeOriginal: s.isVoiceLocked ? true : s.originalParticipatesInCombination,
                        dubIds: s.isVoiceLocked ? [] : s.combinationDubVariants.map(\.id))
        }
        let combo = VariantCombinationGenerator.generate(slots: slots, limit: 256)
        lines.append("可行组合总数(feasible)=\(combo.feasibleCount)，实取=\(combo.combinations.count)，截断=\(combo.truncated)")

        // —— G2 变体导出（真实 App 层链路）——
        let jobs = VariantExportInput.from(segments: segs) { seq[$0.id] ?? 0 }
        let originals = jobs.filter { if case .original = $0 { return true } else { return false } }.count
        let variants = jobs.count - originals
        lines.append("\n## G2 导出任务展开")
        lines.append("任务总数=\(jobs.count)（原版=\(originals)，变体=\(variants)）")
        lines.append("文件名样例: " + jobs.prefix(8).map(\.fileName).joined(separator: ", "))

        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(Brand.shortName)_selftest_export", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let svc = VariantBatchExportService()
        let jobsCopy = jobs
        Task.detached {
            let result = await svc.exportAll(jobs: jobsCopy, outputDirectory: outDir,
                                             config: ExportConfig()) { _ in }
            var report = lines
            report.append("\n## G2 实导出结果")
            report.append("成功=\(result.succeeded)，失败=\(result.failed.count)")
            for f in result.failed { report.append("  失败: \(f.0) — \(f.1)") }
            // 列出产物文件 + 大小
            if let files = try? FileManager.default.contentsOfDirectory(atPath: outDir.path) {
                report.append("产物文件(\(files.count)):")
                for f in files.sorted() {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: outDir.appendingPathComponent(f).path)
                    let sz = (attrs?[.size] as? Int) ?? 0
                    report.append("  \(f)  \(sz) bytes")
                }
                // 探测一个变体文件是否含音频流（用 bundle 内 ffmpeg -i）
                if let oneVariant = files.first(where: { $0.contains("_") && $0.hasSuffix(".mp4") }) {
                    let probe = Self.ffmpegProbe(outDir.appendingPathComponent(oneVariant).path)
                    report.append("变体探测 \(oneVariant):\n\(probe)")
                }
            }
            report.append("\n[done] 导出目录: \(outDir.path)")
            Self.write(outPath, report)
        }
        // 先写一份(同步部分),异步结果稍后覆盖
        write(outPath, lines + ["\n[导出进行中…完成后本文件会被覆盖]"])
    }

    // MARK: - 在「含已克隆视频的真实项目」上生成方案（新代码：每方案一条原序列 + 组合数提示），不删

    @MainActor
    static func runGenReal(container: ModelContainer, target: Int) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_genreal.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { ($0.clonedVoiceId ?? "").isEmpty == false }),
              let project = video.projectVideos.compactMap({ $0.project }).first else {
            write(outPath, ["未找到含克隆视频的项目"]); return
        }
        write(outPath, ["# 在真实项目生成方案", "项目: \(project.name)", "[运行中…]"])
        let vm = SchemeViewModel()
        vm.setModelContext(ctx)
        Task { @MainActor in
            await vm.generateSchemes(for: project, targetVideoCount: target)
            let ai = vm.aiStrategies
            var r = ["# 在真实项目生成方案(完成)", "项目: \(project.name)",
                     "进度: \(vm.generationProgress)",
                     "AI策略数: \(ai.count)"]
            for st in ai {
                r.append("  策略「\(st.name)」: \(st.orderedSchemes.count) 个方案")
                if let sc = st.orderedSchemes.first {
                    let factors = sc.orderedSegments.map { ss -> Int in
                        guard let seg = ss.segment else { return 1 }
                        return seg.combinationSlotCount
                    }
                    r.append("    样例方案「\(sc.name)」组合数=\(factors.reduce(1,*)) (\(factors.map(String.init).joined(separator: "×")))")
                }
            }
            if let err = vm.errorMessage { r.append("errorMessage: \(err)") }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 清理测试期 fan-out 残留（templateGroupId != nil 的方案 + 清空的AI策略）

    @MainActor
    static func runCleanFanout(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_clean.txt"
        let ctx = container.mainContext
        var removedSchemes = 0
        if let schemes = try? ctx.fetch(FetchDescriptor<MixScheme>()) {
            for sc in schemes where sc.templateGroupId != nil {
                ctx.delete(sc); removedSchemes += 1
            }
        }
        try? ctx.save()
        // 删掉因此清空、且非自定义/非叙事/非脚本容器的 AI 策略
        //（isScriptGroup 容器懒建、可能空但有效，G-S7 白名单钉住，勿误删）。
        var removedStrats = 0
        if let strats = try? ctx.fetch(FetchDescriptor<MixStrategy>()) {
            for st in strats where st.schemes.isEmpty && !st.isCustomGroup
                && !st.isNarrativeTemplate && !st.isScriptGroup {
                ctx.delete(st); removedStrats += 1
            }
        }
        try? ctx.save()
        write(outPath, ["# 清理 fan-out 残留", "删除方案: \(removedSchemes)", "删除空AI策略: \(removedStrats)", "[done]"])
    }

    // MARK: - 就绪态与切项目联动（计划 fluid-spring-char 批五 · TC-I02 / TC-I04）
    //
    // 只覆盖「有活入口」的两条：判据都在 ViewModel 的公开 API 上，能在真实库上直接调。
    //   · TC-I01「换项目当帧清 banner」的触发点在 ContentView 的 .onChange 里 —— 那是视图修饰符，
    //     自检程序没有视图图，触发不到。硬测它就得把清理逻辑挪进 VM 或暴露内部状态，属为测试改架构，
    //     已改为人工判据（CLAUDE.md 检查清单第 6 条）。
    //   · TC-I03「prewarm 同项目不互杀」要读 ThumbnailCache 的私有 task 句柄，同理不测；
    //     它的可观察代理是「首屏封面不再同步解码」，看 [Perf] 日志与上屏卡顿。

    /// 真库上验证：多选残留不跨重载（悬空 id 必被清）、骨架判据随项目翻转、快照读到真值。
    /// 全程只建两个临时项目，不动用户数据；结束按 runGenSchemes 的先例清理。
    @MainActor
    static func runReadiness(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_readiness.txt"
        let ctx = container.mainContext
        // 取样有两个坑，都会把判据变成假绿，所以同时避开：
        //   · 必须取两个**不同**的视频：若 A、B 挂同一个，「B 里不得混入 A 的分镜」恒成立。
        //   · 每个视频必须**自带分镜**：若 B 挂的是 0 分镜视频，空集与任何集合求交都是 0，那条同样恒成立。
        let allVideos = (try? ctx.fetch(FetchDescriptor<Video>())) ?? []
        let withSegments = allVideos.filter { !$0.segments.isEmpty }
        guard let videoA = withSegments.first else {
            write(outPath, ["库里没有任何带分镜的视频（视频总数 \(allVideos.count)），无法取样 —— 本判据不算通过"]); return
        }
        let videoB = withSegments.count > 1 ? withSegments[1] : nil

        let projectA = Project(name: "【自检临时A】请忽略")
        let projectB = Project(name: "【自检临时B】请忽略")
        ctx.insert(projectA); ctx.insert(projectB)
        ProjectVideo.associate(project: projectA, video: videoA, in: ctx)
        if let videoB { ProjectVideo.associate(project: projectB, video: videoB, in: ctx) }
        else { ProjectVideo.associate(project: projectB, video: videoA, in: ctx) }   // 退化取样，foreign 判据下面会标未跑
        try? ctx.save()
        let ids = (projectA.id, projectB.id)

        let sampleBName = String((videoB ?? videoA).name.prefix(24))
        let sampleBSegCount = videoB.map { "（分镜 \($0.segments.count) 条）" } ?? ""
        let sameSourceNote = videoB == nil ? "（库里只有 1 个带分镜的视频，AB 同源 → 跨项目纯净性判据记为未跑）" : ""
        var r: [String] = ["# 就绪态与切项目联动自检",
                           "取样池：视频 \(allVideos.count) 个，其中带分镜的 \(withSegments.count) 个",
                           "取样：A←视频「\(String(videoA.name.prefix(24)))」（分镜 \(videoA.segments.count) 条），B←视频「\(sampleBName)」\(sampleBSegCount)\(sameSourceNote)"]

        // —— TC-I04：骨架判据与禁点判据必须分离（批十契约：换项目不上屏骨架，只禁点）——
        let projectVM = ProjectViewModel()
        projectVM.setModelContext(ctx)
        let coldSkeleton = projectVM.readiness.needsSkeleton
        r.append("冷启动 needsSkeleton=\(coldSkeleton)（期望 true —— 屏上还没有任何项目的数据可留）\(coldSkeleton ? "✅" : "❌ FAIL")")
        projectVM.refreshOverviewSnapshot(for: projectA)
        let snapA = projectVM.overviewSnapshot          // 先存下 A 的读数，否则下面那行会把 B 的值当成 A 报出去
        let afterA: (Bool, Bool, Bool) = (projectVM.readiness.needsSkeleton,
                                          projectVM.readiness.holdsData(for: projectA.id),
                                          projectVM.readiness.holdsData(for: projectB.id))
        r.append("加载 A 后：needsSkeleton=\(afterA.0)（期望 false）/ holdsData(A)=\(afterA.1)（期望 true）/ holdsData(B)=\(afterA.2)（期望 false）→ \(afterA == (false, true, false) ? "✅" : "❌ FAIL")")
        projectVM.refreshOverviewSnapshot(for: projectB)
        let afterB: (Bool, Bool, Bool) = (projectVM.readiness.needsSkeleton,
                                          projectVM.readiness.holdsData(for: projectA.id),
                                          projectVM.readiness.holdsData(for: projectB.id))
        r.append("切到 B 后：needsSkeleton=\(afterB.0)（期望 false —— 换项目**不再**上屏骨架）/ holdsData(A)=\(afterB.1)（期望 false → 屏上是旧画面，该禁点）/ holdsData(B)=\(afterB.2)（期望 true）→ \(afterB == (false, false, true) ? "✅" : "❌ FAIL")")
        r.append("快照规模 A=\(snapA.videoCount) 视频 / B=\(projectVM.overviewSnapshot.videoCount) 视频（各挂 1 个视频，必须读到 1；读到 0 就是「先画 0 视频」的回归）")

        // —— TC-I02：重载必须把选中重新对齐到现存数据（含悬空引用保护）——
        let segVM = SegmentLibraryViewModel()
        segVM.setModelContext(ctx)
        segVM.loadSegments(for: projectA)
        let aSegIDs = Set(segVM.segments.map(\.id))
        // 故意植入两个凭空的分镜 id（不属于任何现存数据），先证明植入成立
        segVM.selectedSegmentIDs.insert(UUID())
        segVM.selectedSegmentIDs.insert(UUID())
        segVM.setSelectionMode(true)
        r.append("植入后：selectedSegmentIDs=\(segVM.selectedSegmentIDs.count)（期望 2）A 的分镜数=\(aSegIDs.count)")
        segVM.loadSegments(for: projectB)   // 切项目重载
        let selectedCleared = segVM.selectedSegmentIDs.isEmpty && segVM.selectedSegment == nil && !segVM.isSelectionMode
        let selectedReadout = segVM.selectedSegment == nil ? "nil" : "残留"
        let verdict = selectedCleared ? "✅" : "❌"
        r.append("重载 B 后：IDs=\(segVM.selectedSegmentIDs.count)（期望 0）selectedSegment=\(selectedReadout)（期望 nil）多选模式=\(segVM.isSelectionMode)（期望 false）→ \(verdict)")
        if videoB != nil {
            let bSegIDs = Set(segVM.segments.map(\.id))
            let foreign = aSegIDs.intersection(bSegIDs).count
            // 非空洞性自证：只要有一侧分镜为空，「交集为 0」就恒成立 —— 那条判据当场没测到东西，必须判 FAIL 而不是打 ✅。
            let purityVerdict: String
            if aSegIDs.isEmpty || bSegIDs.isEmpty {
                purityVerdict = "❌ FAIL（取样退化：有一侧分镜为空，空集求交恒为 0，不构成判据）"
            } else {
                purityVerdict = foreign == 0 ? "✅" : "❌ FAIL（交集 \(foreign) 条非空，A 的数据漏进了 B）"
            }
            r.append("跨项目纯净性：A 分镜数=\(aSegIDs.count) / B 分镜数=\(bSegIDs.count)，与 A 的分镜 id 交集=\(foreign)（期望两侧都 >0 且交集为 0）→ \(purityVerdict)")
        } else {
            r.append("跨项目纯净性：未跑（库里只有 1 个带分镜的视频，AB 同源 → 交集必然等于全部，不构成判据）")
        }

        r.append("判读：上面每一行括号里的期望都要与实读一致；任何一处不符即本自检失败。")

        // 清理：先摘关联行再删临时项目，避免级联把用户的真实关联一起带走
        if let rows = try? ctx.fetch(FetchDescriptor<ProjectVideo>()) {
            for row in rows where row.project?.id == ids.0 || row.project?.id == ids.1 { ctx.delete(row) }
        }
        ctx.delete(projectA); ctx.delete(projectB)
        try? ctx.save()
        r.append("[done]")
        write(outPath, r)
    }

    // MARK: - 测短参考音的 clean 率（用 N 秒参考重新克隆，同台词合成5次看漏读几次）

    @MainActor
    static func runShortRef(container: ModelContainer, refSecs: Double) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_shortref.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { $0.name.contains("XCT") }),
              let hash = video.contentHash else { write(outPath, ["无 XCT 视频"]); return }
        let vocals = FileHelper.stemsDirectory(videoHash: hash).appendingPathComponent("vocals.wav").path
        guard FileManager.default.fileExists(atPath: vocals) else { write(outPath, ["无 vocals.wav 缓存"]); return }
        let text = "你真能忍冰箱发霉还带着异味？还不快试试这款滴露除菌喷雾吗？"
        write(outPath, ["# 短参考 clean 率测试 ref=\(refSecs)s", "台词29字: \(text)", "[运行中…]"])
        let sep = VocalSeparationService()
        let clone = VoiceCloneService()
        let vc = QwenTTSClient(model: VoiceCloneService.targetModel)
        let asr = QwenASRClient()
        let ff = FFmpegRunner()
        Task.detached {
            var r = ["# 短参考 clean 率测试 ref=\(refSecs)s", "台词29字(\(text.count)字)"]
            do {
                let ref = try await sep.referenceClip(fromVocals: vocals, maxSeconds: refSecs)
                let enrolled = try await clone.enroll(
                    referenceAudioPath: ref, preferredName: "shortref\(Int(refSecs))")
                let vid = enrolled.voiceId          // 下方循环要用（返回类型变更后需显式解包）
                r.append("新克隆 voice=\(vid.prefix(34)) providerName=\(enrolled.providerName)")
                var clean = 0
                for i in 1...5 {
                    let res = try await vc.synthesize(text: text, voiceId: vid, languageType: "Chinese", rate: 1.0)
                    let pcm = FileHelper.tempDirectory.appendingPathComponent("sr-\(UUID().uuidString).pcm")
                    try await ff.extractAudioPCM(from: res.wavPath, to: pcm.path)
                    let got = try await asr.transcribe(pcmPath: pcm.path)
                    try? FileManager.default.removeItem(at: pcm)
                    let isClean = got.count <= text.count + 6
                    if isClean { clean += 1 }
                    r.append("第\(i)次 \(String(format: "%.1f", res.rawDuration))s \(got.count)字 \(isClean ? "✅" : "❌漏"): \(got.prefix(50))")
                }
                r.append("clean 率: \(clean)/5")
            } catch { r.append("失败: \(error.localizedDescription)") }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 走真实 generateAudio(重试取最短)重生成 seg_002 配音并验证干净

    @MainActor
    static func runRegenDub(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_regendub.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { $0.name.contains("XCT") }),
              let seg = video.segments.first(where: { $0.segmentIndex == "seg_002" }),
              let dub = seg.segmentDubs.first(where: { $0.audioFilePath != nil }) ?? seg.segmentDubs.first else {
            write(outPath, ["无 XCT seg_002 变体"]); return
        }
        let segDur = seg.duration
        let rw = dub.rewrittenText
        write(outPath, ["# 重生成 seg_002 配音(重试取最短)", "分镜\(String(format: "%.1f", segDur))s 改写(\(rw.count)字): \(rw)", "[运行中…]"])
        let vm = DubbingViewModel()
        let asr = QwenASRClient()
        let ff = FFmpegRunner()
        Task { @MainActor in
            let okGen = await vm.generateAudio(for: dub, context: ctx)
            var r = ["# 重生成 seg_002 配音(重试取最短)", "分镜\(String(format: "%.1f", segDur))s 改写(\(rw.count)字): \(rw)",
                     "generateAudio 成功=\(okGen)  新 audioDuration=\(String(format: "%.1f", dub.audioDuration))s"]
            if let path = dub.audioFilePath {
                let pcm = FileHelper.tempDirectory.appendingPathComponent("rd-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractAudioPCM(from: path, to: pcm.path)
                    let got = try await asr.transcribe(pcmPath: pcm.path)
                    r.append("产物实际内容(\(got.count)字): \(got)")
                    r.append(got.count <= rw.count + 6 ? "✅ 干净(无多余内容)" : "❌ 仍漏读")
                } catch { r.append("转写失败: \(error.localizedDescription)") }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 同一克隆音色把同一台词连合成多次（诊断:漏读是偶发还是必现）

    @MainActor
    static func runTTSx(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_ttsx.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { ($0.clonedVoiceId ?? "").isEmpty == false }),
              let voiceId = video.clonedVoiceId else {
            write(outPath, ["无克隆音色视频"]); return
        }
        let text = "你真能忍冰箱发霉还带着异味？还不快试试这款滴露除菌喷雾吗？"   // seg_002 改写台词 29字
        write(outPath, ["# 同台词连合成3次(克隆音色)", "voice=\(voiceId.prefix(34))", "台词(29字): \(text)", "[运行中…]"])
        let vc = QwenTTSClient(model: VoiceCloneService.targetModel)
        let asr = QwenASRClient()
        let ff = FFmpegRunner()
        Task.detached {
            var r = ["# 同台词连合成3次(克隆音色)", "台词(29字): \(text)"]
            for i in 1...3 {
                do {
                    let res = try await vc.synthesize(text: text, voiceId: voiceId, languageType: "Chinese", rate: 1.0)
                    // 转写产物看实际念了啥
                    let pcm = FileHelper.tempDirectory.appendingPathComponent("ttsx-\(UUID().uuidString).pcm")
                    try await ff.extractAudioPCM(from: res.wavPath, to: pcm.path)
                    let got = try await asr.transcribe(pcmPath: pcm.path)
                    try? FileManager.default.removeItem(at: pcm)
                    r.append("第\(i)次: 原始时长\(String(format: "%.1f", res.rawDuration))s  内容(\(got.count)字): \(got.prefix(60))")
                } catch {
                    r.append("第\(i)次 失败: \(error.localizedDescription)")
                }
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 把任意音频文件转文字（诊断:生成的配音里到底念了啥）

    static func runASRFile(path: String) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_asrfile.txt"
        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# ASR 文件诊断", "文件: \((path as NSString).lastPathComponent)"]
            let pcm = FileHelper.tempDirectory.appendingPathComponent("asrfile-\(UUID().uuidString).pcm")
            do {
                // m4a/wav → 16k 单声道裸 PCM（extractAudioPCM 接受任意含音轨的文件）
                try await ff.extractAudioPCM(from: path, to: pcm.path)
                let text = try await asr.transcribe(pcmPath: pcm.path)
                r.append("识别出的内容(\(text.count)字): \(text)")
            } catch {
                r.append("失败: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: pcm)
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 实跑 SegmentTranscriber 门面（零 API 成本：只走本机那条腿，且完全不写库）

    /// 取前 N 段，**只问门面、不落笔**，逐段报 outcome / 实际引擎 / 档位 / 来源根 / 格式 / 耗时，
    /// 并清点临时目录里有没有残留的 `segasr-*`（R-h 的判据）。
    ///
    /// 为什么需要这支探针：MCP 面没有"单段重认"的入口、界面又点不动（`osascript` 无辅助访问），
    /// 而门面是本轮唯一改了生产行为的部件 —— 没有它，R4/R5 就只有编译期证据。
    /// 偏好不是"本地"时**拒绝跑**（那会走云端、产生付费调用），不做静默改设置来凑绿灯。
    @MainActor
    static func runFacade(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_facade.txt"
        let n = Int(ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_FACADE_N"] ?? "2") ?? 2
        var lines: [String] = ["# SegmentTranscriber 门面探针（不写库、只走本机）"]

        let pref = ASRSettings.storedPreference
        lines.append("存储里的偏好: \(pref.map { $0.rawValue } ?? "未设置→回落 \(ASRPolicy.defaultPreference.rawValue)")")
        lines.append("裁定默认值: \(ASRPolicy.defaultPreference.rawValue) · 档位 \(ASRPolicy.engineTier)")
        guard (pref ?? ASRPolicy.defaultPreference) == .local else {
            write(outPath, lines + ["拒绝跑：当前偏好不是本地，会走云端产生 API 成本"])
            return
        }

        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { v in !v.segments.isEmpty && !v.localPath.isEmpty }) else {
            write(outPath, lines + ["库里没有可跑的视频，跳过"])
            return
        }
        let fps = video.fps > 0 ? video.fps : 30
        let videoPath = video.localPath
        var requests: [SegmentTranscriber.Request] = []
        for seg in video.segments.sorted(by: { $0.startFrame < $1.startFrame }).prefix(n) {
            requests.append(SegmentTranscriber.Request(
                videoPath: videoPath, segmentIndex: seg.segmentIndex,
                startSeconds: Double(seg.startFrame) / fps, endSeconds: Double(seg.endFrame) / fps,
                currentText: seg.text, currentSource: seg.textSource))
        }
        lines.append("视频: \(video.name) · 跑 \(requests.count) 段")
        lines.append("风格锚: \(ASRPolicy.retakeStyleAnchor.count) 字")

        let transcriber = SegmentTranscriber.shared
        Task.detached {
            for req in requests {
                let r = await transcriber.transcribe(req)
                lines.append("- \(req.segmentIndex): outcome=\(r.outcome.rawValue) engine=\(r.engine?.rawValue ?? "nil")"
                             + " tier=\(r.tier ?? "nil") root=\(r.rootKind?.displayName ?? "nil")"
                             + " format=\(r.format?.rawValue ?? "nil") elapsed=\(String(format: "%.1f", r.elapsed))s"
                             + " gotText=\(r.gotText)"
                             + " anchor=\(r.anchorUsed)"
                             + (r.reason.map { " reason=\($0)" } ?? ""))
                lines.append("  认到: \((r.textToWrite ?? "").prefix(40))")
            }
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: FileHelper.tempDirectory.path)) ?? [])
                .filter { $0.hasPrefix("segasr-") }
            lines.append("R-h 残留 segasr-* 文件数: \(leftovers.count)")
            lines.append("[done]")
            await MainActor.run { write(outPath, lines) }
        }
    }

    // MARK: - 实跑 reidentifyWholeVideo（逐分镜 clip-ASR）并报告结果

    @MainActor
    static func runReid(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_reid.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { write(outPath, ["无视频"]); return }
        let video = videos.first(where: { $0.name.contains("XCT") && !$0.segments.isEmpty })
            ?? videos.first(where: { !$0.segments.isEmpty })
        guard let video else { write(outPath, ["无带分镜视频"]); return }
        let name = video.name
        write(outPath, ["# 实跑 reidentifyWholeVideo(逐分镜 clip-ASR)", "视频: \(name.prefix(24))", "[运行中…]"])
        let vm = ImportViewModel()
        Task { @MainActor in
            await vm.reidentifyWholeVideo(video, context: ctx)
            var r = ["# reidentifyWholeVideo 完成", "视频: \(name.prefix(24))"]
            for (i, seg) in video.segments.sorted(by: { $0.startFrame < $1.startFrame }).enumerated().prefix(5) {
                r.append("#\(i+1) \(seg.segmentIndex): \(seg.text.prefix(40))")
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - DRIFT 诊断：整片时间戳切出的存量台词 vs 单段音频重切

    @MainActor
    static func runDrift(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_drift.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { write(outPath, ["无视频"]); return }
        // 优先 XCT；否则取第一个有分镜的
        let video = videos.first(where: { $0.name.contains("XCT") && !$0.segments.isEmpty })
            ?? videos.first(where: { !$0.segments.isEmpty })
        guard let video, !video.localPath.isEmpty, FileManager.default.fileExists(atPath: video.localPath) else {
            write(outPath, ["无可用视频"]); return
        }
        let fps = video.fps > 0 ? video.fps : 30
        let segs = video.segments.sorted { $0.startFrame < $1.startFrame }
        // 取 #2/#3/#4（索引1..3）
        let picks = Array(segs.enumerated()).filter { (1...3).contains($0.offset) }
            .map { (idx: $0.offset + 1, start: Double($0.element.startFrame) / fps,
                    end: Double($0.element.endFrame) / fps, stored: $0.element.text) }
        let path = video.localPath
        write(outPath, ["# DRIFT 诊断: 存量台词(整片时间戳) vs 单段音频重切", "视频: \(video.name.prefix(24))", "[运行中…]"])
        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# DRIFT 诊断(完成)", "视频: \(video.name.prefix(24))"]
            // 限速后的整片识别 → 按分镜边界切片
            var fullWords: [ASRWord] = []
            do {
                let fpcm = FileHelper.tempDirectory.appendingPathComponent("driftfull-\(UUID().uuidString).pcm")
                try await ff.extractAudioPCM(from: path, to: fpcm.path)
                fullWords = try await asr.transcribeFull(pcmPath: fpcm.path).words
                try? FileManager.default.removeItem(at: fpcm)
                r.append("限速整片 words=\(fullWords.count)")
            } catch { r.append("限速整片失败: \(error.localizedDescription)") }
            func slice(_ s: Double, _ e: Double) -> String {
                fullWords.filter { $0.start >= s && $0.start < e }.map(\.word).joined()
            }
            for p in picks {
                let pcm = FileHelper.tempDirectory.appendingPathComponent("drift-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractSegmentPCM(from: path, start: p.start, end: p.end, to: pcm.path)
                    let clip = try await asr.transcribe(pcmPath: pcm.path)
                    r.append("#\(p.idx) [\(String(format: "%.1f", p.start))-\(String(format: "%.1f", p.end))]s")
                    r.append("   存量(旧漂移): \(p.stored.prefix(36))")
                    r.append("   限速整片切 : \(slice(p.start, p.end).prefix(36))")
                    r.append("   单段真值   : \(clip.prefix(36))")
                } catch {
                    r.append("#\(p.idx) 失败: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - SPIKE：整片 paraformer 时间戳精度验证

    @MainActor
    static func runASRFull(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_asrfull.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { write(outPath, ["无视频"]); return }
        let infos: [(name: String, path: String, dur: Double)] = videos
            .filter { !$0.segments.isEmpty && !$0.localPath.isEmpty && FileManager.default.fileExists(atPath: $0.localPath) }
            .map { ($0.name, $0.localPath, $0.duration) }
        write(outPath, ["# SPIKE 整片 paraformer 句子粒度(全部视频)", "[运行中…]"])
        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# SPIKE 整片 paraformer 句子粒度(完成)"]
            for info in infos {
                let pcm = FileHelper.tempDirectory.appendingPathComponent("spike-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractAudioPCM(from: info.path, to: pcm.path)
                    let res = try await asr.transcribeFull(pcmPath: pcm.path)
                    // 含句末标点的句子数(说明是 run-on,本应再切)
                    let runOns = res.rawSentences.filter { s in
                        let inner = s.text.dropLast()  // 去掉结尾标点
                        return inner.contains("。") || inner.contains("！") || inner.contains("？")
                    }.count
                    r.append("· \(info.name.prefix(22)) 时长\(String(format: "%.0f", info.dur))s")
                    r.append("   阿里: words=\(res.words.count) 句子=\(res.rawSentences.count) 其中含内部句末标点(run-on)=\(runOns)")
                    for s in res.rawSentences.prefix(3) {
                        r.append("     [\(String(format: "%.1f", s.start))-\(String(format: "%.1f", s.end))] \(s.text.prefix(50))")
                    }
                } catch {
                    r.append("· \(info.name.prefix(22)) 失败: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - 阿里 paraformer ASR 单分镜重提取实跑（真实云端，验证 WS 协议）

    @MainActor
    static func runASR(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_asr.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.first(where: { !$0.segments.isEmpty && !$0.localPath.isEmpty
                  && FileManager.default.fileExists(atPath: $0.localPath) }) else {
            write(outPath, ["无带分镜的视频"]); return
        }
        let segs = video.segments.sorted { $0.segmentIndex < $1.segmentIndex }
        let targets = Array(segs.prefix(3))   // 验前 3 个分镜
        write(outPath, ["# 阿里 paraformer ASR 单分镜重提取实跑", "视频: \(video.name)", "[运行中…]"])

        let ff = FFmpegRunner()
        let asr = QwenASRClient()
        Task.detached {
            var r = ["# 阿里 paraformer ASR 单分镜重提取实跑(完成)", "视频: \(video.name)"]
            let fps = await MainActor.run { video.fps > 0 ? video.fps : 30 }
            for seg in targets {
                let (idx, sf, ef, whisper) = await MainActor.run {
                    (seg.segmentIndex, seg.startFrame, seg.endFrame, seg.text)
                }
                let start = Double(sf) / fps, end = Double(ef) / fps
                let pcm = FileHelper.tempDirectory.appendingPathComponent("asrtest-\(UUID().uuidString).pcm")
                do {
                    try await ff.extractSegmentPCM(from: video.localPath, start: start, end: end, to: pcm.path)
                    let text = try await asr.transcribe(pcmPath: pcm.path)
                    r.append("· \(idx) [\(String(format: "%.1f", start))-\(String(format: "%.1f", end))s]")
                    r.append("   whisper原: \(whisper.prefix(40))")
                    r.append("   阿里ASR : \(text.prefix(40))")
                } catch {
                    r.append("· \(idx) 失败: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: pcm)
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - G1 一键改写实跑（真实云端）

    @MainActor
    static func runRewrite(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_rewrite.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()), !videos.isEmpty else {
            write(outPath, ["无视频"]); return
        }
        // 优先选「已克隆且已有配音」的视频(ea30b31，避免重跑 demucs / 选到半成品克隆)，按已有配音数取最多
        func dubCount(_ v: Video) -> Int { v.segments.flatMap(\.segmentDubs).count }
        let video = videos.filter { ($0.clonedVoiceId ?? "").isEmpty == false && dubCount($0) > 0 }
            .max { dubCount($0) < dubCount($1) }
            ?? videos.max { dubCount($0) < dubCount($1) }!
        let before = video.segments.flatMap(\.segmentDubs).count
        let n = DubbingViewModel().variantCount
        write(outPath, ["# G1 一键改写实跑", "视频: \(video.name)", "改写前变体数: \(before)，每镜变体设置: \(n)", "[运行中…]"])
        let vm = DubbingViewModel()
        Task { @MainActor in
            // 统一改写入口（all 作用域）；排序与生产路径同口径
            let targets = DubTargetOrdering.ordered(video.segments) {
                ($0.startTime, $0.startFrame)
            }
            await vm.rewrite(video: video,
                             targets: targets,
                             presentation: DubScopePresentationMapper.presentation(for: .all),
                             context: ctx)
            let dubs = video.segments.flatMap(\.segmentDubs)
            let withAudio = dubs.filter { $0.audioFilePath != nil }.count
            let cloned = video.clonedVoiceId ?? "nil"
            var r = ["# G1 一键改写实跑(完成)", "视频: \(video.name)",
                     "克隆音色: \(cloned)",
                     "改写后变体总数: \(dubs.count)，其中有音频: \(withAudio)",
                     "非锁定分镜数: \(video.segments.filter { !$0.isVoiceLocked && !$0.text.isEmpty }.count)，每镜应产: \(n)"]
            if let err = vm.errorState?.message { r.append("errorMessage: \(err)") }
            // 各分镜每条配音的时长对齐情况：分镜时长 D / 配音时长 / 末尾空挡静音
            for s in video.segments.sorted(by: { $0.segmentIndex < $1.segmentIndex }) {
                let dur = s.duration
                r.append("  \(s.segmentIndex) 分镜=\(String(format: "%.2f", dur))s locked=\(s.isVoiceLocked) 有效变体=\(s.effectiveDubVariants.count)")
                for d in s.effectiveDubVariants {
                    let gap = dur - d.audioDuration
                    r.append("     变体\(d.textVariantIndex) 配音=\(String(format: "%.2f", d.audioDuration))s 空挡=\(String(format: "%.2f", max(0, gap)))s atempo=\(String(format: "%.2f", d.atempoFactor)) 末尾静音=\(String(format: "%.2f", d.trailingSilence))s")
                }
            }
            r.append("[done]")
            write(outPath, r)
        }
    }

    // MARK: - G-V8 配音就绪腿（M1a/M1b 遗留项；零真实 API、零碰用户库）

    /// 验证「配了全局预置音色 → 未克隆视频一键改写**零克隆直合成**」这条主链路真的通。
    ///
    /// 为什么需要这支腿（M1a 计划遗留，原以真机端到端替代）：
    /// `rewrite()` 是 App 层唯一同时承载「音色解析 →克隆分支判定 → 改写 → 落库 → 批量合成」
    /// 的方法，而它此前**只有真机点击一条入口**。真机验证有三个盲区：
    /// ① 要点四层界面才能走到，回归成本高、失败时定位不到是哪一段；
    /// ② 「零克隆」这个核心主张只能靠"没报错"间接推断，无法证伪；
    /// ③ 每次验证都要真调AI + 真调 TTS = 真花钱。
    /// 本腿把这三点变成可重复、零成本的机械判据：内存库 + 假 AI provider + 假 TTS 客户端。
    ///
    /// 六段判据（逐段独立报，任何一段红不影响其余段落继续跑完）：
    ///   D1 未配置音色 → rewrite 阻断（不产 dub、不克隆）；
    ///   D2 配全局预置 → resolveForLegacy 命中 `.preset`（不走克隆优先）；
    ///   D3 **零克隆调用**（核心）—— fake vcClient 调用数必须为 0，且video.clonedVoiceId 仍为空；
    ///   D4 空壳绑定：脚本槽位经 ScriptDubBinding 拿到载体并回写 selectedSegmentDubId；
    ///   D5 generateAudio 成功（假 TTS 真跑finalize，产物落盘）；
    ///   D6 audioFilePath 存在且文件真实在盘。
    ///
    /// 隔离纪律：自建**内存容器**（`isStoredInMemoryOnly`，绝不碰用户库），
    /// 全局偏好串读写前存原值、跑完原样还原（不留污染）。
    /// 唯一写到磁盘的是 finalize 的产物 m4a（走生产FileHelper 路径），结束即删。
    @MainActor
    static func runVoiceReady(container: ModelContainer) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_voiceready.txt"
        var r: [String] = ["# 配音就绪腿（M1a/M1b 遗留；假 provider + 假 TTS，零真实 API）"]
        var pass = 0, fail = 0
        func judge(_ ok: Bool, _ label: String, _ detail: String = "") {
            if ok { pass += 1; r.append("✅ \(label)\(detail.isEmpty ? "" : "（\(detail)）")") }
            else { fail += 1; r.append("❌ FAIL \(label)\(detail.isEmpty ? "" : "（\(detail)）")") }
        }

        // —— 现场：内存库 + 一个未克隆的分镜 ——
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        let memContainer: ModelContainer
        do {
            memContainer = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        } catch {
            write(outPath, r + ["❌ 内存容器创建失败: \(error.localizedDescription)"]); return
        }
        let ctx = memContainer.mainContext
        let project = Project(name: "VOICE-READY-临时项目")
        let video = Video(name: "VOICE-READY-临时视频", localPath: "/tmp/voice-ready.mov")
        ctx.insert(project); ctx.insert(video)
        ProjectVideo.associate(project: project, video: video, in: ctx)
        let segment = SegmentCommitter().commitBare(
            segmentIndex: "seg_001", startTime: 0, endTime: 3,
            text: "这个厨房油污太难搞了", semanticTypes: [.painPoint],
            positionType: .middle, video: video, context: ctx
        )
        do { try ctx.save() } catch {
            write(outPath, r + ["❌ 内存库初始save 失败: \(error.localizedDescription)"]); return
        }

        // —— 全局偏好：跑完必须原样还原（这条腿不许给用户留下任何配置变化）——
        let savedGlobalRaw = VoicePreferences.globalDefaultRaw
        defer {
            VoicePreferences.globalDefaultRaw = savedGlobalRaw
            r.append("全局偏好已还原为 \(VoicePreferences.globalDefaultRaw ?? "nil")")
        }
        VoicePreferences.globalDefaultRaw = nil

        // —— 假 AI provider：只按 prompt 回一句可解析的改写结果，绝不联网——
        let fakeProvider = SelfRewriteProvider()
        // —— 假 TTS：真写一个可解码的 wav（finalize 要用），rawDuration 按台词字数估——
        let fakeCosy = SelfFakeTTS()
        let fakeVC = SelfFakeTTS()
        let vm = DubbingViewModel(tts: fakeCosy, vcClient: fakeVC,
                                  rewriteService: ScriptRewriteService(provider: fakeProvider))
        let presentation = DubScopePresentationMapper.presentation(for: .all)

        Task { @MainActor in
            // —— D1：未配置音色 → 阻断 ——
            let d1DubsBefore = segment.segmentDubs.count
            await vm.rewrite(video: video, targets: [segment],
                             presentation: presentation, context: ctx)
            let d1Blocked = vm.errorState != nil
                && segment.segmentDubs.count == d1DubsBefore
                && fakeVC.callCount == 0 && fakeCosy.callCount == 0
            judge(d1Blocked, "D1 未配置音色时阻断",
                  d1Blocked ? "已引导去设置，未产 dub、未调TTS" : "error=\(vm.errorState?.message ?? "nil") dub=\(segment.segmentDubs.count - d1DubsBefore) tts=\(fakeCosy.callCount + fakeVC.callCount)")
            if let e = vm.errorState { vm.errorState = nil }

            // —— D2：配全局预置 → 解析命中 preset（非克隆优先）——
            let presetID = CosyVoiceCatalog.all.first?.id ?? ""
            guard !presetID.isEmpty else {
                write(outPath, r + ["❌ CosyVoice 目录为空，无法继续"]); return
            }
            VoicePreferences.globalDefaultRaw = VoiceChoiceCoder.encode(.preset(voiceID: presetID))
            guard case .resolved(let resolvedChoice) =
                    VoicePreferences.resolveForLegacy(video: video, projectOverrideRaw: nil) else {
                write(outPath, r + ["❌ D2 配了全局预置仍解析为 unconfigured"]); return
            }
            let d2Hit = resolvedChoice.engine == .cosyVoice && resolvedChoice.voiceID == presetID
            judge(d2Hit, "D2 全局预置音色解析为 preset",
                  "voiceID=\(resolvedChoice.voiceID) engine=\(resolvedChoice.engine == .cosyVoice ? "cosyVoice" : "qwenVC")")
            r.append("   （该视频未克隆，按设计本就应回落全局；下面 D3 用「强制克隆在先」再验一次压制）")

            // —— D2b：克隆声在先 + 手动跟随全局 → 克隆被压制（回落预置，非克隆优先）——
            video.clonedVoiceId = "cosyvoice-vc-fake-clone"
            let beforeFollowRaw = VoicePreferences.globalDefaultRaw
            _ = beforeFollowRaw
            vm.setVideoFollowsGlobal(true, video: video, context: ctx)
            var d2bHit = false
            if case .resolved(let c) = VoicePreferences.resolveForLegacy(video: video, projectOverrideRaw: nil) {
                d2bHit = c.voiceID == presetID && c.engine == .cosyVoice
            }
            judge(d2bHit, "D2b 克隆声在先但已跟随全局 → 克隆被压制",
                  "voiceFollowsGlobal=\(video.voiceFollowsGlobal)")

            // —— D3（核心）：一键改写走 preset 分支 → **零克隆调用**——
            let vcBefore = fakeVC.callCount
            let cosyBefore = fakeCosy.callCount
            await vm.rewrite(video: video, targets: [segment],
                             presentation: presentation, context: ctx)
            let vcCalls = fakeVC.callCount - vcBefore
            let cosyCalls = fakeCosy.callCount - cosyBefore
            judge(vcCalls == 0, "D3 改写全程零 qwen-vc（克隆）合成调用",
                  "vcClient 调用 \(vcCalls) 次")
            judge(cosyCalls > 0, "D3b CosyVoice（预置）合成确有调用", "cosyClient 调用 \(cosyCalls) 次")
            judge(vm.errorState == nil, "D3c 改写未报错", vm.errorState?.message ?? "")

            let produced = segment.segmentDubs
            let voiced = produced.filter { $0.voiceId == presetID }
            let voicedWithAudio = voiced.filter { $0.audioFilePath != nil }
            r.append("   分镜产出变体 \(produced.count) 条，其中预置音色 \(voiced.count) 条、有音频 \(voicedWithAudio.count) 条")

            // —— D4：脚本槽位空壳绑定（ScriptDubBinding 四分支的 createNew/绑壳路径）——
            //现场：给同分镜建一个脚本族空壳（voiceId 空、无音频），走 generateScriptDub。
            let scheme = MixScheme(name: "VOICE-READY-临时方案")
            let slot = SchemeSegment(position: 1)
            ctx.insert(scheme); ctx.insert(slot)
            scheme.project = project
            slot.scheme = scheme
            slot.segment = segment
            let shell = SegmentDub(segment: segment, voiceId: "", voiceProvider: "cosyvoice",
                                   textVariantIndex: 99, rewrittenText: "这段是脚本成片的台词")
            ctx.insert(shell)
            segment.segmentDubs.append(shell)
            slot.selectedSegmentDubId = shell.id
            try? ctx.save()
            let okSlot = await vm.generateScriptDub(for: slot, scheme: scheme,
                                                    project: project, context: ctx)
            judge(okSlot, "D4 脚本空壳槽位生成成功",
                  "shell voiceId 空 → 绑定后=\(shell.voiceId) selectedDubId一致=\(slot.selectedSegmentDubId != nil)")
            let boundCorrectly = slot.selectedSegmentDubId != nil
            if let bound = try? ctx.fetch(FetchDescriptor<SegmentDub>()).first(where: { $0.id == slot.selectedSegmentDubId }) {
                judge(bound.voiceId == presetID, "D4b 槽位绑定到解析音色（预置）",
                      "bound voiceId=\(bound.voiceId)")
            } else {
                judge(false, "D4b 槽位绑定到解析音色（预置）", "绑定后取不到 dub")
            }
            _ = boundCorrectly

            // —— D5/D6：产物落盘判据 ——
            let allDubs = segment.segmentDubs
            let withPath = allDubs.filter { $0.audioFilePath != nil }
            var realFiles = 0
            var writtenPaths: [String] = []
            for d in withPath {
                if let p = d.audioFilePath, FileManager.default.fileExists(atPath: p) {
                    realFiles += 1
                    writtenPaths.append(p)
                }
            }
            judge(!withPath.isEmpty, "D5 至少一条变体带 audioFilePath",
                  "带路径 \(withPath.count)/\(allDubs.count)")
            judge(!withPath.isEmpty && realFiles == withPath.count, "D6 audioFilePath 指向的文件真实存在",
                  "在盘 \(realFiles)/\(withPath.count)")

            // 逐条明细，便于真机对照
            for d in allDubs.sorted(by: { $0.textVariantIndex < $1.textVariantIndex }) {
                let exists = d.audioFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                r.append("   变体 v\(d.textVariantIndex) voiceId=\(d.voiceId.isEmpty ? "(空壳)" : d.audioFilePath == nil ? d.voiceId : d.voiceId))"
                         + " 台词=\(d.rewrittenText.count)字 status=\(d.status.rawValue)"
                         + " 音频=\(d.audioFilePath == nil ? "无" : (exists ? "在盘" : "❌路径失效"))"
                         + " atempo=\(String(format: "%.2f", d.atempoFactor))")
            }

            // —— 清理：finalize 产物（唯一写盘的东西）———
            var cleaned = 0
            for p in writtenPaths { if (try? FileManager.default.removeItem(atPath: p)) != nil { cleaned += 1 } }
            // Dubs/{videoHash}/{segmentId}/ 整目录带走（同一segment 下的空目录不留）
            let hashDir = FileHelper.appSupportDirectory
                .appendingPathComponent("Dubs", isDirectory: true)
                .appendingPathComponent(video.contentHash ?? video.id.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: hashDir)
            r.append("已清理产物 \(cleaned) 个文件 + 哈希目录")

            r.append("")
            r.append(fail == 0 ? "结论：\(pass)/\(pass + fail) 段全绿 ✅" : "结论：\(pass) 绿 / \(fail) 红 ❌")
            r.append("[done]")
            write(outPath, r)
        }
    }

    /// 自检腿专用假 AI provider：按 prompt 里出现的分镜 id 回一条可解析结果，**绝不联网**。
    private actor SelfRewriteProvider: AIProvider {
        private(set) var callCount = 0
        func generateJSON<T: Decodable>(prompt: String, responseType: T.Type,
                               scene: AIScene) async throws -> T {
            callCount += 1
            // RewriteResultDTO 是本腿唯一关心的 responseType；其余类型本腿不会请求。
            guard let dto = Self.makeRewriteDTO(from: prompt) as? T else {
                throw AIProviderError.invalidResponse("自检假 provider 只支持 RewriteResultDTO")
            }
            return dto
        }
        func generateText(prompt: String, scene: AIScene) async throws -> String {
            callCount += 1; return ""
        }

        /// 从 prompt 里捞出全部 `"seg_xxx"` 形式的分镜 id（RewritePromptBuilder 以 id 建行）。
        /// 返回与原句等长但措辞不同的改写句，落在字数预算内，避免触发 fallback。
        static func makeRewriteDTO(from prompt: String) -> RewriteResultDTO {
            let ids = Self.segmentIDs(in: prompt)
            let items = ids.map { id in
                RewriteResultDTO.Item(segmentId: id, rewrittenText: "自检假改写文案\(id.count)字用于对齐验证")
            }
            return RewriteResultDTO(segments: items)
        }
        static func segmentIDs(in prompt: String) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for token in prompt.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\"" || $0 == "," || $0 == "：" || $0 == ":" }) {
                let t = String(token)
                if t.hasPrefix("seg_") && !t.contains("，") && t.count <= 24 && seen.insert(t).inserted {
                    out.append(t)
                }
            }
            return out
        }
    }

    /// 自检腿专用假 TTS 客户端：真写一个可解码的 wav（finalize 要用），但**不打任何网络**。
    /// 记录调用次数用于「零克隆调用」判据；rawDuration 按字数估算（让 finalize 的 atempo 链有东西可算）。
    private final class SelfFakeTTS: TTSClient, @unchecked Sendable {
        private(set) var callCount = 0
        /// 每秒字数（中文口播约 5 字/秒，取偏慢值让 atempo 落在合理区间）。
        private let charsPerSecond = 4.0
        /// 采样率与位深：44.1kHz / 16bit 单声道 PCM WAV（finalize 的 ffmpeg 认得）。
        private let sampleRate = 44100.0
        private let bytesPerSample: Int = 2

        func synthesize(text: String, voiceId: String,
                        languageType: String, rate: Double) async throws -> TTSResult {
            callCount += 1
            let chars = max(1.0, Double(text.count))
            let seconds = max(0.5, chars / charsPerSecond)
            let url = FileHelper.tempDirectory
                .appendingPathComponent("voiceready-fake-\(UUID().uuidString).wav")
            try Self.writeSilentWav(to: url, seconds: seconds, sampleRate: sampleRate,
                                    bytesPerSample: bytesPerSample)
            return TTSResult(wavPath: url.path, rawDuration: seconds)
        }

        /// 写一个头信息规范、数据为静音的 WAV。静音是刻意的：本腿要验的是
        /// 「管线能不能跑通并在盘落产物」，不是音质；静音同样能被 ffmpeg 正常转码。
        private static func writeSilentWav(to url: URL, seconds: Double,
                                           sampleRate: Double, bytesPerSample: Int) throws {
            let totalFrames = Int(seconds * sampleRate)
            let dataBytes = totalFrames * bytesPerSample
            var pcm = Data(count: dataBytes)   // 全零 = 静音
            let byteRate = Int(sampleRate) * bytesPerSample
            var data = Data()
            func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: Array("RIFF".utf8))
            append(UInt32(36 + dataBytes))
            data.append(contentsOf: Array("WAVEfmt ".utf8))
            append(UInt32(16))                 // fmt chunk size
            append(UInt16(1))                  // PCM
            append(UInt16(1))                  // 单声道
            append(UInt32(sampleRate))
            append(UInt32(byteRate))
            append(UInt16(bytesPerSample))
            append(UInt16(16))                 // bits per sample
            data.append(contentsOf: Array("data".utf8))
            append(UInt32(dataBytes))
            data.append(pcm)
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - G3 方案生成实跑（临时项目，跑完即删，不污染真实数据）

    @MainActor
    static func runGenSchemes(container: ModelContainer, target: Int) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_gen.txt"
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()),
              let video = videos.max(by: { $0.segments.flatMap(\.segmentDubs).count < $1.segments.flatMap(\.segmentDubs).count }) else {
            write(outPath, ["无视频"]); return
        }
        // 临时项目（链接同一视频，全局共享）
        let temp = Project(name: "【自检临时】请忽略")
        temp.status = .ready
        ctx.insert(temp)
        ProjectVideo.associate(project: temp, video: video, in: ctx)
        try? ctx.save()
        let tempId = temp.id
        write(outPath, ["# G3 方案生成实跑(临时项目)", "目标视频数: \(target)", "[运行中…]"])

        let vm = SchemeViewModel()
        vm.setModelContext(ctx)
        Task { @MainActor in
            await vm.generateSchemes(for: temp, targetVideoCount: target)
            // 统计三层
            let ai = vm.aiStrategies
            let allSchemes = ai.flatMap(\.orderedSchemes)
            let groups = Set(allSchemes.compactMap { $0.templateGroupId })
            let variantNamed = allSchemes.filter { $0.name.contains("变体") }.count
            var r = ["# G3 方案生成实跑(完成,临时项目)",
                     "进度文案: \(vm.generationProgress)",
                     "AI策略数: \(ai.count)",
                     "模板组数(templateGroupId 去重): \(groups.count)",
                     "变体视频总数: \(allSchemes.count)，命名含「变体」: \(variantNamed)"]
            if let err = vm.errorMessage { r.append("errorMessage: \(err)") }
            // 抽一个模板组看其变体的 selectedSegmentDubId 是否各异
            if let g = groups.first {
                let inGroup = allSchemes.filter { $0.templateGroupId == g }
                r.append("样例模板组变体数: \(inGroup.count)")
                for sc in inGroup.prefix(4) {
                    let dubIds = sc.orderedSegments.compactMap { $0.selectedSegmentDubId?.uuidString.prefix(6) }
                    r.append("  变体#\(sc.templateVariantIndex) name=\(sc.name) dubs=\(dubIds.joined(separator: ","))")
                }
            }
            // —— 清理临时项目(删 strategies/schemes/schemeSegments/projectVideo/project) ——
            if let schemes = try? ctx.fetch(FetchDescriptor<MixScheme>()) {
                for sc in schemes where sc.project?.id == tempId { ctx.delete(sc) }
            }
            if let strats = try? ctx.fetch(FetchDescriptor<MixStrategy>()) {
                for st in strats where st.project?.id == tempId { ctx.delete(st) }
            }
            if let pvs = try? ctx.fetch(FetchDescriptor<ProjectVideo>()) {
                for p in pvs where p.project?.id == tempId { ctx.delete(p) }
            }
            if let projs = try? ctx.fetch(FetchDescriptor<Project>()) {
                for p in projs where p.id == tempId { ctx.delete(p) }
            }
            try? ctx.save()
            r.append("[临时项目已清理]")
            r.append("[done]")
            write(outPath, r)
        }
    }

    private static func ffmpegProbe(_ path: String) -> String {
        guard let bin = Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg").path,
              FileManager.default.fileExists(atPath: bin) else { return "(无 ffmpeg)" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-i", path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return "(probe 失败: \(error))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(separator: "\n").filter { $0.contains("Duration") || $0.contains("Stream") }
            .joined(separator: "\n")
    }

    private static func write(_ path: String, _ lines: [String]) {
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: 判据五格矩阵（本案 🔴 前置）
    //
    // 见 docs/superpowers/plans/2026-10-04-toone-crossing-real-delete.md §4。
    // 要回答的问题只有一个：`isGoneFromGraph`（= `isDeleted || modelContext == nil`）
    // 在五种相位下会不会**两信号都说活着、而读 `.id` 其实要 trap**。
    // 那一读可能直接命中 SwiftData 内部断言把进程带走，所以：
    // ① 自建**内存容器**，绝不碰用户的库；② 每格**先落盘再读**，报告最后一行停在「即将读」= 该格会崩，
    // 读到值 = 该格不崩。判据值本身也写进报告，好分辨「过严（少画）」与「不足（仍崩）」。

    /// 造一格的现场：A/B 两个项目共享一颗 Video，Video 的 `ownerProject` 指向 A（本案崩点的那条边）。
    /// `storeURL != nil` ⇒ 用**有盘** store（第⑨格用，路径一律由调用方给临时目录，绝不指用户库）。
    @MainActor
    private static func tombstoneGrid(storeURL: URL? = nil) throws -> (container: ModelContainer, ctx: ModelContext,
                                                   a: Project, b: Project, v: Video, pvA: ProjectVideo) {
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        let config: ModelConfiguration
        if let storeURL {
            config = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext
        let a = Project(name: "IT-A")
        let b = Project(name: "IT-B")
        let v = Video(name: "IT-shared", localPath: "/tmp/it-shared.mov")
        ctx.insert(a); ctx.insert(b); ctx.insert(v)
        v.ownerProject = a
        // 关联行一律走 `associate` 工厂（TC-19a 钉着"全仓只许工厂本体裸构造 1 处"）：
        // 自检现场跟着生产走同一条路，既不开豁免口子，测到的也是真实挂载语义（含幂等判重）。
        let pvA = ProjectVideo.associate(project: a, video: v, in: ctx)
        ProjectVideo.associate(project: b, video: v, in: ctx)
        // 一颗真实分镜挂在 v 上：⑯c/d 的卡片快照断言需要 fetched segments，
        // 否则现场零分镜、快照恒为 0。只写自有列 + 同视频边。
        let s = SegmentCommitter().commitBare(
            segmentIndex: "IT-1", startTime: 0, endTime: 1,
            text: "IT-seg", semanticTypes: [.transition],
            positionType: .middle, video: v, context: ctx
        )
        try ctx.save()
        return (container, ctx, a, b, v, pvA)
    }

    @MainActor
    private static func runTombstoneMatrix(single: Int?, grid16: String?) {
        let outPath = ProcessInfo.processInfo.environment["MIXCUT_SELFTEST_OUT"]
            ?? NSTemporaryDirectory() + "\(Brand.shortName)_tombstone_matrix.txt"

        // ⑯ 子档：MIXCUT_SELFTEST_GRID16 = a/b/c/d/e/f/all。
        // "all" 只跑 b-f（a 会 trap 带走进程；a 必须单独指定）。
        if let grid16 {
            runGrid16(which: grid16, outBase: outPath)
            return
        }
        let titles = ["① delete 未 save", "② delete + safeSave", "③ cascade 摘除（ProjectVideo）",
                      "④ 跨 to-one 边（delete+save 之后）", "⑤ 子 context 删 + save（mainContext 已 fault）",
                      "⑥ 跨 to-one 边（delete 未 save，本案候选相位）", "⑦ 存储层批删 delete(model:where:) 后跨边读",
                      "⑧ 通知驱动的重算相位（读数另见 <报告>.grid8.txt）",
                      "⑨ 有盘 store 四相位（读数另见 <报告>.grid9.txt）",
                      "⑪ save 失败的半完成态（读数另见 <报告>.grid11.txt）",
                      "⑬ 驱逐/重开后重新 fault（读数另见 <报告>.grid13.txt）",
                      "⑭ 刀 9 咽喉的功能验证（读数另见 <报告>.grid14.txt）",
                      "⑮ 唯一发布口 + 中心广播的功能验证（读数另见 <报告>.grid15.txt）",
                      "⑯a 旧读法 trap 证据（<报告>.grid16a.txt；必须单独运行）",
                      "⑯b 悬空 ⇒ 索引 nil（.grid16b.txt）",
                      "⑯c 活边正向 UUID（.grid16c.txt）",
                      "⑯d 修复→重开端到端 + 幂等（.grid16d.txt）",
                      "⑯e 悬空边参数化·注册表全边（.grid16e.txt）",
                      "⑯f 修复失败隔离（.grid16f.txt）"]
        var lines: [String] = ["# 判据矩阵（内存容器，不碰用户库）"]
        func commit() { write(outPath, lines) }

        if single == nil || single == 8 { runObservationGrid(outPath: outPath) }
        if single == nil || single == 9 { runDiskGrids(outPath: outPath) }
        if single == nil || single == 11 { runFailedSaveGrid(outPath: outPath) }
        if single == nil || single == 13 { runReopenGrid(outPath: outPath) }
        if single == nil || single == 14 { runSettleGrid(outPath: outPath) }
        if single == nil || single == 15 { runBroadcastGrid(outPath: outPath) }
        for g in (single.map { [$0] } ?? Array(1...7)) {
            guard (1...7).contains(g) else { continue }
            lines.append("")
            lines.append("## 格 \(g) \(titles[g - 1])")
            commit()
            guard let scene = try? tombstoneGrid() else {
                lines.append("- 内存容器建不起来 ⇒ 本格无读数")
                commit(); continue
            }
            // 施加删除，并取出「本格要读的那颗对象」。④ 特意从**活**对象身上跨边去拿，正是崩点的形状。
            var target: (any PersistentModel)?
            var setup = ""
            switch g {
            case 1:
                scene.ctx.delete(scene.a); target = scene.a
                setup = "已 delete(A)，未 save"
            case 2:
                scene.ctx.delete(scene.a); _ = scene.ctx.safeSave(); target = scene.a
                setup = "已 delete(A) + safeSave"
            case 3:
                scene.ctx.delete(scene.a); _ = scene.ctx.safeSave(); target = scene.pvA
                setup = "delete(A) + save 后看被级联的 ProjectVideo（A→B 的关联行应仍在世）"
            case 4:
                scene.ctx.delete(scene.a); _ = scene.ctx.safeSave()
                target = scene.v.ownerProject
                setup = "delete(A) + save；从活着的 Video 跨 ownerProject 边取目标"
                lines.append("- Video.ownerProject 是否仍非 nil = \(scene.v.ownerProject != nil)")
            case 6:
                // 崩点日志的相位候选：真删已发出、save 还没走，边上的指针可能还指着那颗 isDeleted 的对象。
                scene.ctx.delete(scene.a)
                target = scene.v.ownerProject
                setup = "delete(A) 未 save；从活着的 Video 跨 ownerProject 边取目标"
                lines.append("- Video.ownerProject 是否仍非 nil = \(scene.v.ownerProject != nil)")
            case 7:
                // 前案 §3 刀 3 说过这条 API「不动内存里已 materialize 的对象 ⇒ 只会制造更多待读的死对象」，
                // 所以它是最可能造出真相位的那一种删法。
                let aid = scene.a.id
                // 上一版这里写的是 `(try? …) != nil`，把错误整个吞掉 ⇒ 只报出"成功=false"却答不出为什么。
                // 这恰是本仓明令禁止的静默忽略，改成显式捕获，把抛因原样落进报告。
                do {
                    try scene.ctx.delete(model: Project.self,
                                         where: #Predicate<Project> { $0.id == aid })
                    setup = "存储层批删成功（未 save）⇒ 跨边读目标对象"
                    target = scene.v.ownerProject
                    lines.append("- 批删后跨边取 ownerProject：非 nil = \(scene.v.ownerProject != nil)")
                } catch {
                    setup = "存储层批删抛错 ⇒ \(type(of: error))：\(error.localizedDescription)"
                }
            case 5:
                let sub = ModelContext(scene.container)
                let aName = scene.a.name
                if let copy = (try? sub.fetch(FetchDescriptor<Project>()))?.first(where: { $0.name == aName }) {
                    sub.delete(copy); try? sub.save()
                    setup = "子 context 删 A + save（照 MixCutApp.swift:354/398/427 那颗独立 context 的形状）"
                } else { setup = "子 context 里没找到 A ⇒ 本格无读数" }
                target = scene.a
            default: break
            }
            lines.append("- 现场：\(setup)")
            commit()
            guard let t = target else {
                lines.append("- 判定：目标已不在内存里（跨边读到 nil）⇒ 无 `.id` 可读，门槛不会拦到活对象")
                commit(); continue
            }
            let gone = t.isGoneFromGraph
            lines.append("- isDeleted = \(t.isDeleted)")
            lines.append("- modelContext == nil = \(t.modelContext == nil)")
            lines.append("- modelContext === 本格 mainContext = \(t.modelContext === scene.ctx)")
            lines.append("- isGoneFromGraph（两信号析取）= \(gone)")
            lines.append("- 即将读 .id …（若报告停在这一行，说明该格读持久属性会 trap ⇒ 判据不足）")
            commit()
            let id = t.id
            lines.append("- .id 读到 = \(id) ⇒ 本格不崩。判据 = \(gone)："
                         + (gone ? "门槛会拦住这颗（若它其实能读，代价是界面少画一条 ⇒ 判据偏严，可接受但要记着）"
                                 : "门槛放行且实测能读 ⇒ 该格判据充分"))
            commit()
        }
    }

    // MARK: - 格 ⑯ a–f（悬空 fault 现场：SQL 直接造悬空外键）

    /// ⑯ 派发。`all` 只跑 b–f（a 会 trap 带走进程）。
    @MainActor
    private static func runGrid16(which: String, outBase: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grid16-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 每格必须使用**独立子目录**：各格内部都读写 `<dir>/g.store`，
        // 共用目录会让 b 删过 A 的库被 c/d 二次 seed（数据叠加、fetch 取到上一格残留行）。
        func sub(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }

        switch which {
        case "a": grid16a(dir: sub("a"), out: outBase + ".grid16a.txt")
        case "b": grid16b(dir: sub("b"), out: outBase + ".grid16b.txt")
        case "c": grid16c(dir: sub("c"), out: outBase + ".grid16c.txt")
        case "d": grid16d(dir: sub("d"), out: outBase + ".grid16d.txt")
        case "e": grid16e(dir: sub("e"), out: outBase + ".grid16e.txt")
        case "f": grid16f(out: outBase + ".grid16f.txt")
        case "all":
            grid16b(dir: sub("b"), out: outBase + ".grid16b.txt")
            grid16c(dir: sub("c"), out: outBase + ".grid16c.txt")
            grid16d(dir: sub("d"), out: outBase + ".grid16d.txt")
            grid16e(dir: sub("e"), out: outBase + ".grid16e.txt")
            grid16f(out: outBase + ".grid16f.txt")
        default:
            write(outBase + ".grid16.txt", ["未知子档：\(which)（可用 a/b/c/d/e/f/all；a 必须单独运行）"])
        }
    }

    /// 有盘 store 路径。
    private static func gridStoreURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("g.store")
    }

    /// 造满数据现场（A/B 项目 + 共享 Video，ownerProject=A）并落盘；
    /// 函数返回即随 `scene` 释放容器（identity map 消失）。
    @MainActor
    private static func seedPopulatedStore(_ url: URL) -> Bool {
        guard let scene = try? tombstoneGrid(storeURL: url) else { return false }
        return scene.ctx.safeSave()
    }

    /// 悬空现场：先造满现场，再用 SQL 直接删 A 行（模拟漏边的生产删除；
    /// ZVIDEO.ZOWNERPROJECT 保持指向被删行 = 永久悬空）。
    @MainActor
    private static func makeDanglingOwnerEdge(_ dir: URL) -> URL? {
        let url = gridStoreURL(dir)
        guard seedPopulatedStore(url) else { return nil }
        let r = sqlExec(at: url, "DELETE FROM ZPROJECT WHERE ZNAME='IT-A';")
        if !r.ok { MixLog.error("[Grid16] 造悬空失败：\(r.msg)") }
        return r.ok ? url : nil
    }

    /// 用指定 store 重开容器（全新 identity map）。
    private static func openContainer(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        return try ModelContainer(for: schema,
                                 configurations: [ModelConfiguration(schema: schema, url: url)])
    }

    /// 五类模型全量 fetch。
    @MainActor
    private static func fetchAll(_ ctx: ModelContext)
        -> (products: [Product], projects: [Project], pvs: [ProjectVideo],
            videos: [Video], segments: [Segment]) {
        ((try? ctx.fetch(FetchDescriptor<Product>())) ?? [],
         (try? ctx.fetch(FetchDescriptor<Project>())) ?? [],
         (try? ctx.fetch(FetchDescriptor<ProjectVideo>())) ?? [],
         (try? ctx.fetch(FetchDescriptor<Video>())) ?? [],
         (try? ctx.fetch(FetchDescriptor<Segment>())) ?? [])
    }

    /// 从五类活 fetch 结果构建解边索引。
    @MainActor
    private static func buildIndex(_ all: (products: [Product], projects: [Project],
                                          pvs: [ProjectVideo], videos: [Video],
                                          segments: [Segment])) -> LiveModelIDIndex {
        var index = LiveModelIDIndex()
        index.insert(all.products, id: \.id)
        index.insert(all.projects, id: \.id)
        index.insert(all.pvs, id: \.id)
        index.insert(all.videos, id: \.id)
        index.insert(all.segments, id: \.id)
        return index
    }

    /// ⑯a 旧读法（trap 证据；必须单独运行）。
    @MainActor
    private static func grid16a(dir: URL, out: String) {
        let probe = MatrixProbe(path: out)
        probe.emit("# ⑯a 旧读法 trap 证据")
        guard let url = makeDanglingOwnerEdge(dir) else { probe.emit("- 造现场失败"); return }
        do {
            let container = try openContainer(url)
            let ctx = container.mainContext
            let videos = try ctx.fetch(FetchDescriptor<Video>())
            probe.keepAlive(container: container, ctx: ctx, video: videos.first)
            guard let video = videos.first else { probe.emit("- 无 Video ⇒ 无读数"); return }
            let target = video.ownerProject
            probe.emit("- ownerProject 非 nil = \(target != nil)")
            guard let target else {
                probe.emit("- 边已被框架置 nil ⇒ 本相位无空壳，旧读法未 trap（假设证伪）")
                return
            }
            probe.emit("- isDeleted=\(target.isDeleted) modelContext==nil=\(target.modelContext == nil)")
            probe.emit("- 即将读旧读法 ownerProject?.id …（报告停在本行 = trap 机理坐实）")
            let id = target.id
            probe.emit("- 读到 = \(id)（未 trap，旧读法假设证伪）")
        } catch {
            probe.emit("- 开容器失败：\(error)")
        }
    }

    /// ⑯b 悬空 ⇒ 索引解析 nil、不 trap。
    @MainActor
    private static func grid16b(dir: URL, out: String) {
        let probe = MatrixProbe(path: out)
        probe.emit("# ⑯b 悬空边经 LiveIDIndex 解析")
        guard let url = makeDanglingOwnerEdge(dir) else { probe.emit("- 造现场失败"); return }
        do {
            let container = try openContainer(url)
            let ctx = container.mainContext
            probe.keepAlive(container: container, ctx: ctx, video: nil)
            let all = fetchAll(ctx)
            let index = buildIndex(all)
            guard let video = all.videos.first else { probe.emit("- FAIL：无 Video"); return }
            let resolved = index.uuid(for: video.ownerProject)
            let cards = all.segments.map(SegmentCardSnapshot.init)
            probe.emit("- 悬空边解析 = \(String(describing: resolved))（预期 nil）")
            probe.emit("- 快照构建 \(cards.count) 张，零 trap")
            probe.emit(resolved == nil ? "PASS" : "FAIL：预期 nil")
        } catch {
            probe.emit("- FAIL：\(error)")
        }
    }

    /// ⑯c 活边正向解析业务 UUID。
    @MainActor
    private static func grid16c(dir: URL, out: String) {
        let probe = MatrixProbe(path: out)
        probe.emit("# ⑯c 活边正向 UUID")
        let url = gridStoreURL(dir)
        guard seedPopulatedStore(url) else { probe.emit("- FAIL：造现场失败"); return }
        do {
            let container = try openContainer(url)
            let ctx = container.mainContext
            probe.keepAlive(container: container, ctx: ctx, video: nil)
            let all = fetchAll(ctx)
            let index = buildIndex(all)
            guard let video = all.videos.first,
                  let a = all.projects.first(where: { $0.name == "IT-A" }) else {
                probe.emit("- FAIL：现场缺 Video/IT-A"); return
            }
            let ownerResolved = index.uuid(for: video.ownerProject)
            // ProjectVideo 边：关联行的 project 解析必须走索引，**不许读 `$0.project?.name`**
            // （那会跨边 fault 业务列，与生产崩点同形）。A 由 fetched projects 直接定位，
            // 再比对解析出的 UUID 集合。
            let aIDSet: Set<UUID> = [a.id]
            let pvResolved = all.pvs
                .map { index.uuid(for: $0.project) }
                .filter { $0.map { aIDSet.contains($0) } ?? false }
            let ownerOK = ownerResolved == a.id
            let pvOK = !pvResolved.isEmpty && pvResolved.allSatisfy { $0 == a.id }
            probe.emit("- ownerProject 解析 = \(String(describing: ownerResolved))（应 \(a.id)）")
            probe.emit("- A 的 \(pvResolved.count) 关联行 project 边解析全部 == A.id")
            probe.emit(ownerOK && pvOK ? "PASS" : "FAIL")
        } catch {
            probe.emit("- FAIL：\(error)")
        }
    }

    /// ⑯d 修复 → 重开端到端 + 二次修复幂等。
    @MainActor
    private static func grid16d(dir: URL, out: String) {
        let probe = MatrixProbe(path: out)
        probe.emit("# ⑯d 修复→重开端到端")
        guard let url = makeDanglingOwnerEdge(dir) else { probe.emit("- FAIL：造现场失败"); return }

        let danglingSQL = """
            SELECT COUNT(*) FROM ZVIDEO
            WHERE ZOWNERPROJECT IS NOT NULL
              AND ZOWNERPROJECT NOT IN (SELECT Z_PK FROM ZPROJECT)
            """
        let before = sqlInt(at: url, danglingSQL)
        let report = DanglingEdgeRepair.run(at: url)
        let after = sqlInt(at: url, danglingSQL)
        let firstKey = "ZVIDEO.ZOWNERPROJECT"
        let firstChanges = report.repaired[firstKey] ?? 0
        probe.emit("- 修复前悬空=\(before ?? -1)（应 ≥1）；修复该边 changes=\(firstChanges)；修复后悬空=\(after ?? -1)（应 0）")
        probe.emit("- 备份路径：\(report.backupPath ?? "无")")

        // 二次修复：幂等
        let second = DanglingEdgeRepair.run(at: url)
        let secondTotal = second.repaired.values.reduce(Int32(0), +)
        probe.emit("- 二次修复：changes 合计=\(secondTotal)（应 0）")

        // 重开容器，索引/快照全程不 trap；B 侧活边仍可正向解析
        var reopenOK = false
        do {
            let container = try openContainer(url)
            let ctx = container.mainContext
            probe.keepAlive(container: container, ctx: ctx, video: nil)
            let all = fetchAll(ctx)
            let index = buildIndex(all)
            guard let video = all.videos.first,
                  let b = all.projects.first(where: { $0.name == "IT-B" }) else {
                probe.emit("- FAIL：重开后现场缺 Video/IT-B"); return
            }
            let ownerNil = index.uuid(for: video.ownerProject) == nil
            // B 的关联行：解析走索引，不读 `$0.project?.name`（跨边业务列 = 同形崩点）。
            let bIDSet: Set<UUID> = [b.id]
            let bPV = all.pvs
                .map { index.uuid(for: $0.project) }
                .filter { $0.map { bIDSet.contains($0) } ?? false }
            let bOK = !bPV.isEmpty && bPV.allSatisfy { $0 == b.id }
            let cards = all.segments.map(SegmentCardSnapshot.init)
            probe.emit("- 重开后悬空边 nil=\(ownerNil)；B 的 \(bPV.count) 关联行正向解析=\(bOK)；快照 \(cards.count) 张")
            reopenOK = ownerNil && bOK
        } catch {
            probe.emit("- FAIL：重开容器失败：\(error)")
        }
        let pass = before == 1 && firstChanges >= 1 && after == 0
            && secondTotal == 0 && reopenOK && !report.aborted
        probe.emit(pass ? "PASS" : "FAIL")
    }

    /// ⑯e 悬空边参数化（注册表全边）：SQL 造悬空 ⇒ count=1 ⇒ 修复 changes≥1 ⇒ count=0。
    @MainActor
    private static func grid16e(dir: URL, out: String) {
        let probe = MatrixProbe(path: out)
        probe.emit("# ⑯e 悬空边参数化（注册表 \(DanglingToOneEdge.registry.count) 边）")
        var allPass = true
        for (i, edge) in DanglingToOneEdge.registry.enumerated() {
            let edgeDir = dir.appendingPathComponent("e\(i)", isDirectory: true)
            try? FileManager.default.createDirectory(at: edgeDir, withIntermediateDirectories: true)
            let url = edgeDir.appendingPathComponent("e.store")
            guard seedPopulatedStore(url) else {
                probe.emit("- 边 \(i) \(edge.ownerTable).\(edge.column)：FAIL 造现场失败")
                allPass = false; continue
            }
            let testPK = 900_000 + i
            let insertSQL = """
                INSERT INTO \(edge.ownerTable) (Z_PK,\(edge.column))
                VALUES (\(testPK),999999)
                """
            var made = sqlExec(at: url, insertSQL)
            if !made.ok {
                // 退路：UPDATE 既有行该列为悬空值
                let updateSQL = """
                    UPDATE \(edge.ownerTable) SET \(edge.column)=999999
                    WHERE Z_PK=(SELECT Z_PK FROM \(edge.ownerTable) LIMIT 1)
                    """
                made = sqlExec(at: url, updateSQL)
            }
            guard made.ok else {
                probe.emit("- 边 \(i) \(edge.ownerTable).\(edge.column)：FAIL 造悬空失败（\(made.msg)）")
                allPass = false; continue
            }
            let countSQL = """
                SELECT COUNT(*) FROM \(edge.ownerTable)
                WHERE \(edge.column) IS NOT NULL
                  AND \(edge.column) NOT IN (SELECT Z_PK FROM \(edge.destinationTable))
                """
            let before = sqlInt(at: url, countSQL)
            let rep = DanglingEdgeRepair.run(at: url)
            let after = sqlInt(at: url, countSQL)
            let key = "\(edge.ownerTable).\(edge.column)"
            let changes = rep.repaired[key] ?? 0
            let ok = (before ?? 0) >= 1 && changes >= 1 && after == 0
            probe.emit("- 边 \(i) \(key)：before=\(before ?? -1) repaired=\(changes) "
                       + "after=\(after ?? -1) \(ok ? "PASS" : "FAIL")")
            if !ok { allPass = false }
        }
        probe.emit(allPass ? "PASS \(DanglingToOneEdge.registry.count)/\(DanglingToOneEdge.registry.count)"
                          : "FAIL（见上；失败边不伪装通过）")
    }

    /// ⑯f 修复失败隔离：不可打开路径不阻断，后续正常开库流程继续。
    @MainActor
    private static func grid16f(out: String) {
        let probe = MatrixProbe(path: out)
        probe.emit("# ⑯f 修复失败隔离")
        let badURL = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.store")
        let rep = DanglingEdgeRepair.run(at: badURL)
        // sqlite 可能延迟到 prepare 才报错：aborted 或全部计数 -1 都算「没修成且未阻断」。
        let isolated = rep.aborted || rep.counts.values.allSatisfy { $0 == -1 }
        probe.emit("- 不可打开路径：aborted=\(rep.aborted)；isolated=\(isolated)")

        // 后续流程继续：正常开一个内存容器
        let schema = Schema(versionedSchema: AppSchemaV1.self)
        var flowContinues = false
        do {
            _ = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            flowContinues = true
        } catch {
            flowContinues = false
        }
        probe.emit("- 正常开库流程继续 = \(flowContinues)")
        probe.emit(isolated && flowContinues ? "PASS" : "FAIL")
    }

    // MARK: - ⑯ 共用 SQL 小工具

    /// 无结果集语句。
    private static func sqlExec(at url: URL, _ sql: String) -> (ok: Bool, msg: String) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return (false, "open failed")
        }
        defer { sqlite3_close(db) }
        var msg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &msg) == SQLITE_OK { return (true, "") }
        return (false, msg.map { String(cString: $0) } ?? "unknown")
    }

    /// 单 Int 读数。
    private static func sqlInt(at url: URL, _ sql: String) -> Int32? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : nil
    }

    /// 格 ⑧：通知驱动的那一拍。
    ///
    /// 为什么非要有这一格：`ModelContextExtension.swift:8-9` 记着的机制是「删除时 SwiftData 会给**仍存活的
    /// 内存对象**发变更通知 ⇒ 那个视图在消失前又被求值一遍，此时读任何持久属性都命中内部断言」。
    /// ①-⑦ 全是**我们主动去读**，同步排出来一格都不崩 ⇒ 唯一还没排除的相位就是「被通知叫回来读」。
    ///
    /// ⚠️ 这格第一版给出过「onChange 压根没触发」的读数，那是**harness 自己的两个缺陷**造成的假阴性，
    ///    不是这一拍的性质，别拿它当证据：
    ///    ① `scene`（连带 container）随函数返回就被释放，容器一没，通知自然不会来；
    ///    ② `fired` 是在 `safeSave()` 之后**同步**读的，异步派发的通知来不及落。
    ///    现在容器与对象由 `MatrixProbe` 强持有，并在收尾前跑一段 runloop 等通知。
    /// 报告单独落盘（`<out>.grid8.txt`）：这一读可能直接把进程带走，不能拖累其它格的读数。
    @MainActor
    private static func runObservationGrid(outPath: String) {
        let probe = MatrixProbe(path: outPath + ".grid8.txt")
        probe.emit("# 格 ⑧ 通知驱动的重算相位（内存容器，不碰用户库）")
        guard let scene = try? tombstoneGrid() else { probe.emit("- 内存容器建不起来 ⇒ 无读数"); return }
        probe.keepAlive(container: scene.container, ctx: scene.ctx, video: scene.v)
        withObservationTracking {
            _ = scene.v.ownerProject            // 把观察挂在这条 to-one 边上，等同 body 里的那一行
        } onChange: {
            probe.fired = true
            probe.emit("- onChange 进来了 ⇒ 通知确实把『消失前那一次求值』叫回来了")
            probe.readAcrossEdgeAndID()
        }
        probe.emit("- 观察已挂好（容器与对象由探针强持有）；现在 delete(A) + safeSave 触发变更")
        scene.ctx.delete(scene.a)
        _ = scene.ctx.safeSave()
        // 给异步派发留一拍：转到下一个 runloop tick 再看 fired
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        probe.emit("- 收尾（已等过 1s runloop）：onChange 是否触发 = \(probe.fired)"
                   + (probe.fired ? "" : " ⇒ 通知仍没来：这一拍在**纯 SwiftData 层**复现不出来，"
                                       + "它依赖 SwiftUI 的 body 求值路径（本 harness 不是 SwiftUI 视图，测不到；"
                                       + "也不构成『这一拍安全』的证据）"))
    }

    /// 格 ⑨：有盘 store（临时目录，绝不指用户库）。
    /// 崩点发生在装了用户数据的**磁盘库**上，而 ①-⑧ 全在内存库里排 —— WAL 与 save 过程中
    /// 「先清存储行、再改写仍存活对象的关系」这一相位，内存库构造不出来，只能单独测。
    /// 三个相位各起一个新库：②′ 直接读、④′ 跨边读（save 之后）、⑥′ 跨边读（未 save）。
    @MainActor
    private static func runDiskGrids(outPath: String) {
        let probe = MatrixProbe(path: outPath + ".grid9.txt")
        probe.emit("# 格 ⑨ 有盘 store（临时目录，不碰用户库）")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-it-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for phase in ["②′ delete+save 后直接读", "④′ delete+save 后跨边读", "⑥′ delete 未 save 跨边读",
                      "⑩′ **新 context 重新 fetch** 后跨边读（悬空 FK 的 fault 路径）",
                      "⑫′ 有盘库上跑**存储层批删** delete(model:where:)（⑦ 的候选真相位）"] {
            probe.emit("")
            probe.emit("## \(phase)")
            let url = dir.appendingPathComponent("g\(UUID().uuidString).store")
            guard let scene = try? tombstoneGrid(storeURL: url) else {
                probe.emit("- 有盘库建不起来（路径 \(url.path)）⇒ 本相位无读数")
                continue
            }
            probe.keepAlive(container: scene.container, ctx: scene.ctx, video: scene.v)
            if phase.hasPrefix("⑩") {
                // 本案崩点不是"拿着旧引用读"：`rebuild()` 每次都**重新 fetch 全库**，
                // 再由 SwiftData 去 fault 那条指向已删行的 to-one 边。所以必须换一个**新 context** 才测得到这条路。
                scene.ctx.delete(scene.a)
                _ = scene.ctx.safeSave()
                probe.emit("- 已 delete(A) + safeSave；开一个**新 ModelContext** 重新 fetch Video")
                let fresh = ModelContext(scene.container)
                let fetched = (try? fresh.fetch(FetchDescriptor<Video>())) ?? []
                probe.emit("- 新 context fetch 到 Video \(fetched.count) 颗")
                let crossed = fetched.first?.ownerProject
                probe.emit("- 跨边取 ownerProject：非 nil = \(crossed != nil)"
                           + (crossed.map { "；isDeleted=\($0.isDeleted) modelContext==nil=\($0.modelContext == nil)" } ?? ""))
                probe.emit("- 即将读 .id …（报告停在这一行 = **悬空 FK 的 fault 解析**才是真相位）")
                if let crossed { probe.emit("- .id 读到 = \(crossed.id) ⇒ 新 fetch + 悬空边也不崩") }
                continue
            }
            if phase.hasPrefix("⑫") {
                // 前案 §3 刀 3 说这条 API「不动内存里已 materialize 的对象 ⇒ 只会制造更多待读的死对象」，
                // 而 ⑦（内存库）报的是"抛错"却没答出为什么 ⇒ 在有盘库上重做一遍，把错误原样落进报告。
                let aid = scene.a.id
                do {
                    try scene.ctx.delete(model: Project.self,
                                         where: #Predicate<Project> { $0.id == aid })
                    probe.emit("- 批删调用**没抛错**（此刻还没 save）")
                } catch {
                    probe.emit("- 批删抛错 ⇒ \(type(of: error))：\(error.localizedDescription)")
                }
                probe.emit("- 未 save 时跨边取 ownerProject：非 nil = \(scene.v.ownerProject != nil)")
                let saved = scene.ctx.safeSave()
                probe.emit("- safeSave = \(saved)；save 后跨边取 ownerProject：非 nil = \(scene.v.ownerProject != nil)")
                let crossed = scene.v.ownerProject
                if let crossed {
                    probe.emit("- 目标 isDeleted=\(crossed.isDeleted) modelContext==nil=\(crossed.modelContext == nil)")
                }
                probe.emit("- 即将读 .id …（报告停在这一行 = 批删留下的死对象才是本案真相位）")
                if let crossed { probe.emit("- .id 读到 = \(crossed.id) ⇒ 批删相位也不崩") }
                let fresh = ModelContext(scene.container)
                let projects = (try? fresh.fetch(FetchDescriptor<Project>()))?.count ?? -1
                probe.emit("- 新 context fetch Project 数 = \(projects)（2 ⇒ 批删压根没生效；1 ⇒ 行确实被清了）")
                continue
            }
            let saveFirst = !phase.hasPrefix("⑥")
            scene.ctx.delete(scene.a)
            if saveFirst { _ = scene.ctx.safeSave() }
            probe.emit("- 已 delete(A)，\(saveFirst ? "并 safeSave" : "未 save")")
            let target: (any PersistentModel)? = phase.hasPrefix("②") ? scene.a : scene.v.ownerProject
            probe.emit("- 跨边取到对象 = \(target != nil)；"
                       + (target.map { "isDeleted=\($0.isDeleted) modelContext==nil=\($0.modelContext == nil) isGoneFromGraph=\($0.isGoneFromGraph)" } ?? "无目标"))
            probe.emit("- 即将在**有盘 store** 上读 .id …（报告停在这一行 = 这一相位会 trap ⇒ 才是本案真相位）")
            if let target {
                let id = target.id
                probe.emit("- .id 读到 = \(id) ⇒ 本相位不崩")
            }
        }
    }

    /// 格 ⑪：**save 失败的半完成态**（`ModelContextExtension.safeSave` 返回 false 那一支）。
    ///
    /// 为什么单独测它：十格里唯一没覆盖的、又能解释「backing 被清了但内存标记没走完」的成因，
    /// 就是删除已在内存里生效、而落盘失败这一刻 —— 本仓 `safeSave` 明确会返回 false 并只记一条日志，
    /// 界面却已经看不见那一项了（投影在删除时就剪掉），于是内存与库**各说一套**。
    /// 造法：有盘库先正常 save，再把**所在目录改成只读**，然后 delete + safeSave ⇒ save 必然失败。
    /// 目录权限收尾改回可写，免得临时目录里留一堆删不掉的东西。全程只写 `NSTemporaryDirectory()`。
    @MainActor
    private static func runFailedSaveGrid(outPath: String) {
        let probe = MatrixProbe(path: outPath + ".grid11.txt")
        probe.emit("# 格 ⑪ save 失败的半完成态（临时目录，不碰用户库）")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-fail-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let scene = try? tombstoneGrid(
                storeURL: dir.appendingPathComponent("it.store")) else {
                probe.emit("- 有盘库建不起来 ⇒ 无读数"); return
            }
            probe.keepAlive(container: scene.container, ctx: scene.ctx, video: scene.v)
            let fm = FileManager.default
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            probe.emit("- 已把 store 所在目录改成只读（0555），现在 delete(A) + safeSave")
            scene.ctx.delete(scene.a)
            let saved = scene.ctx.safeSave()
            probe.emit("- safeSave 返回 = \(saved)"
                       + (saved ? " ⇒ 只读没拦住（本格读数不代表半完成态，别当结论用）" : " ⇒ 落盘失败，正是要测的那一刻"))
            probe.emit("- 死对象 A：isDeleted=\(scene.a.isDeleted) modelContext==nil=\(scene.a.modelContext == nil) isGoneFromGraph=\(scene.a.isGoneFromGraph)")
            probe.emit("- 活对象 V 跨边取 ownerProject：非 nil = \(scene.v.ownerProject != nil)")
            if let crossed = scene.v.ownerProject {
                probe.emit("- 跨边目标：isDeleted=\(crossed.isDeleted) modelContext==nil=\(crossed.modelContext == nil) isGoneFromGraph=\(crossed.isGoneFromGraph)")
            }
            probe.emit("- 即将读 A.id …（报告停在这一行 = 半完成态会 trap）")
            let idA = scene.a.id
            probe.emit("- A.id 读到 = \(idA) ⇒ 半完成态直接读不崩")
            probe.emit("- 即将跨边读 V.ownerProject?.id …")
            let crossedID = scene.v.ownerProject?.id
            probe.emit("- 跨边读到 = \(String(describing: crossedID)) ⇒ 半完成态跨边读也不崩")
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            _ = scene.ctx.safeSave()               // 恢复可写后补一次，让这次实验别把库留在坏状态
            try? fm.removeItem(at: dir)
            probe.emit("- 收尾：目录权限已还原、临时库已删")
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
            probe.emit("- 造环境失败：\(error.localizedDescription)")
        }
    }

    /// 格 ⑬：把对象**驱逐出 identity map 之后重新 fault** —— 排除法剩下的最后一条候选。
    ///
    /// 为什么 ⑩′ 不够：它换的是新 `ModelContext`，但**同一个 container 的 identity map 还在**，
    /// fetch 回来的还是那颗内存对象，压根没走"从盘上解析那条边"的路。
    /// 而两份崩溃报告都是长会话（进程活了约 12 小时 / 开机 42000s），SwiftData 会驱逐空闲对象、
    /// 之后再从 store 重新 fault —— 那一拍才是 ④′/⑩′ 都没碰到的相位。
    /// 造法：第一程建库 + delete(A) + save 后**彻底释放 container**，第二程用同一个 store URL 重开一个 container，
    /// 全新 identity map 里 fetch Video 再跨边读 —— 等价于"下次启动后第一次读那颗悬空边"。
    @MainActor
    private static func runReopenGrid(outPath: String) {
        let probe = MatrixProbe(path: outPath + ".grid13.txt")
        probe.emit("# 格 ⑬ 驱逐/重开后重新 fault（临时目录，不碰用户库）")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-reopen-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("it.store")
        // 第一程：造现场并落盘；函数一返回，container 就随 `scene` 一起释放（identity map 消失）
        func seedAndDelete() -> Bool {
            guard let scene = try? tombstoneGrid(storeURL: url) else {
                probe.emit("- 第一程：建库失败 ⇒ 无读数"); return false
            }
            probe.emit("- 第一程：A/B 两项目 + 共享 Video，ownerProject=A，已 save")
            scene.ctx.delete(scene.a)
            let ok = scene.ctx.safeSave()
            probe.emit("- 第一程：delete(A) + safeSave = \(ok)；本程结束即释放 container")
            return ok
        }
        _ = seedAndDelete()
        // 第二程：重开同一个 store —— 全新 container、全新 identity map
        do {
            let schema = Schema(versionedSchema: AppSchemaV1.self)
            let reopened = try ModelContainer(for: schema,
                                              configurations: [ModelConfiguration(schema: schema, url: url)])
            let ctx = ModelContext(reopened)
            let videos = (try? ctx.fetch(FetchDescriptor<Video>())) ?? []
            let projects = (try? ctx.fetch(FetchDescriptor<Project>()))?.count ?? -1
            probe.emit("- 第二程：重开成功。Project 数 = \(projects)（1 ⇒ A 确实被清掉）、Video 数 = \(videos.count)")
            let crossed = videos.first?.ownerProject
            probe.emit("- 重开后跨边取 ownerProject：非 nil = \(crossed != nil)")
            if let crossed {
                probe.emit("- 目标 isDeleted=\(crossed.isDeleted) modelContext==nil=\(crossed.modelContext == nil) isGoneFromGraph=\(crossed.isGoneFromGraph)")
            }
            probe.emit("- 即将读重开后的 .id …（报告停在这一行 = **悬空边重 fault 才是真相位**）")
            let id = videos.first?.ownerProject?.id
            probe.emit("- 读到 = \(String(describing: id)) ⇒ 重开后再 fault 也不崩")
        } catch {
            probe.emit("- 第二程：重开失败 ⇒ \(type(of: error))：\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// 格 ⑭：刀 9 咽喉的**功能验证**。编译门证明不了"结算到底做了什么"，所以在这里真跑一遍：
    /// 共享视频必须被改指仍在世的合作项目 B（而不是留给框架置 nil），
    /// 只有 A 引用的视频必须连带删掉，且对已删对象重复调用必须**全零返回**（幂等）。
    @MainActor
    private static func runSettleGrid(outPath: String) {
        let probe = MatrixProbe(path: outPath + ".grid14.txt")
        probe.emit("# 格 ⑭ 删项目咽喉的功能验证（内存容器，不碰用户库）")
        guard let scene = try? tombstoneGrid() else { probe.emit("- 建库失败 ⇒ 无读数"); return }
        let ctx = scene.ctx
        let solo = Video(name: "IT-solo", localPath: "/tmp/it-solo.mov")
        ctx.insert(solo)
        solo.ownerProject = scene.a
        ProjectVideo.associate(project: scene.a, video: solo, in: ctx)
        // 必须先落盘：生产里 ProjectVideo 是导入时就建好并保存的，而咽喉第①步读的是 `project.videos`
        // 这条关系 —— 不 save 就调，测的是"关系还没 materialize"的人造态，不是真实链路。
        _ = ctx.safeSave()
        let ownedCount = ((try? ctx.fetch(FetchDescriptor<Video>())) ?? [Video]())
            .filter { $0.ownerProject === scene.a }.count
        probe.emit("- 删前：A.videos 数 = \(scene.a.videos.count)（应 2：共享 + solo）、"
                   + "ownerProject===A 的视频数 = \(ownedCount)")
        let outcome = ctx.deleteProjectSettlingOwnerEdges(scene.a)
        probe.emit("- 咽喉返回：改指 \(outcome.repointedVideos) 颗、置空 \(outcome.clearedOwners) 颗、"
                   + "连带删视频 \(outcome.deletedVideoNames)、saveFailed=\(outcome.saveFailed)")
        probe.emit("- 删后：共享视频 ownerProject === B = \(scene.v.ownerProject === scene.b)")
        let reloaded = ModelContext(scene.container)
        let videos = (try? reloaded.fetch(FetchDescriptor<Video>()))?.count ?? -1
        let projects = (try? reloaded.fetch(FetchDescriptor<Project>()))?.count ?? -1
        probe.emit("- 落盘复核：Video \(videos) 颗（应 1：solo 被连带删）、Project \(projects) 颗（应 1）")
        let second = ctx.deleteProjectSettlingOwnerEdges(scene.a)
        probe.emit("- 幂等复核（对已删的 A 再调一次）：改指 \(second.repointedVideos)、"
                   + "置空 \(second.clearedOwners)、连带删 \(second.deletedVideoNames.count) 颗（应全 0）")
        let pass = outcome.repointedVideos == 1 && outcome.clearedOwners == 1
            && outcome.deletedVideoNames == ["IT-solo"]
            && scene.v.ownerProject === scene.b && videos == 1 && projects == 1
            && second.repointedVideos == 0 && second.deletedVideoNames.isEmpty
        let verdict = pass ? "通过 —— 归属改指在世项目、无引用视频连带删、重复调用不再删"
                          : "不通过 —— 按上面逐项读数定位"
        probe.emit("- 结论：\(verdict)")
    }

    /// 格 ⑮：刀 2 广播链的**功能验证**。编译门与源码扫描都证明不了"台账到底投不投得出去"，
    /// 而这一族里有两条恰恰是**只在运行时才成立**的判据：
    ///   ① 不可剪枝的变更集必须在发布口被降成 nil（观察者因此走全量重载）；
    ///   ② 嵌套那次**不许被丢弃**（外层剪 A、内层是顺带真删的 B，丢 B 就是回到"库里删了、投影还握着"）；
    ///   ③ 顶掉上一枚时，广播必须发生在新事务**登记之后** —— 否则观察者里一句 `flushNow()`
    ///      就会把还没登记 commit 的新事务"了结"成一次空调用，用户刚点的删除既不真删也不可撤销。
    /// 本格不建库（纯 App 层投递计数），因此不受 SwiftData 相位影响，读数可直接引用。
    @MainActor
    private static func runBroadcastGrid(outPath: String) {
        let probe = MatrixProbe(path: outPath + ".grid15.txt")
        probe.emit("# 格 ⑮ 发布口 + 中心广播的功能验证（不建库，只看投递）")

        var seen: [String] = []
        var reentry: (() -> Void)?
        let token = NotificationCenter.default.addObserver(
            forName: .mixCutDataDidUndo, object: nil, queue: nil) { note in
            let shape = (note.object as? GraphChange).map {
                "prune(proj=\($0.idsDeleted(of: .project).count),seg=\($0.idsDeleted(of: .segment).count))"
            } ?? "full"
            seen.append(shape)
            if let fire = reentry { reentry = nil; fire() }   // 一次性的重入装置
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let segChange: GraphChange = {
            var c = GraphChange(); c.noteDeleted([UUID()], of: .segment); return c
        }()
        let mixedChange: GraphChange = {
            var c = GraphChange()
            c.noteDeleted([UUID()], of: .segment)
            c.noteDeleted([UUID()], of: .scheme)   // 观察者不认得这类 ⇒ 整条该降级
            return c
        }()

        seen.removeAll()
        GraphBroadcast.post(segChange)
        let aDeliveries = seen.count, aShape = seen.first ?? "-"
        probe.emit("- A 可剪枝载荷：投递 \(aDeliveries) 次 \(seen)（应 1 次 prune(seg=1)）")

        seen.removeAll()
        GraphBroadcast.post(mixedChange)
        let bShape = seen.first ?? "-"
        probe.emit("- B 混入 .scheme：投递 \(seen.count) 次 \(seen)（应 1 次 full —— 降级生效，不许半剪）")

        seen.removeAll()
        let innerChange: GraphChange = {
            var c = GraphChange(); c.noteDeleted([UUID()], of: .segment); return c
        }()
        reentry = { GraphBroadcast.post(innerChange) }
        GraphBroadcast.post(segChange)
        let cDeliveries = seen.count
        probe.emit("- C 嵌套广播：投递 \(cDeliveries) 次 \(seen)"
                   + "（应 2 次，第二条是内层那次；只 1 次就是把它丢了 ⇒ 内层的 id 再没人剪）")

        seen.removeAll()
        var dCommitted = 0
        PendingDeletionCenter.shared.schedule(
            message: "自检验证：删除分镜",
            commit: { dCommitted += 1; return segChange },
            undo: {})
        PendingDeletionCenter.shared.flushNow()
        let dDeliveries = seen.count
        probe.emit("- D 中心代广播：commit 执行 \(dCommitted) 次、投递 \(dDeliveries) 次 \(seen)（应 1 / 1）")

        seen.removeAll()
        var eCommitted = 0
        PendingDeletionCenter.shared.schedule(
            message: "自检验证：空台账",
            commit: { eCommitted += 1; return GraphChange() },
            undo: {})
        PendingDeletionCenter.shared.flushNow()
        let eDeliveries = seen.count
        probe.emit("- E 空台账不发：commit \(eCommitted) 次、投递 \(eDeliveries) 次（应 1 / 0，"
                   + "否则每条删除都退化成全量重载 = 切页骨架闪烁回归）")

        seen.removeAll()
        var aCommitted = 0, bCommitted = 0
        reentry = { PendingDeletionCenter.shared.flushNow() }   // 观察者里重入中心（selectedProject.didSet 那条形状）
        PendingDeletionCenter.shared.schedule(
            message: "自检验证 A", commit: { aCommitted += 1; return segChange }, undo: {})
        PendingDeletionCenter.shared.schedule(
            message: "自检验证 B", commit: { bCommitted += 1; return segChange }, undo: {})
        PendingDeletionCenter.shared.flushNow()   // 若 F 的重入没把 B 收掉，这里补收尾，别把事务留在屏上
        let fDeliveries = seen.count
        probe.emit("- F 顶掉顺序（广播晚于登记）：A commit \(aCommitted) 次、B commit \(bCommitted) 次、"
                   + "投递 \(fDeliveries) 次（判据 a==1 且 b==1；b==0 意味着 B 的真删义务被一次空调用吃掉）")

        let pass = aShape.contains("seg=1") && aDeliveries == 1
            && bShape == "full"
            && cDeliveries == 2
            && dCommitted == 1 && dDeliveries == 1
            && eCommitted == 1 && eDeliveries == 0
            && aCommitted == 1 && bCommitted == 1
        let verdict = pass ? "通过 —— 投递/降级/不丢弃/中心代广播/顶掉顺序五条都成立"
                           : "不通过 —— 按上面逐项读数定位"
        probe.emit("- 结论：\(verdict)")
    }
}

/// 格 ⑧/⑨ 的载体。`withObservationTracking` 的 `onChange` 是 `@Sendable`，只能捕获 Sendable 的东西
/// ⇒ 报告缓冲、容器与被观察对象都塞进这个盒；字段只在主 actor 的一串调用里碰，故 `@unchecked`。
/// 容器/上下文/对象**必须强持有**：它们一旦释放，通知与 backing 都会先消失，读数就变成假阴性（第一版就栽在这）。
final class MatrixProbe: @unchecked Sendable {
    let path: String
    var lines: [String] = []
    var video: Video?
    var fired = false
    private var keepContainer: ModelContainer?
    private var keepContext: ModelContext?

    init(path: String) { self.path = path }

    func keepAlive(container: ModelContainer, ctx: ModelContext, video: Video?) {
        self.keepContainer = container
        self.keepContext = ctx
        self.video = video
    }

    /// 落盘即写：这一族读数全靠"进程被带走时最后一行是什么"来判读，
    /// 所以每行都必须立刻写到盘上，不能等收尾。
    func emit(_ s: String) {
        lines.append(s)
        flush()
    }

    /// 把当前缓冲写盘。收尾处显式调一次：万一 `readAcrossEdgeAndID` 里读到一半 trap，
    /// 最后一行「即将读」必须已经在盘上 —— 那正是这一格要的证据。
    func flush() {
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 崩点那一读：跨边拿目标，再 fault 它的持久标量。
    /// 若进程停在这儿，上一条「即将读」就是报告的最后一行 ⇒ 该相位确实会 trap。
    func readAcrossEdgeAndID() {
        guard let video else { emit("- 载体里的 Video 已释放 ⇒ 无对象可跨，本格无读数"); return }
        let target = video.ownerProject
        emit("- 跨边取 ownerProject：非 nil = \(target != nil)")
        guard let target else { emit("- 目标已是 nil ⇒ 框架先把边置空了，没有死对象可读"); return }
        emit("- 目标 isDeleted = \(target.isDeleted)；modelContext == nil = \(target.modelContext == nil)")
        emit("- 即将读 .id …（若报告停在这一行 = 这一拍会 trap ⇒ 门槛必须覆盖通知路径）")
        let id = target.id
        emit("- .id 读到 = \(id) ⇒ 这一拍不崩（门槛在这里拦住属多余，但方向保守）")
    }
}
#endif