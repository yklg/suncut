import Foundation
import Testing

/// 渲染新鲜度守卫。
///
/// 起因（2026-10 复盘）：素材卡片上改标签，标签行不动 —— 数据其实存进去了（重启就对），
/// 断的是"刷新"。两条通道各自断，且**都不报错**：
///
/// * **G2 守缓存通道**：带 `DecodedCache` 的计算属性在 getter 里 `if let cached = box.value { return cached }`
///   短路返回，本次求值完全不碰被跟踪的底层字段 ⇒ SwiftUI 的 Observation 依赖登记不上。
///   而且这不是偶发：`SegmentLibraryViewModel.recomputeAllDerived()` 会无条件遍历全库读
///   `semanticTypes`，卡片首帧之前每个分镜的盒都已经焐热。
/// * **G1 守兜底通道**：`Equatable` 视图的 `==` 里写 `lhs.segment.text == rhs.segment.text`。
///   `Segment` 是 class、同 context 内实例唯一 ⇒ 这是拿一次读数和它自己比，恒真、不承重，
///   但**长得极像一道防线**，于是下一个人会以为"这里已经守过了"。
///
/// 两个判据都做成**吃源码字符串的纯函数**，因此可以用内联 fixture 证明"改前会红"，
/// 而不是对着真文件宣布"扫过了"。锚点一律从结构派生（类的声明、setter 里被赋值的标识符），
/// 不锚 `segment` / `…Data` / `…Cache` 这些名字 —— 改名不是绕过路径。
///
/// ⚠️ 偏移量统一走 **UTF-16**（`NSString`/`NSRegularExpression` 的口径），因为被扫的源码里有中文：
/// `Array(String)` 是字素簇、`NSRange.location` 是 UTF-16 偏移，两者不等，混用会错位。
enum RenderFreshnessScan {

    struct Violation: Equatable {
        let file: String
        let line: Int          // 1-based
        let detail: String
    }

    // MARK: 小工具

