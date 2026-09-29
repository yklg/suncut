import Foundation
import Testing
@testable import MixCutCore

/// `TextProvenance` 的契约测试（计划 v9 §10.4 组 3，TC-88…TC-92）
///
/// 本文件已从预览落地：在 `Tests/MixCutCoreTests/` 内、已编译、`swift test` 跑绿（2026-09-28）。
///
/// **这批测试反过来定了一条设计约束**（写测试才暴露出来的）：`Segment.text` 住在 App target（`MixCut/Models/`），
/// 而工程只有 application target ⇒ 「来源该不该改、改成什么」这条规则**留在 `Segment` 里就永远没有单测**。
/// 因此规则必须下沉成 `Sources/MixCutCore/TextProvenance.swift`，`Segment.setText(_:source:)` 只是它的调用者。
/// 已写回计划 §3.3/§10.6。
///
/// 假定签名：
/// ```
/// public enum TranscriptSource: String, CaseIterable, Sendable {
///     case unknownLegacy      // 旧数据·未记录来源（新列的唯一默认值）
///     case fullVideoSlice     // 整片听写后按时间切到这一段
///     case uploadedClip       // 自建分镜：用户上传文件整听
///     case segmentLocal       // 逐段重听（本地 whisper）
///     case segmentCloud       // 逐段重听（云端 paraformer）
///     case manualEdit         // 界面手改
///     case agentEdit          // MCP / Agent 写入
///     case cleaned            // 启动批量清洗改写
///     case boundaryShift      // 边界调整导致的段间搬字
/// }
/// public struct TextUpdate: Equatable, Sendable {
///     public let shouldWrite: Bool
///     public let source: TranscriptSource          // 不写时 = 原来源
///     public let previousSource: TranscriptSource?  // 不写时 = nil
/// }
/// public enum TextProvenance {
///     public static func resolve(current: String,
///                                currentSource: TranscriptSource,
///                                incoming: String,
///                                writer: TranscriptSource) -> TextUpdate
/// }
/// ```
///
/// 钉住的规则（红线 R8 + 一般规则 R-d/R-e）：
/// - **内容没真变 ⇒ 一律不写、来源不动**（照仓库既有 `MixCutApp.swift:518` 的形状，防止启动清洗把手改来源刷掉）
/// - **空文本 ⇒ 不写**（今天 `ImportViewModel.swift:1234` 把空识别当成功，这条要挡住它）
/// - 写入时 `previousSource` 必是**同一段**的原来源；搬字（`:903/:906` 那种）记 `boundaryShift`，**不继承邻段来源**
/// - 默认值只许是 `unknownLegacy`：不许默认成任何真实来源（第 2 期 S4"默认值冒充数据"那一族）
///
/// 非空洞性对应：TC-92 逐个走**所有**枚举值当 writer 与当 currentSource，任何一格没被走到就是死值。

@Suite("TextProvenance：台词来源与不覆盖纪律")
struct TextProvenanceTests {

    private func resolved(_ current: String,
                          from currentSource: TranscriptSource,
                          to incoming: String,
                          by writer: TranscriptSource) -> TextUpdate {
        TextProvenance.resolve(current: current, currentSource: currentSource,
                               incoming: incoming, writer: writer)
    }

    // MARK: TC-88 幂等

    @Test("TC-88 同一内容重复写 ⇒ 第二次不落笔、来源不被改写（幂等）")
    func repeatedIdenticalWriteIsNoOp() {
        let first = resolved("空", from: .unknownLegacy, to: "人参果很好", by: .segmentLocal)
        #expect(first.shouldWrite)
        #expect(first.source == .segmentLocal)
        #expect(first.previousSource == .unknownLegacy)

        let second = resolved("人参果很好", from: first.source, to: "人参果很好", by: .segmentCloud)
        #expect(!second.shouldWrite, "内容没变却要落笔，等于白刷一次来源")
        #expect(second.source == .segmentLocal, "不写时来源必须保持原值，实际：\(second.source)")
        #expect(second.previousSource == nil)
    }

    // MARK: TC-89 清洗不许刷来源（R-e）

    @Test("TC-89 清洗后文本等价 ⇒ 手改的来源不能被刷成 cleaned")
    func cleaningThatChangesNothingKeepsSource() {
        // 比较规则定为"两端空白去掉后比字符串"，所以首尾空格差异一律算无变化
        let cases: [(String, String)] = [
            ("两层防撞袋", "两层防撞袋"),
            ("两层防撞袋  ", "两层防撞袋"),
            ("  两层防撞袋 \n", "两层防撞袋"),
            ("两层防撞袋", "两层防撞袋 "),
        ]
        for (current, cleaned) in cases {
            let result = resolved(current, from: .manualEdit, to: cleaned, by: .cleaned)
            #expect(!result.shouldWrite,
                    "\"\(current)\" → \"\(cleaned)\" 属无变化清洗，却允许落笔（来源会被刷掉）")
            #expect(result.source == .manualEdit)
        }

