import Testing
import Foundation
@testable import MixCutCore

// MARK: - ChineseTextTokenizer

@Test func tokenizer_cjkProducesUnigramAndBigram() {
    let tokens = ChineseTextTokenizer.tokenStrings(in: "螨虫多")
    // unigram: 螨 虫 多；bigram: 螨虫 虫多
    #expect(tokens == ["螨", "虫", "多", "螨虫", "虫多"])
}

@Test func tokenizer_singleCJKCharacterHasNoBigram() {
    let tokens = ChineseTextTokenizer.tokenStrings(in: "螨")
    #expect(tokens == ["螨"])
}

@Test func tokenizer_stopWordsRemovedFromUnigramButKeptInBigram() {
    let tokens = ChineseTextTokenizer.tokenStrings(in: "好的螨")
    // unigram：好 螨（"的"被过滤）；bigram：好的 的螨（不过滤）
    #expect(tokens == ["好", "螨", "好的", "的螨"])
}

@Test func tokenizer_latinAndDigitsKeptAsWholeLowercased() {
    let tokens = ChineseTextTokenizer.tokenStrings(in: "K-8000 Nice")
    #expect(tokens.contains("k-8000"))
    #expect(tokens.contains("nice"))
}

@Test func tokenizer_mixedCJKAndLatinSplitsAtBoundary() {
    let tokens = ChineseTextTokenizer.tokenStrings(in: "除螨仪K8使用")
    let strings = Set(tokens)
    #expect(strings.contains("k8"))
    #expect(strings.contains("螨"))
    #expect(strings.contains("使用"))
}

@Test func tokenizer_emptyStringYieldsNoTokens() {
    #expect(ChineseTextTokenizer.tokenStrings(in: "").isEmpty)
    #expect(ChineseTextTokenizer.tokenStrings(in: "   \n ").isEmpty)
}

@Test func tokenizer_punctuationOnlyYieldsNoTokens() {
    #expect(ChineseTextTokenizer.tokenStrings(in: "，。！").isEmpty)
}

@Test func tokenizer_tokenFlagsCJKVsLatin() {
    let tokens = ChineseTextTokenizer.tokens(in: "螨a")
    #expect(tokens[0].isCJK)
    #expect(!tokens[1].isCJK)
}

// MARK: - TextChunker

@Test func chunker_emptyOrBlankReturnsNoChunks() {
    #expect(TextChunker.chunks(in: "").isEmpty)
    #expect(TextChunker.chunks(in: "   \n ").isEmpty)
}

@Test func chunker_textShorterThanSizeReturnsSingleChunk() {
    let chunks = TextChunker.chunks(in: "短文本", chunkSize: 500)
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "短文本")
    #expect(chunks[0].index == 0)
}

@Test func chunker_longTextSplitsAndIndexesSequentially() {
    let text = String(repeating: "字", count: 1200)
    let chunks = TextChunker.chunks(in: text, chunkSize: 500, overlap: 80)
    #expect(chunks.count >= 2)
    for chunk in chunks {
        #expect(chunk.index >= 0)
        #expect(!chunk.text.isEmpty)
    }
}

@Test func chunker_prefersNaturalBoundary() {
    // 120 个 "甲" 后在第 100 字处放句号，块大小 100：应在句号处断开
    let text = String(repeating: "甲", count: 100) + "。" + String(repeating: "乙", count: 100)
    let chunks = TextChunker.chunks(in: text, chunkSize: 100, overlap: 0)
    #expect(chunks[0].text.hasSuffix("。"))
}

@Test func chunker_noBoundaryForcesHardSplit() {
    let text = String(repeating: "丙", count: 250)
    let chunks = TextChunker.chunks(in: text, chunkSize: 100, overlap: 0)
    // 无自然边界 ⇒ 按 100 强切成 100/100/50
    #expect(chunks.map(\.text.count) == [100, 100, 50])
}

@Test func chunker_overlapDoesNotCauseInfiniteLoop() {
    let text = String(repeating: "丁", count: 300)
    let chunks = TextChunker.chunks(in: text, chunkSize: 100, overlap: 99)
    // 重叠很大但每步必须前进；最终仍应覆盖全文并终止
    #expect(chunks.last!.text.hasSuffix("丁"))
    #expect(chunks.count > 3)
}

@Test func chunker_overlapAtLeastAdvancesOneCharacter() {
    let text = String(repeating: "戊", count: 150)
    let chunks = TextChunker.chunks(in: text, chunkSize: 100, overlap: 200)
    // overlap 被夹到 chunkSize-1；不死循环
    #expect(chunks.count >= 2)
}
