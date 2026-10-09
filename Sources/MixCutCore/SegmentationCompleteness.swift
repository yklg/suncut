import Foundation

/// 一条分镜的**时间与被信任程度**。刻意不含台词文本，判定只需要这些。
public struct SegmentTiming: Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// `qualityScore` 是 AI 真给的，还是代码补出来的默认值？
    public var scoreFromModel: Bool

    public init(start: Double, end: Double, scoreFromModel: Bool = true) {
        self.start = start
        self.end = end
        self.scoreFromModel = scoreFromModel
    }
}

/// 分镜结果完整性审计的输入。
public struct SegmentationAuditInput: Sendable {
    /// 模型自己声明的 `total_segments`。**nil 或 ≤0 一律读作"该字段不可用"** ——
    /// 宽容解码会把缺失项解成 0，而 0 不是"声明了 0 条"，是"没声明"。
    public var declaredSegmentCount: Int?
    /// 全片时长（秒）。用于判断尾段是否吞掉了整片尾部。
    public var videoDuration: Double
    /// 单段时长上限。由调用方注入，核心层不绑定任何 provider/prompt。
    public var maxSegmentSeconds: Double
    public var segments: [SegmentTiming]
    /// 解码时因为"这一条解不出"而被宽容策略整条丢弃的数量。
    /// 丢掉的条目不在 `segments` 里，所以只能以计数形式进来，给不出下标。
    public var skippedUnparsableCount: Int

    public init(declaredSegmentCount: Int?, videoDuration: Double,
                maxSegmentSeconds: Double = SegmentationCompleteness.promptSegmentLimit,
                segments: [SegmentTiming], skippedUnparsableCount: Int = 0) {
        self.declaredSegmentCount = declaredSegmentCount
        self.videoDuration = videoDuration
        self.maxSegmentSeconds = maxSegmentSeconds
        self.segments = segments
        self.skippedUnparsableCount = skippedUnparsableCount
    }
}

public enum CompletenessGap: Equatable, Sendable {
    /// 一条都没收到。与"少几条"是不同档，必须单独成案。
    case noSegments
    /// 实收条数少于模型自报条数 —— 可证明的丢失。
    case countShortfall(declared: Int, received: Int)
    /// 段长越界。`coversTail` = 它是最后一段且贴着片尾（残缺时典型表现：尾段吞掉全片尾部）。
    case segmentTooLong(index: Int, seconds: Double, limit: Double, coversTail: Bool)
    /// 相邻段在时间上重叠（分区不该有交叠）。
    case overlappingSegments(firstIndex: Int, secondIndex: Int, overlapSeconds: Double)
    /// 这些段的 `qualityScore` 是补出来的默认值，不是模型给的。
    case synthesizedQualityScores(indices: [Int])
    /// 有整条段在解码时被跳过（说明上游正文确实残缺过，且丢的内容可信度未知）。
    case skippedUnparsableSegments(count: Int)
}

/// 分镜结果的完整性审计 —— 缺陷 S3（条数缺口）与 S4（补出来的值）的唯一判定处。
///
/// 为什么不能靠"段边界是否覆盖全片"来判截断：落库前 `createSegments` 会强制首段从 0 开始、
/// 尾段到 `videoDuration` 结束、相邻段首尾相接，所以**残缺结果的时间轴看起来 100% 完整**，
/// 代价全压在"最后一段超长"上 —— 故段长上限这条规则是这里唯一不依赖模型诚实度的判据。
public enum SegmentationCompleteness {

    /// 分镜 prompt 自己声明的硬上限（"任何单个片段不得超过 18 秒"）。
    public static let promptSegmentLimit: Double = 18

    /// 浮点噪声容忍：18.0 合规、18.1 违规。
    public static let floatTolerance: Double = 0.005

