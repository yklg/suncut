import Foundation

// ============================================================================
// 文件夹混剪 · 组合级不重复择片（纯值类型 + 纯函数，零 IO / 零系统随机源）
//
// 计划真源：~/.qoder-cn/plans/northern-slope-widgeon.md（第二轮改判 A/B 段）
//          台账：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md（D23–D36、R25–R50）
//
// ## 口径（D23）
//
// 「不重复」落在**组合级**：同一素材允许在不同条里复现，但整行「类别→素材」搭配必须互不相同。
// 例：4 类各 20/20/10/5 条 ⇒ 上限是 20×20×10×5 = 20000 条互不相同的组合，
// 而不是旧口径"素材最少那一类的 5 条"。
//
// ## 机理：Floyd 无放回抽样 + 混合基数解码 + 素材签名账本
//
// 为什么不用上一版的 Feistel 双射 + cycle-walking + 游标 + 跳过规则 + 两级账本 ——
// 三条理由，**必须留在注释里**，防下一个人在此"简化"回去：
//   ① **游标 + 跳过规则本身是错的**。反例：`radix=[2,2]`、M=4，游标走到 3；
//      第 1 行替补到 index3 记进集合，游标继续前进又发出 3 ⇒ **两行完全相同**。
//      修它要靠 `issued` 集合去兜游标走过的洞 —— 等于两套机理互相补漏。
//      Floyd 天生给 k 个互不相同的序号，不需要游标，也不需要跳过循环。
//   ② **两级账本（committed + preview）是为游标语义长出来的**。签名集合只有
//      "要不要排除已发出"一个用途，预览天然不消耗（不写集合即可），不需要第二颗账本。
//   ③ **cycle-walking 的全部价值是"置换后仍不撞"，而它撞的是序号空间，不是素材空间**。
//      素材级去重（D31）本来就要在签名层过滤一次，Feistel 省不掉那一步 ⇒ 复杂度净亏。
//
// ## 正确性分工（两者不重叠、不互相补漏）
//
//   • Floyd 只保证**同批内序号互不相同** ⇒ 同批内组合互不相同；
//   • **跨批不重复**靠 `issuedSignatures` 排除。
//
// ## Floyd 的已知副作用：产出的序号是**升序**的（外部经验，D35）
//
// 混合基数解码下 `decode(0)` 就是"每一个类别的第 1 个文件"。成员分布本身是均匀的
// （每个 k-子集等概率），但**截断发生在顺序之上**：若"取前 count 个"，就会系统性偏向
// 每个文件夹开头的素材 —— 用户看到的是"翻来覆去就开头那几个"。
// ⇒ 返回前必须用**注入种子的 Fisher-Yates 打散**（不许用 `shuffled()` / `.random(in:)`，
//   守卫 G-a1 钉的就是"混剪通路只许用注入 seed 的随机源"）。
//
// ## 终止性（D36）
//
// Floyd **最坏情况也只消耗 k 次随机数**（《编程珠玑》习题 12.9 的构造性保证）；
// 朴素的"重取到不重复为止"在 k→population 时是 >k 次。判据 FMX-02 就钉这个次数，
// 它同时是"实现被换回朴素重取法"的负腿。生产侧的整批时间预算在调用方（`stop()` +
// `FolderMixLimits.generateBudgetSeconds`），**不在这里赌墙上时钟**。
//
// 接口锁定（FolderMixPickerTests / FolderMixCombinationTests 依赖这些形状）：
//   public struct FolderMixCandidate { identityKey, category, name, path, duration: Double?,
//                                      byteSize: Int64? }
//   public protocol FolderMixRandom  { mutating func nextInt(upperBound:) -> Int }
//   public struct SplitMix64         { init(seed:), nextUInt64(), nextInt(upperBound:) }
//   public struct FolderMixComboSpace { participants, radixes, skippedEmpty, excluded,
//                                       total, isSaturated, decode(index:), encode(ordinals:) }
//   public struct FolderMixComboLedger { issuedSignatures, issuedCount, remaining(in:),
//                                        contains(signature:), commit(signature:) }
//   public struct FolderMixComboRow  { ordinal, picks, signature }
//   public struct FolderMixShortfall { requestedIndex, reason, categories }
//   public struct FolderMixBatchResult { rows, shortfall }
//   public enum FolderMixPicker { combinationCount(candidatesByCategory:orderedCategories:enabled:),
//                                 sampleDistinctOrdinals(count:population:rng:),
//                                 draw(candidatesByCategory:space:ledger:rng:),
//                                 drawMany(candidatesByCategory:space:ledger:count:rng:),
//                                 substitute(row:category:unusableKeys:candidatesByCategory:
//                                            space:ledger:rng:) }
//
// 规则（台账第九节）：
//   R1 同 seed 幂等：同 (输入, seed, ledger) 两次调用逐字同解。
//   R4 空类与未勾选类**不进乘积**、不出现在 picks，且它在排列里的位置不改变其他类别的取数
//      （旧 R4 的"不消耗随机数"在新机理下自动成立：抽样只看参与集）。
//   R5 输出顺序：`picks` 顺序恒等于参与类别顺序（= 用户排列顺序去掉未勾与空类）。不重排。
//   R6 行内同素材：`精确识别` 打开后，同一内容可能同时出现在两个类别的候选里 ⇒
//      同一行不得取两次同一 `identityKey`；撞上就不发这一条，并在差额记录里点名是哪几类（`categories`）。
//   R8 `count > 组合总数` 抛硬错误，**不静默截断**（钳制在 UI 层做）。
//   R9 局部重掷：`substitute` 只在**同一类别内**换素材，其他类别的 picks 逐字不动。
//   R10 产出序号集合的成员分布均匀，且**截断顺序无偏**（打散腿）。
//
// 〔已作废的旧规则，别照抄回去〕R2/R3（素材级会话内不回放、按类别记 used、用尽即重置）
// 与 R7（`drawMany(n)` 的前 k 行逐字等于 `drawMany(k)`）随 D23/D30 整体作废：
// Floyd 每批都是独立随机集，前缀一致在数学上就不可能成立。它承担过的两条真实契约
// 换成了 FMX-07（`remaining` 只由签名集大小推）与 FMX-19（`generate()` 必须复用预览行）。
//
// 非空洞性论证（实现写错时哪条测试红）：
//   • 打散被删掉                 → FMX-04 红（各文件夹首位素材入选计数偏高）
//   • 换回朴素"重取到不重复"      → FMX-02 红（随机数消耗 > 2k−1）
//   • 乘积写成求和               → FMX-01/P1 红（20000 变 55）
//   • 溢出用 `*` 回绕            → P13 红（负数 radix 直接崩或给出假精确）
//   • 空类算进乘积               → P4 红（有空文件夹就一条都出不了）
//   • `drawMany` 顺手写 ledger   → FMX-07 红（预览开始消耗组合）
//   • 签名按 path 记             → 精确识别两态判据红（同内容跨目录判成两条）
// ============================================================================

