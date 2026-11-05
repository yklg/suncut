import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// BF · 空镜承接规划器 + 多段画面滤镜图（B 块差额后置档）
//
// 这批判据钉的是四条纪律里能纯函数化的那三条：
// ① 同一段画面不许播两遍（同源重叠剔除 / 每片只用一次）；
// ② 确定性（乱序输入同一个 plan，全仓无随机）；
// ③ 接不满必须照实报 filled=false，调用方继续拦 —— 不许用半段空镜出一条音画不同步的片子。
// 外加滤镜图两格：无空镜时**逐字节不变**（反向对照），有空镜时归一化链与 concat 齐全。
// ============================================================================

private func supply(_ label: String, _ start: Int, _ end: Int,
                    fps: Double = 25, path: String? = nil,
                    source: String? = nil) -> BrollSupply {
    BrollSupply(label: label, videoPath: path ?? "/tmp/\(label).mp4",
                startFrame: start, endFrame: end, fps: fps,
                sourceKey: source ?? "src-\(label)")
}

private func demand(needed: Double, tolerance: Double = 0.05,
                    slot: String = "seg_001", windowSource: String = "src-window",
                    windowStart: Int = 0, windowEnd: Int = 100) -> BrollDemand {
    BrollDemand(neededSeconds: needed, toleranceSeconds: tolerance, slotSegmentLabel: slot,
                windowSourceKey: windowSource, windowStartFrame: windowStart, windowEndFrame: windowEnd)
}

@Suite("BF · 空镜承接规划")
struct BrollFillPlanTests {

    @Test("BF-1 一片就够 ⇒ 截到刚好补齐，且报接满")
    func singleSupplyCoversExactly() {
        var used = Set<String>()
        let p = BrollPolicy.plan(demand(needed: 2.0),
                                 supplies: [supply("seg_009", 0, 125)], consumed: &used)
        #expect(p.pieces.count == 1)
        #expect(p.pieces[0].frames == 50, "2.0s@25fps 必须截 50 帧；截多了等于把成片垫得比配音还长")
        #expect(p.filled, "接满了却报未接满 ⇒ 会被白拦一条能导的片子")
        #expect(used == ["seg_009"])
    }

    @Test("BF-2 需求在容差内 ⇒ 一片都不插")
    func withinToleranceInsertsNothing() {
        var used = Set<String>()
        let p = BrollPolicy.plan(demand(needed: 0.04),
                                 supplies: [supply("seg_009", 0, 125)], consumed: &used)
        #expect(p == .empty, "容差内的溢出也插空镜 ⇒ 每格尾巴多一帧无关画面，全片累积成毛刺")
    }

    @Test("BF-3 零需求 / 负需求 ⇒ 空 plan 且算接满")
    func noNeedIsNotAFailure() {
        var used = Set<String>()
        #expect(BrollPolicy.plan(demand(needed: 0), supplies: [], consumed: &used) == .empty)
        #expect(BrollPolicy.plan(demand(needed: -3), supplies: [], consumed: &used) == .empty)
    }

    @Test("BF-4 池子不够 ⇒ filled=false，且已取的片照实交回")
    func exhaustedPoolReportsUnfilled() {
        var used = Set<String>()
        let p = BrollPolicy.plan(demand(needed: 5.0),
                                 supplies: [supply("seg_009", 0, 25), supply("seg_010", 0, 25)],
                                 consumed: &used)
        #expect(p.pieces.count == 2)
        #expect(p.coveredSeconds == 2.0)
        #expect(!p.filled, "差 3s 却报接满 ⇒ 导出会拿半段空镜出一条口播没垫满的片子")
    }

