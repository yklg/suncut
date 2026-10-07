import Testing
import Foundation
@testable import MixCutCore

// MARK: - ScriptTextExporter

private func makeDraft(
    direction: ScriptDirection = .forward,
    product: String? = "鲸净除螨仪",
    scenes: [ScriptExportScene]
) -> ScriptExportDraft {
    ScriptExportDraft(title: "测试脚本", direction: direction,
                      productName: product, scenes: scenes)
}

@Test func exporter_txtContainsFullTextTagAndDuration() {
    let draft = makeDraft(scenes: [
        .init(order: 1, tag: "噱头引入", duration: 2.5,
              text: "家人们看过来！", citations: []),
        .init(order: 2, tag: "行动号召", duration: 3.0,
              text: "赶紧下单。", citations: []),
    ])
    let txt = ScriptTextExporter.render(draft, format: .plainText)
    #expect(txt.contains("《测试脚本》"))
    #expect(txt.contains("创作方向：产品资料撰写"))
    #expect(txt.contains("产品：鲸净除螨仪"))
    #expect(txt.contains("共 2 段 · 合计 5.5 秒"))
    #expect(txt.contains("1. [噱头引入]（2.5 秒）"))
    #expect(txt.contains("家人们看过来！"))
    #expect(txt.contains("2. [行动号召]（3.0 秒）"))
    #expect(txt.contains("赶紧下单。"))
}

@Test func exporter_txtReverseDirectionLabelAndCitations() {
    let draft = makeDraft(direction: .reverse, scenes: [
        .init(order: 1, tag: "痛点", duration: 4.0, text: "床上总是痒。",
              citations: [.init(documentTitle: "用户访谈.docx", sourceURL: nil)]),
    ])
    let txt = ScriptTextExporter.render(draft, format: .plainText)
    #expect(txt.contains("创作方向：现成文案结构化"))
    #expect(txt.contains("引用：用户访谈.docx"))
}

@Test func exporter_txtEmptyScenesHasPlaceholder() {
    let draft = makeDraft(scenes: [])
    let txt = ScriptTextExporter.render(draft, format: .plainText)
    #expect(txt.contains("（暂无段落）"))
}

@Test func exporter_txtIsDeterministic() {
    let draft = makeDraft(scenes: [
        .init(order: 1, tag: "过渡", duration: 1.0, text: "你好", citations: []),
    ])
    #expect(ScriptTextExporter.render(draft, format: .plainText)
            == ScriptTextExporter.render(draft, format: .plainText))
}

@Test func exporter_mdHasSectionHeadingsAndFootnoteSources() {
    let draft = makeDraft(scenes: [
        .init(order: 1, tag: "产品方案", duration: 6.0,
              text: "采用高频拍打技术。",
              citations: [.init(documentTitle: "产品手册", sourceURL: "https://example.com/p")]),
        .init(order: 2, tag: "行动号召", duration: 2.0,
              text: "快买。", citations: []),
    ])
    let md = ScriptTextExporter.render(draft, format: .markdown)
    #expect(md.hasPrefix("# 测试脚本"))
    #expect(md.contains("- 创作方向：产品资料撰写"))
    #expect(md.contains("- 段落数：2（合计 8.0 秒）"))
    #expect(md.contains("## 1. 产品方案（6.0 秒）"))
    #expect(md.contains("采用高频拍打技术。[^1]"))
    #expect(md.contains("## 2. 行动号召（2.0 秒）"))
    // 无引用段不带脚注标记
    let ctaLine = md.components(separatedBy: "\n").first { $0 == "快买。" }
    #expect(ctaLine != nil)
    #expect(md.contains("## 引用来源"))
    #expect(md.contains("[^1]: 产品手册（https://example.com/p）"))
}

@Test func exporter_mdDuplicateCitationSharesOneFootnote() {
    let citation = ScriptExportCitation(documentTitle: "同一份资料", sourceURL: nil)
    let draft = makeDraft(scenes: [
        .init(order: 1, tag: "痛点", duration: 2.0, text: "甲。", citations: [citation]),
        .init(order: 2, tag: "方案", duration: 2.0, text: "乙。", citations: [citation]),
    ])
    let md = ScriptTextExporter.render(draft, format: .markdown)
    #expect(md.contains("甲。[^1]"))
    #expect(md.contains("乙。[^1]"))
    #expect(!md.contains("[^2]"))
}

@Test func exporter_mdNoCitationsOmitsSourceSection() {
    let draft = makeDraft(scenes: [
        .init(order: 1, tag: "过渡", duration: 1.0, text: "嗯。", citations: []),
    ])
    let md = ScriptTextExporter.render(draft, format: .markdown)
    #expect(!md.contains("引用来源"))
    #expect(!md.contains("[^1]"))
}

@Test func exporter_formatFileExtensionsAndLabels() {
    #expect(ScriptTextExportFormat.plainText.fileExtension == "txt")
    #expect(ScriptTextExportFormat.markdown.fileExtension == "md")
    for format in ScriptTextExportFormat.allCases {
        #expect(!format.displayLabel.isEmpty)
    }
}
