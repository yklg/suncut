import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// DS · 导出画布尺寸唯一真源（`DeliverySpec.swift`）
//
// ## 这组测试为什么存在
//
// 2026-10-19，本应用批量导出的 41 条成片整批被巨量千川拒收，面板红字
// 「素材尺寸（宽度）不符合规范」。实测这 41 条**全部是 480×854**，而导出链路
// 从头到尾没有任何一处知道自己是 480 宽：尺寸规则抄了 7 份，导出前不校验、
// 导出后只回读 `start_time` 与 `duration`，从不回读宽高。
//
// 本文件钉的是"收敛之后规则只有一份、且那份算得出正确东西"。
//
// ## ⚠️ 这里**不**钉平台的门槛数值
//
// 千川到底按「宽度下限」「必须精确 9:16」还是「标准分辨率白名单」判，三个假设
// 在现有数据里互相混淆、一个都没被证伪（详见 `DeliverySpec` 的文档注释）。
// 所以 `DeliverySpec` 只登记**一手证据**，`judge` 只对已证的形状表态。
// 谁要是往这里加一个没来源的 `minWidth = 720`，本文件的 DS-08 会红。
// ============================================================================

// MARK: - DS-01 档位 → 画布矩阵

@Suite("DS · 档位到画布的换算")
struct DeliveryCanvasMatrixTests {

    /// 参数化先例：`OrphanFileFinderTests.swift` 的 `arguments:`。
    /// 档位 × 素材最大宽高 是一张天然矩阵，逐条写 `@Test` 会把同一件事抄十几遍。
    @Test("档位×源 → 画布：逐格对表",
          arguments: [
            // (档位, 源最大宽, 源最大高, 期望宽, 期望高)
            (DeliveryTier.p1080, 1080, 1920, 1080, 1920),
            (DeliveryTier.p1080, 2160, 3840, 1080, 1920),
            (DeliveryTier.p1080, 720, 1280, 1080, 1920),
            (DeliveryTier.p720, 1080, 1920, 720, 1280),
            (DeliveryTier.p720, 480, 960, 720, 1280),
            (DeliveryTier.p720, 704, 1248, 720, 1280),
            (DeliveryTier.original, 1080, 1920, 1080, 1920),
            (DeliveryTier.original, 2160, 3840, 2160, 3840),
            (DeliveryTier.original, 703, 1247, 704, 1248),   // 奇数向上取偶
            (DeliveryTier.original, 480, 960, 480, 960),
          ])
    func matrix(tier: DeliveryTier, srcW: Int, srcH: Int, wantW: Int, wantH: Int) {
        let got = DeliveryCanvas.size(tier: tier, sourceMaxWidth: srcW, sourceMaxHeight: srcH)
        #expect(got == DeliveryCanvas(width: wantW, height: wantH),
                "\(tier.rawValue) 配 \(srcW)×\(srcH) 应得 \(wantW)×\(wantH)，实得 \(got.width)×\(got.height)")
    }

    @Test("固定投放档不得被素材尺寸带偏：非 9:16、超小、超大三类源都算出同一块画布")
    func fixedTierIgnoresSourceShape() {
        // 这三颗都是素材库里**真实存在**的非 9:16 素材（2026-10-19 ffprobe 实测）。
        // 旧实现下它们只要成为本批最大尺寸，就会原样变成成片画布。
        for src in [(480, 960), (704, 1248), (720, 960), (2160, 3840)] {
            let c = DeliveryCanvas.size(tier: .p1080, sourceMaxWidth: src.0, sourceMaxHeight: src.1)
            #expect(c.width * 16 == c.height * 9, "480×960 这类源把 1080p 档带偏了：\(c.width)×\(c.height)")
        }
    }

    @Test("横屏源也不再翻转固定档 —— 两份旧抄本行为不一致，收敛时统一到竖屏")
    func landscapeSourceKeepsPortraitCanvas() {
        // 旧 `ExportService` 那份写着 `maxWidth > maxHeight ? "1920:1080" : "1080:1920"`，
        // 旧 `DubExportService` 那份不认横屏。现网素材全为竖屏，该分支不可达；
        // 这条测试把"统一到竖屏"这个决定钉住，不让它哪天悄悄分叉回去。
        let c = DeliveryCanvas.size(tier: .p1080, sourceMaxWidth: 1920, sourceMaxHeight: 1080)
        #expect(c == DeliveryCanvas(width: 1080, height: 1920), "实得 \(c.width)×\(c.height)")
    }

    @Test("滤镜字符串是冒号形状（不是 x），且与画布同源")
    func filterStringShape() {
        #expect(DeliveryCanvas(width: 1080, height: 1920).filterString == "1080:1920")
        // 旧代码里那句 `// scale 滤镜用冒号，非 x` 只活在注释里；现在它有一个断言。
        #expect(!DeliveryCanvas(width: 720, height: 1280).filterString.contains("×"))
    }
}

