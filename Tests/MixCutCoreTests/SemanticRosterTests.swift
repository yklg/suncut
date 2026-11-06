import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// SR · AI 面语义标签名册（`SemanticRoster`）的单一真源与漂移台账
//
// ## 为什么要有这一组
//
// 「AI 可以打哪些语义标签」这件事此前抄了七份：`AgentToolCatalog` 的 MCP 工具描述、
// `AIAnalysisService` 的 prompt 正文、`SegmentCommitter` 的归一化关键词表、
// `SlotRetrievalIntent` 的查询模板键，外加 `Resources/Prompts/` 里 5 份 .md。
// 本轮动手前逐颗数过，**其中两份当时正在漂**：
// `video_segmentation_prompt.md` 只列 10 类（缺「过渡」），
// `video_recombination_prompt.md` 只列 9 类且带「等」（缺「产品定位」「过渡」）。
// 而 MCP 描述那份此前硬编 11 类、枚举已经是 12 类。
//
// ⇒ 这一组做三件事：① 把可派生的两处（MCP 描述、prompt 正文）改成从
// `SemanticRoster.aiAssignable` 生成；② 把**不能**代码派生的 5 份 .md 登记成逐文件覆盖台账；
// ③ 台账暴露的那两份缺列，经用户 2026-11-06 拍板「补齐」后已补到 11/11 ——
// 补的是资源正文，逐份按各自的呈现形式落（segmentation 补一节带定义的 11 号条目、
// recombination 把带「等」的软枚举改成完整精确匹配清单），不是简单塞名字。
// 台账因此从"记录债务"变成"守住已补齐的状态"：谁再掉一颗就红。
//
// ## 与 ETB 的分工（别混）
//
// `EmptyLensTagBoundaryTests` 的 ETB-2 管的是**「不许给模型看到『空镜』」**（排除侧）；
// 这一组管的是**「给模型看到的 11 类是不是同一份」**（完整性侧）。
// 两者不能合并：`SemanticRoster` 所在的 `EmptyLensPolicy.swift` 注释里必须写出「空镜」
// 才能解释为什么排除它，而 ETB 的判据是"出现这两个字就算违规"。
// ============================================================================

private let srRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func srRead(_ relative: String) -> String? {
    try? String(contentsOf: srRoot.appendingPathComponent(relative), encoding: .utf8)
}

/// 逐文件登记**当前**的名册覆盖数（11 为满）。
///
/// 这五份是资源文件，**不能**代码派生，所以只能逐颗核对。2026-11-06 之前其中两份正在漂
/// （`video_segmentation_prompt.md` 只列 10 类、`video_recombination_prompt.md` 只列 9 类且带「等」）
/// ⇒ 模型在那两条链上拿不到「过渡」「产品定位」，而「过渡」还是全仓归一化的兜底值。现已补齐 11/11。
/// 登记在此的意义是：谁再掉一颗、或改了名册却没同步改这张表，都会红 ——
/// 无论补齐还是回退，都必须是一次有意识的动作（逐份重读语义 + 同轮改这张表 + 跑 `swift test`）。
private let srLedger: [(file: String, expect: Int, note: String)] = [
    ("MixCut/Resources/Prompts/segment_types_definition.md", 11, "定义本体，满覆盖"),
    ("MixCut/Resources/Prompts/video_segmentation_prompt.md", 11, "2026-11-06 补齐「过渡」（新增第 11 节定义）"),
    ("MixCut/Resources/Prompts/structure_generation_prompt.md", 11, "满覆盖"),
    ("MixCut/Resources/Prompts/reverse_structuring_prompt.md", 11, "满覆盖"),
    ("MixCut/Resources/Prompts/video_recombination_prompt.md", 11, "2026-11-06 把带「等」的软枚举改成完整 11 类精确匹配"),
]

@Suite("SR · AI 面语义标签名册")
struct SemanticRosterTests {