/// 一条候选素材的纯值投影。
public struct FolderMixCandidate: Equatable, Hashable, Sendable, Identifiable {
    /// **素材身份键**（D31）：默认 = 绝对路径（零等待）；「精确识别（慢）」打开 = 内容校验和。
    /// radix、签名账本、`spaceRevision` 全部只认这一颗 ⇒ 去重不需要第二套逻辑。
    public let identityKey: String
    public let category: String
    public let name: String
    /// 入库前的身份载体。方案不指向它 —— 路径只在「扫描→抽中→入库」这一段活着。
    public let path: String
    /// 秒。懒入库下可能读不到；**读不到就是 nil，不许当 0 秒**（决定 6）。
    public let duration: Double?
    /// 盘上字节数（S8）。nil = IO 层读不出 —— 同样不许当 0：超软上限那句「还要占多少盘」
    /// 走 `DiskSpaceBudget.estimate`，喂 0 会让用户按一个虚低的数勾「我已确认」。
    public let byteSize: Int64?

    public init(identityKey: String, category: String, name: String,
                path: String, duration: Double?, byteSize: Int64? = nil) {
        self.identityKey = identityKey
        self.category = category
        self.name = name
        self.path = path
        self.duration = duration
        self.byteSize = byteSize
    }

    public var id: String { identityKey }
}

