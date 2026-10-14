import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 素材可用性（方案 kindled-cloud-robin.md 批 4）——「只有一个持有者、只报不删、只加在链尾」
//
// 这一族判据守的是三条**已经成立**的不变式，把它们从注释升级成会红的东西（与 UG-G13、
// GT-01/02 同一条纪律：注释会被删，判据不会）：
//
// ① 结果集只许**整体赋值**。写成 `formUnion(` 的话，一次误判就永久留在集里 ——
//    用户把文件放回原处，那张卡仍然写着「已丢失」，自愈能力当场失效，而且没有任何报错。
// ② 这一层**不产生任何删除或隐藏动作**（真删记录走视频删除咽喉，由用户显式发起）。
//    「文件没了」自动变成「记录删掉」是这个功能最危险的误读，所以不许只写在文件头里。
// ③ 丢失项的过滤**只加在 `numberedVideos` 链尾**。加到源头（`project.associatedVideos`
//    那一层）会连编号一起过滤掉 ⇒ 藏几张卡就顺带改了别的卡的 `video_no`，而它是 Agent 的
//    寻址契约（`ProjectVideoDedup.swift:53-59` 自述）。次数相同、位置不同也算破坏 ⇒
//    这条与 UG-G11 同形，是**顺序**判据而不是计数判据。
//
// 为什么住在 Swift 层而不是 `scripts/check_*.sh`：本仓的 shell 守卫没有"预期失败"形态，
// 且这套扫描要剥注释（V4-4 那次假红的根因就是文档注释被数进来）—— 复用
// `RelationshipReadScan.codeOnly` 这颗现成的尺子，不另发明第二把。
// ============================================================================

private let availabilityRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private let storeFile = "MixCut/Infrastructure/MaterialAvailabilityStore.swift"
private let importViewFile = "MixCut/Views/Import/ImportView.swift"
private let appFile = "MixCut/App/MixCutApp.swift"

/// 读某文件的**纯代码**（剥掉注释）。取不到或剥完全空一律 Issue.record：
/// 取样面为空时任何"命中 0 处"都长得像通过（仓里已立的阴性读数规矩）。
private func codeOnlyOfFile(_ rel: String) -> String? {
    let url = availabilityRepoRoot.appendingPathComponent(rel)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("读不到 \(rel) ⇒ 判据无法成立，不算通过")
        return nil
    }
    let code = RelationshipReadScan.codeOnly(raw)
    if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Issue.record("\(rel) 剥注释后为空 ⇒ 取样面没命中，本条不算通过")
        return nil
    }
    return code
}

/// 大括号平衡配对取出声明体（计算属性与函数都适用）。
/// ⚠️ 不用行号差/窗口截取：那种写法遇到长函数会截出一半，剩下的一半恒绿。
/// 括号不闭合（被截断）时返回 nil，由调用方报判据失效，不许给出一个"看着能用"的体。
private func balancedBody(of code: String, head: String) -> String? {
    guard let start = code.range(of: head)?.upperBound else { return nil }
    guard let brace = code[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var k = brace
    while k < code.endIndex {
        if code[k] == "{" { depth += 1 }
        else if code[k] == "}" {
            depth -= 1
            if depth == 0 { return String(code[brace...k]) }
        }
        k = code.index(after: k)
    }
    return nil
}

/// 原始文件（**不**剥注释），专给"日志里必须写着这句话"这类判据用。
///
/// ⚠️ 本轮实测到的共享尺子性质：`RelationshipReadScan.codeOnly` 连**字符串字面量一起抹掉**
/// （`environment["MIXCUT_DEBUG_FAIL_SAVE"]` 出来是 `environment[      ]`）。
/// 所以查句子内容走 codeOnly 必然 0 命中 —— 那是"判据在测空气"的一种隐蔽形态。
/// 用法约束：查句子必须同时要求**那一行还有代码侧的锚**（`MixLog.info`），否则注释就能把判据喂绿
/// —— 那正是 V4-4 那族假红的镜像形状。
private func rawOfFile(_ rel: String) -> String? {
    let url = availabilityRepoRoot.appendingPathComponent(rel)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        Issue.record("读不到 \(rel) ⇒ 判据无法成立，不算通过")
        return nil
    }
    return raw
}

