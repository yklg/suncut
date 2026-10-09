import Foundation
import Testing

/// 「真删后读死对象」收口计划 §11 的 G08–G12：视图层裸读模型关系守卫 + 真删站点名册对账。
///
/// 守卫目标（计划 §3 刀 5 / §10 P0-2）：`MixCut/Views/**` 里不许再从 **SwiftData 模型对象**上取
/// to-many 关系（含 `@Relationship` 声明的关系与返回模型数组的**计算便捷入口**，如 `Project.videos`）。
/// 本次 SIGTRAP 的直接触发点 `SegmentLibraryView.swift:688` 就是这类读取，且落在 LazyVStack 的
/// measure 热路径上 —— 库里已真删的 `Segment` 被 fault 出来即命中 SwiftData 内部断言。
///
/// 为什么不复用 `BoundaryAdjustUsageScan.codeOnly`：那颗扫描器把**整段字符串（含 `\(...)` 插值内容）**
/// 抹成空格。本守卫要抓的命中里有两条正长在插值里 ——
/// `Text("\(video.segments.count) 分镜")`（ProjectOverviewView）与
/// `"\(segment.schemeSegments.count) 个方案组合"`（SegmentLibraryView）。
/// 直接复用会让这两条**静默消失**，等于把门做成恒绿的一半 ⇒ 这里自带一棵保插值的剥除器，形状照那套状态机。
///
/// 效力上限（写清楚，不当秘密）：
/// - 这是 **token 级**判据，不做类型推断。receiver 三分：① 在全仓被声明为 `@Model` 类型的标识符 ⇒ 命中；
///   ② 被声明为**非模型**类型的标识符（`group`、`viewModel` 等）⇒ 豁免；③ 类型未知者一律**保守计为命中**
///   （keypath `\.segments`、闭包形参 `$0.segments`、ForEach 隐式参数）。
/// - 后果：`VideoSegmentGroup.segments` 这类**同名结构体字段**若以 `$0.` 形式出现会被计入基线
///   （本文件基线里 `LibraryGroupRef(id: $0.id, segmentIDs: $0.segments.map(\.id))` 那条就是）。
///   销账时逐条核，不靠记得。
/// - 拦的是「从模型对象上取关系集合」这**一次读**；已经取到的数组的后续使用不在射程内（那不该由这棵守卫负责）。
enum RelationshipReadScan {

    struct Hit: Hashable, Comparable {
        var file: String        // 相对包根，如 MixCut/Views/...
        var property: String    // 被读到的关系属性名
        var line: String        // 归一化后的整行（去首尾空白、连续空白压成一个空格）

        static func < (l: Hit, r: Hit) -> Bool {
            (l.file, l.property, l.line) < (r.file, r.property, r.line)
        }
    }

    /// 剥注释、保插值的源码化简（逐字符等长替换，保留换行 ⇒ 行号仍对得上原文）。
    static func codeOnly(_ src: String) -> String {
        var a = Array(src)
        let n = a.count
        enum State { case code, lineComment, blockComment, string, rawString, interpolation }
        var state: State = .code
        var parenDepth = 0
        var i = 0
        while i < n {
            let c = a[i]
            switch state {
            case .code:
                if c == "/", i + 1 < n, a[i + 1] == "/" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .lineComment
                } else if c == "/", i + 1 < n, a[i + 1] == "*" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .blockComment
                } else if c == "\"", i + 2 < n, a[i + 1] == "\"", a[i + 2] == "\"" {
                    a[i] = " "; a[i + 1] = " "; a[i + 2] = " "; i += 3; state = .rawString
                } else if c == "\"" {
                    a[i] = " "; i += 1; state = .string
                } else { i += 1 }
            case .lineComment:
                if c == "\n" { state = .code } else { a[i] = " "; i += 1 }
            case .blockComment:
                if c == "*", i + 1 < n, a[i + 1] == "/" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .code
                } else { if c != "\n" { a[i] = " " }; i += 1 }
            case .string:
                if c == "\\", i + 1 < n, a[i + 1] == "(" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .interpolation; parenDepth = 1
                } else if c == "\\", i + 1 < n {
                    a[i] = " "; a[i + 1] = " "; i += 2
                } else if c == "\"" {
                    a[i] = " "; i += 1; state = .code
                } else { if c != "\n" { a[i] = " " }; i += 1 }
            case .rawString:
                if c == "\"", i + 2 < n, a[i + 1] == "\"", a[i + 2] == "\"" {
                    a[i] = " "; a[i + 1] = " "; a[i + 2] = " "; i += 3; state = .code
                } else { if c != "\n" { a[i] = " " }; i += 1 }
            case .interpolation:
                // 插值内容**原样保留**（这正是本守卫与 codeOnly 的分岔处）
                if c == "(" { parenDepth += 1; i += 1 }
                else if c == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 { a[i] = " "; i += 1; state = .string } else { i += 1 }
                } else { i += 1 }
            }
        }
        return String(a)
    }

    static func normalizedLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: 禁词表（两条来源，缺一不可）

    /// `@Model [final] class X` 的类名。
    static func modelTypeNames(modelSources: [(path: String, code: String)]) -> Set<String> {
        var out = Set<String>()
        for (_, code) in modelSources {
            forEachMatch(in: code, pattern: "@Model\\s+(?:final\\s+)?class\\s+([A-Z]\\w*)") { g in
                if let n = g(1) { out.insert(n) }
            }
        }
        return out
    }

    /// 来源一：`@Relationship ...` 声明**的下一行**上的 `var 名字:`。
    static func relationshipNames(modelSources: [(path: String, code: String)]) -> Set<String> {
        var out = Set<String>()
        for (_, code) in modelSources {
            let lines = code.components(separatedBy: "\n")
            for i in lines.indices where lines[i].contains("@Relationship") {
                let next = i + 1 < lines.count ? lines[i + 1] : ""
                if let m = firstMatch(next, pattern: "\\bvar\\s+(\\w+)\\s*:"), let n = m(1) { out.insert(n) }
            }
        }
        return out
    }

    /// 来源二：**任何**返回「模型类型数组」的属性（存储或计算都算）——
    /// 这条来源专门覆盖 `Project.videos` / `associatedVideos` / `orderedSegments` 这类
    /// 没有 `@Relationship` 注解、视图却天天读的计算便捷入口。
    static func arrayModelNames(modelSources: [(path: String, code: String)],
                               modelTypes: Set<String>) -> Set<String> {
        guard !modelTypes.isEmpty else { return [] }
        var out = Set<String>()
        let alt = modelTypes.sorted().joined(separator: "|")
        for (_, code) in modelSources {
            forEachMatch(in: code, pattern: "\\bvar\\s+(\\w+)\\s*:\\s*\\[(" + alt + ")\\]\\??\\s*(=|\\{)") { g in
                if let n = g(1) { out.insert(n) }
            }
        }
        return out
    }

    // MARK: receiver 分类（在全仓源码里被声明成什么类型）

    struct Receivers {
        var model = Set<String>()
        var nonModel = Set<String>()
    }

    /// **逐文件**分类 receiver：`SchemeViewModel.swift:73` 有 `let group: MixStrategy`（模型），
    /// 而 `SegmentLibraryView.swift:617` 的形参是 `_ group: VideoSegmentGroup`（结构体）——
    /// 同名不同物。跨文件汇总会让结构体那个被误判成模型 receiver，所以一颗文件一份表。
    static func classifyReceivers(in code: String, modelTypes: Set<String>) -> Receivers {
        var r = Receivers()
        r.nonModel.insert("self")      // Views 里的 self 永远是视图自己，不是 SwiftData 对象
        let patterns = ["(?:let|var)\\s+(\\w+)\\s*:\\s*([A-Z]\\w*)",
                        "[,(]\\s*(\\w+)\\s*:\\s*([A-Z]\\w*)"]
        for p in patterns {
            forEachMatch(in: code, pattern: p) { g in
                guard let name = g(1), let type = g(2) else { return }
                if modelTypes.contains(type) { r.model.insert(name) } else { r.nonModel.insert(name) }
            }
        }
        forEachMatch(in: code, pattern: "\\bfunc\\s+\\w+\\s*\\(([^)]*)\\)") { g in
            guard let params = g(1) else { return }
            forEachMatch(in: params, pattern: "(\\w+)\\s*:\\s*([A-Z]\\w*)") { pg in
                guard let name = pg(1), let type = pg(2) else { return }
                if modelTypes.contains(type) { r.model.insert(name) } else { r.nonModel.insert(name) }
            }
        }
        return r
    }

    /// receiver 判定：模型声明⇒命中；非模型声明⇒豁免；
    /// 类型未知者：**大写开头且不是模型类名** ⇒ 视为枚举 case / 静态成员（`NavigationItem.schemes`）豁免，
    /// 其余（小写未知、`$N` 闭包形参、`\\.X` keypath）保守计命中——漏抓比多抓危险。
    static func isHitReceiver(_ receiver: String?, receivers: Receivers,
                              modelTypes: Set<String>) -> Bool {
        guard let receiver else { return true }
        if receivers.model.contains(receiver) { return true }
        if receivers.nonModel.contains(receiver) { return false }
        if let first = receiver.first, first.isUppercase, !modelTypes.contains(receiver) { return false }
        return true
    }

    // MARK: 扫描

    static func scan(viewSources: [(path: String, code: String)],
                     forbidden: Set<String>,
                     modelTypes: Set<String>) -> [Hit] {
        guard !forbidden.isEmpty else { return [] }
        let alt = forbidden.sorted().joined(separator: "|")
        let pattern = "(?:\\\\.|\\b(\\w+)|\\$\\d+)\\.(?:\\?|!)?(" + alt + ")\\b"
        var hits: [Hit] = []
        for (path, code) in viewSources {
            let receivers = classifyReceivers(in: code, modelTypes: modelTypes)
            for line in code.components(separatedBy: "\n") {
                forEachMatch(in: line, pattern: pattern) { g in
                    guard isHitReceiver(g(1), receivers: receivers, modelTypes: modelTypes) else { return }
                    guard let prop = g(2) else { return }
                    hits.append(Hit(file: path, property: prop, line: normalizedLine(line)))
                }
            }
        }
        return hits.sorted()
    }

    /// 门 4a 的判定：视图层一处都不该有。返回非空即红。
    static func verdict(_ hits: [Hit]) -> [String] {
        hits.map { "\($0.file) [\($0.property)] \($0.line)" }
    }
}