    private static func matches(_ pattern: String, in text: String,
                                from: Int = 0, to: Int? = nil) -> [(NSRange, [String])] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let lo = from, hi = min(to ?? ns.length, ns.length)
        guard lo <= hi else { return [] }
        return re.matches(in: text, range: NSRange(location: lo, length: hi - lo)).map { m in
            var gens: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                gens.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            return (m.range, gens)
        }
    }

    private static func lineNumber(_ text: String, at utf16Offset: Int) -> Int {
        let ns = text as NSString
        let limit = min(max(utf16Offset, 0), ns.length)
        var n = 1
        for i in 0..<limit where ns.character(at: i) == 10 { n += 1 }
        return n
    }

    private static let uLBrace: unichar = 123   // {
    private static let uRBrace: unichar = 125   // }
    private static let uSlash: unichar  = 47    // /
    private static let uStar: unichar   = 42    // *
    private static let uQuote: unichar  = 34    // "
    private static let uBS: unichar     = 92    // \

    /// 从 `open` 处的 `{` 找配对的 `}`，返回**内容**区间（UTF-16 偏移，不含花括号）。
    /// 跳过 `//` 行注释、`/* */` 块注释与字符串字面量；不处理三引号块。
    private static func braceBody(_ ns: NSString, open: Int) -> NSRange? {
        var depth = 0
        var i = open
        let n = ns.length
        while i < n {
            let c = ns.character(at: i)
            if c == uSlash, i + 1 < n {
                let nx = ns.character(at: i + 1)
                if nx == uSlash {
                    while i < n, ns.character(at: i) != 10 { i += 1 }
                    continue
                }
                if nx == uStar {
                    i += 2
                    while i + 1 < n, !(ns.character(at: i) == uStar && ns.character(at: i + 1) == uRBrace) { i += 1 }
                    i += 1
                    continue
                }
            }
            if c == uQuote {
                i += 1
                while i < n {
                    let q = ns.character(at: i)
                    if q == uBS { i += 2; continue }
                    if q == uQuote { break }
                    i += 1
                }
            } else if c == uLBrace {
                depth += 1
            } else if c == uRBrace {
                depth -= 1
                if depth == 0 { return NSRange(location: open + 1, length: i - open - 1) }
            }
            i += 1
        }
        return nil
    }

    private static func firstBrace(_ ns: NSString, from: Int) -> Int? {
        var i = from
        while i < ns.length {
            if ns.character(at: i) == uLBrace { return i }
            i += 1
        }
        return nil
    }

    // MARK: 类名收集（G1 用它判断"这个 binding 是不是引用类型"）

    /// 一份源码里声明的所有 class 名（覆盖 `@Model` / `final` / `public` 等前缀写法）。
    static func classTypeNames(in src: String) -> Set<String> {
        Set(matches(#"\bclass\s+([A-Za-z_]\w*)"#, in: src).map { $0.1[0] })
    }

    // MARK: G1 —— `==` 里的恒真自反比较

    /// 扫 `static func == (lhs: T, rhs: T)` 体内所有 `lhs.<引用类型字段>.<路径> == rhs.<同名字段>.<同一路径>`。
    ///
    /// 唯一豁免是路径恰好为 `.id`：它防的是"这张卡被重绑到另一行"，不是恒真。
    static func tautologies(file: String, src: String, classNames: Set<String>) -> [Violation] {
        let ns = src as NSString

        // 1) 每个 struct 的体区间 + 其中类型是 class 的存储属性名
        var structs: [(name: String, body: NSRange, refs: Set<String>)] = []
        for (r, g) in matches(#"\bstruct\s+([A-Za-z_]\w*)"#, in: src) {
            guard let name = g.first, let brace = firstBrace(ns, from: NSMaxRange(r)),
                  let body = braceBody(ns, open: brace) else { continue }
            let region = ns.substring(with: body)
            var refs: Set<String> = []
            for (_, g2) in matches(#"\b(?:let|var)\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)"#, in: region) {
                if g2.count >= 2, classNames.contains(g2[1]) { refs.insert(g2[0]) }
            }
            structs.append((name, body, refs))
        }

        // 2) 每个 == 体，落在哪个 struct 里
        var out: [Violation] = []
        for (r, g) in matches(#"\bstatic func == \(lhs: ([A-Za-z_]\w*), rhs: [A-Za-z_]\w*\)"#, in: src) {
            guard let owner = g.first,
                  let brace = firstBrace(ns, from: NSMaxRange(r)),
                  let body = braceBody(ns, open: brace),
                  let host = structs.first(where: { $0.name == owner && body.location >= $0.body.location
                      && NSMaxRange(body) <= NSMaxRange($0.body) }) else { continue }

            for binding in host.refs.sorted() {
                let b = NSRegularExpression.escapedPattern(for: binding)
                // 组 1 = 字段路径（整条，不是最后一段 —— 重复捕获组只会留最后一次迭代，
                // 所以必须 ((?:…)+) 再包一层，否则 `lhs.a.b.c == rhs.a.b.c` 这种多段路径漏检）；
                // rhs 用 \1 反向引用，保证比的是同一条路径
                let pattern = "lhs\\.\(b)((?:\\??\\.[A-Za-z_]\\w*)+) == rhs\\.\(b)\\1"
                for (mr, mg) in matches(pattern, in: src, from: body.location,
                                        to: NSMaxRange(body)) {
                    let path = mg.first ?? ""
                    let segments = path.components(separatedBy: ".").filter { !$0.isEmpty }
                    if segments == ["id"] { continue }
                    out.append(Violation(
                        file: file,
                        line: lineNumber(src, at: mr.location),
                        detail: "恒真：lhs.\(binding)\(path) == rhs.\(binding)\(path) "
                            + "—— \(binding) 是引用类型且两侧同一个实例，这是拿一次读数和它自己比"))
                }
            }
        }
        return out
    }

    // MARK: G2 —— 缓存 getter 没让返回值依赖底层字段

    /// 找"setter 会写某个存储字段、getter 却按 `box.value` 短路返回"的计算属性，
    /// 要求那条 `if let` 的条件里能追到被写的字段（直接出现，或先 `let v = 字段` 再夹进条件）。
    ///
    /// 丢弃式的 `_ = backingData` **不满足**：它不承重，下一个人会当死码清掉。
    static func unkeyedCachedGetters(file: String, src: String) -> [Violation] {
        let ns = src as NSString
        var out: [Violation] = []

        for (r, g) in matches(#"\bvar\s+([A-Za-z_]\w*)\s*:\s*[^\n{]+\{"#, in: src) {
            guard let propName = g.first,
                  let body = braceBody(ns, open: NSMaxRange(r) - 1) else { continue }
            let propText = ns.substring(with: body)
            guard propText.contains("get"), propText.contains("set") else { continue }

            // setter 里被赋值的裸标识符 = 这个计算属性背后的存储字段
            guard let setBody = subBody(of: "set", in: propText) else { continue }
            var backing: Set<String> = []
            for (_, g2) in matches(#"(?:^|\n)\s*([A-Za-z_]\w*)\s*=[^=]"#, in: setBody) {
                if g2[0] != propName { backing.insert(g2[0]) }
            }
            guard !backing.isEmpty else { continue }

            guard let getBody = subBody(of: "get", in: propText) else { continue }

            for (_, g3) in matches(#"if\s+let\s+[A-Za-z_]\w*\s*=\s*[A-Za-z_]\w*\.value([^{]*)"#, in: getBody) {
                let condition = g3[0]
                if conditionReferences(condition, getter: getBody, backing: backing) { continue }
                out.append(Violation(
                    file: file,
                    line: lineNumber(src, at: r.location),
                    detail: "`\(propName)` 的缓存短路条件 `if let … = ….value\(condition)` 追不到它背后的"
                        + "存储字段 \(backing.sorted()) ⇒ 命中缓存时本次求值完全不碰被跟踪属性，"
                        + "Observation 依赖登记不上（见 Segment.swift DecodedCache 约束 #4）"))
            }
        }
        return out
    }

    /// 条件里是否真的依赖某个被写字段：直接出现，或经由 `let v = 字段` 这一跳。
    private static func conditionReferences(_ condition: String, getter: String,
                                            backing: Set<String>) -> Bool {
        for field in backing {
            let f = NSRegularExpression.escapedPattern(for: field)
            if condition.range(of: "\\b\(f)\\b", options: .regularExpression) != nil { return true }
            // 先算进局部变量再夹进条件：合法，因为那次读确实承重
            for (_, g) in matches(#"\b(?:let|var)\s+([A-Za-z_]\w*)\s*=\s*"# + f + #"\b"#, in: getter) {
                if condition.range(of: "\\b\(g[0])\\b", options: .regularExpression) != nil { return true }
            }
        }
        return false
    }

    /// 取计算属性体里 `get { … }` / `set { … }` 的内容。
    private static func subBody(of keyword: String, in propText: String) -> String? {
        let p = propText as NSString
        guard let r = matches("\\b\(keyword)\\s*\\{", in: propText).first,
              let body = braceBody(p, open: NSMaxRange(r.0) - 1) else { return nil }
        return p.substring(with: body)
    }

    /// 某个 struct 里被识别为**引用类型**的存储属性名。
    /// 恒真判据只在"binding 是 class"时才开火，所以这是 G1 的非空转锚点：
    /// 批 1.2 把真实代码里的恒真删干净之后，`hits` 会是 0 —— 那时唯一能区分
    /// "确实干净" 与 "识别器瞎了" 的，就是这个集合还含着 `segment`。
    static func referenceBindings(structName: String, in src: String, classNames: Set<String>) -> Set<String> {
        let ns = src as NSString
        for (r, g) in matches(#"\bstruct\s+([A-Za-z_]\w*)"#, in: src) {
            guard g.first == structName, let brace = firstBrace(ns, from: NSMaxRange(r)),
                  let body = braceBody(ns, open: brace) else { continue }
            let region = ns.substring(with: body)
            var refs: Set<String> = []
            for (_, g2) in matches(#"\b(?:let|var)\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)"#, in: region) {
                if g2.count >= 2, classNames.contains(g2[1]) { refs.insert(g2[0]) }
            }
            return refs
        }
        return []
    }
    /// 计算属性里"带缓存短路"的个数 —— 供敏感性下限用：扫到 0 说明提取器静默失败，判据失效。
    static func cachedGetterCount(in src: String) -> Int {
        matches(#"\bif\s+let\s+[A-Za-z_]\w*\s*=\s*[A-Za-z_]\w*\.value"#, in: src).count
    }

    static func equalityBodies(in src: String) -> Int {
        matches(#"\bstatic func == \(lhs: "#, in: src).count
    }

    // MARK: G3 —— 遮挡外观只能有一份定义

    /// 遮挡外观的**取值**字面量。注意禁的是值而不是 ffmpeg 的操作名：
    /// `boxblur=` 这种操作名本来就得出现在拼串处，禁它会把正确写法一起抓进来；
    /// 真正会分叉的是 `20` / `1A1A1A` 这些"长什么样"的值。
    static let maskAppearanceValues = ["1A1A1A", "000000@0.5", "boxblur=20"]

    /// 表所在文件（唯一允许出现这些值的地方）
    static let maskSpecTableFile = "Sources/MixCutCore/SubtitleMaskMode.swift"

    /// 扫一份源码里出现遮挡取值的行。跳过整行注释（`//` / `///` 开头）——
    /// 不剥注释会把"解释为什么不能写第二份"的说明行判成违规，那是假红。
    /// 效力上限：行尾注释不剥，写在那儿会误报；误报往安全侧偏（人会把它挪走），漏报才致命。
    static func maskAppearanceOccurrences(file: String, src: String) -> [Violation] {
        if file.hasSuffix(maskSpecTableFile) { return [] }
        var out: [Violation] = []
        for (n, raw) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            for lit in maskAppearanceValues where line.contains(lit) {
                out.append(Violation(file: file, line: n + 1,
                                     detail: "遮挡取值 \(lit) 被写进渲染表之外：\(line.prefix(78))"))
            }
        }
        return out
    }
}

// MARK: - 仓库根与读文件

private let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func read(_ rel: String) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

private func swiftFiles(under dir: String) -> [String] {
    let base = repoRoot.appendingPathComponent(dir)
    guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
    return en.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .map { url in dir + String(url.path.dropFirst(base.path.count)) }
        .sorted()
}

// MARK: - G1

@Test("G1 在真实代码上确实扫到了 == 体与引用类型 binding（敏感性下限，不是恒绿）")
func g1DetectorIsLiveOnRealRepo() {
    let files = swiftFiles(under: "MixCut")
    if files.count < 50 {
        Issue.record("只扫到 \(files.count) 个文件，扫描根可能错了 —— 判据失效，不算通过")
        return
    }
    var joined = ""
    for f in files { joined += read(f) + "\n" }
    let classNames = RenderFreshnessScan.classTypeNames(in: joined)
    #expect(classNames.contains("Segment"), "类名收集失效：没找到 Segment ⇒ G1 会整体空过")
    #expect(classNames.contains("Video"), "类名收集失效：没找到 Video")

    let library = read("MixCut/Views/SegmentLibrary/SegmentLibraryView.swift")
    #expect(RenderFreshnessScan.equalityBodies(in: library) >= 2,
            "没扫到 SegmentCard / SegmentRow 的 == —— 提取器失效，判据空过")
    // 非空转锚点：恒真判据只在 binding 被认成引用类型时开火。批 1.2 之后真实代码里的恒真应为 0，
    // 那时唯一能区分"确实干净"和"识别器瞎了"的就是这一条 —— 它必须仍然认得出 segment 是 class。
    let cardRefs = RenderFreshnessScan.referenceBindings(structName: "SegmentCard", in: library,
                                                          classNames: classNames)
    #expect(cardRefs.contains("segment"),
            "SegmentCard 的 `segment` 没被认成引用类型 binding ⇒ G1 已瞎，下面的 isEmpty 是假绿")
}