/// 「既是日志行、又写着这句话」的行数。注释行没有 `MixLog.info` 前缀，进不来。
private func logLines(_ raw: String, containing phrase: String) -> Int {
    raw.components(separatedBy: "\n")
        .filter { $0.contains("MixLog.info") && $0.contains(phrase) }
        .count
}

/// `name` 的**赋值**次数（`name = ` 带空格）。声明 `var name: T = …` 带冒号，不算赋值 ——
/// 这条分类是 MAV-01 的全部意义：把整体赋值写成并集，计数不变、语义已坏。
private func assignmentCount(_ code: String, name: String) -> Int {
    code.components(separatedBy: "\n").reduce(0) { acc, raw in
        acc + (raw.contains("\(name) = ") ? 1 : 0)
    }
}

/// 两个锚点在体内**先后的**位置（找不到返回 nil）。顺序判据用它，不用行号。
private func ordered(_ body: String, first a: String, then b: String) -> Bool? {
    guard let i = body.range(of: a)?.lowerBound,
          let j = body.range(of: b)?.lowerBound else { return nil }
    return i < j
}

// ============================================================================
// 批 5 名册：G-M01…G-M04 —— 把「长出第 N+1 处裸探针」与「自造第 N+1 套缺失文案」变成会红的事
// ============================================================================

/// 名册条目：文件 + 该文件里裸探针的次数 + 是否豁免 + 理由。
private struct ProbeRosterEntry {
    let file: String
    var count: Int
    var exempt: Bool          // `var`：G-M02 的刀要在内存里造一条"豁免却没理由"的登记来验判据会咬
    var reason: String
}

/// 素材轴上"明知是裸问但本批不动"的登记条目（逐条必须带理由）。
private struct MaterialExemption {
    let file: String
    let count: Int
    let reason: String
}

private func regex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern)
}

/// 递归取 `MixCut/` 与 `Sources/` 下的 .swift（相对包根的路径，排序保证可比）。
private func swiftFilesUnder(_ rel: String) -> [String] {
    let base = availabilityRepoRoot.appendingPathComponent(rel)
    guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]) else {
        Issue.record("扫不到 \(rel) ⇒ 探针根没命中，取样面为空，本条不算通过")
        return []
    }
    var out: [String] = []
    for case let url as URL in en where url.pathExtension == "swift" {
        out.append(url.path.replacingOccurrences(of: availabilityRepoRoot.path + "/", with: ""))
    }
    if out.isEmpty { Issue.record("\(rel) 下取不到 .swift ⇒ 取样面为空") }
    return out.sorted()
}

/// 「拿路径问文件在不在」的两种拼写（`fileExists` / `isReadableFile`）一起算。
private let probePattern = "(fileExists|isReadableFile)\\(atPath:\\s*([^)]{0,120}?)\\)"

/// 命中次数（剥注释后）。
private func probeHitCount(_ code: String) -> Int {
    guard let re = regex(probePattern) else { Issue.record("正则构造失败 ⇒ 判据失效"); return -1 }
    let ns = code as NSString
    return re.matches(in: code, range: NSRange(location: 0, length: ns.length)).count
}

/// 一处的参数表达式里是否出现**模型侧路径属性名**（名字从 `MixCut/Models/*.swift` 现算，
/// 手写名单就是第二真源；这也是把 91 处原始命中收到"素材可用性轴"这一档的口径）。
private func modelPathProperties() -> Set<String> {
    var props: Set<String> = []
    guard let decl = regex("\\bvar\\s+(\\w*(?:Path|URL)\\w*)\\s*:") else {
        Issue.record("属性名正则构造失败 ⇒ 判据失效"); return props
    }
    for rel in swiftFilesUnder("MixCut/Models") {
        guard let raw = try? String(contentsOf: availabilityRepoRoot.appendingPathComponent(rel),
                                    encoding: .utf8) else {
            Issue.record("读不到 \(rel) ⇒ 属性名册不可信"); continue
        }
        let code = RelationshipReadScan.codeOnly(raw)
        let ns = code as NSString
        for m in decl.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            props.insert(ns.substring(with: m.range(at: 1)))
        }
    }
    if props.isEmpty { Issue.record("模型侧取不到任何路径属性名 ⇒ 取样面没命中，判据失效") }
    return props
}

