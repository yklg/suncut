import Foundation

// ============================================================================
// 文件夹混剪的「两层解析」—— 时长与素材身份都先问库里那份，问不到才读盘（D33）。
//
// 为什么这层必须在 Core：这是本轮唯一一处"看起来像优化、其实是口径"的判定 ——
//   ① `Video.duration` 是非可选 Double、初始化给 0，所以库里那份**永远拿不出 nil**；
//      把 0 直接当时长用 = 把"没算过"伪装成"这个素材正好 0 秒"，而 0 在磁盘预算的式子里
//      是**免费额度**（决定 6 要在数据层兑现的就是这一格，不是界面文案）。
//   ② `Video.contentHash` 已经存着、也已经用于全局去重，"精确识别"若一上来就现算校验和，
//      等于把已在库素材算第二遍（≈8 MB/条的读盘白付）。
// 这两条判定都是纯函数，`swift test` 编得到 ⇒ 判据（FMX-14/15/16）落在 U 层，
// 不靠真机目测。IO（`AVURLAsset` / 校验和 / SwiftData 取数）留在 App 层的两颗 reader 里。
//
// 生效条件：调用方把库里读数按 `FolderMixLibraryRecord` 的形状喂进来。
// 拦不住什么：
//   · 拦不住"库里那份本身是错的"—— 这里只信 `Video` 上已有的两列，不复核；
//   · 拦不住 App 层不去问第一层、直接读盘 —— 那由 FMX-14 的探针计数判据与源码扫描腿钉，
//     不由本文件钉（本文件不知道有几趟盘在被读）；
//   · 拦不住 revision 校验被绕过 —— 见 `applyDurations` 的负腿判据。
// 最坏代价：如果第二层被无脑当成默认路径，扫描一个大目录的成本是
//   「未入库文件数 × 一次 AVFoundation 解析」＋（精确档）「× 读头尾各 4 MB」，
//   这正是本文件存在的理由 —— 让"要不要付这笔"变成一个可以判据化的分支。
//
// 规则（台账第九节 / 计划 C 段）：
//   L1 库里那份命中优先：`duration > 0` 或 `contentHash != nil` 才算命中；0 与 nil 都是"没有"。
//   L2 未命中的才排进探针队列，且受 `FolderMixLimits.durationProbeBudgetFiles` 预算约束；
//      排不进的不报错、也不当 0 —— 留 nil，界面显示「—」并逐名计数。
//   L3 异步回填必须带 revision 校验：旧一轮目录的探针结果不许写进新一轮的账（FMX-16）。
//   L4 身份键：默认档 = 路径（零等待，代价是跨目录同内容算两个）；
//      精确档 = 内容校验和（库里那份优先）， radix 因此**不因跨目录重复而变小** ——
//      一个文件只有一个父目录，精确识别真正改变的是"同一行不许重复用同一素材"（失败档 C）。
// ============================================================================

/// 一条素材在**库里已经算好的那份**读数（第一层的全部输入）。
///
/// 为什么不直接收 `Video`：那会把 SwiftData 的模型类型带进 Core（`swift test` 就编不动了），
/// 也让这层"只知道两列"的边界变成"整个模型都能读"。
public struct FolderMixLibraryRecord: Equatable, Sendable {
    /// `Video.contentHash`。nil = 库里没算过（旧数据，或当初校验和算不出来被拒）。
    public let contentHash: String?
    /// `Video.duration`，秒。**非可选**：库里那份给不出"不知道"，只给得出 0 ——
    /// 0 的含义由 L1 解释成"没算过"，不是"这个素材 0 秒"。
    public let durationSeconds: Double

    public init(contentHash: String?, durationSeconds: Double) {
        self.contentHash = contentHash
        self.durationSeconds = durationSeconds
    }
}

public enum FolderMixLibrary {

    /// 第一层的时长读数（L1）：只有 `> 0` 才算命中，否则返回 nil 让调用方去付第二层。
    ///
    /// 写成函数而不是 `record.durationSeconds` 直取，是为了让"0 不是有效值"这件事
    /// 只在这里判一次（守卫 G-c 的同一口径：资格判定不许长两处）。
    public static func duration(of record: FolderMixLibraryRecord?) -> Double? {
        guard let record, record.durationSeconds > 0 else { return nil }
        return record.durationSeconds
    }

    /// 第一层的内容身份：库里那份 hash 命中就零成本复用，没命中返回 nil（由第二层现算）。
    public static func storedContentHash(of record: FolderMixLibraryRecord?) -> String? {
        guard let hash = record?.contentHash, !hash.isEmpty else { return nil }
        return hash
    }

