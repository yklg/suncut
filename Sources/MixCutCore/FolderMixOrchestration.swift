import Foundation

// ============================================================================
// 文件夹混剪 · 生成期编排状态机（计划 D 段 / FMX-18、FMX-19）
//
// 为什么这段逻辑在 Core 而不是 VM 里（计划「I 层三条的可测性」那一节拍的①案）：
//   `FolderMixViewModel` 在 App target，`swift test` 编不到它。把"抽 → 入库 → 解析 → 替补 →
//   摘行 → 提交"里**纯决策**的那一半抽成值类型之后，三条真实契约降成 U 层判据：
//     · FMX-18「只为真被抽中的类别建库」—— 输入是行，输出是任务清单，无 IO；
//     · FMX-19「generate 复用预览行、绝不重抽」—— 无失败时输出行必须与输入行逐字相同；
//     · 失败七档的 A/B/C 三档（入库失败 / 在库但无整片段 / 行内撞同一素材）各有专属错误码。
//   VM 只负责把 SwiftData 与 IO 的事实喂成事件 —— 与 `FolderMixSessionState`、
//   `ProjectDataReadiness.swift:19` 同一个先例形状："什么算合法"的门放 Core，不放 View/VM。
//
// 生效条件：调用方必须先把"入库结果"与"能否解析出整片段"折算成 `resolution`
//   （键 → 可用/不可用 + 不可用的错误码）。这里不碰库、不碰盘。
// 拦不住什么：
//   · 拦不住调用方**重抽一批行**再喂进来 —— FMX-19 钉的是"无失败时输出 == 输入"，
//     真要有人绕过预览重抽，红的是 VM 那条链与真机第 5 步；
//   · 拦不住错误码被统一填成 `.other`（档 A/B 的区分就糊了）—— 由 FMX-09 的
//     "一档一个专属码"判据 + service 侧逐分支构造钉；
//   · 替补的**次数上限**在这里判，但"总共尝试 ≤ 2N"这类跨批口径由 VM 的循环负责。
// 最坏代价：替补是每格一次的线性扫描（不是回溯搜索）⇒ 单批 N 条 × 每行类别数，
//   不会出现"为了凑满一条而重跑整批"的组合爆炸；代价写死在这里，不靠运气收敛。
//
// 规则（台账第九节七档）：
//   G1 档 A 入库失败 ⇒ 同类别内换一条候选替补（`FolderMixIngestFailureCode.ingestFailed`）。
//   G2 档 B 已入库但没有覆盖整片的段 ⇒ 同样替补（`.noWholeClipSegment`），
//      且**绝不替它补建整片段**（T-25 钉这条，那是母体导入的语义，不是混剪的）。
//   G3 档 C 一行里两段解析到同一个 Segment/Video ⇒ 替补一次，仍撞就把这一行摘掉
//      （`.duplicateInRow`）；不许为了凑满而放宽"组合互不相同"。
//   G4 档 D 磁盘预检不过 ⇒ 整批不出，本状态机不参与（service 的 abortMessage 那条路）。
//   G5 摘掉的行必须逐条带原因进 `shortfalls`，界面写「计划 N 条 / 实得 M 条」。
//   G6 只有 `finalizeSucceeded` 之后才由调用方逐行 `commit(signature:)` ——
//      预览、失败、停止都不写签名账本（FMX-07 的另一半）。
// ============================================================================

