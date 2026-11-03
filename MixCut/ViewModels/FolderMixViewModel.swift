import Foundation
import Observation
import SwiftData

/// 文件夹混剪的编排层（计划 Step 5）。
///
/// 职责边界（守卫 G-c：判定不许出现在这里）：
///   - **不判定**：类别归一/扩展名/择片/上限/磁盘公式全在 Core
///     （`FolderMixScanner` / `FolderMixPicker` / `DiskSpaceBudget` / `WholeClipShape`）；
///   - **只编排**：扫描（只读盘）→ 两层解析回填时长/身份 → 抽片（组合级不重复，D23）→
///     生成时才建库入库（D25/D26，走 `ClipIngestService` 而非 `importVM`）→ 建 N 个方案（D10/D11）；
///   - **只有这一处** 拿用户选的目录当真相。
///
/// 会话状态（D3 的作用域）：`used` 只活在内存里、**不落 UserDefaults** ⇒ App 重启即失效。
/// 所以界面上的话必须写「本次会话内不回放」，不写无条件承诺（计划 R7 就是从预览件里抓到这句话说过头）。
@MainActor
@Observable
final class FolderMixViewModel {

    // MARK: 输入面
    /// 用户选的素材根目录（一级子目录 = 类别，D1/D2）
    var rootURL: URL?
    /// 素材来源（D20/D21）：**没有默认值可退**。未选 ⇒ 「生成方案」禁用。
    var source: SegmentSource?
    /// 用户排好的类别顺序 —— 这个顺序就是拼接顺序（D4：整片按排列顺序拼）
    var orderedCategories: [String] = []
    /// **参与集**（D29 左栏勾选轴）：没勾上的类别不进乘积、不出现在 picks。
    /// 默认全勾（除空类，见 `syncEnabledWithScan`）—— 空类不占额度（R4）。
    private(set) var enabledCategories: Set<String> = []
    /// 一次出几条（D16）。**钳位写在 setter 里，全仓只有这一处**：
    /// 界面对它同时有两条写入路径 —— Stepper 的 `stepRowCount` 与 `TextField(value:format:.number)`
    /// 直接键入。只在其中一条钳 = 另一条可以键进 999999999（G-c 拦的就是这种"判定长两处"）。
    var rowCount: Int {
        get { _rowCount }
        set {
            _rowCount = min(max(newValue, FolderMixLimits.countInputClamp.lowerBound),
                            FolderMixLimits.countInputClamp.upperBound)
        }
    }
    private var _rowCount = 1
    /// 当前翻页停在第几条（A11）
    var rowIndex: Int = 1
    /// 软上限（D24）：越过它只警告 + 要确认，不当硬墙。
    var softLimit: Int = FolderMixLimits.defaultSoftLimit
    /// 「我已确认」——超软上限时主按钮的唯一放行口。
    var overLimitConfirmed = false
    /// 「生成前先预览」（D27）
    var previewFirst = true
    /// 「精确识别（慢）」（D31）
    var preciseIdentity = false

    // MARK: 扫描与入库读数
    private(set) var scan: FolderMixScanResult?
    private(set) var rejections: [MaterialFolderRejection] = []
    private(set) var nestedFolderNames: [String] = []
    private(set) var scanError: String?
    private(set) var ingestFailures: [(name: String, reason: String)] = []
    /// **候选的唯一来源 = 文件系统投影**（D25 懒入库）。
    ///
    /// 为什么不是"入库后的 Segment"（上一版的做法）：那要求"先点入库才有候选"，
    /// 而入库会把整目录拷一遍 —— 用户要的正是"选完目录就看到视频、按排列组合出条数"。
    /// 这里只存盘上事实（类别 / 名字 / 路径 / 字节数），时长与身份键由 `candidatesByCategory`
    /// 现拼 —— **没有第二条账本**，所以"入库中止把左栏全变无候选"那个 bug 在这个形状里写不出来
    /// （上一版是靠 T-22 盯一句赋值语句，现在是类型上不存在那句赋值）。
    private struct MaterialEntry {
        let category: String
        let name: String
        let path: String
        let byteSize: Int64?
    }
    private var materials: [MaterialEntry] = []
    /// 第一层读数：库里已算好的 `duration` / `contentHash`（零成本那份）。
    ///
    /// ⚠ 这层的键是**按文件名猜出来的**（决议 J3）：扫描发生在入库之前，那一刻手上没有
    /// 对应关系。所以它**只服务磁盘与耗时预估**，不参与出片正确性 —— 正确性走 `generate()`
    /// 里入库当场交回的那张表（`FolderMixLibraryJoin`），那里没有猜。
    /// 猜不中的代价是多读一次容器头（正确但慢）；同名多行整条不采信（Core 的 H2）。
    private var libraryByPath: [String: FolderMixLibraryRecord] = [:]
    /// 同名多行、因而一条都没采信的名字数（界面要单报，别让用户以为是"库里没有"）。
    private(set) var nameAmbiguityCount = 0
    /// 第二层回填的时长（键 = 路径）。nil = 读过但读不出 ⇒ 界面显示「—」，不许当 0 秒。
    private var probedDurationByPath: [String: Double?] = [:]
    /// 「精确识别（慢）」打开时，哈希定型后才写入这里；未定型的候选退回用路径当键。
    private var identityKeyByPath: [String: String] = [:]
    /// 还没算完校验和的路径。非空 ⇒ **不许抽片**（键还在漂，抽出来的组合下一毫秒就换义）。
    private(set) var pendingIdentityPaths: [String] = []
    private var probeGate = BoundedTaskGate(maxConcurrent: 1)
    private var probeTask: Task<Void, Never>?

    /// 候选视图 = 文件投影 ×（库内已算好的那份 ?? 后台回填的那份）。
    /// 时长与身份键都在这里一次性算出，别处不再各存一份（归属表第 1 行）。
    private(set) var candidatesByCategory: [String: [FolderMixCandidate]] = [:]

    private(set) var isBusy = false   // 只在本类里写（含 `stop()`），界面只读
    private(set) var statusText = ""
    var errorMessage: String?
    private(set) var createdSchemeNames: [String] = []
    /// 上一次生成的方案落在哪个项目（界面上的「去看方案」按钮据此导航，见 `openSummaryProject`）
    private(set) var lastSummaryProjectID: UUID?
    private(set) var lastSummaryProjectName: String?

    // MARK: 抽片结果
    private(set) var rows: [FolderMixComboRow] = []
    /// 本轮预览被摘掉的行（计划 60 / 实得 M 的那份"实得"差额，逐条带原因）。
    private(set) var droppedRows: [FolderMixShortfall] = []
    /// 会话内"已发出"的唯一记录（D23）。**只有 `generate()` 成功路径写它** ——
    /// 预览、失败、停止都不写（FMX-07 钉这条）。
    private var ledger = FolderMixComboLedger()

    /// 会话种子的可读形态：报障时把它连同 seed 一起要回来，就能在本机复现用户那一屏。
    private(set) var sessionSeed: UInt64 = 0
    private var rng = SplitMix64(seed: 0)
    /// 候选键 → Segment 的持久 id。方案创建时**按 id 重新解析**，不持有模型对象 ——
    /// 预览与确认之间用户可能删掉素材，那正是本仓「真删后读死对象」那一族崩溃的形状。
    private var segmentIDByKey: [String: UUID] = [:]

