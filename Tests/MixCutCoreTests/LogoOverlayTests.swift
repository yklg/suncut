import Testing
@testable import MixCutCore

@Suite("LogoOverlay · 配置与裁边")
struct LogoOverlayConfigTests {

    private func cfg() -> LogoOverlayConfig {
        LogoOverlayConfig(
            enabled: true,
            layers: [
                LogoOverlayLayer(file: "logo-a.png", widthPct: 0.55, anchor: .topLeft),
                LogoOverlayLayer(file: "logo-b.png", widthPct: 0.33, anchor: .bottomRight),
            ],
            rightMarginPct: 0.026,
            bottomMarginPct: 0.147)
    }

    @Test("全字段 roundtrip")
    func roundtrip() throws {
        let raw = try #require(LogoOverlayCoder.encode(cfg()))
        #expect(LogoOverlayCoder.decode(raw) == cfg())
    }

    @Test("缺键逐项回落默认值，不整份变 nil")
    func missingKeysFallBackPerKey() throws {
        let decoded = try #require(LogoOverlayCoder.decode(#"{"enabled":true}"#))
        #expect(decoded.version == LogoOverlayConfig.currentVersion)
        #expect(decoded.enabled)
        #expect(decoded.layers.isEmpty)
        #expect(decoded.rightMarginPct == 0.026)
        #expect(decoded.bottomMarginPct == 0.13)
    }

    @Test("坏 JSON / 未知 version 返回 nil")
    func badJSONOrUnknownVersionIsNil() {
        #expect(LogoOverlayCoder.decode("{") == nil)
        #expect(LogoOverlayCoder.decode(nil) == nil)
        #expect(LogoOverlayCoder.decode(#"{"version":2,"enabled":true}"#) == nil)
    }

