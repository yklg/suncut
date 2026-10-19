import Foundation
import Testing

@testable import SunCut

// ============================================================================
// DT · MCP `export_scheme` 的交付目标解析
//
// ## 为什么单独测这颗
//
// MCP 是**无人值守**入口：没有面板、没有人会去盯屏上那行回显。此前三条 UI 导出腿都过
// `ExportConfig`，唯独 MCP 连 config 都不传，直接吃 `ExportConfig()` 的默认值 ——
// 等于"agent 派出去的活完全没有交付口径"。2026-10-19 那 41 条报废品要是出自 MCP，
// 连"谁选的 480p"都查不到。
//
// ## 判别式设计
//
// 打的是**解析函数本身**（输入字符串 → 目标 / 抛错），不是"调一次导出再看产物"。
// 关键的一条是**未知值必须抛**：若写成 `DeliveryTargetID(rawValue:) ?? .qianchuanVertical`，
// 拼错的 `qianchuan` 会静默按千川跑，看起来一切正常 —— 那正是本次事故"无声分叉"的形状。
// ============================================================================

@Suite("DT · MCP 交付目标解析", .serialized)
struct ExportDeliveryTargetParsingTests {

    @Test("省略该字段 ⇒ 千川竖屏投放（缺省必须有闸，不能缺省到「不限」）")
    func omittedMeansQianchuan() throws {
        #expect(try MCPToolHandlers.deliveryTarget(nil) == .qianchuanVertical)
    }

    @Test("两个合法值各自解析成功")
    func validValuesParse() throws {
        #expect(try MCPToolHandlers.deliveryTarget("qianchuanVertical") == .qianchuanVertical)
        #expect(try MCPToolHandlers.deliveryTarget("unrestricted") == .unrestricted)
    }

    @Test("未知值必须抛 invalidArgument，且 message 要把可选项列出来")
    func unknownValueIsRejectedNotSilentlyDefaulted() {
        for bad in ["qianchuan", "QianchuanVertical", "", "unrestricted ", "不限", "720p"] {
            do {
                let got = try MCPToolHandlers.deliveryTarget(bad)
                let shown = bad.isEmpty ? "〈空串〉" : bad
                Issue.record("非法值 \(shown) 竞被接受，解析成 \(got.rawValue) —— 静默回退就是无声分叉")
            } catch let failure as MCPToolHandlers.ToolFailure {
                #expect(failure.code == .invalidArgument,
                        "\(bad) 的错误码应为 invalidArgument，实得 \(failure.code)")
                #expect(failure.message.contains(bad) || bad.isEmpty,
                        "报错要回显用户传的那个值：\(failure.message)")
                #expect(failure.message.contains("qianchuanVertical") && failure.message.contains("unrestricted"),
                        "报错要列出可选项，否则调用方只能猜：\(failure.message)")
            } catch {
                Issue.record("\(bad) 抛的不是 ToolFailure 而是 \(type(of: error))")
            }
        }
    }

    @Test("合法值集合与 schema 里写的 enum 必须一致（防 schema 与解析两头漂）")
    func schemaEnumMatchesParser() throws {
        let tool = try #require(AgentToolCatalog.all.first { $0.name == "export_scheme" })
        #expect(tool.inputSchemaJSON.contains("\"enum\":[\"qianchuanVertical\",\"unrestricted\"]"),
                "schema 的 enum 必须逐字等于 allCases：\(DeliveryTargetID.allCases.map(\.rawValue))")
        // delivery_target 必须是**可选**：加进 required 会打断所有既有调用方
        #expect(!tool.inputSchemaJSON.contains(#""required":["delivery_target""#))
        #expect(tool.inputSchemaJSON.contains(#""required":["scheme_ids","output_dir"]"#))
    }
}
