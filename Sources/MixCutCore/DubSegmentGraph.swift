import Foundation

/// 单分镜中间片的 ffmpeg 滤镜图（纯字符串，导出服务直接拼进命令）。
public struct DubSegmentGraph: Equatable, Sendable {
    public let filterComplex: String
    public let videoMapLabel: String   // 恒 "[vout]"
    public let audioMapLabel: String   // 恒 "[aout]"

    public init(filterComplex: String, videoMapLabel: String, audioMapLabel: String) {
        self.filterComplex = filterComplex
        self.videoMapLabel = videoMapLabel
        self.audioMapLabel = audioMapLabel
    }
}

/// 一条逐句字幕 overlay：PNG 输入序号 + 落位 + 相对分镜起点的时间窗（enable=between 用）。
public struct CaptionOverlay: Sendable, Equatable {
    public let inputIndex: Int
    public let x: Int
    public let y: Int
    public let start: Double
    public let end: Double
    public init(inputIndex: Int, x: Int, y: Int, start: Double, end: Double) {
        self.inputIndex = inputIndex; self.x = x; self.y = y; self.start = start; self.end = end
    }
}

/// 全局 BGM 模式下，原声段的「纯人声」音源：
/// 整轨 vocals.wav 的输入序号 + 原视频时间轴上的切片窗（秒）。
/// ⚠️ 时间窗必须用**原视频**时间轴（segment.startTime/endTime），不能用替换画面片的帧换算——
/// 替换画面片的音轨本来就取自原视频同窗口，vocals.wav 也是对原视频整轨分离的。
public struct VocalsSource: Sendable, Equatable {
    public let inputIndex: Int
    public let start: Double
    public let end: Double
    public init(inputIndex: Int, start: Double, end: Double) {
        self.inputIndex = inputIndex; self.start = start; self.end = end
    }
}

/// 构建「切片 → 9:16 标准化 → 遮挡旧字幕 → 逐句叠新字幕 → 换音轨 → 定格/补静音」滤镜图。
/// 输入约定：input 0 = 源视频；每条 caption PNG = 其 CaptionOverlay.inputIndex；dub m4a = dubAudioInputIndex。
/// 逐句字幕：每句一个 overlay + `enable='between(t,起,止)'`（t=分镜内 0 起，由 trim/setpts 保证）。
/// 旧数据/整段兜底：调用方传 1 条 [0, 分镜时长] 的 CaptionOverlay 即等价整段全程。
public enum DubSegmentGraphBuilder {
    /// ⚠️ 这条链同样吃 `loudnorm`，因此理论上有同一颗雷（见 `LoudnessChainPolicy` 的实测）。
    /// 但本腿的输入是配音 m4a，**未复现**该态 ⇒ 不凭空改这里的音轨；要判得先给 builder
    /// 传进"这条配音有多长、是不是纯静音"。
    private static let loudnorm = "loudnorm=I=-16:TP=-1.5:LRA=11"
    /// trailingSilence 视为 0 的阈值（秒）
    private static let silenceEpsilon = 0.001
    /// 混音时 BGM 相对音量（人声为主、BGM 垫底）
    public static let bgmGain: Double = 0.6

