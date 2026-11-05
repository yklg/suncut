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

    /// 画面窗口起点的**手改覆盖值**（B 块第 14 条），单位是画面来源自己的帧号。
    ///
    /// nil = 自动：起点就是分镜自己的起点，窗口长度由该槽所选配音的实测时长派生
    /// （`PictureWindowPolicy.derive`，不落库）。只有"人改过"才需要存，所以这颗字段
    /// 存的是**覆盖值而不是派生值** —— 存派生值就等于多一处会与配音长度分叉的真源。
    ///
    /// 只许 ≤ 分镜起点（往前挪多带前摇）。往后挪会让本槽画面盖进下一槽里，
    /// 同一段源画面在成片中连续出现两次 ⇒ 看起来就是卡顿，与已拍死的
    /// "不重复用同一分镜"同族。夹取与理由都在 `PictureWindowPolicy.resolveWindowStart`，
    /// 读侧（导出）与写侧（界面）都走那一颗，不在这里重复判。
    ///
    /// 带默认值属轻量迁移（同 `preferredVoiceChoiceRaw`）；旧库该行读出 nil = 自动，
    /// 与"没人改过"同义，不会冒充成某个具体帧号。
    var windowStartOverrideFrame: Int?

    init(position: Int, reasoning: String? = nil, positionReasoning: String? = nil) {
        self.id = UUID()
        self.position = position
        self.reasoning = reasoning
        self.positionReasoning = positionReasoning
    }
}
