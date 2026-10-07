import Testing
import Foundation
@testable import MixCutCore

@Test func stripper_removesScriptAndStyleContent() {
    let html = """
    <html><head><style>.x{color:red}</style>
    <script>alert(1)</script></head>
    <body><p>正文内容</p></body></html>
    """
    let text = HTMLTextStripper.plainText(from: html)
    #expect(text.contains("正文内容"))
    #expect(!text.contains("alert"))
    #expect(!text.contains("color:red"))
}

@Test func stripper_blockTagsBecomeLineBreaks() {
    let html = "<div>第一行</div><div>第二行</div><ul><li>项目</li></ul>"
    let text = HTMLTextStripper.plainText(from: html)
    #expect(text.contains("第一行\n第二行"))
    #expect(text.contains("项目"))
}

@Test func stripper_removesAllRemainingTags() {
    let text = HTMLTextStripper.plainText(from: "<a href='x'>链接</a><b>加粗</b>")
    #expect(text == "链接\n加粗" || text == "链接加粗")
    #expect(!text.contains("<"))
}

@Test func stripper_decodesNamedEntities() {
    #expect(HTMLTextStripper.plainText(from: "<p>a &amp; b&nbsp;c&copy;</p>")
        .contains("a &"))
    #expect(HTMLTextStripper.plainText(from: "&lt;tag&gt;").contains("<tag>"))
}

@Test func stripper_decodesDecimalAndHexEntities() {
    // &#20013; = 中；&#x4E2D; = 中
    #expect(HTMLTextStripper.plainText(from: "&#20013;") == "中")
    #expect(HTMLTextStripper.plainText(from: "&#x4E2D;") == "中")
}

@Test func stripper_collapsesBlankLinesAndWhitespace() {
    let text = HTMLTextStripper.plainText(from: "<p>行1</p><p></p><p>   </p><p>行2</p>")
    #expect(text == "行1\n行2")
}

@Test func stripper_emptyHTMLReturnsEmpty() {
    #expect(HTMLTextStripper.plainText(from: "").isEmpty)
    #expect(HTMLTextStripper.plainText(from: "<html></html>").isEmpty)
}
