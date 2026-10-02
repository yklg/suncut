import Foundation

/// 分镜的**素材来源**（分镜级，同一条视频里不同分镜可以不同）。
///
/// 口径（业务定义）：
/// - selfShot 自拍：公司自己拍摄的原创视频；
/// - curated 搬运：来源于其他人的视频；
/// - aiGenerated AI生产：App 内「分镜头替换」合成的画面，或外部 AI 工具生成后上传的视频；
/// - unclassified 未分类：存量数据/尚未人工归类。
///
/// ⚠️ 迁移契约：`unclassified` 的 rawValue **必须是空串 ""**。Segment.sourceRaw 的默认列值
/// 就是 ""——空串是一个合法枚举值，不是脏数据。把它改成别的（如 "unclassified"）或把未知
/// raw 解析成 curated，都会让全部存量分镜在升级后静默变成「搬运」。SegmentSourceTests S4 钉着。
public enum SegmentSource: String, CaseIterable, Sendable, Identifiable {
    case selfShot = "self_shot"
    case curated
    case aiGenerated = "ai_generated"
    case unclassified = ""

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .selfShot: return "自拍"
        case .curated: return "搬运"
        case .aiGenerated: return "AI生产"
        case .unclassified: return "未分类"
        }
    }

    /// 从持久化 raw 构造；未知值与空值都安全回退到「未分类」，绝不 fatalError。
    public init(persisted raw: String) {
        self = SegmentSource(rawValue: raw) ?? .unclassified
    }
}
