import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// DiskSpaceBudget 判据（B1–B5 → 用例 D1–D9）。
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md（R16 / Step 3 / Step 4）
//
// 这一族要守的是**一个方向性不变量**：预检读数只许偏大、不许偏小。
// 偏小的预检不会立刻报错，而是在导出到第 k 条时把盘写爆（第九节「落盘失败」档），
// 所以这里既有算式对照（与既有 ×2 口径、与导出面板的码率文案同源），也有取整方向、
// 溢出方向和"垃圾输入不炸整批"三条边界。
// ============================================================================

struct DiskSpaceBudgetTests {

    private let mbps = DiskSpaceBudget.defaultOutputBitrateMbps

    @Test("D1 成片项为空时退回既有口径：素材 ×2（B1，与 ImportViewModel.swift:152 同式）")
    func noOutputsReducesToExistingFormula() {
        #expect(DiskSpaceBudget.materialMultiplier == 2)
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: 1_000, outputDurations: [],
                                              bitrateMbps: mbps) == 2_000)
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: 0, outputDurations: [],
                                              bitrateMbps: mbps) == 0)
    }

    @Test("D2 补上成片项：一次出 4 条、每条 60 秒 ⇒ 4 × 60 MB（R16 新增项，缺它就是那条低估）")
    func outputTermsAreAdded() {
        let required = DiskSpaceBudget.requiredBytes(
            materialBytes: 1_000, outputDurations: [60, 60, 60, 60], bitrateMbps: mbps)
        #expect(required == 2_000 + 4 * 60_000_000)
        // 「照抄 ×2」的变异就是这条红：N 增大时读数必须跟着涨
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: 1_000, outputDurations: [60],
                                              bitrateMbps: mbps)
                < required)
    }

    @Test("D3 逐行各算一项再相加（B2），不是先求总时长再取整一次")
    func perRowAccountingNotAggregate() {
        // 两条亚字节成片：逐行向上取整各要 1 字节 ⇒ 合计 2；先合计再取整只要 1
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: 0,
                                              outputDurations: [0.000_000_1, 0.000_000_1],
                                              bitrateMbps: mbps) == 2)
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: 0, outputDurations: [0.000_000_2],
                                              bitrateMbps: mbps) == 1,
                "同样长的素材当成一条算只给 1 字节 —— 这就是「先合计再取整」与逐行取整的差")
    }

    @Test("D4 取整方向只许向上（B3）：亚字节项也按 1 字节要，不四舍五入、不截断")
    func roundingIsAlwaysUp() {
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 0.000_000_1, bitrateMbps: mbps) == 1)
        // 下面几条在二进制浮点里都恰好落在整数上，验的是单位链（bit≠byte）而不是取整
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 1.0, bitrateMbps: mbps) == 1_000_000)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 0.3, bitrateMbps: 1) == 37_500)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 0.25, bitrateMbps: 1) == 31_250)
        // 单位链反例：若把 Mbps 当 MB/s（少除 8），0.25 秒 @1Mbps 会算成 250_000
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 0.25, bitrateMbps: 1) < 100_000)
    }

    @Test("D5 溢出饱和到 Int64.max，不回绕成小数或负数（B4：预检宁可拒绝）")
    func overflowSaturates() {
        let huge = Int64.max / 2 + 1
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: huge, outputDurations: [],
                                              bitrateMbps: mbps) == Int64.max)
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: Int64.max,
                                              outputDurations: [1_000_000_000],
                                              bitrateMbps: mbps) == Int64.max)
        // 单条时长本身溢出
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 1e300, bitrateMbps: mbps) == Int64.max)
        // 任何输入都不许给出负数
        let v = DiskSpaceBudget.requiredBytes(materialBytes: Int64.max - 1,
                                              outputDurations: [Double(Int64.max)],
                                              bitrateMbps: mbps)
        #expect(v == Int64.max && v > 0)
    }

    @Test("D6 非有限/非正的时长与码率按 0 计（B5：这类素材的真实归宿是逐名上报，不是炸掉整批预检）")
    func garbageInputsAreZeroNotCrash() {
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: .nan, bitrateMbps: mbps) == 0)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: .infinity, bitrateMbps: mbps) == Int64.max)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: -5, bitrateMbps: mbps) == 0)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 0, bitrateMbps: mbps) == 0)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 60, bitrateMbps: .nan) == 0)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 60, bitrateMbps: 0) == 0)
        // 混合批：坏的一条不牵连其他条（"整批因单条失败静默中止"是禁项）
        #expect(DiskSpaceBudget.requiredBytes(materialBytes: 0, outputDurations: [.nan, 60],
                                              bitrateMbps: mbps) == 60_000_000)
    }

    @Test("D7 判定口径与既有预检一致：available < required 才算不足（相等算够）")
    func sufficiencyBoundaryMatchesExistingCheck() {
        let need = DiskSpaceBudget.requiredBytes(materialBytes: 500, outputDurations: [60],
                                                 bitrateMbps: mbps)
        #expect(DiskSpaceBudget.isSufficient(freeBytes: need, requiredBytes: need))
        #expect(!DiskSpaceBudget.isSufficient(freeBytes: need - 1, requiredBytes: need))
        #expect(DiskSpaceBudget.isSufficient(freeBytes: 0, requiredBytes: 0))
    }

    @Test("D8 码率常量与导出面板同源（B3 的另一半：两处报的数不许分家）")
    func bitrateConstantIsTheConservativeUpperEdge() {
        // 8 Mbps 取自 ExportService.swift:78 的 default 档与 FFmpegRunner.swift:658 的默认入参，
        // 也是 ExportService.swift:100 那句「约 5-8 Mbps」的上沿。它一旦被改小，
        // 预检就会系统性偏小 ⇒ 这条钉子要求改动它的人同时看见导出面板那三处文案。
        #expect(mbps == 8)
        #expect(DiskSpaceBudget.outputBytes(durationSeconds: 30, bitrateMbps: mbps) == 30_000_000,
                "导出面板写「30 秒视频约 X MB」的那条式子必须与这里同口径（ExportService.swift:91-93）")
    }

    @Test("D9 方案里那笔账：N=8 时漏算成片项 ≈ 缺 480 MB（R16 的量级，不是理论风险）")
    func measuredGapAgainstOldFormula() {
        let material: Int64 = 8 * 100_000_000          // 8 类各 100 MB
        let durations = Array(repeating: 60.0, count: 8)
        let old = material * DiskSpaceBudget.materialMultiplier
        let new = DiskSpaceBudget.requiredBytes(materialBytes: material,
                                                outputDurations: durations, bitrateMbps: mbps)
        let gap = new - old
        #expect(gap == 8 * 60_000_000)
        #expect(gap > 300_000_000 && gap < 600_000_000,
                "计划里记的「N=8 漏算约 300–480 MB」就是这个量级；换成秒级短素材仍成立")
    }

    // ── B6（笔 4 懒入库）：未知时长不计入，但必须逐名报出 ──

    @Test("B6a 未知时长的成片项不计入总量 —— 按 0 计入就是给用户少报")
    func unknownDurationsAreNotCountedAsFree() {
        let knownOnly = DiskSpaceBudget.estimate(
            materialBytes: 1_000,
            items: [DiskSpaceOutputItem(name: "行1", durationSeconds: 60)], bitrateMbps: mbps)
        let withUnknown = DiskSpaceBudget.estimate(
            materialBytes: 1_000,
            items: [DiskSpaceOutputItem(name: "行1", durationSeconds: 60),
                    DiskSpaceOutputItem(name: "行2", durationSeconds: nil)], bitrateMbps: mbps)
        // 未知项**不进**加法 ⇒ 与不含它时逐字相等；写成 `?? 0` 的实现在这条上红
        #expect(withUnknown.requiredBytes == knownOnly.requiredBytes)
        #expect(withUnknown.hasUnknownDurations)
        // 而已知那项确实被算了（否则这条等式会因为"整个成片项被漏掉"而侥幸成立）
        #expect(withUnknown.requiredBytes > DiskSpaceBudget.requiredBytes(
            materialBytes: 1_000, outputDurations: [], bitrateMbps: mbps))
    }

    @Test("B6b 未知项逐名报出，顺序按传入序 —— 只给个数就看不见是哪几条")
    func unknownDurationsAreNamed() {
        let e = DiskSpaceBudget.estimate(
            materialBytes: 0,
            items: [DiskSpaceOutputItem(name: "行1", durationSeconds: nil),
                    DiskSpaceOutputItem(name: "行2", durationSeconds: 41),
                    DiskSpaceOutputItem(name: "行3", durationSeconds: nil)], bitrateMbps: mbps)
        #expect(e.unknownDurationNames == ["行1", "行3"])
        #expect(e.unknownDurationNames.count == 2)
    }

    @Test("B6c 全未知 ⇒ 退回纯素材项，且仍然逐名点名（开局就在补数不等于没有预算）")
    func allUnknownFallsBackToMaterialOnly() {
        let e = DiskSpaceBudget.estimate(
            materialBytes: 5_000,
            items: [DiskSpaceOutputItem(name: "行1", durationSeconds: nil),
                    DiskSpaceOutputItem(name: "行2", durationSeconds: nil)], bitrateMbps: mbps)
        #expect(e.requiredBytes == DiskSpaceBudget.requiredBytes(
            materialBytes: 5_000, outputDurations: [], bitrateMbps: mbps))
        #expect(e.unknownDurationNames.count == 2)
    }
}
