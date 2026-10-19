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
// `.serialized`：见 `ExportCanvasReadbackTests.swift` 头部那段说明 —— 本目标的用例
// 每条都 spawn 多个 ffmpeg/ffprobe，并行跑会因资源压力出现"失败集合会移动"的假红。
// ============================================================================

@Suite("DG · 导出时长前置闸", .serialized)
struct ExportDurationGateTests {

    /// 造一块合成源；返回路径。
    private func source(_ dir: URL, seconds: Int = 6) async throws -> String {
        let path = dir.appendingPathComponent("src.mp4").path
        try await FFmpegRunner().run(arguments: [
            "-y", "-v", "error",
            // 输入全部在前、输出选项全部在后：`-c:v` 若写在第二个 `-i` 之前，会被当成
            // "用 libx264 去**解码** anullsrc" ⇒ `Unknown decoder 'libx264'`、开输入即失败。
            "-f", "lavfi", "-i", "testsrc=size=1080x1920:rate=30:duration=\(seconds)",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "\(seconds)",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path,
        ], totalDuration: nil, timeoutSeconds: 120, onProgress: nil)
        return path
    }

    @Test("1 秒输入 + 千川目标 ⇒ 导出前就被拦下，且**根本没有产出文件**")
    func shortExportIsBlockedBeforeRendering() async throws {
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

    @Test("阳性对照：5 秒输入必须真的导出，且落盘画布就是计划的 1080×1920")
    func fiveSecondExportActuallyWorks() async throws {
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

    /// 本条只测**一件事**：时长闸跟着交付目标走，不是全局硬编码。
    ///
    /// ⚠️ 它**不**断言"1 秒输入能导成功" —— 实测 `ExportService` 喂 1 秒输入时，
    /// 包内 ffmpeg 8.1 会以 `rc=234` 失败，stderr 是 aac 编码器的
    /// `Error submitting audio frame to the encoder / Error encoding a frame: Invalid argument`。
    /// 那是**与本改动无关的既有缺陷**（已记台账 §六-9），分界点也没量出来；
    /// 把它写进本条断言，只会让"闸是否跟目标走"这条判据被一个无关故障绑住。
    @Test("闸跟着交付目标走：同一颗 1 秒输入，「不限」目标不得用时长理由拦它")
    func unrestrictedTargetDoesNotApplyTheDurationGate() async throws {
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
            // 允许它因别的原因失败（现实中就是那颗 rc=234），但**绝不允许**是时长闸拦的
            #expect(!text.contains("时长"),
                    "「不限」目标却用时长理由拦了 ⇒ 闸没跟着交付目标走：\(text)")
        } catch {
            // 非 ExportError 也不该是闸；闸只会以 ExportError.deliveryBlocked 出现
        }
    }
}