@Test("G1 真实代码上不许再有恒真自反比较（批 1.2 已把 SegmentCard.== 那 12 行删掉）")
func g1RatchetOnRealRepo() {
    let files = swiftFiles(under: "MixCut")
    var joined = ""
    for f in files { joined += read(f) + "\n" }
    let classNames = RenderFreshnessScan.classTypeNames(in: joined)

    var hits: [RenderFreshnessScan.Violation] = []
    for f in files { hits += RenderFreshnessScan.tautologies(file: f, src: read(f), classNames: classNames) }

    if !hits.isEmpty {
        let detail = hits.map { "\($0.file):\($0.line) \($0.detail)" }.joined(separator: "\n")
        Issue.record("Equatable 的 == 里出现恒真自反比较（看着像防线、其实一次读数在跟自己比）：\n\(detail)")
    }
}

@Test("G1 能认出恒真自反比较，且对合法的 .id 不误报（正反两半边）")
func g1PositiveAndNegativeHalves() {
    let src = """
    @Model final class Row { var name: String = "" }
    struct Card {
        let row: Row
        let isChecked: Bool
        static func == (lhs: Card, rhs: Card) -> Bool {
            lhs.row.id == rhs.row.id
                && lhs.isChecked == rhs.isChecked
                && lhs.row.name == rhs.row.name
                && lhs.row.parent.kind == rhs.row.parent.kind
        }
    }
    """
    let hits = RenderFreshnessScan.tautologies(file: "x.swift", src: src,
                                               classNames: RenderFreshnessScan.classTypeNames(in: src))
    #expect(hits.count == 2, "应报 name 与 parent.kind 两条，实报 \(hits.map(\.detail))")
    #expect(!hits.contains { $0.detail.contains("lhs.row.id") },
            "`.id` 是显式豁免（防的是行重绑，不是恒真），不该报")

    // 改名对照：binding 与字段都不叫 row/name 了，检出数必须一样
    let renamed = src.replacingOccurrences(of: "row", with: "cell")
                      .replacingOccurrences(of: "name", with: "title")
    let hits2 = RenderFreshnessScan.tautologies(file: "x.swift", src: renamed,
                                                classNames: RenderFreshnessScan.classTypeNames(in: renamed))
    #expect(hits2.count == hits.count, "改名后检出数从 \(hits.count) 变成 \(hits2.count) ⇒ 判据锚在了名字上")

    // 值类型 binding 不该被报
    let valueTyped = src.replacingOccurrences(of: "let row: Row", with: "let row: Int")
    #expect(RenderFreshnessScan.tautologies(file: "x", src: valueTyped,
                                            classNames: RenderFreshnessScan.classTypeNames(in: valueTyped))
                .isEmpty, "binding 不是引用类型时不该报，否则判据太钝")
}

