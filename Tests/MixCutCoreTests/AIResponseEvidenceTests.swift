import Foundation
import Testing
@testable import MixCutCore

/// `AIResponseEvidence` / `AIResponseEvidenceReader` 的契约测试（计划 §10.3 组 1，TC-21…TC-26）
///
/// 钉住的 API 契约：
/// - `read(body:shape:) -> AIResponseEvidence`：**只做字段提取，不做业务解析**
/// - `isBodyEmpty` ⇔ `bodyIsJSONObject && contentFieldPresent && contentBlank`
/// - `usage == nil` 表示"整个 usage 对象缺席"，与"有 usage 但某项为 0"**必须可区分**
///
/// 守护的规则：P5 截断不得算成功 / P3 空与空白的等价类划分 / P6 分类不得互吞 /
/// P7 失败形状各有出口 / P12 缺席≠零 / 外部经验 E1（结论先于 JSON 解析）
///
/// 非空洞性对应：TC-23 是正向对照（干净响应必须判"无缺口"），若把判定写成恒真/恒假，
/// TC-21 与 TC-23 会同时挂掉一对；TC-26 专门验证"无法解析"不会被吞进"空正文"档。
@Suite("AIResponseEvidence 判别证据")
struct AIResponseEvidenceTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - TC-21

    @Test("TC-21 finish_reason=length + 空正文：判为空，且该结论不依赖正文能被解析（E1）")
    func emptyBodyWithLengthStop() {
        let raw = #"{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"length"}],"usage":{"prompt_tokens":4213,"completion_tokens":8192,"total_tokens":12405}}"#
        let e = AIResponseEvidenceReader.read(body: body(raw), shape: .openAICompatible)

        #expect(e.bodyIsJSONObject)
        #expect(e.contentFieldPresent)
        #expect(e.contentLength == 0)
        #expect(e.contentBlank)
        #expect(e.finishReason == "length")
        #expect(e.truncatedByLength)
        #expect(e.isBodyEmpty)
        // 正文本身根本不是合法 JSON，结论仍然拿到了 —— 这就是"判定先于解析"的可验证形式
        #expect((try? JSONSerialization.jsonObject(with: Data("".utf8))) == nil)
    }

    // MARK: - TC-22

    @Test("TC-22 三类等价行：空串 / 纯空白 都是'没有正文'，仅围栏不是（划分给解析层的边界）")
    func whitespaceOnlyBody() {
        let blank = #"{"choices":[{"message":{"content":"   \n\t "},"finish_reason":"length"}]}"#
        let blankEvidence = AIResponseEvidenceReader.read(body: body(blank), shape: .openAICompatible)
        #expect(blankEvidence.contentLength > 0)      // 有字符
        #expect(blankEvidence.contentBlank)           // 但等同没有正文
        #expect(blankEvidence.isBodyEmpty)
        #expect(blankEvidence.truncatedByLength)

        let empty = #"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#
        let emptyEvidence = AIResponseEvidenceReader.read(body: body(empty), shape: .openAICompatible)
        #expect(emptyEvidence.contentLength == 0)
        #expect(emptyEvidence.contentBlank)
        #expect(emptyEvidence.isBodyEmpty)
        #expect(!emptyEvidence.truncatedByLength)     // 空白/空 ≠ 一定是截断，两条轴独立

        // 只有 markdown 围栏：这里**不**判成空正文 —— 剥围栏是 extractJSON 的活，
        // 证据层的职责边界只到"有没有非空白字符"。越界就会两处各写一遍。
        let fence = #"{"choices":[{"message":{"content":"```json\n\n```"},"finish_reason":"length"}]}"#
        let fenceEvidence = AIResponseEvidenceReader.read(body: body(fence), shape: .openAICompatible)
        #expect(!fenceEvidence.contentBlank)
        #expect(!fenceEvidence.isBodyEmpty)
        #expect(fenceEvidence.truncatedByLength)
    }

    // MARK: - TC-23

    @Test("TC-23 干净响应必须判无缺口（正向对照，防恒真判定）")
    func cleanResponse() {
        let raw = #"{"choices":[{"message":{"content":"{\"segments\":[{\"id\":\"seg_001\"}]}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}"#
        let e = AIResponseEvidenceReader.read(body: body(raw), shape: .openAICompatible)

        #expect(!e.isBodyEmpty)
        #expect(!e.contentBlank)
        #expect(!e.truncatedByLength)
        #expect(e.finishReason == "stop")
        #expect(e.contentLength > 0)
        #expect(e.usage?.completionTokens == 20)
    }

    // MARK: - TC-24

    @Test("TC-24 usage 缺席记 nil，不得记 0；部分字段缺席也各自记 nil（P12）")
    func usageAbsentIsNotZero() {
        let noUsage = #"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}]}"#
        let e1 = AIResponseEvidenceReader.read(body: body(noUsage), shape: .openAICompatible)
        #expect(e1.usage == nil)

        let partialUsage = #"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":123}}"#
        let e2 = AIResponseEvidenceReader.read(body: body(partialUsage), shape: .openAICompatible)
        #expect(e2.usage != nil)
        #expect(e2.usage?.promptTokens == 123)
        #expect(e2.usage?.completionTokens == nil)   // 缺席
        #expect(e2.usage?.reasoningTokens == nil)
        // "缺席"与"值为 0"必须能区分开，否则日志会把"网关不返回"写成 0
        #expect(e2.usage?.completionTokens != 0)

        let zeroUsage = #"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}"#
        let e3 = AIResponseEvidenceReader.read(body: body(zeroUsage), shape: .openAICompatible)
        #expect(e3.usage?.completionTokens == 0)
        #expect(e3.usage != e2.usage)
    }

    // MARK: - TC-25

    @Test("TC-25 Claude 形状：stop_reason=max_tokens + thinking 块在前，正文取 text 块（P7 形状分叉）")
    func claudeShapeWithThinking() {
        let raw = """
        {"content":[{"type":"thinking","thinking":"先想想这段广告的结构……"},\
        {"type":"text","text":"{\\"segments\\":[]}"}],\
        "stop_reason":"max_tokens",\
        "usage":{"input_tokens":300,"output_tokens":4000}}
        """
        let e = AIResponseEvidenceReader.read(body: body(raw), shape: .claudeNative)

        #expect(e.bodyIsJSONObject)
        #expect(e.contentFieldPresent)
        #expect(e.finishReason == "max_tokens")
        #expect(e.truncatedByLength)
        #expect(!e.contentBlank)
        #expect(e.contentLength == #"{"segments":[]}"#.count)   // 取到的是 text 块，不是 thinking 块
        #expect(e.usage?.promptTokens == 300)
        #expect(e.usage?.completionTokens == 4000)
        #expect(e.reasoningContentLength == "先想想这段广告的结构……".count)
    }

    // MARK: - TC-26

    @Test("TC-26 非 JSON 响应体 与 缺 choices 的响应体：都不得被归进'空正文'档（P6 分类不互吞）")
    func unparseableShapesDoNotMergeIntoEmptyBody() {
        let garbage = AIResponseEvidenceReader.read(body: body("upstream returned plain text"),
                                                    shape: .openAICompatible)
        #expect(!garbage.bodyIsJSONObject)
        #expect(!garbage.isBodyEmpty)          // 我们根本不知道正文是什么，不能宣称"正文为空"
        #expect(garbage.finishReason == nil)

        let noChoices = AIResponseEvidenceReader.read(
            body: body(#"{"id":"chatcmpl-1","object":"chat.completion"}"#), shape: .openAICompatible)
        #expect(noChoices.bodyIsJSONObject)
        #expect(!noChoices.contentFieldPresent)
        #expect(!noChoices.isBodyEmpty)        // 字段缺失 ≠ 字段为空，两档必须分开
    }

    // MARK: - 摘要措辞不含推断

    @Test("summaryLine 只说观测到的事实：缺席字段写'不返回'，不写 0")
    func summaryLineReportsOnlyObservations() {
        let e = AIResponseEvidenceReader.read(
            body: body(#"{"choices":[{"message":{"content":""},"finish_reason":"length"}]}"#),
            shape: .openAICompatible)
        let line = e.summaryLine()
        #expect(line.contains("usage=该网关不返回"))
        #expect(line.contains("reasoning_content=无此字段"))
        #expect(line.contains("命中长度上限"))
        #expect(!line.contains("max_tokens 截断"))   // 旧文案里的因果推断，不再由这里产出
    }
}
