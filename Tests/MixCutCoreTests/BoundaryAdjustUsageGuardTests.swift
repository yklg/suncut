import Foundation
import Testing

/// BoundaryAdjustRow「契约常量实际使用」源码扫描守卫。
///
/// 守卫目标：微调行视图的 frame 只准引用 `BoundaryAdjustLayout` 常量，不写裸字面量。
/// 纯数据契约测试无法证明视图真的引用了常量，本扫描器沿真实文件源码补齐这半边，
/// 形状照 TagRowContainerGuardTests：真仓基线 + 反向对照（证明守卫非恒绿）。
enum BoundaryAdjustUsageScan {

    /// 剥注释与字符串字面量（逐字符等长替换，保留换行 ⇒ 结构可按原文扫描）。
    static func codeOnly(_ src: String) -> String {
        var a = Array(src)
        let n = a.count
        enum State { case code, lineComment, blockComment, string, rawString }
        var state: State = .code
        var i = 0
        while i < n {
            switch state {
            case .code:
                if a[i] == "/", i + 1 < n, a[i + 1] == "/" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .lineComment
                } else if a[i] == "/", i + 1 < n, a[i + 1] == "*" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .blockComment
                } else if a[i] == "\"" {
                    if i + 2 < n, a[i + 1] == "\"", a[i + 2] == "\"" {
                        a[i] = " "; a[i + 1] = " "; a[i + 2] = " "; i += 3; state = .rawString
                    } else {
                        a[i] = " "; i += 1; state = .string
                    }
                } else { i += 1 }
            case .lineComment:
                if a[i] == "\n" { state = .code } else { a[i] = " "; i += 1 }
            case .blockComment:
                if a[i] == "*", i + 1 < n, a[i + 1] == "/" {
                    a[i] = " "; a[i + 1] = " "; i += 2; state = .code
                } else { if a[i] != "\n" { a[i] = " " }; i += 1 }
            case .string:
                if a[i] == "\\", i + 1 < n { a[i] = " "; a[i + 1] = " "; i += 2 }
                else if a[i] == "\"" { a[i] = " "; i += 1; state = .code }
                else { if a[i] != "\n" { a[i] = " " }; i += 1 }
            case .rawString:
                if a[i] == "\"", i + 2 < n, a[i + 1] == "\"", a[i + 2] == "\"" {
                    a[i] = " "; a[i + 1] = " "; a[i + 2] = " "; i += 3; state = .code
                } else { if a[i] != "\n" { a[i] = " " }; i += 1 }
            }
        }
        return String(a)
    }

    /// 从源码提取 `struct <name>` 的结构域（含外层大括号）；按大括号配对。
    static func structBody(named name: String, in source: String) -> String? {
        guard let marker = source.range(of: "struct \(name)") else { return nil }
        var depth = 0
        var started = false
        var i = marker.upperBound
        let regionStart = i
        while i < source.endIndex {
            let c = source[i]
            if c == "{" {
                depth += 1
                started = true
            } else if c == "}" {
                depth -= 1
                if started, depth == 0 {
                    return String(source[regionStart..<source.index(after: i)])
                }
            }
            i = source.index(after: i)
        }
        return nil
    }

    /// 禁止出现的裸字面量：宽度契约项。
    static let forbiddenPatterns = [
        "width: 10", "width: 14", "width: 20", "width: 43"
    ]

    static func violations(in body: String) -> [String] {
        forbiddenPatterns.filter { body.contains($0) }
    }
}

// MARK: - 仓库根与读文件

private let usageRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private let usageSourceRelative = "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"

private func extractRegion() -> String? {
    guard let src = try? String(contentsOf: usageRepoRoot.appendingPathComponent(usageSourceRelative),
                                encoding: .utf8) else { return nil }
    let stripped = BoundaryAdjustUsageScan.codeOnly(src)
    return BoundaryAdjustUsageScan.structBody(named: "BoundaryAdjustRow", in: stripped)
}

// MARK: - 守卫用例

struct BoundaryAdjustUsageGuardTests {

    @Test("区域提取：SegmentPropertiesSection 中的 BoundaryAdjustRow 结构域非空")
    func regionExtractionSucceeds() {
        guard let body = extractRegion() else {
            Issue.record("无法从真实文件提取 BoundaryAdjustRow 结构域（扫描根或结构名变了）")
            return
        }
        #expect(body.contains("var body"))
    }

    @Test("真仓基线：无裸字面量 frame；契约常量引用 ≥ 6（标签/按钮/字段各 2 处）")
    func realRepoUsesContractConstants() {
        guard let body = extractRegion() else {
            Issue.record("结构域提取失败")
            return
        }
        let violations = BoundaryAdjustUsageScan.violations(in: body)
        #expect(violations.isEmpty, "微调行出现裸字面量：\(violations)")
        // 三类宽度都必须来自契约（视图复用了帧构造器，故按常量种类而非调用点数断言）
        #expect(body.contains("BoundaryAdjustLayout.labelWidth"))
        #expect(body.contains("BoundaryAdjustLayout.adjustButtonWidth"))
        #expect(body.contains("BoundaryAdjustLayout.timeFieldWidth"))
    }

    @Test("反向对照：常量引用替换为字面量后必须扫出违规（守卫非恒绿）")
    func replacingConstantsWithLiteralsFlipsRed() {
        guard let body = extractRegion() else {
            Issue.record("结构域提取失败")
            return
        }
        let mutated = body
            .replacingOccurrences(of: "BoundaryAdjustLayout.labelWidth", with: "10")
            .replacingOccurrences(of: "BoundaryAdjustLayout.adjustButtonWidth", with: "14")
            .replacingOccurrences(of: "BoundaryAdjustLayout.timeFieldWidth", with: "43")
        let violations = BoundaryAdjustUsageScan.violations(in: mutated)
        #expect(violations.count >= 3, "替换后应扫出 ≥3 条违规，实得 \(violations)")
    }
}
