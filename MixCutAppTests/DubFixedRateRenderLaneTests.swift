import Foundation
import Testing

@testable import SunCut

// ============================================================================
// FR-R · 固定语速的**真渲染**腿（计划 §6.1 T16 的执行版）
//
// ## 为什么这一环必须在 App 腿
//
// `DubAudioFinalizer.atempoChain` 住在 App 层。Core 那边已经证完"裁决算得对"
// （`FixedRateGraphReproTests` 6 条）与"导出图复现得对"，剩最后一格是：
//     atempoFactor = 1.0 时，finalizer **到底会不会给音频加滤镜**。
// 会加 ⇒ 语速仍然被改，整条 A 块白做；不会加 ⇒ 时长物理上不可能变。
// 这一格只能靠真 ffmpeg 跑出来，静态读码不算（本仓纪律：静态核对 ≠ 跑过）。
//
// ## 测量独立性
//
// 时长用**测试自己拼的 ffprobe 参数、自己解析**，不复用被测的 probe 口 ——
// 否则是拿被测件证明被测件。另配一条**阳性对照**（探一段已知 1 秒的 testsrc）：
// 测量管线本身坏掉时，那一条会先红，不至于让下面四条"看起来都过"。
//
// ## 台架
//
// 本组每条都会 spawn ffmpeg/ffprobe ⇒ 必须 `.serialized`（管组内）**且**每条体
// 收进 `withFFmpegBench`（管跨 suite —— `.serialized` 只管单 suite，这是本仓实测出来的）。
// ============================================================================

private func frfScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("frf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 独立测量：自己拼参数、自己解析。
private func frfDuration(_ ffmpeg: FFmpegRunner, _ path: String) async throws -> Double {
    let out = try await ffmpeg.runProbe(arguments: [
        "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path
    ], timeoutSeconds: 60)
    guard let value = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw NSError(domain: "frf", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ffprobe 读数不可解析：\(out.debugDescription)"
        ])
    }
    return value
}

/// 造一段确定时长的正弦 wav（不依赖 TTS，零成本、可复跑）。
private func frfSineWav(_ ffmpeg: FFmpegRunner, seconds: Double, to path: String) async throws {
    try await ffmpeg.run(arguments: [
        "-y", "-v", "error", "-f", "lavfi",
        "-i", "sine=frequency=440:sample_rate=44100:duration=\(String(format: "%.3f", seconds))",
        "-ac", "1", path
    ], timeoutSeconds: 120)
}

private func frfRender(_ ffmpeg: FFmpegRunner, from src: String, filters: [String],
                       to dst: String) async throws {
    var args = ["-y", "-v", "error", "-i", src]
    if !filters.isEmpty {
        args += ["-filter:a", filters.joined(separator: ",")]
    }
    args += ["-c:a", "aac", "-b:a", "128k", dst]
    try await ffmpeg.run(arguments: args, timeoutSeconds: 300)
}

@Suite("FR-R · 固定语速真渲染", .serialized)
struct DubFixedRateRenderLaneTests {

    // MARK: 阳性对照 —— 测量管线本身可用

    @Test("FR-R-0 阳性对照：ffprobe 量一段已知 1 秒的产物必须读出 ≈1.0")
    func measurementPipelineWorks() async throws {
        try await withFFmpegBench("FR-R-0 阳性对照") {
            let ffmpeg = FFmpegRunner()
            let dir = try frfScratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let probe = dir.appendingPathComponent("probe.mp4").path
            do {
                try await ffmpeg.run(arguments: [
                    "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc=size=64x64:rate=30:duration=1",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", probe
                ], timeoutSeconds: 120)
            } catch {
                Issue.record("宿主 App 包内取不到 ffmpeg ⇒ 本文件全部判据都没在测东西。原因：\(error)")
                throw error
            }
            let d: Double
            do { d = try await frfDuration(ffmpeg, probe) }
            catch {
                Issue.record("ffprobe 取不到 ⇒ 独立测量这一腿失效。原因：\(error)")
                throw error
            }
            #expect(abs(d - 1.0) < 0.05, "阳性对照读出 \(d)s，不是 1s ⇒ 测量管线本身不可信，下面四条不作数")
        }
    }

    // MARK: 核心那一格 —— atempo 1.0 是否真的不加任何滤镜