    @Test("BF-5 同源自重叠的画面被剔（成片里同一段不许播两遍）")
    func sameSourceOverlapIsRejected() {
        var used = Set<String>()
        // 本格窗口 [0,100)；seg_009 与它重叠 ⇒ 剔；seg_010 起点恰等窗口尾帧 ⇒ 留（开区间）
        let s = [supply("seg_009", 50, 150, source: "src-window"),
                 supply("seg_010", 100, 200, source: "src-window")]
        let p = BrollPolicy.plan(demand(needed: 1.0, windowEnd: 100), supplies: s, consumed: &used)
        #expect(p.pieces.count == 1)
        #expect(p.pieces[0].videoPath == "/tmp/seg_010.mp4",
                "拿重叠的那片 ⇒ 同一段源画面在成片里连播两遍（B 块第一版就是这么漏的）")
    }

    @Test("BF-6 反向对照：不同源的画面允许，哪怕帧号完全相同")
    func differentSourceSameFramesAllowed() {
        var used = Set<String>()
        let p = BrollPolicy.plan(demand(needed: 1.0, windowStart: 0, windowEnd: 100),
                                 supplies: [supply("seg_009", 0, 100, source: "src-other")],
                                 consumed: &used)
        #expect(p.filled, "把不同源的画面也剔了 ⇒ 池子被误判为空，差额永远接不住")
    }

    @Test("BF-7 本格自己那条分镜不许当自己的空镜")
    func ownSegmentIsNotBroll() {
        var used = Set<String>()
        let p = BrollPolicy.plan(demand(needed: 1.0),
                                 supplies: [supply("seg_001", 200, 300, source: "src-other")],
                                 consumed: &used)
        #expect(p.pieces.isEmpty && !p.filled, "label 等于本格分镜编号却被当供给 ⇒ 同一段画面播两遍")
    }

    @Test("BF-8 每片至多用一次：跨槽位共享同一本占用账")
    func eachSupplyUsedOnceAcrossSlots() {
        var used = Set<String>()
        let pool = [supply("seg_009", 0, 100)]
        let first = BrollPolicy.plan(demand(needed: 1.0), supplies: pool, consumed: &used)
        let second = BrollPolicy.plan(demand(needed: 1.0), supplies: pool, consumed: &used)
        #expect(first.filled)
        #expect(second.pieces.isEmpty && !second.filled,
                "第二条槽复用同一片 ⇒ 同一段空镜在成片里出现两次（半段复用也算）")
    }

    @Test("BF-9 确定性：供给乱序输入得到同一个 plan")
    func orderingIsDeterministic() {
        var usedA = Set<String>()
        var usedB = Set<String>()
        let a = BrollPolicy.plan(demand(needed: 3.0),
                                 supplies: [supply("seg_009", 0, 25), supply("seg_003", 0, 25),
                                           supply("seg_011", 0, 25)], consumed: &usedA)
        let b = BrollPolicy.plan(demand(needed: 3.0),
                                 supplies: [supply("seg_011", 0, 25), supply("seg_003", 0, 25),
                                           supply("seg_009", 0, 25)], consumed: &usedB)
        #expect(a == b, "顺序取决于传入次序 ⇒ 同一库重导同一条片子会换画面（无法复现，也无法判回归）")
        #expect(a.pieces.map(\.videoPath) == ["/tmp/seg_003.mp4", "/tmp/seg_009.mp4", "/tmp/seg_011.mp4"],
                "排序键是分镜编号 → 起点帧")
    }

    @Test("BF-10 封顶 4 片：接不满就停，不把一格变成快切空镜集锦")
    func pieceCountIsCapped() {
        var used = Set<String>()
        let many = (1...9).map { supply("seg_0\(String(format: "%02d", $0))", 0, 25) }
        let p = BrollPolicy.plan(demand(needed: 20.0), supplies: many, consumed: &used)
        #expect(p.pieces.count == BrollPolicy.maxPiecesPerSlot)
        #expect(!p.filled)
        #expect(used.count == BrollPolicy.maxPiecesPerSlot, "没插进去的片不许记占用（否则第二格凭空少料）")
    }

    @Test("BF-11 结构性不可用的供给：零帧 / 坏帧率，一律剔掉不报错")
    func unusableSuppliersSkipped() {
        var used = Set<String>()
        let p = BrollPolicy.plan(demand(needed: 1.0),
                                 supplies: [supply("seg_003", 50, 50),
                                           supply("seg_004", 0, 100, fps: 0),
                                           supply("seg_005", 0, 25, source: "src-other")],
                                 consumed: &used)
        #expect(p.pieces.count == 1 && p.filled)
        #expect(used == ["seg_005"])
    }

    @Test("BF-12 池子秒数是单槽乐观口径：只算前 4 片，且不含被剔的")
    func poolSecondsIsOptimisticPerSlot() {
        let many = (1...6).map { supply("seg_0\(String(format: "%02d", $0))", 0, 25) }
        // 6 片 × 1s，单槽封顶 4 片 ⇒ 4s（不是 6s）
        #expect(BrollPolicy.poolSeconds(many, for: demand(needed: 1.0)) == 4.0)
        // 与本格同源重叠的那片不进池
        let overlapped = [supply("seg_009", 50, 150, source: "src-window")]
        #expect(BrollPolicy.poolSeconds(overlapped, for: demand(needed: 1.0, windowEnd: 100)) == 0)
    }
}

