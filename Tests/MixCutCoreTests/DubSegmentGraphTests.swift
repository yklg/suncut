import Testing
@testable import MixCutCore

@Suite("DubSegmentGraph")
struct DubSegmentGraphTests {
    private func cap(_ idx: Int = 1, _ x: Int = 240, _ y: Int = 1601, _ s: Double = 0, _ e: Double = 2) -> CaptionOverlay {
        CaptionOverlay(inputIndex: idx, x: x, y: y, start: s, end: e)
    }

    private func blurDubbed() -> DubSegmentGraph {
        DubSegmentGraphBuilder.build(
            mode: .blur,
            startFrame: 15, endFrame: 75, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false,
            dubAudioInputIndex: 2,
            freezePadFrames: 0,
            trailingSilence: 0.2
        )
    }

    @Test("恒定输出标签")
    func mapLabels() {
        let g = blurDubbed()
        #expect(g.videoMapLabel == "[vout]")
        #expect(g.audioMapLabel == "[aout]")
    }

    @Test("blur 模式含 split/crop/boxblur/overlay 回贴")
    func blurContainsBoxblur() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("split=2"))
        #expect(g.filterComplex.contains("crop=1080:230:0:1536"))
        // ⚠️ 钉全串而不是 "boxblur=20" —— 松断言放得过 boxblur=200，等于没守
        #expect(g.filterComplex.contains("boxblur=20:1[mbb]"))
        #expect(g.filterComplex.contains("overlay=0:1536[masked]"))
    }

    @Test("滤镜串里的样式值只能来自 renderSpec（绕过表写字面量必须变红）")
    func filterStringsDeriveFromSpec() {
        // 这三条把「表 → 串」的对应关系钉死：改表会红，绕开表手写也会红。
        // 预览层读的是同一张表，所以这条同时也是"屏幕上的样子 = 导出的样子"的唯一凭据。
        guard case .blur(let radius, let power) = SubtitleMaskMode.blur.renderSpec else {
            Issue.record("blur 的 renderSpec 不再是 .blur ⇒ 下面的等价断言是空断言"); return
        }
        #expect("boxblur=\(radius):\(power)[mbb]" == "boxblur=20:1[mbb]")
        #expect(blurDubbed().filterComplex.contains("boxblur=\(radius):\(power)[mbb]"))

        for mode in [SubtitleMaskMode.solid, .dim] {
            guard case .fill(let hex, let alpha) = mode.renderSpec else {
                Issue.record("\(mode) 的 renderSpec 不是 .fill ⇒ 断言空过"); continue
            }
            let g = DubSegmentGraphBuilder.build(
                mode: mode, startFrame: 0, endFrame: 60, fps: 30,
                outputWidth: 1080, outputHeight: 1920,
                maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
                captions: [], keepOriginalAudio: false, dubAudioInputIndex: 1,
                freezePadFrames: 0, trailingSilence: 0)
            #expect(g.filterComplex.contains("color=0x\(hex)@\(alpha):t=fill[masked]"),
                    "\(mode)：串里的颜色不是从表里取的")
        }
    }

    @Test("糊半径按裁面色度平面短边钳位（阈值来自包内 ffmpeg 实测）")
    func blurRadiusClampedToCrop() {
        // 实测表（2026-10-01，SunCut.app/Contents/Resources/bin/ffmpeg）：
        // 裁面高 38 ⇒ 最大 9（10 直接 init 失败）；40 ⇒ 10；78 ⇒ 19；80 ⇒ 20。
        // 约束来自 yuv420 的色度平面（半尺寸），不是 luma —— 所以是 /4 不是 /2。
        let base = SubtitleMaskRenderSpec.blur(radiusPixels: 20, power: 1)
        #expect(base.clampedRadius(cropWidth: 1080, cropHeight: 38) == 9)
        #expect(base.clampedRadius(cropWidth: 1080, cropHeight: 40) == 10)
        #expect(base.clampedRadius(cropWidth: 1080, cropHeight: 78) == 19)
        #expect(base.clampedRadius(cropWidth: 1080, cropHeight: 80) == 20)
        #expect(base.clampedRadius(cropWidth: 1080, cropHeight: 230) == 20, "默认带高不该被动")
        // 窄带也要受宽约束：横长条反过来按宽算
        #expect(base.clampedRadius(cropWidth: 60, cropHeight: 400) == 15)

        func band(_ h: Int) -> String {
            DubSegmentGraphBuilder.build(
                mode: .blur, startFrame: 0, endFrame: 60, fps: 30,
                outputWidth: 1080, outputHeight: 1920,
                maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: h),
                captions: [], keepOriginalAudio: false, dubAudioInputIndex: 1,
                freezePadFrames: 0, trailingSilence: 0).filterComplex
        }
        // 38px 这一档今天从卡片上拖不出来（带高会被抬到该分镜的字幕块高度），但它仍是活的输入：
        // 下限落地前已拖矮的存量行、以及窄成片导出（480 宽时同一个下限换算过来只有 36px）都走到这里，
        // 不钳位就是"配音导出 rc=234"硬失败。
        #expect(band(38).contains("boxblur=9:1[mbb]"))
        #expect(!band(38).contains("boxblur=20"))
        // 既有锚值不许动：默认 230px 带高的串与钳位引入前逐字相同
        #expect(band(230).contains("boxblur=20:1[mbb]"))
    }

    @Test("精确切片 + 9:16 标准化")
    func cutAndNormalize() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("trim=start_frame=15:end_frame=75,setpts=PTS-STARTPTS"))
        #expect(g.filterComplex.contains("scale=1080:1920:force_original_aspect_ratio=decrease"))
        #expect(g.filterComplex.contains("setsar=1,fps=30[base]"))
    }

    @Test("逐句叠字幕 PNG：单句 overlay + enable=between")
    func overlaysCaption() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("[masked][1:v]overlay=240:1601:enable='between(t,0.000,2.000)'[capped]"))
    }

    @Test("多句字幕：逐句 overlay 链式串联，各自 enable 时间窗")
    func multipleCaptionsChained() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap(1, 240, 1601, 0, 1), cap(2, 240, 1601, 1, 2)],
            keepOriginalAudio: false, dubAudioInputIndex: 3,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[masked][1:v]overlay=240:1601:enable='between(t,0.000,1.000)'[cap0]"))
        #expect(g.filterComplex.contains("[cap0][2:v]overlay=240:1601:enable='between(t,1.000,2.000)'[capped]"))
    }

    @Test("非锁定段从 dubAudioInputIndex 取音轨 + trailingSilence 补静音")
    func dubbedAudioWithSilence() {
        let g = blurDubbed()
        #expect(g.filterComplex.contains("[2:a]loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100"))
        #expect(g.filterComplex.contains("apad=pad_dur=0.200[aout]"))
    }

    @Test("solid 模式用 drawbox 实色条")
    func solidUsesDrawbox() {
        let g = DubSegmentGraphBuilder.build(
            mode: .solid, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("drawbox=x=0:y=1536:w=1080:h=230:color=0x1A1A1A@1.0:t=fill[masked]"))
        #expect(g.filterComplex.contains("[2:a]loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100[aout]"))
    }

    @Test("none 模式不遮挡（null 透传）")
    func noneModePassesThrough() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[base]null[masked]"))
        #expect(!g.filterComplex.contains("boxblur"))
        #expect(!g.filterComplex.contains("drawbox"))
    }

    @Test("锁定段：用原音轨 atrim + 不叠字幕")
    func lockedKeepsOriginalAudioNoCaption() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [],
            keepOriginalAudio: true, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[0:a]atrim=start=1.00000:end=3.00000"))
        #expect(!g.filterComplex.contains("overlay=240"))
        #expect(g.filterComplex.contains("[masked]null[vout]"))
        #expect(!g.filterComplex.contains("loudnorm"))
    }

    @Test("freezePadFrames>0 用 tpad 定格")
    func freezePadUsesTpad() {
        let g = DubSegmentGraphBuilder.build(
            mode: .blur, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 9, trailingSilence: 0)
        #expect(g.filterComplex.contains("tpad=stop_mode=clone:stop_duration=0.300[vout]"))
    }

    @Test("锁定段即使传了 captions 也不叠字幕")
    func lockedIgnoresCaptions() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: true, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(!g.filterComplex.contains("overlay=240:1601"))
        #expect(g.filterComplex.contains("[masked]null[vout]"))
    }

    @Test("dim 模式用半透明 drawbox")
    func dimUsesTranslucentDrawbox() {
        let g = DubSegmentGraphBuilder.build(
            mode: .dim, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 1536, width: 1080, height: 230),
            captions: [cap()],
            keepOriginalAudio: false, dubAudioInputIndex: 2,
            freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("drawbox=x=0:y=1536:w=1080:h=230:color=0x000000@0.5:t=fill[masked]"))
    }
}