/// 素材轴上的裸问（参数表达式引用了模型路径属性）逐文件计数。
private func materialAxisCounts() -> [String: Int] {
    let props = modelPathProperties()
    var m: [String: Int] = [:]
    for rel in swiftFilesUnder("MixCut") {
        guard let raw = try? String(contentsOf: availabilityRepoRoot.appendingPathComponent(rel),
                                    encoding: .utf8) else { continue }
        let code = RelationshipReadScan.codeOnly(raw)
        guard let re = regex(probePattern) else { Issue.record("正则构造失败 ⇒ 判据失效"); continue }
        let ns = code as NSString
        for hit in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let arg = ns.substring(with: hit.range(at: 2))
            if props.contains(where: { arg.contains("\($0)") }) { m[rel, default: 0] += 1 }
        }
    }
    return m
}

/// 名册比对的三条问题（少/多/数不符/豁免缺理由）—— 形状照 `TombstoneReadGuardTests` 的 `rosterProblems`。
private func rosterProblems(actual: [String: Int], recorded: [ProbeRosterEntry]) -> [String] {
    var problems: [String] = []
    var seen: Set<String> = []
    for e in recorded {
        seen.insert(e.file)
        let got = actual[e.file] ?? 0
        if got != e.count { problems.append("计数不符 \(e.file)：名册 \(e.count) 实得 \(got)") }
        if e.exempt, e.reason.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("判据失效 豁免条目缺理由：\(e.file)")
        }
    }
    for file in actual.keys where !seen.contains(file) {
        problems.append("未登记的新站点：\(file)（\(actual[file] ?? 0) 处）")
    }
    return problems
}