/// 入库/解析失败的**专属**错误码（FMX-09：一档一个码，复用即归因错位）。
///
/// 为什么不能靠字符串匹配：`ImportReport.FailedItem.reason` 是给人看的文案，
/// 磁盘满与无权限的文案会随 `FriendlyError` 改；而"同因连续失败短路"这条逻辑
/// 必须只看**类别**，不看措辞。
public enum FolderMixFailureCode: String, CaseIterable, Equatable, Sendable {
    /// 档 A：拷盘/建库这一步就失败了
    case ingestFailed
    /// 档 B：素材在库里，但没有任何一条覆盖整片的段
    case noWholeClipSegment
    /// 档 C：同一行里两段解析到同一个素材（精确档下跨目录同内容会归并成同一键）
    case duplicateInRow
    /// 档 B2（计划 2026-10-22 决议 J4）：入库报成功了，可这一条没在交回的对应关系里。
    ///
    /// 为什么不能复用 `.ingestFailed`：那次真机 50 条全被摘掉，红字写的是「素材入库或解析失败
    /// （档 ingestFailed）」，而日志同批写的是「新建整片段 0、仅关联 59、**失败 0**」——
    /// 错误码算得对（确实不可用），归因却指错了地方，人照着它去查磁盘和权限永远查不出来。
    /// 一档一个专属码（FMX-09）在这里的唯一作用就是让"错在哪一层"能被读出来。
    case notIngested
    /// 档 B0（计划 2026-10-22 第三轮 笔 K4，决议 K6）：库里那一行**在**、交回也交回了，
    /// 可它指向的库内文件已不在盘上 —— 也就是「源文件已不存在」那条横幅的后一半。
    ///
    /// 为什么必须单独一颗码而不是复用 `.noWholeClipSegment`：真机现场里那 163 行指向的文件
    /// 已经没了（`[OrphanGC] 库里有 163 条素材记录的 localPath 在磁盘上不存在`），若混剪照旧
    /// 只问"有没有整片段"，就会把"文件没了"报成"缺个段"，人照着这句话去查分镜导入通路永远查不出来
    /// —— 一档一码（FMX-09）在这里存在的唯一理由还是"让错在哪一层能被读出来"。
    /// 为什么也不算环境级：换一条素材就能替掉它，与环境无关（`.diskShortfall` 那一档才会短路整批）。
    case materialMissing
    /// 环境级：磁盘不足（短路用；整批停手）
    case diskShortfall
    /// 环境级：读不到（IO 抖动 / 外接盘被拔 / 文件已不在原位置）
    case unreadable
    /// 环境级：没权限 / 卷只读
    case noPermission
    /// 兜底：确实归不进上面任何一档时才用，且必须带原始措辞
    case other
}

extension FolderMixFailureCode {
    /// 这一档在摘行报告里的那句人话（决议 J4：错误码算得对 ≠ 归因对）。
    ///
    /// 为什么单独做一颗属性而不是在界面里写 if：`rawValue` 是给判据和日志看的英文码，
    /// 直接把它塞进红字，用户读到的是「档 ingestFailed」而去查磁盘 ——
    /// 上一版真机就是这样把一条根本没失败的通路报成"入库失败"的。
    /// 档名仍随串带出（既有判据 `reason.contains(rawValue)` 钉着它不许掉）。
    public var shortfallText: String {
        switch self {
        case .ingestFailed: return "素材入库失败"
        case .noWholeClipSegment: return "这条素材此前按分镜导入、整片直拼要的那条覆盖全片的段没补上"
        case .notIngested: return "入库后没找到这条素材"
        case .materialMissing: return "素材文件已不在盘上"
        case .duplicateInRow: return "这一行里两段指向同一素材"
        case .diskShortfall: return "磁盘空间不足"
        case .unreadable: return "文件读不出"
        case .noPermission: return "没有读写权限"
        case .other: return "素材不可用"
        }
    }

    /// 这颗码算不算**环境级**（可以短路整批）。
    ///
    /// 为什么单独做成一颗判定而不是在短路里写 `!= .other`：短路的前提是"这一类失败
    /// 与具体是哪条素材无关"。档 A/B/C 三颗是**素材级**的（换一条就行），`.other` 是
    /// 归不进任何档的（措辞不同也算不同因）—— 把这三类算进环境级，就会在一盘正常素材里
    /// 掐掉整批。这条口径必须能在 `swift test` 里逐码点验，所以它是 Core 的属性而不是 VM 里的 if。
    public var isSystemic: Bool {
        switch self {
        case .diskShortfall, .unreadable, .noPermission: return true
        case .ingestFailed, .noWholeClipSegment, .duplicateInRow, .notIngested,
             .materialMissing, .other: return false
        }
    }
}

/// 一条候选在"入库 + 解析"之后的可用性。
public struct FolderMixResolution: Equatable, Sendable {
    public let identityKey: String
    public let isUsable: Bool
    public let failureCode: FolderMixFailureCode?

