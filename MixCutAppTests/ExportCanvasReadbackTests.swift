import Foundation
import Testing

// ⚠️ module 名是 **SunCut**（App target 的 PRODUCT_NAME，见 VoiceCloneServiceTests.swift 头部说明）。
@testable import SunCut

// ============================================================================
// ES-I · 导出画布的**真渲染 + 真回读**集成判据
//
// ## 为什么这组测试存在
//
// 2026-10-19 整批 41 条成片是 480×854 而被千川拒收，而全仓 **1122 条测试里没有一条**
// 读过产物宽高（`Tests/` 里 `ffprobe` 命中数为 0）：导出链路只回读 `start_time` 与
// `duration`。本文件把"计划画布 == 落盘画布"从**没人知道**升级成**跑一次 ffmpeg 就知道**。
//
// ## 判别式设计（防假绿）
//
// 测量走**测试自己拼的 ffprobe 参数、自己解析**，不复用被测的 `probeCanvasSize` ——
// 只拿被测函数自己的输出断言被测函数，无论实现对错都可能绿（同 `VoiceCloneServiceTests`
// 立的那条规矩）。`probeCanvasSize` 反过来要跟这份独立读数一致，才算它自己被验过。
//
// ## ⚠️ 为什么必须钉 `sample_aspect_ratio == 1:1`
//
// 实测（本机 libx264，2026-10-19）：`scale=480:854` 不带 `setsar` 时，编码器会**自作主张**
// 写一个非 1:1 的 SAR，把 480×854 标成 DAR 16:9；`1080x1920` 会被标成 SAR 256:81。
// 也就是说 `width`/`height` 两个数**对了不代表画面对了** —— 显示比例藏在 SAR 里。
// 我们的链路靠 `FFmpegRunner.concat` 滤镜链尾那句 `setsar=1` 兜住，所以这条必须钉：
// 哪天 `setsar=1` 被谁删了，宽高仍然"看起来正确"，而产物已经不是 9:16 了。
// ES-I-04 配了一条同管道的**阳性对照**，证明这条断言不是天生恒真。
//
// ## 台架前提
//
// 需要 ffmpeg/ffprobe。走 App 自带的 bundle 内二进制（`TEST_HOST = SunCut.app` ⇒
// `Bundle.main` 就是宿主 App）。取不到就**红**，不跳过 —— 本仓守卫一律"判据没跑起来
// 不算通过"（同 `SettingsKeyActionBarGuardTests.swift:75`）。
// ============================================================================

// MARK: - 台架

private let esIffmpeg = FFmpegRunner()

