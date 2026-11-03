import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// FT · 「秒 → 帧」唯一真源守卫（计划 ~/.qoder-cn/plans/mossy-sea-elk.md §6.1 T3/T4）
//
// ## 为什么要有这道门
//
// 本仓秒↔帧换算的权威是 `MixCutCore.FrameTime.frame(seconds:fps:)`
// （`Sources/MixCutCore/FrameTime.swift:16-19`，文件头自述「所有『秒 → 帧』一律 round
// 到最近帧，消除浮点取整歧义（永不差帧）」）。但实测它**只有 1 个消费者**，
// 同一行算术在仓库里被手抄了 **10 处**（逐条登记在下面 `ftLedger`，本文件不重复列行号
// 以免行号腐烂）。
//
// 最刺眼的一条证据：`MixCut/ViewModels/SegmentLibraryViewModel.swift` 里手抄乘 fps 的
// 那两行，**同一个函数的下一行就在用 `FrameTime.seconds`** ⇒ 一处两种口径已在同一屏并存的活样本。
//
// 今天这 10 处**恰好都写 `.rounded()`**，方向一致 ⇒ 没有 bug。本守卫不修这一次，
// 防的是它再抄开、以及抄开之后方向不一致。这个理由不是理论担心：
// 2026-10-19「档位→输出宽高」一条规则抄了 7 份 ⇒ 批量导出的 41 条成片是 480×854
// 被千川拒收，且**没有任何一处代码知道自己算出了 480**（见 `ExportSizeSingleSourceGuardTests` 文件头）。
// 时长换算一旦方向分叉，症状是"音画错位一帧"，比尺寸错更难归因。
//
// ## 判据为什么只扫「乘 fps」，不扫「除 fps」
//
// 秒→帧有**取整方向**可选（floor / ceil / round），抄开就可能分叉，这才是风险面。
// 帧→秒是精确除法，没有方向可选；实测 `Sources/` 与 `MixCut/` 有 51 处 `/ fps`，
// 全数登记成白名单只会让名册失去意义。⇒ 本守卫只管乘法方向。
//
// ## 名册为什么按「文件 + 源码行文本」键控，不按行号
//
// 行号会腐烂（本仓实测：台账里的 `函数名:行号` 期期对不上）。按行文本键控后，
// FT-01 / FT-02 做成**集合相等**：
//   · FT-01 现网有而名册没有 ⇒ 红（新抄开一处）
//   · FT-02 名册有而现网没有 ⇒ 红（收敛了一笔却没摘账 ⇒ 名册领先于存储）
// 于是"把某处改成走 FrameTime"这一笔**必须同时删掉名册里那一行**才能变绿 ⇒ 记账强制，
// 不许默默减。代价：给那 10 处加代码时顺手改行内格式也会打红 —— 这是有意的，
// 名册条目要求逐字对得上，逼一次确认。
//
// ## ⚠ 名册里两处**不可无损替换**成 FrameTime.frame（改之前先读条目 note）
//
//   · `BoundaryAlignmentEngine` 那处是 round-trip 回**秒**（按帧栅格量化），
//     `FrameTime` 没有这颗门面；硬套 `seconds(frame: frame(seconds:))` 会改变 `fps <= 0` 的行为。
//   · `MCPSegmentToolHandlers` 那处在**负数输入**下语义不同：现写法得负帧号，
//     而 `FrameTime.frame` 的 `guard seconds > 0` 会返回 0。
//
// ## 已知漏口（写在这里，不假装看不见）
//
// ① 只认 `* fps` / `fps *` 两种字面形状。把 fps 先赋给另一个局部变量再乘
//    （`let r = fps; x * r`）扫不到 —— 那要靠下面 T4 的行为对表兜，不靠本文件。
// ② 取样面只 `Sources/` 与 `MixCut/`，且靠 `.skipsHiddenFiles` 天然跳过 `.scratch/`
//    （那里有整仓副本，扫它会把旧常量当成现网违规 —— 与 ES 同规矩）。
// ③ 剥注释与字符串后匹配 ⇒ 注释里写「乘 fps」不算违规（本文件头就不算）。
// ============================================================================

// MARK: - 被测判据（纯函数，与文件 IO 解耦）

enum FrameTimeSourceScan {

    /// 一条命中。`file` 是仓库根相对路径，`code` 是剥注释后的行文本（逐字比对）。
    struct Site: Hashable {
        let file: String
        let code: String
    }