    @Test("FR-R-1 atempoChain(1.0) 必须返回空 ⇒ finalizer 根本不加音频滤镜")
    func unityAtempoProducesNoFilter() {
        // 纯函数，不 spawn；单独一条是因为它是下面三条的前提
        #expect(DubAudioFinalizer.atempoChain(1.0).isEmpty,
                "atempo=1.0 竟产出滤镜 ⇒ 固定语速被自己破掉")
        #expect(DubAudioFinalizer.atempoChain(1.0005).isEmpty, "容差边界行为变了")
        #expect(!DubAudioFinalizer.atempoChain(1.01).isEmpty,
                "1.01 也不加滤镜 ⇒ 容差被放宽，1.0 那条是假绿")
    }

    @Test("FR-R-2 真渲染：atempo 1.0 的产物时长必须等于原始时长（不被压进画面）")
    func fixedRateRenderKeepsDuration() async throws {
        try await withFFmpegBench("FR-R-2 不变速真渲染") {
            let ffmpeg = FFmpegRunner()
            let dir = try frfScratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let src = dir.appendingPathComponent("raw.wav").path
            let dst = dir.appendingPathComponent("new.m4a").path
            try await frfSineWav(ffmpeg, seconds: 2.6, to: src)
            let raw = try await frfDuration(ffmpeg, src)

            let filters = DubAudioFinalizer.atempoChain(1.0)   // 新口径
            try await frfRender(ffmpeg, from: src, filters: filters, to: dst)
            let rendered = try await frfDuration(ffmpeg, dst)

            #expect(abs(rendered - raw) < 0.08,
                    "新口径产物 \(rendered)s ≠ 原始 \(raw)s ⇒ 配音仍被拉长/压短，语速一致不成立")
        }
    }

    @Test("FR-R-3 反向对照：旧口径同一条素材会被压到画面时长")
    func legacyRenderCompressesToPicture() async throws {
        try await withFFmpegBench("FR-R-3 旧口径对照") {
            let ffmpeg = FFmpegRunner()
            let dir = try frfScratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let src = dir.appendingPathComponent("raw.wav").path
            let dst = dir.appendingPathComponent("old.m4a").path
            try await frfSineWav(ffmpeg, seconds: 2.6, to: src)

            // 2.6s 配音塞 2.0s 画面 ⇒ 旧口径 atempo = 1.3
            let plan = AudioAligner.plan(targetDuration: 2.0, audioDuration: 2.6,
                                         fps: 30, policy: .legacyStretch)
            #expect(abs(plan.atempoFactor - 1.3) < 0.001, "对照前提变了")
            try await frfRender(ffmpeg, from: src,
                                filters: DubAudioFinalizer.atempoChain(plan.atempoFactor),
                                to: dst)
            let rendered = try await frfDuration(ffmpeg, dst)
            #expect(abs(rendered - 2.0) < 0.1,
                    "旧口径没压到 2.0s（实得 \(rendered)s）⇒ 对照失效，FR-R-2 的差别无从证明")
        }
    }

    @Test("FR-R-4 链式拆分：超 2.0 的系数拆成每段都在合法区间且乘积不变")
    func chainedAtempoStaysInEngineRange() async throws {
        try await withFFmpegBench("FR-R-4 链式拆分") {
            let chain = DubAudioFinalizer.atempoChain(2.6)
            #expect(chain.count == 2, "2.6 应拆成 2 段，实得 \(chain)")
            let factors = chain.map { Double($0.replacingOccurrences(of: "atempo=", with: ""))! }
            for f in factors {
                #expect((0.5...2.0).contains(f), "拆出的 \(f) 落在 ffmpeg atempo 合法区间外")
            }
            #expect(abs(factors.reduce(1.0, *) - 2.6) < 0.001,
                    "乘积 \(factors.reduce(1.0, *)) ≠ 2.6 ⇒ 拆完时长对不上")

            let ffmpeg = FFmpegRunner()
            let dir = try frfScratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let src = dir.appendingPathComponent("raw.wav").path
            let dst = dir.appendingPathComponent("chain.m4a").path
            try await frfSineWav(ffmpeg, seconds: 2.6, to: src)
            try await frfRender(ffmpeg, from: src, filters: chain, to: dst)
            let rendered = try await frfDuration(ffmpeg, dst)
            #expect(abs(rendered - 1.0) < 0.1,
                    "2.6 倍速后应≈1.0s，实得 \(rendered)s ⇒ 链式实现与系数不一致")
        }
    }
}
