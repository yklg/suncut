// MixCut/Models/SegmentDub.swift
import Foundation
import SwiftData

/// 某分镜的一个配音变体（= 分镜 × 改写版 × 音色）。一个 Segment 挂多个 = 变体池。
@Model
final class SegmentDub {
    @Attribute(.unique) var id: UUID
    var segment: Segment?
    var voiceId: String = ""
    var voiceProvider: String = "qwen"
    var textVariantIndex: Int = 0          // 第几个改写版（0..K-1）
    var rewrittenText: String = ""         // 同 textVariantIndex 的各音色行共享同文本
    var audioFilePath: String?             // 按需生成；初始 nil
    var audioDuration: Double = 0
    var atempoFactor: Double = 1.0
    var freezePadFrames: Int = 0
    var trailingSilence: Double = 0

    // 失效追踪（DubStaleness 生成那一刻快照）
    var generatedForStartFrame: Int = -1
    var generatedForEndFrame: Int = -1
    var generatedForTextHash: String = ""
    /// 配音生成那一刻，**分镜原台词**（`Segment.text`）的哈希。
    /// 改写版没动但原台词被重听/搬字换掉了，这条配音也已经对不上画面里的话 —— 以前只追踪改写版，
    /// 那种失效是无声的。默认 `""` = 旧数据（无从判起，不报 stale，只报"未记录"）。
    /// ⚠️ 注意 `generatedForStartFrame/EndFrame` 另兼**时长**职责（`MCPSegmentToolHandlers.swift:375` 用它俩算时长），
    ///    本轮只加这一个 hash 字段，不动那两字段的语义。
    var generatedForSourceTextHash: String = ""

    var statusRaw: String = "pending"      // SegmentDubStatus.rawValue

    /// 是否参与导出组合（默认不参与，opt-in；勾选后才进方案笛卡尔积/单批量导出）
    var participatesInCombination: Bool = false

    /// 逐句字幕行（含每句相对分镜起点的时间窗）。配音(重)生成后由 whisper 对齐自动写入；nil/空=尚未对齐。
    var captionLinesData: Data?

    // MARK: 产品脚本成片（v3.4）
    /// 配音文案的来源：TranscriptSource raw（aiRewrite/productScript/userScriptReverse…）。
    /// 默认 "" = 存量数据（不猜测、不报 stale）；经唯一写入口 `setProvenance` 赋值。
    var textProvenanceRaw: String = ""
    /// 文案引用的资料出处 [CitationDescriptor]（含出处快照）。
    var citationsData: Data?

    /// 文案来源（nil = 存量未记录）。
    var textProvenance: TranscriptSource? {
        textProvenanceRaw.isEmpty ? nil : TranscriptSource(rawValue: textProvenanceRaw)
    }

    /// 唯一写入口：只允许设置一次（脚本配音落库时由 ScriptSceneDubBuilder 调用）。
    func setProvenance(_ source: TranscriptSource) {
        guard textProvenanceRaw.isEmpty else { return }
        textProvenanceRaw = source.rawValue
    }

    /// 引用出处读写。
    var citations: [CitationDescriptor] {
        get {
            guard let d = citationsData else { return [] }
            return (try? JSONDecoder().decode([CitationDescriptor].self, from: d)) ?? []
        }
        set { citationsData = try? JSONEncoder().encode(newValue) }
    }

    var status: SegmentDubStatus {
        get { SegmentDubStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// [CaptionLine] 读写（Data?+JSON，与 keywords/asrWords 同款；CaptionLine 为 MixCutCore 同模块类型，无需 import）
    var captionLines: [CaptionLine] {
        get {
            guard let d = captionLinesData else { return [] }
            return (try? JSONDecoder().decode([CaptionLine].self, from: d)) ?? []
        }
        set { captionLinesData = try? JSONEncoder().encode(newValue) }
    }

    init(segment: Segment?, voiceId: String, voiceProvider: String = "qwen",
         textVariantIndex: Int, rewrittenText: String = "") {
        self.id = UUID()
        self.segment = segment
        self.voiceId = voiceId
        self.voiceProvider = voiceProvider
        self.textVariantIndex = textVariantIndex
        self.rewrittenText = rewrittenText
    }
}

extension Segment {
    /// 导出/组合用的有效配音变体：仅取已生成音频者，并按 textVariantIndex 去重
    /// （同一改写版若有多个音色，优先保留本视频「克隆原声」那条）。clone-only 下每版唯一。
    /// 升序返回，供 _A/_B… 命名与笛卡尔积组合使用。
    var effectiveDubVariants: [SegmentDub] {
        // ⚠️ M2：**段级克隆音色优先**，回落到视频级（存量库兼容）。
        // 旧实现只读 `video?.clonedVoiceId` ⇒ 同一视频里跨说话人的分镜会把
        // A 段的音色当成"本视频克隆声"参与去重，把 B 段的变体误判成重复。
        // 回落链：segment.clonedVoiceId → video.clonedVoiceId（存量） → nil
        effectiveDubVariants(preferredVoiceID: nil,
                             videoCloneVoiceID: clonedVoiceId ?? video?.clonedVoiceId)
    }

    /// M1b R3 口径：同改写版多音色并存时，按「当前解析音色 ＞ 本视频克隆 ＞ 先到先得」去重。
    /// 判据在 Core DubVariantSelector；本方法只做模型→纯值投影与 id 回映。
    /// - 无参旧口径保持等价（preferred=nil → 克隆＞先到），导出/MCP/DebugSelfTest 零行为变化。
    func effectiveDubVariants(preferredVoiceID: String?,
                              videoCloneVoiceID: String?) -> [SegmentDub] {
        let values = segmentDubs.map {
            DubVariantValue(dubID: $0.id,
                            variantIndex: $0.textVariantIndex,
                            voiceID: $0.voiceId,
                            hasAudio: $0.audioFilePath != nil)
        }
        let winners = DubVariantSelector.effective(
            variants: values,
            preferredVoiceID: preferredVoiceID,
            videoCloneVoiceID: videoCloneVoiceID)
        let dubByID = Dictionary(segmentDubs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return winners.compactMap { dubByID[$0.dubID] }
    }

    /// 参与导出组合的变体（= effectiveDubVariants 里勾选了"参与"的）。所有导出路径的单一真源。
    var combinationDubVariants: [SegmentDub] {
        effectiveDubVariants.filter { $0.participatesInCombination }
    }

    /// 该分镜参与组合的"档数"（含锁定/兜底语义）。用于组合计数展示与笛卡尔积基数。
    var combinationSlotCount: Int {
        if isVoiceLocked { return 1 }
        let base = originalParticipatesInCombination ? 1 : 0
        return max(1, base + combinationDubVariants.count)   // 兜底 ≥1（回退仅原版）
    }
}
