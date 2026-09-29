import Foundation

/// 配音失效原因枚举。
/// 当分镜边界或改写台词在配音生成之后被修改，对应配音即视为「stale（过期）」。
public enum StalenessReason: Equatable, Sendable {
    /// 起始帧变化：当前与生成时不一致
    case startFrameChanged(current: Int, recorded: Int)
    /// 结束帧变化：当前与生成时不一致
    case endFrameChanged(current: Int, recorded: Int)
    /// 改写台词哈希变化：当前与生成时不一致
    case textHashChanged(current: String, recorded: String)
    /// **原台词**（`Segment.text`）哈希变化：配音生成之后被逐段重听或手改换掉了来源句子。
    /// 与 `textHashChanged` 是两条独立维度 —— 改写版没动、原台词却变了，正是重提取覆盖的现场。
    case sourceTextChanged(current: String, recorded: String)
}

/// 失效原因的人话版。**放在这里而不是各界面各写一遍**：
/// 计划 §6 的判据是"原台词变了"必须能和"改写版变了"分辨出来（用户据此决定是重听台词还是只重配），
/// 措辞散在两个消费点里，第三个消费点就会说出第三种话。
public extension StalenessReason {
    var userText: String {
        switch self {
        case .startFrameChanged: return "分镜起始帧变了"
        case .endFrameChanged:   return "分镜结束帧变了"
        case .textHashChanged:   return "改写版台词变了"
        case .sourceTextChanged: return "原台词变了"
        }
    }
}

/// 配音失效判定的输入快照（供 `DubStaleness.check` 使用）。
public struct DubSnapshot: Equatable, Sendable {
    /// 生成配音时记录的分镜起始帧
    public let recordedStartFrame: Int
    /// 生成配音时记录的分镜结束帧
    public let recordedEndFrame: Int
    /// 生成配音时记录的改写台词哈希
    public let recordedTextHash: String
    /// 生成配音时记录的**原台词**哈希。空串 = 旧数据未记录 ⇒ 该维度不判（无从判起不编结论）。
    /// 带默认值是为了让既有构造点与既有测试不改一行就能编译（否则加维度会扩散成重构）。
    public let recordedSourceTextHash: String

    public init(recordedStartFrame: Int, recordedEndFrame: Int, recordedTextHash: String,
                recordedSourceTextHash: String = "") {
        self.recordedStartFrame = recordedStartFrame
        self.recordedEndFrame = recordedEndFrame
        self.recordedTextHash = recordedTextHash
        self.recordedSourceTextHash = recordedSourceTextHash
    }
}

/// 配音失效判定结果。
public enum CheckResult: Equatable, Sendable {
    /// 配音与当前帧范围/台词一致，无需重生成
    case fresh
    /// 配音过期，附带所有失效原因（至少一条）
    case stale([StalenessReason])
}

/// 纯函数判定层：无副作用、无 SwiftData 依赖。
/// 判定规则：
///  - `recordedStartFrame == -1` 表示配音从未生成（初始默认值），直接报 stale
///  - 任一字段与当前值不一致 → stale，并收集所有失效原因（可多个同时发生）
public enum DubStaleness {

    /// 对配音快照 vs 当前分镜状态做失效检查。
    ///
    /// - Parameters:
    ///   - snapshot: 配音生成时保存的快照（来自 `SegmentDub` 的四个追踪字段）
    ///   - currentStartFrame: 当前分镜起始帧
    ///   - currentEndFrame:   当前分镜结束帧
    ///   - currentTextHash:   当前改写台词的哈希（可用 `textHash(of:)` 计算）
    /// - Returns: `.fresh` 或 `.stale([reasons])`
    public static func check(snapshot: DubSnapshot,
                             currentStartFrame: Int,
                             currentEndFrame: Int,
                             currentTextHash: String) -> CheckResult {
        // 未曾生成（初始默认值 -1）→ 直接 stale
        guard snapshot.recordedStartFrame != -1 else {
            return .stale([
                .startFrameChanged(current: currentStartFrame, recorded: -1)
            ])
        }

        var reasons: [StalenessReason] = []

        if currentStartFrame != snapshot.recordedStartFrame {
            reasons.append(.startFrameChanged(current: currentStartFrame,
                                              recorded: snapshot.recordedStartFrame))
        }
        if currentEndFrame != snapshot.recordedEndFrame {
            reasons.append(.endFrameChanged(current: currentEndFrame,
                                            recorded: snapshot.recordedEndFrame))
        }
        if currentTextHash != snapshot.recordedTextHash {
            reasons.append(.textHashChanged(current: currentTextHash,
                                            recorded: snapshot.recordedTextHash))
        }

        return reasons.isEmpty ? .fresh : .stale(reasons)
    }

    /// 聚合入口：**唯一**该被界面与 MCP 调用的失效检查（计划 §3.3③，v8 P0-2）。
    ///
    /// 为什么要有它：失效维度会变成三条（帧范围、改写版、原台词），若让每个消费点各自去调再自己拼，
    /// 第三处消费点出现时必漏一维 —— 本项目已因"同一规则两处各写一遍"吃过两次亏。
    /// `check` 保留为老维度的实现（既有测试继续测它），新代码请调本函数。
    ///
    /// - Parameters:
    ///   - currentRewrittenTextHash: 当前改写版台词哈希
    ///   - currentSourceTextHash:    当前**原台词**哈希（`Segment.text`）
    public static func checkAll(snapshot: DubSnapshot,
                                currentStartFrame: Int,
                                currentEndFrame: Int,
                                currentRewrittenTextHash: String,
                                currentSourceTextHash: String) -> CheckResult {
        let base = check(snapshot: snapshot,
                         currentStartFrame: currentStartFrame,
                         currentEndFrame: currentEndFrame,
                         currentTextHash: currentRewrittenTextHash)

        // 旧数据没记录原台词哈希 ⇒ 这一维一概不判，宁缺不造
        guard !snapshot.recordedSourceTextHash.isEmpty else { return base }
        guard currentSourceTextHash != snapshot.recordedSourceTextHash else { return base }

        let extra = StalenessReason.sourceTextChanged(current: currentSourceTextHash,
                                                      recorded: snapshot.recordedSourceTextHash)
        switch base {
        case .fresh:
            return .stale([extra])
        case .stale(let reasons):
            return .stale(reasons + [extra])
        }
    }

    /// 计算改写台词的 DJB2 哈希（16 位十六进制），用于廉价比对台词是否变化。
    /// 非密码学用途，仅需"同输入同输出、不同输入大概率不同输出"。
    /// 空串返回固定 `""`，与 `SegmentDub.generatedForTextHash` 的默认值（未配置占位）保持一致。
    public static func textHash(of text: String) -> String {
        guard !text.isEmpty else { return "" }
        // 使用 DJB2 哈希：轻量、无依赖、满足"改写台词变化即哈希变化"的需求。
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