/// 随机源的抽象。存在的唯一理由是把"消耗了几次随机数"变成可测的（FMX-02）——
/// 那是 Floyd 相对朴素重取法的构造性保证，也是实现被换回去时的负腿。
public protocol FolderMixRandom {
    mutating func nextInt(upperBound: Int) -> Int
}

/// 确定性伪随机源：SplitMix64（全仓唯一一份定义，守卫 G-j 钉住）。
public struct SplitMix64: Hashable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [0, upperBound) 均匀取整 —— **拒绝采样，不许换成 `%`**。
    ///
    /// 为什么不用 `nextUInt64() % upperBound`：`2^64` 不是 `upperBound` 的整数倍时，
    /// 余数 `[0, 2^64 % upperBound)` 会比别的机会多一次 ⇒ 小候选集下"排在前面那条素材"
    /// 被抽中的概率系统性偏高。这条偏置与 R10 是同一件事的两半：一个管取值均匀，
    /// 一个管截断均匀。
    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound 必须 > 0；调用方无候选时不得请求随机（FolderMixPicker 已守住）")
        let ub = UInt64(upperBound)
        let limit = UInt64.max - (UInt64.max % ub)   // ≤ UInt64.max 的 ub 的最大整数倍
        var r = nextUInt64()
        while r > limit { r = nextUInt64() }
        return Int(r % ub)
    }
}

extension SplitMix64: FolderMixRandom {}

/// 组合空间：参与类别 × 各自的候选数。
public struct FolderMixComboSpace: Equatable, Sendable {

    /// 参与集 = 勾选 ∧ 非空，**按用户排列顺序**（R5 的顺序真源）。
    public let participants: [String]
    /// 与 participants 同序同长，全部 ≥ 1；= 该类别**类内去重后**的素材数。
    public let radixes: [Int]
    /// 排列里候选为 0 的类（D13 标灰不阻断）
    public let skippedEmpty: [String]
    /// 用户取消勾选的类
    public let excluded: [String]
    /// Π radixes，饱和到 `Int.max`
    public let total: Int
    /// `total` 是否被饱和截断过 —— 界面据此改口说「组合空间充足」，不报假精确
    public let isSaturated: Bool

    public init(candidatesByCategory: [String: [FolderMixCandidate]],
                orderedCategories: [String],
                enabled: Set<String>) {
        var parts: [String] = []
        var radix: [Int] = []
        var empty: [String] = []
        var off: [String] = []
        for category in orderedCategories {
            let candidates = candidatesByCategory[category] ?? []
            let distinct = Set(candidates.map(\.identityKey)).count      // 类内去重
            if !enabled.contains(category) {
                off.append(category)
                continue
            }
            if distinct == 0 {
                empty.append(category)                                   // R4：不进乘积
                continue
            }
            parts.append(category)
            radix.append(distinct)
        }
        participants = parts
        radixes = radix
        skippedEmpty = empty
        excluded = off

        let product = Self.product(ofRadixes: radix)
        total = product.total
        isSaturated = product.saturated
    }

    /// 组合序号 → 各类别的候选下标。越界返回 nil（**不取模**：取模会把"越界"伪装成合法解）。
    ///
    /// 位序：第一个参与类别是**最高位** ⇒ `decode(0)` 就是"每一类都取第 1 条"。
    /// 这个性质正是 R10 要打散的理由 —— 不打散，序号小的组合会成批出现在界面上。
    public func decode(index: Int) -> [Int]? {
        guard !participants.isEmpty, index >= 0, index < total else { return nil }
        var ordinals = [Int](repeating: 0, count: radixes.count)
        var rest = index
        for i in stride(from: radixes.count - 1, through: 0, by: -1) {
            ordinals[i] = rest % radixes[i]
            rest /= radixes[i]
        }
        return rest == 0 ? ordinals : nil
    }