    /// 「乘 fps」的形状：`* fps` 或 `fps *`（含无空格写法）。
    static let pattern = #"(\*\s*\bfps\b|\bfps\b\s*\*)"#

    /// 在**已剥注释与字符串**的源码上找出所有「乘 fps」的行。
    /// `TagRowHostScan.codeOnly` 是等长置换、换行保留 ⇒ 行内容与原文件对得上。
    static func hits(file: String, src: String) -> [Site] {
        let code = String(TagRowHostScan.codeOnly(src))
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        var out: [Site] = []
        for line in code.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            if re.firstMatch(in: trimmed, options: [], range: range) != nil {
                out.append(Site(file: file, code: trimmed))
            }
        }
        return out
    }
}

// MARK: - 存量名册（收敛一笔须同轮删掉对应条目）

/// 已登记存量抄本。`note` 标的是**收敛时的语义陷阱**，不是"合法理由"。
private let ftLedger: [FrameTimeSourceScan.Site] = [
    .init(file: "Sources/MixCutCore/SegmentSplitRule.swift",
          code: "max(1, Int((minimumSliceSeconds * fps).rounded()))"),
    .init(file: "Sources/MixCutCore/SegmentCloneWindow.swift",
          code: "let span = Int((maxReferenceSeconds * fps).rounded())"),
    .init(file: "Sources/MixCutCore/BoundaryAlignmentEngine.swift",
          code: "picked = picked.map { (($0 * fps).rounded() / fps) }"),
    .init(file: "MixCut/ViewModels/DubbingViewModel.swift",
          code: "let derivedTotal = Int((video.duration * fps).rounded())"),
    .init(file: "MixCut/ViewModels/SegmentLibraryViewModel.swift",
          code: "let toFrame = min(newStart + Int((2 * fps).rounded()), segment.endFrame)"),
    .init(file: "MixCut/ViewModels/SegmentLibraryViewModel.swift",
          code: "let toFrame = min(clamped + Int((2 * fps).rounded()), segment.endFrame)"),
    .init(file: "MixCut/Services/VideoProcessing/FFmpegRunner.swift",
          code: "let startFrame = Int((start * fps).rounded())"),
    .init(file: "MixCut/Services/VideoProcessing/FFmpegRunner.swift",
          code: "let endFrame = Int((end * fps).rounded())"),
    .init(file: "MixCut/Services/MCP/MCPSegmentToolHandlers.swift",
          code: "cut = Int(((args.cut_seconds ?? 0) * fps).rounded())"),
    .init(file: "MixCut/Services/Import/SegmentCommitter.swift",
          code: "let endFrame = max(1, Int((video.duration * fps).rounded()))"),
]

/// 权威本体所在文件 —— 它自己那一处乘法是定义，不是违规。
private let ftAuthorityFile = "Sources/MixCutCore/FrameTime.swift"

// MARK: - 仓库根与遍历

private let ftRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func ftSwiftFiles(under dir: String) -> [String] {
    let base = ftRepoRoot.appendingPathComponent(dir)
    guard FileManager.default.fileExists(atPath: base.path),
          let en = FileManager.default.enumerator(at: base,
                                                  includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) else { return [] }
    let prefix = base.path
    return en.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .map { dir + String($0.path.dropFirst(prefix.count)) }
        .sorted()
}

/// 扫一棵树，返回全部「乘 fps」命中。**一颗文件都读不到 ⇒ 返回 nil**（判据失效，不判通过）。
private func ftScan(root: URL) -> [FrameTimeSourceScan.Site]? {
    var all: [FrameTimeSourceScan.Site] = []
    var readAny = false
    for dir in ["Sources", "MixCut"] {
        for rel in ftSwiftFiles(under: dir) {
            guard let src = try? String(contentsOf: root.appendingPathComponent(rel),
                                        encoding: .utf8) else { continue }
            readAny = true
            all.append(contentsOf: FrameTimeSourceScan.hits(file: rel, src: src))
        }
    }
    return readAny ? all : nil
}

private func ftLiveHits() -> [FrameTimeSourceScan.Site]? { ftScan(root: ftRepoRoot) }

private func ftDescribe(_ sites: Set<FrameTimeSourceScan.Site>) -> String {
    sites.map { "  \($0.file)：\($0.code)" }.sorted().joined(separator: "\n")
}

// MARK: - FT-01 … FT-05

@Suite("FT · 秒→帧 唯一真源（防抄本分裂）")
struct FrameTimeSingleSourceTests {

