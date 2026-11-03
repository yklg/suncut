import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 方案 kindled-cloud-robin.md · 批 1 —— MissingMaterialFinder 判据用例（TC-M01…M12）
//
// 锁定的接口：
//   enum MaterialProbeReading { present, absent, unreadable }
//   struct MaterialRecordPath { id: UUID, path: String }
//   struct MissingScanResult { missingIDs: Set<UUID>, excludedRecords: Int,
//                              unreadableRecords: Int, degraded: Bool, degradationReason: String? }
//   enum MissingMaterialFinder {
//       missingIDs(records:probe:trustedPrefixes:)
//       safeMissingIDs(records:probe:trustedPrefixes:videoRootPresent:)
//   }
//
// 规则（**三档可信度门取自结构、不取自计数** —— 这是它与 safeOrphanFiles 最大的分野）：
//   R1 本类型永不产出删除动作，唯一输出是一组 id ⇒ 它"少给 id"的退化是功能失效，
//      "多给 id"的退化只是多显示一张死卡。两种退化的代价不对称，所以反向防线（M02）与
//      保守门（M03/M04/M11）必须同时有人钉着，缺一条就退化成"永远返回空的假守卫"。
//   R2 degraded == true ⇒ missingIDs 必空，且必须带原因（调用方要把原因上屏：
//      "我查不了"不许伪装成"没丢"，也不许伪装成"丢了"）。
//   R3 素材根目录本身不在（videoRootPresent == false）⇒ 一个都不给：目录在、文件没了 = 用户删的；
//      目录没了 = 卷未挂载 / 域被重置。
//   R4 记录与真源前缀**逐条**判可信度，前缀外的计入 excludedRecords 后其余照常判。
//      safeOrphanFiles 那条"零交集 ⇒ 不可信"的字面镜像恰好在真实事故现场失效（用户把整目录
//      视频都删了 ⇒ 交集为零 ⇒ 功能当场一声不响），所以这里改成逐条排除。
//   R5 探针第三态 .unreadable ≠ 不存在 ⇒ 该条不判缺（宁可留着卡），只进 unreadableRecords；
//      可判定的**全部**读不动才是判据坏了。
//   R6 records 为空 ⇒ 空结果但**不是** degraded（"没素材"不等于"不知道"），且这条先于 R3。
//   R7 前缀比较与 orphan 同口径（大小写 + 末尾斜杠），且目录边界必须算：/Videos2 不算在 /Videos 里。
//   R8 分桶守恒：judgeable + excluded == records.count，一条记录不许同时进两个桶。
//
// 非空洞性约定：每条 degraded 都配一条 ⚠️ 反向对照（同一批证据、门不该咬时必须咬出结论），
// 与 OrphanFileFinderTests.swift:45 的 `safeOrphan_stillReclaimsWhenReferenceSetIsTrustworthy` 同形。
// ============================================================================

// MARK: - 夹具

/// 定宽十六进制 ⇒ uuidString 可手算，且与路径不会撞车
private func vid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
}

private func rec(_ n: Int, _ path: String) -> MaterialRecordPath {
    MaterialRecordPath(id: vid(n), path: path)
}

/// 假探针：I/O 由调用方注入，本文件因此完全不碰文件系统 —— 这是它能进 `swift test` 的前提。
/// 精确字符串比较就够：前缀归一（R7）是 finder 的活，探针只负责回答"这条路径读数是什么"。
private func probe(_ existing: Set<String>, _ unreadable: Set<String> = [])
    -> (String) -> MaterialProbeReading {
    return { path in
        if unreadable.contains(path) { return .unreadable }
        return existing.contains(path) ? .present : .absent
    }
}

private let root = "/v"

// MARK: - 静态判据的取样与判定（TC-M13 / M14 用）
// 「不许复制第二颗归一」与「永不产出删除动作」今天只活在文件头注释里 —— 注释会被删，判据不会。
// 判定抽成对字符串的纯函数，所以能用**合成源码**自证有牙（形状照 TombstoneReadGuardTests 的
// `positiveAndNegativeHalves` / `injectedReadFlipsTheGate`），不必为取证去动生产文件。
// 剥注释复用 `RelationshipReadScan.codeOnly`（仓里已有的一颗），不另写第二份 —— 两把尺子本身就是债。

private let finderPath = "Sources/MixCutCore/MissingMaterialFinder.swift"
private let guardRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

