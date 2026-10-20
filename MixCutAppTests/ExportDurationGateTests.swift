import Foundation
import Testing

@testable import SunCut

// ============================================================================
// DG · 整方案导出的**时长**前置闸（面板原文第四条校验「4s≤时长≤300s」）
//
// ## 为什么这组测试存在
//
// 分镜批量导出目录里躺着一颗真实产物 `1_视频库 (1).mp4` = 540×960 @ **3.066667s**
// （2026-10-19 ffprobe 实测）—— 宽度和时长两条都不合千川。而导出链路里此前
// 搜不到任何时长下限。尺寸那条已经修过一遍，时长是同一类缺口的另一半。
//
// ## 判别式设计
//
// 打的是**真 `ExportService.export`**，不是纯函数：
// ① 被拦时**必须根本没有产出文件** —— 这才证明它是"导出前就拦下"，
//    而不是"渲染完再把半成品删掉"（两种做法对用户完全不同：前者不浪费时间，后者会）。
// ② 配一条同管道的**阳性对照**：5 秒输入必须真的导出来，
//    否则"抛错"可能只是台架坏了、什么都导不出来。
// ③ 换「不限」目标必须放行同一颗短输入 —— 证明闸跟着交付目标走，不是全局硬编码。
//
// ## 台架
//
// `.serialized` ＋ `withFFmpegBench`：见 `ExportCanvasReadbackTests.swift` 头部那段说明 ——
// 本目标的用例每条都 spawn 多个 ffmpeg/ffprobe，并行跑会因资源压力出现"失败集合会移动"的假红；
// `.serialized` 只管组内顺序，跨 suite 的串行由 `withFFmpegBench` 收（2026-10-20 实测补上）。
// ============================================================================

@Suite("DG · 导出时长前置闸", .serialized)
struct ExportDurationGateTests {

    @Test("1 秒输入 + 千川目标 ⇒ 导出前就被拦下，且**根本没有产出文件**")
    func shortExportIsBlockedBeforeRendering() async throws {
        try await withFFmpegBench("shortExportIsBlockedBeforeRendering") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dg-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let src = try await source(dir)
            let out = dir.appendingPathComponent("out.mp4").path
            let input = ExportInput(segments: [(path: src, start: 0, end: 1)],
                                    maxWidth: 1080, maxHeight: 1920)
            do {
                try await ExportService().export(input: input, outputPath: out, config: ExportConfig())
                Issue.record("1 秒输入按千川目标（要求 4~300s）竞导出成功")
            } catch let error as ExportError {
                let text = error.errorDescription ?? ""
                #expect(text.contains("时长"), "报错要说是时长问题，实得：\(text)")
                #expect(text.contains("4s") || text.contains("4.0"), "要带平台要求的区间：\(text)")
                #expect(text.contains("不限"), "要指出「改选不限」这条出路：\(text)")
            }
            // 关键的一条：证明是**前置**拦，不是事后删
            #expect(!FileManager.default.fileExists(atPath: out),
                    "被拦下却留下了文件 ⇒ 它先渲染了再删，白烧了一遍时间")
        }
    }

    @Test("阳性对照：5 秒输入必须真的导出，且落盘画布就是计划的 1080×1920")
    func fiveSecondExportActuallyWorks() async throws {
        try await withFFmpegBench("fiveSecondExportActuallyWorks") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dg-ok-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let src = try await source(dir)
            let out = dir.appendingPathComponent("out.mp4").path
            var config = ExportConfig()
            config.resolution = .p1080
            let input = ExportInput(segments: [(path: src, start: 0, end: 5)],
                                    maxWidth: 1080, maxHeight: 1920)
            try await ExportService().export(input: input, outputPath: out, config: config)

            #expect(FileManager.default.fileExists(atPath: out), "5 秒输入没导出来")
            let probe = try await FFmpegRunner().runProbe(arguments: [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height,sample_aspect_ratio",
                "-show_entries", "format=duration", "-of", "csv=p=0", out])
            let cells = probe.split(separator: "\n").first.map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? []
            #expect(cells.first == "1080" && cells.dropFirst().first == "1920",
                    "落盘不是 1080×1920：\(probe)")
        }
    }

    /// 本条只测**一件事**：时长闸跟着交付目标走，不是全局硬编码。
    ///
    /// 它**不**断言"1 秒输入能导成功" —— 那是 `LC-I` 组（本文件末尾）的活。
    /// 两条分开才有取证力：本条红了说明闸没跟着目标走，那条红了说明编码器又吃下了静音。
    /// （曾经这里"不断言"是因为有一颗未修的 `rc=234` 既有缺陷绑住了它；缺陷已由
    /// `LoudnessChainPolicy` 收口，见台账 §六-9 的处置结果。）
    @Test("闸跟着交付目标走：同一颗 1 秒输入，「不限」目标不得用时长理由拦它")
    func unrestrictedTargetDoesNotApplyTheDurationGate() async throws {
        try await withFFmpegBench("unrestrictedTargetDoesNotApplyTheDurationGate") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("dg-free-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let src = try await source(dir)
            let out = dir.appendingPathComponent("out.mp4").path
            var config = ExportConfig()
            config.deliveryTarget = .unrestricted
            config.resolution = .p1080
            let input = ExportInput(segments: [(path: src, start: 0, end: 1)],
                                    maxWidth: 1080, maxHeight: 1920)
            do {
                try await ExportService().export(input: input, outputPath: out, config: config)
            } catch let error as ExportError {
                let text = error.errorDescription ?? ""
                // 允许它因别的原因失败（这条只问闸），但**绝不允许**是时长闸拦的
                #expect(!text.contains("时长"),
                        "「不限」目标却用时长理由拦了 ⇒ 闸没跟着交付目标走：\(text)")
            } catch {
                // 非 ExportError 也不该是闸；闸只会以 ExportError.deliveryBlocked 出现
            }
        }
    }
}

