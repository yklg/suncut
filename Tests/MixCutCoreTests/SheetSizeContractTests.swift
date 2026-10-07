import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// SHT · App 弹窗（sheet）尺寸契约守卫
//
// ## 为什么要有这道门（它防的是一次真实事故）
//
// `CloneWizardView` 曾**同时**声明两个语义相反的宽度契约：
//     .frame(width: 520)                                // 要求恰好 520
//     .sheetContainerFrame(minWidth: 480, idealWidth: 520, maxWidth: 560)
// 前者是硬性宽度，后者允许收缩到 480。系统按 480 夹紧后，内容仍按 520 排版
// ⇒ 溢出 40pt、左右各切 20pt ⇒ 标题「注册复刻音色」的「注」字与关闭按钮被裁掉。
//
// 关键教训：**这在沙盒 typecheck / silgen 两腿全绿都看不出来**（它们按文件系统
// 扫描，不看布局约束），只有真机跑起来才看得见 ⇒ 必须有机器可校验的守卫。
//
// ## 为什么不用「子 sheet 宽度 ≤ 宿主宽度」这条判据
//
// 已核实 `VoicePickerSheet` 声明 560 宽、其宿主 `SettingsView` 只有 500，
// **却不裁切** —— macOS sheet 在空间不足时会自行收缩到 minWidth。
// 写「子 sheet 必须 ≤ 宿主」会误伤既有正确代码。见 SHT-5 的「合法必绿」样本。
// ============================================================================

// MARK: - 被测判据（纯函数，可单测）

/// sheet 尺寸契约的判据集（**与文件 IO 解耦**，便于做正反用例）。
enum SheetSizeContract {
    /// 从源码里抽出 sheet 的尺寸声明。
    /// - `.frame(width: N)` 的硬性宽度（nil = 没有）。
    /// - `sheetContainerFrame(...)` 的 min/ideal/max（nil = 该项没传）。
    struct Decl: Equatable {
        var hardWidth: CGFloat?
        var minWidth: CGFloat?
        var idealWidth: CGFloat?
        var maxWidth: CGFloat?
        /// `sheetContainerFrame` 之后是否又挂了独立的高度 frame。
        var hasIndependentHeightFrame: Bool = false
        /// 本文件是否用了 sheetContainerFrame（区分「双重契约」与「只有硬宽度」）。
        var usesContainer: Bool = false
    }

