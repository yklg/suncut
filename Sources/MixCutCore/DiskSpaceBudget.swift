import Foundation

// ============================================================================
// 文件夹混剪 · 磁盘预检（纯值 + 纯函数，零 FileManager）。
//
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md（R16 / Step 3 / Step 4）
//
// 为什么不是照抄现成的式子：`ImportViewModel` 现在的预检是
//     let requiredSpace = totalFileSize * 2        // ImportViewModel.swift:163
// 它算的是"复制进来 + 留一份余量"，**没有算 N 条成片的输出**。混剪一次出 N 条 ⇒
// 缺口正好是"预检通过、导出到第 6 条磁盘满"那种事故形态（第九节「落盘失败」档要求
// 预检读数与实际拷贝失败数可对账）。所以这里在原式之上补上成片项：
//
//     required = 素材总字节 × 2  +  Σ(每条成片时长 × 码率/8)
//                └ 沿用既有口径 ┘    └ R16 新增项 ┘
//
// 接口锁定（DiskSpaceBudgetTests 依赖这些形状）：
//   public enum DiskSpaceBudget {
//       static let materialMultiplier: Int64                 // = 2
//       static let defaultOutputBitrateMbps: Double          // = 8
//       static func outputBytes(durationSeconds:bitrateMbps:) -> Int64
//       static func requiredBytes(materialBytes:outputDurations:bitrateMbps:) -> Int64
//       static func estimate(materialBytes:items:bitrateMbps:) -> DiskSpaceEstimate
//       static func isSufficient(freeBytes:requiredBytes:) -> Bool
//   }
//   public struct DiskSpaceOutputItem { name, durationSeconds: Double? }
//   public struct DiskSpaceEstimate   { requiredBytes, unknownDurationNames, hasUnknownDurations }
//
// 规则：
//   B1 `materialMultiplier` 保持 2 —— 与既有母体导入同口径，本期**不**改它（改它等于同时改导入页的行为）。
//   B2 成片项按**每行实际时长**求和，不乘 N 的平均值：混剪的 N 条各不相同，平均值会低估长的那几条。
//   B3 取整一律**向上**（`.rounded(.up)`）：预检的系统性方向只许是"多要"，不许是"少要"。
//   B4 溢出饱和到 `Int64.max` 而不是回绕成小数：预检宁可拒绝，不可放行后写爆盘。
//   B5 非正/NaN 的时长或码率 → 该项按 0 计（这类素材的真实归宿是第九节「单文件读不出时长」档，
//      逐名上报，不靠预检兜）；**+∞ 例外**：它按「未知的大」处理，饱和到 Int64.max。
//   B6 「未知时长」与「0 秒」是两件事：懒入库下探针可能还没回填（决定 6 不许当 0 秒），
//      `estimate` 把这类项**不计入总量**但**逐名**列进 `unknownDurationNames`。
//      为什么不是按 0 计进总量：0 是免费额度，红字少报 ⇒ 用户按少报的数勾了「我已确认」；
//      为什么不是整批拒绝：那会把"后台还在补数"正常态变成开局就报错。
//
// 非空洞性论证（实现写错时哪条测试红）：
//   - 漏掉成片项（照抄 ×2）        → D2 红（N>0 时 required 与 N==0 相同）
//   - 乘 N 的平均时长而非逐行      → D3 红（长短行不同时读数不同）
//   - 取整用 `.down` 或 `Int(x)`   → D4 红（小数部分被丢掉 ⇒ 系统性偏小）
//   - 溢出改成回绕                 → D5 红（巨大输入算出小数/负数）
//   - B5 的守卫写成"抛错"         → D6 红（0 时长参与运算时不该炸整批）
//   - B6 把未知折成 0 塞进总量     → B6a 红（含未知项的读数 > 纯素材项 ⇒ 说明它被算了）
//   - B6 只报个数不报名字           → B6b 红（界面无法逐名出声，「—」和计数对不上）
// ============================================================================

public enum DiskSpaceBudget {

    /// 素材落盘的倍数口径。出处：`MixCut/ViewModels/ImportViewModel.swift:163` 的
    /// `requiredSpace = totalFileSize * 2`（复制进来 + 留一份余量）。
    public static let materialMultiplier: Int64 = 2

    /// 成片码率取值：**取现有码率文案的保守上沿**，不取中间值。
    /// 三处出处（全部实读，别改成本文件自己拍的数）：
    /// - `MixCut/Services/Export/ExportService.swift:72` — `(.medium, .h264Hardware) → 6_000` kbps
    /// - `MixCut/Services/Export/ExportService.swift:78` — `default → 8_000` kbps
    /// - `MixCut/Services/Export/ExportService.swift:100` — CRF 中档文案「约 5-8 Mbps」
    /// - `MixCut/Services/VideoProcessing/FFmpegRunner.swift:658` — 拼接入口默认 `videoBitrateKbps: 8_000`
    /// 取 8 Mbps ⇒ 60 秒约 60 MB，落在方案里"38–60 MB"区间的上沿。
    public static let defaultOutputBitrateMbps: Double = 8

