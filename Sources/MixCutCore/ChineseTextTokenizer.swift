import Foundation

/// 中文混合文本分词器 —— BM25 建索引与查询解析的唯一入口。
///
/// 设计取舍（2026-10 多源实践一致）：
/// - Swift 侧没有成熟、免词典的中文分词器，自研词典维护成本高；字粒度在「短 chunk + RRF + rerank」
///   链路下噪声被充分收敛。
/// - CJK 段同时产出 **unigram（单字）+ bigram（相邻两字）**：单字保住召回，双字覆盖「螨虫/高频」
///   这类天然双字词；
/// - 拉丁/数字段（型号 `K-8000`、英文、价格）按**整词**切出并小写归一，保住精确匹配的优势；
/// - 高频单字停用词过滤做成可测的内置小词表。
public enum ChineseTextTokenizer {

    /// 一个切分后的词元。
    public struct Token: Equatable, Sendable {
        public let text: String
        public let isCJK: Bool
    }

    /// 高频虚词/标点停用表（仅作用于 CJK 单字；bigram 不过滤，避免误杀双字词）。
    static let stopWords: Set<Character> = [
        "的", "了", "是", "我", "你", "他", "她", "它", "们", "在",
        "和", "就", "都", "而", "及", "与", "这", "那", "也", "还",
        "把", "被", "让", "向", "为", "对",
        "，", "。", "！", "？", "、", "；", "：", "「", "」", "“", "”", "（", "）"
    ]

    /// 主入口：把任意文本切成索引/查询词元。
    /// - Parameters:
    ///   - text: 原文
    ///   - removeStopWords: 建索引/查询时是否过滤停用词（默认 true）
    public static func tokens(in text: String, removeStopWords: Bool = true) -> [Token] {
        var result: [Token] = []
        var cjkBuffer = ""

        func flushCJK() {
            guard !cjkBuffer.isEmpty else { return }
            let chars = Array(cjkBuffer)
            // unigram
            for ch in chars {
                if removeStopWords && stopWords.contains(ch) { continue }
                result.append(Token(text: String(ch), isCJK: true))
            }
            // bigram：相邻两字；任一端为停用词仍保留 bigram（双字词不过滤）
            if chars.count >= 2 {
                for i in 0..<(chars.count - 1) {
                    let pair = String(chars[i]) + String(chars[i + 1])
                    result.append(Token(text: pair, isCJK: true))
                }
            }
            cjkBuffer = ""
        }

        var latinBuffer = ""

        func flushLatin() {
            guard !latinBuffer.isEmpty else { return }
            // 拉丁-数字段按下划线/空白/连字符再拆成整词；连字符在型号中保留为单一词
            let words = latinBuffer.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "_" })
            for w in words {
                let cleaned = w.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
                if !cleaned.isEmpty {
                    result.append(Token(text: String(cleaned), isCJK: false))
                }
            }
            latinBuffer = ""
        }

        for ch in text {
            if Self.isCJK(ch) {
                flushLatin()
                cjkBuffer.append(ch)
            } else if ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == "/" || ch == "_" || ch == " " {
                flushCJK()
                latinBuffer.append(ch)
            } else {
                // 其他标点/符号：结束两段、不产生词元
                flushCJK()
                flushLatin()
            }
        }
        flushCJK()
        flushLatin()
        return result
    }

    /// 仅取词面（BM25 实际使用的形式）。
    public static func tokenStrings(in text: String, removeStopWords: Bool = true) -> [String] {
        tokens(in: text, removeStopWords: removeStopWords).map(\.text)
    }

    /// CJK 判定：常用 CJK 统一表意文字与扩展 A、兼容汉字、全角假名范围。
    static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,      // 平/片假名
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 统一表意
             0xF900...0xFAFF,      // CJK 兼容表意
             0x20000...0x2A6DF:    // 扩展 B+
            return true
        default:
            return false
        }
    }
}