    /// `decode` 的逆映射。替补与"逐条比对不重复"都要用它。
    public func encode(ordinals: [Int]) -> Int? {
        guard ordinals.count == radixes.count, !participants.isEmpty, total > 0 else { return nil }
        var index = 0
        for i in 0..<radixes.count {
            guard ordinals[i] >= 0, ordinals[i] < radixes[i] else { return nil }
            let (scaled, o1) = index.multipliedReportingOverflow(by: radixes[i])
            let (summed, o2) = scaled.addingReportingOverflow(ordinals[i])
            if o1 || o2 { return nil }
            index = summed
        }
        return index < total ? index : nil
    }

    /// 某个类别在参与集里的位置；未参与返回 nil。
    public func position(of category: String) -> Int? { participants.firstIndex(of: category) }

    /// 混合基数的乘积，**饱和而不回绕**。
    ///
    /// 为什么单独抽出来：要触发回绕得有 9.2×10¹⁸ 个组合，用候选夹具去凑就是几百万个对象，
    /// 判据跑不动。抽成纯函数后 N4 那把"改成 `&*`"的刀才有地方打。
    /// 回绕比"报不准"危险得多：负数 total 会让 `count > total` 恒真、磁盘预检恒过。
    public static func product(ofRadixes radixes: [Int]) -> (total: Int, saturated: Bool) {
        guard !radixes.isEmpty else { return (0, false) }        // 没有参与类别 ⇒ 一个组合都发不出
        var product = 1
        for r in radixes {
            let (next, overflow) = product.multipliedReportingOverflow(by: r)
            if overflow { return (Int.max, true) }
            product = next
        }
        return (product, false)
    }
}

/// 会话内"已发出"的**唯一**记录。预览、失败、停止都不写它（只有 `generate()` 成功路径写）。
public struct FolderMixComboLedger: Equatable, Sendable {

    /// 每行 = 按参与类别顺序排列的 `identityKey` 元组。
    /// ⚠ 记的是**素材身份**不是路径序号：换目录后序号含义会漂，身份不会（D31）。
    public private(set) var issuedSignatures: Set<[String]> = []

    public init() {}

    public var issuedCount: Int { issuedSignatures.count }

    /// `remaining` **只能**由这颗集合推 —— 另算一份游标就是第二个真源（FMX-07 钉这条）。
    public func remaining(in space: FolderMixComboSpace) -> Int {
        max(0, space.total - issuedCount)
    }

    public func contains(signature: [String]) -> Bool { issuedSignatures.contains(signature) }

    /// 记账。已存在则返回 false 且不重复计（幂等，FMX-08）。
    @discardableResult
    public mutating func commit(signature: [String]) -> Bool { issuedSignatures.insert(signature).inserted }
}

/// 一条方案（= 一个组合）。
public struct FolderMixComboRow: Equatable, Sendable {
    /// 抽中时的组合序号（`space.decode` 的入参）。替补后必须重新 `encode` 回来。
    public let ordinal: Int
    /// 顺序恒等于 `space.participants`（R5）
    public let picks: [FolderMixCandidate]

    public init(ordinal: Int, picks: [FolderMixCandidate]) {
        self.ordinal = ordinal
        self.picks = picks
    }

    /// 这一行的签名 = 各参与类别选中项的身份键，按参与顺序。
    public var signature: [String] { picks.map(\.identityKey) }
}

/// 一条"该出而没出"的记录。**用 struct 不用元组**：元组不 conform Equatable，
/// 拿它当字段会让整个 `FolderMixBatchResult` 合成不出 `==`（编译器只报"不 conform 协议"，
/// 报不到字段上，找起来费劲）。
public struct FolderMixShortfall: Equatable, Sendable {
    public let requestedIndex: Int
    public let reason: String
    /// 行内撞身份时**具体是哪几类** —— 调用方据此走同类替补（R9）。
    /// 只有原因字符串的话，VM 就只能去 parse 中文，那是把契约写在文案上。
    public let categories: [String]
    public init(requestedIndex: Int, reason: String, categories: [String] = []) {
        self.requestedIndex = requestedIndex
        self.reason = reason
        self.categories = categories
    }
}