@Test("G2 扫全部模型文件：每颗缓存都得键化，且确实扫到了它们")
func g2OnAllModelFiles() {
    let files = swiftFiles(under: "MixCut/Models")
    if files.count < 5 {
        Issue.record("只扫到 \(files.count) 个模型文件，扫描根可能错了 —— 判据失效，不算通过")
        return
    }

    var totalCached = 0
    var violations: [RenderFreshnessScan.Violation] = []
    for f in files {
        let src = read(f)
        totalCached += RenderFreshnessScan.cachedGetterCount(in: src)
        violations += RenderFreshnessScan.unkeyedCachedGetters(file: f, src: src)
    }

    // 非空转锚点：全 Models 下至少要有 Segment 的 2 颗 + Video 的 3 颗
    #expect(totalCached >= 5, "全模型文件只扫到 \(totalCached) 处缓存短路 ⇒ 提取器静默失败，判据空过")
    let detail = violations.map { "\($0.file):\($0.line) \($0.detail)" }.joined(separator: "\n")
    #expect(violations.isEmpty, "缓存 getter 的短路条件没读底层字段：\n\(detail)")
}

@Test("G2 两种绕法判红、一种合法写法不误伤")
func g2CatchesEveryEscapeRoute() {
    let bare = """
    @Model final class S { var blobData: Data?; var box = Box<[String]>() }
    extension S {
        var tags: [String] {
            get {
                if let cached = box.value { return cached }
                let d = (try? JSONDecoder().decode([String].self, from: blobData ?? Data())) ?? []
                box.value = d; box.key = blobData
                return d
            }
            set { blobData = try? JSONEncoder().encode(newValue); box.value = newValue; box.key = blobData }
        }
    }
    """
    // (a) 完全不碰底层字段 ⇒ 红
    // (b) 丢弃式读一次 ⇒ 也红（不承重，会被下一个人当死码清掉）
    let discard = bare.replacingOccurrences(
        of: "if let cached = box.value { return cached }",
        with: "_ = blobData\n                if let cached = box.value { return cached }")
    // (c) 先算进局部变量再夹进条件 ⇒ 合法（那次读确实承重）
    let hoisted = bare.replacingOccurrences(
        of: "if let cached = box.value { return cached }",
        with: "let now = blobData\n                if let cached = box.value, box.key == now { return cached }")

    #expect(RenderFreshnessScan.unkeyedCachedGetters(file: "f", src: bare).count == 1, "(a) 必须判红")
    #expect(RenderFreshnessScan.unkeyedCachedGetters(file: "f", src: discard).count == 1, "(b) 丢弃式必须判红")
    #expect(RenderFreshnessScan.unkeyedCachedGetters(file: "f", src: hoisted).isEmpty,
            "(c) 键进条件的合格写法被误判 ⇒ 判据太钝，会把人逼回去删注释")

    // 变异未落地 = 测的是空气。先证明三个 fixture 确实只差那一行。
    #expect(bare != discard && bare != hoisted)
}