@Suite("BF · 多段画面滤镜图")
struct BrollGraphTests {

    private static let noFill = "[0:v]trim=start_frame=15:end_frame=75,setpts=PTS-STARTPTS,"
        + "scale=1080:1920:force_original_aspect_ratio=decrease,"
        + "pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=25[base]"

    private func base(fills: [PicturePieceSource] = []) -> DubSegmentGraph {
        DubSegmentGraphBuilder.build(
            mode: .none, startFrame: 15, endFrame: 75, fps: 25,
            outputWidth: 1080, outputHeight: 1920,
            maskPixel: PixelRect(x: 0, y: 0, width: 100, height: 20),
            captions: [], keepOriginalAudio: false, dubAudioInputIndex: 1,
            freezePadFrames: 0, trailingSilence: 0, fills: fills)
    }

    @Test("BF-13 反向对照：没有空镜时滤镜串里那颗 [base] 与改造前逐字节相同")
    func noFillKeepsTheOldGraphByteForByte() {
        let g = base()
        #expect(g.filterComplex.contains(Self.noFill),
                "无空镜的既有导出腿被改了一点 ⇒ 所有在跑的成片口径都跟着变（这格就是拦住它的）")
        #expect(!g.filterComplex.contains("concat="), "没插空镜却拼 concat ⇒ 单段画面也走了多段路径")
        #expect(!g.filterComplex.contains("[pic0]"))
    }

    @Test("BF-14 一片空镜：两段 trim + concat=n=2，且下游仍吃 [base]")
    func oneFillConcatsTwoPieces() {
        let g = base(fills: [PicturePieceSource(inputIndex: 2, startFrame: 0, endFrame: 50, fps: 25)])
        #expect(g.filterComplex.contains("[2:v]trim=start_frame=0:end_frame=50"))
        #expect(g.filterComplex.contains("[pic0][pic1]concat=n=2:v=1:a=0[base]"))
        #expect(g.filterComplex.contains("[base]null[masked]"), "concat 的输出没接上下游 ⇒ 画面直接丢")
    }

    @Test("BF-15 空镜素材自己的帧率不许漏进出片：归一化一律用槽位帧率")
    func fillIsResampledToSlotFps() {
        // 空镜素材 30fps，槽位 25fps ⇒ 帧号按它自己的 30fps 取，出片仍 fps=25
        let g = base(fills: [PicturePieceSource(inputIndex: 3, startFrame: 60, endFrame: 90, fps: 30)])
        #expect(g.filterComplex.contains("[3:v]trim=start_frame=60:end_frame=90,setpts=PTS-STARTPTS"))
        #expect(g.filterComplex.contains("setsar=1,fps=25[pic1]"),
                "把空镜的 30fps 写成 fps=30 ⇒ 中间片帧率不齐，阶段二 concat -c copy 必红")
    }

    @Test("BF-16 两片空镜：输入序号必须真的出现在串里（不是全用 0:v）")
    func multipleFillsUseTheirOwnInputs() {
        let g = base(fills: [PicturePieceSource(inputIndex: 2, startFrame: 0, endFrame: 25, fps: 25),
                             PicturePieceSource(inputIndex: 3, startFrame: 40, endFrame: 65, fps: 25)])
        #expect(g.filterComplex.contains("[pic0][pic1][pic2]concat=n=3:v=1:a=0[base]"))
        #expect(g.filterComplex.contains("[3:v]trim=start_frame=40:end_frame=65"))
    }
}
