import Foundation

// ============================================================================
// 分镜网格选择器（中立纯逻辑）—— 产品脚本向导匹配页、未来叙事结构人工选片共用。
//
// 设计契约：
// - 不依赖 SwiftData / 任何 ViewModel：App 层把活模型拍平成 GridPickerSegment 传入；
// - 「标签命中」口径与 ScriptMatcher 同源：分镜标签集合与槽位所求标签集合有交集即命中；
// - 占用判定粒度是**分镜**：同视频的其他分镜不受影响；当前段自己占用不算占用；
// - 统计数与网格数据必须同源（都经 filter），杜绝「筛掉后数字说假话」。
// ============================================================================

/// 选择器里一个分镜的纯值投影（只含展示/筛选必需字段）。
public struct GridPickerSegment: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let videoID: UUID
    public let videoName: String
    /// SegmentSource.rawValue（""=未分类）
    public let sourceRaw: String
    public let duration: Double
    /// 视频内编号（segmentIndex，如 seg_008；跨视频可重名，需与 videoName 同看）
    public let segmentIndex: String
    /// 分镜语义标签 rawValue 集合（如「噱头引入」）
    public let tagNames: [String]
    /// 台词原文（搜索用；纯值拷贝，不 fault 模型）
    public let text: String
    /// 缩略图绝对路径（Segment 自有列/替换画面路径；可能为 nil）
    public let thumbnailPath: String?

    public init(id: UUID,
                videoID: UUID,
                videoName: String,
                sourceRaw: String,
                duration: Double,
                segmentIndex: String,
                tagNames: [String],
                text: String,
                thumbnailPath: String? = nil) {
        self.id = id
        self.videoID = videoID
        self.videoName = videoName
        self.sourceRaw = sourceRaw
        self.duration = duration
        self.segmentIndex = segmentIndex
        self.tagNames = tagNames
        self.text = text
        self.thumbnailPath = thumbnailPath
    }

    /// 台词命中（搜索口径：忽略大小写，子串匹配，与 App 视图一致）。
    public func textHit(_ keyword: String) -> Bool {
        text.localizedCaseInsensitiveContains(keyword)
    }
}

/// 选择器当前筛选状态（纯值）。
public struct GridPickerFilter: Equatable, Sendable {
    /// 台词关键字（空串=不过滤；内部按空白 trim）
    public var searchText: String
    /// 来源 rawValue；nil=全部来源
    public var sourceRaw: String?
    /// 视频 id；nil=全部视频
    public var videoID: UUID?
    /// 当前槽位要求的标签集合（分镜任一命中即可）；空集合=不按标签过滤
    public var requiredTags: Set<String>

    public init(searchText: String = "",
                sourceRaw: String? = nil,
                videoID: UUID? = nil,
                requiredTags: Set<String> = []) {
        self.searchText = searchText
        self.sourceRaw = sourceRaw
        self.videoID = videoID
        self.requiredTags = requiredTags
    }

    /// 规整后的搜索词（空白 trim）。
    public var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 视频分组（用于「视频」筛选 chips 与计数）。
public struct GridPickerVideoGroup: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let count: Int
    public init(id: UUID, name: String, count: Int) {
        self.id = id; self.name = name; self.count = count
    }
}

/// 场景对某分镜的占用声明（VM 用 sceneToSegmentID 快照反查后构造）。
public struct GridPickerClaim: Equatable, Sendable {
    public let sceneID: UUID
    public let sceneOrder: Int
    public let sceneTag: String
    public init(sceneID: UUID, sceneOrder: Int, sceneTag: String) {
        self.sceneID = sceneID; self.sceneOrder = sceneOrder; self.sceneTag = sceneTag
    }
}

/// 一个分镜被其他槽位占用的信息（当前槽自己的占用不产生条目）。
public struct GridPickerOccupancy: Equatable, Sendable {
    public let segmentID: UUID
    /// 占用该分镜的场景序号（1 起，展示「第 N 段」）
    public let sceneOrder: Int
    public let sceneTag: String
    public init(segmentID: UUID, sceneOrder: Int, sceneTag: String) {
        self.segmentID = segmentID; self.sceneOrder = sceneOrder; self.sceneTag = sceneTag
    }
}

public enum SegmentGridPicker {

    /// 四维交集过滤：搜索 ∩ 来源 ∩ 视频 ∩ 标签。
    /// 各维独立后取交集，顺序无关（交换/结合律成立，由 GP-6 守护）。
    public static func filter(_ segments: [GridPickerSegment],
                              _ filter: GridPickerFilter) -> [GridPickerSegment] {
        let keyword = filter.trimmedSearch
        let needTags = filter.requiredTags
        return segments.filter { seg in
            if let src = filter.sourceRaw, seg.sourceRaw != src { return false }
            if let vid = filter.videoID, seg.videoID != vid { return false }
            if !needTags.isEmpty, Set(seg.tagNames).isDisjoint(with: needTags) { return false }
            if !keyword.isEmpty, !seg.textHit(keyword) { return false }
            return true
        }
    }

    /// 仅按标签维过滤的计数（供「标签匹配 Y 个」统计；与搜索/来源/视频选择独立）。
    /// 必须与 filter 的标签子句同口径（GP-7 钉死，防止数字与网格不一致）。
    public static func tagMatchedCount(_ segments: [GridPickerSegment], requiredTags: Set<String>) -> Int {
        guard !requiredTags.isEmpty else { return segments.count }
        return segments.count { !Set($0.tagNames).isDisjoint(with: requiredTags) }
    }

    /// 按视频聚合计数（顺序按视频首次出现顺序，稳定；同视频多分镜全部计数）。
    public static func videoGroups(_ segments: [GridPickerSegment]) -> [GridPickerVideoGroup] {
        var order: [UUID] = []
        var nameByID: [UUID: String] = [:]
        var countByID: [UUID: Int] = [:]
        for seg in segments {
            if countByID[seg.videoID] == nil { order.append(seg.videoID) }
            nameByID[seg.videoID] = seg.videoName
            countByID[seg.videoID, default: 0] += 1
        }
        return order.map {
            GridPickerVideoGroup(id: $0, name: nameByID[$0] ?? "未知视频", count: countByID[$0] ?? 0)
        }
    }

    /// 计算占用映射。
    /// - Parameters:
    ///   - claimed: 分镜 id → 占用它的场景（场景顺序 + 标签）；一个分镜在向导内至多被一个场景选中。
    ///   - currentSlotSceneID: 当前正在挑选的场景 id——其占用豁免（不算被占）。
    /// - Returns: 除当前场景外的占用信息（segmentID → 第 N 段），按 segmentID 稳定排序。
    public static func occupancy(claimed: [UUID: GridPickerClaim],
                                 currentSlotSceneID: UUID?) -> [GridPickerOccupancy] {
        claimed.compactMap { segmentID, claim in
            if claim.sceneID == currentSlotSceneID { return nil }
            return GridPickerOccupancy(segmentID: segmentID,
                                       sceneOrder: claim.sceneOrder,
                                       sceneTag: claim.sceneTag)
        }
        .sorted { $0.segmentID.uuidString < $1.segmentID.uuidString }
    }
}