/// 反向轴的两条硬约束 ⇒ 违规清单（空 = 合规）。
private func missingAxisViolations(code: String) -> [String] {
    var out: [String] = []
    // ① 归一只能共用 orphan 那一颗：自己再写一遍，同一个文件在两侧会被认成两个，
    //    那正是 GC 误删的形状（TC-MA-10 从行为侧守同一件事，这里从结构侧守）。
    if code.contains(".lowercased()") { out.append("自造归一：出现了 .lowercased()") }
    if code.contains("hasSuffix(\"/\"") { out.append("自造归一：自己剥末尾斜杠") }
    if !code.contains("OrphanFileFinder.normalize") { out.append("没引用共用的一颗归一") }
    // ② 本类型唯一输出是一组 id；碰文件系统或产出删除动作都越过 R1 的边界。
    //    探针是**注入**的闭包，所以这些词一个都不该出现在代码里（注释里提到 FileManager 不算）。
    for token in ["FileManager", "removeItem", ".delete(", "URL(fileURLWithPath"]
    where code.contains(token) {
        out.append("越界：出现 \(token)")
    }
    return out
}

@Suite("MissingMaterialFinder · 库↔盘反向对账的三档可信度门")
struct MissingMaterialFinderTests {

    // MARK: R1 基本形状与反向防线