public struct FolderMixBatchResult: Equatable, Sendable {
    public let rows: [FolderMixComboRow]
    /// 差了几条、各为什么（"组合空间已耗尽"）。**不为了凑满而放宽不重复**（D24/第十一节）。
    public let shortfall: [FolderMixShortfall]

    public init(rows: [FolderMixComboRow], shortfall: [FolderMixShortfall] = []) {
        self.rows = rows
        self.shortfall = shortfall
    }
}

public enum FolderMixPickerError: Error, Equatable, Sendable {
    case noParticipants
    case countBelowMinimum(Int)
    case countExceedsCombinationSpace(requested: Int, total: Int)
    /// 单次抽取超过硬预算 —— 先拒绝，**不先分配内存**（FMX-11）
    case tooManyRowsPerDraw(requested: Int, budget: Int)
}

public enum FolderMixLimits {
    /// 默认软上限。越过它不是硬墙：页脚出红字预估 + 必须勾「我已确认」（D24）。
    public static let defaultSoftLimit = 50
    /// 条数控件的钳位区间。
    public static let countInputClamp = 1...999_999
    /// 单次抽取的硬预算：超出要求分批。
    /// 拦什么：输入 999999 时先把内存打爆再谈红字预估。
    /// 拦不住什么：调用方自己循环调多次（那是有意的分批）。
    public static let maxRowsPerDraw = 5000
    /// 补抽余量：签名已占的序号会被过滤掉，多抽这些是为了不必再走一轮。
    /// 为什么带余量而不是"抽 count 个过滤后有多少算多少"：后者会在已发出量大时
    /// 稳定少给几条，而少给的条数用户看得见（计划 60 / 实得 57）。
    public static func reDrawReserve(for count: Int) -> Int { max(8, count / 4) }
    /// 同类替补余量。**写成公式不写成常量**：小空间（radix=2）若按固定 3 备货，
    /// 会把 IO 预算算成比可用候选还多。
    public static func substituteReserve(radix: Int, alreadyDrawn: Int) -> Int {
        max(0, min(radix - alreadyDrawn, 3))
    }
    /// 连续几条**同因**失败就判定这是环境级故障（磁盘满 / 无权限 / 外接盘拔出），整批停。
    public static let systemicFailureStreak = 3
    /// 时长探针的条数预算（颗数走 `ConcurrencyPolicy`，不在这里写死）。
    public static let durationProbeBudgetFiles = 2000
    /// 签名集持久化上限：超过就只存 `spaceRevision` 不存签名，并明说"重启后跨批不重复失效"。
    /// 为什么要有：软上限可被调到 999_999，签名集就是 ~10⁶ 条元组。
    public static let maxPersistedSignatures = 20_000
    /// 整批生成的时间预算（秒）。判据侧一律走**步数/假时钟缝**，不赌现网时钟（D36）。
    public static let generateBudgetSeconds = 600
}

public enum FolderMixPicker {

    /// 参与类别的组合总数（只做乘法，**不抽取** —— 改条数/改勾选/改排列都只走这里）。
    public static func combinationCount(candidatesByCategory: [String: [FolderMixCandidate]],
                                        orderedCategories: [String],
                                        enabled: Set<String>) -> Int {
        FolderMixComboSpace(candidatesByCategory: candidatesByCategory,
                            orderedCategories: orderedCategories,
                            enabled: enabled).total
    }