    public static func audit(_ input: SegmentationAuditInput) -> [CompletenessGap] {
        var gaps: [CompletenessGap] = []
        let segs = input.segments

        guard !segs.isEmpty else { return [.noSegments] }

        // S3：可证明的条数缺口（自报值不可用时不下结论）
        if let declared = input.declaredSegmentCount, declared > 0, declared > segs.count {
            gaps.append(.countShortfall(declared: declared, received: segs.count))
        }

        for (i, seg) in segs.enumerated() {
            let seconds = seg.end - seg.start
            if seconds > input.maxSegmentSeconds + floatTolerance {
                let coversTail = i == segs.count - 1
                    && input.videoDuration > 0
                    && abs(seg.end - input.videoDuration) <= max(0.5, floatTolerance)
                gaps.append(.segmentTooLong(index: i, seconds: seconds,
                                            limit: input.maxSegmentSeconds, coversTail: coversTail))
            }
            if i > 0 {
                let prev = segs[i - 1]
                let overlap = prev.end - seg.start
                if overlap > floatTolerance {
                    gaps.append(.overlappingSegments(firstIndex: i - 1, secondIndex: i,
                                                     overlapSeconds: overlap))
                }
            }
        }

        let synthesized = segs.enumerated().filter { !$0.element.scoreFromModel }.map(\.offset)
        if !synthesized.isEmpty { gaps.append(.synthesizedQualityScores(indices: synthesized)) }

        if input.skippedUnparsableCount > 0 {
            gaps.append(.skippedUnparsableSegments(count: input.skippedUnparsableCount))
        }

        return gaps
    }

    /// 可证不完整：一条没有、实收少于自报、或有整条段被解码器丢弃。
    public static func isProvablyIncomplete(_ gaps: [CompletenessGap]) -> Bool {
        gaps.contains { gap in
            if case .noSegments = gap { return true }
            if case .countShortfall = gap { return true }
            if case .skippedUnparsableSegments = gap { return true }
            return false
        }
    }

    /// 违反应用自己声明的分段规则（不依赖模型诚实度）。
    public static func violatesSegmentationRules(_ gaps: [CompletenessGap]) -> Bool {
        gaps.contains { gap in
            if case .segmentTooLong = gap { return true }
            if case .overlappingSegments = gap { return true }
            return false
        }
    }

    /// "尾段吞掉全片尾部"这一形状是残缺的**特征签名**：
    /// `createSegments` 强制首尾相接并把最后一段拉到片尾，所以一旦少段，超长必然落在最后一段上。
    /// 用它来判失败，比"任何一段超长"更不容易误杀真实存在的长镜头。
    public static func showsTruncationSignature(_ gaps: [CompletenessGap]) -> Bool {
        gaps.contains { gap in
            if case .segmentTooLong(_, _, _, let coversTail) = gap { return coversTail }
            return false
        }
    }

    /// 有值是补出来的 / 有段被丢弃 ⇒ 数据可信度存疑（本轮只标记，不做排除）。
    public static func hasUntrustedFields(_ gaps: [CompletenessGap]) -> Bool {
        gaps.contains { gap in
            if case .synthesizedQualityScores = gap { return true }
            if case .skippedUnparsableSegments = gap { return true }
            return false
        }
    }

    /// 一行结论，供日志与错误消息使用。措辞只说观测到的事实。
    public static func summary(of gaps: [CompletenessGap]) -> String {
        guard !gaps.isEmpty else { return "完整性审计：无缺口" }
        return "完整性审计：" + gaps.map(describe).joined(separator: "; ")
    }

    private static func describe(_ gap: CompletenessGap) -> String {
        switch gap {
        case .noSegments:
            return "一条分镜都没收到"
        case .countShortfall(let declared, let received):
            return "实收 \(received) 条 < 模型自报 \(declared) 条（丢了 \(declared - received) 条）"
        case .segmentTooLong(let index, let seconds, let limit, let coversTail):
            let tail = coversTail ? "，且它是尾段、一路吞到片尾" : ""
            return String(format: "第 %d 段长 %.2fs 超过上限 %.2fs%@", index + 1, seconds, limit, tail)
        case .overlappingSegments(let first, let second, let overlap):
            return String(format: "第 %d/%d 段重叠 %.2fs", first + 1, second + 1, overlap)
        case .synthesizedQualityScores(let indices):
            let list = indices.map { String($0 + 1) }.joined(separator: ",")
            return "第 \(list) 段的质量分是补出来的默认值"
        case .skippedUnparsableSegments(let count):
            return "有 \(count) 条段在解码时解不出、被整条丢弃"
        }
    }
}