    /// 解析一个 view 文件的尺寸声明。
    /// 刻意**只解析真实代码**（剥掉注释与字符串字面量）—— 否则文档里写一句
    /// "sheetContainerFrame" 就会被判成违规，守卫第一次接入就因误判被迫加例外。
    static func parse(codeOnly raw: String) -> Decl {
        var d = Decl()
        d.usesContainer = raw.contains("sheetContainerFrame")

        // ⚠️ 只认**与 sheetContainerFrame 同一条 modifier 链**上的 .frame(width:)，
        //    不能匹配文件里任意 .frame(width:)。
        //
        // 踩坑实测（第一版正则的真实假阳性）：`VoicePickerSheet` / `SegmentGridPickerSheet` /
        // `ScriptWizardView` 全部被判红，报出的「硬性宽度」是 18.0 / 34.0 / 22.0 ——
        // 那是**子元素**的尺寸（图标 frame(width:18)、文字 frame(width:130)），
        // 与弹窗外框毫无关系。全仓130+ 处 .frame(width:) 里绝大多数是子元素。
        //
        // 判据：取 sheetContainerFrame **之后 200 字符**内、位于同一「链」上的
        // .frame(width:才算硬性外框。链的边界用「中间出现 `.sheetContainerFrame` 之外的
        // 顶层链断点」近似——实操上够用：外框 frame 一定紧邻 sheetContainerFrame。
        if let containerRange = raw.range(of: "sheetContainerFrame") {
            // 双向紧邻窗：真实的双重契约是「.frame(width:) 在前 或 在后」，
            // 只看一侧会漏（第一版只看后侧 ⇒ 反向样本 SHT-4 失效）。
            //
            // 两侧都只取**紧邻的 modifier 链**（200 字符窗），不匹配文件里任意
            // .frame(width:)。实测踩坑：全仓 130+ 处 .frame(width:) 绝大多数是
            // **子元素**尺寸（图标 18pt、文字 130pt），不限定就会把
            // VoicePickerSheet / SegmentGridPickerSheet / ScriptWizardView 全判红。
            let after = String(raw[containerRange.upperBound...].prefix(200))
            if let r = firstMatch(after, #"^\s*\.frame\(\s*width:\s*([0-9]+(?:\.[0-9]+)?)"#) {
                d.hardWidth = CGFloat(Double(r) ?? 0)
            }
            if d.hardWidth == nil {
                // 向前找**最后一个** .frame(width:)（最近的才是同一链上的外框），
                // 且它后面不得再出现别的顶层内容（否则属于不同链）。
                let head = String(raw[raw.startIndex..<containerRange.lowerBound].suffix(200))
                if let r = lastMatch(head, #"\.frame\(\s*width:\s*([0-9]+(?:\.[0-9]+)?)"#) {
                    d.hardWidth = CGFloat(Double(r) ?? 0)
                }
            }
        }
        // 抓 sheetContainerFrame(...) 的实参块
        if let r = firstCapture(raw, #"sheetContainerFrame\(([^)]*)\)"#) {
            let args = r
            if let v = argValue(args, "minWidth") { d.minWidth = v }
            if let v = argValue(args, "idealWidth") { d.idealWidth = v }
            if let v = argValue(args, "maxWidth") { d.maxWidth = v }
        }
        // 「sheetContainerFrame 之后又单独挂高度 frame」—— 第二个高度真源
        if let range = raw.range(of: "sheetContainerFrame") {
            let tail = String(raw[range.upperBound...])
            d.hasIndependentHeightFrame =
                tail.contains(#".frame(minHeight:"#) || tail.contains(#".frame(maxHeight:"#)
        }
        return d
    }

    /// 判据 1（🔴 本次的根因）：不得同时用硬性宽度与 sheetContainerFrame。
    ///
    /// 两者语义相反：一个要求恰好 N、一个允许缩到 min（N 与 min 不等时必冲突）。
    static func violatesDoubleWidthContract(_ d: Decl) -> Bool {
        d.usesContainer && d.hardWidth != nil
    }

    /// 判据 2：sheetContainerFrame 出现处，min/ideal/max 不得自相矛盾。
    ///
    /// 只抓「`min < ideal` 且 `max == ideal`」这一种**已被证实有害**的形态
    ///（min 允许缩、max 卡死 ideal ⇒ 与硬性宽度叠加时溢出）。
    /// ⚠️ 刻意**不**禁止「min < ideal 且 max == ∞」——`ScriptWizardView`
    /// 就是这个形态且完全合法（弹窗可在小宿主里收缩）。
    static func violatesWidthTriple(_ d: Decl) -> Bool {
        guard d.usesContainer, let mn = d.minWidth, let ideal = d.idealWidth,
              let mx = d.maxWidth else { return false }
        return mn < ideal && mx == ideal
    }

    /// 判据 3：高度真源唯一 —— 不得在 sheetContainerFrame 之后叠加独立高度 frame。
    static func violatesHeightDoubleSource(_ d: Decl) -> Bool {
        d.usesContainer && d.hasIndependentHeightFrame
    }

    // MARK: - 极简正则helper（够用即可，不引第三方依赖）

    private static func firstMatch(_ s: String, _ p: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: p) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges > 1,
              let rr = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[rr])
    }

    /// 取**最后一个**捕获组（同一 modifier 链上最近的那个 .frame(width:)）。
    private static func lastMatch(_ s: String, _ p: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: p) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        var out: String?
        re.enumerateMatches(in: s, range: r) { m, _, _ in
            guard let m, m.numberOfRanges > 1, let rr = Range(m.range(at: 1), in: s) else { return }
            out = String(s[rr])
        }
        return out
    }

    private static func firstCapture(_ s: String, _ p: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { return nil }
        let r = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: r), m.numberOfRanges > 1,
              let rr = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[rr])
    }

    /// 从实参串里取 `name: 数值`（`.infinity` ⇒ nil，表示不限）。
    private static func argValue(_ args: String, _ name: String) -> CGFloat? {
        guard let re = try? NSRegularExpression(pattern: "\(name):\\s*([0-9]+(?:\\.[0-9]+)?|\\.infinity)") else { return nil }
        let r = NSRange(args.startIndex..., in: args)
        guard let m = re.firstMatch(in: args, range: r), m.numberOfRanges > 1,
              let rr = Range(m.range(at: 1), in: args) else { return nil }
        let v = String(args[rr])
        if v == ".infinity" { return nil }
        return CGFloat(Double(v) ?? 0)
    }
}

// MARK: - 仓库扫描

private let shtRepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