        // 对照：真空格被合并掉是**真变化**，这时才落笔并记 cleaned
        let real = resolved("两层 防撞袋", from: .manualEdit, to: "两层防撞袋", by: .cleaned)
        #expect(real.shouldWrite)
        #expect(real.source == .cleaned)
        #expect(real.previousSource == .manualEdit)
    }

    @Test("TC-89b 空识别 / 空白输入 ⇒ 一律不写，原句与来源都不动（挡住 :1234 那个 return true）")
    func emptyIncomingNeverOverwrites() {
        for incoming in ["", "   ", "\n\t "] {
            let result = resolved("孕妈妈一定要舍得吃", from: .fullVideoSlice, to: incoming, by: .segmentLocal)
            #expect(!result.shouldWrite, "空文本(\"\(incoming)\")不该覆盖已有台词")
            #expect(result.source == .fullVideoSlice)
            #expect(result.previousSource == nil)
        }
    }

    // MARK: TC-90 段间搬字

    @Test("TC-90 边界调整搬字 ⇒ 记 boundaryShift，不继承邻段的来源")
    func boundaryShiftDoesNotInheritNeighbour() {
        // A 段是逐段本地重听听出来的，B 段是旧数据；把 A 的尾巴并进 B
        let intoB = resolved("旧的一句", from: .unknownLegacy, to: "旧的一句 + 人工跟机器三重筛选",
                             by: .boundaryShift)
        #expect(intoB.shouldWrite)
        #expect(intoB.source == .boundaryShift, "搬字必须单列一档，不能冒充 .segmentLocal")
        #expect(intoB.previousSource == .unknownLegacy, "记的是**本段**的原来源，不是邻段的")

        // 反向对照：接口本身收不到"邻段来源"这个参数 ⇒ 结构上就继承不了（这条防的是将来加参数时偷懒）
        #expect(intoB.previousSource != .segmentLocal)
    }

    // MARK: TC-91 上传片段与整片切片是两档

    @Test("TC-91 uploadedClip 与 fullVideoSlice 不合并，各自写回自己")
    func uploadedClipAndFullSliceAreDistinct() {
        #expect(TranscriptSource.uploadedClip.rawValue != TranscriptSource.fullVideoSlice.rawValue)

        let uploaded = resolved("", from: .unknownLegacy, to: "都是人工跟机器三重筛选的", by: .uploadedClip)
        #expect(uploaded.shouldWrite && uploaded.source == .uploadedClip)

        let sliced = resolved("", from: .unknownLegacy, to: "都是人工跟机器三重筛选的", by: .fullVideoSlice)
        #expect(sliced.shouldWrite && sliced.source == .fullVideoSlice)

        #expect(uploaded.source != sliced.source, "两档被写成了同一档：段级台词的来源将无法区分")
    }

    // MARK: TC-92 枚举全量（防死值）

    @Test("TC-92 每个来源值都被走到过：当 writer 能写、当原来源能记住")
    func everySourceIsReachable() {
        let writers: [TranscriptSource] = TranscriptSource.allCases.filter { $0 != .unknownLegacy }
        #expect(writers.count == TranscriptSource.allCases.count - 1,
                "默认值之外每档都该能作为写入者出现")

        var seen: [String] = []
        for writer in writers {
            let result = resolved("旧文本", from: .unknownLegacy, to: "新文本-\(writer.rawValue)", by: writer)
            #expect(result.shouldWrite, "\(writer.rawValue) 作为写入者被拒绝，说明规则漏了它")
            #expect(result.source == writer)
            #expect(result.previousSource == .unknownLegacy)
            seen.append(result.source.rawValue)
        }
        #expect(Set(seen).count == writers.count, "不同 writer 写回了同一个来源：\(seen)")

        // 作为原来源也要能被记住
        for original in TranscriptSource.allCases {
            let result = resolved("A", from: original, to: "B", by: .manualEdit)
            #expect(result.previousSource == original, "\(original.rawValue) 作为原来源没被记住")
        }
    }

    @Test("TC-92b 默认值只许是 unknownLegacy（防'默认值冒充数据'）")
    func legacyDefaultIsTheOnlyBlindSpot() {
        #expect(TranscriptSource.allCases.contains(.unknownLegacy),
                "没有 unknownLegacy 这一档 ⇒ 旧库数据会被迫冒充某个真实来源")
        #expect(TranscriptSource.unknownLegacy != .segmentLocal)

        // 旧库迁移过来的段：原文与来源都在，新内容写入时 previousSource 必须显式说出"未记录"
        let upgraded = resolved("base 年代切出来的句子", from: .unknownLegacy, to: "人参果很好", by: .segmentLocal)
        #expect(upgraded.previousSource == .unknownLegacy)
    }

    // MARK: TC-110 trim 只有一个出处（App 侧不得再 trim 一遍）

    @Test("TC-110 要写的那个值由规则层给出：写时已去两端空白，不写时是 nil")
    func ruleLayerReturnsTheValueToWrite() {
        // 入参故意带两端空白：若实现不 trim，这条会红（trim 判据不是恒成立）
        let padded = resolved("旧词", from: .unknownLegacy, to: "  人参果很好 \n", by: .segmentLocal)
        #expect(padded.shouldWrite)
        #expect(padded.textToWrite == "人参果很好",
                "落库值必须已去两端空白；实际：\(String(describing: padded.textToWrite))")

        // 只有一端空白的"变更"：去掉空白后与原文相同 ⇒ 不写，且**不给值**（挡住写空格的口子）
        let whitespaceOnly = resolved("人参果很好", from: .segmentLocal, to: "人参果很好  ", by: .manualEdit)
        #expect(!whitespaceOnly.shouldWrite)
        #expect(whitespaceOnly.textToWrite == nil,
                "shouldWrite=false 还给值，调用方就有第二条路径可以落笔")

        // 空识别（今天被当成功返回的那一档）
        let empty = resolved("原句", from: .fullVideoSlice, to: "   \n ", by: .segmentCloud)
        #expect(!empty.shouldWrite)
        #expect(empty.textToWrite == nil)
        #expect(empty.source == .fullVideoSlice, "空结果不许把来源刷成云端")
    }
}
