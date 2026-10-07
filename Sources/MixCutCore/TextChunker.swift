import Foundation

/// 文本切块器 —— 把长篇资料切成适合 embedding / 检索的 chunk。
///
/// 规则：
/// - 按字符预算切块（默认每块 500 字、相邻块重叠 80 字），重叠保证跨块语义不被切断；
/// - 优先在句号/问号/叹号/换行等自然边界断开，避免半句话成块；
/// - 若整段没有任何可断边界（超长无标点串），按预算强切。
public enum TextChunker {

    public struct Chunk: Equatable, Sendable {
        public let index: Int
        public let text: String
    }

    /// 自然断句边界字符。
    static let boundaryCharacters: Set<Character> = [
        "。", "！", "？", "；", "\n", "…", "」", "”", ".", "!", "?", ";"
    ]

    /// 主入口。
    /// - Parameters:
    ///   - text: 原文
    ///   - chunkSize: 单块目标字符数（默认 500）
    ///   - overlap: 相邻块重叠字符数（默认 80，须 < chunkSize）
    public static func chunks(
        in text: String,
        chunkSize: Int = 500,
        overlap: Int = 80
    ) -> [Chunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, chunkSize > 0 else { return [] }
        let safeOverlap = max(0, min(overlap, chunkSize - 1))

        let characters = Array(trimmed)
        guard characters.count > chunkSize else {
            return [Chunk(index: 0, text: trimmed)]
        }

        var result: [Chunk] = []
        var start = 0

        while start < characters.count {
            var end = min(start + chunkSize, characters.count)

            // 不在文末时，确定断点开在哪里。语义：标点跟随它所属的前一句。
            if end < characters.count {
                if boundaryCharacters.contains(characters[end]) {
                    // end 紧邻边界：把标点收入当前块
                    end = end + 1
                } else {
                    // 向回寻找最近的自然边界（至少留一半预算，否则碎片过多）
                    var boundary = end - 1
                    let minEnd = start + chunkSize / 2
                    while boundary >= minEnd {
                        if boundaryCharacters.contains(characters[boundary]) {
                            end = boundary + 1
                            break
                        }
                        boundary -= 1
                    }
                }
            }

            let piece = String(characters[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                result.append(Chunk(index: result.count, text: piece))
            }

            if end >= characters.count { break }
            // 下一块回退 overlap；防御死循环（回退必须至少前进 1 字）
            start = max(end - safeOverlap, start + 1)
        }
        return result
    }
}
