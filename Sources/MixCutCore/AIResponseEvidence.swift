import Foundation

/// 响应体形状：OpenAI 兼容 与 Claude 原生两套字段名不同，判定必须分别走。
public enum AIResponseShape: String, Equatable, Sendable {
    case openAICompatible
    case claudeNative
}

/// `usage` 的四项计数。任一项都可能缺席 —— **缺席必须读作"该网关不返回"，不能读作 0**。
public struct AITokenUsage: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    /// 推理（reasoning / thinking）占用的输出 tokens。多数网关不返回。
    public var reasoningTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil,
                totalTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
    }

    /// 四项全空。与「有 usage 但某项为 0」必须能区分。
    public var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil && reasoningTokens == nil
    }
}

/// 一次 AI 响应的**判别证据**：在做任何 JSON 解析**之前**先取出结论字段。
///
/// 存在的理由（缺陷本体）：原来代码只在解析失败之后反推"大概是 max_tokens 截断了"，
/// 既把证据销毁（落盘只存正文），又把残缺当成功返回。
public struct AIResponseEvidence: Equatable, Sendable {
    public var shape: AIResponseShape
    /// 响应体能作为 JSON 对象解开吗？false = 连形状都不对，属"无法解析"档，不得吞进空正文档。
    public var bodyIsJSONObject: Bool
    /// 正文原文；nil = 字段缺席或类型不对（与"字段存在但为空串"是两件事）
    public var content: String?
    /// 上游给的停止原因原值（OpenAI `finish_reason` / Claude `stop_reason`）
    public var finishReason: String?
    /// 命中"因长度上限而停"
    public var truncatedByLength: Bool
    /// nil = 整个 usage 对象缺席（≠ 零计数）
    public var usage: AITokenUsage?
    /// 推理正文是否单独成字段返回，及其长度
    public var reasoningContentLength: Int?
    /// 原始响应体，供落盘留证
    public var rawBody: String

    public init(shape: AIResponseShape, bodyIsJSONObject: Bool, content: String?,
                finishReason: String?, truncatedByLength: Bool, usage: AITokenUsage?,
                reasoningContentLength: Int?, rawBody: String) {
        self.shape = shape
        self.bodyIsJSONObject = bodyIsJSONObject
        self.content = content
        self.finishReason = finishReason
        self.truncatedByLength = truncatedByLength
        self.usage = usage
        self.reasoningContentLength = reasoningContentLength
        self.rawBody = rawBody
    }

    /// 正文字段存在且是字符串
    public var contentFieldPresent: Bool { content != nil }
    /// 正文长度（未 trim）
    public var contentLength: Int { content?.count ?? 0 }
    /// 正文去掉空白后为空（覆盖"空串"与"只有空白/换行"两类等价类；不含剥围栏，那是解析层的活）
    public var contentBlank: Bool {
        (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// 正文没吐出来（空串或只有空白）。与"吐了但残缺"是两件事。
    public var isBodyEmpty: Bool { bodyIsJSONObject && contentFieldPresent && contentBlank }

    /// 一行可进日志的结论，措辞只说观测到的事实，不含推断。
    public func summaryLine() -> String {
        var parts: [String] = ["shape=\(shape.rawValue)"]
        if !bodyIsJSONObject { parts.append("body=非 JSON 对象") }
        parts.append("正文=\(contentLength)字符")
        parts.append(contentBlank ? "正文=空白" : "正文=有内容")
        parts.append("finish_reason=\(finishReason ?? "缺席")")
        if truncatedByLength { parts.append("命中长度上限") }
        if let u = usage, !u.isEmpty {
            parts.append("usage[prompt=\(string(u.promptTokens)) completion=\(string(u.completionTokens)) "
                + "total=\(string(u.totalTokens)) reasoning=\(string(u.reasoningTokens))]")
        } else {
            parts.append("usage=该网关不返回")
        }
        parts.append("reasoning_content=\(reasoningContentLength.map { "\($0)字符" } ?? "无此字段")")
        return parts.joined(separator: " ")
    }

    private func string(_ v: Int?) -> String { v.map(String.init) ?? "缺席" }
}

public enum AIResponseEvidenceReader {

    /// 从原始响应体提取判别证据。**不做任何业务解析**。
    /// - Parameters:
    ///   - body: 上游返回的完整响应体
    ///   - shape: 该响应用的是哪套字段名
    public static func read(body: Data, shape: AIResponseShape) -> AIResponseEvidence {
        let raw = String(data: body, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]

        switch shape {
        case .openAICompatible:
            return readOpenAI(json: json, raw: raw)
        case .claudeNative:
            return readClaude(json: json, raw: raw)
        }
    }

    private static func readOpenAI(json: [String: Any]?, raw: String) -> AIResponseEvidence {
        var content: String?
        var finish: String?
        var reasoningLen: Int?

        if let choices = json?["choices"] as? [[String: Any]], let first = choices.first {
            finish = first["finish_reason"] as? String
            if let message = first["message"] as? [String: Any] {
                if let text = message["content"] as? String {
                    content = text
                }
                // 部分网关把推理放在 reasoning_content 里单独返回
                if let r = message["reasoning_content"] as? String {
                    reasoningLen = r.count
                }
            }
        }

        return AIResponseEvidence(
            shape: .openAICompatible,
            bodyIsJSONObject: json != nil,
            content: content,
            finishReason: finish,
            truncatedByLength: finish == "length",
            usage: usage(from: json?["usage"]),
            reasoningContentLength: reasoningLen,
            rawBody: raw)
    }

    private static func readClaude(json: [String: Any]?, raw: String) -> AIResponseEvidence {
        var content: String?
        var reasoningLen: Int?

        if let blocks = json?["content"] as? [[String: Any]] {
            // 开思考时首块是 thinking 块，正文要取 type == "text" 的那块
            if let textBlock = blocks.first(where: { ($0["type"] as? String) == "text" }) ?? blocks.first,
               let text = textBlock["text"] as? String {
                content = text
            }
            if let thinking = blocks.first(where: { ($0["type"] as? String) == "thinking" }),
               let text = thinking["thinking"] as? String {
                reasoningLen = text.count
            }
        }

        let finish = json?["stop_reason"] as? String
        return AIResponseEvidence(
            shape: .claudeNative,
            bodyIsJSONObject: json != nil,
            content: content,
            finishReason: finish,
            truncatedByLength: finish == "max_tokens",
            usage: usage(from: json?["usage"]),
            reasoningContentLength: reasoningLen,
            rawBody: raw)
    }

    /// usage 对象整体缺席 → nil；有对象但个别项缺失 → 该项 nil（都不得当 0）。
    private static func usage(from raw: Any?) -> AITokenUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        let usage = AITokenUsage(
            promptTokens: int(dict["prompt_tokens"] ?? dict["input_tokens"]),
            completionTokens: int(dict["completion_tokens"] ?? dict["output_tokens"]),
            totalTokens: int(dict["total_tokens"]),
            reasoningTokens: int(dict["reasoning_tokens"]))
        return usage
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
