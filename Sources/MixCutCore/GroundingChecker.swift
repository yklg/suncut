import Foundation

/// 文案事实落地校验器（纯逻辑，可单测）。
///
/// 职责：从 AI 新撰文案中抽取**硬事实**（数字、含单位/百分号的量、拉丁专名/型号），
/// 校验每个事实都能在该文引用的资料片段原文里逐字找到 —— 找不到即为「无依据事实」，
/// 从结构上抑制 LLM 编造参数（如「99% 抑菌」资料里根本没有 99%）。
///
/// 边界（诚实声明）：
/// - 只校验可机械抽取的事实形态；纯叙述句的语义真实性不在本判据能力范围内；
/// - 中文专名因缺乏可靠命名实体识别不做抽取（避免误报洪水）；
/// - 文案里没有事实时返回「通过」（不是证据充分，而是无可判对象）。
public enum GroundingChecker {

    public struct Report: Equatable, Sendable {
        /// 抽取到的全部事实。
        public let facts: [String]
        /// 在任一引用片段中找不到出处的事实。
        public let unsupportedFacts: [String]

        public var isGrounded: Bool { unsupportedFacts.isEmpty }
    }

    /// 抽取硬事实（去重，保持出现顺序）：
    /// - 数字：`123`、`3.14`，可带常见单位/后缀 `%` `‰` `℃` `°` `倍` `万` `亿`；
    /// - 拉丁专名/型号：拉丁字母开头、含字母数字的 token（长度 ≥2，如 `ISO9001`、`FDA`、`iPhone16`）。
    public static func extractFacts(from text: String) -> [String] {
        var facts: [String] = []

        let numberPattern = #"\d+(?:\.\d+)?(?:%|‰|℃|°|倍|万|亿)?"#
        let latinPattern = #"[A-Za-z][A-Za-z0-9]{1,}"#

        for pattern in [numberPattern, latinPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let swiftRange = Range(match.range, in: text) else { return }
                facts.append(String(text[swiftRange]))
            }
        }

        // 去重保序；纯数字单位的「年/日」常见噪声（2024、2026）也保留为事实——
        // 年份本就该能在资料里找到，找不到说明是模型顺口编的时间。
        var seen = Set<String>()
        return facts.filter { seen.insert($0).inserted }
    }

    /// 校验文案事实是否都能在引用资料中落地。
    /// - Parameters:
    ///   - text: 待校验文案
    ///   - sources: 该文案引用的资料片段原文（已按引用关系取齐）
    public static func check(text: String, sources: [String]) -> Report {
        let facts = extractFacts(from: text)
        let haystack = sources.joined(separator: "\n")
        let unsupported = facts.filter { !haystack.contains($0) }
        return Report(facts: facts, unsupportedFacts: unsupported)
    }
}