    /// Floyd 无放回抽样：给 `count` 个**互不相同**的序号，取值范围 `[0, population)`。
    ///
    /// 返回前做一次注入种子的 Fisher-Yates 打散（R10）—— 不打散的话结果是升序的，
    /// 而调用方会"取前 count 个"，于是系统性偏向 `decode(0)`（每个文件夹的第一条）。
    /// 随机数消耗：取样 k 次 + 打散 k−1 次 = **2k−1 次，与 population 无关**（FMX-02）。
    public static func sampleDistinctOrdinals<R: FolderMixRandom>(count: Int,
                                                                 population: Int,
                                                                 rng: inout R) -> [Int] {
        precondition(count >= 0 && population >= 0, "计数不许为负；调用方负责拒绝非法入参")
        guard count > 0, population > 0, count <= population else { return [] }
        var picked = Set<Int>()
        picked.reserveCapacity(count)
        // **插入序数组**：Swift 的 Set 迭代顺序不保证稳定（内容相同的两个 Set 也可能不同序），
        // 拿 Array(picked) 当打散的底会把 R1「同 seed 逐字同解」当场击穿
        // —— 这条是第一版判据跑出来才抓到的（P1 两次给出 [3,0,2,4] 与 [0,4,2,5]）。
        var out: [Int] = []
        out.reserveCapacity(count)
        // Floyd 本体：第 j 步在 [0, j] 里取；撞了就补 j 本身（j 这一步还不可能被取过）。
        for j in (population - count)..<population {
            let t = rng.nextInt(upperBound: j + 1)
            if picked.contains(t) {
                picked.insert(j)
                out.append(j)
            } else {
                picked.insert(t)
                out.append(t)
            }
        }
        // Fisher-Yates（注入种子）。不许改成 `shuffled()` —— 那是系统随机源，守卫 G-a1 会红。
        var i = out.count - 1
        while i > 0 {
            let k = rng.nextInt(upperBound: i + 1)
            if k != i { out.swapAt(i, k) }
            i -= 1
        }
        return out
    }

    /// 抽**一条**：从可用序号里取第一个能落成真行的（跳过签名已占的与行内撞身份的）。
    /// 返回 nil = 组合空间已耗尽（调用方要出声，不许静默少给）。
    public static func draw<R: FolderMixRandom>(candidatesByCategory: [String: [FolderMixCandidate]],
                                                space: FolderMixComboSpace,
                                                ledger: FolderMixComboLedger,
                                                rng: inout R) -> FolderMixComboRow? {
        let remaining = space.total - ledger.issuedCount
        guard remaining > 0 else { return nil }
        // 单条也走"批量"的同一套解，避免两套机理（旧 R7 的教训）。
        let batch = try? drawMany(candidatesByCategory: candidatesByCategory, space: space,
                                  ledger: ledger, count: 1, rng: &rng)
        return batch?.rows.first
    }

