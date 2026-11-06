import Foundation
import Testing

// ============================================================================
// 分镜「分类标签」写入口名册 + 回显判据
//
// ## 为什么要有这一组
//
// 「改一条分镜的语义标签」这件事，在这一轮之前**全仓一条测试都没有**：
// `toggleSemanticType` / `updatePositionType` / `applyFilter` / `SegmentFilter` /
// `countByType` / `applySourceToSelected` 在 `Tests/` 与 `MixCutAppTests/` 里零命中，
// 而「至少要保留 1 个语义类型」这条不变式只在 MCP 的代码里存在过，没人钉。
// 于是写通路长成了三套各写一遍：Inspector 直改模型、ViewModel 那条带撤销名与筛选刷新
// 的正解躺着没人调、MCP 自己再来一套。名册就是把「谁有权写标签」这件事变成登记制 ——
// 新增一处写点必须**显式改这张表**，改表时就得回答"它归谁"。
//
// ## 为什么不用正则 `\.semanticTypes\s*=`
//
// 实测它会命中 `MixCut/Views/Shared/SegmentCardCompact.swift:16` 的
// `self.semanticTypes = segment.semanticTypes` —— 那是 `SegmentCardSnapshot` 这枚**值类型
// 快照自己的属性初始化**，跟"绕过写入口"毫无关系。判据落地第一天就红在一行不该管的代码上，
// 而这种判据的下一步通常是被人整条注释掉，收口收益归零。
// 所以口径改成：**赋值号左侧必须是模型对象**，`self.` 开头的自有属性赋值一律不计。
// 这条排除规则本身由 TC-TWR-03 反向验一遍，防止它被写成"什么都不计"的恒绿。
//
// ## 台架
//   · 纯源码扫描 ⇒ 跑在 `swift test`（Core 腿），不依赖任何 App 层符号；
//   · 真仓基线的数字来自一次真实遍历（见 TC-TWR-01 的失败读数），不是拍出来的；
//   · 三条红钉用 `withKnownIssue` 包：实现落地后它们会因"不再有问题"而**自己变红**
//     ⇒ 逼一次摘标，顺带证明这三条不是恒绿。摘标条件逐条写在 reason 里。
// ============================================================================

/// 仓库根：`#filePath` 在 `Tests/MixCutCoreTests/` 下 ⇒ 连剥三层（文件、MixCutCoreTests、Tests）。
/// 少剥一层就会扫到 0 个文件，那"名册全对"是恒绿假象 —— TC-TWR-02 专门拦这一格。
private func twrRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func twrRead(_ relative: String) -> String? {
    try? String(contentsOf: twrRoot().appendingPathComponent(relative), encoding: .utf8)
}

/// 递归收集 `MixCut/` 下全部 .swift（相对仓库根的路径，排序稳定）。
private func twrSwiftFiles(under directory: URL, root: URL) -> [String] {
    var out: [String] = []
    guard let en = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { return out }
    for case let url as URL in en where url.pathExtension == "swift" {
        out.append(String(url.path.dropFirst(root.path.count + 1)))
    }
    return out.sorted()
}

// MARK: - 扫描器

enum TagWriteRoster {

    /// 「往分镜模型写语义标签」的特征串。
    static let token = "semanticTypes = "

    /// 剥注释与字符串字面量（复用仓内既有实现，逐字符等长替换 ⇒ 行结构不变）。
    static func codeOnly(_ src: String) -> String { BoundaryAdjustUsageScan.codeOnly(src) }

    /// 提取 `struct <name>` 的结构域（含外层大括号）。
    static func structBody(named name: String, in source: String) -> String? {
        BoundaryAdjustUsageScan.structBody(named: name, in: source)
    }

