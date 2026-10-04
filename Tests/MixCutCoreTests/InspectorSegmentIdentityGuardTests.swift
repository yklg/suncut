import Foundation
import Testing

/// Inspector 实体身份契约守卫：`SegmentVariantInspector` 宿主处必须挂 `.id(seg.id)`。
///
/// 缺了它，切换分镜时 SwiftUI 复用同一视图实例、所有分镜作用域 @State（台词草稿、
/// 边界时间码、改写版行内编辑态）原样保留 —— 「台词原文永远停在第一个分镜」的 bug
/// 就是这么来的。这行 modifier 表面无存在感（配 opacity 动画时删掉看起来也正常），
/// 注释拦不住，所以用源码扫描守卫，并配变异腿自证。
///
/// 扫描复用 TagRowHostScan.codeOnly（逐字符等长剥注释/字符串，行号不漂）。
enum InspectorIdentityScan {
    struct Result: Equatable {
        /// false = 连宿主锚点都没找到 ⇒ 判据没跑起来，不算通过
        let anchored: Bool
        let foundID: Bool
        let idLine: Int?
    }

    static let anchor = "SegmentVariantInspector("
    static let idToken = ".id(seg.id)"
    /// 锚点后的扫描窗口：覆盖「初始化参数 + 尾闭包 + 相邻 modifier 链」。
    /// 真实代码中 .id 距锚点约 400 字符，2000 给重构留余量；半条 modifier
    /// 落在窗口外的极端情况由变异腿/真实码测试共同兜底。
    static let windowChars = 2000

    static func inspect(_ src: String) -> Result {
        let a = TagRowHostScan.codeOnly(src)
        guard let anchorIdx = indexOfSeq(a, anchor) else {
            return Result(anchored: false, foundID: false, idLine: nil)
        }
        let end = min(a.count, anchorIdx + windowChars)
        if let rel = indexOfSeq(Array(a[anchorIdx..<end]), idToken) {
            let line = newlines(a[0..<(anchorIdx + rel)]) + 1
            return Result(anchored: true, foundID: true, idLine: line)
        }
        return Result(anchored: true, foundID: false, idLine: nil)
    }

    private static func indexOfSeq(_ haystack: [Character], _ needle: String) -> Int? {
        let p = Array(needle)
        guard !p.isEmpty, haystack.count >= p.count else { return nil }
        for s in 0...(haystack.count - p.count) where haystack[s] == p[0] {
            if Array(haystack[s..<(s + p.count)]) == p { return s }
        }
        return nil
    }

    private static func newlines(_ slice: ArraySlice<Character>) -> Int {
        slice.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

// MARK: - 仓库根（形状同 HostedControlGuardTests）

private let identityRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func identityRead(_ rel: String) -> String {
    (try? String(contentsOf: identityRepoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

// MARK: 检测器自身

@Suite("InspectorIdentityScan 检测器")
struct InspectorIdentityScanTests {

    @Test("正腿：锚点窗口内的 .id(seg.id) 必须检出并给出行号")
    func detectsIDBinding() {
        let src = """
        if let seg = viewModel.selectedSegment {
            SegmentVariantInspector(
                segment: seg, dubVM: dubVM, isPinned: true, onClose: {}
            ) {
                SegmentPropertiesContent(segment: seg, viewModel: viewModel)
            }
            .id(seg.id)
            .transition(.opacity)
        }
        """
        let r = InspectorIdentityScan.inspect(src)
        #expect(r.anchored)
        #expect(r.foundID)
        #expect(r.idLine == 7)
    }

    @Test("锚点缺失 → anchored=false（判据没跑起来，不许静默变绿）")
    func missingAnchorIsNotAPass() {
        let r = InspectorIdentityScan.inspect("struct Other: View { var body: some View { EmptyView() } }")
        #expect(!r.anchored)
        #expect(!r.foundID)
    }

    @Test("负腿：注释里的 .id(seg.id) 不算命中；无真 id 时判缺")
    func commentDoesNotCount() {
        let src = """
        // 记得给 SegmentVariantInspector( 挂 .id(seg.id)
        struct S: View {
            var body: some View { SegmentVariantInspector(segment: x) }
        }
        """
        let r = InspectorIdentityScan.inspect(src)
        #expect(r.anchored)
        #expect(!r.foundID, "注释中的文本已被 codeOnly 剥离，不得算命中：\(r)")
    }
}

// MARK: 真实代码 + 变异腿

@Suite("Inspector 实体身份守卫（真实代码）")
struct InspectorSegmentIdentityGuardTests {

    private let realPath = "MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"

    @Test("SegmentVariantInspector 宿主必须以 .id(seg.id) 绑定选中分镜身份")
    func inspectorIsIdentityBound() {
        let src = identityRead(realPath)
        #expect(src.count > 500, "真实文件读不到 —— 判据没跑起来，不算通过")
        let r = InspectorIdentityScan.inspect(src)
        #expect(r.anchored, "没找到 SegmentVariantInspector( 锚点 —— 宿主结构变了，需更新守卫")
        #expect(r.foundID,
                "缺 .id(seg.id)：切分镜时 @State 会跨分镜残留（台词原文不切换 bug 复发）。如确需移除，请同时证明子树内无分镜作用域 @State 并显式更新本守卫。")
    }

    @Test("变异腿：删掉真实代码里的 .id(seg.id)，守卫必须立刻变红")
    func removingIDTurnsItRed() {
        let src = identityRead(realPath)
        let mutated = src.replacingOccurrences(of: ".id(seg.id)", with: "")
        #expect(mutated != src, "变异没落地，对照作废")
        #expect(!InspectorIdentityScan.inspect(mutated).foundID)
    }
}