// MARK: - DS-02 偶数与兜底

@Suite("DS · 偶数不变量与缺测兜底")
struct DeliveryCanvasInvariantsTests {

    @Test("任意源尺寸算出的画布宽高都是偶数（yuv420p 色度次采样要求）",
          arguments: [1, 2, 3, 479, 480, 481, 703, 704, 705, 1079, 1080, 1081, 2159, 2160, 2161])
    func canvasIsAlwaysEven(_ side: Int) {
        for tier in DeliveryTier.allCases {
            let c = DeliveryCanvas.size(tier: tier, sourceMaxWidth: side, sourceMaxHeight: side * 2)
            #expect(c.width % 2 == 0 && c.height % 2 == 0,
                    "\(tier.rawValue) 配 \(side) 算出奇数画布 \(c.width)×\(c.height)")
        }
    }

    @Test("奇数向上取偶，不向下取（向下会让画布比素材还小，白丢一行像素）",
          arguments: [(479, 480), (481, 482), (1079, 1080), (2, 2), (480, 480)])
    func evenUpRoundDirection(_ pair: (Int, Int)) {
        #expect(DeliveryCanvas.evenUp(pair.0) == pair.1, "\(pair.0) 应取偶成 \(pair.1)")
    }

    @Test("源宽高缺失（0 / 负数）退回 1080×1920，绝不产出 0×0")
    func missingSourceDimsFallBack() {
        // scale=0:0 会让 ffmpeg 直接失败，而失败点离"导入没跑完"这个真因隔着三层。
        for (w, h) in [(0, 0), (-1, -1), (0, 1920), (1080, 0)] {
            let c = DeliveryCanvas.size(tier: .original, sourceMaxWidth: w, sourceMaxHeight: h)
            #expect(c.width > 0 && c.height > 0, "\(w)×\(h) 应当兜底，实得 \(c.width)×\(c.height)")
            #expect(c == DeliveryCanvas(width: 1080, height: 1920))
        }
    }
}

// MARK: - DS-03 平台证据表与闸

@Suite("DS · 交付目标判定")
struct DeliverySpecJudgingTests {

    @Test("已证拒收的三个形状必须判拒，且闸口文案指得到日期与一手来源")
    func provenRejectedShapesAreBlocked() {
        for (w, h) in [(480, 854), (480, 960), (704, 1248)] {
            let msg = DeliveryGate.rejectionMessage(for: .qianchuanVertical, width: w, height: h)
            #expect(msg != nil, "\(w)×\(h) 是 2026-10-19 实传被千川拒收的形状，闸口却放行")
            #expect(msg!.contains("2026-10-19"), "文案必须带取证日期，否则证据会腐烂得无人察觉")
            #expect(msg!.contains("拒收"), "文案必须说清是被证明拒收，实得：\(msg ?? "nil")")
        }
    }

    @Test("已证放行的形状判通过且不拦")
    func provenAcceptedShapePasses() {
        #expect(DeliverySpec.qianchuanVertical.judge(width: 1080, height: 1920) == .ok)
        #expect(DeliveryGate.rejectionMessage(for: .qianchuanVertical, width: 1080, height: 1920) == nil)
    }

