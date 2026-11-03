import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// FR-G · 固定语速的配音走真导出图，画面与音频各归谁
// （计划 §6.1 T6/T16 的 Core 半段 —— 这一段不需要 App 腿，见下方"为什么不跑 App 腿"）
//
// 要证的是一条容易搞反的分工：`.fixedRate` 下
//   · **画面**仍然严格等于分镜帧区间（trim=start_frame:end_frame，不因配音变长）；
//   · **音频**不再被压缩进画面 —— 偏长由 `DubLengthGate` 在生成阶段就拒了，
//     走到导出这一步的配音必然 ≤ 画面，导出只负责把"偏短"那段补成静音。
// 也就是说：新口径把"对齐"从导出阶段**前移到了生成阶段**。本文件钉的就是这个前移没走样。
//
// ## 为什么不跑 App 腿
//
// `DubAudioFinalizer.atempoChain` 在 App 层，要断言"atempo=1.0 ⇒ 不加任何音频滤镜"
// 得进 `MixCutAppTests`。而那条腿的宿主进程会跑 `MixCutApp.init` ⇒ SchemaGuard 开**用户活库**，
// 本轮加了 2 颗 `@Model` 字段，那一跑就当场做轻量迁移。⇒ 这一环改用两条替代证据：
//   ① 本文件的图侧断言（Core，零副作用）；
//   ② 仓外真 ffmpeg 实测：旧口径把 4 段分别压到 3.985/5.990/1.584/4.987 秒
//     （正好等于各自画面时长），新口径一段都没被压。
// 真要跑 App 腿，得用户明示 —— 还原点已留在 `.scratch/store-backup-20261026-024504`。
// ============================================================================

@Suite("FR-G · 固定语速的导出图复现")
struct FixedRateGraphReproTests {

    private static let fps = 30.0
    private static let startFrame = 15
    private static let endFrame = 75          // 画面 = 60 帧 = 2.0s

    private static func graph(freezePadFrames: Int, trailingSilence: Double) -> DubSegmentGraph {
        DubSegmentGraphBuilder.build(
            mode: .none,
            startFrame: startFrame, endFrame: endFrame, fps: fps,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [],
            keepOriginalAudio: false,
            dubAudioInputIndex: 2,
            freezePadFrames: freezePadFrames,
            trailingSilence: trailingSilence)
    }

    @Test("G-1 画面严格取分镜帧区间，与配音长短无关")
    func pictureIsSegmentFramesOnly() {
        for trailing in [0.0, 0.4, 1.2] {
            let g = Self.graph(freezePadFrames: 0, trailingSilence: trailing)
            #expect(g.filterComplex.contains(
                        "trim=start_frame=\(Self.startFrame):end_frame=\(Self.endFrame)"),
                    "补 \(trailing)s 静音后画面裁剪竟变了 ⇒ 画面被配音牵着走")
        }
    }

    @Test("G-2 新口径下永不定格补帧：freezePadFrames=0 时图里不得出现 tpad")
    func neverFreezePadsUnderFixedRate() {
        let g = Self.graph(freezePadFrames: 0, trailingSilence: 0.5)
        #expect(!g.filterComplex.contains("tpad"),
                "出现 tpad ⇒ 又在用定格补帧延长画面，与「不留尾帧定格」相违")
    }

    @Test("G-3 偏短才补静音，且补在 loudnorm 之后")
    func silencePaddedAfterLoudnorm() {
        let g = Self.graph(freezePadFrames: 0, trailingSilence: 0.4)
        let body = g.filterComplex
        let hasLoudnorm = body.contains("loudnorm")
        let hasPad = body.contains("apad=pad_dur=0.400")
        #expect(hasLoudnorm, "配音支路应过 loudnorm")
        #expect(hasPad, "trailingSilence=0.4 应翻成 apad=pad_dur=0.400，实得：\(body)")
        // 顺序承重：apad 必须在 loudnorm **之后**，否则补出来的全零静音会进响度测量窗
        if let ln = body.range(of: "loudnorm"), let pad = body.range(of: "apad") {
            #expect(ln.lowerBound < pad.lowerBound,
                    "apad 排在 loudnorm 之前 ⇒ 全零静音进测量窗，本仓那颗 rc=234 的形状会复发")
        }
    }

    @Test("G-4 反向对照：trailingSilence 归零时不得留下 apad（防判据恒真）")
    func noPadWhenNothingToPad() {
        let g = Self.graph(freezePadFrames: 0, trailingSilence: 0.0)
        #expect(!g.filterComplex.contains("apad"),
                "0.0 还补静音 ⇒ G-3 那条断言是假的")
    }

    @Test("G-5 走完整条链：fixedRate 的裁决结果喂进导出图，画面长度不变")
    func endToEndArithmetic() {
        // 场景：文案偏短 —— raw 1.4s 塞 2.0s 画面。
        let picture = Double(Self.endFrame - Self.startFrame) / Self.fps
        let raw = 1.4
        #expect(DubLengthGate.postCheck(audioSeconds: raw, pictureSeconds: picture) == .pass)
        let plan = AudioAligner.plan(targetDuration: picture, audioDuration: raw,
                                     fps: Self.fps, policy: .fixedRate)
        #expect(plan.atempoFactor == 1.0, "新口径竟变速了")
        #expect(abs(plan.trailingSilence - 0.6) < 0.001, "残差应 0.6s，实得 \(plan.trailingSilence)")

        let g = Self.graph(freezePadFrames: plan.freezePadFrames,
                           trailingSilence: plan.trailingSilence)
        #expect(g.filterComplex.contains("apad=pad_dur=0.600"))
        #expect(g.filterComplex.contains("trim=start_frame=\(Self.startFrame):end_frame=\(Self.endFrame)"))
        // 交付时长闸按帧算 ⇒ 这段的读数必须仍是 2.0s（配音长短不参与）
        let gateSeconds = Double(Self.endFrame - Self.startFrame) / Self.fps
        #expect(abs(gateSeconds - picture) < 1e-9)
    }

    @Test("G-6 偏长的输入根本不该走到导出：闸必须拒（前移的证据）")
    func overlongNeverReachesGraph() {
        let picture = Double(Self.endFrame - Self.startFrame) / Self.fps   // 2.0s
        #expect(DubLengthGate.postCheck(audioSeconds: 2.6, pictureSeconds: picture) != .pass,
                "2.6s 配音塞 2.0s 画面竟放行 ⇒ 前移失效，导出会音画分叉")
        // 而旧口径会把它压进画面 —— 那正是语速跳变的来源，对照着钉住。
        // 2.6 / 2.0 = 正好 1.3：这里必须钉**精确值**而不是 `> 1.3`，
        // 否则落在边界上就会自己误红（本会话已在 T4-1 上栽过一次，同族错）。
        let legacy = AudioAligner.plan(targetDuration: picture, audioDuration: 2.6,
                                       fps: Self.fps, policy: .legacyStretch)
        #expect(abs(legacy.atempoFactor - 1.3) < 0.001,
                "旧口径对照值应为 2.6/2.0 = 1.3，实得 \(legacy.atempoFactor) ⇒ 本条的推理需重读")
    }
}
