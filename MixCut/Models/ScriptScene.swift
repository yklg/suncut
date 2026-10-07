import Foundation
import SwiftData

/// 脚本场景：脚本中一个带标签的段落，materialize 前对应一个待匹配槽位。
///
/// - draft/matched 态可改文案、改匹配；`.materialized` 后随脚本整树冻结；
/// - `matchedSegment`：非 cascade to-one（Segment 被删不带走场景，由广播回退 unmatched）；
/// - `citationChunkIDsData`：本场景引用的 KnowledgeChunk ID 列表（确认阶段使用，materialize 时
///   经 ScriptSceneDubBuilder 搬入 SegmentDub.citationsData）。
@Model
final class ScriptScene: Identifiable {
    @Attribute(.unique) var id: UUID
    var script: ScriptDocument?
    var order: Int
    /// SemanticType.rawValue
    var tag: String
    var text: String
    var targetDuration: Double
    var matchedSegment: Segment?
    /// SceneMatchStatus.rawValue：matched / multiCandidate / unmatched
    var matchStatusRaw: String
    var citationChunkIDsData: Data?

    var matchStatus: SceneMatchStatus {
        get { SceneMatchStatus(rawValue: matchStatusRaw) ?? .unmatched }
        set { matchStatusRaw = newValue.rawValue }
    }

    /// 文本唯一写入口（对齐 `Segment.setText(_:source:)` 的收口纪律：
    /// 外部不裸写 `.text`，G10c 守卫据此判定）。内容没变不写。
    func setText(_ incoming: String) {
        guard incoming != text else { return }
        text = incoming
    }

    /// 引用的 chunk ID 读写。
    var citationChunkIDs: [UUID] {
        get {
            guard let d = citationChunkIDsData else { return [] }
            return (try? JSONDecoder().decode([UUID].self, from: d)) ?? []
        }
        set { citationChunkIDsData = try? JSONEncoder().encode(newValue) }
    }

    init(id: UUID = UUID(),
         script: ScriptDocument?,
         order: Int,
         tag: String,
         text: String = "",
         targetDuration: Double,
         matchStatus: SceneMatchStatus = .unmatched) {
        self.id = id
        self.script = script
        self.order = order
        self.tag = tag
        self.text = text
        self.targetDuration = targetDuration
        self.matchStatusRaw = matchStatus.rawValue
    }
}
