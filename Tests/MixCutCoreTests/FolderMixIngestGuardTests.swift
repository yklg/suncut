import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 文件夹混剪的结构判据族，钉在既有代码上。
// 计划：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md
//       （R12 / R14 / R17 / R18；第十二节记着本文件自身的审查与 G-1…G-6）
//
// 为什么钉既有代码而不是等新代码：这些缺陷**今天就存在**，而新通路一旦接上正好踩中。
//   T-15  首跑把 clearsExistingSegments 写死 false ⇒ 已有整片段的新素材会混存（R14）
//   T-16  批次来源经实例可变状态流入持久字段 ⇒ 第三个调用方会静默写"搬运"（R12）
//   T-18  hash 失败退化成 UUID 目录名 ⇒ 同一文件绕过去重、重复入库（R17）
//   T-19  ④ 的承重前提：`asrSentencesData` 全仓只有一个写入点且不写 nil
//         ——「母体链必写非 nil」正是"用形状区分 C 与母体"能成立的全部依据（R18）
//   T-21  `ProjectVideo.associate` 的幂等命中被记成 error ⇒ 混剪让它变成高频路径后
//         日志刷一片红，而红日志会被当成故障证据（风险 9；2026-10-03 那份台账已被误导过一次）
//
// 〔2026-10-20 Step 2 落地：T-15/T-16/T-18 三条**已摘标转正**〕
// 它们原本走 withKnownIssue 的严格 xfail（与 TombstoneReadGuardTests G08b 同口径）——
// "修好之后 withKnownIssue 会因不再有问题而自己变红 ⇒ 逼一次摘标"。Step 2 把三处根因都改了，
// 那一次摘标就是这里。摘标后它们是**永久正向判据**：任何回退（常量写回 false / source 改回
// 读实例状态 / 校验和算不出再退成 UUID 目录名）都会当场红，而不是等下一轮评审才被发现。
// T-19/T-21 不是 xfail —— 它们今天就该绿，且要**一直**绿。
//
// 每条 detector 配三对对照，且对照今天就要绿：
//   阳性：喂"更坏形态"合成源码 ⇒ 必须检出（防判据没牙）
//   阴性：喂"已修形态"合成源码 ⇒ 必须不报（防永远摘不掉的红钉）
//   绕法：拆行 / 包注释 ⇒ 仍要检出（防按行匹配被格式绕过）
// 另有「尾部未被吞」一条，专防注释剥离器失步导致后半文件被静默跳过。
//
// ── 已知绕法（结构判据的固有上限，别把它当封死）────────────────────────
//   ① 抽成命名常量：`let shouldClear = false` + `clearsExistingSegments: shouldClear` → 漏检
//   ② 抽成局部变量：`let fb = UUID().uuidString` + `contentHash: hash ?? fb`      → 漏检
//   ③ 换函数名：新增一个同样兜底 contentHash 的 helper                             → 漏检
//   ④ 跨文件：本族只扫登记在册的文件（见 T-20 名册腿），未登记文件里的同类站点看不见
//   ⑤ 拆接收者：`FolderMixContentKeyReader` 换行再 `.readings(` ⇒ T-23 的计数看不见（T-28 同形）
//      ⇒ 这颗的兜底不是再叠一层 grep，而是 Core 的 FMX-14b：开关关掉 ⇒ 探针清单恒空 ⇒ 无从可算
//   ⇒ 真正的兜底是**行为判据**（Step 2 的 T-15b/T-18b 夹具）。本族的价值是
//     "把已知的三类形态在改动当天就钉住"，不是"证明全仓没有第四类"。
// ============================================================================

private let folderMixRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private let folderMixVMTarget = "MixCut/ViewModels/ImportViewModel.swift"
private let folderMixServiceTarget = "MixCut/Services/Import/ClipIngestService.swift"
private let folderMixModelTarget = "MixCut/Models/Video.swift"
private let folderMixPvTarget = "MixCut/Models/ProjectVideo.swift"

/// 入库真身今天住在**两颗文件**里：适配层在 `ImportViewModel`，六步真身在 `ClipIngestService`
/// （计划 D32，笔 1b 下沉）。扫描面只登一颗 = 门对搬家后的真身完全失明 ——
/// 本仓在 `pendingBatchSource` 上栽过同形：符号没了、门还在、读数恒绿。
private let folderMixIngestTargets = [folderMixVMTarget, folderMixServiceTarget]

/// 对"入库这一族"的所有目标文件各扫一遍再并起来。
/// 行号按各文件独立计数，snippet 前缀带文件名 ⇒ 报错指得准，不会因为拼接而指错位。
private func folderMixIngestHits(_ pick: (String) -> [FolderMixHit]) -> [FolderMixHit] {
    folderMixIngestTargets.flatMap { file in
        pick(folderMixLoad(file)).map { FolderMixHit(line: $0.line, snippet: "\(file):" + $0.snippet) }
    }
}

/// 已登记在册的扫描面。新增调用点若落在这里之外，T-20 会红（名册对账，照 G12 先例）。
/// 注意第一条是**定义处**本身 —— `copyVideoToGlobal(` 这个串在 FileHelper 里以 func 声明的形态出现，
/// 名册按"含该串的文件"算，定义处必须在册，否则 T-20 会假红。
/// ⚠ 这里**只登文件、不登行号**：行号会在任何一次上游改动后腐烂（本计划已经为此返工过三次，
///   见 R1/R20），而 T-20 的判据是"哪些文件有该串"，与行号无关。
private let folderMixRosteredCallers = [
    "MixCut/Utilities/FileHelper.swift",              // 定义处
    "MixCut/ViewModels/ImportViewModel.swift",        // 自建分镜通路一处调用
    "MixCut/Services/Import/ClipIngestService.swift", // 笔 1b 下沉后：母体入库 + 混剪入库各一处
]

private func folderMixLoad(_ relative: String) -> String {
    let url = folderMixRepoRoot.appendingPathComponent(relative)
    guard let s = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("读不出 \(relative) ⇒ 本文件全部结构判据不可信")
        return ""
    }
    return s
}

struct FolderMixHit: Equatable {
    let line: Int          // 1-based 源行号；映射不出来时给 0
    let snippet: String
}

enum FolderMixIngestScan {

    struct Scanned {
        let text: String
        let lineOf: [Int]   // text 的每个字符来自哪一源行
    }

    /// 逐行去注释 + 行内折叠空白，并保留"字符 → 源行号"映射（G-5：报错要能指位）。
    /// 逐行而非逐字符：挡住注释里的示例代码与"把一条语句拆成多行"两类绕过。
    static func scan(_ src: String) -> Scanned {
        var text = ""
        var lineOf: [Int] = []
        var blockDepth = 0
        var inMultiline = false

        for (offset, rawLine) in src.components(separatedBy: "\n").enumerated() {
            let lineNo = offset + 1
            var line = rawLine

            if inMultiline {
                if line.contains("\"\"\"") { inMultiline = false }
                continue                                     // 多行字符串内部：整行不参与扫描
            }
            if blockDepth == 0, let cut = lineStartIndexOfLineComment(line) {
                line = String(line[..<cut])                   // ① 行注释（引号配对才算）
            }
            blockDepth = consumeBlockComment(&line, startingAt: blockDepth)   // ② 块注释，可跨行
            if line.contains("\"\"\"") { inMultiline = true }

            let norm = collapseInline(line)
            if !norm.isEmpty {
                text += norm + " "
                lineOf.append(contentsOf: Array(repeating: lineNo, count: norm.count + 1))
            }
        }
        return Scanned(text: text, lineOf: lineOf)
    }

