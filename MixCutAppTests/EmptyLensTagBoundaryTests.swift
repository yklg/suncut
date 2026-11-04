import Foundation
import Testing

@testable import SunCut

// ============================================================================
// ETB · 「空镜」标签的边界（C 块开闸那一轮的配套守卫）
//
// ## 为什么必须有这道守卫
//
// 「空镜」是**机器专属**标签：只由 `EmptyLensPolicy` 的两条定罪腿写入。
// 它绝不能进任何 AI prompt 的可选标签列表 —— 模型只拿到文本，而空镜的定义是
// "这段音频里没有人说话"，看幻觉文本是看不出静音的。让它可选，等于给模型
// 一条凭文本编造静音结论的口子，而且会把"拦打标"这件事变成"求模型别打标"。
//
// 危险在于**改回去不会有任何东西变红**：`.md` 是资源文件、不参与 Swift 编译，
// 而 `SemanticType` 有 12 个 case、`AIAnalysisService` 的白名单是按 `allCases` 建的
// ⇒ 有人往 prompt 里加一行「空镜」，白名单会当场接受它，判据面一个都不红。
// 本仓对这类"资源文件里的纪律"只用源码级断言钉（先例：`PromptTemplateGuardTests`）。
//
// ## 为什么住在 App 腿
//
// 要拿 `SemanticType.allCases` 与 prompt 文本对账，那个枚举在 App target 里
// （`MixCut/Models/Segment.swift`）。Core 侧看不到它 ⇒ 只能走 xcodebuild 腿。
// 顺带这也复核了"同步目录里的新文件不需要登记"这条 2026-11-04 的结论：
// 本文件没有 pbxproj 条目，跑不跑得起来由读数说话。
// ============================================================================

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // MixCutAppTests
    .deletingLastPathComponent()   // 仓库根

/// 会列出语义标签的资源/源码文件。⚠️ 少列一个文件，这条守卫就只盖住剩下的那些。
private let tagBearingFiles: [String] = [
    "MixCut/Resources/Prompts/segment_types_definition.md",
    "MixCut/Resources/Prompts/video_segmentation_prompt.md",
    "MixCut/Resources/Prompts/structure_generation_prompt.md",
    "MixCut/Resources/Prompts/reverse_structuring_prompt.md",
    "MixCut/Resources/Prompts/video_recombination_prompt.md",
    "MixCut/Services/AI/AIAnalysisService.swift",
    "MixCut/Services/Import/SegmentCommitter.swift",
    "Sources/MixCutCore/AgentToolCatalog.swift",
]

private func read(_ rel: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
}

/// 「这段文本有没有把 空镜 当成可选标签」这件事的唯一判据函数。
/// 抽出来是为了能做**反向对照**：拿一份合成文件喂进去必须判"有"，
/// 否则这条守卫可能只是"扫到了空集合"的恒绿。
private func advertisesEmptyShot(_ text: String) -> Bool {
    text.contains(SemanticType.emptyShot.rawValue)
}

@Suite("ETB · 空镜标签边界")
struct EmptyLensTagBoundaryTests {

    @Test("ETB-1 语义标签共 12 个，第 12 个是「空镜」")
    func tagRoster() {
        // 计数钉死的目的不是数字本身，而是"再加一个 case 要同轮想清楚它归谁写"。
        #expect(SemanticType.allCases.count == 12,
                "标签集变了而这里没跟上 ⇒ 先问新加的那个是谁写入的：AI 能写的和机器专属的不该混在一张表里")
        #expect(SemanticType.allCases.last == .emptyShot)
        #expect(SemanticType.emptyShot.rawValue == "空镜", "标签文案是要上屏给用户看的，改字要连筛选器与徽标一起看")
    }

    @Test("ETB-2 没有任何 prompt／白名单／MCP 描述把「空镜」列为可选标签")
    func emptyShotIsNotAdvertised() throws {
        for rel in tagBearingFiles {
            let text = try read(rel)
            // 先证"扫对了文件"：每个文件都得含某个真标签，否则是在拿空文本自证
            #expect(text.contains("过渡") || text.contains("painPoint") || text.contains("痛点"),
                    "\(rel) 里一个语义标签都没有 ⇒ 取样面对不上，这条判据在这颗文件上是空跑的")
            #expect(!advertisesEmptyShot(text),
                    "\(rel) 把「空镜」当成了可选标签 ⇒ 模型可以凭文本编造静音结论，拦打标退化成求模型别打标")
        }
    }

    @Test("ETB-3 反向对照：这条守卫不是恒绿（合成文件里加了「空镜」必须判成有）")
    func guardIsNotVacuous() throws {
        let real = try read("MixCut/Resources/Prompts/segment_types_definition.md")
        #expect(!advertisesEmptyShot(real), "真文件已经被改坏了，ETB-2 应该已经红在这里")
        #expect(advertisesEmptyShot(real + "\n可选标签：痛点、过渡、空镜"),
                "合成样本都判不出 ⇒ advertisesEmptyShot 恒 false，ETB-2 整条是空跑的")
    }

    @Test("ETB-4 「空镜」能过 SwiftData 的 JSON 往返（标签写进去读得回来，徽标才不会空）")
    func emptyShotSurvivesPersistence() throws {
        let data = try JSONEncoder().encode([SemanticType.emptyShot])
        let back = try JSONDecoder().decode([SemanticType].self, from: data)
        #expect(back == [.emptyShot], "往返丢标签 ⇒ 屏上不会有「空镜」徽标，用户看不到这段为什么没标签")
        // 旧数据（11 个标签的库）读进来不许炸
        let legacy = try JSONDecoder().decode([SemanticType].self,
                                             from: Data("[\"痛点\",\"过渡\"]".utf8))
        #expect(legacy == [.painPoint, .transition])
    }

    @Test("ETB-5 判定住 Core、写入住 App：名单与定罪腿不许在标签枚举里找答案")
    func policyDoesNotDependOnTheTag() {
        // 「空镜」标签只是判定结论的**投影**。判据本身不许读标签，否则第二次重跑分析时
        // 会拿上一次的结果当证据（自证循环），拦不打标也会跟着漂。
        let v = EmptyLensPolicy.verdict(.init(voicedFraction: 0.0), text: "任意文本")
        #expect(v == .emptyLens(.silentWindow))
        #expect(EmptyLensPolicy.knownHallucinationHit("空镜") == nil,
                "标签文案被当成套话名单的一部分 ⇒ 名单与标签耦上了，改名会连带改判定")
    }
}