    @Test("TC-M01 基本形状：只报探针明确说「不存在」的那条，present 一条都不报")
    func basicShapeReportsOnlyAbsent() {
        let records = [rec(1, "/v/a.mp4"), rec(2, "/v/b.mp4"), rec(3, "/v/c.mp4")]
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe(["/v/a.mp4", "/v/c.mp4"]),
                                                   trustedPrefixes: [root])
        #expect(out.missingIDs == [vid(2)], "只该报 b，实得 \(out.missingIDs)")
        #expect(!out.degraded && out.degradationReason == nil)
        #expect(out.excludedRecords == 0 && out.unreadableRecords == 0)
    }

    @Test("TC-M02 整目录被删（全缺）也必须报出来 —— 反向防线：不许退化成「永远给空」的假守卫")
    func allMissingIsStillReported() {
        // 这条钉的正是 safeOrphanFiles 那条字面镜像失效的现场：用户把 161 个视频整个删了 ⇒
        // 库与盘零交集 ⇒ 若照抄"零交集即不可信"，功能在最需要它的时候一声不响。
        let records = (1...5).map { rec($0, "/v/\($0).mp4") }
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe([]),
                                                   trustedPrefixes: [root])
        #expect(out.missingIDs == Set((1...5).map(vid)),
                "全缺时必须 5 条都报，实得 \(out.missingIDs.count) 条")
        #expect(!out.degraded, "全缺是**结论**，不是判据坏了：根目录在、前缀也命中")
        #expect(out.excludedRecords == 0)
    }

    // MARK: R3 第一档：素材根目录本身不在

    @Test("TC-M03 根目录不在磁盘上 ⇒ 一个 id 都不给并说明原因；⚠️ 根目录在时同样的证据必须照常报")
    func absentVideoRootYieldsNothing() {
        let records = (1...3).map { rec($0, "/v/\($0).mp4") }
        let allGone = probe([])

        let gated = MissingMaterialFinder.safeMissingIDs(records: records, probe: allGone,
                                                         trustedPrefixes: [root],
                                                         videoRootPresent: false)
        #expect(gated.missingIDs.isEmpty, "卷未挂载时按这份清单去藏卡 = 把全部素材判成丢失")
        #expect(gated.degraded)
        #expect(gated.degradationReason?.contains("素材根目录") == true,
                "原因必须说清是根目录不在，实得 \(String(describing: gated.degradationReason))")

        // ⚠️ 反向对照（防 M03 测成恒真）：根目录在、文件没了 ⇒ 这 3 条就是用户删的，必须报出来
        let open = MissingMaterialFinder.safeMissingIDs(records: records, probe: allGone,
                                                        trustedPrefixes: [root],
                                                        videoRootPresent: true)
        #expect(open.missingIDs.count == 3 && !open.degraded,
                "门只该在根目录不在时咬，实得 missing=\(open.missingIDs.count) degraded=\(open.degraded)")
        // 不走 safe 的裸查询给同样结论（safe 只加一档，不改判据）
        #expect(MissingMaterialFinder.missingIDs(records: records, probe: allGone,
                                                 trustedPrefixes: [root]).missingIDs.count == 3)
    }

    // MARK: R4 第二档：库与盘没有共同坐标

    @Test("TC-M04 库里路径没有一条落在真源目录下 ⇒ degraded（迁移未完成的样子），且 missingIDs 必空")
    func zeroPrefixHitDowngrades() {
        let records = (1...4).map { rec($0, "/old/Suncut/Videos/\($0).mp4") }
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe([]),
                                                   trustedPrefixes: ["/new/Suncut/Videos"])
        #expect(out.degraded)
        #expect(out.missingIDs.isEmpty, "R2：degraded ⇒ 一个都不许给")
        #expect(out.degradationReason?.contains("没有一条落在") == true,
                "要说清「一条都不在真源目录下」，不许伪装成没丢也不许伪装成丢了")
    }

    @Test("TC-M05 部分记录在前缀外：那些计入 excludedRecords，前缀内的照常判")
    func partialExclusionStillJudgesTheRest() {
        let records = [rec(1, "/new/Videos/a.mp4"),   // 在用
                       rec(2, "/new/Videos/b.mp4"),   // 明确没了 ⇒ 该报
                       rec(3, "/old/Videos/c.mp4"),   // 前缀外 ⇒ 排除
                       rec(4, "/old/Videos/d.mp4")]   // 前缀外 ⇒ 排除
        // 探针在前缀外一律说"存在"也无所谓：排除发生在问文件系统之前（R4 的逐条性）
        let out = MissingMaterialFinder.missingIDs(
            records: records,
            probe: probe(["/new/Videos/a.mp4", "/old/Videos/c.mp4", "/old/Videos/d.mp4"]),
            trustedPrefixes: ["/new/Videos"])
        #expect(out.missingIDs == [vid(2)])
        #expect(out.excludedRecords == 2, "实得 \(out.excludedRecords)")
        #expect(!out.degraded, "有交集就不该整轮降级 —— 那正是 M02 反向防线要防的哑火")
        #expect(out.unreadableRecords == 0)
    }

    // MARK: R7 与 orphan 同口径 + 目录边界

    @Test("TC-M06 前缀比较与 orphan 同口径（大小写 + 末尾斜杠），且兄弟目录不算在前缀内")
    func prefixMatchingSharesNormalizerAndHonoursBoundary() {
        // (a) 前缀写成 /VIDEOS/、记录写成 /videos/a.mp4 ⇒ 仍算可信前缀内。
        //     两条轴若各写一套归一，这条会掉进 excluded，再往下 judgeable 归零 ⇒ 整轮误降级。
        let records = [rec(1, "/videos/a.mp4")]
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe(["/videos/a.mp4"]),
                                                   trustedPrefixes: ["/VIDEOS/"])
        #expect(out.excludedRecords == 0 && !out.degraded,
                "前缀归一与记录不同口径 ⇒ 在用的素材被当成前缀外")
        #expect(out.missingIDs.isEmpty)

        // (b) 目录边界必须算：/Videos2 不是 /Videos 的子目录（少了这一格，旧前缀 /VideosOld
        //     之类会被认成"在册"，于是里面丢的文件全都判缺 —— 那是藏卡，不是报缺）
        let mixed = [rec(2, "/Videos/ok.mp4"), rec(3, "/Videos2/sibling.mp4")]
        let out2 = MissingMaterialFinder.missingIDs(records: mixed,
                                                    probe: probe([]),           // 两条都不在磁盘上
                                                    trustedPrefixes: ["/Videos"])
        #expect(out2.excludedRecords == 1, "兄弟目录那条必须被排除，实得 \(out2.excludedRecords)")
        #expect(out2.missingIDs == [vid(2)], "前缀内那条照常判缺；前缀外那条绝不进 missing")
        #expect(!out2.degraded)

        // (c) 极端形状：记录路径恰好等于前缀（无子路径）⇒ 算在册，不许崩也不许静默丢
        let exact = [rec(4, "/Videos")]
        let out3 = MissingMaterialFinder.missingIDs(records: exact, probe: probe([]),
                                                    trustedPrefixes: ["/Videos"])
        #expect(out3.excludedRecords == 0 && out3.missingIDs == [vid(4)])
    }

    // MARK: R6 空库不是"不知道"

    @Test("TC-M07 records 为空：空结果但**不是** degraded，且这条判定先于「根目录不在」")
    func emptyLibraryIsNotDegraded() {
        let out = MissingMaterialFinder.missingIDs(records: [], probe: probe([]),
                                                   trustedPrefixes: [root])
        #expect(out.missingIDs.isEmpty && !out.degraded && out.degradationReason == nil)
        #expect(out.excludedRecords == 0 && out.unreadableRecords == 0)

        // 顺序也要钉住：全新安装（库是空的、根目录还没建）不该弹"我查不了"
        let safe = MissingMaterialFinder.safeMissingIDs(records: [], probe: probe([]),
                                                        trustedPrefixes: [root],
                                                        videoRootPresent: false)
        #expect(!safe.degraded, "空集判定必须先于根目录判定，否则每次首装都要报一次故障")
    }

    // MARK: R8 分桶守恒

    @Test("TC-M08 分桶守恒：四类各 6 条的夹具下，missing + excluded + unreadable + present == 条数，且桶互斥")
    func bucketsPartitionTheInput() {
        // 24 条、四种形状轮转各 6 条（i%4==3 前缀外；余下按 i%3 分在用/读不动/明确不在）
        var records: [MaterialRecordPath] = []
        var existing: Set<String> = []
        var unreadable: Set<String> = []
        for i in 0..<24 {
            let path = i % 4 == 3 ? "/outside/\(i).mp4" : "/v/\(i).mp4"
            records.append(rec(100 + i, path))
            if i % 4 == 3 { continue }                     // 前缀外的不再问文件系统
            switch i % 3 {
            case 0: existing.insert(path)
            case 1: unreadable.insert(path)
            default: break                                  // 明确不在
            }
        }
        // 夹具自检：期望值全部由**输入**算出，不是由函数输出反推
        let expectExcluded = (0..<24).filter { $0 % 4 == 3 }.count                    // 6
        let expectPresent = (0..<24).filter { $0 % 4 != 3 && $0 % 3 == 0 }.count      // 6
        let expectUnreadable = (0..<24).filter { $0 % 4 != 3 && $0 % 3 == 1 }.count   // 6
        let expectMissing = 24 - expectExcluded - expectPresent - expectUnreadable    // 6
        #expect(expectExcluded == 6 && expectPresent == 6 && expectUnreadable == 6 && expectMissing == 6,
                "夹具不再四类均分，后面的期望值就失去意义")

        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe(existing, unreadable),
                                                   trustedPrefixes: [root])
        #expect(out.missingIDs.count == expectMissing)
        #expect(out.excludedRecords == expectExcluded)
        #expect(out.unreadableRecords == expectUnreadable)
        #expect(out.missingIDs.count + out.excludedRecords + out.unreadableRecords + expectPresent == records.count,
                "有档漏计或有记录进了两个桶")
        #expect(!out.degraded)

        // 桶互斥（"一条不许进两个桶"的两条具体形态）
        let excludedIDs = Set(records.filter { $0.path.hasPrefix("/outside/") }.map(\.id))
        let unreadableIDs = Set(records.filter { unreadable.contains($0.path) }.map(\.id))
        #expect(out.missingIDs.isDisjoint(with: excludedIDs), "前缀外的既被排除又被判缺")
        #expect(out.missingIDs.isDisjoint(with: unreadableIDs), "读不动的既算第三态又被判缺")
        let missingPaths = records.filter { out.missingIDs.contains($0.id) }.map(\.path)
        #expect(missingPaths.allSatisfy { $0.hasPrefix("/v/") }, "报缺的那批必须全在可信前缀内")
    }

    // MARK: 自愈与第三态

    @Test("TC-M09 文件放回原处就自动不在结果里：不并集、不粘滞，本轮读数说了算")
    func missingHealsWhenFileReturns() {
        let records = [rec(1, "/v/a.mp4"), rec(2, "/v/b.mp4")]
        let first = MissingMaterialFinder.missingIDs(records: records,
                                                     probe: probe(["/v/a.mp4"]),
                                                     trustedPrefixes: [root])
        #expect(first.missingIDs == [vid(2)])

        // 用户把 b 放回原处、同时 a 被删了 ⇒ 结论必须整体翻面
        let flipped = MissingMaterialFinder.missingIDs(records: records,
                                                       probe: probe(["/v/b.mp4"]),
                                                       trustedPrefixes: [root])
        #expect(flipped.missingIDs == [vid(1)], "写成并集就永久失去自愈能力（方案批 4 的同一条判据）")

        // 两条都在 ⇒ 空集，但不是 degraded（"没丢"与"查不了"是两句话）
        let healed = MissingMaterialFinder.missingIDs(records: records,
                                                      probe: probe(["/v/a.mp4", "/v/b.mp4"]),
                                                      trustedPrefixes: [root])
        #expect(healed.missingIDs.isEmpty && !healed.degraded)
    }

    @Test("TC-M10 探针第三态（文件在但读不动）≠ 不存在 ⇒ 该条不判缺，只进 unreadableRecords")
    func unreadableIsNotMissing() {
        let records = [rec(1, "/v/a.mp4"), rec(2, "/v/b.mp4")]
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe([], ["/v/a.mp4"]),
                                                   trustedPrefixes: [root])
        #expect(out.missingIDs == [vid(2)], "读不动的那条不许判缺（宁可多显示一张死卡）")
        #expect(out.unreadableRecords == 1)
        #expect(!out.degraded, "还有一条给出明确结论时不该整轮降级")
    }

    @Test("TC-M11 可判定的全部读不动 ⇒ 是判据坏了而不是「全丢了」：degraded 且一个都不给")
    func allUnreadableDowngrades() {
        let records = (1...4).map { rec($0, "/v/\($0).mp4") }
        let all = Set(records.map(\.path))
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe([], all),
                                                   trustedPrefixes: [root])
        #expect(out.degraded)
        #expect(out.missingIDs.isEmpty, "权限/卷未就绪时把四条都判成丢失 = 用户会去点真删")
        #expect(out.degradationReason?.contains("读不动") == true,
                "实得 \(String(describing: out.degradationReason))")

        // ⚠️ 反向对照：只要有一条读得动（在不在都算），就不是"全读不动"，其余照常判
        let mixed = MissingMaterialFinder.missingIDs(records: records,
                                                     probe: probe(["/v/1.mp4"],
                                                                  ["/v/2.mp4", "/v/3.mp4", "/v/4.mp4"]),
                                                     trustedPrefixes: [root])
        #expect(!mixed.degraded && mixed.unreadableRecords == 3 && mixed.missingIDs.isEmpty)
    }

    @Test("TC-M12 空路径是数据问题、不是文件丢失：计入 excludedRecords，不判缺也不触发降级")
    func emptyPathIsExcludedNotMissing() {
        let records = [rec(1, ""), rec(2, "/v/b.mp4")]
        let out = MissingMaterialFinder.missingIDs(records: records,
                                                   probe: probe([]),
                                                   trustedPrefixes: [root])
        #expect(out.excludedRecords == 1, "空路径不该送去问文件系统")
        #expect(out.missingIDs == [vid(2)])
        #expect(!out.degraded, "一条空路径不该把整轮判成不可信")
    }

    // MARK: TC-M13 / M14：把文件头那两条硬约束变成会红的判据

    @Test("TC-M13 反向轴不许自造第二颗归一、也不许碰文件系统（结构侧守法，与 TC-MA-10 的行为侧互补）")
    func missingAxisSharesTheOneNormalizerAndStaysPure() {
        let url = guardRepoRoot.appendingPathComponent(finderPath)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("读不到 \(finderPath) ⇒ 判据无法成立，不算通过")
            return
        }
        let violations = missingAxisViolations(code: RelationshipReadScan.codeOnly(raw))
        #expect(violations.isEmpty, "反向轴违规：\(violations)")
    }

    @Test("TC-M14 这条静态判据自己要有牙：逐种违规注入合成源码，都得报出来；合规样本必须干净")
    func staticCriterionIsNotAlwaysGreen() {
        let injected: [(String, String)] = [
            ("自造 lowercased 归一", "func normalize(_ p: String) -> String { p.lowercased() }"),
            ("自造剥末尾斜杠", "if p.hasSuffix(\"/\") { p.removeLast() }"),
            ("整颗归一改成自研", "func normalize(_ p: String) -> String { p }"),
            ("自己碰文件系统", "FileManager.default.removeItem(at: u)"),
            ("产出删除动作", "context.delete(rows)"),
            ("自己拼 URL 去删", "URL(fileURLWithPath: p)"),
        ]
        for (label, snippet) in injected {
            #expect(!missingAxisViolations(code: snippet).isEmpty,
                    "注入「\(label)」却没报出问题 ⇒ 这条判据恒绿，不算防线")
        }
        // 反向对照：合规写法判为干净，否则上面六条断言全是假信号（恒真的守卫比没有守卫更糟）
        let good = "static func normalize(_ path: String) -> String { OrphanFileFinder.normalize(path) }"
        #expect(missingAxisViolations(code: good).isEmpty, "合规样本被判违规 ⇒ 判据过咬，会把正常改动也拦下")
        // 注释里的 FileManager 不该算越界（真文件头的说明文字就在提它）
        #expect(missingAxisViolations(code: RelationshipReadScan.codeOnly(
            "/// 探针由调用方注入（App 侧走 FileManager，测试用假函数）\n"
            + "func n(_ p: String) -> String { OrphanFileFinder.normalize(p) }")).isEmpty,
                "剥注释没生效 ⇒ 说明文字会把判据变成误报机器")
    }
}