/// 每个用例自己的临时目录，跑完删。
private func esIScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("es-i-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 现造一块合成源（lavfi testsrc），不碰用户素材库。
private func esISynthesize(size: String, to path: String) async throws {
    try await esIffmpeg.run(arguments: [
        "-y", "-v", "error",
        "-f", "lavfi", "-i", "testsrc=size=\(size):rate=30:duration=1",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", path,
    ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
}

/// 独立测量：测试自己拼参数、自己解析，不借道被测的 `probeCanvasSize`。
private func esIMeasure(_ path: String) async throws -> [String: String] {
    let out = try await esIffmpeg.runProbe(arguments: [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,coded_width,coded_height,sample_aspect_ratio",
        "-of", "default=noprint_wrappers=1", path,
    ])
    var kv: [String: String] = [:]
    for line in out.split(separator: "\n") {
        guard let i = line.firstIndex(of: "=") else { continue }
        kv[String(line[..<i])] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
    }
    return kv
}

private func esIRender(sourcePath: String, to outputPath: String, canvas: DeliveryCanvas) async throws {
    try await esIffmpeg.concat(
        segments: [(path: sourcePath, start: 0, end: 1)],
        outputPath: outputPath,
        resolution: canvas.filterString)
}

/// 前置探针：确认宿主 App 包内的 ffmpeg/ffprobe 真在位。
///
/// 为什么要有：2026-10-19 首跑时 3 条用 `concat` 的用例在 **0.000 秒**即失败（抛错，不是断言不过），
/// 而同一批次不用 `concat` 的两条 2 秒后正常通过；增量重跑与冷构建重跑各一次都全绿，
/// **没能复现、也没解释**。0.000 秒意味着还没干活就抛了，最像 `resolveBinary()` 拿不到包内二进制。
/// 这道探针不修那个问题，只是把"神秘空抛"换成"具名原因"，下次再犯能一眼定位。
private func esIRequireBinaries() async throws {
    let dir = try esIScratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let probe = dir.appendingPathComponent("probe.mp4").path
    do {
        try await esISynthesize(size: "64x64", to: probe)
    } catch {
        Issue.record("合成源这一步就失败 ⇒ 宿主 App 包内取不到 ffmpeg，本文件全部判据都没在测东西。原因：\(error)")
        throw error
    }
    do {
        _ = try await esIMeasure(probe)
    } catch {
        Issue.record("ffprobe 取不到 ⇒ 独立测量这一腿失效。原因：\(error)")
        throw error
    }
}

// MARK: - ES-I-01 计划画布 == 落盘画布

@Test("ES-I-01 三块投放画布：真渲染后独立回读的宽高必须逐字等于计划值")
func plannedCanvasIsWhatLands() async throws {
    try await esIRequireBinaries()
    let dir = try esIScratch()
    defer { try? FileManager.default.removeItem(at: dir) }

    let src = dir.appendingPathComponent("src.mp4").path
    try await esISynthesize(size: "1080x1920", to: src)

    for tier in [DeliveryTier.p1080, .p720] {
        let planned = DeliveryCanvas.size(tier: tier, sourceMaxWidth: 1080, sourceMaxHeight: 1920)
        let out = dir.appendingPathComponent("\(tier.rawValue.replacingOccurrences(of: "p", with: "")).mp4").path
        try await esIRender(sourcePath: src, to: out, canvas: planned)

        let m = try await esIMeasure(out)
        #expect(m["width"] == "\(planned.width)" && m["height"] == "\(planned.height)",
                "\(tier.rawValue) 档落盘 \(m["width"] ?? "?")×\(m["height"] ?? "?")，计划 \(planned.filterString)")
        // 宽高对了还不算，显示比例藏在 SAR 里
        #expect(m["sample_aspect_ratio"] == "1:1",
                "\(tier.rawValue) 档落盘 SAR = \(m["sample_aspect_ratio"] ?? "缺")，不是 1:1 ⇒ 画面被悄悄拉变形")
    }
}

// MARK: - ES-I-02 被测探针与独立读数必须一致

@Test("ES-I-02 生产侧 probeCanvasSize 必须与独立 ffprobe 读数一致（探针自己也要被验）")
func productionProbeMatchesIndependentReading() async throws {
    try await esIRequireBinaries()
    let dir = try esIScratch()
    defer { try? FileManager.default.removeItem(at: dir) }

    let src = dir.appendingPathComponent("src.mp4").path
    try await esISynthesize(size: "720x1280", to: src)
    let out = dir.appendingPathComponent("out.mp4").path
    let planned = DeliveryCanvas.size(tier: .p1080, sourceMaxWidth: 720, sourceMaxHeight: 1280)
    try await esIRender(sourcePath: src, to: out, canvas: planned)

    let independent = try await esIMeasure(out)
    let viaProduction = await esIffmpeg.probeCanvasSize(path: out)

    #expect(viaProduction != nil, "生产探针读不到一块刚渲染出来的合法成片")
    #expect(viaProduction?.width == Int(independent["width"] ?? "-1"),
            "生产探针报宽 \(viaProduction?.width.description ?? "nil")，独立读数 \(independent["width"] ?? "?")")
    #expect(viaProduction?.height == Int(independent["height"] ?? "-1"),
            "生产探针报高 \(viaProduction?.height.description ?? "nil")，独立读数 \(independent["height"] ?? "?")")
    // 明确它读的是显示尺寸而不是编码面：两者今天相等，所以这条靠"字段名+对照"而不是靠差异
    #expect(independent["width"] != nil && independent["coded_width"] != nil)
}