// ============================================================================
// LC-I · 「纯数字静音 + 短于 loudnorm 测量窗」的真导出腿（App 层）
//
// 台账 §六-9 那颗 `rc=234` 的既有缺陷，2026-10-20 沿产品链路重取分界后定位为：
//   包内 ffmpeg 8.1 的 `loudnorm` 吃**纯数字静音**且时长不足测量窗时吐 NaN ⇒
//   aac 编码器拒收 ⇒ 整条导出失败，屏上只有一句「视频处理失败（错误码 234）」。
// 分界实测（同一颗静音源、同一条链，只差时长）：2.5s / 2.9s 红，3.0s / 3.1s / 6.0s 绿。
// 有电平（440Hz）1.0s 绿、−81dB 级近静音 2.5s 绿 ⇒ 中毒面严格 = 全零采样。
//
// 下面这几条把"改前必然红、改后应当绿"钉在**真渲染**上，不靠读代码推断：
// · 第 1 条是最小复现（单段 1s 静音）；
// · 第 2 条是真产品可达形态（1s 静音 + 4s 有声 = 总 5s）—— 它过尺寸闸也过时长闸，
//   以前照样整条死在编码器里，所以只有真导一趟才能证明这次修的是那一颗；
// · 第 3 条守住"不许扩大作用面"：可听音频的探测必须回 false，近静音也算可听。
// ============================================================================

@Suite("LC-I · 短静音分镜真导出", .serialized)
struct LoudnessChainIntegrationTests {

