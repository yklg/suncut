import Testing
@testable import MixCutCore

private func scan(_ src: String, _ tokens: [String] = ["MixCut"]) -> [BrandResidueScanner.Hit] {
    BrandResidueScanner.hits(in: src, tokens: tokens)
}

@Test("注释里的旧字样不算残留")
func commentsAreNotResidue() {
    #expect(scan("// MixCut 是旧名\n").isEmpty)
    #expect(scan("/// 见 MixCut.store\n").isEmpty)
    #expect(scan("/* MixCut 块注释 */\n").isEmpty)
    #expect(scan("/*\n  MixCut 在多行块注释里\n*/\n").isEmpty)
}

@Test("标识符里的旧字样不算残留")
func identifiersAreNotResidue() {
    #expect(scan("import MixCutCore\n").isEmpty)
    #expect(scan("struct MixCutApp { }\n").isEmpty)
    #expect(scan("let s = \"xMixCutCore\"\n").isEmpty)     // 字符串内，但被字母包夹 → 不是独立字样
}

@Test("字符串字面量里的独立旧字样算残留，且行号要对")
func stringLiteralIsResidue() {
    let h = scan("let a = 1\nlet b = 2\nText(\"MixCut\")\n")
    #expect(h.count == 1)
    #expect(h.first?.line == 3)
}

@Test("三引号块内部算残留")
func multilineStringIsResidue() {
    let src = "let s = \"\"\"\nMixCut（用户常用简写：MC）\n第二行没有\n\"\"\"\n"
    let h = scan(src, ["MixCut"])
    #expect(h.count == 1)
    #expect(h.first?.line == 2)
}

@Test("转义引号不会提前结束字符串")
func escapedQuoteKeepsStringOpen() {
    #expect(scan("let s = \"他说\\\"MixCut\\\"\"\n").count == 1)
}

@Test("插值内部是代码不算字面量；插值之后的字面量部分仍算")
func interpolationIsCode() {
    #expect(scan("Text(\"你好 \\(Brand.MixCutThing) 世界\")\n").isEmpty)
    #expect(scan("Text(\"你好\\(x)MixCut\")\n").count == 1)
}

@Test("路径字面量里的旧字样算残留（斜杠与点都不是标识符字符）")
func pathLiteralIsResidue() {
    #expect(scan("let p = \"AppSupport/MixCut/Videos\"\n").count == 1)
}

@Test("大小写敏感：小写短名不会被当成显示名命中")
func matchingIsCaseSensitive() {
    #expect(scan("let s = \"mixcut\"\n", ["MixCut"]).isEmpty)
    #expect(scan("let s = \"mixcut\"\n", ["mixcut"]).count == 1)
}

@Test("「MCP」里的 MC 不算命中 —— 这正是裸 contains(\"MC\") 会白给的地方")
func abbrevInsideLongerWordDoesNotCount() {
    #expect(scan("let s = \"见 MCP 文档\"\n", ["MC"]).isEmpty)
    #expect(scan("let s = \"简写：MC）\"\n", ["MC"]).count == 1)
}

@Test("多 token 与同一行多次出现，各自计一次")
func multipleTokensAndOccurrences() {
    #expect(scan("Text(\"MixCut 与 MC 与 MixCut\")\n", ["MixCut", "MC"]).count == 3)
}

@Test("空源码或空 token 表 ⇒ 无命中")
func emptyInputs() {
    #expect(scan("").isEmpty)
    #expect(scan("Text(\"MixCut\")\n", []).isEmpty)
}