    @Test("SR-1 名册本身：11 颗、互不重复、不含机器标签，位置 3 颗")
    func rosterIsWellFormed() {
        #expect(SemanticRoster.aiAssignable.count == 11,
                "AI 面名册变成 \(SemanticRoster.aiAssignable.count) 颗 ⇒ 先问新增那颗归谁写、能不能给模型看")
        #expect(Set(SemanticRoster.aiAssignable).count == SemanticRoster.aiAssignable.count,
                "名册里有重复条目 ⇒ 顺序与去重语义开始分叉")
        #expect(!SemanticRoster.aiAssignable.contains("空镜"),
                "「空镜」进了 AI 可指派名册 ⇒ 直接违反 ETB-2 的排除前提（模型看不出静音）")
        #expect(SemanticRoster.positions == ["开头", "中间", "结尾"],
                "位置名册漂了 ⇒ MCP 描述与 App 层 PositionType 会各说一套")
        // 派生串必须与名册同源，不是另一份手抄。
        #expect(SemanticRoster.slashList == SemanticRoster.aiAssignable.joined(separator: "/"))
        #expect(SemanticRoster.promptList.contains(SemanticRoster.aiAssignable[0]))
        #expect(SemanticRoster.promptList.components(separatedBy: "、").count
                == SemanticRoster.aiAssignable.count)
    }

    @Test("SR-2 MCP 工具描述里的清单是派生的，运行时确实含全部 11 类")
    func mcpToolDescriptionCarriesTheRoster() throws {
        let tool = AgentToolCatalog.all.first { $0.name == "update_segment_tags" }
        let description = try #require(tool?.description)
        for name in SemanticRoster.aiAssignable {
            #expect(description.contains(name), "MCP 描述漏了「\(name)」⇒ 派生没生效")
        }
        for position in SemanticRoster.positions {
            #expect(description.contains(position), "MCP 描述漏了位置「\(position)」")
        }
        #expect(description.contains(SemanticRoster.aiAssignable.count.description),
                "MCP 描述里的颗数不是从名册算的 ⇒ 加一类就会说假话")
        #expect(!description.contains("空镜"), "MCP 描述把机器标签露给了 Agent ⇒ ETB-2 那一族")
    }

    @Test("SR-3 检索意图模板的键必须是名册子集（不许出现模型给不出的标签）")
    func retrievalIntentKeysAreASubset() {
        var offenders: [String] = []
        for key in SlotRetrievalIntent.templates.keys.sorted() {
            if !SemanticRoster.aiAssignable.contains(key) {
                offenders.append("模板键「\(key)」不在 AI 可指派名册里 ⇒ 这条模板永远不会被命中")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // 反过来不要求满覆盖：模板是**有意**的子集（7/11），未列标签走兜底。
        // 这颗只钉"子集"关系，别把它误改成"必须相等"，那会逼着有人给兜底支路也写模板。
        #expect(SlotRetrievalIntent.templates.count < SemanticRoster.aiAssignable.count,
                "模板已经铺满 ⇒ 上面那句『未列标签走兜底』的注释变成假话，去改注释")
    }

    @Test("SR-4 五份 prompt 的名册覆盖数逐文件对账：漂移必须是有意识的改表")
    func promptRosterCoverageIsRostered() {
        var problems: [String] = []
        for row in srLedger {
            guard let text = srRead(row.file) else {
                problems.append("读不到 \(row.file) ⇒ 台账指错了路径，这条判据没在测东西")
                continue
            }
            let hit = SemanticRoster.aiAssignable.filter { text.contains($0) }.count
            if hit != row.expect {
                problems.append("\(row.file)：登记 \(row.expect) 类，实得 \(hit) 类（\(row.note)）")
            }
        }
        #expect(problems.isEmpty, "AI 面名册覆盖台账与真实文件对不上：\n\(problems.joined(separator: "\n"))")
    }

    @Test("SR-5 反向对照：覆盖计数器不是恒绿的（少一颗必须被数出来）")
    func coverageCounterHasTeeth() {
        // 把 SR-4 用的那个计数表达式单独打一份"故意少一类"的合成文本：
        // 少了这一腿，SR-4 可能只是在拿一个恒等于 11 的表达式和自己比。
        let synthetic = SemanticRoster.aiAssignable.dropLast().joined(separator: "、")
        let hit = SemanticRoster.aiAssignable.filter { synthetic.contains($0) }.count
        #expect(hit == SemanticRoster.aiAssignable.count - 1,
                "缺了一颗却仍数满 ⇒ SR-4 的计数器恒绿，整条台账判据是假的")
        #expect(SemanticRoster.aiAssignable.filter { "随便一段没有标签的话".contains($0) }.count == 0,
                "空文本也数得出覆盖 ⇒ 计数器在误报")
    }

    @Test("SR-6 名册与枚举的关系钉死：差集恰好是那颗机器标签")
    func rosterVsEnumDifferenceIsExactlyTheMachineTag() {
        // 这颗是"再加一个 case 时逼一次思考"的闸：新增第 13 类会让这条红，
        // 那时必须回答"它能不能给模型看"，而不是默默加进去。
        // （App 层的 `SemanticType.aiAssignableTypes` 无损映射由
        //   `SemanticTagWriteRuleTests` 的 SR-7 负责 —— Core 腿看不见那个枚举。）
        #expect(SemanticRoster.aiAssignable.count == 11,
                "名册颗数变了 ⇒ 同轮去核对 App 层 aiAssignableTypes 与这条差集断言")
        #expect(!SemanticRoster.aiAssignable.contains("空镜")
                && !SemanticRoster.positions.contains("空镜"),
                "「空镜」以任何形式出现在 AI 面名册里")
    }
}