    private static func consumeBlockComment(_ line: inout String, startingAt depth: Int) -> Int {
        var out = ""
        var level = depth
        var i = line.startIndex
        while i < line.endIndex {
            let rest = line[i...]
            if level > 0 {
                if rest.hasPrefix("*/") { level -= 1; i = line.index(i, offsetBy: 2) }
                else { i = line.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { level += 1; i = line.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") { break }
            out.append(rest.first!)
            i = line.index(after: i)
        }
        line = out
        return level
    }

    private static func lineStartIndexOfLineComment(_ line: String) -> String.Index? {
        var quotes = 0
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" && !isEscaped(line, at: i) { quotes += 1 }
            if ch == "/", quotes % 2 == 0, line.index(after: i) < line.endIndex,
               line[line.index(after: i)] == "/" {
                return i
            }
            i = line.index(after: i)
        }
        return nil
    }

    private static func isEscaped(_ s: String, at idx: String.Index) -> Bool {
        var slashes = 0
        var i = idx
        while i > s.startIndex {
            i = s.index(before: i)
            if s[i] == "\\" { slashes += 1 } else { break }
        }
        return slashes % 2 == 1
    }

    private static func collapseInline(_ s: String) -> String {
        var res = ""
        var lastSpace = false
        for ch in s {
            if ch == " " || ch == "\t" || ch == "\r" {
                if !lastSpace { res.append(" ") }
                lastSpace = true
            } else {
                res.append(ch); lastSpace = false
            }
        }
        return res.trimmingCharacters(in: .whitespaces)
    }

    private static func find(_ sc: Scanned, _ pattern: String) -> [FolderMixHit] {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            Issue.record("正则编译失败：\(pattern)")
            return []
        }
        let ns = sc.text as NSString
        return re.matches(in: sc.text, range: NSRange(location: 0, length: ns.length)).map { m in
            let start = m.range.location
            let line = start < sc.lineOf.count ? sc.lineOf[start] : 0
            return FolderMixHit(line: line,
                                snippet: ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 参数窗口 `(?:[^()]|\([^()]*\))*?`：允许一层嵌套括号，但**不许跨过本调用的右括号**。
    /// 上一版用 `[^;]*?` 收尾，前提是"语句以分号分隔"——Swift 不用分号，于是它越过 `)`
    /// 吃到下一条语句，把修好后的代码也报成命中。是「对照·阴性」实测抓出来的假阳性。
    /// 直接写进正则、不做字符串插值：`#"…"#` 里 `\#(` 会吃掉字面量 `\(`，两次都栽在这上面。

    /// T-15（R14）
    static func hardcodedNoClear(_ src: String) -> [FolderMixHit] {
        find(scan(src),
             #"rebuildSegments\((?:[^()]|\([^()]*\))*?clearsExistingSegments\s*:\s*false\b"#)
    }

    /// T-16（R12）。G-1：`[:=]` —— 只盯 `=` 会漏掉"把隐式状态当参数转发"，
    /// 而 Step 2 正是要新增第二个调用方。实测收紧后真文件命中数仍是 1（当时的那一处赋值），
    /// `pendingBatchSource` 的声明与反向赋值都不误报。Step 2 摘标后该属性**已不存在** ⇒ 命中 0。
    static func instanceStateIntoModel(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"[:=]\s*pendingBatchSource\b"#)
    }

    /// T-18（R17）
    static func uuidHashFallback(_ src: String) -> [FolderMixHit] {
        find(scan(src),
             #"copyVideoToGlobal\((?:[^()]|\([^()]*\))*?contentHash\s*:\s*(?:[^()]|\([^()]*\))*?UUID\s*\(\s*\)\s*\.\s*uuidString"#)
    }

    /// T-19（R18）：`asrSentencesData` 的写入点。④ 的全部依据是"母体链必写非 nil"，
    /// 所以要求：写入点恰好 1 处，且右值不是 nil 字面量。
    static func asrDataWrites(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"asrSentencesData\s*=[^;]"#)
    }
    static func asrDataWrittenToNil(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"asrSentencesData\s*=\s*nil\b"#)
    }

    /// T-20：全仓 `copyVideoToGlobal(` 的调用文件名册。
    static func filesCalling(_ files: [(String, String)], _ token: String) -> [String] {
        files.filter { scan($0.1).text.contains(token) }.map { $0.0 }.sorted()
    }

    /// T-21（风险 9）：`ProjectVideo.associate` 的幂等命中分支记成了什么级别。
    /// 只认"这一句日志"，不认整个函数 —— 同文件里别的 error 不该被这条判据管。
    static func associateIdempotentAsError(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"MixLog\s*\.\s*error\s*\(\s*"[^"]*已关联视频"#)
    }
    static func associateIdempotentAsInfo(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"MixLog\s*\.\s*info\s*\(\s*"[^"]*已关联视频"#)
    }

    // ── 与库对接的键（计划 2026-10-22 笔 J2 · T-30 三条腿 + T-31）──
    //
    // 这一族钉的不是"某个变量叫什么"，而是**用法与写入点计数**：初版计划把门写成"某些标识符
    // 不得出现"，换个名字就绕过、还会误伤合法用法（评审 W1 否掉）。所以这里全部按 API 用法扫。

    /// 腿 A：把库内路径当键的两类写法 —— 相等比较、字典下标。
    static func crossDomainKeyUses(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"[A-Za-z_][\w.]*\.localPath\s*=="#)
            + find(scan(src), #"==\s*[A-Za-z_][\w.]*\.localPath"#)
            + find(scan(src), #"\[\s*[A-Za-z_][\w.]*\.localPath\s*\]"#)
    }

    /// 腿 B：键→段 id 那张表的三类写入点分开数（下标写入 / 整表赋值 / 清空）。
    static func segmentSubscriptWrites(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"segmentIDByKey\s*\[[^\]]{1,80}\]\s*=[^=]"#)
    }
    static func segmentWholeAssignments(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"segmentIDByKey\s*=[^=]"#)
    }
    static func segmentJoinSourced(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"segmentIDByKey\s*=\s*join\.segmentIDByKey"#)
    }
    static func segmentCleared(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"segmentIDByKey\s*=\s*\[:"#)
    }

    /// T-31：入库两支各记一次对应关系的写入点。
    static func ingestedRecordSites(_ src: String) -> [FolderMixHit] {
        find(scan(src), #"report\.ingested\.append\("#)
    }
}

struct FolderMixIngestGuardTests {

    // ── 扫描面非空 ──
    @Test("扫描面非空：入库族的两颗真身文件都在，且锚点确实出现在真实代码里")
    func scanSurfaceIsNotEmpty() {
        let sc = FolderMixIngestScan.scan(folderMixLoad(folderMixVMTarget))
        #expect(!sc.text.isEmpty, "适配层扫描面为空 ⇒ 下面所有判据都不成立")
        let sv = FolderMixIngestScan.scan(folderMixLoad(folderMixServiceTarget))
        #expect(!sv.text.isEmpty, "ClipIngestService 扫描面为空 ⇒ 门对搬家后的真身失明")
        // 锚点按"并起来的那一面"查：真身搬走后适配层里不再有的串，仍然要在服务里找到。
        let union = sc.text + " " + sv.text
        #expect(union.contains("rebuildSegments("), "折叠后的代码里找不到 rebuildSegments 调用")
        #expect(union.contains("copyVideoToGlobal("), "折叠后的代码里找不到 copyVideoToGlobal")
        #expect(union.contains("importOrLink"), "折叠后的代码里找不到 importOrLink（适配层或真身任一即可）")
        #expect(union.contains("defaultSourceRaw"), "折叠后的代码里找不到 defaultSourceRaw 的写入")
        // 〔Step 2 摘标时改过锚点〕原来这里第三条是 `pendingBatchSource` —— 那条隐式通道
        // 已被整体删除，符号本身不存在了，锚点必须换成"文件里现在真的有的东西"，
        // 否则"扫描面非空"会被一个已消解的符号撑成假绿。
        // 〔笔 1b 改登〕`importOrLinkVideo(` 改成 `importOrLink`：真身现在叫
        // `ClipIngestService.importOrLink`，而适配层仍叫 `importOrLinkVideo`；
        // 用前缀串同时覆盖两者，避免"改个名字就假红"。
        let pv = FolderMixIngestScan.scan(folderMixLoad(folderMixPvTarget))
        #expect(pv.text.contains("已关联视频"), "ProjectVideo 里找不到幂等命中的日志句子 ⇒ T-21 无从可扫")
        let model = FolderMixIngestScan.scan(folderMixLoad(folderMixModelTarget))
        #expect(model.text.contains("asrSentencesData"), "Video.swift 里找不到 asrSentencesData ⇒ T-19 无从可扫")
    }

    // ── G-4：注释剥离器失步时，后半文件会被静默跳过 ⇒ 判据局部失明 ──
    @Test("尾部未被吞：文件末尾的标识符必须仍出现在剥离结果里")
    func tailIsNotSwallowed() {
        let src = folderMixLoad(folderMixVMTarget)
        let lines = src.components(separatedBy: "\n")
        let tail = lines.suffix(40).joined(separator: "\n")
        // 取尾部最长的一个代码标识符作为探针（≥8 字符，避免抓到括号/运算符）
        let tokens = tail.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 8 }
        let probe = tokens.max(by: { $0.count < $1.count }) ?? ""
        #expect(!probe.isEmpty, "尾部取不到探针标识符 ⇒ 本条判据形同虚设")
        #expect(FolderMixIngestScan.scan(src).text.contains(probe),
                "尾部探针「\(probe)」在剥离结果里找不到 ⇒ 剥离器失步，后半文件被静默跳过")
    }

    // ── 三条已摘标转正的红钉（Step 2 落地那一轮摘的，理由见文件头）──
    @Test("T-15 首跑不得把 clearsExistingSegments 写死 false —— 计划 R14，Step 2 已修")
    func firstRunMustNotHardcodeNoClear() {
        let hits = folderMixIngestHits { FolderMixIngestScan.hardcodedNoClear($0) }
        // 这个布尔入参背后有一条前置：「此刻没有旧分镜可退」。写死 false 就是不再判它。
        #expect(hits.isEmpty,
                "又有 \(hits.count) 处把 clearsExistingSegments 写死字面量 false：\(hits.map { ":\($0.line)" })。判据真源在 Core 的 WholeClipShape")
    }

    @Test("T-16 批次来源不得经实例可变状态流入持久字段或参数转发 —— 计划 R12/D20，Step 2 已修")
    func batchSourceMustNotFlowThroughInstanceState() {
        let hits = folderMixIngestHits { FolderMixIngestScan.instanceStateIntoModel($0) }
        #expect(hits.isEmpty,
                "仍有 \(hits.count) 处经 pendingBatchSource 流转：\(hits.map { ":\($0.line)" })。importOrLinkVideo 的 source 是必填入参（D20）")
    }

    @Test("T-18 hash 失败不得退化成 UUID 目录名 —— 计划 R17，Step 2 已修")
    func hashFailureMustNotFallBackToUUIDDir() {
        let hits = folderMixIngestHits { FolderMixIngestScan.uuidHashFallback($0) }
        // 那条退化分支会**同时绕过**按 hash 的去重 ⇒ 同一文件反复成行，把 D3 击穿。
        #expect(hits.isEmpty,
                "仍有 \(hits.count) 处用 UUID() 兜底 contentHash：\(hits.map { ":\($0.line)" })。正解是拒绝该文件并逐名上报")
    }

    // ── detector 自身的族计数能力 ──
    @Test("T-18b 族计数：合成两处 UUID 兜底必须全被抓到（真实代码那两处已归零）")
    func detectorCountsWholeFamily() {
        // 真实代码里的同族兜底原本有两处（母体入库 + 自建分镜入库），Step 2 一起改了。
        // 这条腿不再钉"至少两处"，它钉 detector **不许退化成只报第一处** ——
        // 否则 T-18 会变成"修点不修族"的假绿：漏改的那一处永远看不见。
        let twoSites = """
        func a() {
            let d = try FileHelper.copyVideoToGlobal(from: url, contentHash: hash ?? UUID().uuidString)
        }
        func b() {
            let d = try FileHelper.copyVideoToGlobal(from: url2, contentHash: UUID().uuidString)
        }
        """
        let hits = FolderMixIngestScan.uuidHashFallback(twoSites)
        #expect(hits.count == 2, "族里两处兜底只检出 \(hits.count) 处 ⇒ detector 失去了族计数能力")
        #expect(folderMixIngestHits { FolderMixIngestScan.uuidHashFallback($0) }.isEmpty,
                "真实代码仍有残留 ⇒ T-18 与这条读数不一致")
    }

    // ── T-19：④ 的承重前提（今天必须绿，且要一直绿）──
    @Test("T-19 ④ 的依据：asrSentencesData 只有一个写入点，且从不被写成 nil")
    func asrSentencesDataNeverNilmed() {
        let src = folderMixLoad(folderMixModelTarget)
        let writes = FolderMixIngestScan.asrDataWrites(src)
        let nils = FolderMixIngestScan.asrDataWrittenToNil(src)
        #expect(writes.count == 1,
                "写入点应恰好 1 处，实得 \(writes.count) 处：\(writes.map { ":\($0.line) \($0.snippet.prefix(28))" })")
        #expect(nils.isEmpty,
                "出现 `asrSentencesData = nil` ⇒ ④ 的「母体链必写非 nil」前提失效，形状判据会误判：\(nils.map { $0.line })")
    }

    // ── T-20：扫描面名册对账（G-3）──
    @Test("T-20 名册：copyVideoToGlobal 的调用文件必须全部登记在册")
    func callerRosterIsComplete() {
        var found: [String] = []
        let base = folderMixRepoRoot.appendingPathComponent("MixCut")
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: folderMixRepoRoot.path + "/", with: "")
                guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if FolderMixIngestScan.scan(s).text.contains("copyVideoToGlobal(") { found.append(rel) }
            }
        }
        found.sort()
        #expect(!found.isEmpty, "一个调用点都没扫到 ⇒ 本条判据形同虚设（枚举失败？）")
        // 名册是**集合**，登记顺序不承载语义（实测 found 走的是路径序）。
        // 比排序后的两边，免得"加一颗文件"要顺手猜插入位置。
        let rostered = folderMixRosteredCallers.sorted()
        #expect(found == rostered,
                "调用文件与名册不一致：实测 \(found)，登记 \(rostered) ⇒ 新调用点未登记，判据会静默失明")
    }

    // ── T-21：幂等命中的日志级别（风险 9，今天必须绿且要一直绿）──
    @Test("T-21 associate 的幂等命中是正常路径，日志不许用 error 级")
    func associateIdempotentIsNotLoggedAsError() {
        // 混剪把"同一素材属于两个类别项目"变成常规路径（`importOrLinkVideo` 命中去重就走这里），
        // 于是这条幂等分支的触发频率从"事故"变成"每批几十次"。留在 error 级 ⇒ 日志刷一片红，
        // 而红日志会被下一次取证当成故障证据（`2026-10-03-tombstone-read-after-real-delete.md:48`
        // 已经被它误导过一次）。
        let src = folderMixLoad(folderMixPvTarget)
        let asError = FolderMixIngestScan.associateIdempotentAsError(src)
        #expect(asError.isEmpty,
                "幂等命中又改用 error 级记录：\(asError.map { ":\($0.line)" })")
        // 非空洞性：光"没有 error"会因整句日志被删掉而假绿 ⇒ 同一条句子必须确实以 info 在报
        let asInfo = FolderMixIngestScan.associateIdempotentAsInfo(src)
        #expect(asInfo.count == 1,
                "info 级的幂等命中日志应恰好 1 处，实得 \(asInfo.count) 处 ⇒ 句子被改写或删除，本条判据要跟着换锚点")
        // detector 自己的牙齿：只把级别从 info 换回 error（其余逐字不动），必须被抓到
        let mutated = src.replacingOccurrences(of: "MixLog.info(\"项目「",
                                              with: "MixLog.error(\"项目「")
        #expect(!FolderMixIngestScan.associateIdempotentAsError(mutated).isEmpty,
                "把级别改回 error 后 detector 没抓到 ⇒ 这条判据恒真，没有牙")
        #expect(FolderMixIngestScan.associateIdempotentAsInfo(mutated).isEmpty,
                "同一次改写必须让 info 侧也归零，否则两个 detector 是各自独立的字符串")
    }

    // ── 三对对照 ──
    @Test("对照·阳性：更坏形态必须各被检出")
    func detectorsCatchBadForms() {
        let bad = """
        func f() {
            let r = try await rebuildSegments(video, asr: asr, context: c, clearsExistingSegments: false)
            let d = try FileHelper.copyVideoToGlobal(from: url, contentHash: UUID().uuidString)
            video.defaultSourceRaw = pendingBatchSource.rawValue
            video.asrSentencesData = nil
        }
        """
        #expect(FolderMixIngestScan.hardcodedNoClear(bad).count == 1, "T-15 detector 抓不到写死 false")
        #expect(FolderMixIngestScan.uuidHashFallback(bad).count == 1, "T-18 detector 抓不到 UUID 兜底")
        #expect(FolderMixIngestScan.instanceStateIntoModel(bad).count == 1, "T-16 detector 抓不到实例状态流转")
        #expect(FolderMixIngestScan.asrDataWrittenToNil(bad).count == 1, "T-19 抓不到 asrSentencesData = nil")
    }

    @Test("对照·阴性：修好后的形态必须全部不报")
    func detectorsAcceptFixedForms() {
        let fixed = """
        func f() {
            let whole = video.segments.count == 1 && video.segments[0].startTime < 0.01
            let r = try await rebuildSegments(video, asr: asr, context: c, clearsExistingSegments: whole)
            guard let h = hash else { reportRejected(url); return }
            let d = try FileHelper.copyVideoToGlobal(from: url, contentHash: h)
            video.defaultSourceRaw = source.rawValue
            let tag = "seg_\\(UUID().uuidString.prefix(4))"
        }
        """
        #expect(FolderMixIngestScan.hardcodedNoClear(fixed).isEmpty, "T-15 误报已修形态")
        #expect(FolderMixIngestScan.uuidHashFallback(fixed).isEmpty, "T-18 误报已修形态，或把无关 UUID() 当成兜底")
        #expect(FolderMixIngestScan.instanceStateIntoModel(fixed).isEmpty, "T-16 误报已修形态")
        #expect(FolderMixIngestScan.asrDataWrittenToNil(fixed).isEmpty, "T-19 误报已修形态")
    }

    @Test("对照·绕法：拆行 + 注释包裹，仍必须检出且不误报")
    func reformattingAndCommentsDoNotEvade() {
        let evasive = """
        // 正确写法是 clearsExistingSegments: true —— 但这是注释，不该被当成站点
        /* 注释里再抄一遍 copyVideoToGlobal(from: url, contentHash: UUID().uuidString) 也不算站点 */
        func f() {
            let r = try await rebuildSegments(
                video,
                asr: asr,
                context: c,
                clearsExistingSegments:
                    false
            )
            let d = try FileHelper.copyVideoToGlobal(
                from: url,
                contentHash: UUID().uuidString
            )
        }
        """
        let h15 = FolderMixIngestScan.hardcodedNoClear(evasive)
        let h18 = FolderMixIngestScan.uuidHashFallback(evasive)
        #expect(h15.count == 1, "拆行绕过了 T-15（实得 \(h15.count) 处）")
        #expect(h18.count == 1, "拆行绕过 T-18，或注释里的示例被当成真站点（实得 \(h18.count) 处）")
    }

    // ── 笔 1b 下沉带出来的三颗新门 ──

    // T-24「ClipIngestService 全文零 UI 读数与零删除」的真身在
    // `ClipIngestReadoutCharacterizationTests.CR-5` —— 那里同时管着"读数逐条各归各位"，
    // 拆成两处抄本必然漂（同一判据只留唯一承载文件）。这里只留指针，不重抄一遍串清单。

    @Test("T-27 全仓 `func computeFileHash` 定义处恰好 1 处（搬层不留第二份）")
    func fileHashDefinitionIsUnique() {
        // 实测：搬之前它长在 ImportViewModel:1419，而全仓**没有任何门**钉它
        // （`grep computeFileHash scripts Tests` = no hits）⇒ 既无位置门也无副本门，
        // 复制出第二份也不会红。Service → ViewModel 的反向依赖就是这么长出来的。
        var defs: [String] = []
        // 只走三颗源码根：整仓枚举会把 .build/.git 一起吞进来（实测慢到不可接受）
        for root in ["MixCut", "Sources", "Tests"] {
            let base = folderMixRepoRoot.appendingPathComponent(root)
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                Issue.record("枚举 \(root) 失败 ⇒ 本条判据不可信"); continue
            }
            for case let url as URL in en {
                let p = url.path
                if !p.hasSuffix(".swift") || p.contains("/.build/") || p.contains("/.scratch/") { continue }
                guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let scanned = FolderMixIngestScan.scan(s).text
                let hits = scanned.components(separatedBy: "func computeFileHash(").count - 1
                if hits > 0 {
                    defs.append("\(p.replacingOccurrences(of: folderMixRepoRoot.path + "/", with: "")) ×\(hits)")
                }
            }
        }
        #expect(defs.count == 1,
                "`func computeFileHash` 定义处应恰好 1 颗，实得 \(defs.count) 颗：\(defs)。两份副本 = 素材身份有两个真源")
    }

    @Test("T-26 混剪页与混剪 VM 里 importVM 必须清零（笔 5/6 已落地 ⇒ 硬闸，不再是红钉）")
    func mixLaneMustNotHoldImportVM() {
        // 下沉把"入库"从 UI 状态宿主上解绑之后，混剪这条链再持有 importVM 就只是一条
        // 死依赖（View → ViewModel 的越界引用）。留着 = 半迁移，比不搬更坏：
        // 下一个人会以为还有东西要走它。
        // 〔摘标 2026-10-21〕笔 5/6 把这两处删净了（生成期改走 `ClipIngestService`），
        // 所以这条从 withKnownIssue 红钉**升成硬闸**：下面那句 `#expect(found.isEmpty)` 现在直接判。
        // 留红钉在这里只会让"谁又把它接回去"这件事不红 —— 而那正是本轮根治的缺陷会复发的形状。
        var found: [String] = []
        for file in ["MixCut/Views/Import/FolderMixView.swift",
                     "MixCut/ViewModels/FolderMixViewModel.swift"] {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            let hits = scanned.components(separatedBy: "importVM").count - 1
            if hits > 0 { found.append("\(file) ×\(hits)") }
        }
        #expect(found.isEmpty, "混剪链又拿回 importVM 了：\(found) —— 导入页的进度条会被混剪的活污染")
    }

    // ── 笔 4 两层解析带出来的两颗门 ──

    /// 找出"把路径喂给校验和读取器"的调用点（去注释、折行后数，拆行绕不过）。
    /// 合法的调用只有一种形状：**路径参数来自 `plan.identityProbePaths`** ——
    /// 因为"开关关掉就一次都不算"这件事的真源是 Core 的 `FolderMixResolver.plan`
    /// （`preciseIdentity == false` ⇒ 这颗数组恒空），不是调用点上的一个 if。
    /// 所以这里判的不是"有没有 if"，而是"有没有绕过 plan 自己凑一份清单"。
    private func folderMixIdentityCallViolations(_ scanned: String) -> [String] {
        var out: [String] = []
        let needle = "FolderMixContentKeyReader.readings("
        var search = scanned[...]
        while let range = search.range(of: needle) {
            // 往后取到这一调用的前两个实参位置（paths 是第一个实参），只看 120 个字符窗口
            let window = String(scanned[range.upperBound..<min(scanned.index(range.upperBound,
                                                                                  offsetByCharacters: 120),
                                                                  scanned.endIndex)])
            if !window.contains("identityProbePaths") {
                out.append("路径参数没走 plan.identityProbePaths：\(window.prefix(60))")
            }
            search = search[range.upperBound...]
        }
        return out
    }

    @Test("T-23 校验和读取器只许吃 plan 排出来的清单（不许绕过开关自己凑一份）")
    func contentKeyReaderConsumesOnlyThePlan() {
        let defFile = "MixCut/Services/Import/FolderMixContentKeyReader.swift"
        var violations: [String] = []
        var callSites = 0
        for file in ["MixCut/ViewModels/FolderMixViewModel.swift",
                     "MixCut/Views/Import/FolderMixView.swift",
                     "MixCut/Services/Import/FolderMixDurationReader.swift",
                     "MixCut/Services/Import/MaterialFolderScanner.swift"] {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            callSites += scanned.components(separatedBy: "FolderMixContentKeyReader.readings(").count - 1
            violations += folderMixIdentityCallViolations(scanned).map { "\(file) ⇒ \($0)" }
        }
        #expect(violations.isEmpty, "有人绕过了 Core 的探针计划直接算哈希：\(violations)")
        // 调用点上限 1 处：今天 0（笔 5 才接线），接线后恰好 1；出现第 2 处 = 又开了一条哈希通路。
        #expect(callSites <= 1, "校验和读取器出现 \(callSites) 处调用点，上限 1 处")
        // 定义处自己不算调用方（它不 import MixCutCore、也不在上面的扫描面里）
        #expect(!folderMixLoad(defFile).isEmpty, "定义处必须存在，否则这扇门扫的是空集")

        // ── 三对对照（本文件既有约定：判据不许恒真）──
        // 阳性：绕过 plan、直接吃一批路径 ⇒ 必须检出
        let bypass = FolderMixIngestScan.scan(
            "func go(paths: [String]) async {\n  for await r in FolderMixContentKeyReader.readings(paths: paths, gate: g) { _ = r }\n}"
        ).text
        #expect(!folderMixIdentityCallViolations(bypass).isEmpty,
                "对照不检出 ⇒ 这扇门恒真，接线那天它也不会拦")
        // 阴性：照规矩吃 plan ⇒ 不许报
        let legal = FolderMixIngestScan.scan(
            "func go(plan: FolderMixProbePlan) async {\n  for await r in FolderMixContentKeyReader.readings(paths: plan.identityProbePaths, gate: g) { _ = r }\n}"
        ).text
        #expect(folderMixIdentityCallViolations(legal).isEmpty, "合规写法被误伤")
        // 绕法：把**实参**拆成多行 ⇒ 折行之后仍要检出（调用点本身在一行上）
        let splitArgs = FolderMixIngestScan.scan(
            "func go(paths: [String]) async {\n  for await r in FolderMixContentKeyReader.readings(\n    paths: paths,\n    gate: g) { _ = r }\n}"
        ).text
        #expect(!folderMixIdentityCallViolations(splitArgs).isEmpty,
                "实参拆行就检不出 ⇒ 这扇门按行匹配，绕法太便宜")
        // 已知绕法（写在这儿，别让它变成"没人想到"）：把**接收者**拆行 ——
        // `FolderMixContentKeyReader` 换行再 `.readings(`，折行后中间会多一个空格，
        // 这颗门看不见。真兜底是 Core 那颗 FMX-14b（关掉开关 ⇒ 清单恒空 ⇒ 无从可算）。
        let splitReceiver = FolderMixIngestScan.scan(
            "func go(paths: [String]) async {\n  for await r in FolderMixContentKeyReader\n    .readings(paths: paths, gate: g) { _ = r }\n}"
        ).text
        #expect(!splitReceiver.contains("FolderMixContentKeyReader.readings("),
                "拆行后仍拼成一颗调用点 ⇒ 上面那条注释说的绕法已不存在，把它删掉")
    }

    @Test("T-29 IO 面必须请求 .fileSizeKey —— 字节数是懒入库预算的唯一来源")
    func materialScannerMustRequestFileSize() {
        // 为什么这颗值得钉：`FolderMixRawFile.byteSize` 一路传到 `FolderMixCandidate`
        // 再传到 `DiskSpaceBudget.estimate`。IO 层漏掉 key ⇒ 每条都是 nil ⇒ 超软上限那句红字
        // 恒等于"未知"，用户勾「我已确认」时手上没有数；而**编译一切照常、测试也全绿**，
        // 因为 nil 是合法值。这类"合法地失去能力"的退化只能靠结构判据当天拦住。
        let scanned = FolderMixIngestScan.scan(
            folderMixLoad("MixCut/Services/Import/MaterialFolderScanner.swift")).text
        #expect(scanned.contains(".fileSizeKey"), "IO 面不再请求 .fileSizeKey ⇒ byteSize 恒为 nil")
        #expect(scanned.contains("byteSize:"), "请求了却没把它带进 FolderMixRawFile ⇒ 读数被丢弃")
        // 对照阳性：把这两处任一删掉就该红 —— 这里用合成源码证它不是恒真
        let stripped = FolderMixIngestScan.scan(
            "let keys: [URLResourceKey] = [.isDirectoryKey]\nout.files.append(FolderMixRawFile(name: n))"
        ).text
        #expect(!stripped.contains(".fileSizeKey"), "对照没被剥成无 key 形态 ⇒ 这条断言在测别的东西")
    }

    @Test("T-28 探针不许新造第二套闸：并发颗数只能来自 ConcurrencyPolicy")
    func probeReadersReuseTheExistingGate() {
        // 为什么这条值得钉：`BoundedTaskGate` 的取消语义有整套判据（BC-3…BC-6），
        // 在 reader 里另起 `DispatchSemaphore`/`OperationQueue.maxConcurrentOperationCount`/
        // 写死 `maxConcurrent: 4` = 把已经证过的东西换成没证过的东西，
        // 且"停止"那条腿会只停住一半（真机表现为按了停止还在读盘）。
        let forbidden = ["DispatchSemaphore(", "OperationQueue", "maxConcurrentOperationCount",
                         "Mutex(", "os_semaphore"]
        var offenders: [String] = []
        for file in ["MixCut/Services/Import/FolderMixDurationReader.swift",
                     "MixCut/Services/Import/FolderMixContentKeyReader.swift"] {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            for token in forbidden where scanned.contains(token) {
                offenders.append("\(file) 出现 \(token)")
            }
            // 颗数不许写死：一旦出现闸构造，实参必须是策略那颗
            if let range = scanned.range(of: "BoundedTaskGate(maxConcurrent:") {
                let tail = scanned[range.upperBound...]
                let arg = String(tail.prefix(60)).trimmingCharacters(in: .whitespaces)
                if !arg.hasPrefix("ConcurrencyPolicy.maxProbeConcurrency()") {
                    offenders.append("\(file) 的闸颗数没走策略：\(arg.prefix(40))")
                }
            }
        }
        #expect(offenders.isEmpty, "探针层自造并发闸：\(offenders)")

        // 对照阳性：把违规形态喂进去必须检出（否则 #expect(isEmpty) 只是恒真）
        let dirty = FolderMixIngestScan.scan(
            "let sem = DispatchSemaphore(value: 4)\nlet gate = BoundedTaskGate(maxConcurrent: 4)"
        ).text
        #expect(dirty.contains("DispatchSemaphore("), "注释剥离把对照吞了 ⇒ 检出无从谈起")
        // 对照阴性：策略派生的颗数不许误伤
        let clean = FolderMixIngestScan.scan(
            "let gate = BoundedTaskGate(maxConcurrent: ConcurrencyPolicy.maxProbeConcurrency())"
        ).text
        if let range = clean.range(of: "BoundedTaskGate(maxConcurrent:") {
            let arg = String(clean[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            #expect(arg.hasPrefix("ConcurrencyPolicy.maxProbeConcurrency()"),
                    "合规写法被这条腿误伤：\(arg.prefix(40))")
        } else {
            Issue.record("折行后钩子扫不到 BoundedTaskGate 构造 ⇒ 对照失效，这条腿不可信")
        }
    }

    // MARK: 与库对接的键（计划 2026-10-22 笔 J2 · T-30 / T-31）

    /// 混剪链的扫描面。新增读库的文件若没登进来，门对新站点完全失明（T-20 同形教训）。
    private var folderMixJoinTargets: [String] {
        ["MixCut/ViewModels/FolderMixViewModel.swift",
         "MixCut/Services/Import/FolderMixDurationReader.swift",
         "MixCut/Services/Import/FolderMixContentKeyReader.swift"]
    }

    @Test("T-30A 混剪链里把库内路径当键的写法必须为 0（跨域猜键不许回来）")
    func noCrossDomainKeyUseInMixLane() {
        for file in folderMixJoinTargets {
            let hits = FolderMixIngestScan.crossDomainKeyUses(folderMixLoad(file))
            #expect(hits.isEmpty,
                    "腿 A 抓到跨域猜键：\(file) 行号 \(hits.map(\.line)) —— 库内路径与素材目录路径永不相交，就是这次 50 条全摘的成因")
        }
        // 正对照：注入的两种写法必须都被抓到，否则上面那条是恒真
        let dirty = FolderMixIngestScan.crossDomainKeyUses(
            "if candidate.path == video.localPath { go() }\nout[video.localPath] = record")
        #expect(dirty.count == 2, "钩子抓不到注入的两种写法 ⇒ 腿 A 瞎了：\(dirty.map(\.snippet))")
    }

    @Test("T-30B 键→段 id 那张表：下标写入 0 处、整表赋值 1 处且必须来自 join、清空 1 处")
    func segmentKeyTableHasExactlyOneJoinSourcedWriter() {
        let vm = folderMixLoad("MixCut/ViewModels/FolderMixViewModel.swift")
        let subscripts = FolderMixIngestScan.segmentSubscriptWrites(vm)
        let whole = FolderMixIngestScan.segmentWholeAssignments(vm)
        let fromJoin = FolderMixIngestScan.segmentJoinSourced(vm)
        let cleared = FolderMixIngestScan.segmentCleared(vm)
        #expect(subscripts.isEmpty,
                "又长出下标写入：\(subscripts.map { ":\($0.line)" }) ⇒ 这张表有了第二个真源")
        #expect(fromJoin.count == 1, "整表赋值来自 join 的那一处应恰好 1，实得 \(fromJoin.count)")
        #expect(cleared.count == 1, "每次生成开头的清空应恰好 1，实得 \(cleared.count)")
        // 三类分开数才是对的口径：合成一条"赋值点 ≤1"会把清空也算进去（计划初版就栽在这儿）
        #expect(whole.count == fromJoin.count + cleared.count,
                "整表赋值 \(whole.count) 处 ≠ 交回 1 + 清空 1 ⇒ 有第三处写入点：\(whole.map { ":\($0.line)" })")
        #expect(FolderMixIngestScan.segmentSubscriptWrites("segmentIDByKey[key] = segment.id").count == 1,
                "钩子抓不到注入的下标写入 ⇒ 这条腿是恒真")
        #expect(FolderMixIngestScan.segmentCleared("segmentIDByKey = [:]").count == 1)
    }

    @Test("T-30C 对应关系只许来自入库交回；取数只许按 id，不许 fetch 再猜")
    func correspondenceComesOnlyFromIngestReport() {
        let vm = folderMixLoad("MixCut/ViewModels/FolderMixViewModel.swift")
        let text = FolderMixIngestScan.scan(vm).text
        let feed = text.components(separatedBy: "ingested.append(contentsOf: report.ingested)").count - 1
        #expect(feed == 1, "交回累加点 \(feed) 处（应 1）⇒ 对应关系有了第二个来源，或干脆没人喂了")
        let byID = text.components(separatedBy: "wanted.contains(video.id)").count - 1
        #expect(byID == 1, "按 id 取数那处 \(byID)（应 1）：投影换成按路径/名字挑，就等于把猜键搬回这里")
        let fetchers = folderMixJoinTargets
            .filter { FolderMixIngestScan.scan(folderMixLoad($0)).text.contains("FetchDescriptor<Video>") }
            .sorted()
        #expect(fetchers == ["MixCut/Services/Import/FolderMixDurationReader.swift",
                             "MixCut/ViewModels/FolderMixViewModel.swift"],
                "读全表 Video 的文件名册变了：\(fetchers) ⇒ 扫描面要重新核（新站点没人审过）")
    }

    @Test("T-31 入库两支各记一次对应关系（只记新建支就是这次的缺陷形状）")
    func bothIngestBranchesRecordCorrespondence() {
        let svc = folderMixLoad("MixCut/Services/Import/ClipIngestService.swift")
        let sites = FolderMixIngestScan.ingestedRecordSites(svc)
        #expect(sites.count == 2,
                "交回点 \(sites.count) 处（应 2：新建整片段支 + 仅关联支）⇒ 少一支就有一条通路把 id 丢掉")
        let text = FolderMixIngestScan.scan(svc).text
        guard let namesAt = text.range(of: "report.importedNames.append")?.lowerBound,
              let linkAt = text.range(of: "report.linkedExistingNames.append")?.lowerBound else {
            Issue.record("两支的既有写入点找不到 ⇒ 顺序腿无从核对"); return
        }
        var positions: [String.Index] = []
        var search = text.startIndex
        while let r = text.range(of: "report.ingested.append(", range: search..<text.endIndex) {
            positions.append(r.lowerBound); search = r.upperBound
        }
        #expect(positions.count == 2, "交回点解析出 \(positions.count) 处，与计数腿不一致")
        if positions.count == 2 {
            #expect(namesAt < positions[0] && positions[0] < linkAt,
                    "新建支的交回没紧跟在本支里（会被挪到别支，顺序承重）")
            #expect(linkAt < positions[1],
                    "仅关联支没补交回 —— 真机那 59 条走的正是这一支，少这句就是「全部行被摘掉」")
        }
        // 正对照：只在新建支写的形态必须被计数腿抓到
        let oneBranch = "func f() { report.importedNames.append(name) "
            + "report.ingested.append(row) report.linkedExistingNames.append(name) }"
        #expect(FolderMixIngestScan.ingestedRecordSites(oneBranch).count == 1,
                "钩子抓不到「少一支」的形态 ⇒ 这条门是恒真")
    }
}