    /// 现网命中去掉权威本体，剩下就是"抄本全集"。取不出数 ⇒ nil，调用方必须打成红，
    /// **不许 `return` 后读成通过**（那正是"遍历空集恒真"的形态）。
    private static func liveCopies() -> Set<FrameTimeSourceScan.Site>? {
        guard let hits = ftLiveHits() else { return nil }
        return Set(hits.filter { $0.file != ftAuthorityFile })
    }

    @Test("FT-01 除 FrameTime 本体与名册外，不得出现第二处「乘 fps」的秒→帧换算")
    func noNewCopySite() throws {
        guard let copies = Self.liveCopies() else {
            Issue.record("取样面取不出数 ⇒ 判据无法成立，不算通过")
            return
        }
        let offenders = copies.subtracting(ftLedger)
        let detail = ftDescribe(offenders)
        #expect(offenders.isEmpty,
                "新抄开 \(offenders.count) 处秒→帧换算，请改走 FrameTime.frame(seconds:fps:)：\n\(detail)")
    }

    @Test("FT-02 名册每条必须在现网找得到（防名册领先于存储）")
    func ledgerIsNotAheadOfStorage() throws {
        guard let copies = Self.liveCopies() else {
            Issue.record("取样面取不出数 ⇒ 判据无法成立，不算通过")
            return
        }
        let stale = Set(ftLedger).subtracting(copies)
        let detail = ftDescribe(stale)
        #expect(stale.isEmpty,
                "名册里 \(stale.count) 条已在现网找不到（多半是已收敛成 FrameTime，或改了行内格式）⇒ 必须同轮从 ftLedger 删掉：\n\(detail)")
    }

    @Test("FT-03 FrameTime 本体确有「乘 fps」的取整实现（防权威被掏空后本守卫恒绿）")
    func authorityActuallyOwnsTheMath() throws {
        let url = ftRepoRoot.appendingPathComponent(ftAuthorityFile)
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("读不到 \(ftAuthorityFile) ⇒ 判据无法成立")
            return
        }
        let hits = FrameTimeSourceScan.hits(file: ftAuthorityFile, src: src)
        #expect(!hits.isEmpty,
                "\(ftAuthorityFile) 里取不到任何「乘 fps」⇒ 权威口径已不在原处，本守卫失去对照物")
    }

    @Test("FT-04 存量抄本数不得多于名册数（收敛进度可观测）")
    func copyCountDoesNotGrow() throws {
        guard let copies = Self.liveCopies() else {
            Issue.record("取样面取不出数 ⇒ 判据无法成立，不算通过")
            return
        }
        #expect(copies.count <= ftLedger.count,
                "存量抄本 \(copies.count) 处 > 名册 \(ftLedger.count) 条 ⇒ 有新增未登记")
    }

    @Test("FT-05 反向对照：合成含新抄本的源码必须被抓到（防 FT-01 恒绿）")
    func guardIsNotAlwaysGreen() throws {
        // ① 两种字面形状都要抓到
        let fake = """
        func derive(s: Double, fps: Double) -> Int {
            // 注释里写 s * fps 不该被抓
            return Int((s * fps).rounded())
        }
        func alsoBad(s: Double, fps: Double) -> Int {
            return Int((fps * s).rounded())
        }
        func fine(s: Double, fps: Double) -> Int {
            return FrameTime.frame(seconds: s, fps: fps)
        }
        """
        let hits = FrameTimeSourceScan.hits(file: "Fake.swift", src: fake)
        #expect(hits.count == 2,
                "反向对照失手：应抓到 2 处（`* fps` 与 `fps *`），实抓 \(hits.count) ⇒ 匹配口径已失效")

        // ② 注释与字符串里的「乘 fps」不得被抓（codeOnly 剥注释的效力）
        let commentOnly = """
        /// 这里提到 s * fps 只是说明
        let note = "s * fps"
        """
        #expect(FrameTimeSourceScan.hits(file: "Fake.swift", src: commentOnly).isEmpty,
                "注释/字符串里的 `* fps` 不该算违规 ⇒ 一旦被抓说明 codeOnly 没生效，名册会假红")

        // ③ 邻近标识符不得被误伤（\b 的效力）
        let neighbours = """
        let fpsInt = Int(fps.rounded())
        let scale = seconds * fpsScale
        """
        #expect(FrameTimeSourceScan.hits(file: "Fake.swift", src: neighbours).isEmpty,
                "`fpsInt` / `fpsScale` 这类邻近标识符不该算命中 ⇒ \\b 边界失效")
    }
}

// MARK: - T4 · 取整方向基准（独立不变量，不拿实现自身当期望值）