    public init(identityKey: String, isUsable: Bool, failureCode: FolderMixFailureCode? = nil) {
        self.identityKey = identityKey
        self.isUsable = isUsable
        self.failureCode = failureCode
    }

    public static func usable(_ key: String) -> FolderMixResolution {
        FolderMixResolution(identityKey: key, isUsable: true)
    }

    public static func failed(_ key: String, _ code: FolderMixFailureCode) -> FolderMixResolution {
        FolderMixResolution(identityKey: key, isUsable: false, failureCode: code)
    }
}

/// 生成期的入库任务清单（FMX-18 的判据对象）。
public struct FolderMixIngestTask: Equatable, Sendable {
    /// 一个类别要入库的路径（**抽中的 ∪ 替补余量**），保持参与顺序
    public struct Batch: Equatable, Sendable {
        public let category: String
        public let paths: [String]
    }
    public let batches: [Batch]
    /// 排在顺序里、勾了、有候选，但这一批一条都没抽中 ⇒ **不建项目**（D26：扫描零建库，
    /// 生成时也只建真用得上的）。界面据此解释"为什么侧栏少了两格"。
    public let categoriesNotBuilt: [String]

    public var totalPaths: Int { batches.reduce(0) { $0 + $1.paths.count } }
    public var categoriesBuilt: [String] { batches.map(\.category) }
}

/// 一次生成流水的读数（摘行原因 + 最终要建方案的行）。
public struct FolderMixGenerateOutcome: Equatable, Sendable {
    /// 存活行：无失败时与传入的预览行**逐字相同**（FMX-19）
    public let rows: [FolderMixComboRow]
    /// 被摘掉的请求位（"计划 N / 实得 M"的差额），逐条带原因
    public let shortfalls: [FolderMixShortfall]
    /// 环境级失败 ⇒ 整批不建（保留已入库的部分，G4/档 D 之外的短路）
    public let systemicAbort: FolderMixFailureCode?
    /// 实际发生的替补次数（VM 用它判「替补总尝试 ≤ 2N」这条硬预算）
    public let substitutionCount: Int
}

public enum FolderMixGeneratePlanner {

