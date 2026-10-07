import Foundation

/// HTML → 纯文本的轻量剥离器（电商页/普通网页正文提取）。
///
/// 取舍：不引入 SwiftSoup（工程零 SPM 远程包、App 非沙盒），用正则覆盖提取场景：
/// - 先剔除 script/style/noscript 整块；
/// - 块级标签（div/p/br/li/tr/h1-6…）转换行；
/// - 其余标签直接移除；
/// - 解码常见 HTML 实体；连续空白折叠。
/// 若未来需要严格 HTML5 容错，可在同一协议后替换实现。
public enum HTMLTextStripper {

    /// 主入口。
    public static func plainText(from html: String) -> String {
        var text = html

        // 1) 剔除不含正文的元素块（含其内容）
        let hiddenPatterns = [
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<noscript[^>]*>.*?</noscript>",
            "(?is)<!--.*?-->"
        ]
        for pattern in hiddenPatterns {
            text = replacing(pattern, in: text, with: "")
        }

        // 2) 块级标签 → 换行（先插入换行，移除标签后自然分段）
        let blockPattern = try? NSRegularExpression(
            pattern: "(?i)</?(?:p|div|br|li|ul|ol|tr|td|th|table|h[1-6]|section|article|header|footer|hr|blockquote)[^>]*>")
        text = replaceAll(blockPattern, in: text, with: "\n")

        // 3) 移除所有剩余标签
        text = replacing("(?is)<[^>]+>", in: text, with: "")

        // 4) 实体解码
        text = decodeEntities(text)

        // 5) 空白折叠：每行去两端空白，空行合并，最多保留一个空行
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return replaceAll(regex, in: text, with: replacement)
    }

    static func replaceAll(_ regex: NSRegularExpression?, in text: String, with replacement: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    /// 常见 HTML 实体（命名实体 + 数字实体）。
    static let namedEntities: [String: String] = [
        "&nbsp;": "\u{00A0}", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'",
        "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
        "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’",
        "&deg;": "°", "&plusmn;": "±", "&times;": "×", "&divide;": "÷",
        "&copy;": "©", "&reg;": "®", "&trade;": "™",
        "&yen;": "¥", "&euro;": "€", "&pound;": "£", "&cent;": "¢"
    ]

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // 数字实体：&#xHHHH;（十六进制）/ &#NNNN;（十进制）。从后往前替换以保持位置有效。
        result = replaceNumericEntities("&#x([0-9a-fA-F]+);", in: result, radix: 16)
        result = replaceNumericEntities("&#([0-9]+);", in: result, radix: 10)
        return result
    }

    static func replaceNumericEntities(_ pattern: String, in text: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for m in matches.reversed() {
            let entityRange = m.range
            let valueRange = m.range(at: 1)
            guard let valueSwiftRange = Range(valueRange, in: text) else { continue }
            let raw = String(text[valueSwiftRange])
            if let code = UInt32(raw, radix: radix), let scalar = UnicodeScalar(code) {
                nsText.replaceCharacters(in: entityRange, with: String(scalar))
            }
        }
        return nsText as String
    }
}
