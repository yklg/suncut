import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// 文档文本提取：把用户上传的 PDF / DOCX 提取为纯文本，供切块入知识库。
///
/// 失败纪律（不建空文档）：
/// - PDF 为扫描件/图片版（无文本层）⇒ 抛 `DocumentExtractionError.noTextLayer`；
/// - docx 解压或 XML 解析失败 ⇒ 抛对应错误；
/// - App 非沙盒：docx 用系统 `/usr/bin/unzip`（Process）解压到临时目录，无 SPM 依赖。
enum DocumentTextExtractor {

    static func plainText(from fileURL: URL) throws -> String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try extractPDF(fileURL)
        case "docx":
            return try extractDOCX(fileURL)
        case "txt", "md", "markdown":
            return try String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            throw DocumentExtractionError.unsupportedFormat(ext)
        }
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL) throws -> String {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentExtractionError.unreadablePDF
        }
        let text = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DocumentExtractionError.noTextLayer }
        return text
        #else
        throw DocumentExtractionError.unsupportedFormat("pdf")
        #endif
    }

    // MARK: - DOCX

    private static func extractDOCX(_ url: URL) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 系统 unzip（macOS 自带；非沙盒可执行）。-q 安静模式，-d 指定输出目录。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw DocumentExtractionError.docxUnzipFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DocumentExtractionError.docxUnzipFailed
        }

        let documentXML = tempDir.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: documentXML.path) else {
            throw DocumentExtractionError.docxMissingDocument
        }
        let parser = DOCXTextParser()
        let xmlData = try Data(contentsOf: documentXML)
        let parserDelegate = XMLParser(data: xmlData)
        parserDelegate.delegate = parser
        guard parserDelegate.parse() else {
            throw DocumentExtractionError.docxParseFailed
        }
        let text = parser.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DocumentExtractionError.noTextLayer }
        return text
    }
}

// MARK: - Errors

enum DocumentExtractionError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadablePDF
    /// 扫描件/图片版无文本层
    case noTextLayer
    case docxUnzipFailed
    case docxMissingDocument
    case docxParseFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "不支持的文件格式：\(ext)"
        case .unreadablePDF:
            return "无法读取该 PDF 文件"
        case .noTextLayer:
            return "该文件没有可提取的文字（可能是扫描件/图片版），请粘贴文字或使用文本版资料"
        case .docxUnzipFailed:
            return "DOCX 解压失败，请确认文件未损坏"
        case .docxMissingDocument:
            return "DOCX 内容缺失（word/document.xml 不存在）"
        case .docxParseFailed:
            return "DOCX 内容解析失败"
        }
    }
}

// MARK: - DOCX XML 解析委托

/// 解析 word/document.xml：
/// - `w:t`：文本节点
/// - `w:p`：段落结束插入换行
/// - `w:tab`：插入空格
private final class DOCXTextParser: NSObject, XMLParserDelegate {
    var result = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:tab" {
            result.append("\t")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        result.append(string)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "w:p" {
            result.append("\n")
        }
    }
}