    /// 算出这一批要往库里拷哪些文件（G8 一次性入库，不逐行往返）。
    ///
    /// 为什么必须"抽中集 ∪ 每类余量"一次算完再入库：逐行"抽→入库→失败→再抽→再入库"
    /// 在磁盘满时会变成 N×radix 次 IO 且每轮重跑解析 —— 命中本仓「长任务反模式」的
    /// 无僵尸保护 / 非幂等两格。
    public static func ingestTask(rows: [FolderMixComboRow],
                                  candidatesByCategory: [String: [FolderMixCandidate]],
                                  space: FolderMixComboSpace,
                                  reservePerCategory: (Int, Int) -> Int
                                      = FolderMixLimits.substituteReserve) -> FolderMixIngestTask {
        let drawnPerCategory = rows.reduce(into: [String: Int]()) { acc, row in
            for pick in row.picks { acc[pick.category, default: 0] += 1 }
        }
        var batches: [FolderMixIngestTask.Batch] = []
        var notBuilt: [String] = []
        for category in space.participants {
            let drawn = drawnPerCategory[category] ?? 0
            guard drawn > 0, let pool = candidatesByCategory[category], !pool.isEmpty else {
                notBuilt.append(category)
                continue
            }
            // 余量只有一份真源：`FolderMixLimits.substituteReserve`（它自己就按"还剩几条没被抽中"封顶，
            // 并由 `FolderMixPickerTests` 的 LIMITS 四条直接钉住）。
            // 这里**不再夹第二层** —— 上一版外面还套了一道 `min(公式, pool.count - drawn)`，
            // 台架刀实测它是**非 binding 的死夹逼**（`.scratch/fm_mutate_stepK.py` K1-d：摘掉后
            // FMX-18/18b/18c/18f 一条都不红）。原因是形状本身兜住了：补余量那一趟只遍历有限池，
            // 无论 reserve 多大都装不出超过 `pool.count` 条 ⇒ 留着一道测不出来的"保护"就是错觉，
            // 按「戒幽灵代码」删掉，把话写在这里。
            let reserve = reservePerCategory(pool.count, drawn)
            // **先装这一类真被抽中的那些**（保参与顺序、按键去重），再用池子其余补到 `drawn + reserve` 封顶。
            // 为什么必须先装抽中集：上一版直接按池子顺序取前缀，抽中数只当**计数**用 ⇒ 一旦
            // 「条数 ≪ 池子」（小批量 + 大素材目录，也就是日常用法）真被抽中的素材根本没入库，
            // join 只能报「没找到」。2026-10-22 第三轮缺陷一的现场算术：交回 32 = 4×(5+3)、
            // 没找到 173 = (56+52+43+54)−32，而计划 5 条一条没出。
            // 上限、去重、provenance 三条既有断言的口径不变 —— 换的只是清单的来源。
            let byKey = Dictionary(pool.map { ($0.identityKey, $0) },
                                   uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            var paths: [String] = []
            for pick in rows.flatMap(\.picks) where pick.category == category {
                guard seen.insert(pick.identityKey).inserted,
                      let drawnCandidate = byKey[pick.identityKey] else { continue }
                paths.append(drawnCandidate.path)
            }
            for candidate in pool where paths.count < drawn + reserve {
                guard seen.insert(candidate.identityKey).inserted else { continue }
                paths.append(candidate.path)
            }
            batches.append(FolderMixIngestTask.Batch(category: category, paths: paths))
        }
        return FolderMixIngestTask(batches: batches, categoriesNotBuilt: notBuilt)
    }

    /// 把"入库 + 解析"的结果折成最终行集合（G1–G3、G5）。
    ///
    /// 替补**只走 `FolderMixPicker.substitute` 那一颗**：它已经管着"同类别内换、换完仍行内
    /// 不撞身份、签名未被发出过、重新 `encode` 序号"四件事。这里若自己再写一份"挑一条可用的"，
    /// 等于把同一条规则抄第二遍 —— 那正是守卫 G-i/G-j 一直在防的形态（两份会漂）。
    ///
    /// 代价上界：每行每个坏格一次 `substitute`，不递归回溯 ⇒ O(行数 × 类别数)，
    /// 不会出现"为了凑满一条而重跑整批"的组合爆炸。
    public static func resolve<R: FolderMixRandom>(rows: [FolderMixComboRow],
                                                  candidatesByCategory: [String: [FolderMixCandidate]],
                                                  resolution: [String: FolderMixResolution],
                                                  space: FolderMixComboSpace,
                                                  ledger: FolderMixComboLedger,
                                                  rng: inout R) -> FolderMixGenerateOutcome {
        // **只有解析成功（库里有一条覆盖整片的段）的键才算可用**。
        // 没出现在 `resolution` 里的键一律当不可用：懒入库下这份账的覆盖面就是"抽中集 ∪ 余量"，
        // 缺项意味着"根本没入库/没解析成"，把它当可用 = 建出来的方案指向一个库里不存在的段
        // （那正是导出侧静默丢段的形状）。
        let usableKeys = Set(resolution.values.filter { $0.isUsable }.map(\.identityKey))
        let unusable = Set(candidatesByCategory.values.flatMap { $0 }.map(\.identityKey))
            .subtracting(usableKeys)
        // working = 已发出的 ∪ 本批已留下的 ⇒ 替补既要避开上一批，也要避开同批另一行
        var working = ledger
        var kept: [FolderMixComboRow] = []
        var shortfalls: [FolderMixShortfall] = []
        var substitutions = 0

        for row in rows {
            var current = row
            var broken = current.picks.filter { unusable.contains($0.identityKey) }
            if let clash = clashedCell(in: current.picks) {              // 档 C
                broken.append(clash)
            }
            for category in Set(broken.map(\.category)).sorted() {
                if let next = FolderMixPicker.substitute(row: current, category: category,
                                                         unusableKeys: unusable,
                                                         candidatesByCategory: candidatesByCategory,
                                                         space: space, ledger: working, rng: &rng) {
                    current = next
                    substitutions += 1
                }
            }

            let stillUnusable = current.picks.filter { unusable.contains($0.identityKey) }
            let stillClashing = clashedCell(in: current.picks)
            if !stillUnusable.isEmpty || stillClashing != nil {
                let code = stillUnusable.first.flatMap { resolution[$0.identityKey]?.failureCode } ?? .other
                let categories = stillUnusable.map(\.category) + [stillClashing].compactMap { $0?.category }
                shortfalls.append(FolderMixShortfall(
                    requestedIndex: row.ordinal,
                    reason: stillUnusable.isEmpty
                        ? "这一行里两段指向同一素材，同类别内已无可换的新素材（档 C）"
                        : "\(code.shortfallText)，同类别内已无可换的新素材（档 \(code.rawValue)）",
                    categories: Set(categories).sorted()))
                continue
            }
            if working.contains(signature: current.signature) {
                shortfalls.append(FolderMixShortfall(
                    requestedIndex: row.ordinal,
                    reason: "替补出来的组合与已发出的重复（本批内也不许重一条）",
                    categories: Set(broken.map(\.category)).sorted()))
                continue
            }
            _ = working.commit(signature: current.signature)
            kept.append(current)
        }
        return FolderMixGenerateOutcome(rows: kept, shortfalls: shortfalls,
                                       systemicAbort: nil,
                                       substitutionCount: substitutions)
    }

    /// 行内撞身份：返回**第二次**出现那个身份键的那一格（第一次留用）。
    private static func clashedCell(in picks: [FolderMixCandidate]) -> FolderMixCandidate? {
        var seen = Set<String>()
        for pick in picks where !seen.insert(pick.identityKey).inserted { return pick }
        return nil
    }


    /// 环境级失败短路（计划 D 段第 2 条）：连续同因 ≥ `FolderMixLimits.systemicFailureStreak`
    /// 就先停整批，不再替补。磁盘满 / 无权限是**环境**问题，逐条重试只会把 IO 与时间烧光，
    /// 并把同一句错误报 N 遍。
    public struct FailureLedger: Equatable, Sendable {
        private var streak: Int = 0
        private var lastCode: FolderMixFailureCode?
        public private(set) var abortCode: FolderMixFailureCode?

        public init() {}

        /// 记一条失败，返回"这一刻是否已经该短路"。
        public mutating func note(_ code: FolderMixFailureCode,
                                 threshold: Int = FolderMixLimits.systemicFailureStreak) -> Bool {
            guard abortCode == nil else { return true }
            streak = (code == lastCode) ? streak + 1 : 1
            lastCode = code
            if code.isSystemic, streak >= threshold {
                abortCode = code
                return true
            }
            return false
        }
    }
}

// MARK: - 与库对接：入库当场交回的对应关系（计划 2026-10-22 决议 J1 / J2 / J6）

// ============================================================================
// 为什么这里要一张"对应关系"表，而不是拿任何一颗键去库里反查
//
// 上一版的错：混剪用**素材目录里的绝对路径**去查 `Video.localPath`，而那一行的路径是
// 拷贝落地的 `<应用程序支持>/videos/<内容校验和>/<文件名>` —— 一颗键跨了两个域，永不相交。
// 于是真机 50 条全被摘掉，红字还指着"入库失败"（那次入库失败数是 0）。
//
// 这一版不再猜：**入库的那一刻，"哪个源文件落进哪一行"是调用方已经知道的事实**
// （`ClipIngestService.importOrLink` 两支都返回行对象），所以让它把这张表交回来。
// 表里的键自始至终活在候选自己那个域里 ⇒ 跨域比对没有存在的余地。
// 这也是 ORP 里的 Identity Field 模式：身份靠携带，不靠派生属性反查。
//
// 生效条件：每条候选在解析之前必然已经过入库那一趟（App 侧 `generate()` 的批次循环）。
// 拦不住什么：
//   · 拦不住将来出现"不入库、直接引用外部文件"的第三条通路 —— 那时这张表是空的，
//     每条都会落 `.notIngested`。**证伪读数**：日志里「交回 N」与「候选总数」对不上
//     而入库又报成功，就是这条不变式被破，不再是"某条素材没进去"。
//   · 拦不住调用方把表填错（拿名字、拿 localPath 去凑）—— JOIN-7 那条腿钉的就是这个形状。
// 最坏代价：整批被判成"入库后没找到"，错误落在最表层、离真因最远 ⇒ 所以那颗码是专属的
//   `.notIngested` 而不是复用 `.ingestFailed`，且计数逐个报出来（不靠一句"失败"糊过去）。
// 为什么这些逻辑在 Core：`FolderMixViewModel` 在 App target，`swift test` 编不到它 ——
//   这次"1306 条判据全绿而真机第一步就废"的直接成因之一就是对接这件事从没进过判据层。
// ============================================================================

/// 入库当场交回的一条对应关系：这个源文件落进了库里哪一行。
///
/// 记的是**行 id**，不是段 id —— "哪条段覆盖整片"由 `WholeClipShape` 现判（决议 J6：
/// 入库服务不兼职判段，否则 D25「绝不替解析不到的素材补建整片段」那条门要搬进服务重开）。
public struct FolderMixIngestedRow: Equatable, Hashable, Sendable {
    /// 素材目录里的绝对路径，与 `FolderMixCandidate.path` 同源同形
    public let sourcePath: String
    /// 库里那一行的持久 id。存 id 不存对象：预览与生成之间用户可能删素材，
    /// 持模型对象正是本仓「真删后读死对象」那一族崩溃的形状。
    public let videoID: UUID