    /// 素材身份键（L4）。
    ///
    /// 为什么默认档是路径而不是 hash：hash 是"读过盘才知道"的东西，而懒入库要求
    /// 选完目录就能立刻算出组合总数 —— 用路径当键 ⇒ 扫描期一次盘都不用多开。
    /// 代价写在台账第十一节：外接盘重新挂载点一变，全部键都变 ⇒ revision 变 ⇒ 预览作废。
    public static func identityKey(of record: FolderMixLibraryRecord?, path: String,
                                   preciseIdentity: Bool, computedHash: String? = nil) -> String {
        guard preciseIdentity else { return path }
        return storedContentHash(of: record) ?? computedHash ?? path
    }
}

/// 「还得读哪些盘」的计划 —— 纯函数，所以"库里命中 ⇒ 一次盘都不读"能被钉死（FMX-14）。
public struct FolderMixProbePlan: Equatable, Sendable {
    /// 需要在第二层读时长的路径（未命中第一层的那批，已按预算截断）
    public let durationProbePaths: [String]
    /// 超预算没排上的路径（L2：留 nil、界面显示「—」，不报错也不当 0）
    public let deferredDurationPaths: [String]
    /// 需要现算校验和的路径（**只有精确档非空**；默认档一次都不该有）
    public let identityProbePaths: [String]
    /// 第一层命中数（界面据此写「库里已有 X 条｜需新算 Y 条」，把开关的收益做成看得见）
    public let libraryDurationHits: Int
    public let libraryIdentityHits: Int

    /// 探针总次数 —— FMX-14 断言"全在库 ⇒ 0"用的就是这颗。
    public var totalProbeCount: Int { durationProbePaths.count + identityProbePaths.count }
}

/// 一条待解析的文件读数（IO 层给什么这里收什么，不带模型对象）。
public struct FolderMixFileEntry: Equatable, Sendable {
    /// 绝对路径（默认档的身份键载体）
    public let path: String
    public let byteSize: Int64?

    public init(path: String, byteSize: Int64? = nil) {
        self.path = path
        self.byteSize = byteSize
    }
}

public enum FolderMixResolver {

    /// 出计划：把"哪些还得读盘"从"读了再说"变成"先算出来"。
    ///
    /// 为什么要单独一步而不是直接在 reader 里边读边判：预算（L2）与"第一层命中就跳过"
    /// 这两条判定必须可测，而它们一旦长在 IO 里，`swift test` 就看不见它们了。
    public static func plan(files: [FolderMixFileEntry],
                            library: [String: FolderMixLibraryRecord],
                            preciseIdentity: Bool,
                            durationBudget: Int) -> FolderMixProbePlan {
        var durationHits = 0
        var identityHits = 0
        var needDuration: [String] = []
        var needIdentity: [String] = []

        for file in files {
            let record = library[file.path]
            if FolderMixLibrary.duration(of: record) != nil {
                durationHits += 1
            } else {
                needDuration.append(file.path)
            }
            if preciseIdentity {
                // L4：精确档才问身份；库里那份 hash 命中即零成本
                if FolderMixLibrary.storedContentHash(of: record) != nil {
                    identityHits += 1
                } else {
                    needIdentity.append(file.path)
                }
            }
        }
        // 预算按输入顺序截：探针是后台渐进回填，先扫到的先补 —— 顺序稳定，界面上
        // 「—」变数字的过程才可复现（同 R1 的道理，不靠"反正随机"）。
        let budget = max(0, durationBudget)
        let within = Array(needDuration.prefix(budget))
        return FolderMixProbePlan(durationProbePaths: within,
                                  deferredDurationPaths: Array(needDuration.dropFirst(within.count)),
                                  identityProbePaths: needIdentity,
                                  libraryDurationHits: durationHits,
                                  libraryIdentityHits: identityHits)
    }

    /// 异步回填的时效闸（L3）。
    ///
    /// 返回 nil = 这批结果作废（一轮探针在路上时用户换了目录 / 切了精确识别开关）。
    /// 为什么做成纯函数：把"旧任务不许写新账"做成能直接喂假 revision 的判据，
    /// 而不是让它在真机上靠时序碰 —— 时序判据在 CI 里永远绿。
    /// 为什么 revision 是泛型：Core 不该规定这颗数的形态（判据里用 Int 好写，
    /// 真链路上 `FolderMixSpaceFingerprint` 给的是字符串指纹），而"相等与否"这条规则只有一份。
    public static func applyDurations<Revision: Hashable>(_ probed: [String: Double?],
                                                          startedRevision: Revision,
                                                          currentRevision: Revision) -> [String: Double?]? {
        guard startedRevision == currentRevision else { return nil }
        return probed
    }