/// 落库分区的形状审计 —— 与上面 `audit` 问的是**两个不同的问题**，必须分开：
///
/// * `audit` 问「模型有没有把答应交付的东西交全」，判在**模型原始结果**上；
/// * 这里问「最终要落库的分区是否违反应用自己的规则」，判在**规划层产出之后**。
///
/// 为什么非拆不可：`audit` 里"某段超过 18 秒"同时充当两件事 —— 既是"违反应用规则"，
/// 又是"模型丢段的特征签名"（`createSegments` 强制铺满全片，少段必然表现为尾段超长）。
/// 规划层一旦合并出更长的段，这两种语义就会互相冒充：合并产物被读成"漏交付"，
/// 真漏交付被读成"只是规则违规"。拆开之后，超长度在分区侧只是规则违规，
/// 截断签名只在提案侧成立。
public enum SegmentPartitionAudit {

    /// 一段最终落库区间（秒）。
    public struct Interval: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
        public var seconds: Double { max(0, end - start) }
    }

    public enum Gap: Equatable, Sendable {
        /// 一条都没有。与"形状不对"是不同档，必须单独成案。
        case empty
        case tooLong(index: Int, seconds: Double, limit: Double)
        case overlapping(firstIndex: Int, secondIndex: Int, seconds: Double)
        case holeBetween(firstIndex: Int, secondIndex: Int, seconds: Double)
        case notCoveringHead(startSeconds: Double)
        case notCoveringTail(endSeconds: Double, videoDuration: Double)
    }

    public static func audit(intervals: [Interval],
                            videoDuration: Double,
                            maxSeconds: Double = SegmentationCompleteness.promptSegmentLimit) -> [Gap] {
        let tol = SegmentationCompleteness.floatTolerance
        guard !intervals.isEmpty else { return [.empty] }

        var gaps: [Gap] = []
        for (i, iv) in intervals.enumerated() {
            if iv.seconds > maxSeconds + tol {
                gaps.append(.tooLong(index: i, seconds: iv.seconds, limit: maxSeconds))
            }
            guard i > 0 else { continue }
            let prev = intervals[i - 1]
            let delta = iv.start - prev.end
            if delta < -tol {
                gaps.append(.overlapping(firstIndex: i - 1, secondIndex: i, seconds: -delta))
            } else if delta > tol {
                gaps.append(.holeBetween(firstIndex: i - 1, secondIndex: i, seconds: delta))
            }
        }
        if abs(intervals[0].start) > tol {
            gaps.append(.notCoveringHead(startSeconds: intervals[0].start))
        }
        if videoDuration > 0, abs(intervals[lastIndex(of: intervals)].end - videoDuration) > 0.05 {
            // 0.05 而非 floatTolerance：帧化会把秒边界挪到不足半帧处（真实库实测差 0.0145s）
            gaps.append(.notCoveringTail(endSeconds: intervals[lastIndex(of: intervals)].end,
                                         videoDuration: videoDuration))
        }
        return gaps
    }

    public static func summary(of gaps: [Gap]) -> String {
        guard !gaps.isEmpty else { return "分区审计：形状合规" }
        return "分区审计：" + gaps.map { gap -> String in
            switch gap {
            case .empty: return "一条分镜都没有"
            case .tooLong(let i, let s, let limit):
                return String(format: "第 %d 段 %.2fs 超过应用上限 %.2fs", i + 1, s, limit)
            case .overlapping(let a, let b, let s):
                return String(format: "第 %d/%d 段重叠 %.2fs", a + 1, b + 1, s)
            case .holeBetween(let a, let b, let s):
                return String(format: "第 %d/%d 段之间有 %.2fs 空洞", a + 1, b + 1, s)
            case .notCoveringHead(let s):
                return String(format: "首段没从 0 起（起点 %.2fs）", s)
            case .notCoveringTail(let e, let d):
                return String(format: "尾段没到片长（%.2fs vs %.2fs）", e, d)
            }
        }.joined(separator: "; ")
    }

    private static func lastIndex(of intervals: [Interval]) -> Int { intervals.count - 1 }
}