    @Test("未被任何一手记录覆盖的形状判 unproven —— 未核验不等于不合格，闸口必须放行")
    func unprovenShapesAreNotBlocked() {
        // 720×1280 是典型：用户口述放行过，但没有逐条对着平台读数核过，因此不在 provenAccepted 里
        // （F 格正在证它）。拿"没证据"去拦用户，就是拿猜测当事实。
        // 126×224 是刻意挑的：它**精确 9:16**、宽得离谱、名册里没有 ——
        // 用来证明"比例规则"不会顺手把没测过的小尺寸一起拦掉（规则只管比例，宽度下限仍未立）。
        // 注：900×1600 与 1080×1620 已从本表移出，2026-10-19 五格对照给了它们确定读数。
        // 2160×3840 也已移出 —— 面板原文有**上限** 1440*2560，4K 是越界不是未核验（见 DS-04c）。
        // 126×224 也已移出：它精确 9:16 但宽度远低于 720，按平台先后次序会被区间规则拦掉，
        // 属于"已证越界"不是"未核验"。这里只留**两条规则都合、却没被任何记录覆盖**的尺寸
        // （宽须被 9 整除才是精确 9:16：729×16=11664=1296×9、1179×16=18864=2096×9）。
        for (w, h) in [(720, 1280), (729, 1296), (1179, 2096), (1440, 2560)] {
            #expect(DeliverySpec.qianchuanVertical.judge(width: w, height: h) == .unproven,
                    "\(w)×\(h) 没有任何一手记录覆盖")
            #expect(DeliveryGate.rejectionMessage(for: .qianchuanVertical, width: w, height: h) == nil,
                    "\(w)×\(h) 未核验却被硬拦")
        }
    }

    @Test("「不限」目标两张表都为空 ⇒ 什么都不拦（本地留档腿）")
    func unrestrictedSpecNeverBlocks() {
        #expect(DeliverySpec.unrestricted.provenAccepted.isEmpty)
        #expect(DeliverySpec.unrestricted.provenRejected.isEmpty)
        for (w, h) in [(480, 854), (480, 960), (1080, 1920)] {
            #expect(DeliverySpec.unrestricted.judge(width: w, height: h) == .unproven)
            #expect(DeliveryGate.rejectionMessage(for: .unrestricted, width: w, height: h) == nil)
        }
    }

    @Test("缺省交付目标必须是千川，不是「不限」—— 缺省到不限等于没有闸")
    func fallbackIsQianchuan() {
        #expect(DeliverySpec.fallback == .qianchuanVertical)
    }
}

// MARK: - DS-04b 两条独立校验（2026-10-19 五格对照的产出）

@Suite("DS · 宽度名册与比例规则是两条独立校验")
struct AspectRuleTests {