    @Test("未知 anchor / 不安全文件名 / 超 2 层 / 非法宽度都被丢弃或夹取")
    func hostileConfigIsSanitized() throws {
        let raw = #"""
        {"version":1,"enabled":true,"layers":[
          {"file":"ok.png","widthPct":2.0,"anchor":"topLeft"},
          {"file":"../escape.png","widthPct":0.2,"anchor":"bottomRight"},
          {"file":"bad-anchor.png","widthPct":0.2,"anchor":"middle"},
          {"file":"missing-anchor.png","widthPct":0.2},
          {"file":"third.png","widthPct":0.2,"anchor":"topLeft"},
          {"file":"neg.png","widthPct":-1,"anchor":"topLeft"}
        ]}
        """#
        let decoded = try #require(LogoOverlayCoder.decode(raw))
        #expect(decoded.layers.count == 1)
        #expect(decoded.layers[0].file == "ok.png")
        #expect(decoded.layers[0].widthPct == 1.0)
    }

    @Test("文件名安全判定")
    func safeFileNames() {
        #expect(LogoOverlayConfig.isSafeFileName("logo-abc.png"))
        #expect(!LogoOverlayConfig.isSafeFileName(""))
        #expect(!LogoOverlayConfig.isSafeFileName("."))
        #expect(!LogoOverlayConfig.isSafeFileName(".."))
        #expect(!LogoOverlayConfig.isSafeFileName("../x.png"))
        #expect(!LogoOverlayConfig.isSafeFileName("a/b.png"))
    }
}

@Suite("LogoOverlay · AlphaBounds")
struct AlphaBoundsTests {

    private func rgba(_ alphas: [UInt8]) -> [UInt8] {
        alphas.flatMap { [0, 0, 0, $0] }
    }

    @Test("全透明返回 nil")
    func fullyTransparent() {
        #expect(AlphaBounds.boundingBox(width: 2, height: 2, rgba: rgba([0, 0, 0, 0])) == nil)
    }

    @Test("全不透明返回全框")
    func fullyOpaque() {
        #expect(AlphaBounds.boundingBox(width: 2, height: 2, rgba: rgba([255, 255, 255, 255]))
                == PixelRect(x: 0, y: 0, width: 2, height: 2))
    }

    @Test("阈值严格大于：15/16 不算，17 算")
    func thresholdIsStrict() {
        let size = (3, 3)
        func one(_ a: UInt8) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: size.0 * size.1 * 4)
            bytes[(1 * size.0 + 1) * 4 + 3] = a
            return bytes
        }
        #expect(AlphaBounds.boundingBox(width: size.0, height: size.1, rgba: one(15)) == nil)
        #expect(AlphaBounds.boundingBox(width: size.0, height: size.1, rgba: one(16)) == nil)
        #expect(AlphaBounds.boundingBox(width: size.0, height: size.1, rgba: one(17))
                == PixelRect(x: 1, y: 1, width: 1, height: 1))
    }

    @Test("1px 透明边与抗锯齿弱边都被裁掉")
    func borderAndAntiAliasTrimmed() {
        let w = 4, h = 4
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        // 外圈 alpha=8（抗锯齿弱边），内圈 2×2 像素 alpha=200
        for y in 0..<h {
            for x in 0..<w {
                let isEdge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                if x >= 1, x <= 2, y >= 1, y <= 2 { bytes[(y * w + x) * 4 + 3] = 200 }
                else if isEdge { bytes[(y * w + x) * 4 + 3] = 8 }
            }
        }
        #expect(AlphaBounds.boundingBox(width: w, height: h, rgba: bytes)
                == PixelRect(x: 1, y: 1, width: 2, height: 2))
    }

    @Test("空/非法尺寸返回 nil")
    func invalidInputs() {
        #expect(AlphaBounds.boundingBox(width: 0, height: 0, rgba: []) == nil)
        #expect(AlphaBounds.boundingBox(width: 2, height: 2, rgba: [1, 2, 3]) == nil)
        #expect(AlphaBounds.boundingBox(width: 1, height: 1, rgba: rgba([255]))
                == PixelRect(x: 0, y: 0, width: 1, height: 1))
    }
}

@Suite("LogoOverlay · 布局")
struct LogoOverlayLayoutTests {

    private let sizes: [String: (width: Int, height: Int)] = [
        "logo.png": (256, 78),
        "title.png": (1384, 814),
    ]
    private let kLayers = [
        LogoOverlayLayer(file: "logo.png", widthPct: 0.55, anchor: .topLeft),
        LogoOverlayLayer(file: "title.png", widthPct: 0.33, anchor: .bottomRight),
    ]

    @Test("K 预设 @720×1280：logo (0,0,396,122)、文字 (463,952,238,140)")
    func kPreset720() {
        let layout = LogoOverlayLayout.compute(
            canvasWidth: 720, canvasHeight: 1280, layers: kLayers,
            imageSizes: sizes, rightMarginPct: 0.026, bottomMarginPct: 0.147)
        #expect(layout.items.map(\.rect) == [
            PixelRect(x: 0, y: 0, width: 396, height: 122),
            PixelRect(x: 463, y: 952, width: 238, height: 140),
        ])
    }

    @Test("通用默认 @720×1280：logo (0,0,144,44)、文字 (485,986,216,128)")
    func generic720() {
        let layers = [
            LogoOverlayLayer(file: "logo.png", widthPct: 0.20, anchor: .topLeft),
            LogoOverlayLayer(file: "title.png", widthPct: 0.30, anchor: .bottomRight),
        ]
        let layout = LogoOverlayLayout.compute(
            canvasWidth: 720, canvasHeight: 1280, layers: layers,
            imageSizes: sizes, rightMarginPct: 0.026, bottomMarginPct: 0.13)
        #expect(layout.items.map(\.rect) == [
            PixelRect(x: 0, y: 0, width: 144, height: 44),
            PixelRect(x: 485, y: 986, width: 216, height: 128),
        ])
    }

    @Test("K 预设 @1080×1920：logo (0,0,594,182)、文字 (696,1428,356,210)")
    func kPreset1080() {
        let layout = LogoOverlayLayout.compute(
            canvasWidth: 1080, canvasHeight: 1920, layers: kLayers,
            imageSizes: sizes, rightMarginPct: 0.026, bottomMarginPct: 0.147)
        #expect(layout.items.map(\.rect) == [
            PixelRect(x: 0, y: 0, width: 594, height: 182),
            PixelRect(x: 696, y: 1428, width: 356, height: 210),
        ])
    }

    @Test("碰撞：相切不算、越 1px 算、全覆盖算、零尺寸 mask 不算")
    func captionCollision() {
        func overlaps(_ mask: PixelRect) -> Bool {
            LogoOverlayLayout.compute(
                canvasWidth: 720, canvasHeight: 1280, layers: [kLayers[1]],
                imageSizes: sizes, rightMarginPct: 0.026, bottomMarginPct: 0.147,
                avoidRect: mask).overlapsCaptionMask
        }
        #expect(!overlaps(PixelRect(x: 0, y: 1092, width: 720, height: 188)))
        #expect(overlaps(PixelRect(x: 0, y: 1091, width: 720, height: 189)))
        #expect(overlaps(PixelRect(x: 0, y: 0, width: 720, height: 1280)))
        #expect(!overlaps(PixelRect(x: 0, y: 0, width: 0, height: 0)))
    }

    @Test("缺图片尺寸的层被跳过；空图层返回空布局")
    func missingSizeSkipped() {
        let layout = LogoOverlayLayout.compute(
            canvasWidth: 720, canvasHeight: 1280, layers: kLayers,
            imageSizes: ["logo.png": (256, 78)],
            rightMarginPct: 0.026, bottomMarginPct: 0.147)
        #expect(layout.items.count == 1)
        #expect(layout.items[0].rect == PixelRect(x: 0, y: 0, width: 396, height: 122))
        #expect(LogoOverlayLayout.compute(canvasWidth: 720, canvasHeight: 1280, layers: [],
                                          imageSizes: sizes).items.isEmpty)
    }
}

@Suite("LogoOverlay · 滤镜链")
struct LogoOverlayGraphTests {

    private let rectA = PixelRect(x: 0, y: 0, width: 396, height: 122)
    private let rectB = PixelRect(x: 463, y: 952, width: 238, height: 140)

    @Test("空 stage 不改串")
    func emptyStageIsNoOp() {
        var parts: [String] = ["base"]
        let out = LogoOverlayGraph.append(to: &parts, stage: LogoOverlayStage(layers: []),
                                          from: "vout", to: "vout")
        #expect(out == "vout")
        #expect(parts == ["base"])
    }

    @Test("单层左上：精确 scale/overlay 串")
    func singleTopLeft() {
        var parts: [String] = []
        LogoOverlayGraph.append(
            to: &parts,
            stage: LogoOverlayStage(layers: [.init(inputIndex: 2, rect: rectA)]),
            from: "voutBase", to: "vout")
        #expect(parts == [
            "[2:v]format=rgba,scale=396:122:flags=lanczos,setsar=1[logo0]",
            "[voutBase][logo0]overlay=0:0[vout]",
        ])
    }

    @Test("双层链顺序与中间标签")
    func twoLayersChained() {
        var parts: [String] = []
        LogoOverlayGraph.append(
            to: &parts,
            stage: LogoOverlayStage(layers: [
                .init(inputIndex: 2, rect: rectA),
                .init(inputIndex: 3, rect: rectB),
            ]),
            from: "voutBase", to: "vout")
        #expect(parts == [
            "[2:v]format=rgba,scale=396:122:flags=lanczos,setsar=1[logo0]",
            "[voutBase][logo0]overlay=0:0[logoStep0]",
            "[3:v]format=rgba,scale=238:140:flags=lanczos,setsar=1[logo1]",
            "[logoStep0][logo1]overlay=463:952[vout]",
        ])
    }
}

@Suite("DubSegmentGraph · logo 接入")
struct DubSegmentGraphLogoTests {

    private func build(logo: LogoOverlayStage?, freeze: Int = 0) -> DubSegmentGraph {
        DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 0, endFrame: 60, fps: 30,
            outputWidth: 720, outputHeight: 1280,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 100),
            captions: [], keepOriginalAudio: true,
            dubAudioInputIndex: 1, freezePadFrames: freeze, trailingSilence: 0,
            logo: logo)
    }

    @Test("无 logo：串逐字节不变（含锁定段与 [vout] 标签）")
    func nilLogoKeepsExistingString() {
        let expected = "[0:v]trim=start_frame=0:end_frame=60,setpts=PTS-STARTPTS,"
            + "scale=720:1280:force_original_aspect_ratio=decrease,"
            + "pad=720:1280:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=30[base];"
            + "[base]null[masked];[masked]null[vout];"
            + "[0:a]atrim=start=0.00000:end=2.00000,asetpts=PTS-STARTPTS,aresample=44100[aout]"
        #expect(build(logo: nil).filterComplex == expected)
        #expect(build(logo: nil).videoMapLabel == "[vout]")
        #expect(build(logo: nil).audioMapLabel == "[aout]")
    }

    @Test("有 logo：链接在最终画面之后，videoMapLabel 仍 [vout]")
    func logoAppendedAfterFinalVideo() {
        let stage = LogoOverlayStage(layers: [
            .init(inputIndex: 2, rect: PixelRect(x: 0, y: 0, width: 396, height: 122)),
        ])
        let g = build(logo: stage)
        #expect(g.filterComplex.contains("[masked]null[voutBase];"))
        #expect(g.filterComplex.contains("[voutBase][logo0]overlay=0:0[vout];"))
        #expect(g.filterComplex.hasSuffix("[aout]"))
        #expect(g.videoMapLabel == "[vout]")
        #expect(g.audioMapLabel == "[aout]")
    }

    @Test("freezePad 时先 tpad 到 voutBase，再叠 logo")
    func freezePadThenLogo() {
        let stage = LogoOverlayStage(layers: [
            .init(inputIndex: 2, rect: PixelRect(x: 0, y: 0, width: 396, height: 122)),
        ])
        let g = build(logo: stage, freeze: 9)
        #expect(g.filterComplex.contains("tpad=stop_mode=clone:stop_duration=0.300[voutBase];"))
        #expect(g.filterComplex.contains("[voutBase][logo0]overlay=0:0[vout];"))
    }
}
