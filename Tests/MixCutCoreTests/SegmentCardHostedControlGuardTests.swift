import Foundation
import Testing

/// 滚动掉帧第 1 批的防线：**每卡常驻挂载的视图里不许再出现 AppKit 宿主控件**。
///
/// 依据是 2026-10-02 的两口径读数（`.scratch/scroll-after.trace` 等，计划文件
/// `glacial-canyon-crane.md` 里有并排表）：滚动窗口主线程样本里 **40.5% 的栈含
/// `PlatformViewHost`/`NSHostingView`**、32.5% 在 `NSView` 布局；把 `SegmentDubControls`
/// 里 `Toggle(.switch)` + 两颗 `Button` 换成自绘之后，主线程忙时 −42%、每帧 p99 88.9→22.3ms、
/// ≥50ms 的整段占用 22 段/4,082ms → 1 段/101ms。
///
/// ⚠️ 为什么需要这条守卫而不是文件顶那句注释：注释不报错。下一个加功能的人（包括下一次的我）
/// 在卡片里放一颗原生 `Toggle` 是"更规范"的写法，它会让这 2.9 秒/20 秒静默回来，且没有任何信号。
///
/// ⚠️ 作用域是**按 struct 切的**，不是按文件：`SubtitleFontSizePopover` 里的 `Button` 是弹层内容，
/// 只在展开时才建，不在这条判据的靶面上。判据若按文件数就会误报，然后被人整条关掉。
enum HostedControlScan {
    /// macOS 上会落到 AppKit 宿主视图的控件构造名。
    static let tokens: Set<String> = [
        "Toggle", "Button", "Menu", "Slider", "Picker", "Stepper",
        "TextEditor", "TextField", "SecureField", "ColorPicker", "DatePicker",
    ]

    struct Hit: Equatable {
        let line: Int
        let token: String
    }

    struct Result: Equatable {
        /// `false` = 连 struct 头都没找到 ⇒ 判据本身没跑起来，**不算通过**。
        let anchored: Bool
        let hits: [Hit]
    }

    /// 只扫 `marker`（形如 `"struct SegmentCard"`）起的那一个花括号块内部。
    static func hits(in src: String, inside marker: String) -> Result {
        var a = Array(TagRowHostScan.codeOnly(src))   // 复用那颗剥注释/剥字符串的公共件
        maskLazyClosures(&a)                          // 遮蔽 contextMenu/alert 等延迟闭包
        let n = a.count
        guard let head = indexOfSeq(a, marker) else { return Result(anchored: false, hits: []) }
        var i = head + marker.count
        while i < n, a[i] != "{" { i += 1 }
        guard i < n else { return Result(anchored: false, hits: []) }
        let openLine = newlines(a[0..<i]) + 1
        var depth = 0
        var j = i
        var end = n
        while j < n {
            if a[j] == "{" { depth += 1 }
            else if a[j] == "}" {
                depth -= 1
                if depth == 0 { end = j; break }
            }
            j += 1
        }
        return Result(anchored: true, hits: scanRegion(Array(a[i..<end]), startLine: openLine))
    }

    /// 遮蔽 SwiftUI 延迟构建的修饰符闭包：contextMenu / alert / sheet / popover /
    /// confirmationDialog 的内容只在用户触发时由 AppKit 构建，不是每卡常驻宿主。
    /// 做法：定位修饰符名，从其后第一个 `{` 按括号配对整段替换为空格（保留换行）。
    private static let lazyModifiers = [
        ".contextMenu", ".alert(", ".sheet(", ".popover(", ".confirmationDialog("
    ]

    private static func maskLazyClosures(_ a: inout [Character]) {
        for modifier in lazyModifiers {
            var searchFrom = 0
            while let range = findSeq(Array(a[searchFrom..<a.count]), modifier) {
                let found = searchFrom + range.lowerBound
                searchFrom = found + modifier.count
                // 找修饰符之后第一个 `{`
                var brace = searchFrom
                while brace < a.count, a[brace] != "{" { brace += 1 }
                guard brace < a.count else { break }
                var depth = 0
                var end = brace
                while end < a.count {
                    if a[end] == "{" { depth += 1 }
                    else if a[end] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    end += 1
                }
                guard end < a.count else { break }
                for k in brace...end where a[k] != "\n" { a[k] = " " }
                searchFrom = end + 1
            }
        }
    }

    private static func findSeq(_ hay: [Character], _ needle: String) -> Range<Int>? {
        let p = Array(needle)
        guard !p.isEmpty, hay.count >= p.count else { return nil }
        for s in 0...(hay.count - p.count) where hay[s] == p[0] {
            if Array(hay[s..<(s + p.count)]) == p { return s..<(s + p.count) }
        }
        return nil
    }