/// ⚠️ **由 dump 腿生成，不许手写**。重生成：
/// `MEDIA_DUMP_EXISTS_ROSTER=1 swift test --filter MediaAvailabilityGuardTests`
/// 然后整段粘回 `.scratch/material_probe_roster.txt` 里的两张表。
/// 为什么全仓逐文件计数也要登：素材轴只 8 个文件，但"新长出一处裸问"这件事本身
/// 不分轴 —— 计数名册负责"变多就红"，G-M03 负责"素材轴必须走唯一出口"。
private let probeRoster: [ProbeRosterEntry] = [
    // 84 处 / 29 文件 —— 全部由 dump 腿产出。`exempt` 全为 false：这张表管的是"计数变了就红"，
    // 不承担理由；"素材轴必须走唯一出口"由下面 `materialExemptions` + G-M03 管。
    .init(file: #"MixCut/App/DebugSelfTest.swift"#, count: 4, exempt: false, reason: ""),
    .init(file: #"MixCut/App/MixCutApp.swift"#, count: 6, exempt: false, reason: ""),
    .init(file: #"MixCut/App/SchemaGuard.swift"#, count: 3, exempt: false, reason: ""),
    .init(file: #"MixCut/Infrastructure/MaterialAvailabilityStore.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Models/Segment.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/AI/OpenAICompatibleClient.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/ASR/ASRService.swift"#, count: 6, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/Export/BatchSegmentExportService.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/Export/DubExportService.swift"#, count: 6, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/Export/ExportService.swift"#, count: 3, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/Export/VariantBatchExportService.swift"#, count: 2, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/Knowledge/DocumentTextExtractor.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/MCP/MCPToolHandlers.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/ShotEdit/ShotCompositionService.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/TTS/CloneRegistrationService.swift"#, count: 2, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/TTS/RawAudioCacheStore.swift"#, count: 5, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/TTS/VocalSeparationService.swift"#, count: 7, exempt: false, reason: ""),
    .init(file: #"MixCut/Services/VideoProcessing/FFmpegRunner.swift"#, count: 7, exempt: false, reason: ""),
    .init(file: #"MixCut/Utilities/FileHelper.swift"#, count: 10, exempt: false, reason: ""),
    .init(file: #"MixCut/ViewModels/DubbingViewModel.swift"#, count: 5, exempt: false, reason: ""),
    .init(file: #"MixCut/ViewModels/ImportViewModel.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/ViewModels/SchemeViewModel.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/ViewModels/ShotEditViewModel.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Views/Export/ExportView.swift"#, count: 2, exempt: false, reason: ""),
    .init(file: #"MixCut/Views/Schemes/SchemeDetailView.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Views/SegmentLibrary/BatchExportSheet.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Views/SegmentLibrary/CaptionTimingEditorSheet.swift"#, count: 1, exempt: false, reason: ""),
    .init(file: #"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, count: 2, exempt: false, reason: ""),
    .init(file: #"MixCut/Views/Settings/SettingsView.swift"#, count: 1, exempt: false, reason: ""),
]

/// 素材轴豁免（逐条理由）。批 5 之后这一档应当只剩"删除前先问在不在"那一族 —— 它问的是
/// "要不要动手"，不是"能不能用"，归一是未来的事，本批不动（理由写在这里，不写在代码注释里）。
private let materialExemptions: [MaterialExemption] = [
    .init(file: #"MixCut/Utilities/FileHelper.swift"#, count: 1,
          reason: "`deleteGlobalVideoFiles` 里那句问的是「要不要动手删」，不是「能不能用」——"
              + "语义与可用性轴相反（在才删），归一是未来的事，本批不动它。"
              + "这条登记同时是方案里点名的「未来的归一处」：`Segment.replacedFileExists` 若哪天一起收，"
              + "这张表与 G-M03 的期望值要同批改"),
]

@Suite("素材可用性 · 名册与文案（批 5）")
struct MaterialAvailabilityRosterTests {

    @Test("G-M01 全仓裸问文件的站点必须逐文件等于登记（长出一处即红）")
    func realRepoMatchesProbeRoster() {
        let actual = materialProbeCounts()
        let total = actual.values.reduce(0, +)
        #expect(total > 0, "一个裸问都没取到 ⇒ 取样面失效，下面的相等断言是空的")
        let problems = rosterProblems(actual: actual, recorded: probeRoster)
        #expect(problems.isEmpty, "名册不认账：\(problems)")
    }

    @Test("G-M02 名册的三条刀：新增站点 / 计数被改小 / 豁免缺理由，三种都得报问题")
    func rosterGateIsNotAlwaysGreen() {
        let actual = materialProbeCounts()
        var minusOne = probeRoster
        minusOne.removeFirst()
        #expect(!rosterProblems(actual: actual, recorded: minusOne).isEmpty, "名册少一行却全绿 ⇒ 门恒绿")
        var shrunk = probeRoster
        shrunk[0].count -= 1
        #expect(!rosterProblems(actual: actual, recorded: shrunk).isEmpty, "计数对不上却全绿")
        // ③ 豁免但没写理由 ⇒ 必须叫"判据失效"，不许当通过。
        //    名册今天一条豁免都没有（素材轴的豁免登记在 `materialExemptions` 那张小表里），
        //    所以这颗刀是在**内存副本**上造这个坏态，而不是要求真表里必须留着一条豁免。
        var noReason = probeRoster
        noReason[0].exempt = true
        noReason[0].reason = ""
        #expect(rosterProblems(actual: actual, recorded: noReason)
                .contains { $0.contains("判据失效") }, "豁免没了理由却当通过 ⇒ 欠账挂着")
        // 同一条的正对照：把理由补回去，这条问题就必须消失（否则"判据失效"是恒报，不是咬到了坏态）
        noReason[0].reason = "补回来的理由"
        #expect(!rosterProblems(actual: actual, recorded: noReason)
                .contains { $0.contains("判据失效") }, "有理由的豁免也被报成判据失效 ⇒ 这条刀过咬")
        // 注入腿（不动生产文件）：把一处新裸问当成一份文件喂进同一棵扫描器
        let injected = ["MixCut/Services/__InjectedProbe__.swift": 1]
        var merged = actual
        for (k, v) in injected { merged[k, default: 0] += v }
        #expect(rosterProblems(actual: merged, recorded: probeRoster)
                .contains { $0.contains("__InjectedProbe__") }, "新增一处裸问没被认出 ⇒ 门对增长不敏感")
    }

    @Test("G-M03 素材轴的裸问必须走唯一出口，豁免逐条带理由")
    func materialAxisMustAskTheOneDoor() {
        let got = materialAxisCounts()
        let want = Dictionary(uniqueKeysWithValues: materialExemptions.map { ($0.file, $0.count) })
        #expect(got == want, "素材轴上还有没登记的裸问：实得 \(got.sorted { $0.key < $1.key })，期望 \(want)")
        #expect(materialExemptions.allSatisfy { !$0.reason.isEmpty },
                "有落点没写理由 ⇒ 判据失效（豁免不许当欠账挂着）")
        // 取样面非空：唯一出口本身必须被数到，否则"等于豁免"其实是"等于空"
        #expect(FileHelperDoorUsageCount() >= 8,
                "改问唯一出口的站点少于 8 处 ⇒ 批 5 的收口没落地，G-M03 在测空气")
    }

    @Test("G-M04 缺失文案只有一处定义：旧自造措辞在代码里必须归零")
    func noSelfInventedMissingCopy() {
        // 这四套说法批 5 之前分属四个页面，说的是同一件事。
        //
        // ⚠️ 这颗**必须走原文按行剥注释**，不能走 `codeOnly`：那把尺子连字符串字面量一起抹掉
        // （MAV-08 ④ 量过），拿它查句子内容永远 0 命中 —— 台架第一版就是这样"全绿"的，
        // 是 M9 那把刀把它戳红的。按行切 `//` 之后的部分再比，注释里正当引用旧文案不受影响。
        // 已知假阴面：`/* … */` 块注释里写的自造文案扫不到（本仓散文一律 `//`，写块注释时请连判据一起改）。
        let forbidden = ["找不到原视频文件", "因素材缺失", "找不到源视频", "画面文件缺失"]
        var hits: [(String, String)] = []
        for rel in swiftFilesUnder("MixCut") + swiftFilesUnder("Sources") {
            guard let raw = try? String(contentsOf: availabilityRepoRoot.appendingPathComponent(rel),
                                        encoding: .utf8) else { continue }
            for (i, line) in raw.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for word in forbidden where code.contains(word) {
                    hits.append((rel + ":\(i + 1)", word))
                }
            }
        }
        #expect(hits.isEmpty, "又长出自造的缺失文案：\(hits)")
        // 同管道的正对照：真源本身必须扫得到，否则上面那条 0 命中只证明扫描器瞎了
        let door = FileHelperDoorUsageCount()
        #expect(door >= 8, "改问唯一出口的站点少于 8 处（实得 \(door)）⇒ 正对照没内容可正")
        var copies = 0
        for rel in swiftFilesUnder("MixCut") {
            guard let raw = try? String(contentsOf: availabilityRepoRoot.appendingPathComponent(rel),
                                        encoding: .utf8) else { continue }
            copies += raw.components(separatedBy: "MissingMaterialCopy.").count - 1
        }
        #expect(copies >= 6, "MissingMaterialCopy 的引用点少于 6 处（实得 \(copies)）⇒ 文案真源没被走")
    }

    /// 基线重生成腿（平时不参与判定）：`MEDIA_DUMP_EXISTS_ROSTER=1` 才执行。
    /// 存在的理由与 G08d 同：这张表必须由守卫自己产出，**手写 = 第二份实现，会静默漂移**。
    @Test("G-M05 名册重生成（仅在 MEDIA_DUMP_EXISTS_ROSTER=1 时启用）",
          .enabled(if: ProcessInfo.processInfo.environment["MEDIA_DUMP_EXISTS_ROSTER"] == "1"))
    func dumpRosterForRegeneration() throws {
        let actual = materialProbeCounts()
        let axis = materialAxisCounts()
        var lines: [String] = ["// probeRoster（裸问计数名册，\(actual.values.reduce(0, +)) 处 / \(actual.count) 文件）"]
        for file in actual.keys.sorted() {
            let exempt = axis[file] != nil   // 素材轴上的文件默认不豁免；其余按理由逐条补
            lines.append("    .init(file: #\"\(file)\"#, count: \(actual[file] ?? 0), exempt: \(exempt), reason: \"\"),")
        }
        lines.append("")
        lines.append("// materialExemptions（素材轴豁免，逐条理由）")
        for file in axis.keys.sorted() {
            lines.append("    .init(file: #\"\(file)\"#, count: \(axis[file] ?? 0), reason: \"FILL_ME\"),")
        }
        let out = availabilityRepoRoot.appendingPathComponent(".scratch/material_probe_roster.txt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        Issue.record("已写出 \(out.path)（\(lines.count) 行）⇒ 把两张表粘回源文件后重跑 G-M01/M03")
    }
}

/// 唯一出口 `FileHelper.isMaterialFilePresent` / `materialProbe` 的引用点数（G-M03 的正对照）。
private func FileHelperDoorUsageCount() -> Int {
    var n = 0
    for rel in swiftFilesUnder("MixCut") {
        guard let raw = try? String(contentsOf: availabilityRepoRoot.appendingPathComponent(rel),
                                    encoding: .utf8) else { continue }
        let code = RelationshipReadScan.codeOnly(raw)
        n += code.components(separatedBy: "FileHelper.isMaterialFilePresent(").count - 1
    }
    return n
}

/// 裸问计数（全仓，逐文件）—— 与 `probeRoster` 对齐的就是这一棵。
private func materialProbeCounts() -> [String: Int] {
    var m: [String: Int] = [:]
    for rel in swiftFilesUnder("MixCut") {
        guard let raw = try? String(contentsOf: availabilityRepoRoot.appendingPathComponent(rel),
                                    encoding: .utf8) else {
            Issue.record("\(rel) 读不出来 ⇒ 取样面不全，本条不算通过"); continue
        }
        let n = probeHitCount(RelationshipReadScan.codeOnly(raw))
        if n > 0 { m[rel] = n }
    }
    return m
}

@Suite("素材可用性 · 唯一持有者 / 只报不删 / 过滤只加链尾")
struct MediaAvailabilityGuardTests {

    @Test("MAV-01 结果集只许整体赋值：formUnion 0 处、赋值恰好 1 处")
    func resultSetIsAssignedWholesale() {
        guard let code = codeOnlyOfFile(storeFile) else { return }
        #expect(!code.contains("formUnion("),
                "缺失集被写成并集 ⇒ 一次误判永久留存，放回文件也不自愈")
        let assigns = assignmentCount(code, name: "missingVideoIDs")
        #expect(assigns == 1, "missingVideoIDs 的赋值实得 \(assigns) 处，期望 1 处（多一处就多一个写侧）")
        #expect(code.contains("missingVideoIDs = result.missingIDs"),
                "唯一那处赋值不是整体换成扫描结果 ⇒ 锚点搬错，上面那条计数已在测别的东西")
    }

    @Test("MAV-02 这一层不产生删除：咽喉、真删、删文件三样都不许出现在持有者里")
    func storeNeverDeletes() {
        guard let code = codeOnlyOfFile(storeFile) else { return }
        for forbidden in ["context.delete", "ctx.delete", "PendingDeletionCenter", "removeItem"] {
            #expect(!code.contains(forbidden),
                    "可用性持有者里出现了 \(forbidden) ⇒ 「文件没了」被自动当成「记录删掉」，这条轴的边界已破")
        }
        // 反向对照（同一条扫描管道必须有抓得住东西的时候，否则 0 命中证明不了任何事）
        #expect(code.contains("MissingMaterialFinder.safeMissingIDs("),
                "持有者没调用 Core 的判定 ⇒ 取样面或真源已挪走，上面那三条「不含」是空的")
    }

    @Test("MAV-03 判定只有一个出口：App 层调用 safeMissingIDs 恰好 1 处")
    func judgementHasOneDoor() {
        guard let code = codeOnlyOfFile(storeFile) else { return }
        // 「扫不扫」与「用不用」若各写一份前缀/探针，同一批素材就能得到两个结论（批 5 的
        // 判定唯一出口就是把其余散判也并进这一颗，所以这里钉的是"目前只有一处"）。
        let doors = code.components(separatedBy: "MissingMaterialFinder.safeMissingIDs(").count - 1
        #expect(doors == 1, "App 层判定出口实得 \(doors) 处，期望 1 处 ⇒ 两份判定必然分叉")
    }

    @Test("MAV-04 扫描跑在 nonisolated async 上，不是 Task.detached（取消要能沿链传播）")
    func scanIsNotDetached() {
        guard let code = codeOnlyOfFile(storeFile) else { return }
        #expect(!code.contains("Task.detached"),
                "扫描退回 Task.detached ⇒ 它不继承父任务取消，.task(id:) 取消不了它，「最坏只多跑几条」是假保护")
        #expect(code.contains("nonisolated"),
                "扫描没标 nonisolated ⇒ 它跑在 MainActor 上，161 次 stat 会卡住首屏")
    }

    @Test("MAV-05 对账挂在已有的 .task(id: project.id) 里，不新开任务、不做 LaunchStep")
    func refreshIsHookedOnExistingTask() {
        guard let code = codeOnlyOfFile(importViewFile) else { return }
        guard let body = balancedBody(of: code, head: ".task(id: project.id)") else {
            Issue.record("取不到 .task(id: project.id) 的 body ⇒ 判据失效：挂点被搬走或改名")
            return
        }
        #expect(body.contains("MaterialAvailabilityStore.shared.refresh(for: project)"),
                "对账没挂进这颗已有的 .task ⇒ 界面永远读到空集，「不再显示丢失项」当场失效")
        // 这条腿的取样面必须非空：整颗 .task 里除 refresh 之外还有真东西
        #expect(body.contains("ThumbnailCache.shared.prewarm"),
                ".task body 只剩对账一句 ⇒ 锚点截到的不是原来那颗任务")
    }

    @Test("MAV-06 丢失项过滤只加在链尾：编号先算完，再过滤")
    func missingFilterIsAppliedAtTheTail() {
        guard let code = codeOnlyOfFile(importViewFile) else { return }
        guard let body = balancedBody(of: code, head: "private var numberedVideos:") else {
            Issue.record("取不到 numberedVideos 的计算属性体 ⇒ 判据失效：那颗被改名或拆走")
            return
        }
        // ① 真源那一行原文不许被改写（它是 G08 名册在册的读取点）
        #expect(body.contains("return project.associatedVideos"),
                "`return project.associatedVideos` 不在了 ⇒ 过滤挪到了源头，编号会跟着卡一起前移")
        // ② 顺序：先 sorted（号已定），后 showsMissingVideos 的链尾过滤。
        //    锚点故意不带 `{`：`.sorted {` 与 `.sorted{` 两种写法都合法，带上括号会让一次
        //    无关重排把"顺序判据"退化成"取不出锚点"—— 那声报错是真的，但抓的不是这条不变式。
        switch ordered(body, first: ".sorted", then: "showsMissingVideos") {
        case nil:  Issue.record("sorted 或链尾过滤两个锚点取不出 ⇒ 顺序判据在测空气")
        case .some(true): break
        case .some(false):
            Issue.record("链尾过滤排在 sorted **之前** ⇒ 被藏的丢失项会改变其余视频的 video_no")
        }
        // ③ 过滤这颗只出现一次（两处过滤 = 中间还夹了一份编号口径，那是第二真源的形状）
        let tailFilters = body.components(separatedBy: "showsMissingVideos").count - 1
        #expect(tailFilters == 1, "numberedVideos 体内 showsMissingVideos 实得 \(tailFilters) 处，期望 1 处")
    }

    @Test("MAV-07 启动期的库盘分叉只出声：那条日志不删文件、不藏记录")
    func launchLogIsReportOnly() {
        guard let code = codeOnlyOfFile(appFile) else { return }
        guard let body = balancedBody(of: code, head: "private static func runOrphanGC(") else {
            Issue.record("取不到 runOrphanGC 的函数体 ⇒ 判据失效：GC 入口改名或拆分")
            return
        }
        #expect(body.contains("MaterialAvailabilityStore.missingDivideReading"),
                "启动期不再打库盘分叉 ⇒ 这条轴又回到「取证只能开 sqlite3」")
        for forbidden in ["removeItem", ".delete(", "missingVideoIDs"] {
            #expect(!body.contains(forbidden),
                    "对账日志体内出现 \(forbidden) ⇒ 「只报不删」这条明令已被破")
        }
        // 正向对照：GC 的删除动作确实不在这个体内（它在被调的 collectOrphanFiles 里）
        #expect(body.contains("FileHelper.collectOrphanFiles"),
                "GC 真删动作的落点变了 ⇒ 上面那三条「不含」抓的已经不是这条链")
    }

    @Test("MAV-09 取消与结果都必须出声：竞态那一格要有读数点，不许靠「看起来没反应」猜")
    func cancellationIsObservable() {
        guard let raw = rawOfFile(storeFile) else { return }
        // 两条早退路径各要有一句日志：发起时已取消 / 问完才取消。只留一条的话，真机上分不清
        // "扫描根本没跑"与"跑完但结果被丢了"，而这两种的修法完全不同。
        #expect(logLines(raw, containing: "已取消") >= 2,
                "取消路径的日志读数点少于 2 处 ⇒ E2E 竞态那格没得测")
        #expect(logLines(raw, containing: "本轮问了") == 1,
                "正常路径没打一条「本轮问了 N 条」⇒ 耗时那格没有基准")
        // 可分性正对照：这句话只许出现在日志行里。哪天注释里也写「已取消」，上面那两条计数就
        // 分不清代码与散文了 —— 当场叫出来，而不是悄悄变成恒绿。
        let prose = raw.components(separatedBy: "\n")
            .filter { $0.contains("已取消") && !$0.contains("MixLog.info") }
        #expect(prose.isEmpty, "「已取消」出现在非日志行 ⇒ 上面的计数已不可分：\(prose)")
    }

    @Test("MAV-08 判据自己的牙：赋值/顺序/提取器三种分类都要既咬得住违规也放过合规写法")
    func criteriaHaveTeeth() {
        // ① 整体赋值 vs 并集：同一行只改赋值形状，计数不变而语义已坏 —— 分类必须认出来
        #expect(assignmentCount("{ missingVideoIDs = result.missingIDs }", name: "missingVideoIDs") == 1)
        #expect(assignmentCount("{ missingVideoIDs.formUnion(result.missingIDs) }",
                               name: "missingVideoIDs") == 0,
                "并集写法被算成赋值 ⇒ MAV-01 那条 ==1 会被并集蒙过")
        #expect("formUnion(".contains("formUnion("), "formUnion 探针本身失效")
        // 声明行不许算成赋值（否则 MAV-01 的 ==1 恒不成立，判据天天假红）
        #expect(assignmentCount("var missingVideoIDs: Set<UUID> = []", name: "missingVideoIDs") == 0,
                "把声明算成赋值 ⇒ 计数永远多一处")

        // ② 顺序判据：链尾合规写法绿，源头过滤写法红
        #expect(ordered("{ return project.associatedVideos.filter{ x }.sorted{ $0.no < $1.no }.filter { showsMissingVideos || c } }",
                        first: ".sorted", then: "showsMissingVideos") == .some(true))
        #expect(ordered("{ return project.associatedVideos.filter { showsMissingVideos || c }.sorted{ $0.no < $1.no } }",
                        first: ".sorted", then: "showsMissingVideos") == .some(false),
                "源头过滤这种写法没被判成「顺序错」 ⇒ MAV-06 恒绿")
        #expect(ordered("{ 只有 sorted 一个锚点 .sorted }", first: ".sorted", then: "showsMissingVideos") == nil,
                "缺锚点却返回了结论 ⇒ 提取器会把「搬走的那半」当成通过")

        // ③ 提取器：锚点不存在 / 括号不闭合都不许给出函数体
        #expect(balancedBody(of: "func elsewhere { x }", head: "private static func runOrphanGC(") == nil)
        #expect(balancedBody(of: "private static func runOrphanGC { x", head: "private static func runOrphanGC(") == nil)
        // ③b 锚点必须是**带分隔符的整名**：`private var numberedVideos` 是
        //     `private var numberedVideosRenamed` 的前缀，改名那种变异会照样命中而一声不响
        //     （M4 第一版就被这样放过 —— 取证时跑出来的，不是想出来的）。
        #expect(balancedBody(of: "private var numberedVideosRenamed: [Int] { a }",
                             head: "private var numberedVideos:") == nil,
                "前缀命中被当成锚点命中 ⇒ 改名类变异抓不到，MAV-06 会在错的那份代码上判绿")
        #expect(balancedBody(of: "private var numberedVideos: [Int] { a }",
                             head: "private var numberedVideos:") != nil,
                "整名锚点存在却取不出 ⇒ ③b 那条红是台架自己的错")
        // ④ 共享尺子自己的性质必须被量出来（本轮就被它骗过一次）：`codeOnly` 连**字符串字面量**
        //    一起抹掉，所以"日志里必须写着这句话"这类判据不许走它 —— 走了就永远是 0 命中，
        //    而 0 命中看起来和"确实没有"一模一样。
        #expect(!RelationshipReadScan.codeOnly("MixLog.info(\"已取消\")").contains("已取消"),
                "codeOnly 这次没抹字面量 ⇒ MAV-09 该改用剥注释那颗，把这条与它的注释一起重评")
    }
}