    @Test("486×864 是精确 9:16，它被拒只能记在**宽度**名册上，不许记成违反比例规则")
    func narrowButExactRatioIsRejectedByRosterNotRule() {
        let verdict = DeliverySpec.qianchuanVertical.judge(width: 486, height: 864)
        guard case .rejected(let reason) = verdict else {
            Issue.record("486×864 实传被拒，判定却是 \(verdict)"); return
        }
        #expect(reason == .thisSizeProvenRejected(
                    DeliverySpec.qianchuanVertical.provenRejected.first { $0.width == 486 }!),
                "B 格的平台原文是「（宽度）」，理由必须记在名册上：\(reason)")
    }

    @Test("1080×1620 宽 1080 完全够，它被拒只能记成违反比例规则")
    func wrongRatioIsRejectedByRule() {
        let verdict = DeliverySpec.qianchuanVertical.judge(width: 1080, height: 1620)
        guard case .rejected(let reason) = verdict else {
            Issue.record("1080×1620 实传被拒，判定却是 \(verdict)"); return
        }
        guard case .violatesProvenRule(let rule, let evidence) = reason else {
            Issue.record("C 格的平台原文是「比例」，理由必须记在规则上：\(reason)"); return
        }
        #expect(rule == .exactNineSixteen)
        #expect(evidence.date == "2026-10-19")
        let msg = DeliveryGate.rejectionMessage(for: .qianchuanVertical, width: 1080, height: 1620)
        #expect(msg?.contains("精确 9:16") == true, "文案要指得出违反了哪条规则：\(msg ?? "nil")")
    }

    @Test("900×1600 不是任何标准分辨率档，却实传放行 ⇒ 平台不查白名单")
    func nonStandardExactRatioSizeIsAccepted() {
        #expect(DeliverySpec.qianchuanVertical.judge(width: 900, height: 1600) == .ok)
    }

    /// 平台原文（用户 2026-10-19 截自「上传视频」面板）：
    /// 「竖版视频：宽高比9:16，视频码率≥516kbps，大小≤1000M，**720*1280≤分辨率≤1440*2560**，4s≤时长≤300s」
    /// 与同批实传逐格对表一致：486×864 与 480×854 报「（宽度）」被拒、900×1600 放行。
    @Test("分辨率**上限**是这张规则表里新的一半：4K 走 .original 会超上限被拒")
    func resolutionRangeHasACeilingToo() {
        guard let range = DeliverySpec.qianchuanVertical.resolutionRange else {
            Issue.record("千川目标没带分辨率区间 —— 上限那条又没人守了"); return
        }
        #expect(range.contains(width: 1080, height: 1920))
        #expect(range.contains(width: 720, height: 1280), "下限应当含边界")
        #expect(range.contains(width: 1440, height: 2560), "上限应当含边界")
        // 素材库里实有 10 颗 2160×3840；.original 是面板默认档 ⇒ 这颗以前无人拦
        #expect(!range.contains(width: 2160, height: 3840))
        guard case .rejected(.outsideProvenResolutionRange) = DeliverySpec.qianchuanVertical
                .judge(width: 2160, height: 3840) else {
            Issue.record("2160×3840 精确 9:16 但超上限，必须被区间规则拦下"); return
        }
    }

    @Test("次序要照平台自己的先后来：宽度与比例都不合时，报的是区间（D 格实测如此）")
    func rangeIsCheckedBeforeRatio() {
        // 400×711 既不在区间内、也不是精确 9:16，且**不在名册里**
        // —— 用一颗没传过的，才证明是规则在按次序判，而不是名册先命中。
        #expect(400 * 16 != 711 * 9, "这颗必须两条都不合，否则本测试什么都没测")
        let verdict = DeliverySpec.qianchuanVertical.judge(width: 400, height: 711)
        guard case .rejected(let reason) = verdict else {
            Issue.record("400×711 该被拦，实得 \(verdict)"); return
        }
        #expect(reason == .outsideProvenResolutionRange(DeliverySpec.qianchuanVertical.resolutionRange!),
                "平台对 480×854 报的是「（宽度）」，所以区间要先于比例：\(reason)")
    }

    @Test("区间规则也必须带一手证据，且不许凭空存在")
    func rangeCarriesEvidenceAndIsTargetScoped() {
        guard let range = DeliverySpec.qianchuanVertical.resolutionRange else {
            Issue.record("千川目标缺区间规则"); return
        }
        #expect(range.evidence.source.contains("720*1280"), "要引面板原文：\(range.evidence.source)")
        #expect(range.evidence.date == "2026-10-19")
        #expect(DeliverySpec.unrestricted.resolutionRange == nil,
                "「不限」目标不该带任何区间")
    }

    @Test("规则不许无证据存在：每条 AspectRule 都要有非空来源与日期")
    func everyRuleCarriesEvidence() {
        for rule in AspectRule.allCases {
            let e = rule.evidence
            #expect(e.source.count >= 8, "\(rule.rawValue) 的来源写得太短，回溯不到：\(e.source)")
            #expect(e.date.count == 10 && e.date.contains("-"), "\(rule.rawValue) 缺日期：\(e.date)")
            for banned in ["待核验", "未核验", "TODO", "听说", "应该"] {
                #expect(!e.source.contains(banned), "规则来源里出现「\(banned)」= 无证据立规则")
            }
        }
        #expect(!DeliverySpec.qianchuanVertical.aspectRules.isEmpty, "千川目标必须带着已证规则")
        #expect(DeliverySpec.qianchuanVertical.resolutionRange != nil, "千川目标必须带着已证区间")
    }

    @Test("规则只属于所选目标：「不限」下 1080×1620 仍是未核验，不是被拦")
    func rulesAreScopedToTheTarget() {
        #expect(DeliverySpec.unrestricted.aspectRules.isEmpty)
        #expect(DeliverySpec.unrestricted.judge(width: 1080, height: 1620) == .unproven)
        #expect(DeliveryGate.rejectionMessage(for: .unrestricted, width: 1080, height: 1620) == nil)
    }

    /// 本规则取**零容差**（`w*16 == h*9` 整数相等），这比已证的边界更严一档：
    /// 实传只证了「2:3 被拒」与「精确 9:16 放行」，**平台对"差两像素"的近邻尺寸容不容、
    /// 容多少从未测过**。取零容差是有方向的保守 —— 宁可拦下一个也许能过的画布，
    /// 也不要放出去一条整批报废（2026-10-19 那 41 条就是这么发生的）。
    /// 若哪天要放宽，必须先去平台实传取证，不许凭感觉填容差。
    @Test("零容差：差 2 像素的近邻画布按规则拦下（此立场比已证边界更严，理由见注释）")
    func ratioRuleIsZeroTolerance() {
        #expect(!AspectRule.exactNineSixteen.isSatisfied(width: 1080, height: 1922))
        #expect(!AspectRule.exactNineSixteen.isSatisfied(width: 1080, height: 1918))
        #expect(AspectRule.exactNineSixteen.isSatisfied(width: 1080, height: 1920))
        #expect(AspectRule.exactNineSixteen.isSatisfied(width: 486, height: 864))
        #expect(AspectRule.exactNineSixteen.isSatisfied(width: 900, height: 1600))
        // 旧 480p 档写死的 (480, 854) 正是这条规则要拦的典型：480×16=7680 ≠ 854×9=7686
        #expect(!AspectRule.exactNineSixteen.isSatisfied(width: 480, height: 854))
    }

    @Test("名册命中优先于规则：704×1248 既在名册又不合规则，理由要记成实传过的那条")
    func rosterBeatsRule() {
        guard case .rejected(let reason) = DeliverySpec.qianchuanVertical.judge(width: 704, height: 1248)
        else { Issue.record("704×1248 实传被拒却没判拒"); return }
        #expect(reason == .thisSizeProvenRejected(
                    DeliverySpec.qianchuanVertical.provenRejected.first { $0.width == 704 }!),
                "亲手传过的尺寸应当优先引用那条记录：\(reason)")
    }
}