    /// 汇总项目名（D10：`MixScheme.project` 是单值，N 条方案要落在同一个项目里）。
    static let summaryProjectName = "文件夹混剪"

    init() { reseed() }

    // MARK: - 种子

    /// 会话种子取自**挂钟**，不是 `SystemRandomNumberGenerator`（守卫 G-a）。
    /// 理由：抽片必须"给定 seed 逐字可复现"（R1），所以仓里不许长出第二个真随机源；
    /// 而"每次打开这一页想看到不同组合"只需要 seed 每轮不同 —— 时间戳够用了，
    /// 并且它是**可日志化的数**：用户报障时把这一屏的 seed 报回来，我们能在本机重放同一批抽取。
    func reseed() {
        let seconds = max(0, Date().timeIntervalSince1970)
        sessionSeed = UInt64(seconds * 1_000_000)     // 微秒精度；UInt64 装得下（≈1.8e15）
        rng = SplitMix64(seed: sessionSeed)
        MixLog.info("[FolderMix] 会话 seed=\(sessionSeed)")
    }


    // MARK: - ⓪ 会话持久化（D28）—— 编解码在 Core，这里只把 JSON 塞进 UserDefaults

    /// 为什么状态不许留在页面自己的 `@State`：上一轮实测到"切到别的侧栏页再切回、
    /// 或重启 App 就整页销毁重建" ⇒ 回到「0 类 + 先选一个素材根目录」那屏
    /// （就是用户报的"入库后左侧啥也不是"）。现在状态住在这里 + 落一份 JSON。
    static let sessionDefaultsKey = "folderMix.session.v1"

    private func snapshot() -> FolderMixSessionState {
        FolderMixSessionState(rootPath: rootURL?.path,
                              orderedCategories: orderedCategories,
                              enabledCategories: Array(enabledCategories),
                              rowCount: rowCount, softLimit: softLimit,
                              previewFirst: previewFirst, preciseIdentity: preciseIdentity,
                              spaceRevision: spaceRevision,
                              rowOrdinals: rows.map(\.ordinal))
    }

