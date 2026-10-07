import Foundation
import SwiftData

/// 方案-分镜关联（有序）
@Model
final class SchemeSegment: Identifiable {
    @Attribute(.unique) var id: UUID
    var position: Int           // 在方案中的排列顺序（从 1 开始）
    var reasoning: String?      // AI 选择此分镜的理由
    var positionReasoning: String?  // 为什么放在这个位置

    var scheme: MixScheme?
    var segment: Segment?

    /// 该槽选定的配音变体 SegmentDub.id；nil = 原声/锁定（P5）
    var selectedSegmentDubId: UUID?

    /// M1b：脚本成片段级音色覆盖（VoiceChoiceCoder 串）。
    /// nil/坏串 = 跟随方案级解析（项目覆盖 → 全局默认）；仅作用于此后新生成，
    /// 旧音频保留，DubVariantSelector.isStale 负责提示「点生成后按新音色合成」。
    /// 带默认值轻量迁移；keepOriginal 普通方案不使用此字段。
    var preferredVoiceChoiceRaw: String?

    init(position: Int, reasoning: String? = nil, positionReasoning: String? = nil) {
        self.id = UUID()
        self.position = position
        self.reasoning = reasoning
        self.positionReasoning = positionReasoning
    }
}
