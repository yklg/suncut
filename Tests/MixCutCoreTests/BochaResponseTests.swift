import Testing
import Foundation
@testable import MixCutCore

@Test func bocha_parsesValidPayload() throws {
    let payload = """
    {
      "webPages": {
        "value": [
          {"name":"标题A","url":"https://a.com","snippet":"片段A","summary":"正文摘要A","siteName":"A站"},
          {"name":"标题B","url":"https://b.com","snippet":"片段B","summary":"","siteName":"B站","datePublished":"2026-09-01"}
        ]
      }
    }
    """.data(using: .utf8)!

    let results = try BochaResponseParsing.parse(payload)
    #expect(results.count == 2)
    #expect(results[0].title == "标题A")
    #expect(results[0].summary == "正文摘要A")
    #expect(results[0].datePublished == nil)
    #expect(results[1].summary == "")
    #expect(results[1].datePublished == "2026-09-01")
}

@Test func bocha_missingWebPagesThrows() {
    let payload = #"{"foo":1}"#.data(using: .utf8)!
    #expect(throws: BochaResponseParsing.ParseError.invalidResponse) {
        try BochaResponseParsing.parse(payload)
    }
}

@Test func bocha_emptyValueReturnsEmptyList() throws {
    let payload = #"{"webPages":{"value":[]}}"#.data(using: .utf8)!
    let results = try BochaResponseParsing.parse(payload)
    #expect(results.isEmpty)
}

@Test func bocha_malformedJSONThrows() {
    let payload = "not json".data(using: .utf8)!
    #expect(throws: BochaResponseParsing.ParseError.invalidResponse) {
        try BochaResponseParsing.parse(payload)
    }
}
