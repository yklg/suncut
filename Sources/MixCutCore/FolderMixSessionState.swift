import Foundation

// ============================================================================
// 文件夹混剪 · 会话状态与空间指纹（纯值类型 + Codable，零 IO）
//
// 计划真源：~/.qoder-cn/plans/northern-slope-widgeon.md B 段（D28 / D31）
//
// ## 为什么编解码住在 Core，而不是 View 里
//
// "什么算一份合法状态、缺了键怎么退、旧版本能不能读"全是**判定**。本仓的门 G-c 就是拦这个：
// 判定长在 View 里 ⇒ `swift test` 一条都覆盖不到。App 层只负责把 JSON 塞进 `UserDefaults`
// （持久化先例：`MixCut/Views/Export/ExportView.swift` 的导出配置四颗 `@AppStorage`）。
//
// ## 迁移铁律：**每个字段都必须容忍缺失**
//
// Swift 的 `Codable` 对**非 Optional** 字段即使给了默认值，缺键时照样 `keyNotFound`
// （本仓实测，见项目记忆「Swift Codable 缺失键只看 Optional」）。而这份状态是要落盘的 ⇒
// 任何一次加字段都会让**旧盘上的那份读不出来**，用户表现为"重开 App 页面回到初始态"，
// 且不会有任何报错 —— 典型的静默回归。
// ⇒ 这里手写 `init(from:)`，全部走 `decodeIfPresent` + 默认值；
//   判据 FMX-12 逐个字段删键验证，不是"看起来写了默认值"就算。
//
// ## `spaceRevision` 是干什么的
//
// 组合序号的含义**绑在候选集的形状上**：重扫一次目录（多了一个文件、或切了"精确识别"），
// 同一个序号会解码成不同的素材搭配。所以指纹一变，已抽出的预览行与"已发出"账本必须作废并
// 明说 —— 否则界面上留着的是"按旧形状抽的组合"，而读数按新形状算，两边都在说谎。
//
// 指纹含：参与类别名（按排列顺序）、每类**去重后**的候选数、每类首末 identityKey、
//        以及「精确识别」开关本身（切开关会改 identityKey 的口径 ⇒ 必然算成一次漂移）。
// 故意**不含**：条数、软上限、预览开关 —— 那些不改变序号的含义，改一下就把预览冲掉是噪声。
// ============================================================================

/// 会话状态。App 层序列化成 JSON 存 `UserDefaults`，字段增减都只动这一个文件。
public struct FolderMixSessionState: Codable, Equatable, Sendable {

    /// 用户选的素材根目录绝对路径。nil = 还没选过。
    public var rootPath: String?
    /// 用户排好的类别顺序（= 拼接顺序，D4）
    public var orderedCategories: [String]
    /// 勾选上的类别（D29）。没在内的不进乘积。
    public var enabledCategories: [String]
    /// 一次出几条
    public var rowCount: Int
    /// 软上限（D24）
    public var softLimit: Int
    /// 「生成前先预览」（D27）
    public var previewFirst: Bool
    /// 「精确识别（慢）」（D31）
    public var preciseIdentity: Bool
    /// 上一次抽片所依据的空间指纹。rehydrate 时**只有它相符**才允许保留预览行。
    public var spaceRevision: String
    /// 预览行的**组合序号**（不是路径、不是素材对象）。
    ///
    /// 为什么存序号而不是存整行：一行 = 「每个参与类别的第几个候选」那一串下标，
    /// 而 `FolderMixComboSpace.decode(index:)` 能从序号把它重建出来 ⇒ 持久面只有 `[Int]`，
    /// 也不会把已经失效的路径/素材对象带到新一轮里（真删后读死对象那一族崩溃的形状）。
    /// Optional：老数据缺这颗键时必须能解出来（本仓实测：非 Optional 即使有默认值也 keyNotFound）。
    public var rowOrdinals: [Int]?

    public init(rootPath: String? = nil,
                orderedCategories: [String] = [],
                enabledCategories: [String] = [],
                rowCount: Int = 1,
                softLimit: Int = FolderMixLimits.defaultSoftLimit,
                previewFirst: Bool = true,
                preciseIdentity: Bool = false,
                spaceRevision: String = "",
                rowOrdinals: [Int]? = nil) {
        self.rootPath = rootPath
        self.orderedCategories = orderedCategories
        self.enabledCategories = enabledCategories
        self.rowCount = rowCount
        self.softLimit = softLimit
        self.previewFirst = previewFirst
        self.preciseIdentity = preciseIdentity
        self.spaceRevision = spaceRevision
        self.rowOrdinals = rowOrdinals
    }