@Test("G2 不被改名绕过：字段与盒都换掉名字，检出数不变")
func g2SurvivesRenaming() {
    let keyed = """
    @Model final class S { var tagsBlob: Data?; var tagBox = Box<[String]>() }
    extension S {
        var tags: [String] {
            get {
                if let hit = tagBox.value, tagBox.key == tagsBlob { return hit }
                let d = (try? JSONDecoder().decode([String].self, from: tagsBlob ?? Data())) ?? []
                tagBox.value = d; tagBox.key = tagsBlob
                return d
            }
            set { tagsBlob = try? JSONEncoder().encode(newValue); tagBox.value = newValue; tagBox.key = tagsBlob }
        }
    }
    """
    let unkeyed = keyed.replacingOccurrences(of: ", tagBox.key == tagsBlob", with: "")
    #expect(unkeyed != keyed, "变异没落地")
    #expect(RenderFreshnessScan.unkeyedCachedGetters(file: "f", src: keyed).isEmpty)
    #expect(RenderFreshnessScan.unkeyedCachedGetters(file: "f", src: unkeyed).count == 1,
            "改名后判据失效 ⇒ 它锚在了 semanticTypes / …Data 这些名字上")
}

@Test("G2 不误伤没有缓存的计算属性")
func g2IgnoresPlainComputedProperties() {
    let src = """
    @Model final class S { var aX: Double = 0; var aY: Double = 0 }
    extension S {
        var rect: Rect {
            get { Rect(x: aX, y: aY) }
            set { aX = newValue.x; aY = newValue.y }
        }
    }
    """
    #expect(RenderFreshnessScan.unkeyedCachedGetters(file: "f", src: src).isEmpty)
}