    /// 一条成片的字节数：`码率(Mbps) × 1e6 / 8 × 时长(秒)`，向上取整。
    /// 只算视频轨；音频轨（AAC 128–192 kbps ≈ 视频项的 1.6–2.4%）落在 B3 的余量里，
    /// 不为它再造第二个真源 —— 导出页那句「30 秒视频约 X MB」用的是同一条式子
    /// （`ExportService.swift:91-93`），口径必须一致，否则预检和面板会报两个不同的数。
    public static func outputBytes(durationSeconds: Double, bitrateMbps: Double) -> Int64 {
        // B5：非正或 NaN（NaN 与任何数比较都是 false，落进这里）⇒ 该项按 0 计。
        //     这类素材的真实归宿是第九节「单文件读不出时长」档（逐名上报），预检不替它沉默。
        guard durationSeconds > 0, bitrateMbps > 0 else { return 0 }
        // 「无穷大」不是「坏数据」而是「未知的大」⇒ 往拒绝方向偏（B3/B4 同一个方向）
        if durationSeconds.isInfinite || bitrateMbps.isInfinite { return Int64.max }
        let bytesPerSecond = bitrateMbps * 1_000_000.0 / 8.0
        let raw = durationSeconds * bytesPerSecond
        guard raw.isFinite, raw < Double(Int64.max) else { return Int64.max }        // B4
        let rounded = raw.rounded(.up)                                               // B3
        // 注意这里用 `<` 而不是 `<=`：`Double(Int64.max)` 本身就是 2^63（Int64 装不下），
        // 写成 `<=` 会让 Int64(rounded) 在边界上直接 trap。
        return rounded < Double(Int64.max) ? Int64(rounded) : Int64.max
    }

    /// 预检总量：素材 ×2 ＋ 每条成片的时长各算一项（B1/B2）。
    /// `outputDurations` 的长度就是"一次出几条"⇒ 空数组退回既有口径（素材 ×2），
    /// 母体导入页将来也能复用同一个入口，不必再抄一遍式子。
    public static func requiredBytes(materialBytes: Int64,
                                     outputDurations: [Double],
                                     bitrateMbps: Double) -> Int64 {
        var total: Int64 = 0
        if materialBytes > 0 {
            let (doubled, overflow) = materialBytes.multipliedReportingOverflow(by: materialMultiplier)
            total = overflow ? Int64.max : doubled                                     // B4
        }
        for duration in outputDurations {
            let (next, overflow) = total.addingReportingOverflow(
                outputBytes(durationSeconds: duration, bitrateMbps: bitrateMbps))
            total = overflow ? Int64.max : next                                        // B4
        }
        return total
    }

    /// 预算 + 「哪些项因为时长未知没算进去」（B6）。
    ///
    /// 为什么不复用上面那颗、把未知当 0 传进去：0 在式子里是**免费额度**
    /// （`outputBytes` 的非正分支就按 0 计），而"未知"是"还不知道"。
    /// 超软上限那句红字是用户勾「我已确认」的**唯一依据** —— 少报一笔，那一句确认就不作数了。
    /// 取整权威仍只有一处：本函数逐条调 `outputBytes`，不写第二份式子。
    public static func estimate(materialBytes: Int64, items: [DiskSpaceOutputItem],
                                bitrateMbps: Double) -> DiskSpaceEstimate {
        let known = items.compactMap(\.durationSeconds)
        let unknown = items.filter { $0.durationSeconds == nil }.map(\.name)
        return DiskSpaceEstimate(
            requiredBytes: requiredBytes(materialBytes: materialBytes, outputDurations: known,
                                         bitrateMbps: bitrateMbps),
            unknownDurationNames: unknown)
    }

    /// 判定口径与既有预检一致：`availableSpace < requiredSpace` ⇒ 不足（`ImportViewModel.swift:187`）。
    public static func isSufficient(freeBytes: Int64, requiredBytes: Int64) -> Bool {
        freeBytes >= requiredBytes
    }
}

/// 一条待估的成片项：名字 + 时长读数。时长**可选**，就是为了把"未知"传到预算层去点名。
public struct DiskSpaceOutputItem: Equatable, Sendable {
    public let name: String
    public let durationSeconds: Double?

    public init(name: String, durationSeconds: Double?) {
        self.name = name
        self.durationSeconds = durationSeconds
    }
}

/// 预算读数：总字节 + 没算进去的那几项的名字（B6 要"逐名"，只给个数就看不见是哪几条）。
public struct DiskSpaceEstimate: Equatable, Sendable {
    public let requiredBytes: Int64
    public let unknownDurationNames: [String]

    public var hasUnknownDurations: Bool { !unknownDurationNames.isEmpty }

    public init(requiredBytes: Int64, unknownDurationNames: [String]) {
        self.requiredBytes = requiredBytes
        self.unknownDurationNames = unknownDurationNames
    }
}