    public init(sourcePath: String, videoID: UUID) {
        self.sourcePath = sourcePath
        self.videoID = videoID
    }
}

/// 那一行的可解析形状（由 App 层从 SwiftData 投影出来，Core 只认这两样）。
public struct FolderMixRowShape: Equatable, Sendable {
    public let videoID: UUID
    /// 覆盖整片那条段的 id；nil = 有行但没有整片段（档 B）
    public let wholeClipSegmentID: UUID?
    /// 库里那一行的 `localPath` 现在到底指不指得着一个读得动的文件（决议 K6）。
    ///
    /// ⚠ **必填、无默认值**（本仓「边界类型必须同形且必填」那条）：给个 `= true` 的默认，
    /// 就等于让"忘了查可用性"静默变成"文件都还在" —— 那正是这次要消灭的静默坏方案形状。
    public let filePresent: Bool

    public init(videoID: UUID, wholeClipSegmentID: UUID?, filePresent: Bool) {
        self.videoID = videoID
        self.wholeClipSegmentID = wholeClipSegmentID
        self.filePresent = filePresent
    }
}

/// 对接结果 + **六个计数**。
///
/// 计数不是装饰：界面的聚合红字（决议 J5）与那行 `[FolderMix] 对接：…` 日志都吃它，
/// 真机三条腿的判据物也是它。没有读数就只有"肉眼数方案"—— 那正是这次缺陷能藏住的原因之一。
public struct FolderMixJoinOutcome: Equatable, Sendable {
    /// 交回里有这行、但库内文件已不在盘上的候选数（档 B0，决议 K6）
    public let missingFileCount: Int
    /// 键（`identityKey`）→ 可用性，直接喂 `FolderMixGeneratePlanner.resolve`
    public let resolution: [String: FolderMixResolution]
    /// 键 → 段 id：建方案前唯一的桥（键与上面同源，所以两张表不会漂）
    public let segmentIDByKey: [String: UUID]
    /// 服务交回了几条（原样计数，不去重）
    public let ingestedCount: Int
    /// 命中且拿到段 id 的候选数
    public let hitCount: Int
    public let noWholeClipCount: Int
    public let failedIngestCount: Int
    public let notIngestedCount: Int
    /// 同一颗源路径被交回了几次（重试 / 双批）。>0 不代表出错，但必须看得见
    public let duplicateIngestCount: Int
}

public enum FolderMixLibraryJoin {