@Suite("FT · 秒→帧 取整方向基准（T4）")
struct FrameTimeRoundingDirectionTests {

    /// 含二进制不精确值（8.4/8.43 都不是可精确表示的 Double）与非整帧率（23.976/29.97，
    /// 本仓导出链会出现），以及 0 / 负数 / 极大。
    private static let fpsValues: [Double] = [1, 25, 30, 60, 23.976, 29.97]
    private static let secondValues: [Double] = [0.001, 0.02, 0.5, 1, 1.38, 1.41, 1.42,
                                                 2, 8.4, 8.43, 12.004, 3600, 1e6]

    /// 独立判据：选出的帧与目标秒的**真实帧位**距离不得超过半帧。
    ///
    /// 这条不重复实现的算式（实现是 `Int((seconds * fps).rounded())`，这里是帧域距离），
    /// 所以它能证伪；若写成 `Int((s*fps).rounded())` 当期望值就是拿实现证实现，恒真。
    ///
    /// ⚠️ 这里**不能**用「比所有邻帧都近」的严格距离比较 —— 实测本仓第一个反例：
    ///   `seconds = 1.38, fps = 25` 的真实帧位是 **34.5 整**（平局），实现按 half-away-from-zero
    ///   取 35；但在浮点域里 `|35/25 − 1.38| = 0.020000000000000018`，
    ///   而 `|34/25 − 1.38| = 0.019999999999999796` —— **34 反而更近**。
    ///   即浮点表示把实数平局压歪了，严格"最近"比较在平局点必然误报（同 WebKit bug 52697
    ///   那类"直接 seek 到帧边界在浮点下永远有问题"）。⇒ 平局归谁由 T4-2 的实算值钉，
    ///   本条只管"没跳飞半帧以上"这个方向性下界。
    @Test("T4-1 选中帧与真实帧位距离不超过半帧（独立不变量，逐格扫）")
    func staysWithinHalfFrame() {
        for fps in Self.fpsValues {
            for s in Self.secondValues {
                let got = FrameTime.frame(seconds: s, fps: fps)
                let want = s * fps
                let off = abs(Double(got) - want)
                #expect(off <= 0.5 + 1e-9,
                        "fps=\(fps) seconds=\(s)：真实帧位 \(want)，却选了 \(got)（偏 \(off) > 半帧）")
            }
        }
    }

    /// 期望值全部**实算**得来（Python 侧按 Swift 的 half-away-from-zero 口径核过）。
    /// 三格分别钉住三种退化方向：
    ///   · 8.43×25 = 210.75 → 211（floor 会得 210）
    ///   · 1.41×25 = 35.25  → 35 （ceil  会得 36）
    ///   · 0.02×25 = 0.5    → 1  （平局取远离零；floor 会得 0）
    @Test("T4-2 取整方向既不是 floor 也不是 ceil，平局远离零（实算基准值）")
    func directionIsNeitherFloorNorCeil() {
        #expect(FrameTime.frame(seconds: 8.43, fps: 25) == 211,
                "8.43×25 = 210.75，round 应得 211；得 210 说明被改成了向下取整")
        #expect(FrameTime.frame(seconds: 1.41, fps: 25) == 35,
                "1.41×25 = 35.25，round 应得 35；得 36 说明被改成了向上取整")
        #expect(FrameTime.frame(seconds: 0.02, fps: 25) == 1,
                "0.02×25 = 0.5，平局应远离零得 1；得 0 说明平局方向被改过")
    }

    @Test("T4-3 非正输入一律夹到 0（不产负帧号、不崩）")
    func nonPositiveInputsClampToZero() {
        #expect(FrameTime.frame(seconds: 0, fps: 30) == 0)
        #expect(FrameTime.frame(seconds: -5, fps: 30) == 0)
        #expect(FrameTime.frame(seconds: 5, fps: 0) == 0)
        #expect(FrameTime.frame(seconds: 5, fps: -1) == 0)
        #expect(FrameTime.frame(seconds: -5, fps: -1) == 0)
    }

    @Test("T4-4 帧↔秒往返：已落在栅格上的帧无损回来")
    func roundTripIsLosslessOnGrid() {
        for fps in Self.fpsValues {
            for frame in [0, 1, 7, 210, 4321] {
                let secs = FrameTime.seconds(frame: frame, fps: fps)
                let back = FrameTime.frame(seconds: secs, fps: fps)
                #expect(back == frame, "fps=\(fps) frame=\(frame) 往返后变成 \(back)")
            }
        }
    }
}
