import Foundation

/// 粘贴文案的逐句切行器（纯逻辑，可单测）。
///
/// 逆向结构化契约：**原文逐字保留**——切段只发生在本机，不经过 LLM，
/// 从结构上保证「逆向不改写」，LLM 只负责给切好的行打标签。
///
/// 规则：
/// 1. 先按用户已有的换行切（用户自己分好段就尊重）；
/// 2. 非空行再按句末标点（。！？；… .!?；以及引号收尾）细切，标点留在上一句；
/// 3. 过短碎片（≤3 字）并入相邻行，避免一句话被标点拆碎后单独成行。
public enum PastedScriptLines {

    public struct Line: Equatable, Sendable {
        public let index: Int
        public let text: String
    }

    static let sentenceEnders: Set<Character> = [
        "。", "！", "？", "；", "…", ".", "!", "?", ";",
    ]

    public static func lines(in raw: String) -> [Line] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var fragments: [String] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // 碎片合并只在**同一条用户行内**进行：用户主动敲的换行是硬边界，
            // 哪怕这行只有 2–3 个字也是他自己分好的段，跨换行合并会把用户的
            // 分段意图抹掉（送 LLM 打标的行数/粒度随之全错）。
            fragments.append(contentsOf: mergeShortFragments(splitSentences(line)))
        }

        return fragments.enumerated().map { Line(index: $0.offset + 1, text: $0.element) }
    }

    /// 按句末标点切句，标点附在前句；成对引号（」”）跟在句末标点后时一并收走。
    static func splitSentences(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var buffer = ""

        var index = 0
        while index < characters.count {
            let ch = characters[index]
            buffer.append(ch)
            if sentenceEnders.contains(ch) {
                // 吃掉紧随的右引号/右括号
                var next = index + 1
                while next < characters.count,
                      characters[next] == "”" || characters[next] == "」" || characters[next] == "）" {
                    buffer.append(characters[next])
                    next += 1
                }
                let trimmed = buffer.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                buffer = ""
                index = next
                continue
            }
            index += 1
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// ≤3 字的碎片并入相邻句（优先并入前句；首行碎片并入后句）。
    static func mergeShortFragments(_ fragments: [String]) -> [String] {
        let threshold = 3
        var result: [String] = []
        for fragment in fragments {
            if fragment.count <= threshold {
                if !result.isEmpty {
                    result[result.count - 1] += fragment
                } else {
                    result.append(fragment)   // 暂存，等下一句来并
                }
            } else {
                if !result.isEmpty, result[result.count - 1].count <= threshold {
                    result[result.count - 1] += fragment
                } else {
                    result.append(fragment)
                }
            }
        }
        return result
    }
}