// MARK: - DS-04c 时长区间（面板原文第四条校验）

@Suite("DS · 时长区间")
struct DurationRangeTests {

    @Test("上下边界含端点；越界的两侧各判一次拒", arguments: [
        // (秒, 期望是否放行)
        (0.3, false), (3.9, false), (4.0, true), (60.0, true),
        (300.0, true), (300.1, false), (3600.0, false),
    ])
    func boundaries(seconds: Double, expectOK: Bool) {
        let v = DeliverySpec.qianchuanVertical.verdict(durationSeconds: seconds)
        if expectOK {
            #expect(v == .ok, "\(seconds)s 在 4~300s 内，却判 \(v)")
        } else {
            guard case .rejected(.outsideProvenDurationRange) = v else {
                Issue.record("\(seconds)s 越界，却没被区间规则拦住（实得 \(v)）"); return
            }
        }
    }

    @Test("那颗真实越界产物：3.066667s 必须判拒，且文案指得到「时长」")
    func realOffendingArtifactIsCaught() {
        let v = DeliverySpec.qianchuanVertical.verdict(durationSeconds: 3.066667)
        guard case .rejected(let reason) = v else {
            Issue.record("实测 3.066667s 的产物未被拦（实得 \(v)）"); return
        }
        #expect(reason.violationLabel.contains("时长"), "文案要说是时长：\(reason.violationLabel)")
        #expect(reason.evidence.date == "2026-10-19")
    }

