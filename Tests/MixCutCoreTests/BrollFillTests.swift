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

@Suite("BF · 入池的第三道证据（静音占比）")
struct BrollSupplyGateTests {

    @Test("BF-25 非套话、文本非空的段：静音占比定罪才入池")
    func energyEvidenceAdmitsNonPhraseText() {
        // 纯音乐被 whisper 认成「Zither Harp」那一类：文本非空、名单也不命中
        let text = "Zither Harp"
        #expect(!BrollPolicy.acceptsAsSupply(text: text, taggedAsEmptyShot: true),
                "没给证据时本该拒（这是并行线那道读侧闸的既有口径，不能被新功能悄悄放宽）")
        #expect(BrollPolicy.acceptsAsSupply(text: text, taggedAsEmptyShot: true, voicedFraction: 0.05),
                "给了'窗口内 95% 是静音'的证据还拒 ⇒ 能量层补标的段进不了池，补了等于没补")
    }

    @Test("BF-26 反向对照：证据说全程在响 ⇒ 仍不入池（手改标签的口子没放宽）")
    func loudEvidenceStillRejected() {
        #expect(!BrollPolicy.acceptsAsSupply(text: "秋冬一到嘴就干", taggedAsEmptyShot: true,
                                            voicedFraction: 0.98),
                "有声音证据说这段一直在响，还让它入池 ⇒ 池子重新变成手改标签就能进")
        #expect(!BrollPolicy.acceptsAsSupply(text: "秋冬一到嘴就干", taggedAsEmptyShot: false,
                                            voicedFraction: 0.0),
                "没打「空镜」标签 ⇒ 再安静的画面也不能自动当插片用（标签是唯一的入口）")
    }

    @Test("BF-27 阈值只有一颗：入池闸与拦打标用同一个数")
    func thresholdIsSharedWithTheTaggingGate() {
        let atCeil = EmptyLensPolicy.voicedFractionCeil
        #expect(BrollPolicy.acceptsAsSupply(text: "Zither Harp", taggedAsEmptyShot: true,
                                           voicedFraction: atCeil),
                "闸与池在阈值边界上必须同判（一个收一个拒 ⇒ 标签打了、池子却不要）")
        #expect(!BrollPolicy.acceptsAsSupply(text: "Zither Harp", taggedAsEmptyShot: true,
                                             voicedFraction: atCeil + 0.001))
        #expect(EmptyLensPolicy.energyConvicts(voicedFraction: atCeil + 0.001) == false)
        #expect(EmptyLensPolicy.energyConvicts(voicedFraction: nil) == false,
                "没探测过 ≠ 全程静音：nil 必须判不成立")
    }
}

@Suite("BF · 生成侧的空镜预算（跨槽占用账）")
struct SchemeBrollBudgetTests {

    // 预算这颗存在的理由：空镜"每片至多用一次"。生成侧若只看本槽的池子，
    // 就会对每一格都许诺整个池子 ⇒ 生成放行、导出拦下，而那时 TTS 钱已经花掉了。
    private func budget(_ demands: [BrollDemand], target: Int, supplies: [BrollSupply]) -> Double {
        SchemeBrollBudget.brollSecondsAvailable(demands: demands, targetIndex: target,
                                                supplies: supplies, granularitySeconds: 0.04)
    }