    public static func build(
        mode: SubtitleMaskMode,
        startFrame: Int, endFrame: Int, fps: Double,
        outputWidth: Int, outputHeight: Int,
        maskPixel: PixelRect,
        captions: [CaptionOverlay],
        keepOriginalAudio: Bool,
        dubAudioInputIndex: Int,
        freezePadFrames: Int,
        trailingSilence: Double,
        bgmInputIndex: Int? = nil,
        vocalsSource: VocalsSource? = nil,
        logo: LogoOverlayStage? = nil
    ) -> DubSegmentGraph {
        let w = outputWidth, h = outputHeight
        let fpsInt = Int(fps.rounded())
        var parts: [String] = []

        // 1) 视频：精确切片 + 9:16 标准化 → [base]
        parts.append(
            "[0:v]trim=start_frame=\(startFrame):end_frame=\(endFrame),setpts=PTS-STARTPTS," +
            "scale=\(w):\(h):force_original_aspect_ratio=decrease," +
            "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=\(fpsInt)[base]"
        )

        // 2) 遮挡旧字幕 → [masked]
        // ⚠️ 半径 / 颜色 / alpha 一律从 `SubtitleMaskMode.renderSpec` 取，**这里不许再写字面量**：
        // 卡片预览读的是同一张表，把值写回这里就等于"导出糊成这样、屏幕上却是另一样"的两份真相。
        let mx = maskPixel.x, my = maskPixel.y, mw = maskPixel.width, mh = maskPixel.height
        let spec = mode.renderSpec
        switch spec {
        case .passthrough:
            parts.append("[base]null[masked]")
        case .blur(_, let power):
            // ⚠️ 必须钳位：遮挡条可以拖到 38px 高，而 boxblur 的半径受**色度平面**限制
            // （r ≤ min(裁面宽,高)/4），超了 ffmpeg 直接 init 失败、导出 rc=234。
            // 默认带高 230px 时钳位不动（20 < 57），所以现有导出的滤镜串逐字节不变。
            let r = spec.clampedRadius(cropWidth: mw, cropHeight: mh)
            parts.append("[base]split=2[mb0][mb1]")
            parts.append("[mb1]crop=\(mw):\(mh):\(mx):\(my),boxblur=\(r):\(power)[mbb]")
            parts.append("[mb0][mbb]overlay=\(mx):\(my)[masked]")
        case .fill(let hex, let alpha):
            parts.append("[base]drawbox=x=\(mx):y=\(my):w=\(mw):h=\(mh):color=0x\(hex)@\(alpha):t=fill[masked]")
        }

        // 3) 逐句叠新字幕 PNG → [capped]（每句一个 overlay + enable=between；无字幕则透传 [masked]）
        // 锁定段（保留原声）一律不叠字幕，即使调用方误传了 captions
        let effectiveCaptions = keepOriginalAudio ? [] : captions
        let videoBeforePad: String
        if effectiveCaptions.isEmpty {
            videoBeforePad = "masked"
        } else {
            var prev = "masked"
            for (i, c) in effectiveCaptions.enumerated() {
                let out = (i == effectiveCaptions.count - 1) ? "capped" : "cap\(i)"
                parts.append(
                    "[\(prev)][\(c.inputIndex):v]overlay=\(c.x):\(c.y):" +
                    "enable='between(t,\(String(format: "%.3f", c.start)),\(String(format: "%.3f", c.end)))'[\(out)]"
                )
                prev = out
            }
            videoBeforePad = "capped"
        }

        // 4) 末尾定格补帧 → [voutBase]（有 logo）/ [vout]（无 logo ⇒ 既有串逐字节不变）
        let hasLogo = !(logo?.layers.isEmpty ?? true)
        let finalVideoLabel = hasLogo ? "voutBase" : "vout"
        if freezePadFrames > 0 {
            let dur = Double(freezePadFrames) / fps
            parts.append("[\(videoBeforePad)]tpad=stop_mode=clone:stop_duration=\(String(format: "%.3f", dur))[\(finalVideoLabel)]")
        } else {
            parts.append("[\(videoBeforePad)]null[\(finalVideoLabel)]")
        }

        // 5) logo 链接在最终画面之后 ⇒ 品牌永远压在字幕/mask 之上
        if hasLogo, let logo {
            LogoOverlayGraph.append(to: &parts, stage: logo, from: "voutBase", to: "vout")
        }

        // 6) 音频 → [aout]
        if keepOriginalAudio {
            if let vs = vocalsSource {
                // 全局 BGM 模式：原声段只留纯口播（整轨 vocals.wav 按原视频时间轴切片）
                parts.append(
                    "[\(vs.inputIndex):a]atrim=start=\(String(format: "%.5f", vs.start)):end=\(String(format: "%.5f", vs.end))," +
                    "asetpts=PTS-STARTPTS,aresample=44100[aout]"
                )
            } else {
                let aStart = Double(startFrame) / fps
                let aEnd = Double(endFrame) / fps
                parts.append(
                    "[0:a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                    "asetpts=PTS-STARTPTS,aresample=44100[aout]"
                )
            }
        } else {
            let padSuffix = trailingSilence > silenceEpsilon
                ? ",apad=pad_dur=\(String(format: "%.3f", trailingSilence))"
                : ""
            if let bgmIdx = bgmInputIndex {
                let aStart = Double(startFrame) / fps
                let aEnd = Double(endFrame) / fps
                // aresample 必须在 loudnorm 之后：loudnorm 内部升到 192k，排在它前面等于
                // 把交付件写成 96000 Hz（2026-11-03 实测；同素材 mean_volume 两写法相同）。
                parts.append("[\(dubAudioInputIndex):a]\(loudnorm),aresample=44100\(padSuffix)[voice]")
                parts.append(
                    "[\(bgmIdx):a]atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd))," +
                    "asetpts=PTS-STARTPTS,aresample=44100,volume=\(String(format: "%.2f", Self.bgmGain))[bgmcut]"
                )
                parts.append("[voice][bgmcut]amix=inputs=2:duration=first:normalize=0[aout]")
            } else {
                parts.append("[\(dubAudioInputIndex):a]\(loudnorm),aresample=44100\(padSuffix)[aout]")
            }
        }

        return DubSegmentGraph(filterComplex: parts.joined(separator: ";"),
                               videoMapLabel: "[vout]",
                               audioMapLabel: "[aout]")
    }
}

