import Foundation
import Testing
@testable import MixCutCore

/// 身份字面量的单一来源守卫。
///
/// 守的不是"有没有出现 MixCut 这个词"（UI 文案、类型名里合法存在），而是**身份常量**——
/// bundle id、目录名、库文件名、日志名、MCP 注册名。这些一旦散进各文件，换品牌时就会漏改，
/// 而漏改的后果是静默读到旧路径或写错注册键。
///
/// 判据三条，全部从 `Brand` 派生，所以本文件不含任何身份字面量，Brand 换值后口径自动跟着变：
/// 1. 小写短名（bundleID、`*.log`、MCP 键、`~/.cache/<短名>` 都含它）；
/// 2. `"MixCut.store"` 这种带引号的库文件字面量；
/// 3. `appendingPathComponent("MixCut"` 这种带引号的目录名字面量。
///
/// 历史路径（`Brand.legacyCacheBundleID` / `legacyShortName`）是有意钉死的例外，只能住在 Brand.swift 里。
@Test("身份字面量只允许出现在 Brand.swift")
func brandLiteralsLiveOnlyInBrandSwift() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/MixCutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 包根
    let brandFile = "Sources/MixCutCore/Brand.swift"

    let forbidden = [
        Brand.shortName,
        "\"\(Brand.storeFileName)\"",
        "appendingPathComponent(\"\(Brand.dataDirectoryName)\"",
    ]

    var offenders: [String] = []
    var scanned = 0
    for dir in ["MixCut", "Sources", "Tests"] {
        let base = root.appendingPathComponent(dir)
        guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            Issue.record("扫描目录不存在：\(dir) —— 判据失效，不是通过")
            return
        }
        for case let url as URL in en where url.pathExtension == "swift" {
            var rel = url.path
            if rel.hasPrefix(root.path) { rel = String(rel.dropFirst(root.path.count + 1)) }
            if rel == brandFile { continue }
            scanned += 1
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }          // 注释里提历史路径是必要的说明
                for lit in forbidden where line.contains(lit) {
                    offenders.append("\(rel):\(n + 1)  \(t.prefix(78))")
                }
            }
        }
    }

    if scanned <= 100 {
        Issue.record("只扫到 \(scanned) 个文件，扫描根可能错了 —— 判据失效，不算通过")
    }
    if !offenders.isEmpty {
        let detail = offenders.joined(separator: "\n")
        Issue.record("身份字面量散落在 Brand.swift 之外：\n\(detail)")
    }
}

@Test("Brand 的派生值都由身份字段拼出，历史值不随当前值漂移")
func brandDerivedValuesAndLegacyArePinned() throws {
    #expect(Brand.logFileName == "\(Brand.shortName).log")
    #expect(Brand.mcpServerName == Brand.shortName)
    #expect(Brand.voiceAliasFallback == Brand.shortName)
    #expect(Brand.logDirectoryComponent == "\(Brand.bundleID)/logs")
    #expect(Brand.aiFailDirectoryComponent == "\(Brand.bundleID)/ai-fail")
    #expect(Brand.legacyWhisperModelsComponent == "\(Brand.legacyCacheBundleID)/whisper-models")
    #expect(Brand.legacyHomeCacheModelsComponent == ".cache/\(Brand.legacyShortName)/models")

    // 历史值必须是**独立钉死的字面量**。若写成 `= bundleID` / `= shortName`，换品牌时它们会
    // 跟着漂移，老用户盘上已下载的文件就再也扫不到 —— 这一条要能变红。
    let brandText = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MixCutCore/Brand.swift"),
        encoding: .utf8)
    for name in ["legacyCacheBundleID", "legacyShortName"] {
        #expect(brandText.contains("let \(name) = \""), "\(name) 必须直接赋字面量，不能引用当前身份字段")
    }
}