    @Test("BF-17 池子够 ⇒ 本槽需求全额可得")
    func fullNeedWhenPoolIsBigEnough() {
        let got = budget([demand(needed: 2.0)], target: 0, supplies: [supply("seg_009", 0, 100)])
        #expect(got >= 1.95 && got <= 2.0,
                "池子够却给不满需求 ⇒ 超字闸仍会拒一条本来接得住的文案（got \(got)）")
    }

    @Test("BF-18 池子只有一半 ⇒ 只报一半，不许许诺整池")
    func partialPoolIsReportedPartially() {
        let got = budget([demand(needed: 2.0)], target: 0, supplies: [supply("seg_009", 0, 25)])
        #expect(got >= 0.95 && got <= 1.06,
                "1s 的池子却报 2s ⇒ 导出侧一定接不满，钱白花（got \(got)）")
    }

    @Test("BF-19 前面的槽已把池子吃光 ⇒ 本槽预算为 0")
    func earlierSlotExhaustsPool() {
        let demands = [demand(needed: 2.0, slot: "seg_001"), demand(needed: 2.0, slot: "seg_002")]
        let got = budget(demands, target: 1, supplies: [supply("seg_009", 0, 50)])
        #expect(got == 0, "池子已被前一格占掉还给第二格许诺 ⇒ 两格都以为接得住（got \(got)）")
    }

    @Test("BF-20 后面的槽已有配音占了池子 ⇒ 不许把它的量抢来给自己")
    func laterExistingNeedIsReserved() {
        // 目标格在前（位置 0），第二格**已经生成过**一条差 2s 的配音，池子总共只有 2s
        let demands = [demand(needed: 2.0, slot: "seg_001"), demand(needed: 2.0, slot: "seg_002")]
        let got = budget(demands, target: 0, supplies: [supply("seg_009", 0, 50)])
        #expect(got == 0,
                "抢走了已花钱那条配音该用的空镜 ⇒ 导出时前一格接住、后一格被拦，等于把已生成的配音作废")
    }

    @Test("BF-21 反向对照：池子够两格用时，本槽照样拿满（证 BF-20 不是恒 0）")
    func poolBigEnoughForBoth() {
        let demands = [demand(needed: 2.0, slot: "seg_001"), demand(needed: 2.0, slot: "seg_002")]
        let got = budget(demands, target: 0, supplies: [supply("seg_009", 0, 50), supply("seg_010", 0, 50)])
        #expect(got >= 1.95,
                "池子明明够两格却报 0 ⇒ 超字闸退化成 B-2 之前的硬拒，用户还得改短台词")
    }

    @Test("BF-22 没需求 / 没池子 / 下标越界 ⇒ 一律 0，不猜")
    func degenerateInputsYieldZero() {
        #expect(budget([demand(needed: 0)], target: 0, supplies: [supply("seg_009", 0, 100)]) == 0)
        #expect(budget([demand(needed: 2.0)], target: 0, supplies: []) == 0)
        #expect(SchemeBrollBudget.brollSecondsAvailable(demands: [demand(needed: 2.0)], targetIndex: 5,
                                                       supplies: [supply("seg_009", 0, 100)],
                                                       granularitySeconds: 0.04) == 0)
        #expect(SchemeBrollBudget.brollSecondsAvailable(demands: [demand(needed: 2.0)], targetIndex: 0,
                                                       supplies: [supply("seg_009", 0, 100)],
                                                       granularitySeconds: 0) == 0,
                "步长给 0 会转不完 ⇒ 这颗必须拒收非法步长")
    }

    @Test("BF-23 自证：把预算填回需求再重放，别的槽照样接得住（这数可兑现）")
    func promisedNumberIsHonorable() {
        // 两条各 2s 的空镜；本格要 3s、后格要 2s ⇒ 本格最多只能拿满**一条** 2s：
        // 拿 2.5s 会同时占用两条（用掉半片=整片被占，纪律 2），后格就饿死。
        let supplies = [supply("seg_009", 0, 50), supply("seg_010", 0, 50)]
        let got = budget([demand(needed: 3.0, slot: "seg_001"), demand(needed: 2.0, slot: "seg_002")],
                         target: 0, supplies: supplies)
        #expect(got >= 1.95 && got <= 2.05, "只能拿满第一条 2s（实得 \(got)）")
        // 把预算填回本格需求再问后格：它照样该拿满 2s，否则这颗数是空头承诺
        let after = budget([demand(needed: got, slot: "seg_001"), demand(needed: 2.0, slot: "seg_002")],
                           target: 1, supplies: supplies)
        #expect(after >= 1.95,
                "按预算分配后另一格反而接不住 ⇒ 生成侧拿这颗数放行、导出侧却拦（白烧 TTS）")
    }

    @Test("BF-24 容差以内的需求不占池子 ⇒ 预算归零，不留步长残渣")
    func withinToleranceBudgetIsExactlyZero() {
        let got = budget([demand(needed: 3.0, slot: "seg_001"), demand(needed: 0.04, slot: "seg_002")],
                         target: 1, supplies: [supply("seg_009", 0, 75)])
        #expect(got == 0, "0.04s 的需求一片都不占 ⇒ 报 0.02x 这种二分残渣等于允许可见的半帧空镜")
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

// MARK: - 入池口径（纪律 1 的可执行形态，2026-11-06）

@Test("BF-ADMIT-1 入池四档等价类：未标签一律拒；标签+空台词/套话放行；标签+真口播拒")
func admissionEquivalenceClasses() {
    // ① 没打「空镜」标签 ⇒ 无论台词是什么都不进池（标签是必要条件）。
    #expect(!BrollPolicy.acceptsAsSupply(text: "", taggedAsEmptyShot: false),
            "没打空镜标签的空白段进了池 ⇒ 必要条件被绕过")
    #expect(!BrollPolicy.acceptsAsSupply(text: "秋冬一到嘴就干", taggedAsEmptyShot: false),
            "没打空镜标签的真口播进了池")

    // ② 标签 + 台词归一后为空 ⇒ 放行。
    #expect(BrollPolicy.acceptsAsSupply(text: "", taggedAsEmptyShot: true),
            "空台词的空镜段被拒 ⇒ 差额承接拿不到最正当的那批供给")
    #expect(BrollPolicy.acceptsAsSupply(text: "   \n ", taggedAsEmptyShot: true),
            "纯空白台词没被归一成空 ⇒ 与 ① 同一档却给了不同答案")

    // ③ 标签 + 台词是 whisper 幻觉套话（**非空**）⇒ 必须放行。
    //    这一档是整颗口径的存在理由：只按"台词为空"筛就会把旧库补标产出的供给全踢掉。
    let phrase = EmptyLensPolicy.knownHallucinationPhrases[0]
    #expect(BrollPolicy.acceptsAsSupply(text: phrase, taggedAsEmptyShot: true),
            "名单层命中的段被请出池 ⇒ 补标这条路白做，差额承接回到空池")

    // ④ 标签 + 真口播 ⇒ 拒（用户手改、MCP 乱写都挡在这里）。
    #expect(!BrollPolicy.acceptsAsSupply(text: "秋冬一到嘴就干，这颗橙子汁水多到离谱",
                                        taggedAsEmptyShot: true),
            "有口播的段仅凭标签就进了插片池 ⇒ 读侧闸没生效")
}