// MARK: - 门 5：跨 to-one 边界的读取必须过活对象门槛（本案刀 10）

/// 第二起同族崩（2026-10-04，`Project.id.getter` @ `SegmentPickerDrawer.swift:106`）证明：
/// 门 4a 自认的效力上限（`:24`「只拦取关系集合这一次读」+ 计划 §3 刀 5「to-one 读取不拦」）
/// **不是可接受残留，是真实 hazard** —— 穿过一条没有删除规则的 to-one 边再 fault 一个持久标量，
/// 读到的可以是已被真删的对象，同样命中 SwiftData 内部断言（SIGTRAP）。
///
/// 三棵扫描器的分工因此是：门 4a 管「取集合」，门 4b 管「谁在真删」，门 5 管「跨边读」。
///
/// 效力上限（照门 4a 的规矩写死，不当秘密）：
/// - token 级、不做类型推断；receiver 三分沿用 `RelationshipReadScan.classifyReceivers`
///   （实测反例：`SidebarView.swift:160` 的 `let product = …` 是局部量，但**类型未知 ⇒ 保守计命中**，
///   这条与门 4a 同源，销账时逐条核，不靠记得）。
/// - 只管「跨过去之后立刻 fault 成员」这一形；`\.edge` keypath 形态（如 `ForEach(_, id: \.video.id)`）
///   token 级抓不住 ⇒ 那是**已知漏抓**，由允许清单 + 真机 T-0 兜，不许声称门 5 已穷尽。
enum ToOneReadScan {

    /// 门槛 token：同一行里出现过任意一个（词边界匹配，`live` 不许被 `delivery` 撞中）即算过门。
    static let gateTokens = ["live", "isGoneFromGraph", "isDroppedFromContext", "liveSegment"]

    /// 第三来源：`var X: <Model>?` —— **无 `@Relationship`、无删除规则**的裸 to-one 边。
    /// 返回声明条数（含重名，如 `project` 出现在 `ProjectVideo`/`MixScheme`/`MixStrategy` 三处），
    /// 去重后的名字集由调用方再取 —— 两条都要断言（G13）：条数防来源漏扫，名字集防来源跑偏。
    static func toOneEdgeDeclarations(modelSources: [(path: String, code: String)],
                                      modelTypes: Set<String>) -> [(path: String, name: String)] {
        guard !modelTypes.isEmpty else { return [] }
        var out: [(String, String)] = []
        let alt = modelTypes.sorted().joined(separator: "|")
        for (path, code) in modelSources {
            // 行尾用 `\n` 而不是 `$`：NSRegularExpression 默认不开 anchorsMatchLines，
            // `$` 只锚整段末尾 ⇒ 用它会一条都派生不出来（门 5 变恒绿的另一种形态）。
            forEachMatch(in: code,
                         pattern: "\\bvar\\s+(\\w+)\\s*:\\s*(" + alt + ")\\?\\s*(?:\n|[=\\{])") { g in
                if let n = g(1) { out.append((path, n)) }
            }
        }
        return out
    }

    /// 一行的过门判定：**词边界**匹配门槛 token（子串匹配会被 `delivery` / `evaluate` 撞中 ⇒ 假豁免）。
    static func hasGate(_ line: String) -> Bool {
        gateTokens.contains { forEachMatchHas(line, "\\b" + $0 + "\\b") }
    }

    /// 崩形：`receiver.edge?.<成员>` 或 `receiver.edge!.<成员>` —— 跨过一条边再去 fault 持久属性。
    static func scan(viewSources: [(path: String, code: String)],
                     edges: Set<String>,
                     modelTypes: Set<String>) -> [RelationshipReadScan.Hit] {
        guard !edges.isEmpty else { return [] }
        let alt = edges.sorted().joined(separator: "|")
        let pattern = "(?:\\\\\\.|\\b(\\w+)|\\$\\d+)\\.(" + alt + ")\\s*(?:\\?|!)\\s*\\.\\s*\\w"
        var hits: [RelationshipReadScan.Hit] = []
        for (path, code) in viewSources {
            let receivers = RelationshipReadScan.classifyReceivers(in: code, modelTypes: modelTypes)
            for line in code.components(separatedBy: "\n") {
                guard !hasGate(line) else { continue }
                forEachMatch(in: line, pattern: pattern) { g in
                    guard RelationshipReadScan.isHitReceiver(g(1), receivers: receivers,
                                                             modelTypes: modelTypes) else { return }
                    guard let prop = g(2) else { return }
                    hits.append(RelationshipReadScan.Hit(file: path, property: prop,
                                                         line: RelationshipReadScan.normalizedLine(line)))
                }
            }
        }
        return hits.sorted()
    }
}

/// 只问「匹配得到吗」，不复用 enumerateMatches 的闭包（那棵要逐段回调）。
private func forEachMatchHas(_ text: String, _ pattern: String) -> Bool {
    guard let re = regexCache.regex(pattern) else { return false }
    let ns = text as NSString
    return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
}

// MARK: - 正则小工具（NSRegularExpression；\s 与 (?:) 均受支持）

private let regexCache = NSRegexCache()

/// Swift Testing 会**并行**跑用例，而这棵缓存是可变字典 ⇒ 必须上锁。
/// （本仓其它守卫用例都是纯字符串操作，这是第一棵带共享可变状态的扫描器 —— 不加锁会 SIGSEGV，实测过。）
final class NSRegexCache {
    private let lock = NSLock()
    private var store: [String: NSRegularExpression] = [:]
    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = store[pattern] { return hit }
        let made = try? NSRegularExpression(pattern: pattern)
        store[pattern] = made
        return made
    }
}

/// 逐次给出每段匹配的捕获闭包：`g(1)` = 第 1 个捕获组，`g(0)` = 整段。
func forEachMatch(in text: String, pattern: String, _ body: (_ group: (Int) -> String?) -> Void) {
    guard let re = regexCache.regex(pattern) else { return }
    let ns = text as NSString
    re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
        guard let m else { return }
        body({ idx in
            guard idx < m.numberOfRanges else { return nil }
            let r = m.range(at: idx)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r)
        })
    }
}

func firstMatch(_ text: String, pattern: String) -> ((Int) -> String?)? {
    guard let re = regexCache.regex(pattern) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return { idx in
        guard idx < m.numberOfRanges else { return nil }
        let r = m.range(at: idx)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }
}

// MARK: - 仓库根与文件枚举