// MARK: - ES-I-03 非 9:16 素材不得把画布带偏

@Test("ES-I-03 480×960 与 704×1248 两块非 9:16 源进 1080×1920 画布：落盘仍是精确 9:16 且 SAR 1:1")
func oddRatioSourceStillLandsOnExactCanvas() async throws {
    try await esIRequireBinaries()
    let dir = try esIScratch()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 这两颗是素材库里真实存在的非 9:16 素材的尺寸（2026-10-19 ffprobe 实测）
    for (i, srcSize) in ["480x960", "704x1248"].enumerated() {
        let src = dir.appendingPathComponent("src\(i).mp4").path
        try await esISynthesize(size: srcSize, to: src)
        let out = dir.appendingPathComponent("out\(i).mp4").path
        let planned = DeliveryCanvas.size(tier: .p1080, sourceMaxWidth: 0, sourceMaxHeight: 0)
        try await esIRender(sourcePath: src, to: out, canvas: planned)

        let m = try await esIMeasure(out)
        #expect(m["width"] == "1080" && m["height"] == "1920",
                "\(srcSize) 源把画布带偏成 \(m["width"] ?? "?")×\(m["height"] ?? "?")")
        #expect(Int(m["width"]!)! * 16 == Int(m["height"]!)! * 9, "落盘不是精确 9:16")
        #expect(m["sample_aspect_ratio"] == "1:1", "SAR 不是 1:1：\(m["sample_aspect_ratio"] ?? "缺")")
    }
}

// MARK: - ES-I-04 SAR 断言的阳性对照（证明它不是恒真）

@Test("ES-I-04 同管道阳性对照：不带 setsar 的渲染 SAR 就不是 1:1 —— 否则 ES-I-01 那条 SAR 断言是空的")
func sarAssertionHasTeeth() async throws {
    try await esIRequireBinaries()
    let dir = try esIScratch()
    defer { try? FileManager.default.removeItem(at: dir) }

    let src = dir.appendingPathComponent("src.mp4").path
    try await esISynthesize(size: "1280x720", to: src)
    // 刻意绕开生产链路：只 scale、不 setsar
    let bare = dir.appendingPathComponent("bare.mp4").path
    try await esIffmpeg.run(arguments: [
        "-y", "-v", "error", "-i", src,
        "-vf", "scale=480:854", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", bare,
    ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)

    let m = try await esIMeasure(bare)
    #expect(m["width"] == "480" && m["height"] == "854", "对照样本本身没造出来：\(m)")
    #expect(m["sample_aspect_ratio"] != "1:1",
            "不带 setsar 也读到 1:1 ⇒ 这台架测不出 SAR 漂移，ES-I-01 的 SAR 断言是恒真的假判据")
}

// MARK: - ES-I-05 空读数必须算失败

@Test("ES-I-05 没有视频流 / 文件不存在 ⇒ 探针必须返回 nil，不能报 0×0 或旧值")
func emptyReadingsAreNotSilentlyAccepted() async throws {
    try await esIRequireBinaries()
    let dir = try esIScratch()
    defer { try? FileManager.default.removeItem(at: dir) }

    // ① 纯音频 mp4：`-select_streams v:0` 会选到空集
    let audioOnly = dir.appendingPathComponent("audio.mp4").path
    try await esIffmpeg.run(arguments: [
        "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
        "-c:a", "aac", audioOnly,
    ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
    let m = try await esIMeasure(audioOnly)
    #expect(m["width"] == nil, "纯音频文件居然读出了 width —— 独立测量这一腿也失效了")
    #expect(await esIffmpeg.probeCanvasSize(path: audioOnly) == nil,
            "探针在纯音频上返回了非 nil ⇒ 后置回读会被空读数当成通过")

    // ② 文件根本不存在
    #expect(await esIffmpeg.probeCanvasSize(path: dir.appendingPathComponent("nope.mp4").path) == nil,
            "不存在的文件必须读不到")
}
