import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 两层解析判据（FMX-14 / FMX-15 / FMX-16，计划 D33）
//
// 这一族钉的是同一件事：**库里已经算好的那两份（时长、校验和）必须被消费，读盘只兜未入库的文件。**
// 它值得单独一族，是因为上一版计划把"读盘"当默认路径、还打算新造一颗"唯一读时长的地方"——
// 那是重复计算，不是设计。
//
// 非空洞性（每条都有一把对应的刀，见 `.scratch/` 那轮读数）：
//   - 把第一层摘掉（直接读盘）        → FMX-14 红（探针计数从 0 变 2）
//   - 把 `duration > 0 ? : nil` 写成直接取库值 → FMX-15 红（0 被当成有效读数）
//   - 去掉 `if preciseIdentity` 分支  → FMX-14b 红（默认档开始算哈希 = 把成本塞回默认路径）
//   - 预算写成不截断                  → FMX-14c 红（deferred 空、探针数超预算）
//   - revision 校验做成"只记日志不拦" → FMX-16 红（旧结果照样并进新账）
//   - 回填覆盖已有读数 / 把 nil 写进去 → FMX-16b 红
//
// App 层那一半（`FolderMixDurationReader` / `FolderMixContentKeyReader`）不在这里测：
//   它们在 App target，`swift test` 编不到。那半由源码扫描腿钉（T-23 调用点唯一、T-28 不新造闸），
//   取消语义则直接引用既有整套判据 `BoundedTaskGateTests` BC-3…BC-6（本轮不重写一遍，
//   也不假装新测了它 —— 那是 FMX-17 的结案理由）。
// ============================================================================

struct FolderMixResolveTests {

    private func file(_ path: String, _ size: Int64? = 1_000) -> FolderMixFileEntry {
        FolderMixFileEntry(path: path, byteSize: size)
    }

    private func record(_ hash: String?, _ seconds: Double) -> FolderMixLibraryRecord {
        FolderMixLibraryRecord(contentHash: hash, durationSeconds: seconds)
    }

    // ── FMX-14：第一层命中 ⇒ 一次盘都不读 ──

    @Test("FMX-14 库里两份都已算好 ⇒ 探针计划是空的（零读盘）")
    func libraryHitsProduceNoProbes() {
        let files = [file("/r/A/a.mp4"), file("/r/A/b.mp4")]
        let lib = ["/r/A/a.mp4": record("h1", 12), "/r/A/b.mp4": record("h2", 31.5)]
        let plan = FolderMixResolver.plan(files: files, library: lib,
                                          preciseIdentity: false, durationBudget: 2_000)
        #expect(plan.totalProbeCount == 0, "库里命中还排进探针 = 把已算好的东西算第二遍")
        #expect(plan.durationProbePaths.isEmpty)
        #expect(plan.libraryDurationHits == 2)
        #expect(plan.identityProbePaths.isEmpty, "默认档一次都不该发起校验和计算")
    }

    @Test("FMX-14b 精确档：库里那份 hash 零成本复用，只有未入库的才排进哈希队列")
    func preciseTierReusesStoredHash() {
        let files = [file("/r/A/a.mp4"), file("/r/B/b.mp4")]
        let lib = ["/r/A/a.mp4": record("h1", 12)]           // b.mp4 还没入库
        let plan = FolderMixResolver.plan(files: files, library: lib,
                                          preciseIdentity: true, durationBudget: 2_000)
        #expect(plan.identityProbePaths == ["/r/B/b.mp4"])
        #expect(plan.libraryIdentityHits == 1)
        // 时长那一维不受开关影响：a 已有、b 没有
        #expect(plan.durationProbePaths == ["/r/B/b.mp4"])

        // 负腿：同一份输入把开关关掉，哈希队列必须是空的（"顺手总是算一遍"的写法在这条上红）
        let off = FolderMixResolver.plan(files: files, library: lib,
                                         preciseIdentity: false, durationBudget: 2_000)
        #expect(off.identityProbePaths.isEmpty)
        #expect(off.libraryIdentityHits == 0, "默认档不该把第一层的哈希命中报成收益")
    }

