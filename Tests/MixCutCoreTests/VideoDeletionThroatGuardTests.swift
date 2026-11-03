import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 视频删除咽喉的「落盘结果不许被丢弃」判据（方案 kindled-cloud-robin.md 批 2 · 评审 P0-2）
//
// 为什么这条活在 Swift 层而不是 `check_undo_guards.sh`：shell 守卫没有"预期失败"这种形态，
// 把一条今天就不成立的判据写进去，等于把整支守卫钉死在红 —— 而红钉可以进套件（仓里既有纪律，
// `TombstoneReadGuardTests` 的 G08b/G15b 就是这么留的证据），Swift Testing 有 withKnownIssue，
// 修好之后它会因"不再有问题"而**自己变红**，逼一次摘标。
//
// 守的是什么：`ModelContextExtension.safeSave` 返回 Bool（`@discardableResult`，
// 所以裸调用连编译警告都没有），失败只打日志。单条删除时"没删掉"只是这一条；批 2 把它数组化之后
// 会放大成**部分成功**：前 k 条落盘、第 k+1 条 save 失败，而 ticket 的 undo 会把**全部** N 条
// 关联放回界面 ⇒ 界面与库不一致、重启后一部分回来一部分永久没了，且没人说出来。
// 方案拍板的语义是：false ⇒ 立刻停止本批、如实报「已删 k 条 / 未删 N−k 条」、undo 只回填未删成功的那部分。
//
// 现状（2026-10-13 更新）：**批 2 已落地** —— 咽喉改成数组化的 `commitVideoDeletion(_:in:)`，
// 两处落盘都走 `guard context.safeSave() else` ⇒ 名册数从 2 归 0。于是本文件的两条判据换班：
//   · GT-01 从"红钉（理想态 0，等批 2 摘标）"变成**硬闸**：再多一处静默丢弃就红；
//   · GT-02 新立**形状**判据：两次落盘都必须以 guard 形态存在（失败分支不许被摘光）。
// 只验"没丢返回值"不够 —— 有人改成 `if safeSave() { … }` 也不算丢弃，但失败时再没人停本批、
// 也没人说"未删几条"，那正是这里要挡住的第二种退化。
// 历史上这两处〔旧读数：`ImportViewModel.swift:814/830`，现为 `:98/:171`〕的裸 `context.safeSave()`（当时 UG-G11 只钉住了
// 它们的**位置与次数**，看不出结果被丢弃 ⇒ 那条缺口就是本文件的由来）。
// ============================================================================

private let throatRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private let throatFile = "MixCut/ViewModels/ImportViewModel.swift"

/// 咽喉的 commit 函数名。批 2 会把它改名成 `commitVideoDeletion` —— 两个名字都认，
/// 但**认不到任何一个就必须出声**（判据缺席比判据变红危险）。
private let throatHeads = ["private func commitDelete", "private func commitVideoDeletion"]

