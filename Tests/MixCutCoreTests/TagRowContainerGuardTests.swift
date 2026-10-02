import Foundation
import Testing
@testable import MixCutCore

/// A3 守卫：标签行**宿主形状**守卫。
///
/// 症状：`HStack { 中文标签 }` 装不下时压的是柔性 Text，中文被压到一字一行 ⇒ 屏幕上像"标签被遮挡"。
/// 同一个形状在这个仓库里已经手工修过三回（`ImportView` 的标签区、素材库网格卡、素材库列表行），
/// 第四处只是等谁来踩。本守卫把"标签住在会换行的容器里"从**我记得**升级成**判据**。
///
/// 判据（批准稿原文）：扫 `MixCut/**/*.swift`，凡 `SemanticTypeTag(` / `PositionTypeTag(` /
/// `QualityBadge(` 出现在既不在 `FlowLayout { }` 内、其调用链又没有 `.lineLimit(...)` 的位置 ⇒ 判红。
/// （批准稿只点名前两个，`QualityBadge` 是同一批同形状的那一颗，一并纳入 —— 名单比承诺宽一档。）
///
/// ⚠️ 两半边**不等价**：`FlowLayout` 是**换行**（标签全见）；调用点 `lineLimit(1)` 只是**不竖排**
/// （窄的时候换成省略号）。判据放过后者，但别把"绿"读成"这样也够了"。
enum TagRowHostScan {
    struct Violation: Equatable {
        let file: String
        let line: Int
        let tag: String
        let host: String
    }

    static let tagNames: Set<String> = ["SemanticTypeTag", "PositionTypeTag", "QualityBadge"]
    /// 会换行的宿主。
    static let wrappingHosts: Set<String> = ["FlowLayout"]
    /// 会把柔性 Text 压扁的宿主。写全 SwiftUI 那一族：只列 `HStack` 等于把 `LazyVStack` 那条路留白。
    static let rigidHosts: Set<String> = ["HStack", "VStack", "ZStack", "LazyVStack", "LazyHStack"]