    /// 每次改动都落一份。为什么不做节流：整颗 JSON 是几百字节级，
    /// 而"忘了落"的代价是用户切个页就丢勾选与条数 —— 方向明确，不必省这点写盘。
    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot()) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionDefaultsKey)
    }

    /// 打开这一页时还原：读状态 → 目录还在就自动重扫（懒入库下只是两层 `contentsOfDirectory`）→
    /// 指纹相符才把预览行按序号重建回来。
    ///
    /// 返回 false = 没有可还原的会话（或目录已失效），界面停在"先选一个素材根目录"。
    @discardableResult
    func restoreFromDisk(context: ModelContext) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionDefaultsKey),
              let saved = try? JSONDecoder().decode(FolderMixSessionState.self, from: data),
              let path = saved.rootPath else { return false }
        let url = URL(fileURLWithPath: path)
        rowCount = saved.clampedRowCount
        softLimit = saved.softLimit
        previewFirst = saved.previewFirst
        preciseIdentity = saved.preciseIdentity
        // 这里**不自己裸问一次 `fileExists`**：目录能不能读，唯一真源是 IO 面那颗
        // `MaterialFolderScanner`（它把读不动的原因报进 `rootError`）。全仓"裸问在不在"的站点
        // 由 `MediaAvailabilityGuardTests` G-M01 逐文件名册盯着，多一处就要改一次名册；
        // 而这颗本来也不该由 VM 自己问 —— 扫一次既知道在不在，也知道读不读得动。
        beginScan(root: url, context: context, preserveSelection: true)
        if let ioError = scanError {
            // 目录失效（外接盘被拔/改名/权限）：**保留用户的选择**，只出红字让他重选，
            // 不静默清状态 —— 清了等于把他的排列与勾选一起丢掉，而那与目录在不在无关。
            orderedCategories = saved.orderedCategories
            enabledCategories = Set(saved.enabledCategories)
            errorMessage = "素材目录读不到了：\(ioError)\n"
                + "你的类别顺序与勾选都还在，重选同一个目录就能接着用。"
            statusText = "目录失效，等待重新选择。"
            MixLog.error("[FolderMix] 还原失败：\(ioError)")
            return false
        }
        // 顺序按存档还原（用户排的序就是拼接顺序，不能退回扫描序）：存档里没有的新类别
        // 追加到末尾，已经消失的从勾选里剔掉**并说出来** —— 静默少一类 = 用户以为还是
        // 上一批的搭配，实际组合空间已经变了。
        let alive = Set(candidatesByCategory.keys)
        let allNames = scan?.categories.map(\.name) ?? []
        let restored = saved.orderedCategories.filter { alive.contains($0) }
        orderedCategories = restored + allNames.filter { !restored.contains($0) }
        enabledCategories = Set(saved.enabledCategories).intersection(alive)
        let missing = saved.enabledCategories.filter { !alive.contains($0) }
        if !missing.isEmpty {
            errorMessage = "这些类别在目录里已经不在了，未参与：\(missing.joined(separator: "、"))"
        }
        // 行只按**序号**重建：素材对象与路径都不持久化（真删后读死对象那一族崩溃的形状）。
        if let ordinals = saved.rehydratableOrdinals(nowRevision: spaceRevision) {
            let built = space
            let rebuilt = ordinals.compactMap { ordinal -> FolderMixComboRow? in
                FolderMixPicker.row(forOrdinal: ordinal, candidatesByCategory: candidatesByCategory,
                                    space: built)
            }
            if rebuilt.count == ordinals.count, !rebuilt.isEmpty {
                rows = rebuilt
                droppedRows = []
                rowIndex = 1
                statusText = "已还原上次的 \(rows.count) 条预览（目录内容没变）。"
                MixLog.info("[FolderMix] rehydrate 成功 rows=\(rows.count)")
            }
        } else {
            statusText = "目录内容或口径已变（组合空间换了一副），预览已作废，重新抽一次。"
        }
        return true
    }

    // MARK: - ① 扫描（只读盘：不建库、不拷盘、不跑缩略图 —— D25 懒入库）

    /// 扫根目录：一级子目录 → 类别 → 候选（文件系统投影）。
    ///
    /// 与上一版的根本差别是**这里不再要求"先入库所选类别"**。上一版把候选真源定成
    /// "入库后的 Segment"，于是"选完目录还看不到东西"，而用户要的是选完就识别；
    /// 拷盘被推迟到 `generate()`，且只拷真被抽中的那几条（FMX-18）。
    ///
    /// `context` 只用来读"库里已经算好的那两份"（`Video.duration` / `Video.contentHash`，
    /// D33 的第一层）：读列零成本，一条盘都不多开；命中不到的文件才排进后台探针。
    /// - Parameter preserveSelection: 还原会话时传 true —— 勾过哪些类是用户的选择，
    ///   重扫不该把它重置回"非空类默认全勾"。新选目录传 false（默认）。
    func beginScan(root: URL, context: ModelContext, preserveSelection: Bool = false) {
        rootURL = root
        isBusy = true
        defer { isBusy = false }
        stopProbes()

        let io = MaterialFolderScanner.scan(root: root)
        scanError = io.rootError
        rejections = io.rejected
        nestedFolderNames = io.nestedDirectoryNames

        let result = FolderMixScanner.scan(io.directories)
        scan = result
        // 排列默认 = 扫描顺序（Finder 口径的 localizedStandardCompare，见 MaterialFolderScanner）；
        // 空类别也进列表：D13 标灰但不阻断，用户看得见"为什么这一格是空的"。
        orderedCategories = result.categories.map(\.name)
        rowIndex = 1

        materials = result.categories.flatMap { category in
            category.videoFiles.map { file in
                MaterialEntry(category: category.name, name: file.name,
                              path: root.appendingPathComponent(file.folder)
                                  .appendingPathComponent(file.name).path,
                              byteSize: file.byteSize)
            }
        }
        let guess = FolderMixDurationReader.libraryGuess(
            files: materials.map { FolderMixScannedFile(path: $0.path, name: $0.name) },
            in: context)
        libraryByPath = guess.libraryByPath
        nameAmbiguityCount = guess.ambiguousCount
        probedDurationByPath = [:]
        identityKeyByPath = [:]
        rebuildCandidates()
        if preserveSelection {
            // 只把"已经不存在的类别"从勾选里摘掉（目录改名/删了），其余原样保留。
            let alive = Set(candidatesByCategory.keys)
            enabledCategories = enabledCategories.intersection(alive)
        } else {
            syncEnabledWithScan()
        }
        rows = []
        droppedRows = []

        let plan = FolderMixResolver.plan(
            files: materials.map { FolderMixFileEntry(path: $0.path, byteSize: $0.byteSize) },
            library: libraryByPath, preciseIdentity: preciseIdentity,
            durationBudget: FolderMixLimits.durationProbeBudgetFiles)
        // 精确档：哈希没定型之前**不许抽片**（键还在漂，抽出来的组合下一毫秒就换义了）。
        pendingIdentityPaths = plan.identityProbePaths
        startProbes(plan: plan)
        persist()

        statusText = result.categories.isEmpty
            ? "没找到一级子文件夹。这个目录里每个子文件夹就是一个类别。"
            : "识别到 \(result.categories.count) 个类别、\(result.totalVideoFiles) 个视频文件"
            + "（另有 \(result.totalRejectedFiles) 个文件不是可拼接的视频，未参选）"
            + probeCostNote(plan: plan)
        MixLog.info("[FolderMix] 扫描 \(root.lastPathComponent)：类别 \(result.categories.count)、"
                    + "拒绝目录 \(io.rejected.count)、未递归子夹 \(io.nestedDirectoryNames.count)、"
                    + "按名字认出已在库 \(plan.libraryDurationHits)、同名歧义 \(nameAmbiguityCount)、"
                    + "待探 \(plan.durationProbePaths.count)、待算校验和 \(plan.identityProbePaths.count)")
    }

    /// 代价读数（决定 8 的开关要有收益看得见，否则像摆设）。
    ///
    /// 措辞改口的理由（计划 2026-10-22）：上一版这里写「库里已有 X 条（零成本）」读起来像
    /// 确证，而那层其实一行都没命中（键跨了两个域）。现在时长那句**明写是按文件名认**，
    /// 歧义单独报出来，别混进"库里没有"；校验和那句是真确证（库里那列就是内容哈希）。
    private func probeCostNote(plan: FolderMixProbePlan) -> String {
        var notes: [String] = []
        if plan.libraryDurationHits > 0 || nameAmbiguityCount > 0
            || !plan.durationProbePaths.isEmpty || !plan.deferredDurationPaths.isEmpty {
            var line = "；时长：按文件名认出 \(plan.libraryDurationHits) 条已在库（零成本）"
            if nameAmbiguityCount > 0 {
                line += "、同名歧义 \(nameAmbiguityCount) 个名字退回探针"
            }
            line += "、需新算 \(plan.durationProbePaths.count) 条"
            if !plan.deferredDurationPaths.isEmpty {
                line += "、超预算 \(plan.deferredDurationPaths.count) 条本轮不算"
            }
            notes.append(line)
        }
        if !plan.identityProbePaths.isEmpty || preciseIdentity {
            notes.append("；校验和：库里已有 \(plan.libraryIdentityHits) 条（零成本），需新算 "
                + "\(plan.identityProbePaths.count) 条（每条约读 8 MB 头尾）")
        }
        return notes.joined()
    }

    /// 三张读数表 → 候选（全页**唯一**一处算 identityKey 与 duration 的地方）。
    private func rebuildCandidates() {
        var byCategory: [String: [FolderMixCandidate]] = [:]
        for entry in materials {
            let record = libraryByPath[entry.path]
            let key = FolderMixLibrary.identityKey(of: record, path: entry.path,
                                                   preciseIdentity: preciseIdentity,
                                                   computedHash: identityKeyByPath[entry.path])
            // 决定 6：库里那份是非可选 Double、默认 0 ⇒ 0 是"没算过"，不是"这个素材 0 秒"。
            // 折成 nil 才不会被磁盘预算当免费额度（FMX-15/B6 两头钉）。
            let duration = FolderMixLibrary.duration(of: record)
                ?? (probedDurationByPath[entry.path] ?? nil)
            byCategory[entry.category, default: []].append(
                FolderMixCandidate(identityKey: key, category: entry.category, name: entry.name,
                                   path: entry.path, duration: duration, byteSize: entry.byteSize))
        }
        candidatesByCategory = byCategory
    }

    /// 后台渐进回填：时长先补，精确档再补校验和。两条流共用一颗闸（颗数走 ConcurrencyPolicy）。
    private func startProbes(plan: FolderMixProbePlan) {
        guard !plan.durationProbePaths.isEmpty || !plan.identityProbePaths.isEmpty else { return }
        let started = spaceRevision
        probeGate = BoundedTaskGate(maxConcurrent: ConcurrencyPolicy.maxProbeConcurrency())
        let gate = probeGate
        probeTask = Task { [weak self] in
            for await reading in FolderMixDurationReader.readings(
                paths: plan.durationProbePaths, gate: gate,
                probe: FolderMixDurationReader.assetDuration) {
                guard let self, !Task.isCancelled else { return }
                // L3：旧一轮目录/旧开关的探针结果不许写进新一轮的账
                guard let fresh = FolderMixResolver.applyDurations([reading.path: reading.seconds],
                                                                   startedRevision: started,
                                                                   currentRevision: self.spaceRevision)
                else { return }
                self.probedDurationByPath = FolderMixResolver.mergedDurations(
                    current: self.probedDurationByPath, incoming: fresh)
                self.rebuildCandidates()
            }
            guard !Task.isCancelled else { return }
            for await hashed in FolderMixContentKeyReader.readings(
                paths: plan.identityProbePaths, gate: gate,
                compute: ClipIngestService.computeFileHash) {
                guard let self, !Task.isCancelled else { return }
                if let hash = hashed.hash, !hash.isEmpty {
                    self.identityKeyByPath[hashed.path] = hash
                } else {
                    // 读不出校验和 ⇒ 记一个**专属**键，不让它退回路径：
                    // 退回路径会让这一颗在精确档里与另一颗同内容素材并成一键，
                    // 用户以为开关生效了，实际那一格是猜的。
                    self.identityKeyByPath[hashed.path] = "unreadable:" + hashed.path
                    MixLog.info("[FolderMix] 校验和读不出，这一颗独占一键（不与任何素材归并）：\(hashed.path)")
                }
                self.pendingIdentityPaths.removeAll { $0 == hashed.path }
                self.rebuildCandidates()
                if self.pendingIdentityPaths.isEmpty {
                    self.statusText = "内容归并完成，可以抽了。" + self.statusText
                }
            }
        }
    }

    /// 停止 = 把闸整体取消透传（复用既有语义）。**停止不删任何东西**（与 `finishAsCancelled` 同口径）。
    func stopProbes() {
        probeTask?.cancel()
        probeTask = nil
        FolderMixDurationReader.cancel(probeGate)
    }

    /// 切「精确识别（慢）」：口径一变 identityKey 就变 ⇒ 组合空间换了一副，旧预览必须作废（FMX-13）。
    func setPreciseIdentity(_ on: Bool, context: ModelContext) {
        guard preciseIdentity != on else { return }
        preciseIdentity = on
        // 口径一变 identityKey 就变 ⇒ 组合空间换了一副，旧预览必须作废（FMX-13）。
        // 只改 spaceRevision 不清 rows 的写法最阴：卡面上的字还是那张搭配，序号含义已经漂了。
        rows = []
        droppedRows = []
        rebuildCandidates()
        guard rootURL != nil, scan != nil else {
            MixLog.info("[FolderMix] 精确识别开关=\(on)（还没扫目录，不起探针）")
            return
        }
        let plan = FolderMixResolver.plan(
            files: materials.map { FolderMixFileEntry(path: $0.path, byteSize: $0.byteSize) },
            library: libraryByPath, preciseIdentity: on,
            durationBudget: FolderMixLimits.durationProbeBudgetFiles)
        pendingIdentityPaths = plan.identityProbePaths
        stopProbes()
        startProbes(plan: plan)
        statusText = (on ? "已切到「精确识别」：正在按内容归并…" : "已切到「按路径识别」：零等待档")
            + probeCostNote(plan: plan)
        MixLog.info("[FolderMix] 精确识别开关=\(on)：待算校验和 \(pendingIdentityPaths.count) 条，预览已作废")
    }



    /// 归一合并了多个文件夹的类别（界面要逐条写「2 个文件夹归为 1 个类别：A、A␣」）。
    var mergedCategories: [FolderMixCategory] { scan?.mergedCategories ?? [] }
    var emptyCategories: [FolderMixCategory] { scan?.emptyCategories ?? [] }

    // MARK: - ② 生成期：抽中才入库（D25/D26），一键跑完「抽 → 入库 → 解析 → 替补 → 建方案」

    /// 入库用的两颗服务。为什么在这里自己持有而不是拿 `importVM`：
    /// `ImportViewModel` 同时是导入页的 **UI 状态宿主**（`phase/progress/progressDescription/errorMessage`
    /// + `ToastCenter`），两个页面驱动同一颗实例，混剪一跑导入页的进度条就在显示混剪的活
    /// —— 这是计划 D-0 定档要根治的那条架构根因，不是"加个忙碌位"能糊过去的。
    private let committer = SegmentCommitter()
    private let ffmpeg = FFmpegRunner()

    /// 主按钮。`previewFirst` 开着（默认）时第一次点只出预览、第二次点才动盘（D27）。
    ///
    /// 流水（计划 D 段）：**抽 → 算入库任务（抽中集 ∪ 每类余量，一次算完）→
    /// 只为真被抽中的类别建项目并入库 → 按整片段解析 → 失败进 unusable 走同类替补 →
    /// 替不动的行摘掉 → 存活行建方案 → 只有成功后才把签名记进账本。**
    func generate(projectVM: ProjectViewModel, schemeVM: SchemeViewModel, context: ModelContext) async {
        guard let root = rootURL, let source else {
            errorMessage = "先选素材目录并选定素材来源。"
            return
        }
        guard pendingIdentityPaths.isEmpty else {
            errorMessage = "「精确识别」还在按内容归并（还剩 \(pendingIdentityPaths.count) 条），稍等再抽。"
            return
        }
        guard !isOverSoftLimit || overLimitConfirmed else {
            // 档 F：超软上限但未确认 —— 主按钮本来就该禁用，走到这里说明绕过了闸
            errorMessage = "这次要新建约 \(ingestBytesNote()) 的素材文件，勾「我已确认」再生成。"
            MixLog.error("[FolderMix] 超软上限未确认被绕过 rowCount=\(rowCount) softLimit=\(softLimit)")
            return
        }
        if previewFirst && rows.isEmpty {
            drawBatch()
            if rows.isEmpty { return }
            statusText = "预览已就绪（\(rows.count) 条互不相同的组合）。"
                + "确认后才会拷盘建方案 —— 现在库里一条都没动。"
            return
        }
        guard !rows.isEmpty else { errorMessage = "还没有抽出任何一条。"; return }

        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        ingestFailures = []
        segmentIDByKey = [:]

        // ① 入库任务一次算完（不许"抽→入库→失败→再抽→再入库"逐行往返：磁盘满时那是 N×radix 次 IO）
        let task = FolderMixGeneratePlanner.ingestTask(rows: rows,
                                                      candidatesByCategory: candidatesByCategory,
                                                      space: space)
        // ② 只为真被抽中的类别建库；每个类别一次入库（含替补余量）
        var codeByPath: [String: FolderMixFailureCode] = [:]
        /// 本批补建了几条混剪内部整片段（决议 K2 甲-隐）——界面上那句「自动补建 k 条」吃它。
        var internalWholeClipBuilt = 0
        /// 入库**当场**交回的对应关系（源文件路径 → 库里那一行）。跨域猜键就是被它替掉的。
        var ingested: [FolderMixIngestedRow] = []
        var failureLedger = FolderMixGeneratePlanner.FailureLedger()
        projectVM.fetchProducts()
        projectVM.fetchProjects()
        for (offset, batch) in task.batches.enumerated() {
            if Task.isCancelled {
                // 档 G：停止 ≠ 删除 —— 已入库的保留、方案一条不建（与 finishAsCancelled 同口径）
                statusText = "已停止：本次已入库的素材保留，没有生成方案。"
                MixLog.info("[FolderMix] 用户停止生成，已完成批次 \(offset)/\(task.batches.count)")
                return
            }
            guard let product = projectVM.ensureProduct(named: root.lastPathComponent),
                  let project = projectVM.ensureProject(named: batch.category, in: product) else {
                errorMessage = "建库失败：产品「\(root.lastPathComponent)」或类别「\(batch.category)」建不出来。"
                MixLog.error("[FolderMix] 建库失败 category=\(batch.category)")
                return
            }
            statusText = "入库 \(offset + 1)/\(task.batches.count)：\(batch.category)（\(batch.paths.count) 条）"
            var hooks = ClipIngestHooks()
            let urls = batch.paths.map { URL(fileURLWithPath: $0) }
            let report = await ClipIngestService.importClips(urls: urls, to: project, source: source,
                                                             context: context, committer: committer,
                                                             ffmpeg: ffmpeg, hooks: hooks)
            for item in report.failed {
                ingestFailures.append((name: item.name, reason: item.reason))
                codeByPath[item.path] = item.code
                if failureLedger.note(item.code) {
                    // 环境级短路：整批停手，不再替补、不再拷盘，已入库的部分留着
                    errorMessage = "环境级失败（\(item.reason)）：连续 \(FolderMixLimits.systemicFailureStreak) "
                        + "条同一类故障，整批已停止，不再替补。已入库的素材保留。"
                    MixLog.error("[FolderMix] 环境级短路 code=\(item.code.rawValue)，批次 \(offset+1)")
                    return
                }
            }
            ingested.append(contentsOf: report.ingested)
            internalWholeClipBuilt += report.internalWholeClipBuilt
            if let abort = report.abortMessage {
                errorMessage = abort
                MixLog.error("[FolderMix] 入库中止：\(abort)")
                return
            }
        }

        // ③ 先问一句"库里那一行还指得着文件吗"（决议 K6）；**查不了就整批不建**（K7）——
        //    宁可一句「本轮查不了」，也不许伪装成"没丢"照样建出一批导出必坏的方案。
        let reading = availabilityReading(for: ingested, context: context)
        if reading.degraded {
            errorMessage = "素材还在不在盘上这件事本轮查不了：\(reading.degradationReason ?? "未知原因")，"
                + "未生成方案。已入库的素材保留。"
            MixLog.error("[FolderMix] 可用性判据降级 ⇒ 整批未生成：\(reading.degradationReason ?? "")")
            return
        }

        // ③b 用入库交回的那张表解析（缺失档先于"无整片段"报，档序在 Core 那颗 join 里）
        let join = FolderMixLibraryJoin.resolve(candidatesByCategory: candidatesByCategory,
                                                ingested: ingested,
                                                shapes: rowShapes(for: ingested, context: context,
                                                                  missingIDs: reading.missingIDs),
                                                failureCodeBySourcePath: codeByPath)
        segmentIDByKey = join.segmentIDByKey
        // 这行日志就是第六节三条真机腿的判据物：五个数各自一档，不许靠肉眼数方案
        MixLog.info("[FolderMix] 对接：交回 \(join.ingestedCount)（重复 \(join.duplicateIngestCount)）、"
                    + "命中 \(join.hitCount)、无整片段 \(join.noWholeClipCount)、"
                    + "入库失败 \(join.failedIngestCount)、没找到 \(join.notIngestedCount)、"
                    + "文件缺失 \(join.missingFileCount)")
        let resolution = join.resolution

        // ④ 失败项走同类替补，替不动的摘行并逐条报原因（档 A/B/C）
        let requested = rows.count
        let outcome = { () -> FolderMixGenerateOutcome in
            var rng = self.rng
            return FolderMixGeneratePlanner.resolve(rows: self.rows,
                                                    candidatesByCategory: self.candidatesByCategory,
                                                    resolution: resolution, space: self.space,
                                                    ledger: self.ledger, rng: &rng)
        }()
        rows = outcome.rows
        droppedRows = outcome.shortfalls
        rowIndex = 1
        if internalWholeClipBuilt > 0 {
            // 甲-隐 的可见性交代：补出来的段**不进分镜素材库**（决议 K9 那颗唯一出口负责），
            // 所以必须在这里说一句，否则用户会以为那批素材本来就有整片段。
            statusText += "；本轮自动补建 \(internalWholeClipBuilt) 条整片段（不进分镜素材库）"
        }
        if outcome.substitutionCount > 0 {
            MixLog.info("[FolderMix] 替补 \(outcome.substitutionCount) 次，摘行 \(outcome.shortfalls.count) 条")
        }
        guard !rows.isEmpty else {
            errorMessage = "计划 \(requested) 条一条都没出：" + shortfallNote(droppedRows)
            MixLog.error("[FolderMix] 全部行被摘掉 requested=\(requested) shortfalls=\(droppedRows.count)")
            return
        }

        // ⑤ 建方案（要么 N 个要么 0 个；成功后才写签名账本 —— 都在 createSchemes 里）
        await createSchemes(projectVM: projectVM, schemeVM: schemeVM, context: context)
        if !createdSchemeNames.isEmpty, !droppedRows.isEmpty {
            statusText += "；计划 \(createdSchemeNames.count + droppedRows.count) / 实得 "
                + "\(createdSchemeNames.count)：" + shortfallNote(droppedRows)
        }
    }

    /// 把入库交回的那批行 id 投影成「有没有覆盖整片的段」（决议 J6：判段仍走 `WholeClipShape`）。
    ///
    /// ⚠ 这里**只按 id 取数**——上一版在这一层拿 `video.localPath` 当外键去查（素材目录里的
    /// 路径 vs 拷贝落地的库内路径，永不相交），又把段 id 的查找写成 `candidate.path == video.localPath`
    /// （恒 false ⇒ 键表全空）。两处都是同一个跨域猜键，现在由 `FolderMixLibraryJoin` 一处承担。
    /// 键 → 持久 id 这张表是建方案前唯一的桥（不持有模型对象）：预览与确认之间用户可能删素材，
    /// 那正是本仓「真删后读死对象」那一族崩溃的形状。
    /// `internal`（不是 private）的唯一理由：App 腿 `FolderMixIngestJoinTests` 要用真 SwiftData
    /// 容器跑一遍"交回 → 投影 → join"这段接缝 —— 这段在 `swift test` 里编不到，
    /// 而它正是这次 50 条全摘的位置。别把它改回 private，那条判据会退成纯函数测试。
    func rowShapes(for ingested: [FolderMixIngestedRow], context: ModelContext,
                   missingIDs: Set<UUID>) -> [UUID: FolderMixRowShape] {
        guard !ingested.isEmpty else { return [:] }
        let wanted = Set(ingested.map(\.videoID))
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        var out: [UUID: FolderMixRowShape] = [:]
        for video in videos where wanted.contains(video.id) {
            let wholeClip = video.segments.first { segment in
                WholeClipShape.isWholeClip(
                    segments: [WholeClipSegmentShape(startTime: segment.startTime,
                                                    endTime: segment.endTime)],
                    videoDuration: video.duration)
            }
            out[video.id] = FolderMixRowShape(videoID: video.id,
                                              wholeClipSegmentID: wholeClip?.id,
                                              filePresent: !missingIDs.contains(video.id))
        }
        return out
    }

    /// 库里那一行的**库内拷贝路径**现在到底指不指得着一个读得动的文件（决议 K6/K7）。
    ///
    /// 为什么直接调 `MaterialAvailabilityStore.missingDivideReading` 而不是那颗共享集：
    /// · 共享集是按项目 `refresh` 的（挂点在导入页与分镜库两页），混剪的类别项目从没触发过它
    ///   ⇒ 读它只会拿到**上一个项目的缺失集**或空集，跨项目串"丢失"；
    /// · 那颗判定本体是 `nonisolated static`、收值类型入参，界面（`refresh`）与启动对账
    ///   （`runOrphanGC`）用的就是同一颗 ⇒ 只调它既不产生第二个答案，也不引入异步等待。
    /// 明令：这里**不新建第二个持有者**，也不自己拼一次文件存在性判断（探针唯一出口在
    /// `FileHelper.materialProbe`，那颗判定内部已经在用它）。
    func availabilityReading(for ingested: [FolderMixIngestedRow], context: ModelContext)
        -> MissingScanResult {
        guard !ingested.isEmpty else { return MissingScanResult() }
        let wanted = Set(ingested.map(\.videoID))
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        return MaterialAvailabilityStore.missingDivideReading(
            records: videos.filter { wanted.contains($0.id) }
                .map { MaterialRecordPath(id: $0.id, path: $0.localPath) })
    }

    /// 摘行报告按（档, 类别）**聚合**成一句（决议 J5）：50 条逐条拼接完全不可读，
    /// 而聚合不丢信息 —— 条数、类别、哪一档都在（档名由 Core 那句 reason 自带）。
    private func shortfallNote(_ shortfalls: [FolderMixShortfall]) -> String {
        var order: [String] = []
        var buckets: [String: (count: Int, categories: Set<String>)] = [:]
        for shortfall in shortfalls {
            if buckets[shortfall.reason] == nil { order.append(shortfall.reason) }
            var bucket = buckets[shortfall.reason] ?? (0, [])
            bucket.count += 1
            bucket.categories.formUnion(shortfall.categories)
            buckets[shortfall.reason] = bucket
        }
        return order.map { reason in
            let bucket = buckets[reason] ?? (0, [])
            let categoryNote = bucket.categories.isEmpty
                ? "" : "（\(bucket.categories.sorted().joined(separator: "、"))）"
            return "\(bucket.count) 条\(categoryNote)：\(reason)"
        }.joined(separator: "；")
    }


    // MARK: - ③ 抽片（组合级不重复，D23/D30）

    /// 当前参与集与组合空间。改条数/改勾选/改排列只重算这颗（O(类别数) 乘法，不抽取）。
    var space: FolderMixComboSpace {
        FolderMixComboSpace(candidatesByCategory: candidatesByCategory,
                            orderedCategories: orderedCategories,
                            enabled: enabledCategories)
    }

    /// 组合总数 M（= Π 各类别类内去重后的素材数）。
    var combinationTotal: Int { space.total }
    /// 本轮会话已经发出的组合数（页脚那颗「已发出」）。
    var ledgerIssuedCount: Int { ledger.issuedCount }
    /// 还能出多少条互不相同的组合。
    var remainingCombos: Int { ledger.remaining(in: space) }
    /// 是否已经大到报不出准数 —— 界面此时**两颗都不许报精确数**（评审 P2-4）。
    var isSpaceSaturated: Bool { space.isSaturated }

    /// 勾选/取消一个类别。**作废当前预览行**：旧行是按旧参与集抽出来的，留着就是在替新参与集说谎。
    func setEnabled(_ name: String, on: Bool) {
        guard enabledCategories.contains(name) != on else { return }
        if on { enabledCategories.insert(name) } else { enabledCategories.remove(name) }
        rows = []
        rowIndex = 1
        persist()
        MixLog.info("[FolderMix] 勾选变更 category=\(name) enabled=\(on) 组合总数=\(combinationTotal)")
    }

    /// 整栏勾选/取消（左栏那两颗「全选 / 全不选」）。
    /// 全选**不把空类拉进来**：空类不占额度是 R4 的口径，勾上它只会让乘积多乘一个 0。
    func setAllEnabled(_ on: Bool) {
        enabledCategories = on
            ? Set(orderedCategories.filter { (candidatesByCategory[$0]?.isEmpty == false) })
            : []
        rows = []
        rowIndex = 1
        persist()
        MixLog.info("[FolderMix] 批量勾选 enabled=\(on) 参与=\(space.participants.count) "
                    + "组合总数=\(combinationTotal)")
    }

    /// 扫描完成后同步默认勾选：非空类默认参与、空类默认不参与（D13/D29）。
    func syncEnabledWithScan() {
        var next = Set<String>()
        for name in orderedCategories where (candidatesByCategory[name]?.isEmpty == false) { next.insert(name) }
        enabledCategories = next
    }

    /// 生成 N 条预览（D27 先看再确认）。**只读签名账本做排除，绝不写它** ⇒ 预览不消耗组合。
    func drawBatch() {
        guard pendingIdentityPaths.isEmpty else {
            errorMessage = "「精确识别」还在按内容归并（还剩 \(pendingIdentityPaths.count) 条），抽了会换义。"
            return
        }
        guard !space.participants.isEmpty else { errorMessage = "没有勾选任何有素材的类别。"; return }
        guard rowCount >= 1 else { errorMessage = "条数至少 1 条。"; return }
        errorMessage = nil
        do {
            let batch = try FolderMixPicker.drawMany(candidatesByCategory: candidatesByCategory,
                                                     space: space,
                                                     ledger: ledger,
                                                     count: rowCount,
                                                     rng: &rng)
            rows = batch.rows
            droppedRows = batch.shortfall
            rowIndex = 1
            MixLog.info("[FolderMix] 抽片 \(batch.rows.count) 条（组合总数 \(combinationTotal)、"
                        + "已发出 \(ledger.issuedCount)、剩余 \(remainingCombos)）"
                        + (batch.shortfall.isEmpty ? "" : "，摘行 \(batch.shortfall.count) 条"))
            statusText = rowNotesText()
            persist()
        } catch let error as FolderMixPickerError {
            rows = []
            droppedRows = []
            errorMessage = describe(error)
            MixLog.error("[FolderMix] 抽片被拒：\(error)")
        } catch {
            rows = []
            errorMessage = FriendlyError.reason(for: error)
        }
    }

    /// 第 k 条「换一换」：换到**另一个互不相同的组合**（R9 的等价形态）。
    /// 组合级口径下"素材跨条复现"是允许的，所以这里不再判"与其他条撞素材"，
    /// 只判"这一行整条签名是否已发出过 / 是否与别的行同签名"。
    func rerollCurrentRow() {
        guard rows.indices.contains(rowIndex - 1) else { return }
        let current = rows[rowIndex - 1]
        var blocked = ledger
        for (offset, row) in rows.enumerated() where offset != rowIndex - 1 {
            _ = blocked.commit(signature: row.signature)     // 排除池 = 已发出 ∪ 其他行
        }
        var attempt: FolderMixComboRow?
        for _ in 0..<24 {                                    // 有界重试，不无限循环（D36）
            guard let candidate = FolderMixPicker.draw(candidatesByCategory: candidatesByCategory,
                                                       space: space, ledger: blocked,
                                                       rng: &rng) else { break }
            if candidate.signature != current.signature { attempt = candidate; break }
            _ = blocked.commit(signature: candidate.signature)
        }
        guard let replacement = attempt else {
            statusText = "第 \(rowIndex) 条已无可换的新组合（参与类别的搭配已全部发出过），保持不变。"
            MixLog.info("[FolderMix] 第 \(rowIndex) 条换一换无处可换")
            return
        }
        rows[rowIndex - 1] = replacement
        MixLog.info("[FolderMix] 第 \(rowIndex) 条换一换完成 ordinal=\(replacement.ordinal)")
        statusText = rowNotesText()
    }

    /// 清掉"已发出"记录，重新开始一轮。
    func resetSession() {
        rows = []
        droppedRows = []
        ledger = FolderMixComboLedger()
        persist()
        reseed()
        statusText = "已清空本次会话的发出记录，可以重新抽了。"
        MixLog.info("[FolderMix] 会话签名账本已清空（重新开始一轮）")
    }

    private func describe(_ error: FolderMixPickerError) -> String {
        switch error {
        case .noParticipants:
            return "没有勾选任何有素材的类别。"
        case .countBelowMinimum(let got):
            return "条数至少 1 条（当前 \(got)）。"
        case .countExceedsCombinationSpace(let requested, let total):
            // 第九节「N > 组合总数」= 拒绝档：就地红字 + 说明为什么 + 给下一步。
            return "凑不出 \(requested) 条互不相同的组合：参与类别的搭配一共只有 \(total) 种。"
                + "减少条数、勾上更多类别，或点「重新开始一轮」清掉已发出的记录。"
        case .tooManyRowsPerDraw(let requested, let budget):
            return "一次最多抽 \(budget) 条（当前要求 \(requested)）。请分批生成。"
        }
    }

    private func rowNotesText() -> String {
        func list(_ names: [String]) -> String { Array(Set(names)).sorted().joined(separator: "、") }
        var parts: [String] = ["已抽出 \(rows.count) 条互不相同的组合"]
        let blocked = droppedRows.flatMap(\.categories)
        if !blocked.isEmpty {
            parts.append("这些类别与同一条里其他类别用了同一素材，需替补：\(list(blocked))")
        }
        if !space.skippedEmpty.isEmpty {
            parts.append("空类别（不占额度）：\(list(space.skippedEmpty))")
        }
        if !space.excluded.isEmpty {
            parts.append("未勾选：\(list(space.excluded))")
        }
        if !droppedRows.isEmpty {
            parts.append("计划 \(rows.count + droppedRows.count) / 实得 \(rows.count)："
                + list(droppedRows.map(\.reason)))
        }
        return parts.joined(separator: "；")
    }

    // MARK: - 当前条的读数（View 用）

    var currentRow: FolderMixComboRow? { rows.indices.contains(rowIndex - 1) ? rows[rowIndex - 1] : nil }
    var canStepBack: Bool { rowIndex > 1 }
    var canStepForward: Bool { rowIndex < rows.count }
    var canDraw: Bool { source != nil && !space.participants.isEmpty && pendingIdentityPaths.isEmpty }

    /// 主按钮该不该亮。**这条分支只能在 VM 里**：预览档与生成档的放行条件不同
    /// （预览看 `canDraw`，生成看 `canCreate`），写到 View 里就是判定长在界面层（G-c）。
    var canStartMainAction: Bool {
        previewFirst && rows.isEmpty ? canDraw : canCreate
    }

    /// 「停止」：取消在跑的探针与入库。口径与既有 `finishAsCancelled` 一致 ——
    /// **停止 ≠ 删除**：已入库的素材与已建的项目都保留（不新增任何直删站点，G12 名册会抓）。
    func stop() {
        stopProbes()
        isBusy = false
        statusText = "已停止：已入库的素材保留，未生成的方案不会出现。"
        MixLog.info("[FolderMix] 用户停止")
    }
    /// 主按钮放行条件：有来源、参与集非空、还剩组合、超软上限时必须已确认。
    var canCreate: Bool {
        source != nil && !rows.isEmpty && remainingCombos > 0 && pendingIdentityPaths.isEmpty
            && (rowCount <= softLimit || overLimitConfirmed)
    }
    /// 是否处于"超软上限"态（界面据此出红字预估 + 那颗确认勾选）。
    var isOverSoftLimit: Bool { rowCount > softLimit }
    /// 条数 +1 / -1（Stepper 走这颗）。
    func stepRowCount(_ delta: Int) {
        rowCount = rowCount + delta        // 钳位在 setter 里，只有一处
        persist()
    }

    /// 软上限也可改并被记住（D24）。同样不许钳在 View 里（G-c）。
    func stepSoftLimit(_ delta: Int) {
        softLimit = min(max(1, softLimit + delta), FolderMixLimits.countInputClamp.upperBound)
        persist()
    }

    /// 本条预计时长（秒）—— D4 整片相加，不截断。
    /// 时长读不到的按 0 计入**总和**，但必须在界面上单独显示「—」并计入 `unknownDurationCount`
    /// （决定 6：不许把"不知道"当"0 秒"骗过磁盘预算）。
    func rowDuration(_ row: FolderMixComboRow?) -> Double {
        row?.picks.reduce(0) { $0 + ($1.duration ?? 0) } ?? 0
    }

    /// 全批里时长未知的条数（>0 时界面上要逐名出声）。
    var unknownDurationCount: Int {
        rows.reduce(0) { $0 + $1.picks.filter { $0.duration == nil }.count }
    }

    /// 组合空间的指纹（`FolderMixSpaceFingerprint`）。探针回填要拿它自校验（L3/FMX-16）：
    /// 旧一轮目录或旧开关的结果不许写进新一轮的账。
    var spaceRevision: String {
        FolderMixSpaceFingerprint.revision(space: space, candidatesByCategory: candidatesByCategory,
                                           preciseIdentity: preciseIdentity)
    }

    /// 「这次导出还要占多少盘」（R16 的可见化）。混剪只到方案（D17），落盘发生在导出页，
    /// 所以这里只**报数**不阻断；式子与入库预检同真源（`DiskSpaceBudget`）。
    ///
    /// 走 `estimate` 而不是 `requiredBytes`：预览行里有时长未知的素材时，那些项**不计入总量**
    /// 但要**逐名**报出来（B6）—— 按 0 计入 = 给用户少报，而他正是按这个数勾「我已确认」的。
    var outputEstimate: DiskSpaceEstimate {
        DiskSpaceBudget.estimate(
            materialBytes: 0,
            items: rows.map { row in
                DiskSpaceOutputItem(name: "第 \(row.ordinal + 1) 条",
                                    durationSeconds: row.picks.contains(where: { $0.duration == nil })
                                        ? nil : rowDuration(row))
            },
            bitrateMbps: DiskSpaceBudget.defaultOutputBitrateMbps)
    }

    var estimatedOutputBytes: Int64 { outputEstimate.requiredBytes }

    /// 生成期要拷进库多少字节（超软上限那句红字的头一项：「将新建约 U 个素材文件（≈ X GB 拷贝）」）。
    /// 素材字节数读不出的那颗不计入、但计数（同 B6 的口径）。
    func ingestBytesNote() -> String {
        let task = FolderMixGeneratePlanner.ingestTask(rows: rows,
                                                      candidatesByCategory: candidatesByCategory,
                                                      space: space)
        let wanted = Set(task.batches.flatMap(\.paths))
        var bytes: Int64 = 0
        var unknown = 0
        for entry in materials where wanted.contains(entry.path) {
            if let size = entry.byteSize { bytes += size } else { unknown += 1 }
        }
        let note = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return unknown > 0
            ? "\(note)（另有 \(unknown) 条读不出大小，未计入）"
            : note
    }

    // MARK: - 排列与翻页

    /// 归一合并提示（第九节：两个文件夹 trim 后同名 ⇒ 放行 + 合并，但**必须出声** ——
    /// 静默合并会让用户以为少了一个类别）。
    var mergedNote: String {
        mergedCategories.map { category in
            "\(category.rawFolderNames.count) 个文件夹归为 1 个类别："
                + category.rawFolderNames.map { "「\($0)」" }.joined(separator: "、")
        }.joined(separator: "；")
    }

    /// 被整类拒绝的目录（替身 / 读不出），逐名带原因，不藏（第九节 symlink 档）。
    var rejectionNote: String {
        rejections.map { "\($0.name)：\($0.reason)" }.joined(separator: "；")
    }

    /// 调顺序（D4：这个顺序就是拼接顺序）。
    /// 顺序一变就**清空已抽出的预览** —— 那些卡是按旧顺序抽的，留着就是在替新顺序说谎。
    func moveCategory(_ offset: Int, up: Bool) {
        let target = up ? offset - 1 : offset + 1
        guard orderedCategories.indices.contains(offset),
              orderedCategories.indices.contains(target) else { return }
        orderedCategories.swapAt(offset, target)
        rows = []
        rowIndex = 1
        persist()
    }

    /// 翻页（A11）：N 条靠翻页压高度，不铺卡片墙（D15）。
    func step(_ delta: Int) {
        guard !rows.isEmpty else { return }
        rowIndex = min(max(1, rowIndex + delta), rows.count)
    }

    // MARK: - ④ 建 N 个方案

    /// 生成 N 个独立方案（D10/D11/D16）。
    /// **要么 N 个要么 0 个**（第九节「createCustomScheme 返回 nil」= 拒绝档）：
    /// 先把每条的 Segment 按持久 id 重新解析一遍（期间被删掉的素材会在这里被查到），
    /// 再逐条建；中途失败就删掉本次已建的那些，不留半批。
    func createSchemes(projectVM: ProjectViewModel, schemeVM: SchemeViewModel,
                       context: ModelContext) async {
        guard !rows.isEmpty else { errorMessage = "还没有抽出任何一条。"; return }
        guard let source, let root = rootURL else {
            errorMessage = "先选定素材来源。"
            return
        }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        createdSchemeNames = []

        // ① 全量预解析：任何一条缺段就整批不建
        var resolved: [[Segment]] = []
        let live = (try? context.fetch(FetchDescriptor<Segment>())) ?? []
        var byID: [UUID: Segment] = [:]
        for segment in live where byID[segment.id] == nil { byID[segment.id] = segment }
        for (offset, row) in rows.enumerated() {
            var segments: [Segment] = []
            for pick in row.picks {
                guard let id = segmentIDByKey[pick.id], let segment = byID[id] else {
                    errorMessage = "第 \(offset + 1) 条里的「\(pick.name)」已经不在素材库里（被删掉了？）。"
                        + "整批未生成，请重新抽一次。"
                    MixLog.error("[FolderMix] 预解析缺段 row=\(offset + 1) key=\(pick.id)")
                    return
                }
                segments.append(segment)
            }
            if segments.isEmpty {
                errorMessage = "第 \(offset + 1) 条一条素材都没有（该类别素材已用尽或被删）。整批未生成。"
                MixLog.error("[FolderMix] 空行 row=\(offset + 1)")
                return
            }
            resolved.append(segments)
        }

        // ② 汇总项目（D11：一个产品共用一个 ⇒ 同名复用，重扫不副本）
        projectVM.fetchProducts()
        projectVM.fetchProjects()
        guard let product = projectVM.ensureProduct(named: root.lastPathComponent),
              let summary = projectVM.ensureProject(named: Self.summaryProjectName, in: product) else {
            errorMessage = "汇总项目「\(Self.summaryProjectName)」建不出来（库未就绪？）。"
            MixLog.error("[FolderMix] 汇总项目创建失败")
            return
        }

        // ③ 逐条建方案；失败则走**既有删除咽喉**回滚本次已建的（不是 `context.delete` 直删）
        var made: [MixScheme] = []
        for (offset, segments) in resolved.enumerated() {
            statusText = "生成第 \(offset + 1)/\(resolved.count) 条方案…"
            guard let scheme = await schemeVM.createCustomScheme(from: segments, in: summary,
                                                                inferMetadata: false) else {
                // ⚠ 这里曾写成 `context.delete(scheme)` —— 那是**新增第 12 处绕过咽喉的直删**，
                // 被既有名册判据当场抓出（`TombstoneReadGuardTests` G12：真删站点总数 54→55、
                // 且"未登记的新站点"）。直删正是本案那一族 SIGTRAP 的成因，
                // 而 `deleteScheme` 已经把「界面隐藏 + 宽限期 + 撤销浮条 + 脚本配音回收」都办了。
                for scheme in made { schemeVM.deleteScheme(scheme) }
                errorMessage = "第 \(offset + 1) 条方案创建失败：\(schemeVM.errorMessage ?? "未知原因")"
                    + "整批 \(resolved.count) 条均未生成（已建的 \(made.count) 条已走删除队列回收）。"
                MixLog.error("[FolderMix] 建方案中途失败 row=\(offset + 1)，已回滚 \(made.count) 条")
                return
            }
            made.append(scheme)
            createdSchemeNames.append(scheme.name)
        }
        context.safeSave()

        // ④ **只有走到这一步才算"发出"**：把这批行的签名记进账本。
        //    预览、失败、取消都不写它（归属表第 3 行；FMX-06/FMX-07 两头钉）。
        for row in rows {
            if ledger.commit(signature: row.signature) { continue }
            MixLog.info("[FolderMix] 签名已在账上，不重复记账 ordinal=\(row.ordinal)")
        }

        // ⑤ 记下方案落在哪个项目，交给界面去导航（**不在这里改 selectedProject**）
        lastSummaryProjectName = summary.name
        lastSummaryProjectID = summary.id
        MixLog.info("[FolderMix] 建 N 方案完成：\(createdSchemeNames.count) 条落在「\(summary.name)」、"
                    + "来源标签 \(source.displayName)、seed \(sessionSeed)")
        statusText = "已生成 \(createdSchemeNames.count) 条方案，都在项目「\(Self.summaryProjectName)」里；"
            + "导出请到「导出」页勾选（本期只到方案）。"
    }

    /// 方案落在汇总项目里，而方案页按"当前选中项目"取数（风险 3）⇒ 必须切过去才看得见。
    /// 这件事放在**用户点「去看方案」那一刻**做，而不是生成完自动做：
    /// 自动生成时切项目会让 ContentView 的分支翻面（`if let project = selectedProject`），
    /// 那一屏的 @State 随之销毁 —— 用户刚点完"生成"，预览卡片就凭空清空了。
    /// （同仓先例：`ContentView` 里「不用 .id() 强制重建」与骨架屏分支翻转那两条注释。）
    func openSummaryProject(projectVM: ProjectViewModel, schemeVM: SchemeViewModel) {
        guard let id = lastSummaryProjectID,
              let project = projectVM.projects.first(where: { $0.id == id }) else {
            errorMessage = "找不到汇总项目「\(Self.summaryProjectName)」，请到侧栏手动选它。"
            return
        }
        projectVM.selectedProject = project
        schemeVM.loadSchemes(for: project)
        NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.schemes)
    }
}
