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
        // 720×1280 是典型：用户口述放行过，但没有逐条对着平台读数核过，因此不在 provenAccepted 里。
        // 拿"没证据"去拦用户，就是拿猜测当事实。
        for (w, h) in [(720, 1280), (2160, 3840), (900, 1600), (1080, 1620)] {
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

// MARK: - DS-05 派生量随基准漂移

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
