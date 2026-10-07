import Testing
import Foundation
@testable import MixCutCore

// MARK: - PastedScriptLines（逆向：原文逐字保留，本机切行）

@Test func pastedLines_emptyInputYieldsNoLines() {
    #expect(PastedScriptLines.lines(in: "").isEmpty)
    #expect(PastedScriptLines.lines(in: "   \n \r\n  ").isEmpty)
}

@Test func pastedLines_respectsUserLineBreaksFirst() {
    let lines = PastedScriptLines.lines(in: "第一行\n第二行\n第三行")
    #expect(lines.map(\.text) == ["第一行", "第二行", "第三行"])
    #expect(lines.map(\.index) == [1, 2, 3])
}

@Test func pastedLines_splitsOnSentenceEndersAndKeepsPunctuation() {
    let lines = PastedScriptLines.lines(in: "你好吗？我很好。真的很棒呢！")
    #expect(lines.map(\.text) == ["你好吗？", "我很好。", "真的很棒呢！"])
}

@Test func pastedLines_shortUserLineIsNotMergedAcrossLineBreak() {
    // 用户硬换行为强边界：即使相邻两行都很短，也不许跨行合并抹掉分段意图。
    let lines = PastedScriptLines.lines(in: "好。\n产品主打高频拍打。")
    #expect(lines.map(\.text) == ["好。", "产品主打高频拍打。"])
}

@Test func pastedLines_swallowsClosingQuoteAfterEnder() {
    let lines = PastedScriptLines.lines(in: "他说“没错”。然后走了。")
    #expect(lines.first?.text == "他说“没错”。")
    #expect(lines.last?.text == "然后走了。")
}

@Test func pastedLines_shortFragmentsMergeIntoPrevious() {
    // “走吧”后仅 2 字碎片并入前句
    let lines = PastedScriptLines.lines(in: "我们走吧。好的。")
    // 好的 = 2 字，并入前句
    #expect(lines.map(\.text) == ["我们走吧。好的。"])
}

@Test func pastedLines_leadingShortFragmentMergesIntoNext() {
    // 首碎片 ≤3 字暂存，等下一句到来时并入
    let lines = PastedScriptLines.lines(in: "好。我们现在开始详细介绍这个产品。")
    #expect(lines.count == 1)
    #expect(lines.first?.text.hasPrefix("好。") == true)
}

@Test func pastedLines_crlfNormalizedAndTrimsWhitespace() {
    let lines = PastedScriptLines.lines(in: "  第一段内容。  \r\n  第二段内容。")
    #expect(lines.map(\.text) == ["第一段内容。", "第二段内容。"])
}

@Test func pastedLines_blankLinesIgnored() {
    let lines = PastedScriptLines.lines(in: "第一句。\n\n\n第二句。\n")
    #expect(lines.map(\.text) == ["第一句。", "第二句。"])
}

@Test func pastedLines_textWithoutEndersBecomesSingleLine() {
    let lines = PastedScriptLines.lines(in: "一整段没有句末标点的口播文案应该完整保留")
    #expect(lines.count == 1)
    #expect(lines.first?.text == "一整段没有句末标点的口播文案应该完整保留")
}

@Test func pastedLines_originalCharactersNeverDropped() {
    // 逐字保留契约：切行只能重排边界，不能丢字（忽略首尾空白修剪）。
    let raw = " 家人们谁懂啊！这个除螨仪真的绝了。99元到手，还送滤芯，冲吧！ "
    let lines = PastedScriptLines.lines(in: raw)
    let rejoined = lines.map(\.text).joined()
    let expected = raw
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(rejoined == expected)
}