    /// 数出源码里「模型对象被写语义标签」的行。
    ///
    /// 口径两半边都得有牙齿：
    /// ① 计入 `segment.semanticTypes = …` / `seg.semanticTypes = …` / 裸 `semanticTypes = …`（模型自有 setter 内部）；
    /// ② 不计 `self.semanticTypes = …` —— 值类型快照的自有属性初始化，与写入口无关。
    static func writeLines(in source: String) -> [Int: String] {
        var hits: [Int: String] = [:]
        let lines = codeOnly(source).split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, raw) in lines.enumerated() {
            let line = String(raw)
            guard line.contains(token) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("self." + token) { continue }
            hits[idx + 1, default: ""] = trimmed
        }
        return hits
    }

    /// 登记制名册：文件 → 允许出现的写点行数。
    ///
    /// ⚠️ 数字来自**真实遍历**（当前合计 14 处 / 5 个文件），改它必须是一次有意识的动作。
    /// 2026-11-06 本轮改表两处：`SegmentPropertiesSection` 3 → 2（Inspector 那颗 Menu 的直写
    /// 已收敛进 VM，剩下两处是 `SegmentBatchActions` 的覆盖与撤销还原）；
    /// `SegmentLibraryViewModel` 1 → 3（新增的两条批量各带一处覆盖写与快照还原写）。
    static let registered: [(file: String, count: Int, why: String)] = [
        ("MixCut/Models/Segment.swift", 2,
         "模型自己的 setter 内部（deprecated 单值兼容层往多值数组回落）"),
        ("MixCut/ViewModels/SegmentLibraryViewModel.swift", 3,
         "UI 侧唯一写入口：单条 toggle + 批量加标签 + 批量撤销还原"),
        ("MixCut/ViewModels/ImportViewModel.swift", 4,
         "导入侧自动打标 + 空镜闸 + 自建分镜路径"),
        ("MixCut/Services/MCP/MCPSegmentToolHandlers.swift", 3,
         "MCP 的 add / remove / set 三条腿（必须能在无 UI 状态时工作，不收进 VM）"),
        ("MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift", 2,
         "仅 SegmentBatchActions 的覆盖与撤销还原（Inspector 直写已于本轮收敛掉，见 TC-TWR-05）"),
    ]

    /// 全仓扫描：返回「实际有写点的文件 → 行数」。
    static func scanAll(under mixCutDirectory: URL, root: URL) -> [String: Int] {
        var result: [String: Int] = [:]
        for rel in twrSwiftFiles(under: mixCutDirectory, root: root) {
            guard let src = twrRead(rel) else { continue }
            let n = writeLines(in: src).count
            if n > 0 { result[rel] = n }
        }
        return result
    }
}

// MARK: - 判据

// MARK: - 「空串当图标」这一族

/// macOS 上 `Menu` / `contextMenu` 里用 `Label(_, systemImage: 命中 ? "checkmark" : "")`
/// 表达选中态 —— 这一形已被逐列量测证伪（12 项文字同一起排、零勾选）：`Button` 在菜单里
/// 没有选择语义，而空串不是合法 symbol 名。
///
/// 本轮只收了**与症状同源**的那一处（分镜卡右键的「标记素材来源」）。另两处属不同功能面
/// （项目侧栏的产品选择器、分镜抽屉的产品筛选），改它们要各自验一次渲染，不在本轮范围 ——
/// 但登记在明处，防止这一族悄悄再长第三、第四颗。
enum DeadCheckmarkIdiom {
    static let pattern = "? \"checkmark\" : \"\""

    /// 在册清单：文件 → 允许的出现次数（注释行不计，见 `count(in:)`）。
    static let roster: [String: Int] = [
        "MixCut/Views/Sidebar/SidebarView.swift": 1,
        "MixCut/Views/Schemes/SegmentPickerDrawer.swift": 1,
    ]

    /// 逐行数，跳过注释行 —— 本轮修完的那两处，注释里会**引用**这一形来说明为什么禁用，
    /// 不跳注释就会把解释自己的话判成违规（判据红在文档上，是它被删掉的最快路径）。
    static func count(in source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { acc, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("*") { return acc }
            return acc + (line.contains(pattern) ? 1 : 0)
        }
    }
}

@Suite("TWR · 分镜语义标签写入口名册", .serialized)
struct TagWriteRosterTests {

    /// 真仓遍历：每个文件实际几行。
    private var actual: [String: Int] {
        TagWriteRoster.scanAll(under: twrRoot().appendingPathComponent("MixCut"),
                               root: twrRoot())
    }