    @Test("时长规则也必须带一手原文，且「会拒」那一半不许冒充实测")
    func durationEvidenceIsHonest() {
        guard let range = DeliverySpec.qianchuanVertical.durationRange else {
            Issue.record("千川目标缺时长区间"); return
        }
        #expect(range.evidenceSource.contains("4s≤时长≤300s"), "要引面板原文：\(range.evidenceSource)")
        // 那颗 3.07s 文件只证了"存在越界产物"，没证"平台会拒"—— 注释必须自己承认这点
        #expect(range.evidenceSource.contains("未被实传"),
                "证据串要写清「会拒」是原文推定不是实测：\(range.evidenceSource)")
        #expect(range.evidenceDate.count == 10)
        #expect(DeliverySpec.unrestricted.durationRange == nil, "「不限」不该带时长区间")
        #expect(DeliverySpec.unrestricted.verdict(durationSeconds: 0.3) == .unproven)
    }

    /// 时长与尺寸**故意不合成一个 judge**：没有证据说明平台先查哪一条。
    @Test("时长与尺寸各自独立判定，不许假装知道谁先")
    func durationAndSizeAreJudgedSeparately() {
        // 一颗尺寸完全合规、时长越界的：尺寸判 ok，时长判拒
        #expect(DeliverySpec.qianchuanVertical.judge(width: 1080, height: 1920) == .ok)
        guard case .rejected(.outsideProvenDurationRange) =
                DeliverySpec.qianchuanVertical.verdict(durationSeconds: 2.0) else {
            Issue.record("尺寸合规但时长 2s 越界，该被时长规则单独拦住"); return
        }
    }
}

// MARK: - DS-04 证据表自身不许掺水

@Suite("DS · 证据表完整性")
struct DeliverySpecEvidenceTests {

    @Test("每条证据都必须有非空来源与日期，且不得写未核验类字样")
    func everyRecordIsTraceable() {
        let all = DeliverySpec.qianchuanVertical.provenAccepted
            + DeliverySpec.qianchuanVertical.provenRejected
        #expect(!all.isEmpty, "千川目标一条证据都没有 ⇒ 这张表是摆设")
        for r in all {
            #expect(r.width > 0 && r.height > 0)
            #expect(r.source.count >= 8, "来源写得太短，回溯不到：\(r.source)")
            #expect(r.date.count == 10 && r.date.contains("-"), "日期必须是 yyyy-MM-dd，实得 \(r.date)")
            for banned in ["待核验", "未核验", "TODO", "待定", "听说", "应该"] {
                #expect(!r.source.contains(banned), "证据来源里出现「\(banned)」= 把猜测登记成事实")
                #expect(!r.date.contains(banned))
            }
        }
    }

    @Test("已证放行与已证拒收两张表不得有同一形状（自相矛盾的证据）")
    func tablesDoNotContradict() {
        let accepted = Set(DeliverySpec.qianchuanVertical.provenAccepted.map { "\($0.width)x\($0.height)" })
        for r in DeliverySpec.qianchuanVertical.provenRejected {
            #expect(!accepted.contains("\(r.width)x\(r.height)"),
                    "\(r.width)×\(r.height) 同时被判过放行与拒收")
        }
    }
}

// MARK: - DS-05 面板回显与换算同源

@Suite("DS · 面板回显")
struct DeliveryReadoutTests {

