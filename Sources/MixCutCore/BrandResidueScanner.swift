import Foundation

/// 在 Swift 源文本里找"品牌字样残留在**字符串字面量内部**"的位置。
///
/// 为什么不是 grep：改名之后，守卫若只盯**新**名字，就永远看不见**旧**名字留在界面文案里
/// （MixCut → Suncut 这一步真发生过：326 条测试全绿、守卫全 PASS，界面却还写着旧名）。
/// 而旧字样合法的栖身之处也不少 —— 注释、类型名（`MixCutCore`/`MixCutApp`）、历史路径常量 ——
/// 所以判据必须精确到"出现在字符串字面量里、且不是标识符的一部分"，否则会退化成噪音或恒真。
public enum BrandResidueScanner {

    public struct Hit: Equatable {
        public let line: Int
        public let snippet: String

        public init(line: Int, snippet: String) {
            self.line = line
            self.snippet = snippet
        }
    }

    /// 扫描整份源码，报告出现在字符串字面量（含三引号块）内部的字样命中。
    ///
    /// 只把 ASCII 字母/数字/下划线当标识符字符，所以 `"用MixCut做混剪"` 算命中，
    /// 而 `MixCutCore`、`"xMixCutCore"`、`"MCP"` 里的 `MC` 都不算。
    /// 注释（`//`、`///`、`/* */` 可嵌套）与 `\(...)` 插值里的代码都不算。
    /// 不处理 raw string（`#"…"#`）—— 本仓没有用到。
    public static func hits(in source: String, tokens: [String]) -> [Hit] {
        let needles = tokens.filter { !$0.isEmpty }.map { Array($0) }
        guard !needles.isEmpty, !source.isEmpty else { return [] }

        let chars = Array(source)
        func isIdentifierChar(_ c: Character) -> Bool {
            c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
        }
        func matches(_ needle: [Character], at start: Int) -> Bool {
            guard start + needle.count <= chars.count else { return false }
            for (offset, expected) in needle.enumerated() where chars[start + offset] != expected { return false }
            if start > 0, isIdentifierChar(chars[start - 1]) { return false }
            let after = start + needle.count
            if after < chars.count, isIdentifierChar(chars[after]) { return false }
            return true
        }
        func tokenEnd(at start: Int) -> Int? {
            for needle in needles where matches(needle, at: start) { return start + needle.count }
            return nil
        }

        enum Context: Equatable { case code(parenDepth: Int), lineString, blockString }

        var stack: [Context] = [.code(parenDepth: 0)]
        var result: [Hit] = []
        var index = 0
        var line = 1
        var lineStart = 0
        var blockCommentDepth = 0
        var inLineComment = false

        func pair(_ i: Int, _ s: String) -> Bool {
            guard i + 1 < chars.count else { return false }
            let a = chars[i], b = chars[i + 1]
            return (a == s.first! && b == s.last!)
        }
        func triple(_ i: Int) -> Bool {
            i + 2 < chars.count && chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\""
        }
        func top() -> Context { stack[stack.count - 1] }

        while index < chars.count {
            let c = chars[index]

            if c == "\n" {
                line += 1
                index += 1
                lineStart = index
                inLineComment = false
                if top() == .lineString { stack.removeLast() }   // 单行串不可能跨行
                continue
            }

            if blockCommentDepth > 0 {
                if pair(index, "*/") { blockCommentDepth -= 1; index += 2 }
                else if pair(index, "/*") { blockCommentDepth += 1; index += 2 }
                else { index += 1 }
                continue
            }
            if inLineComment { index += 1; continue }

            switch top() {
            case .code(let depth):
                if pair(index, "//") { inLineComment = true; index += 2; continue }
                if pair(index, "/*") { blockCommentDepth = 1; index += 2; continue }
                if triple(index) { stack.append(.blockString); index += 3; continue }
                if c == "\"" { stack.append(.lineString); index += 1; continue }
                if c == "(" { stack[stack.count - 1] = .code(parenDepth: depth + 1) }
                if c == ")" {
                    if depth - 1 <= 0, stack.count > 1 { stack.removeLast() }
                    else { stack[stack.count - 1] = .code(parenDepth: depth - 1) }
                }
                index += 1

            case .lineString, .blockString:
                let multiline = top() == .blockString
                if c == "\\" {
                    if pair(index, "\\(") { stack.append(.code(parenDepth: 1)); index += 2 }
                    else { index += 2 }              // 转义字符整体跳过，\" 不会结束字符串
                    continue
                }
                if multiline, triple(index) { stack.removeLast(); index += 3; continue }
                if !multiline, c == "\"" { stack.removeLast(); index += 1; continue }
                if let end = tokenEnd(at: index) {
                    let text = String(chars[lineStart..<index])
                    result.append(Hit(line: line, snippet: text.trimmingCharacters(in: .whitespaces)))
                    index = end
                    continue
                }
                index += 1
            }
        }
        return result
    }
}
