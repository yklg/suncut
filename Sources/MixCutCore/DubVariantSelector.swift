import Foundation

// ============================================================================
// 有效配音变体选择（R3，纯逻辑）—— 同一改写版（textVariantIndex）存在多个音色的
// 配音时，UI 展示/默认选中「该听哪一条」的唯一判据。
//
// 背景（M1a→M1b）：未克隆视频改用全局预置音色后，同一分镜的同一改写版会先后挂着
// 音色 A、音色 B 两条已生成配音。旧 effectiveDubVariants 的去重是「克隆 dub ＞ 先到先得」，
// 用户把音色 A 切成 B 并生成后，旧 A 配音仍永久压过新 B，界面像没切成功。
//
// 胜出优先级（按 textVariantIndex 分组，组内三选一）：
//   1. voiceID == 当前解析音色（preferredVoiceID）→ 用户当前选择永远胜出；
//   2. voiceID == 本视频克隆声（videoCloneVoiceID）→ 存量克隆行为；
//   3. 先到先得（数组顺序 = 关系枚举顺序，保持旧兜底确定性）。
//
// 规则纯值、不碰 SwiftData；App 模型层负责把 SegmentDub 投影成 DubVariantValue。
// ============================================================================

public struct DubVariantValue: Equatable, Sendable {
    public let dubID: UUID
    public let variantIndex: Int
    public let voiceID: String
    public let hasAudio: Bool

    public init(dubID: UUID, variantIndex: Int, voiceID: String, hasAudio: Bool) {
        self.dubID = dubID
        self.variantIndex = variantIndex
        self.voiceID = voiceID
        self.hasAudio = hasAudio
    }
}

public enum DubVariantSelector {

    /// 从变体池中选出「每个改写版唯一一条」的有效变体，按 variantIndex 升序。
    /// - Parameters:
    ///   - variants: 分镜下全部配音载体的纯值投影（含无音频空壳——本函数负责过滤）。
    ///   - preferredVoiceID: 当前解析出的生效音色 id（UI 场景传 resolvedChoice.voiceID；
    ///     传 nil = 调用方不关心当前音色，回落到克隆/先到，即 M1a 旧行为）。
    ///   - videoCloneVoiceID: 本视频的逐视频克隆声 id（存量克隆优先口径；nil = 未克隆）。
    public static func effective(variants: [DubVariantValue],
                                 preferredVoiceID: String?,
                                 videoCloneVoiceID: String?) -> [DubVariantValue] {
        var winnerByIndex: [Int: DubVariantValue] = [:]
        for candidate in variants where candidate.hasAudio {
            guard let incumbent = winnerByIndex[candidate.variantIndex] else {
                winnerByIndex[candidate.variantIndex] = candidate
                continue
            }
            if rank(candidate, preferredVoiceID: preferredVoiceID,
                    videoCloneVoiceID: videoCloneVoiceID)
                < rank(incumbent, preferredVoiceID: preferredVoiceID,
                       videoCloneVoiceID: videoCloneVoiceID) {
                winnerByIndex[candidate.variantIndex] = candidate
            }
        }
        return winnerByIndex.values.sorted { $0.variantIndex < $1.variantIndex }
    }

    /// 组内胜出排序：数字越小越优先。preferred 0 ＞ clone 1 ＞ 先到 2。
    private static func rank(_ v: DubVariantValue,
                             preferredVoiceID: String?,
                             videoCloneVoiceID: String?) -> Int {
        if let preferredVoiceID, !preferredVoiceID.isEmpty, v.voiceID == preferredVoiceID {
            return 0
        }
        if let videoCloneVoiceID, !videoCloneVoiceID.isEmpty, v.voiceID == videoCloneVoiceID {
            return 1
        }
        return 2
    }

    /// 槽位「已改选音色但音频还是旧音色」判定（staleVoice 态唯一判据）。
    ///
    /// 语义边界：
    /// - 仅在槽位已有绑定音频时才有意义（无音频是 pending/missing，不是 stale）；
    /// - boundVoiceID/resolvedVoiceID 任一为空（nil 或空串）→ 不判 stale（无法比对）；
    /// - 两者非空且不等 → true：提示用户「点生成后按新音色合成」，不自动重生、不自动计费。
    public static func isStale(boundVoiceID: String?, resolvedVoiceID: String?) -> Bool {
        guard let bound = nonEmpty(boundVoiceID), let resolved = nonEmpty(resolvedVoiceID) else {
            return false
        }
        return bound != resolved
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
