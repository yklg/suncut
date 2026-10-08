import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// PB · prompt 模板「不教模型数字数」守卫
//
// ## 为什么需要这道守卫（一次真实故障）
//
// 2026-10-08 用户实测：`deepseek-v4-flash` 改写失败，报「模型这次没有输出正文」。
// 原始响应留证（`ai-fail-2026-10-07T16-29-46Z.json`）显示：
//
//     "content": "",                                  ← 正文空
//     "reasoning_content": "We need answer JSON only. Need rewrite one segment.
//       Original: \"金黄色的果肉…\" Count? … Let's count: 金1 黄2 色3 的4 果5 …
//       Yes 23. Allow 23-26. Must not shorter. …
//       First 4 = 金黄色的. So first 4 = 金黄色的. New: [金黄色果"
//     "finish_reason": "length"                      ← 撞 8192 上限
//
// 模型把 8192 token 全烧在**逐字数字数**上（数原文、算区间、反复重算「前 4 个字」），
// 正文一个字都没轮到写。
//
// 诱因是 prompt 同时给了四个数字：原字数=N、目标≈N、允许 N~M、以及「前 4 个字不得相同」。
//
// ## 这条守卫守护什么
//
// 「prompt 里不许出现精确字数区间 / 让模型数字数」这条纪律，**只写在注释里是不够的**
// —— `.md` 是资源文件、不参与 Swift 编译，改回去不会有任何测试变红。
// ⇒ 用源码级断言把它钉住。
// ============================================================================

private func promptTemplate(_ name: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MixCutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 包根
let path = root.appendingPathComponent("MixCut/Resources/Prompts").appendingPathComponent(name)
    return try String(contentsOf: path, encoding: .utf8)
}

@Test("PB-1 改写模板不得出现精确字数区间（否则推理模型会逐字数字数、正文被思考挤空）")
func pb1_noExactCharRangeInRewriteTemplate() throws {
    let tpl = try promptTemplate("script_rewrite_prompt.md")
    // 形如「允许 23~26」「10-12 字」的精确区间
    let rangePatterns = [#"允许\s*\d+\s*[\-–~]\s*\d+"#, #"\d+\s*[\-–~]\s*\d+\s*字"#]
    for p in rangePatterns {
        #expect(tpl.range(of: p, options: .regularExpression) == nil,
                "改写模板出现精确字数区间（匹配 \(p)）：会把模型逼进逐字数字数 ⇒ 正文被思考挤空")
    }
    #expect(!tpl.contains("允许区间"), "改写模板不得再要求「必须落在允许区间内」")
}

@Test("PB-2 改写模板不得要求「前 N 个字」逐字比对（实测诱发反复重算）")
func pb2_noFirstNCharsRequirement() throws {
    let tpl = try promptTemplate("script_rewrite_prompt.md")
    #expect(tpl.range(of: #"前\s*\d+\s*个字"#, options: .regularExpression) == nil,
            "改写模板不得要求「前 N 个字」逐字比对——实测会让推理模型反复重算")
}

@Test("PB-3 改写模板保留「不得更短」的定性要求（不能因去数字而丢掉对齐依据）")
func pb3_keepsQualitativeLengthRequirement() throws {
    let tpl = try promptTemplate("script_rewrite_prompt.md")
    #expect(tpl.contains("不得更短") || tpl.contains("略长不略短"),
            "放宽字数 ≠ 取消长度要求：短于原文会让 TTS 配音末尾露空挡（见AlignmentPlan）")
    #expect(tpl.contains("自动校验") || tpl.contains("会自动重试"),
            "应告知模型字数由本机校验，让它专注写文案而非数字数")
}

@Test("PB-4 反向对照：守卫本身非恒绿（把区间塞回去必须变红）")
func pb4_guardIsNotAlwaysGreen() {
    // 直接用与 PB-1 相同的正则，验证它确实能抓住区间（否则 PB-1 是假绿）。
    let bad = "每条新台词必须落在「允许 23~26字」内。"
    let hit = bad.range(of: #"允许\s*\d+\s*[\-–~]\s*\d+"#, options: .regularExpression)
    #expect(hit != nil, "守卫正则失效：注入的区间都没被抓住⇒ PB-1 会是假绿")

    let good = "每条新台词长度与原台词相当、宁可略长不略短即可。"
    let noHit = good.range(of: #"允许\s*\d+\s*[\-–~]\s*\d+"#, options: .regularExpression)
    #expect(noHit == nil, "定性表述被误判成区间 ⇒ 守卫规则过宽")
}