    /// 把「每类别的候选」与「入库交回的对应关系 + 行形状」折成 resolution 与 键→段 id。
    ///
    /// 未命中时的档位判定顺序（决议 J4，一档一码）：
    ///   ① 交回里有这颗路径 + 形状有段 ⇒ 可用；
    ///   ② 交回里有这颗路径 + 形状没段 ⇒ `.noWholeClipSegment`（档 B，**不许**报"入库失败"）；
    ///   ③ 交回里没有 + 该路径带入库失败码 ⇒ 用那颗码（档 A 族，环境级的照旧可短路）；
    ///   ④ 整批已中止（`batchAbortCode` 非空）⇒ 用中止码，**不许**逐条谎报"入库后没找到"
    ///      （TC-J7：磁盘预检没过时，屏幕上应该是"磁盘不足"，而不是 50 条"没找到"）；
    ///   ⑤ 其余 ⇒ `.notIngested`。
    ///
    /// ①②③④⑤ 这个顺序本身是判据：把 ④⑤ 调过来，磁盘满那一跑就会把整批归因到"素材不见了"。
    public static func resolve(candidatesByCategory: [String: [FolderMixCandidate]],
                               ingested: [FolderMixIngestedRow],
                               shapes: [UUID: FolderMixRowShape],
                               failureCodeBySourcePath: [String: FolderMixFailureCode],
                               batchAbortCode: FolderMixFailureCode? = nil) -> FolderMixJoinOutcome {
        // 同一颗路径被交回多次时取**第一条有整片段形状的那份**；一条都没形状就退回第一条。
        // 为什么不是"最后写的那条"：那会让结果跟着数组顺序漂（本仓在 `libraryRecords` 里
        // 早就为同样的历史脏数据写过这条口径 —— 两份实现必须同形）。
        var chosenByPath: [String: UUID] = [:]
        var duplicates = 0
        for row in ingested {
            if let picked = chosenByPath[row.sourcePath] {
                duplicates += 1
                // 只在"已选的那条没形状、这条有"时升级 ⇒ 结果不随交回顺序漂
                if shapes[picked]?.wholeClipSegmentID == nil,
                   shapes[row.videoID]?.wholeClipSegmentID != nil {
                    chosenByPath[row.sourcePath] = row.videoID
                }
                continue
            }
            chosenByPath[row.sourcePath] = row.videoID
        }

        var resolution: [String: FolderMixResolution] = [:]
        var segmentIDByKey: [String: UUID] = [:]
        var hit = 0, noWholeClip = 0, failedIngest = 0, notIngested = 0, missingFile = 0

        for group in candidatesByCategory.values {
            for candidate in group {
                let key = candidate.identityKey
                if let videoID = chosenByPath[candidate.path] {
                    // **缺失档排在"无整片段"之前**（先因先报，决议 K7）：文件都没了的时候，
                    // 那句「没有覆盖整片的段」是事实但会把人引去查分镜导入通路 —— 上一轮
                    // 「素材入库失败」那句归因错位就是同一族事故。
                    if shapes[videoID]?.filePresent == false {
                        resolution[key] = .failed(key, .materialMissing)
                        missingFile += 1
                        continue
                    }
                    if let segmentID = shapes[videoID]?.wholeClipSegmentID {
                        resolution[key] = .usable(key)
                        segmentIDByKey[key] = segmentID
                        hit += 1
                    } else {
                        resolution[key] = .failed(key, .noWholeClipSegment)
                        noWholeClip += 1
                    }
                    continue
                }
                if let code = failureCodeBySourcePath[candidate.path] {
                    resolution[key] = .failed(key, code)
                    failedIngest += 1
                    continue
                }
                if let abort = batchAbortCode {
                    resolution[key] = .failed(key, abort)
                    failedIngest += 1
                    continue
                }
                resolution[key] = .failed(key, .notIngested)
                notIngested += 1
            }
        }
        return FolderMixJoinOutcome(missingFileCount: missingFile,
                                    resolution: resolution, segmentIDByKey: segmentIDByKey,
                                    ingestedCount: ingested.count, hitCount: hit,
                                    noWholeClipCount: noWholeClip, failedIngestCount: failedIngest,
                                    notIngestedCount: notIngested, duplicateIngestCount: duplicates)
    }
}