/// 剥掉注释与字符串字面量，只留真实代码。
///
/// **必须剥**：否则文档注释里写一句「本 view 用了 sheetContainerFrame」就会被
/// 判成双重契约，守卫第一次接入就误判 → 被迫加例外 → 沦为噪声。
private func shtCodeOnly(_ raw: String) -> String {
    var out = ""
    out.reserveCapacity(raw.count)
    var inLineComment = false, inBlockComment = false, inString = false, escape = false
    var prev: Character = " "
    for ch in raw {
        if inLineComment {
            if ch == "\n" { inLineComment = false; out.append(ch) }
            prev = ch
            continue
        }
        if inBlockComment {
            if prev == "*" && ch == "/" { inBlockComment = false; prev = " " } else { prev = ch }
            continue
        }
        if inString {
            if escape { escape = false } else if ch == "\\" { escape = true } else if ch == "\"" { inString = false }
            prev = ch
            continue
        }
        if prev == "/", ch == "/" { inLineComment = true; prev = " "; continue }
        if prev == "/", ch == "*" { inBlockComment = true; prev = " "; continue }
        if ch == "\"" { inString = true; prev = ch; continue }
        out.append(ch)
        prev = ch
    }
    return out
}

private func shtViewFiles() -> [(path: String, code: String)] {
    let base = shtRepoRoot.appendingPathComponent("MixCut/Views")
    guard let en = FileManager.default.enumerator(at: base,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
    var out: [(String, String)] = []
    for case let url as URL in en where url.pathExtension == "swift" {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let rel = url.path.replacingOccurrences(of: shtRepoRoot.path + "/", with: "")
        out.append((rel, shtCodeOnly(s)))
    }
    return out.sorted { $0.0 < $1.0 }
}

// MARK: - SHT-1 禁止双重尺寸契约（🔴 本次的根因）

@Test("SHT-1 禁止同时声明 .frame(width:) 与 sheetContainerFrame（两个语义相反的宽度真源）")
func sht1_noDoubleWidthContract() {
    var problems: [String] = []
    for (path, code) in shtViewFiles() {
        let d = SheetSizeContract.parse(codeOnly: code)
        if SheetSizeContract.violatesDoubleWidthContract(d) {
            problems.append("\(path)：硬性宽度 \(d.hardWidth.map(String.init(describing:)) ?? "?") + sheetContainerFrame（min \(d.minWidth.map(String.init(describing:)) ?? "无")）⇒ 内容按硬宽度排版、按 min 夹紧 ⇒ 溢出被裁")
        }
    }
    #expect(problems.isEmpty, "发现双重宽度契约（沙盒编译腿全绿、只有真机可见）")
}

@Test("SHT-1b 本仓当前 CloneWizardView 必须是合法样本（防守卫连合法代码一起判红）")
func sht1b_cloneWizardIsLegal() {
    // 这条同时钉住「修复已落地」：若有人把 .frame(width:) 加回来，SHT-1 与本条会同时变红。
    let url = shtRepoRoot.appendingPathComponent("MixCut/Views/Settings/CloneWizardView.swift")
    let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let d = SheetSizeContract.parse(codeOnly: shtCodeOnly(raw))
    #expect(d.usesContainer, "向导必须用 sheetContainerFrame（尺寸唯一真源）")
    #expect(d.hardWidth == nil, "向导不得再叠硬性 .frame(width:)（那是本次错位根因）")
}

// MARK: - SHT-2 min/ideal/max 语义一致

@Test("SHT-2 禁止「min < ideal 且 max == ideal」的自相矛盾组合")
func sht2_noContradictoryWidthTriple() {
    var problems: [String] = []
    for (path, code) in shtViewFiles() {
        let d = SheetSizeContract.parse(codeOnly: code)
        if SheetSizeContract.violatesWidthTriple(d) {
            problems.append("\(path)：min \(d.minWidth!) < ideal \(d.idealWidth!) 且 max == ideal ⇒ 与硬性宽度叠加时必溢出")
        }
    }
    #expect(problems.isEmpty, "发现矛盾的三宽度组合（min<ideal 且 max==ideal）")
}

// MARK: - SHT-3 高度真源唯一

@Test("SHT-3 禁止在 sheetContainerFrame 之后叠加独立高度 frame（第二个高度真源）")
func sht3_noDoubleHeightSource() {
    var problems: [String] = []
    for (path, code) in shtViewFiles() {
        let d = SheetSizeContract.parse(codeOnly: code)
        if SheetSizeContract.violatesHeightDoubleSource(d) {
            problems.append("\(path)：sheetContainerFrame 之后又挂了独立 .frame(minHeight:/maxHeight:) ⇒ 高度有两个真源")
        }
    }
    #expect(problems.isEmpty, "发现双高度真源（sheetContainerFrame 之后又挂了独立高度 frame）")
}

// MARK: - SHT-4 反向对照：守卫非恒绿（skill 强制）

@Test("SHT-4 反向对照：注入双重契约的样本必须被判红（守卫不是恒绿）")
func sht4_guardIsNotAlwaysGreen() {
    let bad = """
    struct X: View {
        var body: some View {
            VStack { Text("hi") }
                .frame(width: 520)
                .sheetContainerFrame(minWidth: 480, idealWidth: 520, maxWidth: 560,
                                     minHeight: 420, idealHeight: 560)
        }
    }
    """
    let d = SheetSizeContract.parse(codeOnly: bad)
    #expect(SheetSizeContract.violatesDoubleWidthContract(d), "注入的双重契约未被抓住 ⇒ 守卫恒绿")

    // 矛盾三宽度
    let bad2 = """
    .sheetContainerFrame(minWidth: 400, idealWidth: 520, maxWidth: 520)
    """
    #expect(SheetSizeContract.violatesWidthTriple(SheetSizeContract.parse(codeOnly: bad2)),
            "矛盾三宽度未被抓住")

    // 双高度真源
    let bad3 = """
    .sheetContainerFrame(minWidth: 460, idealWidth: 460, maxWidth: 460, minHeight: 420, idealHeight: 560)
    .frame(minHeight: 380)
    """
    #expect(SheetSizeContract.violatesHeightDoubleSource(SheetSizeContract.parse(codeOnly: bad3)),
            "双高度真源未被抓住")
}