    /// 回显里那个数字必须**就是** `size()` 算出来的那个 —— 不是第二处拼出来的。
    /// 做法：把 `size()` 的输出格式化进期望串，再要求 `readout` 含同一串。
    @Test("固定档回显逐字含 size() 的产出，且三种判定各说各的话", arguments: [
        // (目标, 档位, 期望尾巴关键词)
        (DeliveryTargetID.qianchuanVertical, DeliveryTier.p1080, "平台已证放行"),
        (DeliveryTargetID.qianchuanVertical, DeliveryTier.p720, "未核验"),
        (DeliveryTargetID.unrestricted, DeliveryTier.p1080, "未核验"),
    ])
    func readoutCarriesTheSameNumber(target: DeliveryTargetID, tier: DeliveryTier, tail: String) {
        let canvas = DeliveryCanvas.size(tier: tier, sourceMaxWidth: 0, sourceMaxHeight: 0)
        let text = DeliveryCanvas.readout(target: target, tier: tier)
        #expect(text.contains("\(canvas.width)×\(canvas.height)"),
                "回显没报出 size() 的 \(canvas.width)×\(canvas.height)：\(text)")
        #expect(text.contains(target.label), "回显要说清交付目标：\(text)")
        #expect(text.contains(tail), "判定措辞应为「\(tail)」：\(text)")
    }

    @Test("已证拒收的尺寸必须在回显里被点名，而不是静默显示一个数")
    func rejectedSizeIsNamed() {
        // 480×960 是 2026-10-19 用户实传被拒的形状；用 .original + 显式源尺寸复现它
        let text = DeliveryCanvas.readout(target: .qianchuanVertical,
                                          tier: .original, sourceMaxWidth: 480, sourceMaxHeight: 960)
        #expect(text.contains("480×960"), "回显里没有该画布：\(text)")
        #expect(text.contains("已被平台证明不可投放"), "拒收形状不能只报个数：\(text)")
        #expect(text.contains("2026-10-19"), "要带取证日期：\(text)")
    }

    @Test(".original 且面板没有素材尺寸时，回显必须承认不知道，不许假报一个数")
    func originalWithoutSourceDimsAdmitsIgnorance() {
        // 面板若自己再遍历一遍素材去"预测"最大宽，就是第八份算尺寸的抄本 —— 那正是本次事故的形状。
        let text = DeliveryCanvas.readout(target: .qianchuanVertical, tier: .original)
        #expect(!text.contains("×"), "没有素材尺寸却报了具体画布，等于猜：\(text)")
        #expect(text.contains("导出时现算"), "要如实说明不知道：\(text)")
    }

    @Test("给了素材尺寸时 .original 回显必须报出取偶后的实际画布")
    func originalWithSourceDimsReportsCanvas() {
        let text = DeliveryCanvas.readout(target: .unrestricted,
                                          tier: .original, sourceMaxWidth: 703, sourceMaxHeight: 1247)
        #expect(text.contains("704×1248"), "奇数应取偶后回显：\(text)")
    }
}

// MARK: - DS-06 派生量随基准漂移

@Suite("DS · 派生量的基准不变量")
struct DerivedMetricBasisTests {

