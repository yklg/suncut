import Foundation

/// 知识库文档的来源类型。
public enum KnowledgeSource: String, CaseIterable, Sendable {
    /// 用户本地上传（txt/md/pdf/docx）
    case upload
    /// AI 联网调研产物
    case aiResearch
    /// 电商商品链接解析
    case ecommerceLink
    /// 用户手动粘贴文本
    case manualPaste

    public var displayLabel: String {
        switch self {
        case .upload:         return "本地上传"
        case .aiResearch:     return "AI 调研"
        case .ecommerceLink:  return "电商链接"
        case .manualPaste:    return "手动粘贴"
        }
    }
}

/// 引用溯源描述：文案中的一句断言对应哪份资料。
///
/// - `documentTitle`/`sourceURL` 均为**快照**——原文档日后改名或删除，出处仍可读；
/// - 引用随文案走：materialize 时与文案一起写入 `SegmentDub.citationsData`。
public struct CitationDescriptor: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let documentTitle: String
    public let sourceURL: String?

    public init(chunkID: UUID, documentTitle: String, sourceURL: String?) {
        self.chunkID = chunkID
        self.documentTitle = documentTitle
        self.sourceURL = sourceURL
    }
}
