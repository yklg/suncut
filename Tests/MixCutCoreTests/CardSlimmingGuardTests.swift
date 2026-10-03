import Foundation
import Testing

/// 卡片瘦化守卫：编辑控件不得回流到卡片/列表行；片段属性视图只住在 SegmentPropertiesSection；
/// 自绘控件与批量枚举全项目唯一定义。
///
/// 守卫目标：A1 瘦化是结构约束（卡片 = 纯展示），没有自动拦截的话，后续任何需求
/// 都可能把控件再次塞回卡片，重演溢出/错位。形状照仓库既有源码扫描守卫：真仓基线 + 反向对照。
enum CardSlimmingScan {

    /// 剥注释与字符串字面量。
    static func codeOnly(_ src: String) -> String {
        BoundaryAdjustUsageScan.codeOnly(src)
    }

    static func structBody(named name: String, in source: String) -> String? {
        BoundaryAdjustUsageScan.structBody(named: name, in: source)
    }

    /// 卡片/列表行内禁止出现的编辑控件与旧入口。
    static let forbiddenInCard = [
        "SegmentDubControls(",
        "BoundaryAdjustRow(",
        "SegmentDubCompactControls(",
        "InlineSwitch(",
        "SubtitleFontSizePopover(",
        "SegmentCard.apply"
    ]

    static func violations(in body: String) -> [String] {
        forbiddenInCard.filter { body.contains($0) }
    }

    /// 只允许出现在 SegmentPropertiesSection.swift 的片段属性视图名。
    static let propertySectionNames = [
        "BoundarySection", "SubtitleSection", "VoiceLockSection", "CategorySection"
    ]
}

// MARK: - 仓库根

private let slimRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let libraryViewRelative = "MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"
private let propertiesRelative = "MixCut/Views/SegmentLibrary/SegmentPropertiesSection.swift"

private let mixCutDirectory = slimRepoRoot.appendingPathComponent("MixCut")

private func readLibraryView() -> String? {
    guard let src = try? String(contentsOf: slimRepoRoot.appendingPathComponent(libraryViewRelative),
                                encoding: .utf8) else { return nil }
    return CardSlimmingScan.codeOnly(src)
}

/// 递归收集 MixCut 下全部 .swift 源码（codeOnly）。
private func allSwiftSources(in directory: URL) -> [String] {
    var result: [String] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.isDirectoryKey])
    else { return result }
    for url in entries {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            result.append(contentsOf: allSwiftSources(in: url))
        } else if url.pathExtension == "swift",
                  let src = try? String(contentsOf: url, encoding: .utf8) {
            result.append(CardSlimmingScan.codeOnly(src))
        }
    }
    return result
}

// MARK: - 守卫用例

struct CardSlimmingGuardTests {

    // MARK: 卡片/列表行无编辑控件

    @Test("SegmentCard / SegmentRow 结构域内无编辑控件与旧入口")
    func cardsContainNoEditControls() {
        guard let view = readLibraryView() else {
            Issue.record("无法读取 SegmentLibraryView")
            return
        }
        for name in ["SegmentCard", "SegmentRow"] {
            guard let body = CardSlimmingScan.structBody(named: name, in: view) else {
                Issue.record("提取 \(name) 结构域失败")
                continue
            }
            let violations = CardSlimmingScan.violations(in: body)
            #expect(violations.isEmpty, "\(name) 中出现编辑控件：\(violations)")
        }
    }

    @Test("反向对照：卡片域注入禁名必须扫红（守卫非恒绿）")
    func injectedForbiddenNameIsDetected() {
        guard let view = readLibraryView(),
              let body = CardSlimmingScan.structBody(named: "SegmentCard", in: view) else {
            Issue.record("提取失败")
            return
        }
        let mutated = body + "\nInlineSwitch(isOn: .constant(false), label: \"\", systemImage: \"\", help: \"\") {}"
        #expect(!CardSlimmingScan.violations(in: mutated).isEmpty)
    }

    // MARK: 片段属性视图只住在 SegmentPropertiesSection

    @Test("片段属性视图名只出现在 SegmentPropertiesSection.swift")
    func propertyViewsLiveOnlyInPropertiesFile() {
        let sources = allSwiftSources(in: mixCutDirectory)
        guard let sectionSource = try? String(
            contentsOf: slimRepoRoot.appendingPathComponent(propertiesRelative),
            encoding: .utf8) else {
            Issue.record("无法读取 SegmentPropertiesSection.swift")
            return
        }
        let strippedSection = CardSlimmingScan.codeOnly(sectionSource)
        for name in CardSlimmingScan.propertySectionNames {
            #expect(strippedSection.contains(name), "\(name) 应定义在 SegmentPropertiesSection")
            for source in sources {
                // 同一份文件内容会包含自身——跳过：用「除属性文件外」的来源集合
            }
        }
        // 除属性文件外的任何来源都不应出现属性视图名（private 类型名）
        for source in sources where !source.contains("struct SegmentPropertiesContent") {
            for name in CardSlimmingScan.propertySectionNames {
                #expect(!source.contains(name), "\(name) 泄漏到属性文件之外")
            }
        }
    }

    // MARK: 唯一定义

    @Test("InlineSwitch / InlineTapLabel / SegmentBatchActions 全项目各仅 1 处定义")
    func singleDefinitions() {
        let sources = allSwiftSources(in: mixCutDirectory)
        let definitions = [
            "struct InlineSwitch",
            "struct InlineTapLabel",
            "enum SegmentBatchActions"
        ]
        for def in definitions {
            let count = sources.reduce(0) { $0 + ($1.contains(def) ? 1 : 0) }
            #expect(count == 1, "\(def) 定义数应为 1，实得 \(count)")
        }
    }

    @Test("无 SegmentCard.apply 残留调用")
    func noLegacyCardApplyReferences() {
        let sources = allSwiftSources(in: mixCutDirectory)
        for source in sources {
            #expect(!source.contains("SegmentCard.apply"))
        }
    }
}