    /// 此前全仓没有任何一条测试给 `canonicalWidth` 传过非默认值 ——
    /// 于是"按 1080 基准换算"这件事只在一个点上被测过，换个画布就没人管。
    @Test("预览模糊半径按 displayWidth / canonicalWidth 线性缩放，并被短边 1/4 钳住")
    func previewBlurRadiusTracksBasis() {
        let mode = SubtitleMaskMode.blur
        let nominal = CGFloat(mode.renderSpec.nominalBlurRadius)
        #expect(nominal > 0, "blur 档标称半径必须为正，否则这条测试什么都没测")

        // 基准 == 显示宽 ⇒ 不缩放（cropHeight 取到不会被 1/4 钳位的大小，专门测缩放这一半）
        #expect(mode.previewBlurRadius(displayWidth: 1080, displayCropHeight: 800, canonicalWidth: 1080)
                == nominal)
        // 显示宽是基准的 2/3 ⇒ 半径也应是 2/3
        let at720 = mode.previewBlurRadius(displayWidth: 720, displayCropHeight: 800, canonicalWidth: 1080)
        #expect(abs(at720 - nominal * 720 / 1080) < 0.001,
                "720 宽上的半径应为 \(nominal * 720 / 1080)，实得 \(at720)")
        // 短边 1/4 的钳位必须仍然生效 —— 缩放算出来了也不能越过 ffmpeg 的硬限
        let clamped = mode.previewBlurRadius(displayWidth: 1080, displayCropHeight: 40, canonicalWidth: 1080)
        #expect(clamped == 10, "裁面短边 40 ⇒ 半径上限 10，实得 \(clamped)")
    }

    /// 本条不是"验证它不变"，而是**把量到的不不变性登记下来**，防止哪天有人以为换个基准是安全的。
    ///
    /// 2026-10-19 手算并与实测温差对表（`ratio = 0.06`）：
    /// - 720×1280 → `fontSize 43.2`、`ceil(60.48)=61`、padding `max(18, 8.64)=18` ⇒ `97/1280  = 0.07578`
    /// - 1080×1920 → `fontSize 64.8`、`ceil(90.72)=91`、padding `max(18, 12.96)=18` ⇒ `127/1920 = 0.06615`
    /// - 2160×3840 → `fontSize 129.6`、`ceil(181.44)=182`、padding `max(18, 25.92)=25.92` ⇒ `233.84/3840 = 0.06090`
    ///
    /// 根因：`CaptionRenderer.minVerticalPadding = 18` 是**绝对像素**下限，不随 canonical 基准缩放
    /// （`verticalPaddingFactor = 0.20` 要到 `fontSize > 90` 才接管，即 `canonicalWidth × ratio > 90`）。
    /// ⇒ 基准越大，那 36px 固定留白在画面里占比越小，相对下限越低。
    ///
    /// 今天**生产无害**：所有调用点都吃 1080×1920 的默认基准。但 `canonicalWidth/Height` 是 public
    /// 形参，谁传一块别的基准就会拿到差 14.6% 的下限而毫无提示 —— 本条把方向与量级钉死。
    @Test("字幕下限随 canonical 基准**不**保持不变：基准越大、相对下限越低（绝对留白 18px 不缩放）")
    func captionFloorDriftsWithCanonicalBasis() {
        let ratio = 0.06
        func floor(_ w: Int, _ h: Int) -> Double {
            SubtitleMaskRect.minimumHeight(fontRatio: ratio, canonicalWidth: w, canonicalHeight: h)
        }
        let at720 = floor(720, 1280), at1080 = floor(1080, 1920), at2160 = floor(2160, 3840)

        #expect(at720 > at1080 && at1080 > at2160,
                "方向必须是基准越大下限越低，实得 \(at720) / \(at1080) / \(at2160)")
        // 量级：720 基准比 1080 高约 14.6%（实测值，改动这个数要有意的）
        #expect(abs(at720 / at1080 - 1.0) > 0.05,
                "差异已被抹平 ⇒ 要么留白改成随基准缩放（那本条注释要一起改），要么这条测试失效")
        #expect(abs(at720 / at1080 - 1.0) < 0.30, "差异大到不合理：\(at720) vs \(at1080)")
        // 三条都仍须落在合法区间内
        for f in [at720, at1080, at2160] {
            #expect(f >= SubtitleMaskRect.minSize && f <= 1.0, "下限越界：\(f)")
        }
    }

    @Test("字号比例越大，遮挡带下限必须越高（单调，且与基准无关）",
          arguments: [(720, 1280), (1080, 1920), (2160, 3840)])
    func captionFloorIsMonotonicInFontRatio(_ basis: (Int, Int)) {
        let small = SubtitleMaskRect.minimumHeight(fontRatio: 0.03,
                                                   canonicalWidth: basis.0, canonicalHeight: basis.1)
        let large = SubtitleMaskRect.minimumHeight(fontRatio: 0.09,
                                                   canonicalWidth: basis.0, canonicalHeight: basis.1)
        #expect(large > small, "\(basis.0)×\(basis.1) 基准上字号翻倍而下限没涨：\(small) → \(large)")
    }
}