@Suite("DubSegmentGraph BGM 混音")
struct DubSegmentGraphBGMTests {

    @Test("提供 bgmInputIndex 时音轨为 voice+bgm amix")
    func mixesBGMWhenIndexProvided() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captions: [],
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0,
            bgmInputIndex: 2)
        let fc = g.filterComplex
        #expect(fc.contains("[1:a]loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100"))
        #expect(fc.contains("[2:a]atrim=start=1.00000:end=3.00000"))
        #expect(fc.contains("volume=0.60"))
        #expect(fc.contains("amix=inputs=2:duration=first:normalize=0[aout]"))
    }

    @Test("bgmInputIndex 为 nil 时退化为纯人声（回归保护）")
    func noBGMFallsBackToVoiceOnly() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 30, endFrame: 90, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captions: [],
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0)
        let fc = g.filterComplex
        #expect(!fc.contains("amix"))
        #expect(fc.contains("[1:a]loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100[aout]"))
    }

    @Test("带 trailingSilence + BGM：人声有 apad 再与 BGM 混")
    func bgmWithTrailingSilence() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 0, height: 0),
            captions: [],
            keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0.5,
            bgmInputIndex: 2)
        let fc = g.filterComplex
        #expect(fc.contains("apad=pad_dur=0.500"))
        #expect(fc.contains("amix=inputs=2:duration=first:normalize=0[aout]"))
    }
}