    public static let empty = FolderMixSessionState()

    /// 所有键名（判据 FMX-12 逐个删掉再解一次用）。
    /// 住在 Core 而不是测试里：加字段时这里漏了，判据当场红 —— 而不是等用户重开 App 发现页面被清空。
    public static let allCodingKeys: [String] = [
        "rootPath", "orderedCategories", "enabledCategories", "rowCount",
        "softLimit", "previewFirst", "preciseIdentity", "spaceRevision", "rowOrdinals",
    ]

    private enum CodingKeys: String, CodingKey {
        case rootPath, orderedCategories, enabledCategories, rowCount
        case softLimit, previewFirst, preciseIdentity, spaceRevision, rowOrdinals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 逐颗 decodeIfPresent：任何一颗缺键都退回默认值，**不抛错**。
        rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath)
        orderedCategories = try c.decodeIfPresent([String].self, forKey: .orderedCategories) ?? []
        enabledCategories = try c.decodeIfPresent([String].self, forKey: .enabledCategories) ?? []
        rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount) ?? 1
        softLimit = try c.decodeIfPresent(Int.self, forKey: .softLimit)
            ?? FolderMixLimits.defaultSoftLimit
        previewFirst = try c.decodeIfPresent(Bool.self, forKey: .previewFirst) ?? true
        preciseIdentity = try c.decodeIfPresent(Bool.self, forKey: .preciseIdentity) ?? false
        spaceRevision = try c.decodeIfPresent(String.self, forKey: .spaceRevision) ?? ""
        rowOrdinals = try c.decodeIfPresent([Int].self, forKey: .rowOrdinals)
    }

    /// rehydrate 预览行的唯一入口：**序号只在指纹相符时才可复用**，否则整批作废。
    ///
    /// 为什么必须这样：序号的含义由"参与集 + 每类去重后的候选数 + 顺序"决定。目录内容变了、
    /// 勾了别的类、或切了精确识别开关，同一个序号就指向另一批素材 —— 把旧行留下来，
    /// 界面上的卡片与页脚的「组合总数/剩余」会在两套口径下各自说谎（FMX-13 钉的就是这一格）。
    public func rehydratableOrdinals(nowRevision: String) -> [Int]? {
        guard !spaceRevision.isEmpty, spaceRevision == nowRevision else { return nil }
        return rowOrdinals
    }

    /// 条数钳进输入区间。VM 与界面共用这一颗（钳位口径不许有两份）。
    public var clampedRowCount: Int {
        min(max(rowCount, FolderMixLimits.countInputClamp.lowerBound),
            FolderMixLimits.countInputClamp.upperBound)
    }
}

/// 空间指纹。**只有参与集的形状**进指纹，形状一变即作废。
public enum FolderMixSpaceFingerprint {

    /// - Parameters:
    ///   - space: 当前组合空间（已含"勾选 ∧ 非空"的参与集与类内去重后的 radix）
    ///   - candidatesByCategory: 取首末 identityKey 用（顺序敏感）
    ///   - preciseIdentity: 开关本身进指纹（切它会改 identityKey 口径，见文件头）
    public static func revision(space: FolderMixComboSpace,
                                candidatesByCategory: [String: [FolderMixCandidate]],
                                preciseIdentity: Bool) -> String {
        var parts: [String] = [preciseIdentity ? "precise" : "path"]
        for (slot, category) in space.participants.enumerated() {
            let keys = (candidatesByCategory[category] ?? []).map(\.identityKey)
            let first = keys.first ?? "-"
            let last = keys.count > 1 ? keys[keys.count - 1] : "-"
            let radix = slot < space.radixes.count ? space.radixes[slot] : 0
            parts.append("\(category)#\(radix)#\(first)#\(last)")
        }
        // 未参与/空类也要进指纹：用户把一类从"未勾"改成"有候选且勾上"是形状变化，
        // 但只数参与集会漏掉"某个空类突然有了文件"这一类漂移。
        for category in space.skippedEmpty { parts.append("empty:" + category) }
        for category in space.excluded { parts.append("off:" + category) }
        return stableHash(parts.joined(separator: "|"))
    }

    /// 稳定摘要：FNV-1a 64 位。
    ///
    /// 为什么自己算而不用 `hashValue`：Swift 的 `String.hashValue` **每次进程启动都换种子**，
    /// 拿它当持久化指纹 ⇒ 重启必然"漂移"，预览永远保不住（而且永远复现不出来）。
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x100_0000_01b3
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}