    @Test("最小复现：1 秒纯数字静音单段必须真导出来（改前 rc=234）")
    func oneSecondPureSilentSegmentActuallyExports() async throws {
        try await withFFmpegBench("oneSecondPureSilentSegmentActuallyExports") {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }

            let src = try await source(dir)
            let out = dir.appendingPathComponent("out.mp4").path
            var config = ExportConfig()
            config.deliveryTarget = .unrestricted
            config.resolution = .p1080
            let input = ExportInput(segments: [(path: src, start: 0, end: 1)],
                                    maxWidth: 1080, maxHeight: 1920)
            try await ExportService().export(input: input, outputPath: out, config: config)

            #expect(FileManager.default.fileExists(atPath: out), "1 秒静音单段没导出来")
            let dur = try await duration(of: out)
            #expect(dur > 0.8 && dur < 1.3, "导出时长不是 1 秒量级，实得 \(dur)s")
        }
    }

    @Test("真产品可达形态：1s 静音分镜 + 4s 有声分镜（总 5s，两条闸都过）必须整条导出来")
    func schemeWithOneSilentShortSegmentExports() async throws {
        try await withFFmpegBench("schemeWithOneSilentShortSegmentExports") {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }

            let silent = try await source(dir, name: "sil")
            let audible = try await source(dir, name: "tone",
                                          audioGraph: "sine=frequency=440:sample_rate=44100")
            let out = dir.appendingPathComponent("out.mp4").path
            var config = ExportConfig()
            // 缺省就是千川目标：这条用例因此同时是"两条闸都放行 ⇒ 渲染也必须放行"的证据
            config.resolution = .p1080
            let input = ExportInput(segments: [(path: silent, start: 0, end: 1),
                                               (path: audible, start: 0, end: 4)],
                                    maxWidth: 1080, maxHeight: 1920)
            try await ExportService().export(input: input, outputPath: out, config: config)

            #expect(FileManager.default.fileExists(atPath: out),
                    "含一条 1s 静音分镜的方案整条导出失败（以前是 rc=234）")
            let dur = try await duration(of: out)
            #expect(dur > 4.6 && dur < 5.5, "两段拼接后总时长不是 5 秒量级，实得 \(dur)s")
        }
    }

    /// 守作用面：探测只认"全零采样"。可听与近静音都必须回 false ——
    /// 否则这次改动会把今天能导的片子一起改道成静音交付。
    @Test("静音探测的作用面：纯静音真、有电平假、近静音假")
    func silenceProbeScopeIsExactZeroOnly() async throws {
        try await withFFmpegBench("silenceProbeScopeIsExactZeroOnly") {
            let dir = try scratch()
            defer { try? FileManager.default.removeItem(at: dir) }

            let ff = FFmpegRunner()
            let silent = try await source(dir, name: "sil")
            let audible = try await source(dir, name: "tone",
                                          audioGraph: "sine=frequency=440:sample_rate=44100")
            let nearSilent = try await source(dir, name: "whisper",
                                              audioGraph: "sine=frequency=440:sample_rate=44100,volume=0.001")

            // `await` 必须写在 #expect 外面：宏参数里的 await 展不开（实测 error: cannot find 'await' in scope）。
            let onSilent = await ff.probePureDigitalSilence(path: silent, start: 0, end: 2.5)
            let onAudible = await ff.probePureDigitalSilence(path: audible, start: 0, end: 2.5)
            let onNearSilent = await ff.probePureDigitalSilence(path: nearSilent, start: 0, end: 2.5)

            #expect(onSilent, "纯数字静音没被判出来 ⇒ rc=234 那颗会原样复发")
            #expect(!onAudible, "440Hz 有电平被判成静音 ⇒ 有声分镜会被悄悄换成静音")
            #expect(!onNearSilent, "近静音（约 −81dB）被判成静音 ⇒ 改道面超出了今天必然失败的那些")
        }
    }
}

// MARK: - 台架共用（文件级 private，两个 suite 都走这一份造源逻辑）