    private static func scanRegion(_ a: [Character], startLine: Int) -> [Hit] {
        let n = a.count
        var out: [Hit] = []
        var i = 0
        var line = startLine
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i < n {
            let c = a[i]
            if c == "\n" { line += 1; i += 1; continue }
            if isIdent(c) {
                var j = i
                while j < n, isIdent(a[j]) { j += 1 }
                let name = String(a[i..<j])
                if tokens.contains(name) {
                    var k = j
                    while k < n, a[k] == " " || a[k] == "\t" || a[k] == "\n" || a[k] == "\r" { k += 1 }
                    // 两种调用形状都得算：`Token(...)` 与尾闭包 `Token { } label: { }`。
                    // 只认前者会漏 —— 行内那颗 `Menu { … } label: { … }` 就是尾闭包，
                    // 我第一版就是这么漏掉真实代码里的宿主控件的。
                    if k < n, a[k] == "(" || a[k] == "{" { out.append(Hit(line: line, token: name)) }
                }
                i = j
                continue
            }
            // `.toggleStyle(` 单列一个信号：原生开关样式一旦在场，上面几乎必有 Toggle，
            // 但有人会把 Toggle 包进自己的 View 里只留 toggleStyle —— 那种照样是宿主。
            if c == "." {
                var j = i + 1
                while j < n, isIdent(a[j]) { j += 1 }
                if String(a[(i + 1)..<min(j, n)]) == "toggleStyle" {
                    out.append(Hit(line: line, token: ".toggleStyle"))
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    private static func indexOfSeq(_ hay: [Character], _ needle: String) -> Int? {
        let p = Array(needle)
        guard !p.isEmpty, hay.count >= p.count else { return nil }
        for s in 0...(hay.count - p.count) where hay[s] == p[0] {
            if Array(hay[s..<(s + p.count)]) == p { return s }
        }
        return nil
    }

    private static func newlines(_ slice: ArraySlice<Character>) -> Int {
        slice.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

// MARK: - 仓库根与读文件（形状同 TagRowContainerGuardTests）

private let hostRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func hostRead(_ rel: String) -> String {
    (try? String(contentsOf: hostRepoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

/// 每卡/每行常驻挂载路径上的文件。少一个就是扫描面窄一档。
private let perCardFiles = [
    "MixCut/Views/SegmentLibrary/SegmentLibraryView.swift",
    "MixCut/Views/Shared/SegmentCardCompact.swift",
]

// MARK: - 检测器自身：正向半边（每个 token 都得检出）

@Test("名单里每一颗宿主控件都必须被检出，写法变体也一样（取样面窄一档=恒绿）")
func everyTokenIsDetected() {
    for token in HostedControlScan.tokens {
        let src = "struct S: View {\n    var body: some View {\n        \(token)(x: 1)\n    }\n}\n"
        let r = HostedControlScan.hits(in: src, inside: "struct S")
        #expect(r.anchored, "连 struct 头都没找到，检测器没跑起来")
        #expect(r.hits.map(\.token) == [token], "\(token) 必须判红，实得 \(r.hits)")
        #expect(r.hits.first?.line == 3, "行号要指到调用那行：\(r.hits)")
    }
}

@Test("写法变体不许绕过：换行参数、带前缀的同名标识符、多一颗算多一颗")
func variantsAndPrefixes() {
    let multi = "struct S: View {\n var body: some View {\n  Toggle(\n   isOn: x) { Text(\"y\") }\n  Button(\n   action: f) { Text(\"z\") }\n }\n}\n"
    #expect(HostedControlScan.hits(in: multi, inside: "struct S").hits.count == 2)
    // 前缀不是命中：`SegmentDubControls(` 里不含 `Button(`，`MyButton(` 也不该算 Button
    #expect(HostedControlScan.hits(in: "struct S: View {\n SegmentDubControls(x: 1)\n MyButton(x: 1)\n}\n",
                                   inside: "struct S").hits.isEmpty)
    // 尾闭包形状：`Menu { … } label: { … }`、`Button { … } label: { … }` 也要算
    let trailing = "struct S: View {\n Menu { Text(\"a\") } label: { Text(\"b\") }\n Button { f() } label: { Text(\"c\") }\n}\n"
    let th = HostedControlScan.hits(in: trailing, inside: "struct S")
    #expect(th.hits.map(\.token).sorted() == ["Button", "Menu"], "尾闭包形状必须检出，实得 \(th.hits)")
    // `.toggleStyle` 单列一个信号
    let ts = "struct S: View {\n Toggle(isOn: x) {}\n .toggleStyle(.switch)\n}\n"
    #expect(HostedControlScan.hits(in: ts, inside: "struct S").hits.count == 2)
}

@Test("负半边：注释与字符串里的 Toggle( 不算，struct 之外的也不算")
func commentsStringsAndScope() {
    #expect(HostedControlScan.hits(in: "// Toggle(isOn: x)\nstruct S: View { }\n", inside: "struct S").hits.isEmpty)
    #expect(HostedControlScan.hits(in: "let s = \"Button(\"\nstruct S: View { }\n", inside: "struct S").hits.isEmpty)
    // struct 闭括号之后的一颗 Toggle 不在靶面上（作用域按 struct 切，不是按文件切）
    let outside = "struct S: View {\n Text(\"a\")\n}\nstruct Other: View {\n Button(x: 1)\n}\n"
    let r = HostedControlScan.hits(in: outside, inside: "struct S")
    #expect(r.anchored && r.hits.isEmpty, "struct 外的 Button 不该算进来：\(r.hits)")
    // struct 里的才算
    let inside = "struct S: View {\n Button(x: 1)\n}\n"
    #expect(HostedControlScan.hits(in: inside, inside: "struct S").hits.count == 1)
}

@Test("锚点找不到时必须报「判据没跑起来」，不许静默变绿")
func missingAnchorIsNotAPass() {
    let r = HostedControlScan.hits(in: "struct Whatever: View { Text(1) }\n", inside: "struct SegmentDubControls")
    #expect(!r.anchored)
    #expect(r.hits.isEmpty)
}

// MARK: - 真实代码

@Test("扫描根健全：三个每卡路径文件都必须读得到且含 struct")
func scanRootIsSane() {
    for f in perCardFiles {
        let src = hostRead(f)
        if src.count < 200 || !src.contains("struct ") {
            Issue.record("\(f) 读不到或不含 struct —— 判据本身没跑起来，不算通过")
        }
    }
}

@Test("瘦化防线：SegmentCard / SegmentRow（常驻网格单元）必须零宿主控件")
func cardsAndRowsAreHostControlFree() {
    let src = hostRead("MixCut/Views/SegmentLibrary/SegmentLibraryView.swift")
    for marker in ["struct SegmentCard", "struct SegmentRow"] {
        let r = HostedControlScan.hits(in: src, inside: marker)
        if !r.anchored {
            Issue.record("没找到 `\(marker)` —— 判据没跑起来，不算通过")
            continue
        }
        #expect(r.hits.isEmpty,
                "常驻单元内又出现 AppKit 宿主控件：\(r.hits)。编辑动作应进 Inspector；要例外请带新的每帧实测数字显式改判据。")
    }
}

@Test("紧凑选择卡（抽屉/排序面板）只允许 Button（整卡点按），其余重宿主零出现")
func compactCardOnlyAllowsButtonWrapper() {
    let src = hostRead("MixCut/Views/Shared/SegmentCardCompact.swift")
    let r = HostedControlScan.hits(in: src, inside: "struct SegmentCardCompact")
    #expect(r.anchored, "没找到 `struct SegmentCardCompact`")
    let heavy = r.hits.filter { $0.token != "Button" }
    #expect(heavy.isEmpty, "紧凑卡只允许整卡 Button，实得重宿主：\(heavy)")
}

@Test("反向对照（真码）：卡片域换回原生 Toggle，守卫必须立刻变红")
func mutatingCardBackToNativeTurnsItRed() {
    let src = hostRead("MixCut/Views/SegmentLibrary/SegmentLibraryView.swift")
    // 在 SegmentCard 的 body 内植入一颗原生 Toggle（模拟控件回流）
    guard let range = src.range(of: "struct SegmentCard") else {
        Issue.record("没找到 struct SegmentCard")
        return
    }
    let searchRange: Range<String.Index> = range.lowerBound..<src.endIndex
    let mutated = src.replacingOccurrences(of: "var body: some View {",
                                           with: "var body: some View {\n Toggle(isOn: .constant(false)) { Text(\"x\") }",
                                           options: [], range: searchRange)
    #expect(mutated != src, "变异没落地，对照作废")
    let r = HostedControlScan.hits(in: mutated, inside: "struct SegmentCard")
    #expect(r.hits.contains(where: { $0.token == "Toggle" }),
            "回流的 Toggle 必须被抓到，实得 \(r.hits)")
}
