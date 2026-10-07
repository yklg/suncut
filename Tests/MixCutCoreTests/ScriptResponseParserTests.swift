import Testing
import Foundation
@testable import MixCutCore

// MARK: - Writing

@Test func parser_wrappedScenesParses() throws {
    let scenes = try ScriptResponseParser.parseScenes("""
    好的，这是脚本：
    ```json
    {"scenes":[
      {"order":1,"text":"你还在为螨虫烦恼吗","citations":[1,2]},
      {"order":2,"text":"高频拍打深层除螨","citations":[3]}
    ]}
    ```
    """)
    #expect(scenes.count == 2)
    #expect(scenes[0].text == "你还在为螨虫烦恼吗")
    #expect(scenes[0].citationIndexes == [1, 2])
    #expect(scenes[1].order == 2)
}

@Test func parser_bareArrayAccepted() throws {
    let scenes = try ScriptResponseParser.parseScenes("""
    [{"order":1,"text":"单段文案","citations":[]}]
    """)
    #expect(scenes.count == 1)
    #expect(scenes[0].text == "单段文案")
}

@Test func parser_singleObjectAccepted() throws {
    let scenes = try ScriptResponseParser.parseScenes(#"{"text":"只有一段"}"#)
    #expect(scenes.count == 1)
    #expect(scenes[0].order == 1)
}

@Test func parser_trailingCommaTolerated() throws {
    let scenes = try ScriptResponseParser.parseScenes("""
    {"scenes":[{"order":1,"text":"尾随逗号",},]}
    """)
    #expect(scenes.count == 1)
    #expect(scenes[0].text == "尾随逗号")
}

@Test func parser_citationNumberAsStringCoerced() throws {
    let scenes = try ScriptResponseParser.parseScenes("""
    {"scenes":[{"order":1,"text":"编号是字符串","citations":["1","2"]}]}
    """)
    #expect(scenes[0].citationIndexes == [1, 2])
}

@Test func parser_scenesSortedByOrder() throws {
    let scenes = try ScriptResponseParser.parseScenes("""
    {"scenes":[
      {"order":3,"text":"第三"},
      {"order":1,"text":"第一"},
      {"order":2,"text":"第二"}
    ]}
    """)
    #expect(scenes.map(\.text) == ["第一", "第二", "第三"])
}

@Test func parser_emptyScenesThrows() {
    #expect(throws: ScriptResponseParser.ParseError.noScenes) {
        try ScriptResponseParser.parseScenes(#"{"scenes":[]}"#)
    }
}

@Test func parser_noJSONThrows() {
    #expect(throws: ScriptResponseParser.ParseError.noJSONFound) {
        try ScriptResponseParser.parseScenes("抱歉我无法生成这个内容")
    }
}

// MARK: - Structure

@Test func parser_structureSlotsParsed() throws {
    let slots = try ScriptResponseParser.parseStructure("""
    {"slots":[{"tag":"噱头引入","duration":2.5},{"tag":"行动号召","duration":4.0}]}
    """)
    #expect(slots.count == 2)
    #expect(slots[0].tag == "噱头引入")
    #expect(slots[0].duration == 2.5)
}

@Test func parser_structureSkipsEmptyTag() throws {
    let slots = try ScriptResponseParser.parseStructure("""
    [{"tag":"","duration":1},{"tag":"过渡","duration":2}]
    """)
    #expect(slots.count == 1)
    #expect(slots[0].tag == "过渡")
}
