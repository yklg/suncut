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
// 现状（2026-10-10 实读）：咽喉里两次 safeSave 都是丢返回值的裸调用 ——
//   commitDelete 内第一次：删完 pv 就落盘，好让 cascade 摘掉 video.projectVideos 反向数组
//                          （这次不能合并到循环外，UG-G11 守的就是它的**位置**）
//   commitDelete 内第二次：真删视频记录与分镜之后收尾
// 所以这里先做**名册式冻结**（GT-01：一处都不许多），同时把理想态钉成红钉（GT-02：应为 0 处）。
// 批 2 落地时 GT-02 自己变红 ⇒ 摘标并把期望改成 0，那一刻这条判据才算真正闭合。
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

@Suite("视频删除咽喉 · safeSave 返回值不许被静默丢弃")
struct VideoDeletionThroatGuardTests {

    /// 读咽喉源码并定位 commit 函数体；取不到就 Issue.record（不许当成通过）。
    private func throatBodyOrRecord() -> String? {
        let url = throatRepoRoot.appendingPathComponent(throatFile)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("读不到 \(throatFile) ⇒ 判据无法成立，不算通过")
            return nil
        }
        let code = RelationshipReadScan.codeOnly(raw)      // 复用仓里已有的那颗剥注释，不另写第二把尺子
        for head in throatHeads {
            if let b = functionBody(code: code, head: head) { return b }
        }
        let heads = throatHeads.joined(separator: " / ")
        Issue.record("取不到咽喉的 commit 函数体（\(heads) 都不在）⇒ 判据失效：批 2 改了名却没把锚点搬过来")
        return nil
    }

    @Test("GT-01 名册式冻结：咽喉里丢弃返回值的 safeSave 必须恰好 2 处，一处都不许多")
    func discardedSavesAreRostered() {
        guard let body = throatBodyOrRecord() else { return }
        let n = discardedSaveCount(body)
        // 期望值不是"函数返回几就算几"：这 2 处是实读数出来的（第一次为 cascade 落盘、第二次收尾），
        // 想再加第 3 处必须先在这里登记理由 —— 新增静默丢弃正是 P0-2 要防的放大路径。
        #expect(n == 2, "咽喉里丢弃返回值的 safeSave 实得 \(n) 处，名册登记 2 处（多一处＝新的静默丢弃）")
        // 自证非空：函数体里确实有 safeSave，否则上面的 2 永远不可能成立，而 0 也会被当成"通过"
        #expect(body.contains("safeSave()"), "函数体里没有 safeSave ⇒ 锚点搬错地方了")
    }

    @Test("GT-02 理想态：咽喉里不该有任何一处静默丢弃 save 结果（批 2 修好后本条会因不再有问题而红 ⇒ 摘标）")
    func noSaveResultShouldBeDiscarded() {
        guard let body = throatBodyOrRecord() else { return }
        let n = discardedSaveCount(body)
        withKnownIssue("P0-2 未修：咽喉里 \(n) 处 safeSave() 都丢了 Bool（@discardableResult ⇒ 连警告都没有），失败只打日志；批量删除时会放大成部分失败无人出声——前 k 条落盘、第 k+1 条失败，而 undo 把全部 N 条放回界面。修法见方案批 2：false ⇒ 停止本批、报「已删 k / 未删 N−k」、undo 只回填未删成功的那部分") {
            #expect(n == 0, "实得 \(n) 处静默丢弃")
        }
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
}