    @Test("FMX-14c 预算封顶：排不进的进 deferred，既不报错也不当 0 秒")
    func budgetTruncatesInsteadOfOverrunning() {
        let files = (1...5).map { file("/r/A/\($0).mp4") }
        let plan = FolderMixResolver.plan(files: files, library: [:],
                                          preciseIdentity: false, durationBudget: 2)
        #expect(plan.durationProbePaths == ["/r/A/1.mp4", "/r/A/2.mp4"], "按输入顺序补，读数才可复现")
        #expect(plan.deferredDurationPaths == ["/r/A/3.mp4", "/r/A/4.mp4", "/r/A/5.mp4"])
        #expect(plan.libraryDurationHits == 0)
    }

    // ── FMX-15：0 不是"这个素材正好 0 秒"，是"没算过" ──

    @Test("FMX-15 库里那份的 0 折成未知，且这条素材被排进探针而不是排进预算")
    func zeroDurationIsUnknownNotFree() {
        #expect(FolderMixLibrary.duration(of: record(nil, 0)) == nil)
        #expect(FolderMixLibrary.duration(of: record("h", 0)) == nil, "hash 有值不豁免时长为 0")
        #expect(FolderMixLibrary.duration(of: nil) == nil)
        #expect(FolderMixLibrary.duration(of: record(nil, 0.25)) == 0.25)

        let plan = FolderMixResolver.plan(files: [file("/r/A/z.mp4")],
                                          library: ["/r/A/z.mp4": record(nil, 0)],
                                          preciseIdentity: false, durationBudget: 10)
        #expect(plan.durationProbePaths == ["/r/A/z.mp4"],
                "把 0 当有效读数的写法在这里存活不了：它会让界面显示 0 秒、并被磁盘预算当免费额度")
        #expect(plan.libraryDurationHits == 0)
    }

    // ── L4：身份键的两档 ──

    @Test("L4 身份键：默认档取路径，精确档取库里 hash、其次现算、都没有才退回路径")
    func identityKeyTiers() {
        #expect(FolderMixLibrary.identityKey(of: record("h1", 12), path: "/p/a.mp4",
                                             preciseIdentity: false) == "/p/a.mp4")
        #expect(FolderMixLibrary.identityKey(of: record("h1", 12), path: "/p/a.mp4",
                                             preciseIdentity: true) == "h1")
        #expect(FolderMixLibrary.identityKey(of: nil, path: "/p/a.mp4", preciseIdentity: true,
                                            computedHash: "fresh") == "fresh")
        // 都拿不到才退回路径。这一格必须显式：静默丢候选会让"精确识别"变成"少几条素材"
        #expect(FolderMixLibrary.identityKey(of: nil, path: "/p/a.mp4", preciseIdentity: true) == "/p/a.mp4")
        #expect(FolderMixLibrary.identityKey(of: record("", 5), path: "/p/a.mp4",
                                             preciseIdentity: true) == "/p/a.mp4",
                "空串 hash 等于没有 hash，不许当成一个身份键把所有空串素材并成一条")
    }

    // ── FMX-16：异步回填的时效闸 ──

    @Test("FMX-16 旧一轮目录的探针结果不许写进新一轮的账")
    func staleRevisionDiscardsResults() {
        let probed = ["/p/a.mp4": Optional(12.0)]
        #expect(FolderMixResolver.applyDurations(probed, startedRevision: 7, currentRevision: 7) == probed)
        #expect(FolderMixResolver.applyDurations(probed, startedRevision: 7, currentRevision: 8) == nil,
                "revision 变了还照样回填 = 把上一个目录的时长挂到新目录的素材上")
    }

    @Test("FMX-16b 回填只补缺口：不覆盖已有读数；读不出的记成显式未知（不是 0，也不是「没记过」）")
    func mergeFillsOnlyGaps() {
        let current: [String: Double?] = ["/p/a.mp4": 12, "/p/b.mp4": nil]
        let incoming: [String: Double?] = ["/p/a.mp4": 99, "/p/b.mp4": 30, "/p/c.mp4": nil]
        let merged = FolderMixResolver.mergedDurations(current: current, incoming: incoming)
        #expect(merged["/p/a.mp4"]! == 12, "已有读数被后台探针覆盖 = 同一素材在一次会话里数字会跳")
        #expect(merged["/p/b.mp4"]! == 30)
        // 三层比较要看清：`merged[k]` 是 `Double??` —— 键存在但值为 nil 时它**不是** nil。
        // 这里断的是"这个键被记下了，且记的是未知"，也就是下一轮不再对它重复发探针。
        #expect(merged.keys.contains("/p/c.mp4"))
        #expect(merged["/p/c.mp4"]! == nil, "读不出要显式记 nil，但不许折成 0")
    }

    // MARK: 名字启发式（计划 2026-10-22 决议 J3 / TC-J4 / TC-J5）
    //
    // 这层**只服务扫描期的代价预估**：那一刻手上没有对应关系，只能按名字猜。
    // 猜错不允许影响出片 —— 所以这里不返回任何 id，拼不出一条方案。

    private func scanned(_ path: String) -> FolderMixScannedFile {
        FolderMixScannedFile(path: path, name: (path as NSString).lastPathComponent)
    }

    private func nameRow(_ name: String, duration: Double, hash: String? = nil)
        -> FolderMixLibraryNameRow {
        FolderMixLibraryNameRow(videoName: name,
                                record: FolderMixLibraryRecord(contentHash: hash,
                                                               durationSeconds: duration))
    }

    @Test("TC-J4 正规化差异不许变成猜不中：Swift 的名字相等按标准等价")
    func normalizationDifferenceStillHitsTheSameRow() {
        // 实测前提（写这条之前我以为会判成两颗，跑了才知道不是）：Swift 的 String 相等
        // 按 Unicode 标准等价，所以 NFD 的扫描名与 NFC 的库内行**值是同一颗**（字节不同）。
        // 这层因此不需要自己做正规化；反过来，大小写就真的是两颗（见 TC-J5）。
        let nfc = "é钩子.mp4"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(Array(nfc.unicodeScalars) != Array(nfd.unicodeScalars),
                "夹具前提：两种正规化在字节层面必须不同，否则这条判据没证任何东西")
        let outcome = FolderMixNameHeuristic.guess(
            files: [scanned("/Users/x/素材/爆点/" + nfd)],
            libraryRows: [nameRow(nfc, duration: 20)])
        #expect(outcome.hitCount == 1, "正规化差异不该让已经在库的素材白付一次读盘")
        #expect(outcome.libraryByPath.values.first?.durationSeconds == 20)
        #expect(outcome.missedPaths.isEmpty && outcome.ambiguousNames.isEmpty)
    }

    @Test("TC-J5 大小写不同的两颗不许并成同名：各自命中各自的读数")
    func caseDifferencesAreNotMerged() {
        let outcome = FolderMixNameHeuristic.guess(
            files: [scanned("/Users/x/素材/爆点/钩子.mp4"),
                    scanned("/Users/x/素材/卖点/钩子.MP4")],
            libraryRows: [nameRow("钩子.mp4", duration: 10),
                          nameRow("钩子.MP4", duration: 30)])
        #expect(outcome.hitCount == 2)
        #expect(outcome.libraryByPath["/Users/x/素材/爆点/钩子.mp4"]?.durationSeconds == 10)
        #expect(outcome.libraryByPath["/Users/x/素材/卖点/钩子.MP4"]?.durationSeconds == 30,
                "APFS 默认大小写不敏感 ⇒ 一旦做 caseInsensitive 比较，两颗不同素材会被并成一行读数")
        #expect(outcome.ambiguousNames.isEmpty)
    }

    @Test("H2 同名多行整条不采信：报歧义、退探针，绝不挑一条来用")
    func ambiguousNameIsRejectedEntirely() {
        let outcome = FolderMixNameHeuristic.guess(
            files: [scanned("/Users/x/素材/爆点/钩子A.mp4")],
            libraryRows: [nameRow("钩子A.mp4", duration: 11),
                          nameRow("钩子A.mp4", duration: 99)])
        #expect(outcome.hitCount == 0)
        #expect(outcome.ambiguousNames == ["钩子A.mp4"])
        #expect(outcome.missedPaths == ["/Users/x/素材/爆点/钩子A.mp4"])
    }

    @Test("H1/H3 正向腿：同名唯一才采信，认不出的进 missed（配刀：不许改成多行也采信）")
    func uniqueNameHitsAndMissesAreReportedSeparately() {
        let outcome = FolderMixNameHeuristic.guess(
            files: [scanned("/Users/x/素材/爆点/钩子A.mp4"),
                    scanned("/Users/x/素材/爆点/新素材.mp4")],
            libraryRows: [nameRow("钩子A.mp4", duration: 44, hash: "abcd")])
        #expect(outcome.hitCount == 1)
        #expect(outcome.libraryByPath["/Users/x/素材/爆点/钩子A.mp4"]?.contentHash == "abcd")
        #expect(outcome.missedPaths == ["/Users/x/素材/爆点/新素材.mp4"])
        #expect(outcome.ambiguousCount == 0)
    }
}
