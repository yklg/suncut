import Foundation

/// 分镜规划的阈值。**默认值即出厂值**，App 层可以用 UserDefaults 覆盖后整体注入
/// （Core 禁 UserDefaults，见 `scripts/check_asr_guards.sh`，所以覆盖必须发生在上游）。
public struct SegmentationPlanConfig: Equatable, Sendable {

    /// 整片保留上限：时长 ≤ 此值**且**句子数 ≤ `wholeVideoMaxSentences` 时，整片就是一条分镜，不调模型。
    ///
    /// 10 秒不是拍的：真实库 165 条素材里，≤8s 会把 25 条压成单段（压后每段中位 3 句、最大 5 句，
    /// 而全库句/段中位本就是 2.0），≤10s 压 42 条但最大压到 8 句 —— 所以下面配了句数预算兜住。
    public var wholeVideoMaxSeconds: Double = 10
    /// 整片保留的句数预算：压完这一段若超过这么多句，就不压（保住字幕/配音的时间粒度）。
    public var wholeVideoMaxSentences: Int = 6

    /// 过碎判据：平均段长低于此值判为"切碎了"，触发确定性合并。
    ///
    /// 取代原先"段数 > 句子数"那条 —— 它在 165 条真实素材上只命中 2 条，等于永不生效。
    /// 也不用"段数 > 镜头数"：那会命中 41%，而其中 40 条是一镜到底的口播，
    /// "在一个镜头里按话切段"正是混剪要的可组合粒度，拿它当合并令箭等于削掉重组能力。
    public var minAverageSegmentSeconds: Double = 3.5

    /// 单段时长上限。**直接引用 `SegmentationCompleteness.promptSegmentLimit`**，
    /// 不在这里另立一个数 —— 18 秒的定义全仓只许有一处（`check_ai_completeness_guards.sh` 钉着）。
    public var segmentSecondsCap: Double = SegmentationCompleteness.promptSegmentLimit

    /// 极短碎片的合并下限。维持历史值 2.0 不变：真实库里 `<2s` 段总数为 0，说明这道兜底本来就在起作用。
    public var minSegmentSeconds: Double = 2.0

    public init() {}
}

/// 规划结果。
public struct SegmentationPlan: Equatable, Sendable {

    /// AI 返回分镜的**下标分组**，每组将产出一条落库分镜，顺序保持原序。
    /// 例：`[[0,1],[2],[3,4]]` = 第 0、1 条并成一段，第 2 条独立，第 3、4 条并成一段。
    public var groups: [[Int]]
    /// 本次实际生效的规则，供留痕与日志使用（谁改写了用户的素材必须说得出名字）。
    public var appliedRules: [SegmentationRule]

    /// 一条规则都没有触发时的形状：每条 AI 分镜原样成段。
    public static func identity(count: Int) -> SegmentationPlan {
        SegmentationPlan(groups: (0..<count).map { [$0] }, appliedRules: [])
    }

    public init(groups: [[Int]], appliedRules: [SegmentationRule] = []) {
        self.groups = groups
        self.appliedRules = appliedRules
    }
}

/// 会改写分镜区间的规则。命名与用户能看到的留痕文案一一对应。
public enum SegmentationRule: String, Equatable, Sendable, CaseIterable {
    /// 短视频整片保留，压根不调模型
    case wholeVideoKept
    /// 平均段长过短 ⇒ 把相邻分镜并回去
    case fragmentedMerged

    /// 给用户看的说法（与 `TranscriptSource.displayLabel` 同一惯例：措辞只说做过的事）。
    public var displayName: String {
        switch self {
        case .wholeVideoKept:    return "整片保留"
        case .fragmentedMerged:  return "过碎合并"
        }
    }
}

/// 分镜规划 —— "什么时候允许下刀"这条规则的唯一归属处。
///
/// 为什么要有这个类型：切点此前由三处各说各话 —— 档位秒数写在 prompt 自然语言里
/// （`AIAnalysisService.buildSegmentationPrompt`）、硬上限是 `SegmentationCompleteness` 的常量、
/// 最短段长硬编码在 App 的调用点。结果任何一条新规则都只能"拿到 AI 结果后改数组"，
/// 也就必然长成一份新拷贝。这里把决策收成一个**纯函数**，App 只负责执行。
public enum SegmentationPlanner {