private let guardRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func swiftFiles(under relative: String) -> [String] {
    let base = guardRepoRoot.appendingPathComponent(relative)
    guard let en = FileManager.default.enumerator(at: base,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
    var out: [String] = []
    for case let url as URL in en where url.pathExtension == "swift" {
        out.append(url.path.replacingOccurrences(of: guardRepoRoot.path + "/", with: ""))
    }
    return out.sorted()
}

private func load(_ path: String) -> String? {
    try? String(contentsOf: guardRepoRoot.appendingPathComponent(path), encoding: .utf8)
}

private func modelSources() -> [(path: String, code: String)] {
    let files = swiftFiles(under: "MixCut/Models")
    let pairs = files.compactMap { p -> (String, String)? in
        guard let s = load(p) else { return nil }
        return (p, RelationshipReadScan.codeOnly(s))
    }
    if pairs.count != files.count { Issue.record("Models 有文件读不出来（\(files.count - pairs.count) 个）⇒ 禁词表不可信") }
    return pairs
}

private func viewSources() -> [(path: String, code: String)] {
    let files = swiftFiles(under: "MixCut/Views")
    let pairs = files.compactMap { p -> (String, String)? in
        guard let s = load(p) else { return nil }
        return (p, RelationshipReadScan.codeOnly(s))
    }
    if pairs.count != files.count { Issue.record("Views 有文件读不出来 ⇒ 取样面不全，本条不算通过") }
    if files.isEmpty { Issue.record("MixCut/Views 扫不到 .swift ⇒ 探针根没命中，本条不算通过") }
    return pairs
}

private func allMixCutSources() -> [(path: String, code: String)] {
    swiftFiles(under: "MixCut").compactMap { p -> (String, String)? in
        guard let s = load(p) else { return nil }
        return (p, RelationshipReadScan.codeOnly(s))
    }
}

/// 真仓扫描的单一入口：判据失效（禁词表空 / 取样面空）在这里当场叫出来，不伪装成通过。
private func realScan() -> [RelationshipReadScan.Hit]? {
    let models = modelSources()
    let types = RelationshipReadScan.modelTypeNames(modelSources: models)
    let forbidden = RelationshipReadScan.relationshipNames(modelSources: models)
        .union(RelationshipReadScan.arrayModelNames(modelSources: models, modelTypes: types))
    if types.isEmpty { Issue.record("取不到任何 @Model 类名 ⇒ 判据失效"); return nil }
    if forbidden.isEmpty { Issue.record("禁词表为空 ⇒ 判据失效"); return nil }
    return RelationshipReadScan.scan(viewSources: viewSources(), forbidden: forbidden, modelTypes: types)
}

// MARK: - G08–G12

struct TombstoneReadGuardTests {

    /// 基线名册（**由本守卫自己生成、非手写** —— 用 `TOMBSTONE_DUMP_BASELINE=1` 跑 G08d 那条腿重生成）：
    /// 45 处 / 43 键 / 12 个文件。
    /// v1.6 刀 1 首批销账：`SegmentLibraryView` 的 3 处 `video.segments` + `DubSettingsBar` 的
    /// `variantCount = video.segments.reduce(…)` 已拔掉；同批新登记 1 处（`$1.segmentDubs` 闭包形参，
    /// 保守命中）⇒ 49 − 5 + 1 = 45。
    /// 逐条 = (文件, 关系属性名, 归一化行, 该组合出现次数)。
    /// 这条名册的用处：**新增一处 ⇒ 红；悄悄拔掉一处 ⇒ 也红**（销账必须同时改这张表，逼一次 review）。
    static let baseline: [(String, String, String, Int)] = [
        (#"MixCut/Views/Export/ExportView.swift"#, "orderedSchemes", #"ForEach(strategy.orderedSchemes) { scheme in"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "orderedSchemes", #"let ids = Set(strategy.orderedSchemes.map(\.id))"#, 2),
        (#"MixCut/Views/Export/ExportView.swift"#, "orderedSchemes", #"let schemeIDs = Set(strategy.orderedSchemes.map(\.id))"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "orderedSchemes", #"let strategySchemeIDs = Set(strategy.orderedSchemes.map(\.id))"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "orderedSegments", #"let badVideo = scheme.orderedSegments.compactMap({ $0.segment?.video })"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "schemeSegments", #"for ss in scheme.schemeSegments where ss.segment?.source == .curated {"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "schemes", #"let total = strategy.schemes.count"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "associatedVideos", #"return project.associatedVideos"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "segments", #"&& video.segments.isEmpty"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "segments", #"for seg in video.segments {"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "segments", #"if !video.segments.isEmpty {"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "videos", #"MixLog.info( Int(Date().timeIntervalSince(t0) * 1000) project.videos.count )"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "videos", #"if project.videos.contains(where: { !$0.isUserUploaded }) {"#, 1),
        (#"MixCut/Views/Import/ImportView.swift"#, "videos", #"let thumbPaths = project.videos.compactMap(\.thumbnailPath)"#, 1),
        (#"MixCut/Views/Overview/ProjectOverviewView.swift"#, "segments", #"Text( video.segments.count )"#, 1),
        (#"MixCut/Views/Schemes/NarrativeStructureEditorView.swift"#, "videos", #"project.videos.flatMap(\.segments).map { seg in"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "orderedSegments", #"ForEach(Array(scheme.orderedSegments.enumerated()), id: \.element.id) { idx, schemeSeg in"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "orderedSegments", #"ForEach(scheme.orderedSegments) { schemeSeg in"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "orderedSegments", #"for ss in scheme.orderedSegments {"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "orderedSegments", #"let types = scheme.orderedSegments.flatMap { $0.segment?.semanticTypes ?? [] }"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "orderedSegments", #"scheme.orderedSegments.map { ss in"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "schemeSegments", #"canDelete: scheme.schemeSegments.count > 1,"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "schemeSegments", #"if let schemeSeg = scheme.schemeSegments.first(where: { $0.id == schemeSegmentID }) {"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "schemeSegments", #"let referencedDubIDs = Set(scheme.schemeSegments.compactMap { $0.selectedSegmentDubId })"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "segmentDubs", #"for d in seg.segmentDubs where d.voiceId != current {"#, 1),
        (#"MixCut/Views/Schemes/SchemeListView.swift"#, "orderedSchemes", #"ForEach(strategy.orderedSchemes) { scheme in"#, 1),
        (#"MixCut/Views/Schemes/SchemeListView.swift"#, "schemes", #"if strategy.isScriptGroup && strategy.schemes.isEmpty {"#, 1),
        (#"MixCut/Views/Schemes/SchemeListView.swift"#, "schemes", #"} else if strategy.isCustomGroup && strategy.schemes.isEmpty {"#, 1),
        (#"MixCut/Views/Schemes/SchemeListView.swift"#, "schemes", #"} else if strategy.isNarrativeTemplate && strategy.schemes.isEmpty {"#, 1),
        (#"MixCut/Views/Schemes/SchemeListView.swift"#, "videos", #"let allSegments = project.videos.flatMap(\.segments)"#, 1),
        (#"MixCut/Views/Schemes/SegmentPickerDrawer.swift"#, "schemeSegments", #"Set(scheme.schemeSegments.compactMap { liveIndex.uuid(for: $0.segment) })"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "schemeSegments", #"ToastCenter.shared.show( segment.schemeSegments.count ,"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "schemeSegments", #"if segment.schemeSegments.isEmpty {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "videos", #"let videoCovers = project.videos.compactMap(\.thumbnailPath)"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"#, "segments", #"let targets = video.segments.filter { $0.id != source.id }"#, 2),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "segmentDubs", #"?? segment.segmentDubs.first { $0.textVariantIndex == t }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "segmentDubs", #"for dub in segment.segmentDubs where !dub.isDroppedFromContext {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "segmentDubs", #"segment.segmentDubs.first { $0.textVariantIndex == t && $0.voiceId == v }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "segmentDubs", #"} else if segment.segmentDubs.isEmpty {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "segments", #"vid.segments.contains(where: { $0.id != segment.id"#, 1),
        (#"MixCut/Views/SegmentLibrary/ShotEditSheet.swift"#, "variants", #"ForEach(shot.variants.sorted { $0.createdAt < $1.createdAt }) { v in"#, 1),
    ]

    private func asMap(_ hits: [RelationshipReadScan.Hit]) -> [String: Int] {
        var m: [String: Int] = [:]
        for h in hits { m["\(h.file)|\(h.property)|\(h.line)", default: 0] += 1 }
        return m
    }

    @Test("G08 真仓敏感性下限：扫描结论必须与基线名册逐条相等（新增与偷拔都拦）")
    func baselineRosterIsReproducedExactly() throws {
        guard let hits = realScan() else { throw GuardError.probeDead }
        #expect(!hits.isEmpty, "真仓一处都没扫到 ⇒ 守卫恒绿，判据失效")
        var want: [String: Int] = [:]
        for (f, p, l, c) in Self.baseline { want["\(f)|\(p)|\(l)"] = c }
        let got = asMap(hits)
        let added = got.keys.filter { (want[$0] ?? 0) != got[$0] }.sorted()
        let removed = want.keys.filter { (got[$0] ?? 0) != want[$0] }.sorted()
        #expect(added.isEmpty, "基线之外多出 \(added.count) 处裸读（或某条计数变了）：\(added.prefix(6))")
        #expect(removed.isEmpty, "基线里有 \(removed.count) 条现在扫不到 —— 销账必须同时改这张表：\(removed.prefix(6))")
        // 崩点复发锁（刀 1 首批销账后改指这里）：原来这条断言是「崩点那一行必须在册」，
        // 现在那一行已被拔掉，若继续断言在册就等于把「已修」判成回归。
        // 改成两半且都承重：① 该文件必须仍有别的命中 ⇒ 证明它确实落在取样面上（不是探针指到空文件）；
        // ② 该文件里 `|segments|` 这一族必须归零 ⇒ 崩点复发即红。
        // 「扫描器认不认得这个形状」由 G08c 的注入腿负责，两条合起来才是完整判据。
        #expect(got.keys.contains { $0.hasPrefix("MixCut/Views/SegmentLibrary/SegmentLibraryView.swift|") },
                "SegmentLibraryView 没有任何命中 ⇒ 取样面没覆盖崩点所在文件，下面的零断言是空的")
        #expect(!got.keys.contains { $0.hasPrefix("MixCut/Views/SegmentLibrary/SegmentLibraryView.swift|segments|") },
                "本次 SIGTRAP 的直接触发点（SegmentLibraryView 读 video.segments）又回来了")
        // 数量锁：实得 43（M2 引入：`SegmentVariantInspector.voices` 段级优先时新增
        // `segmentDubs` 遍历与 `video.segments.contains`（复用可能性判定）两处读取）。
        // ⚠️ 数字**由生成腿读出**（`TOMBSTONE_DUMP_BASELINE=1 swift test --filter dumpBaselineForRegeneration`，
        // 看 `.scratch/guard_baseline_new.txt` 首行 TOTAL_HITS），不是手数。
        #expect(hits.count == 43, "命中总数应为 43（M2 新增 voices 的两处遍历），实得 \(hits.count)")
    }

    @Test("G08c 敏感性变异：往真实取样面里注入一处新裸读，门必须立刻认出来")
    func injectedReadFlipsTheGate() throws {
        guard let hits = realScan(), !hits.isEmpty else { throw GuardError.probeDead }
        let models = modelSources()
        let types = RelationshipReadScan.modelTypeNames(modelSources: models)
        let forbidden = RelationshipReadScan.relationshipNames(modelSources: models)
            .union(RelationshipReadScan.arrayModelNames(modelSources: models, modelTypes: types))
        // 不动生产文件：把注入行当成一份「视图文件」喂给同一棵扫描器
        let injected: [(path: String, code: String)] =
            [(path: "MixCut/Views/__Injected__.swift",
              code: #"private func probe(_ video: Video) -> Set<UUID> { Set(video.segments.map(\.id)) }"#)]
        let after = RelationshipReadScan.scan(viewSources: viewSources() + injected,
                                              forbidden: forbidden, modelTypes: types)
        let added = RelationshipReadScan.verdict(after).filter { $0.contains("__Injected__") }
        #expect(added.count == 1, "注入的裸读没被单独认出（实得 \(added)）⇒ 门对新增不敏感")
        #expect(after.count == hits.count + 1, "注入一处后总数应 +1，实得 \(hits.count) → \(after.count)")
    }

    @Test("G08b 门判定：视图层裸读必须为 0 —— 今天必红，是有意留下的证据")
    func gateVerdictIsRedToday() {
        // 严格 xfail 语义（与仓内「测试暴露缺陷时记 xfail(strict)」同一口径）：
        // 刀 1 落地把这批读取拔掉之后，withKnownIssue 会因为「不再有问题」而**自己变红** ⇒ 逼一次摘标。
        withKnownIssue("门 4a 尚未收口：视图层仍有裸读模型关系，见计划 §3 刀 1 / §11.4 G08") {
            guard let hits = realScan() else { return }
            #expect(RelationshipReadScan.verdict(hits).isEmpty,
                    "仍有 \(hits.count) 处裸读未拔")
        }
    }

    @Test("G09 改名不绕过：模型属性改名、或先赋局部变量再遍历，检出数不变")
    func renamingDoesNotEvade() {
        // 合成一对源码：模型里把关系叫 clips（不叫 segments），视图里 video.clips 必须照样被抓
        let modelsRenamed = [(path: "M/Video.swift", code: """
        @Model final class Video {
            @Relationship(deleteRule: .cascade, inverse: \\Segment.video)
            var clips: [Segment] = []
            var name: String = ""
        }
        """)]
        let modelsOriginal = [(path: "M/Video.swift", code: """
        @Model final class Video {
            @Relationship(deleteRule: .cascade, inverse: \\Segment.video)
            var segments: [Segment] = []
            var name: String = ""
        }
        """)]
        let types = ["Video", "Segment"]
        let viewRenamed = [(path: "V/A.swift", code: "Set(video.clips.map(\\.id))")]
        let viewOriginal = [(path: "V/A.swift", code: "Set(video.segments.map(\\.id))")]
        func count(_ models: [(path: String, code: String)], _ views: [(path: String, code: String)]) -> Int {
            let forb = RelationshipReadScan.relationshipNames(modelSources: models)
                .union(RelationshipReadScan.arrayModelNames(modelSources: models, modelTypes: Set(types)))
            return RelationshipReadScan.scan(viewSources: views, forbidden: forb, modelTypes: Set(types)).count
        }
        #expect(count(modelsOriginal, viewOriginal) == 1, "原名形状必须抓到 1 处")
        #expect(count(modelsRenamed, viewRenamed) == 1, "改名后仍须抓到 1 处 —— 禁词表来自 Models，不靠硬编码")

        // 先赋局部变量再遍历：读取那一行本身就在视图源码里，照样被抓
        let staged = [(path: "V/B.swift", code: "let s = video.segments\n_ = s.map(\\.id)")]
        #expect(count(modelsOriginal, staged) >= 1, "「先算变量再夹一层」不得绕过")
    }

    @Test("G10 正反两半边：非模型 receiver 不误伤，两种绕法判红")
    func positiveAndNegativeHalves() {
        let types = Set(["Video", "Segment"])
        let models = [(path: "M/Video.swift", code: """
        @Model final class Video {
            @Relationship(deleteRule: .cascade, inverse: \\Segment.video)
            var segments: [Segment] = []
        }
        """)]
        let forb = RelationshipReadScan.relationshipNames(modelSources: models)
            .union(RelationshipReadScan.arrayModelNames(modelSources: models, modelTypes: types))
        // 声明面必须与用例同文件（receiver 分类就是逐文件做的）：
        // group 是结构体、viewModel 是 VM，video/segment 才是模型
        let decls = """
        struct Card {
            let video: Video
            let segment: Segment
            let group: VideoSegmentGroup
            let viewModel: SegmentLibraryViewModel
        }
        """
        func scan(_ body: String) -> [String] {
            let one = [(path: "V/Host.swift", code: decls + "\n" + body)]
            return RelationshipReadScan.scan(viewSources: one, forbidden: forb, modelTypes: types).map { $0.line }
        }
        // 负半边（不许误伤）：结构体字段与 VM 数组，同名但都不是模型关系
        let legal = """
        Text("\\(group.segments.count) 个分镜")
        let covers = viewModel.segments.compactMap(\\.thumbnailPath)
        """
        #expect(scan(legal).isEmpty, "同名但非模型的字段被误判：\(scan(legal))")
        // 正半边（三种绕法都要判红）：模型直读、keypath、$N 闭包形参、类型未知的小写 receiver
        #expect(scan("domainIDs: Set(video.segments.map(\\.id)),").count == 1, "模型对象上直读没被抓")
        #expect(scan("let ids = rows.flatMap { $0.segments }").count == 1, "$N 闭包形参形式没被抓")
        #expect(scan("let ids = untypedThing.segments").count == 1, "未知小写 receiver 没被保守计命中")
        // 枚举 case / 静态成员形状（大写且非模型类名）不该算模型读取
        #expect(scan("openItem(NavigationItem.schemes)").isEmpty, "枚举 case 被误判成模型读取")
    }

    @Test("G11 第二来源承重：关掉「返回模型数组的计算属性」⇒ project.videos 那批命中必须归 0")
    func secondSourceCarriesWeight() throws {
        let models = modelSources()
        let types = RelationshipReadScan.modelTypeNames(modelSources: models)
        let fromRelationship = RelationshipReadScan.relationshipNames(modelSources: models)
        let fromArrays = RelationshipReadScan.arrayModelNames(modelSources: models, modelTypes: types)
        // 判据失效先挡住：两条来源各自都必须取到名字
        #expect(!fromRelationship.isEmpty, "来源一（@Relationship）取不到名字 ⇒ 判据失效")
        #expect(!fromArrays.isEmpty, "来源二（模型数组属性）取不到名字 ⇒ 判据失效")
        // 来源二必须独占到几个名字，否则它对全集毫无贡献（恒绿装饰）
        let onlyBySecond = fromArrays.subtracting(fromRelationship)
        #expect(!onlyBySecond.isEmpty,
                "来源二没有独占贡献：关掉它检出不变 ⇒ 它不承重")

        let views = viewSources()
        let full = RelationshipReadScan.scan(viewSources: views,
                                             forbidden: fromRelationship.union(fromArrays),
                                             modelTypes: types)
        let narrow = RelationshipReadScan.scan(viewSources: views,
                                               forbidden: fromRelationship,
                                               modelTypes: types)
        let lost = Set(full.map { "\($0.property)|\($0.line)" }).subtracting(narrow.map { "\($0.property)|\($0.line)" })
        #expect(!lost.isEmpty, "关掉来源二后检出数一条没变 ⇒ 这条来源不承重（P0-2 复发）")
        #expect(lost.contains { $0.hasPrefix("videos|") } || lost.contains { $0.hasPrefix("associatedVideos|") },
                "来源二丢掉的命中里必须包含 project.videos 这一族，实得：\(lost.prefix(8))")
    }

    // MARK: G12 门 4b —— 真删站点名册对账

    struct DeleteRosterEntry {
        var file: String
        var count: Int
        var exempt: Bool
        var reason: String
    }

    /// 对账：文件集或计数与名册不符 ⇒ 报问题；豁免条目缺理由 ⇒ 报「判据失效」。
    static func rosterProblems(actual: [String: Int], recorded: [DeleteRosterEntry]) -> [String] {
        var problems: [String] = []
        var seen: Set<String> = []
        for e in recorded {
            seen.insert(e.file)
            let got = actual[e.file] ?? 0
            if got != e.count {
                problems.append("计数不符 \(e.file)：名册 \(e.count) 实得 \(got)")
            }
            if e.exempt, e.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("判据失效 豁免条目缺理由：\(e.file)")
            }
        }
        for file in actual.keys where !seen.contains(file) {
            problems.append("未登记的新站点：\(file)（\(actual[file] ?? 0) 处）")
        }
        return problems
    }

    /// 名册（v1.4 实测建册 41 条 / 11 文件；v1.8 刀 9 后重算）：删项目收成一颗咽喉之后，
    /// `ProjectViewModel` 与 `MCPToolHandlers` 那 3+3 处**消失**（不是漏登记 —— 是那两份复制粘贴实现没了）；
    /// `DebugSelfTest` 从 9 涨到 21，涨的全是判据矩阵的自检现场（内存/临时容器，不碰用户库）。
    static let deleteRoster: [DeleteRosterEntry] = [
        // W1 分镜生产者收口：合并过短分镜时的 2 处 delete 随 mergeShortSegments 一起
        // 从本文件搬进 SegmentCommitter（下面那行成对登记），总数当时不变。
        // W2 整片保留：重建入口多出**一条**删旧分镜的分支 —— 两条分支各自都得把取消检查放在删除之前
        // （AI 路径要先等模型返回、整片保留路径根本不返回），删除点合不成一处，故 +1 ⇒ 真仓总数 54。
        .init(file: "MixCut/ViewModels/ImportViewModel.swift", count: 9, exempt: false, reason: ""),
        .init(file: "MixCut/Services/Import/SegmentCommitter.swift", count: 2, exempt: false, reason: ""),
        .init(file: "MixCut/ViewModels/SegmentLibraryViewModel.swift", count: 4, exempt: false, reason: ""),
        .init(file: "MixCut/ViewModels/SchemeViewModel.swift", count: 4, exempt: false, reason: ""),
        .init(file: "MixCut/ViewModels/ShotEditViewModel.swift", count: 3, exempt: false, reason: ""),
        .init(file: "MixCut/Services/MCP/MCPSegmentToolHandlers.swift", count: 2, exempt: false, reason: ""),
        // 全局音色：deleteVariant 删改写版本（原有）+ 脚本配音绑定复用分支删被取代空壳（新增）= 2
        .init(file: "MixCut/ViewModels/DubbingViewModel.swift", count: 2, exempt: false, reason: ""),
        .init(file: "MixCut/Views/Schemes/SchemeDetailView.swift", count: 1, exempt: false, reason: ""),
        .init(file: "MixCut/Services/Knowledge/KnowledgeIngestService.swift", count: 1, exempt: false, reason: ""),
        .init(file: "MixCut/ViewModels/ScriptWizardViewModel.swift", count: 2, exempt: false, reason: ""),
        // M2 复刻音色库：删除音色记录（删库记录**不删任何音频文件** —— 已生成配音是自包含的m4a）。
        .init(file: "MixCut/ViewModels/VoiceCloneViewModel.swift", count: 1, exempt: false, reason: ""),
        .init(file: "MixCut/App/MixCutApp.swift", count: 2, exempt: true,
              reason: "启动 fixups 用独立 ModelContext(container)（:353/:397/:426），跑在任何视图建立投影之前"),
        .init(file: "MixCut/App/DebugSelfTest.swift", count: 21, exempt: true,
              reason: "#if DEBUG 自检：自造临时项目/自己的 context（内存容器或临时目录 store），跑在界面接管之前，不碰用户库"),
    ]

    private func actualDeleteCounts() -> [String: Int] {
        var m: [String: Int] = [:]
        let re = regexCache.regex("\\b(?:context|ctx|modelContext)\\.delete\\(")
        for path in swiftFiles(under: "MixCut") {
            guard let raw = load(path), let re else { continue }
            let code = RelationshipReadScan.codeOnly(raw) as NSString
            var c = 0
            re.enumerateMatches(in: code as String, range: NSRange(location: 0, length: code.length)) { _, _, _ in c += 1 }
            if c > 0 { m[path] = c }
        }
        return m
    }

    @Test("G12 名册对账：真仓 54 处 delete 必须逐文件等于登记")
    func realRepoMatchesDeleteRoster() {
        let actual = actualDeleteCounts()
        let total = actual.values.reduce(0, +)
        #expect(total == 54, "真删站点总数应为 54（全局音色 +2、复刻音色库 +1、W2 整片保留分支 +1），实得 \(total) ⇒ 名册或扫描面已漂移")
        let problems = Self.rosterProblems(actual: actual, recorded: Self.deleteRoster)
        #expect(problems.isEmpty, "门 4b 不认账：\(problems)")
    }

    @Test("G12b 反向对照：删一行名册 / 新增一处站点 / 豁免缺理由，三种都得报问题")
    func rosterGateIsNotAlwaysGreen() {
        let actual = actualDeleteCounts()
        // ① 从名册里删一行 ⇒ 必须报「未登记的新站点」
        var minusOne = Self.deleteRoster
        minusOne.removeFirst()
        #expect(!Self.rosterProblems(actual: actual, recorded: minusOne).isEmpty,
                "名册少一行却全绿 ⇒ 门 4b 恒绿")
        // ② 计数被改小 ⇒ 必须报
        var shrunk = Self.deleteRoster
        shrunk[0].count -= 1
        #expect(!Self.rosterProblems(actual: actual, recorded: shrunk).isEmpty,
                "计数对不上却全绿")
        // ③ 豁免条目没写理由 ⇒ 必须判「判据失效」，不能当通过
        // （按属性定位第一条豁免，不数下标：名册会随收口增删行，硬编码下标早晚会指错行甚至越界）
        var noReason = Self.deleteRoster
        guard let exempt = noReason.firstIndex(where: \.exempt) else {
            Issue.record("名册里一条豁免都没有 ⇒ 这条反向对照失效了")
            return
        }
        noReason[exempt].reason = ""
        let problems = Self.rosterProblems(actual: actual, recorded: noReason)
        #expect(problems.contains { $0.contains("判据失效") }, "豁免缺理由却没报错：\(problems)")
        // ④ 正向对照：完整名册必须返回空（否则前三条是恒红不是恒绿）
        #expect(Self.rosterProblems(actual: actual, recorded: Self.deleteRoster).isEmpty)
    }

    /// 门 4b 的补格（G18）。刀 9 把删项目收成一颗咽喉后，咽喉内部写的是**裸 `delete(...)`**
    /// （它就在 `extension ModelContext` 里，写 `self.delete(...)` 反而啰嗦），
    /// 而门 4b 的 regex 只认 `context|ctx|modelContext.delete(` ⇒ 这几处真删落在扫描面之外。
    /// 不补这一格，就等于"把 6 处站点悄悄挪出名册"——正是这条守卫存在的理由要防的事。
    static let throatDeleteRoster: [(line: String, count: Int, why: String)] = [
        ("for object in Array(objects) { delete(object) }", 1,
         "Sequence 重载：先 Array 快照再逐个删，这条就是它存在的意义"),
        ("delete(project)", 1, "咽喉第③步：真删项目（级联带走 ProjectVideo/MixStrategy/MixScheme/SchemeSegment）"),
        ("delete(segments)", 1, "补删无引用视频的整段分镜（走同一条 Sequence 重载）。上游是 "
         + "`let segments = Array(video.segments)`：先快照**再**记 id、再删 —— 因为 `noteDeleted` 要的 id "
         + "必须在对象真删之前取，删完再读 `video.segments` 就是死对象读数"),
        ("delete(video)", 1, "补删没有任何其它引用的 Video 本体"),
    ]

    @Test("G18 咽喉内的裸 delete 落点必须逐条登记（门 4b 的 regex 看不见它们）")
    func bareDeletesInsideTheThroatAreRostered() throws {
        let path = "MixCut/Utilities/ModelContextExtension.swift"
        guard let raw = load(path) else { throw GuardError.probeDead }
        var got: [String: Int] = [:]
        for line in RelationshipReadScan.codeOnly(raw).components(separatedBy: "\n") {
            forEachMatch(in: line, pattern: "(?:^|[^.\\w])delete\\(") { _ in
                got[RelationshipReadScan.normalizedLine(line), default: 0] += 1
            }
        }
        let want = Dictionary(uniqueKeysWithValues: Self.throatDeleteRoster.map { ($0.line, $0.count) })
        #expect(got == want, "咽喉内的裸 delete 与登记不符：实得 \(got.sorted { $0.key < $1.key })")
        #expect(Self.throatDeleteRoster.allSatisfy { !$0.why.isEmpty },
                "有落点没写理由 ⇒ 判据失效（豁免不许当欠账挂着）")
    }

    /// 基线重生成腿（销账用，平时不参与判定）：`TOMBSTONE_DUMP_BASELINE=1 swift test --filter TombstoneReadGuardTests`
    /// 才执行，把当前扫描结果按本表格式写进 `.scratch/guard_baseline_new.txt`。
    /// 存在的理由：这张表必须由守卫自己产出，**不许手写**（手写=第二份实现，会静默漂移）。
    @Test("G08d 基线重生成（仅在 TOMBSTONE_DUMP_BASELINE=1 时启用）",
          .enabled(if: ProcessInfo.processInfo.environment["TOMBSTONE_DUMP_BASELINE"] == "1"))
    func dumpBaselineForRegeneration() throws {
        guard let hits = realScan(), !hits.isEmpty else { throw GuardError.probeDead }
        var counts: [String: Int] = [:]
        for h in hits { counts["\(h.file)|\(h.property)|\(h.line)", default: 0] += 1 }
        var out = "TOTAL_HITS=\(hits.count) KEYS=\(counts.count) FILES=\(Set(hits.map { $0.file }).count)\n"
        for key in counts.keys.sorted() {
            let parts = key.components(separatedBy: "|")
            out += "        (#\"\(parts[0])\"#, \"\(parts[1])\", #\"\(parts[2])\"#, \(counts[key]!)),\n"
        }
        let url = guardRepoRoot.appendingPathComponent(".scratch/guard_baseline_new.txt")
        try Data(out.utf8).write(to: url)
    }

    // MARK: 门 5（G13–G17）· 跨 to-one 边界的读取必须过活对象门槛

    /// 门 5 存量名册（**由 G17d 生成、不手写** —— 手写=第二份实现，会静默漂移）。
    /// 实测读数：**43 处 / 41 键 / 12 个文件**（`TOMBSTONE_DUMP_TOONE=1` 跑出来的，不是我估的）。
    /// ⚠️ 计划 §3 决策 3 与 §17.3 原先记的「宽口径 40 处 / 12 文件」是我用 grep 人工数的，**以本表为准**：
    ///    差在扫描器会把同一行内的多处跨边与各跨边成员都算上（如 ShotEditSheet 两行同样的 `segment.video?.fps`）。
    /// 逐条 = (文件, 被跨的边名, 归一化行, 该组合出现次数)。新增一处⇒红；悄悄拔掉一处不改表⇒也红。
    static let toOneBaseline: [(String, String, String, Int)] = [
        (#"MixCut/Views/Export/ExportView.swift"#, "segment", #"for ss in scheme.schemeSegments where ss.segment?.source == .curated {"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "segment", #"if let sid = ss.segment?.id { ids.insert(sid) }"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "segment", #"let badVideo = scheme.orderedSegments.compactMap({ $0.segment?.video })"#, 1),
        (#"MixCut/Views/Export/ExportView.swift"#, "strategy", #"let strategyName = scheme.strategy?.name ??"#, 2),
        (#"MixCut/Views/Overview/WelcomeView.swift"#, "product", #".help( project.name project.product?.name ?? ProductCatalogDefaults.defaultProductName )"#, 1),
        (#"MixCut/Views/Overview/WelcomeView.swift"#, "product", #"Text(project.product?.name ?? ProductCatalogDefaults.defaultProductName)"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "segment", #"let originalTypes = schemeSeg.segment?.semanticTypes ?? []"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "segment", #"let types = scheme.orderedSegments.flatMap { $0.segment?.semanticTypes ?? [] }"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "segment", #"return schemeSeg.segment?.effectiveDubVariants.first { $0.id == id }"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "video", #"guard let seg = ss.segment, let current = seg.video?.clonedVoiceId else { continue }"#, 1),
        (#"MixCut/Views/Schemes/SchemeDetailView.swift"#, "video", #"private var fps: Double { segment.video?.fps ?? 30 }"#, 1),
        (#"MixCut/Views/SegmentLibrary/CaptionTimingEditorSheet.swift"#, "segment", #"private var segDuration: Double { dub.segment?.duration ?? 0 }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "video", #"if let hash = segment.video?.contentHash {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "video", #"if let videoPath = segment.video?.localPath, !videoPath.isEmpty {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "video", #"if segment.video?.isUserUploaded == true,"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "video", #"let fps = segment.video?.fps ?? 0"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"#, "video", #"let st = segment.video?.status, st != .completed, st != .failed {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"#, "video", #"private var fps: Double { segment.video?.fps ?? 30 }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"if !dubVM.isBusy(videoID: segment.video?.id) {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"if dubVM.isBusy(videoID: segment.video?.id) {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"if dubVM.isBusy(videoID: segment.video?.id), let vid = segment.video?.id {"#, 2),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"if id == segment.video?.clonedVoiceId { return }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"if let vid = segment.video?.id {"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"out = (segment.video?.selectedVoiceIds ?? []).filter { !$0.isEmpty }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"#, "video", #"} else if !dubVM.isBusy(videoID: segment.video?.id) {"#, 1),
        (#"MixCut/Views/SegmentLibrary/ShotEditSheet.swift"#, "video", #"private var fps: Double { segment.video?.fps ?? 30 }"#, 2),
        (#"MixCut/Views/SegmentLibrary/ShotEditSheet.swift"#, "video", #"private var srcPath: String { segment.video?.localPath ?? }"#, 1),
        (#"MixCut/Views/SegmentLibrary/ShotEditSheet.swift"#, "video", #"videoPath: segment.video?.localPath ?? ,"#, 1),
        (#"MixCut/Views/SegmentLibrary/SplitSegmentSheet.swift"#, "video", #"guard let path = segment.video?.localPath else { return }"#, 1),
        (#"MixCut/Views/SegmentLibrary/SplitSegmentSheet.swift"#, "video", #"let f = segment.video?.fps ?? 30"#, 1),
        (#"MixCut/Views/Shared/ProductPresentation.swift"#, "product", #"Text(project.product?.name ?? ProductCatalogDefaults.defaultProductName)"#, 1),
        (#"MixCut/Views/Sidebar/SidebarView.swift"#, "product", #"Text(project.product?.name ?? ProductCatalogDefaults.defaultProductName)"#, 1),
    ]

    /// 门 5 的真仓扫描入口。判据失效（边名集为空 / 取样面为空）在这里当场叫出来，不伪装成通过。
    private func realToOneScan() -> [RelationshipReadScan.Hit]? {
        let models = modelSources()
        let types = RelationshipReadScan.modelTypeNames(modelSources: models)
        let edges = Set(ToOneReadScan.toOneEdgeDeclarations(modelSources: models, modelTypes: types).map(\.name))
        if types.isEmpty { Issue.record("取不到任何 @Model 类名 ⇒ 门 5 判据失效"); return nil }
        if edges.isEmpty { Issue.record("一条 to-one 边都没派生出来 ⇒ 第三来源跑偏，门 5 恒绿"); return nil }
        return ToOneReadScan.scan(viewSources: viewSources(), edges: edges, modelTypes: types)
    }

    @Test("G13 第三来源承重：to-one 边必须派生出 20 条声明 / 13 个名字，且名单逐条对得上（v3.4 含知识库+脚本 7 条新边）")
    func toOneEdgeSourceIsLoaded() {
        let models = modelSources()
        let types = RelationshipReadScan.modelTypeNames(modelSources: models)
        let decls = ToOneReadScan.toOneEdgeDeclarations(modelSources: models, modelTypes: types)
        let names = Set(decls.map(\.name))
        // 条数与去重名数**两条都要断言**：只断名集会漏掉「同一名字多挂一处」那条边（project 就有三个宿主）。
        #expect(decls.count == 20, "to-one 边声明应为 20 条，实得 \(decls.count) ⇒ 来源漏扫或模型层新增了边没登记")
        #expect(names == ["document", "matchedSegment", "ownerProject", "parentSegment",
                          "product", "project", "realizedScheme", "scheme", "script",
                          "segment", "shot", "strategy", "video"],
                "边名集合与实测锚定不符：\(names.sorted())")
    }

    @Test("G14 门 5 敏感性：注入崩形必须认得，过门写法不许误伤（正反两半边）")
    func toOneGateIsSensitiveBothWays() throws {
        let models = modelSources()
        let types = RelationshipReadScan.modelTypeNames(modelSources: models)
        let edges = Set(ToOneReadScan.toOneEdgeDeclarations(modelSources: models, modelTypes: types).map(\.name))
        guard !edges.isEmpty else { throw GuardError.probeDead }

        // 正半边：崩点那一形的最小复现（本案 SegmentPickerDrawer.swift:106）
        let bad: [(path: String, code: String)] =
            [(path: "MixCut/Views/__Injected_ToOne__.swift",
              code: #"self.catalogVideos = videos.map { CatalogVideo(id: $0.id, ownerProjectID: $0.ownerProject?.id) }"#)]
        let hitsBad = ToOneReadScan.scan(viewSources: bad, edges: edges, modelTypes: types)
        #expect(hitsBad.count == 1, "本案崩形没被抓到 ⇒ 门 5 恒绿：\(ToOneReadScan.scan(viewSources: bad, edges: edges, modelTypes: types).map(\.line))")

        // 反半边一：过门写法（刀 8 的目标形态）不许算命中
        let gated: [(path: String, code: String)] =
            [(path: "MixCut/Views/__Injected_Gated__.swift",
              code: #"self.catalogVideos = videos.map { CatalogVideo(id: $0.id, ownerProjectID: $0.ownerProject.live?.id) }"#)]
        #expect(ToOneReadScan.scan(viewSources: gated, edges: edges, modelTypes: types).isEmpty,
                "过门写法被误判成裸跨 ⇒ 门 5 会把正确改法也拦掉，落地时必被绕过")

        // 反半边二：门槛判据本身（`video?.isDroppedFromContext`）不能被自己的规则拦成违规
        // —— 这是 SegmentLibraryView.swift:622 今天真实在写的形态。
        let predicate: [(path: String, code: String)] =
            [(path: "MixCut/Views/__Injected_Pred__.swift",
              code: "if group.video?.isDroppedFromContext == true { Color.clear }")]
        #expect(ToOneReadScan.scan(viewSources: predicate, edges: edges, modelTypes: types).isEmpty,
                "门槛判据自身被门 5 判红 ⇒ 判据与门槛互相打架")
    }

    @Test("G15 门 5 名册对账：未过门的跨边读取必须与基线逐条相等")
    func toOneBaselineIsReproducedExactly() throws {
        guard let hits = realToOneScan() else { throw GuardError.probeDead }
        var want: [String: Int] = [:]
        for (f, p, l, c) in Self.toOneBaseline { want["\(f)|\(p)|\(l)"] = c }
        var got: [String: Int] = [:]
        for h in hits { got["\(h.file)|\(h.property)|\(h.line)", default: 0] += 1 }
        let added = got.keys.filter { (want[$0] ?? 0) != got[$0] }.sorted()
        let removed = want.keys.filter { (got[$0] ?? 0) != want[$0] }.sorted()
        #expect(added.isEmpty, "基线之外多出 \(added.count) 处未过门的跨边读取：\(added.prefix(6))")
        #expect(removed.isEmpty, "基线里有 \(removed.count) 条现在扫不到 —— 销账必须同时改这张表：\(removed.prefix(6))")
    }

    @Test("G15b 门 5 判定：视图层未过门的跨边读取必须为 0 —— 今天必红，是有意留下的证据")
    func toOneGateVerdictIsRedToday() {
        // 与 G08b 同一口径的 strict-xfail：刀 8 把这批读取改完，这条会因「不再有问题」自己变红 ⇒ 逼一次摘标。
        withKnownIssue("门 5 尚未收口：视图层仍有跨 to-one 边未过门的读取，见计划 §17.4 TC-T01/T03") {
            guard let hits = realToOneScan() else { return }
            #expect(hits.isEmpty, "仍有 \(hits.count) 处未过门的跨边读取")
        }
    }

    /// 产出型路径里所有 `?? UUID()` 兜底的实测读数（G16 / G16b 共用一棵扫描，不各扫一遍）。
    private func randomUUIDFallbacks() -> Set<String> {
        let faces = ["MixCut/Services/", "MixCut/ViewModels/", "MixCut/Utilities/", "MixCut/Views/Export/"]
        return Set(allMixCutSources()
            .filter { (pair) in faces.contains { (f: String) in pair.path.hasPrefix(f) } }
            .flatMap { (pair) -> [String] in
                pair.code.components(separatedBy: "\n")
                    .filter { forEachMatchHas($0, "\\?\\?\\s*UUID\\(\\)") }
                    .map { "\(pair.path): \(RelationshipReadScan.normalizedLine($0))" }
            })
    }

    /// 已经拆掉的 4 处**归属 / 分组键**随机兜底（本案 P0）。钉住原文，改回去即红。
    static let deadRandomAttributionKeys: [(file: String, line: String)] = [
        ("MixCut/Services/MCP/MCPSegmentToolHandlers.swift",
         "let projectID: UUID = segments.first?.video?.projectVideos.first?.project?.id ?? UUID()"),
        ("MixCut/Services/MCP/MCPSegmentToolHandlers.swift",
         "let projectID: UUID = eligible.first?.video?.projectVideos.first?.project?.id ?? UUID()"),
        ("MixCut/Services/MCP/MCPSegmentToolHandlers.swift",
         "let byVideo = Dictionary(grouping: eligible, by: { $0.video?.id ?? UUID() })"),
        ("MixCut/Services/MCP/MCPToolHandlers.swift",
         "let job = jobs.begin(kind: .exportScheme, projectID: projectID ?? UUID())"),
    ]

    @Test("G16 归属/分组键的随机 UUID 兜底必须拆干净（旧范式残留=0，改回去即红）")
    func attributionRandomFallbacksStayRemoved() {
        // 为什么这条比"崩"更该守：门槛把读不到变成 nil 之后，`?? UUID()` 会把一次 SIGTRAP
        // 换成「job 归属键 / 导出分组键是一个不存在或不随机的 UUID」—— 静默错数据不会拦住任何人。
        let live = randomUUIDFallbacks()
        for dead in Self.deadRandomAttributionKeys {
            let key = "\(dead.file): \(dead.line)"
            #expect(!live.contains(key), "随机归属键兜底又回来了 ⇒ 会张冠李戴：\(key)")
        }
        // 锚点清单自身也要承重：缩成空表 = 这条门恒绿
        #expect(Self.deadRandomAttributionKeys.count == 4,
                "归属键锚点清单应为 4 条，实得 \(Self.deadRandomAttributionKeys.count)")
    }

    @Test("G16b 随机兜底名册对账：剩余每条必须登记带理由 —— 新增一处即红")
    func randomFallbackRosterIsReproducedExactly() {
        let got = randomUUIDFallbacks()
        let want = Set(Self.randomFallbackRoster.map(\.line))
        #expect(got == want, "随机兜底与名册不符：未认领的新增 \(got.subtracting(want).sorted())；已被拆掉的 \(want.subtracting(got).sorted())")
        #expect(Self.randomFallbackRoster.allSatisfy { !$0.reason.isEmpty },
                "有兜底条目没写理由 ⇒ 判据失效（豁免不许当欠账挂着）")
    }

    /// 仍在仓里的随机 UUID 兜底（逐条认领）。归属/分组键那 4 条已拆，见 `deadRandomAttributionKeys`。
    static let randomFallbackRoster: [(line: String, reason: String)] = [
        (#"MixCut/ViewModels/ImportViewModel.swift: guard let destURL = try? FileHelper.copyVideoToGlobal(from: url, contentHash: hash ?? UUID().uuidString) else {"#,
          "P2：contentHash 缺失时的唯一性占位，**不是**归属/分组键；是否改成「跳过并上报」另案 review"),
    ]

    @Test("G17 锚点防呆：readiness / prewarm 那 5 处必须逐字不变（不许被顺手改成门后取值）")
    func readinessAndPrewarmAnchorsStayUntouched() {
        // 那两处输入**已经是 UUID 值**，过门只会把「能不能点 / 预热键」变成可 nil ⇒ 语义漂移；
        // 且 shell 门是按处数逐字锚的（check_navigation_readiness_guards.sh:106/:140），改了就双红。
        let views = viewSources()
        /// 按**整段代码**数（不是按行）：`prewarm(paths:` 与 `for: project.id` 可能跨行，按行数会漏。
        func count(_ pattern: String) -> Int {
            var n = 0
            for pair in views {
                forEachMatch(in: pair.code, pattern: pattern) { _ in n += 1 }
            }
            return n
        }
        #expect(count(#"allowsHitTesting\([\s\S]{0,120}?readiness\.holdsData\(for: project\.id\)"#) == 2,
                "readiness 禁点锚点处数变了（应为 2：SegmentLibraryView:39 / ProjectOverviewView:33）")
        #expect(count(#"prewarm\(paths:[\s\S]{0,240}?for: project\.id\)"#) == 3,
                "prewarm 锚点处数变了（应为 3：SegmentLibraryView:56 / ProjectOverviewView:38 / ImportView:35）")
    }

    @Test("G19 唯一发布口：.mixCutDataDidUndo 的直接 post 只许存在于 GraphBroadcast 体内（1 处）")
    func graphChangeChannelHasSinglePublisher() {
        // 为什么钉这条：刀 2 的全部价值在于「剪枝 / 重入闸 / 降级」三条规则只写一遍。
        // 只要再出现一处手写 `NotificationCenter.post(name: .mixCutDataDidUndo…)`，
        // 它就绕过了重入闸（同栈递归，前案 §10 健壮-1 P0）或绕过了载荷降级 ⇒ 三条规则变成三条运气。
        var posts: [String] = []
        for pair in allMixCutSources() {
            for (idx, raw) in pair.code.components(separatedBy: "\n").enumerated()
            where forEachMatchHas(raw, "\\.post\\(name:\\s*\\.mixCutDataDidUndo") {
                posts.append("\(pair.path):\(idx + 1) \(RelationshipReadScan.normalizedLine(raw))")
            }
        }
        #expect(posts.count == 1,
                "发布口不唯一 ⇒ 剪枝/重入闸/降级会被绕过：\(posts.sorted())")
        let head = posts.first ?? ""
        #expect(head.hasPrefix("MixCut/App/ContentView.swift:") && head.contains("object: payload"),
                "唯一那处 post 必须是 GraphBroadcast 里的 `object: payload`，实得：\(head)")

        // 消费口只许 4 处，且身份钉死（匹配三种合法订阅写法）：
        //  - ContentView.onReceive：publisher(for:)，剪枝/全量重载（第一消费者）；
        //  - DebugSelfTest：block 式 addObserver(forName:) 自检探针；
        //  - DubbingViewModel：target-action addObserver(name:)，只做「数据真删 → 取消作业」，
        //    禁止 load/flush（职责边界由 DubbingTaskOwnershipGuardTests G4 另钉）；
        //  - ScriptWizardViewModel（M4/W3）：target-action + nonisolated Task hop，
        //    做「已锁定分镜真删 → 场景回退 unmatched」；回退纯判据在 Core ScriptMatchRepair，
        //    fetch/save 发生在 hop 出 post 同步栈之后（由 check_script_pipeline_guards G-S4 钉 hop）。
        // selector 形态必须带 selector: 前缀锚定，否则会误中 GraphBroadcast 里
        // 唯一那处 `post(name: .mixCutDataDidUndo, …)`。
        let observerPattern =
            "publisher\\(for:\\s*\\.mixCutDataDidUndo\\)"
            + "|forName:\\s*\\.mixCutDataDidUndo"
            + "|selector:[\\s\\S]{0,120}?name:\\s*\\.mixCutDataDidUndo"
        var observerFiles: [String] = []
        for pair in allMixCutSources() {
            forEachMatch(in: pair.code, pattern: observerPattern) { _ in
                observerFiles.append(pair.path)
            }
        }
        #expect(observerFiles.count == 4,
                "观察者应为 4 处（ContentView 剪枝 + DubbingViewModel 取消作业 + ScriptWizardViewModel 匹配回退 + DebugSelfTest 自检探针），实得 \(observerFiles.count)：\(observerFiles)")
        #expect(Set(observerFiles) == [
            "MixCut/App/ContentView.swift",
            "MixCut/App/DebugSelfTest.swift",
            "MixCut/ViewModels/DubbingViewModel.swift",
            "MixCut/ViewModels/ScriptWizardViewModel.swift"
        ], "消费者身份漂移：\(observerFiles)")

        // 发布口自身那三条承重写法逐字钉住：丢了任一条，上面两条锚就成了空壳。
        guard let raw = load("MixCut/App/ContentView.swift") else {
            Issue.record("读不到 ContentView.swift ⇒ 本条不算通过"); return
        }
        let broadcast = RelationshipReadScan.codeOnly(raw)
        #expect(forEachMatchHas(broadcast, "if\\s+isBroadcasting\\s*\\{"),
                "GraphBroadcast 的重入分叉被改掉了（嵌套那次必须进队列，不许直接 post 也不许丢弃）")
        #expect(forEachMatchHas(broadcast, "while\\s*!queued\\.isEmpty"),
                "GraphBroadcast 的排空循环被摘掉了 ⇒ 嵌套那次的台账再也没人投递")
        #expect(forEachMatchHas(broadcast, "\\(change\\?\\.isPrunable\\s*\\?\\?\\s*false\\)\\s*\\?\\s*change\\s*:\\s*nil"),
                "GraphBroadcast 的「不可剪枝 ⇒ 降级为无载荷」规则被改掉了")
    }

    /// 门 5 名册重生成腿（销账用，平时不启用）：
    /// `TOMBSTONE_DUMP_TOONE=1 swift test --filter TombstoneReadGuardTests`
    @Test("G17d 门 5 基线重生成（仅在 TOMBSTONE_DUMP_TOONE=1 时启用）",
          .enabled(if: ProcessInfo.processInfo.environment["TOMBSTONE_DUMP_TOONE"] == "1"))
    func dumpToOneBaseline() throws {
        guard let hits = realToOneScan() else { throw GuardError.probeDead }
        var counts: [String: Int] = [:]
        for h in hits { counts["\(h.file)|\(h.property)|\(h.line)", default: 0] += 1 }
        var out = "TOTAL=\(hits.count) KEYS=\(counts.count) FILES=\(Set(hits.map { $0.file }).count)\n"
        for key in counts.keys.sorted() {
            let parts = key.components(separatedBy: "|")
            out += "        (#\"\(parts[0])\"#, \"\(parts[1])\", #\"\(parts[2])\"#, \(counts[key]!)),\n"
        }
        let url = guardRepoRoot.appendingPathComponent(".scratch/guard_toone_baseline_new.txt")
        try Data(out.utf8).write(to: url)
    }

    // MARK: G21 DanglingToOneEdge 注册表三元组对账

    /// 一条三元组。
    struct EdgeTriple: Hashable, Comparable {
        var ownerTable: String
        var column: String
        var destinationTable: String

        static func < (l: EdgeTriple, r: EdgeTriple) -> Bool {
            (l.ownerTable, l.column, l.destinationTable)
                < (r.ownerTable, r.column, r.destinationTable)
        }
    }

    /// 解析 MixCutApp.swift 内 `DanglingToOneEdge.registry` 的登记三元组。
    private func parseRepairRegistry(_ source: String) -> Set<EdgeTriple> {
        let pattern = #"\.init\(ownerTable:\s*"([^"]+)",\s*column:\s*"([^"]+)",\s*destinationTable:\s*"([^"]+)""#
        var out: Set<EdgeTriple> = []
        forEachMatch(in: source, pattern: pattern) { g in
            guard let o = g(1), let c = g(2), let d = g(3) else { return }
            out.insert(EdgeTriple(ownerTable: o, column: c, destinationTable: d))
        }
        return out
    }

    /// 从 Models 源码派生三元组（owner 表.Z列 → 目标表）。
    /// 目标类型限定为 @Model 类名（排除 `String?`/`Data?` 等 Codable 属性 —— 与
    /// `ToOneReadScan.toOneEdgeDeclarations` 同一过滤口径）。
    private func deriveModelTriples(_ modelSources: [(path: String, code: String)]) -> Set<EdgeTriple> {
        let types = RelationshipReadScan.modelTypeNames(modelSources: modelSources)
        guard !types.isEmpty else { return [] }
        let alt = types.sorted().joined(separator: "|")
        var out: Set<EdgeTriple> = []
        for (_, code) in modelSources {
            // 文件内的 @Model 类名 → owner 表
            var className: String?
            forEachMatch(in: code, pattern: "@Model\\s+(?:final\\s+)?class\\s+([A-Z]\\w*)") { g in
                if let n = g(1) { className = n }
            }
            guard let owner = className else { continue }
            // var edge: ModelType?
            forEachMatch(in: code,
                         pattern: "\\bvar\\s+(\\w+)\\s*:\\s*(" + alt + ")\\?\\s*(?:\n|[=\\{])") { g in
                guard let edge = g(1), let target = g(2) else { return }
                out.insert(EdgeTriple(ownerTable: "Z" + owner.uppercased(),
                                      column: "Z" + edge.uppercased(),
                                      destinationTable: "Z" + target.uppercased()))
            }
        }
        return out
    }

    @Test("G21 DanglingToOneEdge 注册表 ≡ Models 派生三元组（20 条逐条相等；v3.4 含知识库+脚本 7 条）")
    func edgeRegistryTriplesMatchModels() throws {
        let appSource = try #require(load("MixCut/App/MixCutApp.swift"))
        let registered = parseRepairRegistry(appSource)
        let derived = deriveModelTriples(modelSources())

        #expect(registered.count == 20, "注册表应为 20 条，实得 \(registered.count)")
        let missing = registered.subtracting(derived).sorted()
        let extra = derived.subtracting(registered).sorted()
        #expect(missing.isEmpty,
                "注册表里有 Models 派不出来的边（列名/表名错或幽灵登记）：\(missing.prefix(6))")
        #expect(extra.isEmpty,
                "Models 里有注册表漏登记的边：\(extra.prefix(6))")
    }
}

private enum GuardError: Error {
    case probeDead
}

// MARK: - G22 跨边「.live」形态扫描（第三起 SIGTRAP 同族回归门）

struct EdgeLiveFaultScan {
    /// 危险形态：`.<to-one edge>.live` —— 穿过关系边 fault 目标后再做存活判断。
    ///
    /// 不允许的原因（grid16 实测）：悬空边 fault 出的空壳 `isDeleted=false`、
    /// `modelContext != nil`，`.live` 两信号全假；后续读持久列即 trap。
    /// 安全形态只能是标识符优先：读边目标的 persistentModelID，查活 fetch 构建的索引。
    /// 同对象的 `.live`（如 `segmentByID[id]?.live`）不是跨边，本扫描不命中。
    static func scan(sources: [(path: String, code: String)], edges: Set<String>)
        -> [RelationshipReadScan.Hit] {
        guard !edges.isEmpty else { return [] }
        let alt = edges.sorted().joined(separator: "|")
        let pattern = "\\.(" + alt + ")\\.live\\b"
        var hits: [RelationshipReadScan.Hit] = []
        for (path, code) in sources {
            for line in code.components(separatedBy: "\n") {
                forEachMatch(in: line, pattern: pattern) { g in
                    guard let edge = g(1) else { return }
                    hits.append(RelationshipReadScan.Hit(
                        file: path, property: edge,
                        line: RelationshipReadScan.normalizedLine(line)))
                }
            }
        }
        return hits.sorted()
    }
}

struct EdgeLiveFaultGuardTests {

    /// 从 Models 派生全部 to-one 边名（与 G13/G22 同一来源，不另建表）。
    private func edgeNames() -> Set<String> {
        let models = modelSources()
        let types = RelationshipReadScan.modelTypeNames(modelSources: models)
        return Set(ToOneReadScan.toOneEdgeDeclarations(
            modelSources: models, modelTypes: types).map(\.name))
    }

    @Test("G22 MixCut 源码零「跨 to-one 边 .live」形态（先 fault 再检查；第三起 SIGTRAP 同族）")
    func noEdgeLiveFaulting() {
        let hits = EdgeLiveFaultScan.scan(sources: allMixCutSources(), edges: edgeNames())
        #expect(hits.isEmpty,
                "存在跨 to-one 边后 .live 的形态，必须改为标识符优先（LiveModelIDIndex）：\(hits.prefix(6))")
    }

    @Test("G22b 变异自证：危险样本必红；同对象/字典下标 .live 与原语定义不误伤")
    func gateIsSensitiveAndPrecise() {
        let edges = Set(["matchedSegment"])

        let bad = [(path: "MixCut/Views/__Injected_BadEdge__.swift",
                    code: "let id = scene.matchedSegment.live?.id")]
        #expect(EdgeLiveFaultScan.scan(sources: bad, edges: edges).count == 1,
                "注入的危险形态没被抓到 ⇒ G22 恒绿")

        let safeSubscript = [(path: "MixCut/Views/__Safe_Subscript__.swift",
                              code: "let live = viewModel.segmentByID[id]?.live")]
        #expect(EdgeLiveFaultScan.scan(sources: safeSubscript, edges: edges).isEmpty,
                "字典下标同对象 .live 被误伤 ⇒ G22 噪音化")

        let safeObject = [(path: "MixCut/Views/__Safe_Object__.swift",
                           code: "if let seg = oneFetchedObject.live { draw(seg) }")]
        #expect(EdgeLiveFaultScan.scan(sources: safeObject, edges: edges).isEmpty,
                "同一活对象的 .live 被误伤")

        let primitive = [(path: "MixCut/Utilities/__Primitive__.swift",
                          code: "var live: Self? { isGoneFromGraph ? nil : self }")]
        #expect(EdgeLiveFaultScan.scan(sources: primitive, edges: edges).isEmpty,
                "过门原语定义被自己的门拦了")
    }
}