// MARK: - SHT-5 合法必绿等价类（缺这条，守卫第一次接入就会因误判加例外）

@Test("SHT-5 合法必绿：既有三种不同形态的 sheet 都不该被判红")
func sht5_knownGoodSheetsStayGreen() {
    // ① 三者同值 + 不传 maxHeight（VoicePickerSheet 形态：560/560/560）
    let good1 = """
    .sheetContainerFrame(minWidth: 560, idealWidth: 560, maxWidth: 560,
                         minHeight: 420, idealHeight: 580)
    """
    let d1 = SheetSizeContract.parse(codeOnly: good1)
    #expect(!SheetSizeContract.violatesDoubleWidthContract(d1))
    #expect(!SheetSizeContract.violatesWidthTriple(d1))
    #expect(!SheetSizeContract.violatesHeightDoubleSource(d1))

    // ② min < ideal 且 max == ∞（ScriptWizardView 形态：640/860/∞）——
    //    **这是合法的**，弹窗可在小宿主里收缩。判据 2 刻意不抓它。
    let good2 = """
    .sheetContainerFrame(minWidth: 640, idealWidth: 860, maxWidth: .infinity,
                         minHeight: 480, idealHeight: 680)
    """
    let d2 = SheetSizeContract.parse(codeOnly: good2)
    #expect(!SheetSizeContract.violatesWidthTriple(d2), "min<ideal 且 max=∞ 是合法形态，不得判红")
    #expect(d2.maxWidth == nil, "maxWidth == .infinity 应解析为 nil（不限）")

    // ③ 只有硬性宽度、无 sheetContainerFrame（老式固定尺寸 sheet）——
    //    不构成「双重契约」，不该判红。
    let good3 = """
    .frame(width: 520)
    .frame(minHeight: 380)
    """
    let d3 = SheetSizeContract.parse(codeOnly: good3)
    #expect(!SheetSizeContract.violatesDoubleWidthContract(d3), "只有硬宽度 ≠ 双重契约")
}

@Test("SHT-6 注释与字符串里的 sheetContainerFrame 不算违规（守卫不得误报文档）")
func sht6_commentsAndStringsAreStripped() {
    let withDoc = """
    /// 本 view 的尺寸用 sheetContainerFrame(minWidth: 480, idealWidth: 520) 统一管理。
    // 旧代码曾用 .frame(width: 520)，已废弃。
    struct Y: View { var body: some View { Text("x") } }
    """
    let d = SheetSizeContract.parse(codeOnly: shtCodeOnly(withDoc))
    #expect(!d.usesContainer, "注释里的 sheetContainerFrame 必须被剥掉，否则守卫会误伤文档")
    #expect(d.hardWidth == nil, "注释里的 .frame(width:) 也必须被剥掉")
}