// MARK: - G3

@Test("G3 遮挡取值只准住在渲染表里")
func g3MaskAppearanceValuesLiveOnlyInTheTable() {
    var offenders: [RenderFreshnessScan.Violation] = []
    var scanned = 0
    for dir in ["MixCut", "Sources/MixCutCore"] {
        for rel in swiftFiles(under: dir) {
            scanned += 1
            offenders += RenderFreshnessScan.maskAppearanceOccurrences(file: rel, src: read(rel))
        }
    }
    if scanned < 100 {
        Issue.record("只扫到 \(scanned) 个文件，扫描根可能错了 —— 判据失效，不算通过")
    }
    // 非空转锚点：表本身必须真的含这些取值，否则"只准住在表里"是在守一个空集合
    let table = read(RenderFreshnessScan.maskSpecTableFile)
    let inTable = RenderFreshnessScan.maskAppearanceValues.filter { table.contains($0) }
    #expect(inTable.count >= 2,
            "渲染表里只找到 \(inTable) 个待钉取值 ⇒ 表被改空了，G3 会恒绿")

    if !offenders.isEmpty {
        let detail = offenders.map { "\($0.file):\($0.line) \($0.detail)" }.joined(separator: "\n")
        Issue.record("遮挡取值散在渲染表之外（导出与预览会分叉）：\n\(detail)")
    }
}

@Test("G3 正反两半边：抄值回使用方必红，从表取值不误伤")
func g3PositiveAndNegativeHalves() {
    // 负半边 —— 变异必须落地，否则测的是空气
    let copied = """
    parts.append("[mb1]crop=\\(mw):\\(mh),boxblur=20:1[mbb]")
    parts.append("[base]drawbox=color=0x1A1A1A@1.0:t=fill[masked]")
    """
    let copiedHits = RenderFreshnessScan.maskAppearanceOccurrences(file: "a.swift", src: copied)
    #expect(copiedHits.count == 2, "把表里的值抄回拼串处应该被抓到 2 条，实报 \(copiedHits.count)")

    // 正半边 —— 从表里取值的写法（操作名可以出现，取值不行）
    let derived = """
    case .blur(let radius, let power):
        parts.append("[mb1]crop=\\(mw):\\(mh),boxblur=\\(radius):\\(power)[mbb]")
    case .fill(let hex, let alpha):
        parts.append("[base]drawbox=color=0x\\(hex)@\\(alpha):t=fill[masked]")
    """
    #expect(RenderFreshnessScan.maskAppearanceOccurrences(file: "a.swift", src: derived).isEmpty,
            "从表取值的写法被误判 ⇒ 判据太钝，会逼人绕开它")

    // 注释里的说明不算违规（不剥注释会把"解释为什么不能写第二份"判成假红）
    let commentOnly = "// 导出是 0x1A1A1A@1.0 的实色条，别再抄一份到预览层\nlet x = 1"
    #expect(RenderFreshnessScan.maskAppearanceOccurrences(file: "a.swift", src: commentOnly).isEmpty)
}