    @Test("TC-TWR-01 名册逐字对账：写标签的行只许落在已登记的 5 个文件、条数不许漂")
    func rosterMatchesRegistered() {
        let got = actual
        var problems: [String] = []
        for rel in got.keys.sorted() where !TagWriteRoster.registered.contains(where: { $0.file == rel }) {
            problems.append("未登记的文件出现写点：\(rel)（\(got[rel] ?? 0) 行）")
        }
        for item in TagWriteRoster.registered {
            let n = got[item.file] ?? 0
            if n != item.count {
                problems.append("\(item.file)：登记 \(item.count) 行，实得 \(n) 行")
            }
        }
        #expect(problems.isEmpty,
                "名册与真实代码对不上：\n\(problems.joined(separator: "\n"))")
    }

    @Test("TC-TWR-02 扫描根不许空转：真仓至少扫到 14 处、分布在 5 个文件")
    func scanRootIsLiveNotAnEmptyTraversal() {
        let got = actual
        let scanned = twrSwiftFiles(under: twrRoot().appendingPathComponent("MixCut"),
                                    root: twrRoot()).count
        let total = got.values.reduce(0, +)
        // 敏感性下限：扫到的源文件数与写点数都得有读数。扫到 0 说明根路径错了，
        // 那时 TC-TWR-01 的"名册全对"就是恒绿的假象。
        #expect(scanned >= 100, "只扫到 \(scanned) 个 .swift ⇒ 扫描根可能错了，判据没跑起来，不算通过")
        #expect(total >= 14, "真仓写点合计 \(total) 处，低于登记的 14 ⇒ 先怀疑扫描口径而不是宣布收口完成")
        #expect(got.count >= 5, "写点分布在 \(got.count) 个文件，少于登记的 5 个 ⇒ 遍历口径缩了")
    }

    @Test("TC-TWR-03 排除规则有牙齿：self. 自有属性赋值不计，模型对象赋值必计")
    func exclusionRuleHasBothHalves() {
        // 正半边：值类型快照自己的属性初始化 —— 这就是 R1 里那条会被正则误伤的写法。
        let snapshot = """
        struct SegmentCardSnapshot {
            var semanticTypes: [SemanticType] = []
            init(_ segment: Segment) {
                self.semanticTypes = segment.semanticTypes
            }
        }
        """
        #expect(TagWriteRoster.writeLines(in: snapshot).isEmpty,
                "self. 自有属性赋值被计成了写点 ⇒ 名册会红在无关代码上（R1 那一族）")

        // 反半边：真往模型对象上写，必须被计到。少了这一腿，上面的排除就成了"什么都不计"的恒绿。
        let realWrite = """
        func f(_ seg: Segment) {
            seg.semanticTypes = [.hook]
            for item in targets { item.seg.semanticTypes = item.types }
        }
        """
        #expect(TagWriteRoster.writeLines(in: realWrite).count == 2,
                "模型对象上的直写没被检出 ⇒ 这条守卫拦不住新增写点")
    }

    @Test("TC-TWR-04 反向对照：往 Views 注一行直写，名册必须翻红")
    func injectedDirectWriteIsCaught() {
        let path = "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"
        guard let src = twrRead(path) else {
            Issue.record("读不到 \(path) ⇒ 判据没跑起来，不算通过")
            return
        }
        let mutated = src + "\nfunc injected(_ segment: Segment) { segment.semanticTypes = [.hook] }\n"
        #expect(TagWriteRoster.writeLines(in: mutated).count
                == TagWriteRoster.writeLines(in: src).count + 1,
                "注进去的直写没让计数 +1 ⇒ 今天的绿并非真的在数这件事")
    }

    @Test("TC-TWR-05 CategorySection 体内不许直写模型（写只走 VM 那一个入口）")
    func inspectorStopsWritingModelDirectly() {
        let path = "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"
        guard let src = twrRead(path),
              let body = TagWriteRoster.structBody(named: "CategorySection", in: src) else {
            Issue.record("取不到 struct CategorySection 的结构域 ⇒ 判据没跑起来，不算通过")
            return
        }
        // 2026-11-06 摘标：本条原是 withKnownIssue 红钉（当时 CategorySection 自己写
        // `segment.semanticTypes = types` + `try? modelContext.save()`，绕开 VM 那条带
        // 撤销动作名与筛选刷新的正解 ⇒ 改了标签但顶部 chip 计数不刷新）。
        // 计划笔 2/4 落地后它因「不再有问题」自己变红 ⇒ 摘标，断言转为永久闸。
        #expect(!body.contains("modelContext"), "分类区在自己拿 context 落库 ⇒ 绕开了 VM 唯一写入口")
        #expect(!body.contains("try?"), "分类区有被 `try?` 吞掉的失败")
        #expect(!body.contains("semanticTypes = "), "分类区在直写模型")
        #expect(!body.contains("positionType = "), "分类区在直写位置")
    }

    @Test("TC-TWR-06 收起态必须回显已命中的标签（不许是硬编码文案）")
    func collapsedRowEchoesCurrentValue() {
        let path = "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"
        guard let raw = twrRead(path) else {
            Issue.record("读不到 \(path) ⇒ 判据没跑起来，不算通过")
            return
        }
        // 逐颗宿主各问各的事 —— 全塞进 CategorySection 的结构域里断言，
        // 实现落地后这条永远摘不了标（那些调用点根本不在 CategorySection 体内，
        // 于是它成了一条"红到没人能修"的判据，结局就是被整条删掉）。
        let section = TagWriteRoster.structBody(named: "CategorySection", in: raw) ?? ""
        let echo = TagWriteRoster.structBody(named: "CategoryEcho", in: raw) ?? ""
        let editor = TagWriteRoster.structBody(named: "SegmentCategoryEditor", in: raw) ?? ""
        // 2026-11-06 摘标：原为 withKnownIssue 红钉（标题是一段硬编码 `Text("语义 / 位置")`，
        // 不读 segment.semanticTypes / positionType ⇒ 用户看不到哪些标签已命中）。
        // 逐颗宿主各问各的事 —— 全塞进 CategorySection 的结构域里断言，实现落地后这条永远
        // 摘不了标（那些调用点根本不在它体内），于是它会变成"红到没人能修"的判据。
        // 用**未剥字符串**的原文：codeOnly 会把字符串字面量抹掉，那条硬编码文案就扫不见了。
        #expect(!raw.contains("Text(\"语义 / 位置\")"), "标题仍是硬编码文案")
        #expect(section.contains("trailing:"), "分类分区没把回显挂进折叠壳的 trailing 槽")
        #expect(section.contains("CategoryEcho("), "分类分区没接回显宿主")
        #expect(section.contains("SegmentCategoryEditor("), "分类分区没接编辑宿主")
        #expect(!section.contains("Menu {"), "分类分区还留着那颗下拉菜单")
        #expect(echo.contains("SemanticTypeTag("), "回显没铺语义标签胶囊")
        #expect(echo.contains("PositionTypeTag("), "回显没铺位置胶囊")
        #expect(editor.contains("viewModel.toggleSemanticType(for:"), "语义改动没走 VM 唯一写入口")
        #expect(editor.contains("viewModel.updatePositionType(for:"), "位置改动没走 VM 唯一写入口")
        // 单值/多值两套语言必须在视觉上可分辨，否则"再点一次"的后果只能靠猜。
        #expect(editor.contains("PositionChoiceChip("), "位置那颗没和语义 chip 用不同的可操作语言")
    }

    @Test("TC-TWR-07 回显这颗第二显示宿主必须自带 lineLimit（不许把卡片压成竖排）")
    func echoSitesCarryTheirOwnLineLimit() {
        // TagRowContainerGuardTests 认两半边逃生口：宿主是 FlowLayout，或调用点自带 .lineLimit。
        // 回显住在标题行那个刚性 HStack 里 ⇒ 只能靠后半边。这条钉的是"别哪天把它挪进裸栈就忘了"。
        let path = "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"
        guard let raw = twrRead(path) else {
            Issue.record("读不到 \(path) ⇒ 判据没跑起来，不算通过")
            return
        }
        let echo = TagWriteRoster.structBody(named: "CategoryEcho", in: raw)
            ?? TagWriteRoster.structBody(named: "CategorySection", in: raw) ?? ""
        // 先数调用点在不在，再逐点验修饰符。少了这一半，下面的 for 会遍历空集，
        // 于是"每个调用点都带 .lineLimit(1)"在宿主还不存在时**恒真**，红钉就空过了
        // （本条第一版就是这么假绿了一次，被 "Known issue was not recorded" 抓出来）。
        let sites = echo.components(separatedBy: "SemanticTypeTag(").dropFirst().count
            + echo.components(separatedBy: "PositionTypeTag(").dropFirst().count
        // 2026-11-06 摘标：原为 withKnownIssue 红钉（当时回显宿主还不存在、调用点数 = 0）。
        // `sites > 0` 这条存在性守卫必须留着：少了它下面的 for 会遍历空集，
        // "每个调用点都带 .lineLimit(1)"就退化成恒真 —— 本条第一版正是这么假绿的。
        #expect(sites > 0,
                "一个回显调用点都没有 ⇒ 逐点验修饰符会因遍历空集而恒真，这条判据没在测东西")
        for tag in ["SemanticTypeTag(", "PositionTypeTag("] {
            for chunk in echo.components(separatedBy: tag).dropFirst() {
                // 只看调用点后面那段修饰符链：启发式，链拉得比 200 字还长会漏判。
                // 真到那一步该改用 AST 级扫描，而不是把这条放宽成"出现过 .lineLimit 就行"。
                let head = String(chunk.prefix(200))
                #expect(head.contains(".lineLimit(1)"),
                        "\(tag) 调用点没带 .lineLimit(1)，窄容器里会压成一字一行")
            }
        }
    }

    @Test("TC-TWR-08 「空串当图标」这一族只许停在已登记的 2 处，本轮收口的两处必须归零")
    func deadCheckmarkIdiomStaysRostered() {
        let root = twrRoot()
        var seen: [String: Int] = [:]
        for rel in twrSwiftFiles(under: root.appendingPathComponent("MixCut"), root: root) {
            guard let src = twrRead(rel) else { continue }
            let n = DeadCheckmarkIdiom.count(in: src)
            if n > 0 { seen[rel] = n }
        }
        // 正腿：本轮收口的两处必须归零（卡片右键的来源菜单、Inspector 的分类菜单）。
        for cleaned in ["MixCut/Views/SegmentLibrary/SegmentLibraryView.swift",
                        "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"] {
            #expect(seen[cleaned] == nil,
                    "\(cleaned) 又长回这一形（\(seen[cleaned] ?? 0) 处）⇒ 选中态重新变成看不见的东西")
        }
        // 在册腿：剩下的两处按文件逐颗对账，新增一处就红 —— 不是把这一族判死，是不许它无声生长。
        var problems: [String] = []
        for rel in seen.keys.sorted() where !DeadCheckmarkIdiom.roster.keys.contains(rel) {
            problems.append("未登记的文件长回这一形：\(rel)（\(seen[rel] ?? 0) 处）")
        }
        for (rel, want) in DeadCheckmarkIdiom.roster {
            let got = seen[rel] ?? 0
            if got != want { problems.append("\(rel)：登记 \(want)，实得 \(got)") }
        }
        #expect(problems.isEmpty,
                "「空串当图标」名册与真实代码对不上：\n\(problems.joined(separator: "\n"))")

        // 排除规则自己也得有牙齿：注释里的引用不计，但代码里的一计。
        // 少了这一腿，"跳过注释"就可能被写成"什么都不计"的恒绿。
        #expect(DeadCheckmarkIdiom.count(
            in: "// 不许写成 systemImage: on ? \"checkmark\" : \"\"\n") == 0,
                "注释里的引用被计成违规 ⇒ 解释自己的话会把这条判据逼删")
        #expect(DeadCheckmarkIdiom.count(
            in: "Label(x, systemImage: on ? \"checkmark\" : \"\")\n") == 1,
                "代码里的这一形没被计到 ⇒ 名册拦不住新增")
    }
}