// MARK: - G23 #Predicate 多层 to-one 链扫描（CoreData SQL 生成异常 abort 回归门）

struct PredicateChainDepthScan {
    /// 危险形态（均在单个 `#Predicate { … }` 闭包内判定）：
    ///
    /// 1. **深链**：一条关系链上出现 ≥2 个 `?.`（如 `x.a?.b?.c`）；
    /// 2. **重复起链**：同一个链前缀（如 `chunk.document?`）在谓词里出现 ≥2 次
    ///    （原崩溃谓词对 document 同时访问 product? 与 isEnabled）。
    ///
    /// 命中任一即说明该谓词无法被 CoreData SQL 生成器翻译——SQL 生成阶段抛 ObjC 异常、
    /// Swift 无法捕获，进程 abort。安全替代：无 #Predicate fetch + 标识符优先的 Swift 侧过滤。
    static func scan(sources: [(path: String, code: String)])
        -> [RelationshipReadScan.Hit] {
        var hits: [RelationshipReadScan.Hit] = []
        for (path, code) in sources {
            let closures = predicateClosures(in: code)
            for item in closures {
                if let reason = violation(in: item.body) {
                    let line = code.components(separatedBy: "\n")
                        .dropFirst(item.line).first ?? item.body
                    hits.append(RelationshipReadScan.Hit(
                        file: path,
                        property: reason,
                        line: RelationshipReadScan.normalizedLine(line)))
                }
            }
        }
        return hits.sorted()
    }