    /// 一次出 N 条预览。**只读 ledger 做排除，绝不写它**（预览不消耗组合，D27）。
    public static func drawMany<R: FolderMixRandom>(candidatesByCategory: [String: [FolderMixCandidate]],
                                                    space: FolderMixComboSpace,
                                                    ledger: FolderMixComboLedger,
                                                    count: Int,
                                                    rng: inout R) throws -> FolderMixBatchResult {
        guard !space.participants.isEmpty else { throw FolderMixPickerError.noParticipants }
        guard count >= 1 else { throw FolderMixPickerError.countBelowMinimum(count) }
        guard count <= FolderMixLimits.maxRowsPerDraw else {
            throw FolderMixPickerError.tooManyRowsPerDraw(requested: count,
                                                          budget: FolderMixLimits.maxRowsPerDraw)
        }
        // 饱和空间里 count > total 永假 ⇒ 只有没饱和时才可能"超总数"，此时抛硬错误不截断（R8）。
        if !space.isSaturated, count > space.total {
            throw FolderMixPickerError.countExceedsCombinationSpace(requested: count, total: space.total)
        }

        let remaining = space.total - ledger.issuedCount
        // 要得比剩的多 ⇒ 空间接近填满，此时**必须把整个序号域扫一遍**：
        // 只抽 count+reserve 个的话，可能一个都没落进那几个"未发出"的序号上，
        // 于是明明还剩却报"已耗尽"（FMX-01 实测停在 3/4 就是这么来的）。
        // 大空间里 remaining 必然远大于 count（issued 受 maxPersistedSignatures 约束），
        // 所以这条只在真快发满时生效，不会把预算撑开。
        let available: Int
        if count >= remaining {
            available = min(space.total, FolderMixLimits.maxRowsPerDraw * 4)
        } else {
            available = min(remaining, count + FolderMixLimits.reDrawReserve(for: count))
        }
        guard available > 0 else {
            return FolderMixBatchResult(rows: [],
                                        shortfall: (1...count).map {
                                            FolderMixShortfall(requestedIndex: $0,
                                                               reason: "组合空间已耗尽")
                                        })
        }

        let ordinals = sampleDistinctOrdinals(count: available, population: space.total, rng: &rng)
        var rows: [FolderMixComboRow] = []
        var notes: [FolderMixShortfall] = []

        for ordinal in ordinals {
            guard rows.count < count else { break }
            guard let decoded = space.decode(index: ordinal) else { continue }
            var collided: [String] = []
            guard let built = buildRow(ordinal: ordinal, ordinals: decoded, space: space,
                                       candidatesByCategory: candidatesByCategory,
                                       collided: &collided) else {
                if !collided.isEmpty {
                    // 行内撞身份：这一条不能要（成片会连着放同一段），记下待替补的具体类别。
                    notes.append(FolderMixShortfall(
                        requestedIndex: rows.count + 1,
                        reason: "行内同素材：\(collided.joined(separator: "、"))",
                        categories: collided))
                }
                continue
            }
            // 只需要排除**跨批**已发出的签名。同批不需要第二层集合：
            // Floyd 保证序号互不相同，而每类候选已按 identityKey 去重 ⇒
            // 两个不同序号至少在一类上取到不同身份 ⇒ 签名必然互不相同。
            // （这里原来挂过一个 `seenHere`，被 N8 那把刀证明不可达 ⇒ 删。
            //   留一条测不到的分支，比留一条测不到的常量更坏。）
            if ledger.contains(signature: built.signature) { continue }
            rows.append(built)
        }

        // 差额逐条出声（不为凑满而放宽不重复）。行内撞身份的原因也一并带出去。
        var shortfall: [FolderMixShortfall] = notes
        if rows.count < count {
            shortfall += ((rows.count + 1)...count).map {
                FolderMixShortfall(requestedIndex: $0,
                                   reason: "组合空间已耗尽（已发出 \(ledger.issuedCount) 条）")
            }
        }
        return FolderMixBatchResult(rows: rows, shortfall: shortfall)
    }

    /// 第 k 条的**同类替补**（D28 决定 5）：只在 `category` 这一类里换一条素材，
    /// 其他类别的 picks 逐字不动（R9）。换完仍与已发出的签名撞、或该类已无可用候选 ⇒ 返回 nil，
    /// 由调用方摘行并写明原因（**不改 spaceRevision**：一次失败不该把整页预览冲掉）。
    public static func substitute<R: FolderMixRandom>(row: FolderMixComboRow,
                                                      category: String,
                                                      unusableKeys: Set<String>,
                                                      candidatesByCategory: [String: [FolderMixCandidate]],
                                                      space: FolderMixComboSpace,
                                                      ledger: FolderMixComboLedger,
                                                      rng: inout R) -> FolderMixComboRow? {
        guard let slot = space.position(of: category), slot < row.picks.count else { return nil }
        let pool = (candidatesByCategory[category] ?? []).filter { candidate in
            !unusableKeys.contains(candidate.identityKey) && candidate.identityKey != row.picks[slot].identityKey
        }
        guard !pool.isEmpty else { return nil }

        // 按注入种子打乱候选顺序后逐个试，第一个"签名没被发过"的就用它 ——
        // 比"随机抽一个再判撞"好：小空间里后者会反复撞在同一批已发出的签名上却什么都不报。
        var order = pool
        var i = order.count - 1
        while i > 0 {
            let k = rng.nextInt(upperBound: i + 1)
            if k != i { order.swapAt(i, k) }
            i -= 1
        }
        for candidate in order {
            var picks = row.picks
            picks[slot] = candidate
            // 换完仍然行内撞身份 ⇒ 这条不算解（R6）
            if Set(picks.map(\.identityKey)).count != picks.count { continue }
            let signature = picks.map(\.identityKey)
            if ledger.contains(signature: signature) { continue }
            guard let ordinals = ordinalsOf(picks: picks, space: space,
                                            candidatesByCategory: candidatesByCategory),
                  let ordinal = space.encode(ordinals: ordinals) else { continue }
            return FolderMixComboRow(ordinal: ordinal, picks: picks)
        }
        return nil
    }