private extension String {
    /// 按**字符**（不是 UTF-8 偏移）前移 n 步，越界就 clamp 到 endIndex。
    /// 为什么要自己写：`index(_:offsetBy:)` 的默认 `limitedBy` 语义容易在这里返回越界位置，
    /// 而窗口取值一旦越界就直接 trap —— 判据不该有把整个套件弄崩的权限。
    func index(_ i: Index, offsetByCharacters n: Int) -> Index {
        var idx = i
        var steps = n
        while steps > 0, idx < endIndex { idx = index(after: idx); steps -= 1 }
        return idx
    }

    @Test("T-22 候选账本只由一处重建，且任何路径都不许把它清空")
    func candidateLedgerHasExactlyOneRebuilder() {
        // 这一族要钉的是上一轮那条**用户报上来的 bug**：入库失败分支里把候选清空 ⇒
        // 左栏整列变「无候选」。上一轮的形状是"候选真源 = 入库后的 Segment"，所以只能盯
        // `candidatesByCategory = [:]` 这句赋值；本轮改成文件系统投影之后，
        // 那份账是 `rebuildCandidates()` 从 `materials` 现算的**派生视图** ⇒
        // 清空这件事在形状上就写不出来了。于是判据换成盯"只有一处赋值 + 不许赋空字典"。
        let scanned = FolderMixIngestScan.scan(
            folderMixLoad("MixCut/ViewModels/FolderMixViewModel.swift")).text
        let assignments = scanned.components(separatedBy: "candidatesByCategory = ").count - 1
        #expect(assignments == 1,
                "候选账本出现 \(assignments) 处赋值（上限 1）⇒ 多一处就是第二个真源，会漂")
        #expect(!scanned.contains("candidatesByCategory = [:]"),
                "有人又写了清空那一句 ⇒ 失败分支会把左栏全变「无候选」（就是用户报的那个现场）")
        // 对照阳性：合成"两处赋值 + 一句清空"的形态必须被同一颗探测器抓到
        let dirty = FolderMixIngestScan.scan(
            "func a() { candidatesByCategory = [:] }\nfunc b() { candidatesByCategory = x }").text
        #expect(dirty.components(separatedBy: "candidatesByCategory = ").count - 1 == 2,
                "折行/拼接把赋值句拆开了 ⇒ 计数腿是瞎的")
        #expect(dirty.contains("candidatesByCategory = [:]"))
    }

    @Test("T-25 整片段补建只许长在入库真身那两处，且第二处必须带标记与两道守门（甲-隐改口径）")
    func wholeClipBackfillIsConfinedToTheIngestThroat() {
        // D 段那句"绝不替解析不到的素材补建整片段"若没有这颗门就只是愿望：
        // 补建看起来能"救回"一条素材，实际是把母体导入的分镜语义塞进混剪，
        // 而那批补出来的段没人复核过形状，导出侧照拼不误。
        // 名册（实读）：定义处 + 母体链 + 搬进 service 的入库真身，共 3 颗文件。
        let roster = ["MixCut/Services/Import/SegmentCommitter.swift",
                      "MixCut/ViewModels/ImportViewModel.swift",
                      "MixCut/Services/Import/ClipIngestService.swift"]
        for file in roster {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            #expect(scanned.contains("commitWholeVideo("),
                    "\(file) 在册却抓不到调用点 ⇒ 名册与代码已经对不上，这颗门开始失明")
        }
        var offenders: [String] = []
        for file in ["MixCut/Views/Import/FolderMixView.swift",
                     "MixCut/ViewModels/FolderMixViewModel.swift",
                     "MixCut/Services/Import/MaterialFolderScanner.swift",
                     "MixCut/Services/Import/FolderMixDurationReader.swift",
                     "MixCut/Services/Import/FolderMixContentKeyReader.swift"] {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            if scanned.contains("commitWholeVideo(") { offenders.append(file) }
        }
        #expect(offenders.isEmpty, "混剪链自己补建整片段：\(offenders)")

        // 改口径新增的两条腿（决议 K2 甲-隐 / K3，计划 2026-10-22 第三轮）：
        // 补建只许发生在入库真身那**两处**（新建支 + 去重命中的补建支），且第二处必须带标记与两道守门。
        let service = FolderMixIngestScan.scan(folderMixLoad("MixCut/Services/Import/ClipIngestService.swift")).text
        let calls = service.components(separatedBy: "commitWholeVideo(").count - 1
        #expect(calls == 2,
                "service 内 commitWholeVideo( 实得 \(calls) 处，登记为 2 处（新建支 + 补建支）⇒ 多一处就是第三个补建入口，少一处是甲-隐被打掉")
        #expect(service.contains("mixInternalWholeClip = true"),
                "补建出来的那条没打标记 ⇒ 会直接混进用户的分镜素材库（甲-隐 变成甲-显）")
        #expect(service.contains("hasWholeClip") && service.contains("FileHelper.materialProbe"),
                "补建支少了某道守门：hasWholeClip = 幂等（重扫不叠第二片），materialProbe = 绝不给已缺文件的行补段")
        // 正对照：注入"第三处调用 + 没标记"的形态，两条计数腿都必须抓到
        let dirty = FolderMixIngestScan.scan(
            "commitWholeVideo(for: a)\ncommitWholeVideo(for: b)\ncommitWholeVideo(for: c)\n").text
        #expect(dirty.components(separatedBy: "commitWholeVideo(").count - 1 == 3,
                "计数腿抓不到三处调用 ⇒ 它是瞎的")
    }

    @Test("T-34 混剪补建的载体必须停在 .imported —— 母体导入不许被静默判成「已分析」（计划 P-2）")
    func mixCarrierStatusNeverCompleted() {
        // P-2 的触发链：若混剪入库把 Video.status 收成 `.completed`，同一文件日后走母体导入时
        // `needsAnalysis = status != .completed || segments.isEmpty` 两个条件同时为假
        // ⇒ 阶段 2（镜头检测 + ASR + AI）整段跳过，用户拿到一条覆盖整片的粗分镜且无提示。
        // 本门钉住：入库真身只许写 `.imported`，且 needsAnalysis 的表达式必须保留对 status 的判断。
        let service = FolderMixIngestScan.scan(
            folderMixLoad("MixCut/Services/Import/ClipIngestService.swift")).text
        #expect(service.contains("video.status = .imported"),
                "新建支不再写 .imported ⇒ 母体链与混剪的边界失去可区分性")
        #expect(!service.contains("video.status = .completed"),
                "混剪入库把载体收成 .completed ⇒ P-2 跨通路污染立即成立")
        #expect(service.contains("existingVideo.status != .completed"),
                "needsAnalysis 不再看 status ⇒ 已入库的载体可能被静默判成「无需分析」")
        #expect(service.contains("existingVideo.segments.isEmpty"),
                "needsAnalysis 不再看段数 ⇒ 无段载体不会触发分析")

        // 正对照：注入 P-2 的写法必须被同一颗字符串判据认出来（否则四条只是「文件里恰好没写」）。
        let dirty = FolderMixIngestScan.scan("video.status = .completed\nvideo.status = .imported").text
        #expect(dirty.contains("video.status = .completed"),
                "扫描器读不出 `.completed` ⇒ 上面那条反例腿是瞎的")
    }

    @Test("T-32d「查不了」那一档必须真的整批停手：degraded 分支里要有 errorMessage 与 return")
    func degradedBranchAbortsTheWholeBatch() {
        // 拦什么：有人把 degraded 退成"当没缺处理"（放行）或退成"全标缺失"—— 两种都是伪装。
        // 拦不住什么：这条盯的是源码形态；执行路径由 App 腿 JOIN-23 + 真机腿 3 负责（写明白，别冒充跑过）。
        let scanned = FolderMixIngestScan.scan(folderMixLoad("MixCut/ViewModels/FolderMixViewModel.swift"))
        // 条件本身要钉死成 `if reading.degraded {` —— 台架刀实测：只查分支体时，
        // 有人把它改成 `if false, reading.degraded {`（等价于摘掉这一档）一条都不红。
        let head = scanned.text.components(separatedBy: "reading.degraded").dropFirst().first ?? ""
        #expect(!head.isEmpty, "抓不到 `reading.degraded` 那道分支 ⇒ 判据在测空气")
        #expect(scanned.text.contains("if reading.degraded {"),
                "降级那道分支的条件写法变了 ⇒ 这一档可能已被等价摘掉（台架刀 K4-d 就是把它改成 if false,）")
        let body = String(head.prefix(420))
        #expect(body.contains("errorMessage ="), "degraded 那档没出声：\(body.prefix(80))")
        #expect(body.contains("return"), "degraded 那档没停手（没 return）⇒ 会照常往下建方案")
        #expect(body.contains("查不了"), "文案没写\"查不了\"就不许算这一档（既有口径：不许伪装成没丢）")
    }

    @Test("T-32 可用性那条轴：混剪只调唯一判定本体，且每个投影点都被喂了缺失集")
    func availabilityRidesTheSingleRuler() {
        // 腿 A：混剪 VM 必须调 `missingDivideReading` 那颗（界面 refresh / 启动对账 / 混剪三处同源）。
        //   抓什么：有人改回"读那颗共享集"或自己 refresh —— 那是把跨项目串缺失集请回来。
        let vmFile = "MixCut/ViewModels/FolderMixViewModel.swift"
        let vm = FolderMixIngestScan.scan(folderMixLoad(vmFile)).text
        #expect(vm.contains("MaterialAvailabilityStore.missingDivideReading"),
                "混剪不再调那颗唯一判定 ⇒ 这条轴又回到两个答案（\(vmFile)）")
        // 腿 B：混剪链**不许**读那颗共享集、也不许自己拼一次文件存在性判断。
        //   拦什么：第二个持有者（`shared.missingVideoIDs`）与第二把尺子（裸 `fileExists(`）。
        //   拦不住什么：把判定抄成另一颗同名函数 —— 那要腿 A 那颗串对上才看得见。
        var offenders: [String] = []
        for file in [vmFile,
                     "MixCut/Services/Import/ClipIngestService.swift",
                     "MixCut/Services/Import/MaterialFolderScanner.swift",
                     "MixCut/Services/Import/FolderMixDurationReader.swift",
                     "MixCut/Services/Import/FolderMixContentKeyReader.swift",
                     "MixCut/Views/Import/FolderMixView.swift"] {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            if scanned.contains("MaterialAvailabilityStore.shared") || scanned.contains("fileExists(") {
                offenders.append(file)
            }
        }
        #expect(offenders.isEmpty, "混剪链里出现第二把尺子或第二个持有者：\(offenders)")
        // 正对照：两种写法都要被同一颗探测器抓到，否则上面那条是恒真
        let dirty = FolderMixIngestScan.scan(
            "let gone = FileManager.default.fileExists(atPath: p)\n"
            + "let set = MaterialAvailabilityStore.shared.missingVideoIDs").text
        #expect(dirty.contains("fileExists(") && dirty.contains("MaterialAvailabilityStore.shared"),
                "探测器抓不到注入的两种写法 ⇒ 腿 B 瞎了")

        // 腿 C（覆盖评估 TC-K1）：每个 `rowShapes(for:` 调用点都必须把缺失集喂进去。
        //   为什么单独钉：那颗新参数**必填无默认** ⇒ 漏传编译不过，但"传了个空集合"照样静默全可用，
        //   而空集是合法值、编译器一声不响。这条腿盯的是"调用点真的在传读数"而不是"函数签名有没有"。
        var hollow: [String] = []
        var sites = 0
        for file in [vmFile, "MixCutAppTests/FolderMixIngestJoinTests.swift"] {
            let scanned = FolderMixIngestScan.scan(folderMixLoad(file)).text
            for piece in scanned.components(separatedBy: "rowShapes(for:").dropFirst() {
                sites += 1
                let head = String(piece.prefix(220))
                if !head.contains("missingIDs:") { hollow.append(file) }
            }
        }
        #expect(sites >= 1, "一处 `rowShapes(for:` 调用点都没抓到 ⇒ 这条腿在测空气（名册与代码对不上）")
        #expect(hollow.isEmpty, "有调用点没把缺失集喂进投影：\(hollow)")
        let hollowControl = FolderMixIngestScan.scan(
            "shapes: rowShapes(for: ingested, context: context)").text
        #expect(!hollowControl.components(separatedBy: "rowShapes(for:").dropFirst()
            .map { String($0.prefix(220)) }.allSatisfy { $0.contains("missingIDs:") },
                 "注入的漏传写法抓不到 ⇒ 腿 C 是恒真的")
    }
    @Test("T-33 可见性名册：18 处都挂上唯一出口，8 组豁免面一处都没偷挂过滤")
    func visibilityRosterIsPaired() {
        // 决议 K9（甲-隐 的可见性收口）。名册口径：`grep -rn "\\.segments" MixCut` 的全部命中
        // = 29 颗文件 / 120 处，逐颗表态 ⇒ 18 处挂出口、其余按四类豁免（计划 K2-6 / 第十节）。
        // 〔2026-10-23 V3 改口〕19 → 18：概览页那张卡片不再逐卡读 `displayableSegmentCount`，
        //   取数点搬进 `ProjectViewModel.refreshOverviewSnapshot`（下面那条 VM 名册已经是它）。
        // 拦什么：少挂一处 = 用户看不见的段出现在那一屏；多挂一处 = 把功能自己打死或漏删数据。
        // 拦不住什么：把同一处判据抄进别的文件 —— 名册按文件计数，同文件内的重复写法要人审。
        let mustHaveExit: [(file: String, needle: String, note: String)] = [
            ("MixCut/ViewModels/SegmentLibraryViewModel.swift", "video.displayableSegments", "分镜库全域投影（出-1）"),
            ("MixCut/ViewModels/SegmentLibraryViewModel.swift", "!$0.mixInternalWholeClip", "撤销那两条绕过装载的 append（出-17/18）"),
            ("MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift", "video.displayableSegments", "批量字号/遮罩作用域（出-2/3）"),
            ("MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift", "vid.displayableSegments", "克隆复用来源（出-4）"),
            ("MixCut/ViewModels/ProjectViewModel.swift", "displayableSegmentCount", "概览一次读全（原出-5/6 收进这一点）"),
            ("MixCut/Views/Import/ImportView.swift", "video.displayableSegments", "导入页标签墙（出-7/8）"),
            ("MixCut/Views/Import/ImportView.swift", "displayableSegments.isEmpty", "重试分析门禁（出-19，实施时补）"),
            ("MixCut/Views/Schemes/SchemeListView.swift", "displayableSegmentCount", "「N 个分镜可用」那句（出-9）"),
            ("MixCut/Views/Schemes/SchemeListView.swift", "project.displayableSegments", "生成弹窗的预估总时长（出-10）"),
            ("MixCut/ViewModels/SchemeViewModel.swift", "project.displayableSegments", "AI 方案生成与叙事结构候选池（出-11/14/16）"),
            ("MixCut/ViewModels/SchemeViewModel.swift", "video.displayableSegments", "描述符两处（出-12/15）"),
            ("MixCut/Views/Schemes/NarrativeStructureEditorView.swift", "project.displayableSegments", "view 层候选池（出-16）"),
            ("MixCut/Views/Schemes/SegmentPickerDrawer.swift", "mixInternalWholeClip", "方案编辑选段抽屉（出-18 名单里的抽屉）"),
        ]
        var missing: [String] = []
        for row in mustHaveExit {
            let text = FolderMixIngestScan.scan(folderMixLoad(row.file)).text
            if !text.contains(row.needle) { missing.append("\(row.file) ← \(row.note)") }
        }
        #expect(missing.isEmpty, "该挂唯一出口的站点没挂上：\(missing)")

        // 豁免面：过滤挂上去就是把功能打死（导出取的就是那条内部段 / 删除要连带删干净 /
        // 启动修复漏了它就来路不明 / MCP 本轮只登记不落地）。
        let mustNotFilter: [String] = [
            "MixCut/Services/Export/ExportService.swift",
            "MixCut/Utilities/ModelContextExtension.swift",
            "MixCut/App/MixCutApp.swift",
            "MixCut/Services/MCP/MCPToolHandlers.swift",
            "MixCut/Services/MCP/MCPSegmentToolHandlers.swift",
            "MixCut/ViewModels/FolderMixViewModel.swift",
            "MixCut/Services/Import/ClipIngestService.swift",
        ]
        var leaked: [String] = []
        for file in mustNotFilter where !file.hasSuffix("ClipIngestService.swift") {
            let text = FolderMixIngestScan.scan(folderMixLoad(file)).text
            if text.contains("displayableSegments") || text.contains("mixInternalWholeClip") {
                leaked.append(file)
            }
        }
        #expect(leaked.isEmpty, "这些面必须看见全部段（含内部段），不许挂可见性过滤：\(leaked) —— 唯一例外是 ClipIngestService 里那道补建守门，它读标记不读出口")

        // 一颗字段两用那条分叉（计划 K2-4 第 4 条）：数字走新颗，三处禁用闸继续读旧颗。
        let list = FolderMixIngestScan.scan(folderMixLoad("MixCut/Views/Schemes/SchemeListView.swift")).text
        let gateUses = list.components(separatedBy: "segmentCount == 0").count - 1
        #expect(gateUses == 3, "「有没有料」那三处禁用闸实得 \(gateUses) 处，期望 3 ⇒ 闸被改过就得重评")
        let model = FolderMixIngestScan.scan(folderMixLoad("MixCut/Models/Project.swift")).text
        #expect(model.contains("var segmentCount: Int") && model.contains("var displayableSegmentCount: Int"),
                "两颗数必须并存：就地过滤 segmentCount 等于偷改那三处闸")

        // 正对照（防恒真）：漏挂的形态与偷挂的形态都必须被同一套探测器抓到
        let hollow = FolderMixIngestScan.scan("for video in project.videos { allSegments.append(contentsOf: video.segments) }").text
        #expect(!hollow.contains("displayableSegments"), "注入的未收口写法抓不到 ⇒ 正腿是瞎的")
        let greedy = FolderMixIngestScan.scan(
            "guard let segment = slot.segment, !segment.mixInternalWholeClip {").text
        #expect(greedy.contains("mixInternalWholeClip"), "注入的越界过滤写法抓不到 ⇒ 反腿是瞎的")
    }
}