    /// 一个 #Predicate 闭包投影（体 + 起始行号）。
    struct Closure {
        let body: String
        let line: Int
    }

    /// 提取每个 #Predicate 的闭包体及其起始行（按括号配平切取；不做完整 Swift 解析）。
    static func predicateClosures(in code: String) -> [Closure] {
        var out: [Closure] = []
        let ns = code as NSString
        let re = regexCache.regex("#Predicate(?:<[^>]+>)?\\s*\\{")
        re?.enumerateMatches(in: code, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let braceStart = NSMaxRange(m.range) - 1
            guard braceStart < code.count else { return }
            var depth = 0
            var index = code.index(code.startIndex, offsetBy: braceStart)
            let startIndex = index
            var ended = index
            while index < code.endIndex {
                let ch = code[index]
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 { ended = index; break }
                }
                index = code.index(after: index)
            }
            let body = String(code[code.index(after: startIndex)..<ended])
            let prefix = code[..<startIndex]
            let line = prefix.filter { $0 == "\n" }.count
            out.append(Closure(body: body, line: line))
        }
        return out
    }

    /// 闭包体内的违规判定；返回违规描述，无违规 nil。
    static func violation(in body: String) -> String? {
        // ① 深链：标识符后连续 ≥2 个 ?. 关系跳转。
        let deepPattern = "\\b\\w+(?:\\?\\.\\w+){2,}"
        var deep = false
        forEachMatch(in: body, pattern: deepPattern) { _ in deep = true }
        if deep { return "multiLevelChain" }

        // ② 重复起链：同一「根.edge?」前缀出现 ≥2 次。
        var counts: [String: Int] = [:]
        let chainStart = "\\b(\\w+)\\.(\\w+)\\?"
        forEachMatch(in: body, pattern: chainStart) { g in
            guard let root = g(1), let edge = g(2) else { return }
            let key = root + "." + edge
            counts[key, default: 0] += 1
        }
        if let repeated = counts.first(where: { $0.value >= 2 }) {
            return "repeatedChain:" + repeated.key
        }
        return nil
    }
}