    /// 把回填结果并进既有账本：只补缺口 —— 已有读数不被覆盖，也不把 nil 折成 0。
    ///
    /// "读不出"要**显式记成 nil**（键存在、值为 nil），不是"这个键没出现过"：
    /// 前者表示"探过了、这条给不出时长"，下一轮可以不再为它发探针；后者会被误当成
    /// "还没探"而每轮重跑。界面对两者的显示也不同（「—」 vs 还在补数中的空位）。
    public static func mergedDurations(current: [String: Double?],
                                       incoming: [String: Double?]) -> [String: Double?] {
        var out = current
        for (path, value) in incoming where out[path] == nil || out[path]! == nil {
            out[path] = value
        }
        return out
    }
}

// MARK: - 扫描期第一层的"名字启发式"（计划 2026-10-22 决议 J3：只服务预估，不进正确性）

// ============================================================================
// 为什么这里必须按名字**猜**，而且猜错不算缺陷：
//   扫描发生在入库之前 —— 此刻手上只有文件系统里的路径与文件名，库里那一行没有任何
//   现成的对应关系可用（真正精确的那张表在生成期由 `FolderMixLibraryJoin` 拿，
//   那里是"入库当场交回"，没有猜）。这层的唯一用途是**给用户报代价**：
//   「这条大概不用新算，库里那份时长是现成的」。
//
// 生效条件：只在扫描期用；产物喂给 `FolderMixResolver.plan` 的第一层输入。
// 拦不住什么：拦不住调用方把这层的产物拿去做出片判定 —— 所以它**故意不返回任何 id**，
//   拿它没法拼出一条方案（形状本身就是边界）。
// 最坏代价：猜不中 ⇒ 多读一次容器头（正确但慢）；猜错⇒**不会**，因为同名多行整条不采信。
//
// 规则：
//   H1 相等口径就是 Swift 的字符串相等（按 Unicode 标准等价 ⇒ 正规化差异天然被吸收，
//      实测由 TC-J4 钉住），但**不做大小写折叠**：折叠过一次，两颗不同的素材就会并成
//      一行读数，那正是"替错素材"的形状（TC-J5 钉）。
//   H2 同一名字在库里有多行 ⇒ 这个名字**一条都不采信**（记进 ambiguousNames），退回探针。
//   H3 认不出不报错：进 missedPaths，由第二层照常读盘。
// ============================================================================

/// 扫描到的一个文件在名字轴上的投影（路径 + 文件名）。
public struct FolderMixScannedFile: Equatable, Sendable {
    public let path: String
    public let name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// 库里那一行在名字轴上的投影。**没有 id、没有路径** —— 这层的产物不该有资格拼方案。
public struct FolderMixLibraryNameRow: Equatable, Sendable {
    public let videoName: String
    public let record: FolderMixLibraryRecord

    public init(videoName: String, record: FolderMixLibraryRecord) {
        self.videoName = videoName
        self.record = record
    }
}

public enum FolderMixNameHeuristic {

    public struct Outcome: Equatable, Sendable {
        /// 猜中的那批：扫描路径 → 库里已算好的那份读数（只含同名唯一的）
        public let libraryByPath: [String: FolderMixLibraryRecord]
        /// 库里同名多行 ⇒ 整条不采信的名字（界面要单报，别让用户以为是"没找到"）
        public let ambiguousNames: [String]
        /// 认不出的扫描路径（退探针）
        public let missedPaths: [String]

        public var hitCount: Int { libraryByPath.count }
        public var ambiguousCount: Int { ambiguousNames.count }
    }

    /// H1–H3。做成纯函数的理由和这层其余判定一样：长在 IO 里 `swift test` 就看不见它。
    public static func guess(files: [FolderMixScannedFile],
                             libraryRows: [FolderMixLibraryNameRow]) -> Outcome {
        var rowsByName: [String: [FolderMixLibraryRecord]] = [:]
        for row in libraryRows { rowsByName[row.videoName, default: []].append(row.record) }

        var byPath: [String: FolderMixLibraryRecord] = [:]
        var ambiguous: Set<String> = []
        var missed: [String] = []
        for file in files {
            guard let candidates = rowsByName[file.name] else {
                missed.append(file.path)
                continue
            }
            guard candidates.count == 1 else {          // H2：同名多行一条都不采信
                ambiguous.insert(file.name)
                missed.append(file.path)
                continue
            }
            byPath[file.path] = candidates[0]
        }
        return Outcome(libraryByPath: byPath,
                       ambiguousNames: ambiguous.sorted(),
                       missedPaths: missed)
    }
}