/// 每次运行独立的临时目录。
/// 每次运行独立的临时目录。⚠️ 建目录失败必须**抛**，不许 `try?` 咽掉 ——
/// 本目标历史上四轮瞎红有一轮的抛点就在这里（咽掉之后症状会漂到下一条 ffmpeg 调用上）。
private func scratch(_ tag: String = "lc") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 造一块合成源；返回路径。`audioGraph` 决定音轨长什么样 ——
/// 默认是**纯数字静音**（`anullsrc`），另外两档用 `sine`（有电平 / 近静音）。
private func source(_ dir: URL,
                    name: String = "src",
                    seconds: Int = 6,
                    size: String = "1080x1920",
                    audioGraph: String = "anullsrc=r=44100:cl=stereo") async throws -> String {
    let path = dir.appendingPathComponent("\(name).mp4").path
    try await FFmpegRunner().run(arguments: [
        "-y", "-v", "error",
        // 输入全部在前、输出选项全部在后：`-c:v` 若写在第二个 `-i` 之前，会被当成
        // "用 libx264 去**解码** anullsrc" ⇒ `Unknown decoder 'libx264'`、开输入即失败。
        "-f", "lavfi", "-i", "testsrc=size=\(size):rate=30:duration=\(seconds)",
        "-f", "lavfi", "-i", audioGraph,
        "-t", "\(seconds)",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path,
    ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
    return path
}

/// 独立回读落盘时长（判据不靠被测链路自己报的数）。
private func duration(of path: String) async throws -> Double {
    let out = try await FFmpegRunner().runProbe(arguments: [
        "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
    guard let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw FFmpegError.outputParsingFailed("读不到时长：\(out)")
    }
    return d
}

// ============================================================================
// VB · 分镜批量「原版」腿 —— 只拦不改（台账 §六-2 漏口 #7 的收口）
//
// 2026-10-20 拍定：给"原版"加 scale 等于把这个名字变成谎话（它的意思就是源片原样），
// 所以这条腿的收法与变体那条**不同**：不合规格就整条不导（源文件仍进交付目录，但那是素材不是产物），
// 切完再回读一次落盘宽高。
//
// 判据打在**真 `VariantBatchExportService.exportAll`** 上（不是纯函数），三条分工：
// · 尺寸拦：480×960 是实传被拒名册里的一颗，且切片时长刻意给 5s ⇒ 只有尺寸这一条会命中；
// · 时长拦：1080×1920 尺寸全合，切片刻意给 2s ⇒ 只有时长这一条会命中。两条各自独立，
//   省得"其实是另一条拦的"被当成这条的证据；
// · 阳性对照：合规的 5s 必须真的导出来并回读 1080×1920 —— 否则前两条的"被拦下"
//   可能只是台架坏了、什么都导不出来。
// ============================================================================

@Suite("VB · 分镜批量原版腿", .serialized)
struct VariantOriginalLegTests {

    /// 跑一颗原版任务。返回 (成功数, 失败清单, 交付目录里的 mp4)。
    /// ⚠️ 源文件必须放在**另一个目录**：交付目录里留任何 mp4 都算这条腿没拦住。
    private func runOriginal(sourcePath: String, seconds: Double, outDir: URL,
                             config: ExportConfig = ExportConfig()) async
        -> (succeeded: Int, failed: [(String, String)], products: [String]) {
        let job = VariantExportJob.original(sourcePath: sourcePath, startTime: 0, endTime: seconds,
                                           fps: 30, fileName: "原版.mp4")
        let result = await VariantBatchExportService().exportAll(jobs: [job], outputDirectory: outDir) { _ in }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        let products = names.filter { $0.hasSuffix(".mp4") }
        return (result.succeeded, result.failed, products)
    }

    @Test("480×960 的原版 ⇒ 整条不导，失败清单写明「不可投放＋改选不限」，且交付目录里没有产物")
    func provenRejectedSizeIsBlocked() async throws {
        try await withFFmpegBench("provenRejectedSizeIsBlocked") {
            let srcDir = try scratch("vb-src"), outDir = try scratch("vb-out")
            defer { try? FileManager.default.removeItem(at: srcDir)
                    try? FileManager.default.removeItem(at: outDir) }

            let src = try await source(srcDir, name: "w480", seconds: 6, size: "480x960")
            let r = await runOriginal(sourcePath: src, seconds: 5, outDir: outDir)

            #expect(r.succeeded == 0 && r.failed.count == 1, "原版腿没拦下 480×960：\(r.failed)")
            let why = r.failed.first?.1 ?? ""
            #expect(why.contains("不可投放") && why.contains("不限"),
                    "拦下要说清「不可投放」并给出「改选不限」这条出路，实得：\(why)")
            #expect(r.products.isEmpty, "被拦下却往交付目录放了 mp4：\(r.products)")
        }
    }

    @Test("尺寸全合但只有 2 秒的原版 ⇒ 被时长那条拦下（与尺寸那条各自独立）")
    func shortOriginalIsBlockedByTheDurationRule() async throws {
        try await withFFmpegBench("shortOriginalIsBlockedByTheDurationRule") {
            let srcDir = try scratch("vb-src"), outDir = try scratch("vb-out")
            defer { try? FileManager.default.removeItem(at: srcDir)
                    try? FileManager.default.removeItem(at: outDir) }

            let src = try await source(srcDir, seconds: 6)
            let r = await runOriginal(sourcePath: src, seconds: 2, outDir: outDir)

            #expect(r.succeeded == 0 && r.failed.count == 1, "2 秒的原版没被时长那条拦下：\(r.failed)")
            let why = r.failed.first?.1 ?? ""
            #expect(why.contains("时长"), "报的要写清是时长问题，实得：\(why)")
            #expect(r.products.isEmpty, "被拦下却留下了产物：\(r.products)")
        }
    }

    @Test("阳性对照：合规的 5 秒 1080×1920 原版必须真导出来，回读宽高一致")
    func conformingOriginalActuallyLands() async throws {
        try await withFFmpegBench("conformingOriginalActuallyLands") {
            let srcDir = try scratch("vb-src"), outDir = try scratch("vb-out")
            defer { try? FileManager.default.removeItem(at: srcDir)
                    try? FileManager.default.removeItem(at: outDir) }

            let src = try await source(srcDir, seconds: 6)
            let r = await runOriginal(sourcePath: src, seconds: 5, outDir: outDir)

            #expect(r.succeeded == 1 && r.failed.isEmpty, "合规原版被拦或失败：\(r.failed)")
            #expect(r.products == ["原版.mp4"], "交付目录里的东西不对：\(r.products)")
            let landed = await FFmpegRunner().probeCanvasSize(
                path: outDir.appendingPathComponent("原版.mp4").path)
            #expect(landed == DeliveryCanvas(width: 1080, height: 1920),
                    "原版落盘画布不是源片的 1080×1920，实得 \(String(describing: landed))")
        }
    }
}
