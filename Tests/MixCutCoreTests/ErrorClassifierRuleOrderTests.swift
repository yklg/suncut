import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// ER · 错误分类器「规则顺序」的源码级守卫
//
// ## 为什么用源码级而不是行为级
//
// `APIErrorClassifier` 在 **App 层**（`MixCut/Services/AI/AIProvider.swift`），
// 而本仓 App 层**没有测试载体**（`Package.swift` 只有 MixCutCoreTests，
// xcodeproj 无 test target——见 `.workbuddy/plans/app-test-target-bootstrap.md`）。
// ⇒ 行为级断言写不了。
//
// 但 skill 要求的守卫形态恰恰是「测既有测试的源码」同构的：
// **约束必须机器可校验**，否则纪律只写在文档里。
//
// ## 为什么这条规则值得钉
//
// M2 实测：注册音色时服务端返
//   InvalidParameter: Required input 'preferred_name' is invalid
// 而分类器的 400 兜底把它**误诊**为「模型名称或接口地址与该平台不匹配」，
// 把用户引去改完全无关的设置。
// 修复是新增一条更精确的规则，但**它的位置比它的内容更重要** ——
// 一旦被挪到 400 兜底之后，误诊会**静默复发**（测试全绿、体验照旧差）。
// ============================================================================

/// 读 App 层源码（相对仓库根）。测试在 Core 包内，故按 #filePath 上溯三层。
private func appSource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MixCutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 包根
    let path = root.appendingPathComponent(relative)
    return try String(contentsOf: path, encoding: .utf8)
}

@Test("ER-1 preferred_name 规则必须排在 400 兜底规则**之前**（否则误诊静默复发）")
func er1_preferredNameRuleBeforeFallback() throws {
    let code = try appSource("MixCut/Services/AI/AIProvider.swift")

    let precise = code.range(of: "l.contains(\"preferred_name\")")
        ?? code.range(of: "l.contains(\"voice_name\")")
    #expect(precise != nil, "找不到 preferred_name 规则 —— 分类器里缺这条 ⇒ M2 的误诊会复发")

    let fallback = code.range(of: "l.contains(\"http 400\")")
    #expect(fallback != nil, "找不到 400 兜底规则（结构变了？同步更新本守卫）")

    if let p = precise, let f = fallback {
        #expect(p.lowerBound < f.lowerBound,
                "preferred_name 规则被挪到 400 兜底**之后** ⇒ 它永远不命中 ⇒ 误诊复发")
    }
}

@Test("ER-2 400 兜底规则必须保留（其他 400 仍需要它兜底，不能删）")
func er2_fallbackStillExists() throws {
    let code = try appSource("MixCut/Services/AI/AIProvider.swift")
    #expect(code.contains("l.contains(\"http 400\")"),
            "400 兜底被删了 ⇒ 其他 400 错误会直接抛原文给用户")
}

@Test("ER-3 命中 hint 时不再铺开原始 JSON（request_id 淹没红字）")
func er3_rawDetailFoldedByDefault() throws {
    let code = try appSource("MixCut/Services/AI/AIProvider.swift")
    #expect(code.contains("includeRawDetail: Bool = false"),
            "friendly() 的 includeRawDetail 应默认 false（折叠原始响应）")
    // ⚠️ 这条**不能**反过来写死「必须拼接原文」—— 那是缺陷不是契约。
    // 判据放在参数默认值上：默认折叠、需要时可显式打开。
    #expect(code.contains("guard includeRawDetail else { return hint }"),
            "折叠分支缺失 ⇒ 命中 hint 时仍会铺开 200 字符 JSON")
}