/// 取函数体：大括号平衡配对。窗口式截取会漏长函数 ⇒ 恒绿，所以不用行号差。
/// 括号始终不闭合（函数体被截断）时返回 nil，由调用方报判据失效，不许给出一个"看着能用"的体。
private func functionBody(code: String, head: String) -> String? {
    let i = code.range(of: head)
    guard let start = i?.upperBound else { return nil }
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

/// 以 `guard …safeSave() else` 形态存在的落盘次数 —— 只看"结果进了控制流"的那种写法。
private func safeSaveGuardCount(_ body: String) -> Int {
    var n = 0
    for raw in body.components(separatedBy: "\n") {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("guard ") && t.contains("safeSave()") && t.contains(" else") { n += 1 }
    }
    return n
}

/// 返回被丢弃的 `safeSave()` 调用点数：只算"表达式语句"形态（`x.safeSave()` 独占一行）。
/// 取了返回值的三种写法都不算：`let ok = `、`if `、`guard `，以及显式忽略 `_ = `
/// —— 显式忽略至少是个可读的决定，静默丢弃才是问题。
private func discardedSaveCount(_ body: String) -> Int {
    var n = 0
    for raw in body.components(separatedBy: "\n") {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("safeSave()") else { continue }
        if t.hasPrefix("if ") || t.hasPrefix("guard ") { continue }
        if t.contains("=") { continue }          // let x = / _ = / x = …：结果有去处
        n += 1
    }
    return n
}

/// 注入缝的三条硬约束（返回问题清单，空 = 合规）。
/// 为什么逐条查而不是"看着像就行"：这颗缝的唯一作用是"让真机能造出落盘失败"。
/// 它一旦变成默认拒绝、或者漏进 Release，就从读数点变成生产缺陷 —— 那是本方案最坏的一种假绿。
private func seamProblems(_ body: String) -> [String] {
    var problems: [String] = []
    if !body.contains("#if DEBUG") { problems.append("不在 #if DEBUG 内 ⇒ Release 也会注入") }
    if !body.contains("else { return true }") { problems.append("变量没设或设成空时不是默认放行") }
    if let r = body.range(of: "#else") {
        let releaseTail = body[r.upperBound...].replacingOccurrences(of: "#endif", with: "")
        if !releaseTail.contains("return true") { problems.append("Release 分支没恒真返回") }
    } else {
        problems.append("缺 #else ⇒ Release 侧根本没有兜底返回")
    }
    return problems
}

@Suite("视频删除咽喉 · safeSave 返回值不许被静默丢弃")
struct VideoDeletionThroatGuardTests {

    /// 读咽喉源码并剥注释；读不到、或剥完全空 ⇒ Issue.record（取样面为空时任何"0 命中"都长得像通过）。
    private func readThroatCode() -> String? {
        guard let raw = readThroatRaw() else { return nil }
        let code = RelationshipReadScan.codeOnly(raw)
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Issue.record("\(throatFile) 剥注释后为空 ⇒ 取样面没命中，本条不算通过")
            return nil
        }
        return code
    }

    /// 原始文本（不剥注释）。⚠️ 查**句子内容**必须走这颗：实测 `codeOnly` 连字符串字面量一起抹掉
    /// （`environment["MIXCUT_DEBUG_FAIL_SAVE"]` 出来是 `environment[      ]`），
    /// 拿它查句子必然 0 命中 —— 那是"判据在测空气"的一种隐蔽形态。
    private func readThroatRaw() -> String? {
        let url = throatRepoRoot.appendingPathComponent(throatFile)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("读不到 \(throatFile) ⇒ 判据无法成立，不算通过")
            return nil
        }
        return raw
    }

    /// 读咽喉源码并定位 commit 函数体；取不到就 Issue.record（不许当成通过）。
    private func throatBodyOrRecord() -> String? {
        guard let code = readThroatCode() else { return nil }
        for head in throatHeads {
            if let b = functionBody(code: code, head: head) { return b }
        }
        let heads = throatHeads.joined(separator: " / ")
        Issue.record("取不到咽喉的 commit 函数体（\(heads) 都不在）⇒ 判据失效：批 2 改了名却没把锚点搬过来")
        return nil
    }

    @Test("GT-01 咽喉里不许有任何一处静默丢弃 save 结果（批 2 已修，多一处裸调用即红）")
    func noSaveResultMayBeDiscarded() {
        guard let body = throatBodyOrRecord() else { return }
        let n = discardedSaveCount(body)
        // 历史上这里是 2 处裸 `context.safeSave()`（`@discardableResult` ⇒ 连警告都没有），
        // 方案 P0-2 把它当"批量部分失败会静默分叉"的根因之一。批 2 落地后名册数归 0，
        // 本条从"红钉"变成"硬闸"：再加一处静默丢弃就红，不必再靠人记得取返回值。
        #expect(n == 0, "咽喉里有 \(n) 处静默丢弃 safeSave 的结果 ⇒ 批量时会放大成部分成功无人出声")
        #expect(body.contains("safeSave()"), "函数体里一个 safeSave 都没有 ⇒ 锚点搬错地方了")
    }

    @Test("GT-02 两次落盘都必须以 guard 形态存在：结果要进控制流，不许写成 if 后不管")
    func bothSavesMustFeedTheControlFlow() {
        guard let body = throatBodyOrRecord() else { return }
        let guards = safeSaveGuardCount(body)
        // 2 = 中间那次（让 cascade 摘掉反向数组）+ 收尾那次（记录真删后落盘）。
        // 只断言"没有裸调用"是不够的：有人改成 `if context.safeSave() { …成功分支… }` 也不算丢弃，
        // 但失败分支被删掉后就再没人停本批、也没人说"未删几条" —— 形状必须一起钉。
        #expect(guards == 2, "guard 形态的 safeSave 实得 \(guards) 处，期望 2 处（失败分支被摘光就是假修）")
    }

    @Test("GT-03 这条判据自己要有牙：结果有去处的写法一律不算丢弃，裸调用必须算")
    func scannerClassifiesAllFourShapes() {
        let discarded = """
        {
            context.safeSave()
        }
        """
        #expect(discardedSaveCount(discarded) == 1, "裸调用没被抓出来 ⇒ 判据恒绿，不算防线")

        // 三种"结果有去处"：赋值给变量、显式 `_ =` 忽略、作为 if/guard 的条件（条件那两行故意换行写，
        // 让它们真的走到 if / guard 那两个前缀分支，而不是被"行尾不是 safeSave()"顺手躲过）
        let taken = """
        {
            let ok = context.safeSave()
            _ = context.safeSave()
            if context.safeSave()
            { return true }
            guard context.safeSave()
            else { return false }
        }
        """
        #expect(discardedSaveCount(taken) == 0, "取了返回值（含显式忽略）的被算成丢弃 ⇒ 判据过咬，正常写法也拦")

        // 夹具非空洞性：两种形态的差别真的存在（同一行加一个 `_ = ` 前缀就该从 1 变 0）
        let mixed = """
        {
            context.safeSave()
            _ = context.safeSave()
        }
        """
        #expect(discardedSaveCount(mixed) == 1, "同一函数体里两种形态并存时分类失效")

        // GT-02 那颗形状判据自己的牙：guard 形态数得对上，且"裸调用"与"if 后不管"都不算
        let shaped = """
        {
            guard context.safeSave() else { return 0 }
            context.safeSave()
            if context.safeSave() { doThing() }
        }
        """
        #expect(safeSaveGuardCount(shaped) == 1, "guard 形态计数错 ⇒ GT-02 既会漏报也会误报")
        #expect(discardedSaveCount(shaped) == 1, "裸调用没被算成丢弃 ⇒ GT-01 恒绿")
    }

    @Test("GT-04 锚点取不到时必须出声：两个名字都不在 ⇒ 返回 nil 让调用方报判据失效")
    func missingAnchorIsNotSilentlyGreen() {
        let code = "func somethingElse() { context.safeSave() }"
        #expect(functionBody(code: code, head: "private func commitDelete") == nil,
                "锚点根本不存在却取出了函数体 ⇒ 上面的判据在测空气")
        #expect(functionBody(code: "private func commitDelete(video: Video) { context.safeSave() }",
                             head: "private func commitDelete") != nil,
                "锚点存在却取不出来 ⇒ 提取器坏了，GT-01/02 都不可信")
        // 括号未闭合（函数体被截断）也不许给出一个"看着能用"的体
        #expect(functionBody(code: "private func commitDelete { context.safeSave()",
                             head: "private func commitDelete") == nil)
    }

    @Test("GT-05 落盘失败注入缝：只许挂在咽喉那两次落盘上，且必须 DEBUG-only、默认放行")
    func saveFaultSeamIsDebugOnlyAndDefaultAllow() {
        guard let raw = readThroatRaw() else { return }
        // 调用点数走原文：`guard debugSaveHolds(stage: "pv")` 里的句子被 codeOnly 抹掉，
        // 但 `guard debugSaveHolds(stage:` 这段是代码，原文里数得准（定义行不含 `guard ` 前缀）。
        let calls = raw.components(separatedBy: "\n")
            .filter { $0.contains("guard debugSaveHolds(stage:") }
            .count
        #expect(calls == 2, "注入缝调用点实得 \(calls) 处，期望 2 处 ⇒ 多一处就是有人把缝挪去了别的链上")
        // 环境变量必须被**代码行**读到：文档注释里也写着这个名字，只查子串会分不清两者。
        let envRead = raw.components(separatedBy: "\n")
            .filter { $0.contains("ProcessInfo") && $0.contains("MIXCUT_DEBUG_FAIL_SAVE") }
        #expect(envRead.count == 1, "读环境变量的代码行实得 \(envRead.count) 处，期望 1 处 ⇒ 注入缝是空壳或被复制过")
        // 可分性正对照：这个名字除了那一行代码，只许出现在注释里（注释行没有 ProcessInfo）。
        #expect(raw.components(separatedBy: "\n")
                .contains { $0.contains("MIXCUT_DEBUG_FAIL_SAVE") && !$0.contains("ProcessInfo") },
                "注释里没写用法 ⇒ 这条判据的正对照没内容可分，计数意义要重评")
        guard let code = readThroatCode(),
              let body = functionBody(code: code, head: "private func debugSaveHolds") else {
            Issue.record("取不到 debugSaveHolds 的函数体 ⇒ 判据失效：缝被改名或拆散，GT-05 已在测空气")
            return
        }
        let problems = seamProblems(body)
        #expect(problems.isEmpty, "注入缝不合规矩：\(problems)")
    }

    @Test("GT-06 注入缝判据自己的牙：三种违规各报一条，合规写法不报")
    func seamGateHasTeeth() {
        let compliant = """
        {
            #if DEBUG
            guard let spec = ProcessInfo.processInfo.environment["X"], !spec.isEmpty else { return true }
            return spec != "all" && spec != stage
            #else
            return true
            #endif
        }
        """
        #expect(seamProblems(compliant).isEmpty, "合规写法被报问题 ⇒ GT-05 天天假红")

        // ① 忘了 #if DEBUG：Release 也会注入（这是最贵的一种错）
        let noGuard = compliant.replacingOccurrences(of: "#if DEBUG", with: "")
        #expect(seamProblems(noGuard).contains { $0.contains("#if DEBUG") }, "漏了 DEBUG 闸却没报")
        // ② 默认拒绝：变量没设就失败 —— 正常用户一删就"部分失败"
        let defaultDeny = compliant.replacingOccurrences(of: "else { return true }", with: "else { return false }")
        #expect(seamProblems(defaultDeny).contains { $0.contains("默认放行") }, "默认拒绝没被抓出来")
        // ③ Release 分支留空：编不过之前判据就该先红（整份夹具现写，不用 replace ——
        //    多行字符串会被 Swift 按 closing delimiter 的缩进剥掉前导空格，按空格数找子串必失配）
        let emptyRelease = """
        {
            #if DEBUG
            guard let spec = ProcessInfo.processInfo.environment["X"], !spec.isEmpty else { return true }
            return spec != stage
            #else
            #endif
        }
        """
        #expect(seamProblems(emptyRelease).contains { $0.contains("Release") }, "Release 分支空转却全绿")
    }
}
