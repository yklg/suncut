import Foundation

/// 方案序列的**连贯性校验**（纯函数，可单测）—— 只装事实层面就错了的那几条。
///
/// 为什么必须有：`generateNarrativeVariants` 的 prompt 里写着"对每个变体做台词连贯性自检，
/// 只输出连贯的"，而程序侧只跑 `isValidVariant` —— 它判的是**结构**（条数、不重复、每条来自
/// 自己那一段的候选）。也就是说：模型说"我自检过了"就没人再查，用户看到的"排完不像一条口播"
/// 恰恰落在这道缝里。本文件把其中**可以不依赖模型自觉、用事实就能判**的那几条变成程序判据。
///
/// 与既有契约的关系：入参形状与 `NarrativeStructureEngine.isValidVariant(_:pools:)` 完全一致
/// （同一份 `pools`、同一串 id），所以它是**加进同一条流水线**的一道门，不是另一套校验。
public struct ContinuityConfig: Equatable, Sendable {

    /// 重叠容忍：同素材两段区间相交超过这么多秒才算画面重复（留一点浮点/帧化余量）。
    public var overlapToleranceSeconds: Double

    public init(overlapToleranceSeconds: Double = 0.1) {
        self.overlapToleranceSeconds = overlapToleranceSeconds
    }

    public static let `default` = ContinuityConfig()
}

/// 一条连贯性问题。**这里只允许装"事实层面就错了"的判据** —— 两条都不依赖"多少秒算跳"
/// 这类拍脑袋的线，所以也都不需要模型意见。
///
/// 曾经有第三条 `sourceJump`（同素材相邻两段之间跳掉一截原片内容，阈值 3s），已**删除**：
/// 真机跑一批方案生成拿到 62 条该告警，跳空中位数 **26.6s**、最大 **87.0s** —— 混剪本来就是
/// 从一条素材里挑着用的，"跳"是这门手艺的常态而不是缺陷。一条把绝大多数正常产出都点名的规则
/// 没有信息量，留着只会让人学会无视日志（详见计划 §AB）。
public enum ContinuityIssue: Equatable, Sendable {

    /// 同一素材里，**后说的话被排在先说的话之前**（原始时间顺序倒了）。
    case invertedOrder(pairIndex: Int, sourceKey: String)
    /// 同一素材的两段画面区间相交 ⇒ 同一画面播两遍。
    case overlappingFrames(pairIndex: Int, sourceKey: String, seconds: Double)

    /// 给用户看的相邻对位置（内部下标从 0 起，人数的从 1 起 —— 别让 `pairIndex: 0` 出现在日志里）。
    public var pairIndexLabel: Int {
        switch self {
        case .invertedOrder(let pairIndex, _), .overlappingFrames(let pairIndex, _, _):
            return pairIndex + 1
        }
    }

    /// 给人看的一句话（进日志；措辞只说观测到的事实）。
    public func describe() -> String {
        let pairPosition = pairIndexLabel
        switch self {
        case .invertedOrder:
            return "第 \(pairPosition)-\(pairPosition + 1) 条来自同一素材，但台词的原始先后被排反"
        case .overlappingFrames(_, let key, let seconds):
            return String(format: "第 %d-%d 条画面重叠 %.1fs（同一素材 %@ 的同一段会播两遍）",
                          pairPosition, pairPosition + 1, seconds, key)
        }
    }
}

public enum NarrativeContinuity {

    /// 一个变体的连贯性问题清单，按相邻对逐个判。
    ///
    /// 只判**同素材**的相邻对：跨素材拼接必然换画面，没有客观的"连续"可言，
    /// 拿它当判据就是凭感觉拦人。
    public static func issues(_ segmentIDs: [UUID], pools: [[SegmentDescriptor]],
                              in cfg: ContinuityConfig = .default) -> [ContinuityIssue] {
        let picked = segmentIDs.compactMap { id in
            pools.lazy.flatMap { $0 }.first { $0.id == id }
        }
        guard picked.count == segmentIDs.count else {
            // 有 id 在候选里找不到 ⇒ 结构层已经会拒（isValidVariant），这里不重复判
            return []
        }
        return issues(inOrder: picked, in: cfg)
    }

    /// 直接吃"已按成片顺序排好的分镜" —— 批量组合那条路（模型直接给一条序列）用它。
    /// 两条路共用**同一份**判据实现，不各写一遍（否则阈值一改就分家）。
    public static func issues(inOrder picked: [SegmentDescriptor],
                              in cfg: ContinuityConfig = .default) -> [ContinuityIssue] {
        var found: [ContinuityIssue] = []
        // 少于两条没有"相邻对"可言。这里必须显式挡：`0..<(count - 1)` 在 count == 0 时
        // 会算出 `0..<(-1)` 直接 fatal error（实测：空序列一条就把进程打崩）。
        guard picked.count >= 2 else { return found }
        for pair in 0..<(picked.count - 1) {
            let a = picked[pair], b = picked[pair + 1]
            guard a.sourceKey == b.sourceKey else { continue }
            let aEnd = a.startSeconds + a.duration
            if b.startSeconds < a.startSeconds {
                found.append(.invertedOrder(pairIndex: pair, sourceKey: a.sourceKey))
            }
            // 区间求交，不是"前一条的末尾减后一条的开头"：后者在 b 整段早于 a 时会
            // 算出一个假重叠（实测把 10-14s 与 4-8s 判成重叠 10s）。
            let bEnd = b.startSeconds + b.duration
            let overlap = min(aEnd, bEnd) - max(a.startSeconds, b.startSeconds)
            if overlap > cfg.overlapToleranceSeconds {
                found.append(.overlappingFrames(pairIndex: pair, sourceKey: a.sourceKey,
                                                seconds: overlap))
            }
        }
        return found
    }
}
