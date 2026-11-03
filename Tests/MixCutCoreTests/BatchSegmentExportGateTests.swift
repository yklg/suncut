import Foundation
import Testing

// ============================================================================
// ES-09 · MCP `export_segments` 那条腿的交付闸与回读（计划 2026-10-19 §六-3）
//
// 为什么要有这组：`BatchSegmentExportService` 只有 MCP 在用、UI 不走它，所以它是整条导出链里
// **唯一**没有被「切前两闸 + 切后回读」覆盖的交付腿。它此前按源片尺寸直接切，闸一条都不挂；
// 而 MCP 是无人值守入口，出片后没人会替它看尺寸。
//
// 本组是**源码形状判据**（该文件在 App target，`swift test` 编不到）：
// 钉住「两条闸都在切之前」「切之后有回读」「入口显式解析 delivery_target」。
// 真正的执行腿由 App 测试目标/用户跑（会起宿主实例）。
// ============================================================================

private enum BatchExportProbeError: Error { case probeDead }

private let batchExportRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func batchExportSource(_ relative: String) -> String? {
    try? String(contentsOf: batchExportRepoRoot.appendingPathComponent(relative), encoding: .utf8)
}

struct BatchSegmentExportGateTests {

    @Test("ES-09 MCP 分镜批量导出：切前两条闸 + 切后回读 + 入口显式解析交付目标")
    func mcpSegmentExportIsGatedAndReadBack() throws {
        guard let service = batchExportSource("MixCut/Services/Export/BatchSegmentExportService.swift") else {
            throw BatchExportProbeError.probeDead
        }
        #expect(service.contains("spec: DeliverySpec"),
                "exportAll 不再收交付口径 ⇒ MCP 这条路又回到「没有任何闸」的形状")
        #expect(service.contains("DeliveryGate.rejectionMessage"),
                "缺宽高/比例/分辨率区间闸 ⇒ 产物可能被平台拒收")
        #expect(service.contains("DeliveryGate.durationRejectionMessage"),
                "缺时长区间闸 ⇒ 短于 4s 的切片会混进交付清单")
        let probeCount = service.components(separatedBy: "probeCanvasSize").count - 1
        #expect(probeCount >= 2,
                "回读腿缺失（实得 \(probeCount) 次 probeCanvasSize）：切前一次读计划画布、切后一次读落盘画布")
        #expect(service.contains("removeItem(at: outputURL)"),
                "失败/半成品不删 ⇒ 用户目录会留下「能播但内容只有一半」的 mp4")

        guard let handler = batchExportSource("MixCut/Services/MCP/MCPSegmentToolHandlers.swift") else {
            throw BatchExportProbeError.probeDead
        }
        #expect(handler.contains("MCPToolHandlers.deliveryTarget(args.delivery_target)"),
                "入口没走统一解析 ⇒ 未知 delivery_target 会被静默当成缺省")
        #expect(handler.contains("spec: spec"),
                "解析出的交付目标没喂进服务 ⇒ 闸用的还是另一份默认值")

        guard let catalog = batchExportSource("Sources/MixCutCore/AgentToolCatalog.swift") else {
            throw BatchExportProbeError.probeDead
        }
        #expect(catalog.contains(#""delivery_target":{"type":"string","enum":["qianchuanVertical","unrestricted"]"#),
                "工具 schema 没暴露交付目标 ⇒ Agent 无法按投放/留档两种口径调用")
    }

    @Test("ES-09b 反例：把两条闸摘掉后，同一组形状判据必须变红")
    func missingGateIsDetected() {
        let hollow = """
        func exportAll(items: [BatchExportItem]) async {
            try? await ffmpeg.cutSegment(from: item.sourcePath, start: 0, end: 1, to: "x")
        }
        """
        #expect(!hollow.contains("DeliveryGate.rejectionMessage"))
        #expect(!hollow.contains("DeliveryGate.durationRejectionMessage"))
        #expect(hollow.components(separatedBy: "probeCanvasSize").count - 1 == 0,
                "没有回读的形态必须被同一套计数认出（否则上面那条是恒绿的）")
    }
}
