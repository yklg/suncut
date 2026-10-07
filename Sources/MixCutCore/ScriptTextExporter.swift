import Foundation

// MARK: - 导出投影（纯值，零 SwiftData 依赖）

/// 脚本导出用的单条引用出处快照。
public struct ScriptExportCitation: Equatable, Sendable {
    public let documentTitle: String
    public let sourceURL: String?

    public init(documentTitle: String, sourceURL: String?) {
        self.documentTitle = documentTitle
        self.sourceURL = sourceURL
    }
}

/// 脚本导出用的单段投影。
public struct ScriptExportScene: Equatable, Sendable {
    public let order: Int
    public let tag: String
    public let duration: Double
    public let text: String
    public let citations: [ScriptExportCitation]

    public init(order: Int, tag: String, duration: Double,
                text: String, citations: [ScriptExportCitation] = []) {
        self.order = order
        self.tag = tag
        self.duration = duration
        self.text = text
        self.citations = citations
    }
}

/// 脚本导出用的整篇投影。
public struct ScriptExportDraft: Equatable, Sendable {
    public let title: String
    public let direction: ScriptDirection
    public let productName: String?
    public let scenes: [ScriptExportScene]

    public init(title: String, direction: ScriptDirection,
                productName: String?, scenes: [ScriptExportScene]) {
        self.title = title
        self.direction = direction
        self.productName = productName
        self.scenes = scenes
    }

    /// 总时长（各段求和）。
    public var totalDuration: Double { scenes.reduce(0) { $0 + $1.duration } }
}

/// 脚本文本导出格式。
public enum ScriptTextExportFormat: String, CaseIterable, Sendable {
    case plainText
    case markdown

    public var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown:  return "md"
        }
    }

    public var displayLabel: String {
        switch self {
        case .plainText: return "纯文本 (.txt)"
        case .markdown:  return "Markdown (.md)"
        }
    }
}

// MARK: - Exporter

/// 脚本 → .txt / .md 渲染器（纯逻辑，可快照测试）。
///
/// 契约：
/// - 输出确定、无时间戳/机器信息（同样输入逐字一致，便于回归）；
/// - .txt 以序号+标签+时长分段，文案全文不截断；
/// - .md 以标签为分节标题，引用走脚注，文末附来源列表；无引用的段落不带脚注；
/// - 逆向文案与正向文案同构渲染，仅「创作方向」标注不同。
public enum ScriptTextExporter {

    public static func render(_ draft: ScriptExportDraft, format: ScriptTextExportFormat) -> String {
        switch format {
        case .plainText: return renderPlainText(draft)
        case .markdown:  return renderMarkdown(draft)
        }
    }

    // MARK: TXT

    static func renderPlainText(_ draft: ScriptExportDraft) -> String {
        var lines: [String] = []
        lines.append("《\(draft.title)》")
        lines.append("创作方向：\(directionLabel(draft.direction))")
        if let product = draft.productName, !product.isEmpty {
            lines.append("产品：\(product)")
        }
        lines.append("共 \(draft.scenes.count) 段 · 合计 \(durationText(draft.totalDuration)) 秒")
        lines.append("")

        if draft.scenes.isEmpty {
            lines.append("（暂无段落）")
            return lines.joined(separator: "\n") + "\n"
        }

        for scene in draft.scenes {
            lines.append("\(scene.order). [\(scene.tag)]（\(durationText(scene.duration)) 秒）")
            lines.append(scene.text)
            if !scene.citations.isEmpty {
                let titles = scene.citations.map(\.documentTitle)
                lines.append("引用：" + titles.joined(separator: "、"))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Markdown

    static func renderMarkdown(_ draft: ScriptExportDraft) -> String {
        var lines: [String] = []
        lines.append("# \(draft.title)")
        lines.append("")
        lines.append("- 创作方向：\(directionLabel(draft.direction))")
        if let product = draft.productName, !product.isEmpty {
            lines.append("- 产品：\(product)")
        }
        lines.append("- 段落数：\(draft.scenes.count)（合计 \(durationText(draft.totalDuration)) 秒）")
        lines.append("")

        if draft.scenes.isEmpty {
            lines.append("（暂无段落）")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        // 全局脚注编号：同一文档标题+URL 合并为同一脚注，按首次出现顺序编号。
        var footnoteOrder: [String] = []
        var footnoteIndex: [String: Int] = [:]
        var footnoteBodies: [Int: String] = [:]

        func index(for citation: ScriptExportCitation) -> Int {
            let key = citation.sourceURL.map { "\(citation.documentTitle)|\($0)" } ?? citation.documentTitle
            if let existing = footnoteIndex[key] { return existing }
            let number = (footnoteIndex.count) + 1
            footnoteIndex[key] = number
            footnoteOrder.append(key)
            let suffix = citation.sourceURL.map { "（\($0)）" } ?? ""
            footnoteBodies[number] = "\(citation.documentTitle)\(suffix)"
            return number
        }

        for scene in draft.scenes {
            lines.append("## \(scene.order). \(scene.tag)（\(durationText(scene.duration)) 秒）")
            lines.append("")
            if scene.citations.isEmpty {
                lines.append(scene.text)
            } else {
                let marks = scene.citations.map { "[^\(index(for: $0))]" }.joined()
                lines.append(scene.text + marks)
            }
            lines.append("")
        }

        if !footnoteOrder.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## 引用来源")
            lines.append("")
            for key in footnoteOrder {
                let number = footnoteIndex[key]!
                lines.append("[^\(number)]: \(footnoteBodies[number]!)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    /// 时长保留一位小数（整数也带 .0，保证导出稳定可读）。
    static func durationText(_ duration: Double) -> String {
        String(format: "%.1f", duration)
    }

    static func directionLabel(_ direction: ScriptDirection) -> String {
        switch direction {
        case .forward: return "产品资料撰写"
        case .reverse: return "现成文案结构化"
        }
    }
}
