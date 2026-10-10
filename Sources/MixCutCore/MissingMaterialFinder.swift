import Foundation

/// 「库里有记录、磁盘上却没有文件」的对账（`OrphanFileFinder` 的**反向孪生**）。
///
/// 两条轴的不对称必须写在脸上：orphan 问的是「磁盘有、库里无 ⇒ 可以删文件」，
/// 本类型问的是「库里有、磁盘无 ⇒ 只能不再显示」。
/// **本文件永不产出任何删除动作** —— 它的唯一输出是一组 id，供上层做投影过滤；
/// 真删记录是另一条链（视频删除咽喉）的事，由用户显式发起。
///
/// 为什么这条轴此前不存在：`Video.localPath`（App 侧）只是一根裸 String，语义是"某处有个文件"，
/// 模型层没有任何地方表达"这根路径当前指向一个真实文件"。于是每个用文件的地方只能
/// 在用之前自己 stat 一次、各自决定给什么提示。判定收在这里，是为了让它只有一个答案、
/// 并且能被 `swift test` 打到。
///
/// 方向性代价（决定所有降级档的取舍）：**藏一张好卡**与**多显示一张死卡**不是同一种错。
/// 多显示最坏是"点了播不了"；误藏则会让用户以为素材没了。所以判据不确定时一律偏向多显示，
/// 并且"我查不了"必须报成"查不了"，不许伪装成"没丢"，也不许伪装成"丢了"。
public enum MaterialProbeReading: Equatable, Sendable {
    /// 在，且读得动
    case present
    /// 明确不在（ENOENT 那一类）
    case absent
    /// 文件在但读不动（无权限 / 卷半挂载 / I/O 出错）—— **不等于不存在**
    case unreadable
}

/// 一条待对账的记录：id + 路径。全是值类型，可以安全地递出主 Actor 去 stat。
public struct MaterialRecordPath: Sendable, Hashable {
    public let id: UUID
    public let path: String

    public init(id: UUID, path: String) {
        self.id = id
        self.path = path
    }
}

/// 一次对账的读数。
public struct MissingScanResult: Equatable, Sendable {
    /// 落在可信前缀内、且探针明确报"不存在"的记录
    public let missingIDs: Set<UUID>
    /// 路径不在当前素材真源目录下 ⇒ **不参与判定**的条数（品牌迁移未完成 / 旧前缀未改写的现场）
    public let excludedRecords: Int
    /// 在可信前缀内但读不动的条数（第三态，既不判在也不判缺）
    public let unreadableRecords: Int
    /// true = 判据本身不可信 ⇒ `missingIDs` 保证为空，调用方**必须**把原因上屏
    public let degraded: Bool
    public let degradationReason: String?

    public init(missingIDs: Set<UUID> = [], excludedRecords: Int = 0,
                unreadableRecords: Int = 0, degraded: Bool = false,
                degradationReason: String? = nil) {
        self.missingIDs = missingIDs
        self.excludedRecords = excludedRecords
        self.unreadableRecords = unreadableRecords
        self.degraded = degraded
        self.degradationReason = degradationReason
    }

    static func degradedOnly(_ reason: String) -> MissingScanResult {
        MissingScanResult(degraded: true, degradationReason: reason)
    }
}

public enum MissingMaterialFinder {

    /// 归一化**复用 orphan 那一颗**（大小写 + 末尾斜杠，APFS 默认大小写不敏感）。
    /// 两条轴若各写一套归一，同一个文件在两侧会被认成两个 —— 那正是 GC 误删的形状。
    static func normalize(_ path: String) -> String { OrphanFileFinder.normalize(path) }

    /// `path` 是否落在某个可信前缀之下（目录边界必须算：`/Videos2` 不算在 `/Videos` 里）。
    static func isUnderTrustedPrefix(_ path: String, _ prefixes: [String]) -> Bool {
        let p = normalize(path)
        return prefixes.contains { prefix in
            let q = normalize(prefix)
            guard !q.isEmpty, p.hasPrefix(q) else { return false }
            return p.count == q.count || p[p.index(p.startIndex, offsetBy: q.count)] == "/"
        }
    }

    /// 纯查询：把「存在性读数」映射成「哪些记录没有文件」。
    /// - Parameter probe: 由调用方注入的 I/O 探针（App 侧走 FileManager，测试用假函数）。
    ///   本函数不碰文件系统 —— 这是它能进 `swift test` 的全部前提。
    public static func missingIDs(
        records: [MaterialRecordPath],
        probe: (String) -> MaterialProbeReading,
        trustedPrefixes: [String]
    ) -> MissingScanResult {
        guard !records.isEmpty else { return MissingScanResult() }   // 「库里没素材」不是「不知道」

        var missing: Set<UUID> = []
        var excluded = 0
        var unreadable = 0
        var judgeable = 0
        for record in records {
            guard !record.path.isEmpty else {
                excluded += 1        // 空路径是数据问题，不是"文件没了"
                continue
            }
            guard isUnderTrustedPrefix(record.path, trustedPrefixes) else {
                excluded += 1
                continue
            }
            judgeable += 1
            switch probe(record.path) {
            case .present: break
            case .absent:  missing.insert(record.id)
            case .unreadable: unreadable += 1
            }
        }

        // 一条都没落在可信目录下 ⇒ 库与盘没有共同坐标（迁移未完成 / 前缀未改写），
        // 这时"全都不存在"这种读数是判据自己坏了，不是用户的文件没了。
        if judgeable == 0 {
            return .degradedOnly("库里 \(records.count) 条素材路径没有一条落在当前素材真源目录下，"
                                 + "无法判断文件是否还在（目录迁移或路径改写可能未完成）")
        }
        // 全部读不动 ⇒ 同样是判据不可信，而不是"全丢了"
        if missing.isEmpty && unreadable == judgeable {
            return .degradedOnly("可判定的 \(judgeable) 条素材全部读不动（权限或卷未就绪），"
                                 + "本轮不判缺失")
        }
        return MissingScanResult(missingIDs: missing, excludedRecords: excluded,
                                 unreadableRecords: unreadable)
    }

    /// 保守入口：证据不可信 ⇒ 一个 id 都不给，并说明为什么。
    ///
    /// ⚠️ 这里**刻意不照抄** `safeOrphanFiles` 的「零交集 ⇒ 不可信」的字面镜像 ——
    /// 它的镜像是「全部记录都查不到 ⇒ 不可信」，而那恰好在真实事故现场（用户把该目录下的
    /// 视频整个删了）失效，会让这个功能在最需要它的时候一声不响。所以不可信信号只取自**结构**：
    /// 素材根目录本身在不在（`videoRootPresent`）、记录与真源前缀有没有共同坐标（`missingIDs` 里判）。
    public static func safeMissingIDs(
        records: [MaterialRecordPath],
        probe: (String) -> MaterialProbeReading,
        trustedPrefixes: [String],
        videoRootPresent: Bool
    ) -> MissingScanResult {
        guard !records.isEmpty else { return MissingScanResult() }
        guard videoRootPresent else {
            return .degradedOnly("素材根目录本身不在磁盘上（外置卷未挂载或数据目录被移走），"
                                 + "本轮不判缺失")
        }
        return missingIDs(records: records, probe: probe, trustedPrefixes: trustedPrefixes)
    }
}
