import Foundation

// ============================================================================
// 视频批量删除的**作用域判定**（方案 kindled-cloud-robin.md 批 3）
//
// 形状照 `DubRewriteScopeResolver.swift:38-57` 的既有裁定：**宁可 disabled，也不越界**。
// 但这里比配音那一颗多一档：删除是不可逆的，所以"勾选里混进了不属于本项目可见集合的 id"
// 不能像界面过滤那样"只取交集继续干活" —— 那样 Toast 上「已删除 30 个视频」这句话就是说谎
// （用户勾了 30 个，实际只删了能删的那 22 个，剩下 8 个既不报错也不见）。
// ⇒ 整条拒绝 + 把越界的 id 交回调用方点名。
//
// 第二条不变量是从 `SegmentBatchPolicy.tally` 那里搬过来的**计数诚实**（那是本仓批量动作的既有真源）：
// 每个被勾选的 id 必须恰好落进 units / foreign / unresolvable 三个桶之一 —— 漏计就是"总数对不上"，
// 多计就是同一件事被做两遍。
// ============================================================================

/// 一个通过校验、可以进入删除咽喉的候选：视频 id ＋ 它在**本项目**里的关联行 id 集合。
public struct VideoDeletionCandidate: Sendable, Hashable, Equatable {
    public let videoID: UUID
    /// 该视频在本项目里的关联行。同项目同视频两条关联是历史脏形状（崩溃族那批），
    /// 这种视频只该出**一个** unit，但两条 pv 都要收进来 —— 少摘一条就删不掉。
    public let projectVideoIDs: Set<UUID>

    public init(videoID: UUID, projectVideoIDs: Set<UUID>) {
        self.videoID = videoID
        self.projectVideoIDs = projectVideoIDs
    }
}

/// 一次批量删除的作用域读数。
public struct VideoDeletionScope: Sendable, Equatable {
    /// 通过校验的候选，按 videoID 的 `uuidString` 稳定升序（编号与文案都靠它，不能随重绘抖）
    public let units: [VideoDeletionCandidate]
    /// 勾选里不属于本项目可见集合的 id ⇒ 非空即整条拒绝
    public let foreignIDs: Set<UUID>
    /// 在本项目可见、但取不到任何关联行的 id（悬挂关联那一族）：**不许静默丢**，
    /// 丢了就等于「已删除 N 个视频」里少数了几个
    public let unresolvableIDs: Set<UUID>

    public init(units: [VideoDeletionCandidate], foreignIDs: Set<UUID>, unresolvableIDs: Set<UUID>) {
        self.units = units
        self.foreignIDs = foreignIDs
        self.unresolvableIDs = unresolvableIDs
    }

    /// 有越界成员 ⇒ 调用方必须拒绝整批，不许"删我能删的那半"
    public var isRejected: Bool { !foreignIDs.isEmpty }

    /// **删除咽喉唯一准读的这一字段**：一旦有越界成员就恒空。
    ///
    /// 为什么不止步于"返回 isRejected 让调用方自己判"：那样"忘了判就删"仍然是合法代码，
    /// 而它造成的正是本条要防的形状 —— 用户勾 30 个、实删 22 个，剩下 8 个无声消失，
    /// Toast 上「已删除 30 个视频」变成谎话。把闸门做进类型，调用方要越界必须显式去读
    /// 诊断字段 `units`，review 时看得见。
    public var deletableUnits: [VideoDeletionCandidate] { foreignIDs.isEmpty ? units : [] }

    /// 什么都没勾（不是错误，是空操作）
    public var isEmpty: Bool { units.isEmpty && foreignIDs.isEmpty && unresolvableIDs.isEmpty }
}

public enum VideoDeletionScopeResolver {

    /// - Parameters:
    ///   - selectedVideoIDs: 勾选集合（全局视频 id，跨项目长活在 VM 里）。
    ///   - visibleVideoIDs: 本项目**当前可见**的视频 id —— 这就是删除的定义域。
    ///     ⚠️ 定义域必须是"用户看得见的那些"：批 3 的 ⇧ 连选与 ⌘A 都以可见集合为准，
    ///     拿 `project.videos` 当定义域会让隐藏项被删（用户看不见却少了一条素材，是最坏的那种分叉）。
    ///   - associationsByVideo: videoID → 该项目下它的关联行 id 集合（空集或缺键 ⇒ 进 unresolvable）。
    public static func resolve(
        selectedVideoIDs: Set<UUID>,
        visibleVideoIDs: Set<UUID>,
        associationsByVideo: [UUID: Set<UUID>]
    ) -> VideoDeletionScope {
        var foreign: Set<UUID> = []
        var unresolvable: Set<UUID> = []
        var units: [VideoDeletionCandidate] = []
        for videoID in selectedVideoIDs {
            guard visibleVideoIDs.contains(videoID) else {
                foreign.insert(videoID)
                continue
            }
            guard let pvs = associationsByVideo[videoID], !pvs.isEmpty else {
                unresolvable.insert(videoID)
                continue
            }
            units.append(VideoDeletionCandidate(videoID: videoID, projectVideoIDs: pvs))
        }
        units.sort { $0.videoID.uuidString < $1.videoID.uuidString }
        return VideoDeletionScope(units: units, foreignIDs: foreign, unresolvableIDs: unresolvable)
    }
}

/// 二次确认与浮条的**实数**（方案：文案分两档说清，且「本次将真删 B 个分镜记录」要说在前面）。
/// 分档判据取自"该视频是否还被别的项目引用"，取自删除**之前**的快照
/// （`referenceCountBefore` —— 隐藏步骤动的正是 `projectVideos`，事后再问必错）。
public struct VideoDeletionTotals: Sendable, Equatable {
    /// 所有关联都在本项目 ⇒ 连视频与分镜记录一起删
    public let localOnlyCount: Int
    /// 还被其它项目引用 ⇒ 只解除本项目关联，记录保留
    public let stillReferencedCount: Int
    /// 本次会连带删掉的分镜记录数（只算 localOnly 那些 —— 别的项目的分镜一条都不动）
    public let segmentsDeleted: Int
    /// 关联取不到、既删不了也没被算进上面任何一档的条数（必须在文案里说出来，不许默默少掉）
    public let unresolvableCount: Int

    public init(localOnlyCount: Int, stillReferencedCount: Int,
                segmentsDeleted: Int, unresolvableCount: Int) {
        self.localOnlyCount = localOnlyCount
        self.stillReferencedCount = stillReferencedCount
        self.segmentsDeleted = segmentsDeleted
        self.unresolvableCount = unresolvableCount
    }

    /// 一条候选的快照。`associationCountInProject == referenceCountBefore` 即"只被本项目用"。
    public struct Entry: Sendable, Equatable {
        public let referenceCountBefore: Int
        public let associationCountInProject: Int
        /// 本项目侧这条视频拥有的分镜数
        public let segmentCount: Int

        public init(referenceCountBefore: Int, associationCountInProject: Int, segmentCount: Int) {
            self.referenceCountBefore = referenceCountBefore
            self.associationCountInProject = associationCountInProject
            self.segmentCount = segmentCount
        }
    }

    public static func tally(_ entries: [Entry]) -> VideoDeletionTotals {
        var local = 0, other = 0, segments = 0
        for e in entries {
            if e.referenceCountBefore == e.associationCountInProject {
                local += 1
                segments += e.segmentCount
            } else {
                other += 1
            }
        }
        return VideoDeletionTotals(localOnlyCount: local, stillReferencedCount: other,
                                   segmentsDeleted: segments, unresolvableCount: 0)
    }
}