struct PredicateChainGuardTests {
    @Test("G23 MixCut 源码零「#Predicate 多层 to-one 链 / 重复起链」（SQL 生成异常 abort 同族）")
    func noDeepChainPredicates() {
        let hits = PredicateChainDepthScan.scan(sources: allMixCutSources())
        #expect(hits.isEmpty,
                "存在无法被 CoreData 翻译的 #Predicate，改为无 #Predicate fetch + Swift 侧过滤：\(hits.prefix(6))")
    }

    @Test("G23b 变异自证：深链/重复起链必红；单层链与谓词外可选链不误伤")
    func gateIsSensitiveAndPrecise() {
        let deep = [(path: "MixCut/__Deep__.swift",
                     code: "predicate(#Predicate { $0.document?.product?.id == x })")]
        #expect(PredicateChainDepthScan.scan(sources: deep).count == 1,
                "两层深链没被抓到")

        // 纯规则②：单层 ?. 但同一链前缀对 document 访问两个不同属性。
        let repeated = [(path: "MixCut/__Repeated__.swift",
                         code: "#Predicate { c in c.document?.title == x && c.document?.isEnabled == true }")]
        let repeatedHits = PredicateChainDepthScan.scan(sources: repeated)
        #expect(repeatedHits.contains { $0.property.hasPrefix("repeatedChain:") },
                "重复起链（document? 出现两次）没被抓到，实得 \(repeatedHits)")

        // 原崩溃谓词：深链①与重复起链②同时存在。
        let original = [(path: "MixCut/__OriginalCrash__.swift",
                         code: "#Predicate { c in c.document?.product?.id == x && c.document?.isEnabled == true }")]
        #expect(!PredicateChainDepthScan.scan(sources: original).isEmpty,
                "原崩溃谓词没被抓到")

        let single = [(path: "MixCut/__Single__.swift",
                       code: "#Predicate { doc in doc.product?.id == x }")]
        #expect(PredicateChainDepthScan.scan(sources: single).isEmpty,
                "单层链被误伤 ⇒ G23 噪音化")

        let outside = [(path: "MixCut/__Outside__.swift",
                        code: "let id = scene.matchedSegment.live?.id")]
        #expect(PredicateChainDepthScan.scan(sources: outside).isEmpty,
                "谓词外的普通可选链被误伤")

        let selfColumn = [(path: "MixCut/__Column__.swift",
                           code: "#Predicate<Video> { $0.contentHash == h }")]
        #expect(PredicateChainDepthScan.scan(sources: selfColumn).isEmpty,
                "自有列比较被误伤")
    }
}