/// 「这段音频能不能喂给 `loudnorm`」的唯一判据。
///
/// 为什么必须存在（2026-10-20 沿产品链路实测）：包内 ffmpeg 8.1 的 `loudnorm` 在
/// **纯数字静音 + 时长不足它的测量窗**时吐出 NaN 采样，aac 编码器随即拒收，
/// 整条导出以 `rc=234 / Error submitting audio frame to the encoder` 失败，
/// 而屏上只剩一句「视频处理失败（错误码 234）」——原因一个字都没说。
///
/// 实测分界（同一颗静音源、同一条滤镜链，只差时长）：
/// 2.5s 与 2.9s ⇒ rc=234 且 stderr 有 `Input contains (near) NaN/+-Inf`；
/// 3.0s、3.1s、6.0s ⇒ rc=0。**只有纯静音会中**：−81 dB 级近静音 2.5s、
/// 440Hz 有电平 1.0s 都是 rc=0。
/// 中毒单位是**单条分镜**不是成片总时长：1s 静音分镜 + 4s 有声分镜（总 5s，
/// 过千川时长闸）照样整条红 —— 所以光靠时长闸拦不住它。
///
/// 判据为什么是「恰好 -inf」而不是「足够安静」：`astats` 对纯数字静音报
/// `RMS level dB: -inf`，对 −81 dB 报有限值，实测只有前者触发 NaN。
/// 于是本判据的作用面严格等于「今天必然失败的那些」，对现在能导的片子逐字节不变。
public enum LoudnessChainPolicy {

    /// ffmpeg 8.1 `loudnorm` 的测量窗（秒）。R128 短时响度窗同为 3s，与实测分界吻合。
    public static let measurementWindowSeconds: Double = 3.0

    /// 要不要为「是不是纯静音」花一次探测。
    /// 够长的音频今天就不中毒 ⇒ 不为它付那一次解码，探测成本只摊在短段上。
    public static func needsSilenceProbe(durationSeconds: Double) -> Bool {
        durationSeconds < measurementWindowSeconds
    }

    /// `true` ⇒ 这一段必须走静音支路，不许喂给 `loudnorm`。
    public static func mustBypassLoudnorm(durationSeconds: Double,
                                         isPureDigitalSilence: Bool) -> Bool {
        needsSilenceProbe(durationSeconds: durationSeconds) && isPureDigitalSilence
    }
}
