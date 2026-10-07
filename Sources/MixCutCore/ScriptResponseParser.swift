import Foundation

/// 脚本类 LLM 响应的容错解析器（纯逻辑，可单测）。
///
/// LLM 写脚本时常带：前后缀寒暄、```json 围栏、尾随逗号、截断残缺、类型漂移。
/// 本解析器统一处理：
/// 1. 剥离 markdown 围栏与寒暄，截取首个 `{`/`[` 到匹配收尾；
/// 2. 删除对象/数组内尾随逗号；
/// 3. JSONSerialization 解析后手工映射（容忍单条坏数据跳过、数字/字符串漂移）。
public enum ScriptResponseParser {

    public enum ParseError: Error, Equatable {
        case noJSONFound
        case serializationFailed
        case noScenes
    }

    /// 写作产物的单场景投影。
    public struct WrittenScene: Equatable, Sendable {
        public let order: Int
        public let text: String
        /// 1-based 资料编号（映射回检索产物）；非法/缺失编号过滤掉。
        public let citationIndexes: [Int]
    }

    /// 结构产物的单槽投影（AI 自动结构）。
    public struct StructureSlot: Equatable, Sendable {
        public let tag: String
        public let duration: Double
    }

    // MARK: - Writing Response

    /// 解析写作响应，接受：
    /// - `{"scenes":[{"order":1,"text":"…","citations":[1,2]}]}`；
    /// - 裸数组 `[{…}]`；单对象 `{…}`（按 1 条处理）。
    /// 空 scenes ⇒ `.noScenes`。
    public static func parseScenes(_ raw: String) throws -> [WrittenScene] {
        let value = try jsonValue(from: raw)

        let items: [[String: Any]]
        if let dict = value as? [String: Any] {
            if let list = dict["scenes"] as? [[String: Any]] {
                items = list
            } else {
                items = [dict]   // 单对象
            }
        } else if let list = value as? [[String: Any]] {
            items = list
        } else {
            items = []
        }

        var scenes: [WrittenScene] = []
        for (index, item) in items.enumerated() {
            guard let text = item["text"] as? String, !text.isEmpty else { continue }
            let order = intValue(item["order"]) ?? (index + 1)
            let citations = (item["citations"] as? [Any])?
                .compactMap(intValue)
                .filter { $0 > 0 } ?? []
            scenes.append(WrittenScene(order: order, text: text, citationIndexes: citations))
        }
        // 按 order 升序，稳定（同 order 保持原顺序——枚举顺序天然稳定）。
        scenes.sort { $0.order < $1.order }
        guard !scenes.isEmpty else { throw ParseError.noScenes }
        return scenes
    }

    // MARK: - Structure Response

    /// 解析 AI 自动结构响应：`{"slots":[{"tag":"痛点","duration":3.0}]}` / 裸数组。
    /// tag 必须是非空字符串；duration 非法按 0 保留（UI 可再校）。
    public static func parseStructure(_ raw: String) throws -> [StructureSlot] {
        let value = try jsonValue(from: raw)

        let items: [[String: Any]]
        if let dict = value as? [String: Any], let list = dict["slots"] as? [[String: Any]] {
            items = list
        } else if let list = value as? [[String: Any]] {
            items = list
        } else if let dict = value as? [String: Any] {
            items = [dict]
        } else {
            items = []
        }

        let slots = items.compactMap { item -> StructureSlot? in
            guard let tag = item["tag"] as? String, !tag.isEmpty else { return nil }
            return StructureSlot(tag: tag, duration: doubleValue(item["duration"]) ?? 0)
        }
        guard !slots.isEmpty else { throw ParseError.noScenes }
        return slots
    }

    // MARK: - Reverse Tagging

    /// 逆向打标签产物的单行投影。
    public struct TaggedLine: Equatable, Sendable {
        public let index: Int
        public let tag: String
    }

    /// 解析逆向打标签响应：`{"lines":[{"index":1,"tag":"痛点"}]}` / 裸数组。
    /// 按 index 升序返回；index 缺失按数组位置（1-based）补齐。
    public static func parseTagging(_ raw: String) throws -> [TaggedLine] {
        let value = try jsonValue(from: raw)

        let items: [[String: Any]]
        if let dict = value as? [String: Any], let list = dict["lines"] as? [[String: Any]] {
            items = list
        } else if let list = value as? [[String: Any]] {
            items = list
        } else if let dict = value as? [String: Any] {
            items = [dict]
        } else {
            items = []
        }

        let tagged = items.enumerated().compactMap { position, item -> TaggedLine? in
            guard let tag = item["tag"] as? String, !tag.isEmpty else { return nil }
            let index = intValue(item["index"]) ?? (position + 1)
            return TaggedLine(index: index, tag: tag)
        }
        .sorted { $0.index < $1.index }
        guard !tagged.isEmpty else { throw ParseError.noScenes }
        return tagged
    }

    // MARK: - Scrubbing

    /// 从可能含寒暄/围栏的 LLM 文本中提取并解析 JSON 值。
    public static func jsonValue(from raw: String) throws -> Any {
        guard let jsonText = firstJSONSlice(raw) else { throw ParseError.noJSONFound }
        let cleaned = removeTrailingCommas(jsonText)
        guard let value = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) else {
            throw ParseError.serializationFailed
        }
        return value
    }

    /// 剥离 ```json 围栏，截取首个 `{`/`[` 到与之匹配的收尾（按括号配平，忽略字符串内符号）。
    /// 截断残缺（配不平）时退化为「首符号到文本末尾」，交给后续清洗与序列化尽力解析。
    static func firstJSONSlice(_ raw: String) -> String? {
        var text = raw
        // 去围栏：```json … ``` / ``` … ```
        if let fenceRegex = try? NSRegularExpression(
            pattern: "(?s)```(?:json|JSON)?\\s*(.*?)```"),
           let match = fenceRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            text = String(text[range])
        }

        let characters = Array(text)
        guard let start = characters.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open: Character = characters[start]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false

        for index in start..<characters.count {
            let ch = characters[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == open { depth += 1 }
            else if ch == close {
                depth -= 1
                if depth == 0 {
                    return String(characters[start...index])
                }
            }
        }
        // 残缺：返回首符号到末尾
        return String(characters[start...])
    }

    /// 删除 `,}` / `,]` 形态的尾随逗号（含空白）。
    static func removeTrailingCommas(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #",(\s*[}\]])"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    // MARK: - Coercion

    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let s = any as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