@Suite("全局 BGM 模式：原声段用纯人声音源")
struct VocalsSourceTests {

    @Test("传 vocalsSource 时原声段音频取自 vocals 输入并按秒切片")
    func vocalsSliceReplacesOriginalAudio() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 90, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: true,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0,
            vocalsSource: VocalsSource(inputIndex: 1, start: 12.5, end: 15.5))
        #expect(g.filterComplex.contains("[1:a]atrim=start=12.50000:end=15.50000"))
        #expect(!g.filterComplex.contains("[0:a]"))
    }

    @Test("不传 vocalsSource 时行为不变（原声取 [0:a]）")
    func defaultKeepsOriginalBehavior() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 90, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: true,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0)
        #expect(g.filterComplex.contains("[0:a]atrim="))
    }

    @Test("配音段不受 vocalsSource 影响（音频仍取配音输入）")
    func dubSegmentIgnoresVocalsSource() {
        let g = DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 90, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: false,
            dubAudioInputIndex: 1, freezePadFrames: 0, trailingSilence: 0,
            vocalsSource: VocalsSource(inputIndex: 2, start: 0, end: 3))
        #expect(g.filterComplex.contains("[1:a]loudnorm=I=-16:TP=-1.5:LRA=11,aresample=44100"))
        #expect(!g.filterComplex.contains("[2:a]"))
    }
}