    /// 整片保留判定。**必须在调用模型之前**问 —— 它的价值就是省下那次付费调用。
    ///
    /// 句子数为 0（无音轨/识别全空）时**不保留**：那不是"短片"，是"没数据"，
    /// 让模型去看总比凭空合成一段诚实。
    public static func shouldKeepWholeVideo(duration: Double,
                                           sentenceCount: Int,
                                           in cfg: SegmentationPlanConfig = SegmentationPlanConfig()) -> Bool {
        guard duration > 0, sentenceCount > 0 else { return false }
        return duration <= cfg.wholeVideoMaxSeconds && sentenceCount <= cfg.wholeVideoMaxSentences
    }

    /// 对 AI 返回的分镜做规划：触发过碎规则时给出合并分组，否则原样。
    ///
    /// 合并是**确定性**的，且绝不回头重调模型 —— 重调会形成"越切越贵"的循环，结果也不可复现。
    ///
    /// 策略是**最小干预**：一组一达到 `minAverageSegmentSeconds` 就收口，不为了凑满
    /// `segmentSecondsCap` 而多并几段。理由是过碎规则只想治"每段太短"，把组凑到上限
    /// 会额外吃掉重组粒度 —— 同一份库能排出的组合数会因此掉下去。
    /// `segmentSecondsCap` 在这里只当**硬护栏**用：攒到装不下就当场切组。
    public static func plan(segments: [SegmentTiming],
                            duration: Double,
                            in cfg: SegmentationPlanConfig = SegmentationPlanConfig()) -> SegmentationPlan {
        let count = segments.count
        guard count > 1 else { return SegmentationPlan.identity(count: count) }

        let lengths = segments.map { max(0, $0.end - $0.start) }
        let average = lengths.reduce(0, +) / Double(count)
        guard average < cfg.minAverageSegmentSeconds else { return SegmentationPlan.identity(count: count) }

        var groups: [[Int]] = []
        var current: [Int] = []
        var currentLength = 0.0
        for i in 0..<count {
            // 已经攒够一段就收尾；下一条塞得进就继续攒
            if !current.isEmpty, currentLength + lengths[i] > cfg.segmentSecondsCap {
                groups.append(current)
                current = []
                currentLength = 0
            }
            current.append(i)
            currentLength += lengths[i]
            if currentLength >= cfg.minAverageSegmentSeconds {
                groups.append(current)
                current = []
                currentLength = 0
            }
        }
        // 收尾那一小撮：太短就并进前一组（前提是不撞上限），否则独立成组
        if !current.isEmpty {
            if currentLength < cfg.minSegmentSeconds, var last = groups.popLast(),
               let head = last.first, let tail = last.last {
                let lastLength = segments[tail].end - segments[head].start
                if lastLength + currentLength <= cfg.segmentSecondsCap {
                    last.append(contentsOf: current)
                    groups.append(last)
                } else {
                    groups.append(last)
                    groups.append(current)
                }
            } else {
                groups.append(current)
            }
        }
        return SegmentationPlan(groups: groups, appliedRules: [.fragmentedMerged])
    }

    /// 分组对应的区间（起点取组内首条、终点取组内末条），供 App 侧执行器落库。
    public static func intervals(of plan: SegmentationPlan,
                                 segments: [SegmentTiming],
                                 duration: Double) -> [(start: Double, end: Double, indices: [Int])] {
        plan.groups.compactMap { group in
            guard let first = group.first, let last = group.last,
                  first < segments.count, last < segments.count else { return nil }
            return (segments[first].start, segments[last].end, group)
        }
        // 末段一路拉到片尾：与落库端的既有约定一致（分区必须铺满全片）
        .enumerated().map { idx, item in
            idx == (plan.groups.count - 1) && duration > 0
                ? (item.start, duration, item.indices)
                : item
        }
    }
}
