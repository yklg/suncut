import Foundation

/// 脚本槽位 → 分镜匹配器（纯逻辑，可单测）。
///
/// 匹配契约（v3.4 · M3）：
/// - 输入：脚本槽位（标签 + 目标时长）与候选分镜（语义标签集 + 真实时长）；
/// - **标签过滤**：候选分镜的语义标签集必须包含槽位标签；
/// - **时长过滤**：候选时长落在目标时长 ±15% 区间（对应配音 atempo 安全区 0.5–2.0 的收口，
///   ±15% 内基本无需变速；见 SpeechDuration）；
/// - 同一分镜被两个及以上槽位同时命中 ⇒ 报 **冲突**（不允许成片里同一镜头出现两次）；
/// - 同分按 id 稳定排序（检索/匹配结果必须可复跑）。
public enum ScriptMatcher {

    /// 待匹配槽位（由 ScriptScene 投影）。
    public struct Slot: Equatable, Sendable {
        public let id: UUID
        public let order: Int
        public let tag: String
        public let targetDuration: Double

        public init(id: UUID, order: Int, tag: String, targetDuration: Double) {
            self.id = id
            self.order = order
            self.tag = tag
            self.targetDuration = targetDuration
        }

        /// 时长窗口 [min, max]；目标时长 ≤ 0 时窗口不存在（只按标签匹配）。
        public var durationWindow: ClosedRange<Double>? {
            guard targetDuration > 0 else { return nil }
            return targetDuration * 0.85 ... targetDuration * 1.15
        }
    }

    /// 候选分镜（由 Segment 投影）。
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let tags: [String]
        public let duration: Double

        public init(id: UUID, tags: [String], duration: Double) {
            self.id = id
            self.tags = tags
            self.duration = duration
        }
    }

    /// 单个槽位的匹配结论。
    public enum Result: Equatable, Sendable {
        /// 唯一锁定
        case matched(segmentID: UUID)
        /// 多个候选（segmentIDs 按评分降序、同分 id 升序，供用户手工选）
        case multiCandidate(segmentIDs: [UUID])
        /// 无候选（可改标签/时长，或手工选片）
        case unmatched
    }

    /// 一个冲突：同一分镜被多个槽位同时命中。
    public struct Conflict: Equatable, Sendable {
        public let segmentID: UUID
        public let slotIDs: [UUID]
    }

    public struct Outcome: Equatable, Sendable {
        /// 顺序与入参 slots 一致。
        public let results: [Result]
        public let conflicts: [Conflict]

        public var allMatched: Bool {
            results.allSatisfy {
                if case .matched = $0 { return true }
                return false
            }
        }
    }

    /// 主入口。
    public static func match(slots: [Slot], candidates: [Candidate]) -> Outcome {
        // 1) 逐槽列出命中候选（标签 + 时长窗口），评分 = 时长偏离度（越小越好）。
        var options: [UUID: [UUID]] = [:]   // slotID → 排序后的候选 id
        for slot in slots {
            let hits = candidates
                .filter { $0.tags.contains(slot.tag) }
                .filter { candidate in
                    guard let window = slot.durationWindow else { return true }
                    return window.contains(candidate.duration)
                }
            options[slot.id] = rank(hits, target: slot.targetDuration)
        }

        // 2) 贪心分配：候选越少的槽位越先占（最受限优先），保证「唯一锁定」优先于多候选被占。
        let processed = slots.sorted { lhs, rhs in
            let lc = options[lhs.id]?.count ?? 0
            let rc = options[rhs.id]?.count ?? 0
            if lc != rc { return lc < rc }
            return lhs.order < rhs.order
        }

        var claimedBy: [UUID: [UUID]] = [:]   // segmentID → 已声明的槽位
        var finalBySlot: [UUID: Result] = [:]

        for slot in processed {
            let ranked = options[slot.id] ?? []
            // 该槽在「未被它槽声明」的候选里取最优。
            let free = ranked.filter { segmentID in
                claimedBy[segmentID] == nil
            }
            guard let best = free.first else {
                // 全部候选已被其他槽位声明：保持候选可见但标记冲突（multiCandidate），无候选则 unmatched。
                finalBySlot[slot.id] = ranked.isEmpty ? .unmatched : .multiCandidate(segmentIDs: ranked)
                for segmentID in ranked {
                    claimedBy[segmentID] = (claimedBy[segmentID] ?? []) + [slot.id]
                }
                continue
            }
            claimedBy[best] = (claimedBy[best] ?? []) + [slot.id]
            // 唯一名单中只有一个候选 → matched；否则 multiCandidate 但首选已声明。
            finalBySlot[slot.id] = ranked.count == 1
                ? .matched(segmentID: best)
                : .multiCandidate(segmentIDs: ranked)
        }

        // 3) 冲突收口：被 ≥2 个槽位声明的分镜。multiCandidate 槽位若其首选无冲突，升级为 matched。
        var conflicts: [Conflict] = []
        for (segmentID, slotIDs) in claimedBy where slotIDs.count > 1 {
            conflicts.append(Conflict(segmentID: segmentID,
                                      slotIDs: slotIDs.sorted(by: slotOrder(slots))))
        }

        for slot in slots {
            guard case .multiCandidate(let ids) = finalBySlot[slot.id],
                  let first = ids.first else { continue }
            let conflictedSegments = Set(conflicts.map(\.segmentID))
            if !conflictedSegments.contains(first) {
                finalBySlot[slot.id] = .matched(segmentID: first)
            }
        }

        let results = slots.map { finalBySlot[$0.id] ?? .unmatched }
        conflicts.sort {
            $0.segmentID.uuidString < $1.segmentID.uuidString
        }
        return Outcome(results: results, conflicts: conflicts)
    }

    // MARK: - Helpers

    /// 候选评分排序：先按时长偏离度升序，同分按 id 升序（确定性）。
    static func rank(_ hits: [Candidate], target: Double) -> [UUID] {
        hits.sorted { lhs, rhs in
            let dl = deviation(lhs.duration, target: target)
            let dr = deviation(rhs.duration, target: target)
            if dl != dr { return dl < dr }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        .map(\.id)
    }

    /// 时长偏离度（目标 ≤ 0 时全部等价 = 0，交给 id 稳定排序）。
    static func deviation(_ duration: Double, target: Double) -> Double {
        guard target > 0 else { return 0 }
        return abs(duration - target) / target
    }

    static func slotOrder(_ slots: [Slot]) -> (UUID, UUID) -> Bool {
        let orderMap = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.order) })
        return { (orderMap[$0] ?? .max) < (orderMap[$1] ?? .max) }
    }
}