@Test("BF-ADMIT-2 不变式：名单层判成空镜的文本，必然入池（补标命中集 ⊆ 池子）")
func phraseVerdictImpliesAdmission() {
    // 这条把「写侧补标的判据」与「读侧入池的判据」锁成同一件事：
    // 只要 phraseOnlyVerdict 判空镜，acceptsAsSupply 就必须放行 —— 否则补标产出的段永远进不了池。
    var offenders: [String] = []
    for phrase in EmptyLensPolicy.knownHallucinationPhrases {
        guard EmptyLensPolicy.phraseOnlyVerdict(phrase).isEmptyLens else {
            offenders.append("名单条目本身不再判空镜：\(phrase.prefix(8))")
            continue
        }
        if !BrollPolicy.acceptsAsSupply(text: phrase, taggedAsEmptyShot: true) {
            offenders.append("判成空镜却入不了池：\(phrase.prefix(8))")
        }
        // 带尾巴的变体（幻觉套话后面又接了几个字）也必须一致，否则"就地复算"这条腿会漂移。
        let withTail = phrase + "转发"
        let verdictStill = EmptyLensPolicy.phraseOnlyVerdict(withTail).isEmptyLens
        let admitted = BrollPolicy.acceptsAsSupply(text: withTail, taggedAsEmptyShot: true)
        if verdictStill != admitted {
            offenders.append("带尾巴变体两侧不一致：verdict=\(verdictStill) 入池=\(admitted)")
        }
    }
    #expect(offenders.isEmpty, "\(offenders)")
    #expect(!EmptyLensPolicy.knownHallucinationPhrases.isEmpty, "名单是空的 ⇒ 上面整条恒真，不算通过")
}

@Test("BF-ADMIT-3 反向对照：只按「台词为空」筛的口径会打断补标（证明口径不能那么写）")
func naiveEmptyTextOnlyFilterWouldBreakBackfill() {
    // 这棵是"看起来最自然"的错实现：`tagged && text.isEmpty`。
    // 它必须与真口径在名单层那一档上给出**不同**答案 —— 否则 BF-ADMIT-2 那条不变式是空的。
    let phrase = EmptyLensPolicy.knownHallucinationPhrases[0]
    func naive(_ text: String, _ tagged: Bool) -> Bool { tagged && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    #expect(naive(phrase, true) == false, "错实现竟然也放行套话段 ⇒ 两口径等价，BF-ADMIT-2 失去意义")
    #expect(BrollPolicy.acceptsAsSupply(text: phrase, taggedAsEmptyShot: true) == true,
            "真口径反而拒了套话段 ⇒ 不变式那条腿已经先红了")
    // 而两口径在"真口播"那一档必须一致地拒 —— 不一致就说明读侧闸只是换个地方放水。
    #expect(naive("这颗橙子汁水多到离谱", true) == false
            && BrollPolicy.acceptsAsSupply(text: "这颗橙子汁水多到离谱", taggedAsEmptyShot: true) == false,
            "真口播在某一口径下进了池")
}

@Test("BF-ADMIT-4 已知漏口照实拦：非套话的纯音乐文本不是空镜，别当已解决")
func knownMissStaysMissAdmitted() {
    // EL-18 钉的是同一件事的写侧（判不出空镜）；这里钉读侧：那种段即使被人手打了标签，
    // 只要文本既非空又不在名单上，就不该进插片池。
    for text in ["Zither Harp", "你的眼中只有我"] {
        #expect(!BrollPolicy.acceptsAsSupply(text: text, taggedAsEmptyShot: true),
                "\(text) 进了插片池 ⇒ 读侧闸比写侧漏得更多")
    }
}
}