    // MARK: 内部

    /// 序号 → 一行。撞身份（R6）不塞进行里，而是从 `collided` 带出去 ——
    /// 行类型上留一个"返回时永远为空"的字段就是幽灵字段。
    /// 序号 → 一行（持久化 rehydrate 与 `drawMany` 共用这一颗，**不留第二份解码路径**）。
    ///
    /// 为什么公开：会话只持久化序号（不持久化路径与素材对象），重启后要把上一批预览
    /// 重建回来 —— 若 rehydrate 自己再写一遍「按下标取候选」，去重口径（`distinctCandidates`）
    /// 与行内撞身份（R6）就有两份实现，会漂。
    /// 返回 nil 的两种情况都该作废这一行：序号越界（目录内容变了）、或行内撞身份
    /// （精确档归并后撞键 —— 那种情况下宁可少一条，也不出一条重复的）。
    public static func row(forOrdinal ordinal: Int,
                           candidatesByCategory: [String: [FolderMixCandidate]],
                           space: FolderMixComboSpace) -> FolderMixComboRow? {
        guard let ordinals = space.decode(index: ordinal) else { return nil }
        var collided: [String] = []
        return buildRow(ordinal: ordinal, ordinals: ordinals, space: space,
                        candidatesByCategory: candidatesByCategory, collided: &collided)
    }

    private static func buildRow(ordinal: Int, ordinals: [Int], space: FolderMixComboSpace,
                                 candidatesByCategory: [String: [FolderMixCandidate]],
                                 collided: inout [String]) -> FolderMixComboRow? {
        var picks: [FolderMixCandidate] = []
        var taken = Set<String>()
        for (slot, category) in space.participants.enumerated() {
            let distinct = distinctCandidates(candidatesByCategory[category] ?? [])
            guard ordinals[slot] < distinct.count else { return nil }
            let candidate = distinct[ordinals[slot]]
            if taken.contains(candidate.identityKey) {
                collided.append(category)         // R6：行内同素材，交给调用方同类替补
                continue
            }
            taken.insert(candidate.identityKey)
            picks.append(candidate)
        }
        guard collided.isEmpty, picks.count == space.participants.count else { return nil }
        return FolderMixComboRow(ordinal: ordinal, picks: picks)
    }

    /// 类内按 `identityKey` 去重，**保留首次出现顺序**（不许排序：顺序就是用户看到的候选顺序）。
    private static func distinctCandidates(_ candidates: [FolderMixCandidate]) -> [FolderMixCandidate] {
        var seen = Set<String>()
        var out: [FolderMixCandidate] = []
        for candidate in candidates where !seen.contains(candidate.identityKey) {
            seen.insert(candidate.identityKey)
            out.append(candidate)
        }
        return out
    }
}

private extension FolderMixPicker {
    /// picks → 各类别在**类内去重后**的候选下标。定位不到就返回 nil（说明 picks 与 space 不同源）。
    static func ordinalsOf(picks: [FolderMixCandidate], space: FolderMixComboSpace,
                           candidatesByCategory: [String: [FolderMixCandidate]]) -> [Int]? {
        guard picks.count == space.participants.count else { return nil }
        var out: [Int] = []
        for (slot, category) in space.participants.enumerated() {
            let distinct = distinctCandidates(candidatesByCategory[category] ?? [])
            guard let i = distinct.firstIndex(where: { $0.identityKey == picks[slot].identityKey })
            else { return nil }
            out.append(i)
        }
        return out
    }
}
