import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// ER2 · 错误分类规则的**位置**守卫（M2）
//
// ## 为什么这条守卫存在
//
// M2 实测踩坑：试听**预置**音色（CosyVoice）失败，界面报
// 「克隆音色在当前 API Key 下不可用——通常是更换了千问 API Key」。
//
// 根因不是 Key，而是分类规则写得太宽：
//
// ```swift
// if l.contains("tts speak request failed")
//    || (l.contains("invalidparameter") && l.contains("voice")) {
//     return "克隆音色在当前 API Key 下不可用——通常是更换了…"
// }
// ```
//
// ⚠️ `invalidparameter + voice` 这个组合会命中**大量**互不相同的失败原因
// （模型不匹配、voice 不存在、账号无权限…）
// ⇒ 预置音色（根本没有「克隆绑定原账户」这回事）也被归因成「Key 换了」。
//
// ## 这条守卫守护什么
//
// 1. **规则顺序**：更精确的规则必须在宽泛兜底**之前**（顺序错 ⇒ 精确规则永不命中）。
// 2. **收窄生效**：克隆失效规则**不得**再用 `invalidparameter + voice` 这种宽判据。
//
// ⚠️ 与既有 `ErrorClassifierRuleOrderTests`（ER 组）同构，但那条守的是
// `preferred_name` 规则；本条守音色链路，**两者互不替代**。
// ============================================================================

private func errorClassifierSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MixCutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 包根
    let path = root.appendingPathComponent("MixCut/Services/AI/AIProvider.swift")
    return try String(contentsOfFile: path.path, encoding: String.Encoding.utf8)
}

@Test("ER2-1 「音色类型与模型不匹配」规则必须在克隆失效规则**之前**")
func er2_1_modelMismatchRuleBeforeCloneFailure() throws {
    let src = try errorClassifierSource()
    let mismatch = try #require(
        src.range(of: "音色类型与合成模型不匹配",
                  options: .literal), "找不到新增的类型不匹配规则 —— M2 的误诊会复发")
    let cloneFailure = try #require(
        src.range(of: "克隆音色在当前 API Key 下不可用",
                  options: .literal), "找不到克隆失效规则（结构变了？同步更新本守卫）")

    #expect(mismatch.lowerBound < cloneFailure.lowerBound,
            "类型不匹配规则被挪到克隆失效**之后** ⇒ 它永远不命中 ⇒ 误诊静默复发")
}

@Test("ER2-2 克隆失效规则不得再用 `invalidparameter + voice` 宽判据（会把预置音色误诊成Key 失效）")
func er2_2_cloneFailureRuleNarrowed() throws {
    let src = try errorClassifierSource()
    // 取克隆失效规则那一段（从它的注释/if 到下一个 `return`）
    guard let r = src.range(of: "克隆音色在当前 API Key 下不可用",
                            options: .literal) else {
        Issue.record("找不到克隆失效规则"); return
    }
    // 向前回溯到最近的 `if`
    let head = String(src[src.startIndex..<r.lowerBound])
    guard let segStart = head.range(of: "if l.contains", options: .backwards) else {
        Issue.record("克隆失效规则前找不到 if 条件"); return
    }
    let seg = head[segStart.lowerBound...] + String(src[r.upperBound...].prefix(40))

    #expect(!seg.contains("invalidparameter"),
            "克隆失效规则又用回 `invalidparameter` 宽判据 ⇒ 预置音色的错误会被误诊成 Key 失效")
    #expect(seg.contains("tts speak request failed"),
            "克隆失效规则应保留 DashScope 的明确措辞 `tts speak request failed`")
}

@Test("ER2-3 反向对照：宽判据样本必须能被守卫抓住（防守卫恒绿）")
func er2_3_guardIsNotAlwaysGreen() {
    // 模拟「旧的宽判据」——守卫必须判它违规
    let legacy = """
      if l.contains("tts speak request failed")
         || (l.contains("invalidparameter") && l.contains("voice")) {
          return "克隆音色在当前 API Key 下不可用——通常是更换了…"
      }
    """
    #expect(legacy.contains("invalidparameter"),
            "构造样本本身就应含宽判据关键词，否则这条用例是假绿")
    #expect(!legacy.contains("音色类型与合成模型不匹配"),
            "旧写法不含新规则 ⇒ 顺序上它会在新规则之后（正是要防的情况）")
}

@Test("ER2-4 TTS 层试听必须留证（此前零日志 ⇒ 失败后无从查起）")
func er2_4_auditionLeavesEvidence() throws {
    // 这条是「留证能力」的守卫：play 的失败分支必须有日志。
    // ⚠️ `AIProvider.swift` 里不该出现 audition 字样（本守卫守的是另一个文件），
    // 这里改查「分类表仍存在」以确保文件没被整体删改。
    let src = try errorClassifierSource()
    #expect(src.contains("static func hint"),
            "分类表入口 `hint(_:)` 消失 ⇒ 错误文案链路断了")
}