    /// 剥注释与字符串字面量：**逐字符等长**替换（换行原样保留 ⇒ 行号不漂）。
    /// 不剥就会假红 —— 这三个名字在 `SegmentCardCompact` 的文档注释里以文字形式出现过。
    /// 已知上限：字符串插值 `\(…)` 内部按字面量一起抹掉（本仓库没有"在插值里造标签"的写法）。
    static func codeOnly(_ src: String) -> [Character] {
        let out = Array(src)
        var a = out
        let n = a.count
        enum State { case code, lineComment, blockComment, string, rawString }
        var state: State = .code
        var i = 0
        while i < n {
            switch state {
            case .code:
                if a[i] == "/", i + 1 < n, a[i + 1] == "/" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .lineComment
                } else if a[i] == "/", i + 1 < n, a[i + 1] == "*" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .blockComment
                } else if a[i] == "\"" {
                    if i + 2 < n, a[i + 1] == "\"", a[i + 2] == "\"" {
                        a[i] = " "; a[i + 1] = " "; a[i + 2] = " "; i += 3; state = .rawString
                    } else {
                        a[i] = " "; i += 1; state = .string
                    }
                } else {
                    i += 1
                }
            case .lineComment:
                if a[i] == "\n" { state = .code } else { a[i] = " "; i += 1 }
            case .blockComment:
                if a[i] == "*", i + 1 < n, a[i + 1] == "/" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .code
                } else if a[i] != "\n" {
                    a[i] = " "; i += 1
                } else { i += 1 }
            case .string:
                if a[i] == "\\", i + 1 < n { a[i] = " "; a[i + 1] = " "; i += 2 }
                else if a[i] == "\"" { a[i] = " "; i += 1; state = .code }
                else if a[i] == "\n" { i += 1; state = .code }   // 未闭合的行内串不吞后文
                else { a[i] = " "; i += 1 }
            case .rawString:
                if a[i] == "\"", i + 2 < n, a[i + 1] == "\"", a[i + 2] == "\"" {
                    a[i] = " "; a[i + 1] = " "; a[i + 2] = " "; i += 3; state = .code
                } else { if a[i] != "\n" { a[i] = " " }; i += 1 }
            }
        }
        return a
    }

    /// 扫一份源文本，返回违规调用点。
    ///
    /// 做法：单遍走字符，维护一个**容器栈**（`nil` = 对布局透明的作用域，如 `if { }` / `ForEach { }` /
    /// 任意闭包）。命中容器关键字（可带 `(...)`）且紧跟 `{` 才入栈为具名宿主；其余 `{` 入栈为透明。
    /// 标签调用点的判定看**最内层具名宿主**：`FlowLayout { HStack { 标签 } }` 仍然判红 —— 塌的是最里那层。
    static func scan(file: String, src: String) -> [Violation] {
        let a = codeOnly(src)
        let n = a.count
        var i = 0
        var line = 1
        var stack: [String?] = []
        var out: [Violation] = []

        func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func readIdent(_ at: Int) -> (name: String, end: Int) {
            var j = at
            while j < n, isIdentChar(a[j]) { j += 1 }
            return (String(a[at..<j]), j)
        }
        func skipWS(_ at: Int) -> Int {
            var j = at
            while j < n, a[j] == " " || a[j] == "\t" || a[j] == "\n" || a[j] == "\r" { j += 1 }
            return j
        }
        func skipBalanced(_ at: Int, open: Character, close: Character) -> Int {
            guard at < n, a[at] == open else { return at + 1 }
            var depth = 0, j = at
            while j < n {
                if a[j] == open { depth += 1 }
                else if a[j] == close { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return at + 1
        }
        /// 只看调用点**之后**的修饰链 ⇒ 组件自己 body 里那行 `.lineLimit(1)` 不会漏进来当代替品
        /// （三个标签组件内部今天都写了 `lineLimit(1)`，判据若往定义里看就是恒绿防线）。
        func chainHasLineLimit(after: Int) -> Bool {
            var j = after
            for _ in 0..<64 {
                let k = skipWS(j)
                guard k < n, a[k] == "." else { return false }
                let (name, end) = readIdent(k + 1)
                guard !name.isEmpty else { return false }
                var p = skipWS(end)
                if p < n, a[p] == "(" { p = skipBalanced(p, open: "(", close: ")") }
                else if p < n, a[p] == "{" { p = skipBalanced(p, open: "{", close: "}") }
                if name == "lineLimit" { return true }
                j = p
            }
            return false
        }

        while i < n {
            let c = a[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == "{" { stack.append(nil); i += 1; continue }
            if c == "}" { if !stack.isEmpty { stack.removeLast() }; i += 1; continue }
            if c.isLetter || c == "_" {
                let (name, end) = readIdent(i)
                if tagNames.contains(name) {
                    let p = skipWS(end)
                    if p < n, a[p] == "(" {
                        let close = skipBalanced(p, open: "(", close: ")")
                        let host = stack.compactMap({ $0 }).last
                        let ok = host.map { wrappingHosts.contains($0) } ?? false
                        if !ok, let host, rigidHosts.contains(host),
                           !chainHasLineLimit(after: close) {
                            out.append(Violation(file: file, line: line, tag: name, host: host))
                        }
                        i = end          // 参数内部照常走：标签套标签也要数
                        continue
                    }
                }
                if rigidHosts.contains(name) || wrappingHosts.contains(name) {
                    var q = skipWS(end)
                    if q < n, a[q] == "(" { q = skipBalanced(q, open: "(", close: ")") }
                    q = skipWS(q)
                    if q < n, a[q] == "{" {
                        stack.append(name)
                        i = q + 1        // 已消费这个 "{"
                        continue
                    }
                }
                i = end
                continue
            }
            i += 1
        }
        return out
    }

    /// 只取调用点（不判宿主），用来登记"仓库里今天有几处"。
    static func sites(file: String, src: String) -> [(tag: String, line: Int)] {
        let a = codeOnly(src)
        var line = 1
        var i = 0
        var out: [(String, Int)] = []
        while i < a.count {
            if a[i] == "\n" { line += 1; i += 1; continue }
            if a[i] == "_" || a[i].isLetter {
                let start = i
                while i < a.count, a[i].isLetter || a[i].isNumber || a[i] == "_" { i += 1 }
                if tagNames.contains(String(a[start..<i])) {
                    var j = i
                    while j < a.count, a[j] == " " || a[j] == "\t" { j += 1 }
                    if j < a.count, a[j] == "(" { out.append((String(a[start..<i]), line)) }
                }
                continue
            }
            i += 1
        }
        return out
    }
}

// MARK: - 仓库根与读文件

private let tagRowRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func tagRowRead(_ rel: String) -> String {
    (try? String(contentsOf: tagRowRepoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

private func tagRowFiles(under dir: String) -> [String] {
    let base = tagRowRepoRoot.appendingPathComponent(dir)
    guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
    let prefix = base.path
    let urls = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    return urls.map { url -> String in dir + String(url.path.dropFirst(prefix.count)) }.sorted()
}

private func violations(_ src: String) -> [TagRowHostScan.Violation] {
    TagRowHostScan.scan(file: "fixture", src: src)
}

private func redNames(_ src: String) -> [String] { violations(src).map(\.tag) }

// MARK: - 正反两半边

@Test("正反对照：同一个标签，裸 HStack 判红、FlowLayout 判绿（三个标签名各自一条）")
func hostDecides() {
    let cases: [(String, String)] = [
        ("SemanticTypeTag", "SemanticTypeTag(type: t)"),
        ("PositionTypeTag", "PositionTypeTag(type: t)"),
        ("QualityBadge", "QualityBadge(score: 3)"),
    ]
    for (name, call) in cases {
        #expect(redNames("HStack { \(call) }") == [name], "\(call) 在裸 HStack 里必须判红")
        #expect(violations("FlowLayout { \(call) }").isEmpty, "\(call) 在 FlowLayout 里不该判红")
    }
}

@Test("组件自己 body 里的 lineLimit 不算护身符 —— 否则这条守卫天生恒绿")
func internalLineLimitDoesNotExemptCallSite() {
    let src = """
    struct SemanticTypeTag: View {
        var body: some View {
            Text("开场钩子")
                .lineLimit(1)
                .fixedSize()
        }
    }
    struct Host: View {
        var body: some View {
            HStack { SemanticTypeTag(type: t) }
        }
    }
    """
    let v = violations(src)
    #expect(v.count == 1)
    #expect(v.first?.host == "HStack")
    #expect(v.first?.line == 10, "行号要指到调用点，不是定义那行：\(v.first?.line ?? -1)")
}

@Test("第二半边：调用点 .lineLimit(1) 放过；但只有别的修饰符不放过")
func callSiteLineLimitIsTheSecondEscapeHatch() {
    #expect(violations("HStack { SemanticTypeTag(type: t).lineLimit(1) }").isEmpty)
    #expect(violations("HStack {\n  SemanticTypeTag(type: t)\n    .fixedSize()\n    .lineLimit(1)\n}").isEmpty,
              "多行链上的 .lineLimit 也要认，否则判据锚在单行写法上")
    #expect(redNames("HStack { SemanticTypeTag(type: t).font(.caption2) }") == ["SemanticTypeTag"],
              "有修饰符 ≠ 有 lineLimit")
    #expect(redNames("HStack { SemanticTypeTag(type: t) } ") == ["SemanticTypeTag"])
}

@Test("容器写法不许锚在形状上：多行声明、带参数的裸栈都要判对")
func containerSyntaxVariants() {
    #expect(violations("FlowLayout\n    (spacing: 3)\n{\n    SemanticTypeTag(type: t)\n}").isEmpty)
    #expect(redNames("HStack(alignment: .center, spacing: 8) { SemanticTypeTag(type: t) }") == ["SemanticTypeTag"])
    #expect(redNames("LazyVStack { PositionTypeTag(type: t) }") == ["PositionTypeTag"])
    #expect(redNames("ZStack { QualityBadge(score: 1) }") == ["QualityBadge"])
    // 没有花括号的 HStack 不是宿主（值构造），不能因为出现名字就误判
    #expect(violations("let h = HStack()\nvar body: some View { SemanticTypeTag(type: t) }").isEmpty)
}

@Test("最内层具名宿主说了算：FlowLayout 里再套一层裸 HStack 照样红")
func innermostHostWins() {
    #expect(redNames("FlowLayout { HStack { SemanticTypeTag(type: t) } }") == ["SemanticTypeTag"],
              "塌的是最里那层，外层会换行救不了它")
    #expect(violations("FlowLayout { Group { SemanticTypeTag(type: t) } }").isEmpty)
}

@Test("if / ForEach 这类透明作用域不许打断判定 —— 作用域窄一档就是横扫没做")
func transparentScopesDoNotBreakTheChain() {
    #expect(violations("FlowLayout { ForEach(items, id: \\.self) { SemanticTypeTag(type: $0) } }").isEmpty)
    #expect(redNames("HStack { ForEach(items, id: \\.self) { SemanticTypeTag(type: $0) } }") == ["SemanticTypeTag"])
    #expect(redNames("HStack {\n if flag {\n  PositionTypeTag(type: t)\n }\n}") == ["PositionTypeTag"])
    #expect(redNames("HStack { AnyView(SemanticTypeTag(type: t)) }") == ["SemanticTypeTag"],
              "包一层 AnyView 不算换了宿主")
}

@Test("注释与字符串里的标签名不算调用点；类型声明本身也不算")
func commentsAndDeclarationsAreNotCallSites() {
    #expect(violations("// SemanticTypeTag(type: t) 在注释里\n").isEmpty)
    #expect(violations("/// 见 PositionTypeTag(type: t)\n").isEmpty)
    #expect(violations("/* HStack { QualityBadge(score: 1) } */\n").isEmpty)
    #expect(violations("let s = \"SemanticTypeTag(type: t)\"\n").isEmpty)
    #expect(violations("struct SemanticTypeTag: View { }\n").isEmpty)
    #expect(violations("let factory: (T) -> SemanticTypeTag = { $0 }\n").isEmpty)
}

@Test("藏进局部变量躲不掉：调用点还在裸栈里就判红")
func localBindingDoesNotDodgeTheCallSite() {
    let v = violations("HStack {\n let t = SemanticTypeTag(type: type)\n t.lineLimit(1)\n}")
    #expect(v.count == 1, "调用点被 let 接住也要数到：\(v)")
    #expect(v.first?.line == 2)
}

@Test("已知漏口钉在明处：认不出的容器名一律当透明，这条守卫守不住自定义栈")
func unrecognizedContainerIsTreatedAsTransparent() {
    // 这条「通过」的内容是"这里不承重"：自定义容器要收口就得加进 TagRowHostScan 的两张名单。
    #expect(violations("TagRow { SemanticTypeTag(type: t) }").isEmpty)
    #expect(violations("HStack { SemanticTypeTag(type: t) }").isEmpty == false)
}

// MARK: - 真实仓库

@Test("扫描根与站点基线：MixCut/ 下 8 处调用点、零违规（登记数来自 grep，不是跑出来的）")
func realRepoSitesAreAllWrapped() {
    let files = tagRowFiles(under: "MixCut")
    if files.count < 50 {
        Issue.record("只扫到 \(files.count) 个 .swift，扫描根可能错了 —— 判据本身没跑起来，不算通过")
        return
    }
    var all: [TagRowHostScan.Violation] = []
    var counted: [String: Int] = [:]
    for f in files {
        let src = tagRowRead(f)
        for s in TagRowHostScan.sites(file: f, src: src) { counted[s.tag, default: 0] += 1 }
        all += TagRowHostScan.scan(file: f, src: src)
    }
    #expect(counted["SemanticTypeTag"] == 4, "语义标签调用点数了变了：\(counted)")
    #expect(counted["PositionTypeTag"] == 2)
    #expect(counted["QualityBadge"] == 2)
    #expect(all.isEmpty, "标签行塌成竖排的那一形又回来了：\(all)")
}

@Test("反向对照：把 FlowLayout 全量改名成 HStack，今天这 8 处必须全部翻红")
func renamingTheHostFlipsEveryRealSiteRed() {
    let hosts = ["MixCut/Views/SegmentLibrary/SegmentLibraryView.swift",
                 "MixCut/Views/Shared/SegmentCardCompact.swift",
                 "MixCut/Views/Schemes/SchemeDetailView.swift"]
    var siteTotal = 0, redTotal = 0
    for h in hosts {
        let src = tagRowRead(h)
        let sites = TagRowHostScan.sites(file: h, src: src).count
        let mutated = TagRowHostScan.scan(file: h, src: src.replacingOccurrences(of: "FlowLayout", with: "HStack"))
        siteTotal += sites
        redTotal += mutated.count
        #expect(mutated.count == sites,
                "\(h)：改名后应有 \(sites) 处翻红，实得 \(mutated.count) —— 说明今天这几处的绿并非全靠宿主名字")
    }
    #expect(siteTotal == 8, "三个宿主文件的站点数合计应为 8，实得 \(siteTotal)")
    #expect(redTotal == 8)
}
