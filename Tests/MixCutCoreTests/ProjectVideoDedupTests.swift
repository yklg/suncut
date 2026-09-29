import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 计划 docs/superpowers/plans/2026-09-28-duplicate-project-video-crash.md v5 · §8.3 TC-01…TC-15
//
// 本文件锁定的接口（实现必须逐字满足，否则这些用例不算通过）：
//
//   public struct ProjectVideoAssociation: Sendable, Hashable {
//       public let pvID: UUID
//       public let projectID: UUID?     // nil = 悬挂关联（关系对象取不到）
//       public let videoID: UUID?       // nil = 悬挂关联
//       public let addedAt: Date        // Core Data 与 Date 同为 referenceDate(2001-01-01) 时钟
//       public init(pvID: UUID, projectID: UUID?, videoID: UUID?, addedAt: Date)
//   }
//   public struct ProjectVideoDedupResult: Sendable, Equatable {
//       public let retained: [ProjectVideoAssociation]                       // 每组恰一条，可解析行
//       public let deleted: Set<UUID>                                        // 应删的 pvID
//       public let untouched: Set<UUID>                                      // 悬挂行的 pvID
//       public func retainedVideos(inProject: UUID) -> [UUID]                // 按 addedAt 升序
//       public func videoNoByVideoID(inProject: UUID) -> [UUID: Int]         // 1-based、连续、无跳号
//   }
//   public enum ProjectVideoDedup {
//       public static func deduplicate(_ rows: [ProjectVideoAssociation]) -> ProjectVideoDedupResult
//   }
//
// 规则（§3.4）：
//   R1 分组键 = (projectID, videoID)，每组只留一条；
//   R2 组内选择 = addedAt 最早；addedAt 相等时按 pvID.uuidString 字典序最小（INV-T，先例 MixScheme.swift:69-75）；
//   R3 组间顺序 = addedAt 升序，tie 同上 —— **顺序不能依赖输入数组的下标**；
//   R4 对**可解析行**：deleted ∩ retained = ∅，且 deleted ∪ retained = 输入全部可解析行的 pvID；
//   R5 **每组的保留数恰好为 1**（INV-B：这条挡住孤儿 GC 误删磁盘文件，见 §3.4 硬约束 1）；
//   R6 deduplicate(retained) 的 deleted 必须为空（INV-D 幂等）；
//   R7 **悬挂行（projectID 或 videoID 为 nil）不删、不留、不编号** —— 它既进不了分组，
//      也绝不能被顺手删掉（既有自愈路径 recoverFromDisk 可能把它接回去），
//      但它也不得计入 `videoCount`（与 MCP 既有口径 MCPToolHandlers.swift:84 一致）。
//
// 非空洞性论证（实现若写错，哪一条会红）：
//   - 写成「留最后一条」          → TC-03 / TC-04 / TC-15 / TC-14 的「留最早」性质红
//   - 写成「按数组顺序留首条」    → TC-05 / TC-14 红
//   - 忘 tie-break（不稳定序）    → TC-06 / TC-14 红
//   - 分组只按 videoID（忽略项目）→ TC-07 / TC-12 红（这条最危险：会删掉别的项目的关联）
//   - 编号从 0 起或跳号           → TC-02 / TC-10 红
//   - 不幂等（二次仍删）          → TC-09 红
//   - 顺手删悬挂行                → TC-11 红
//   注意：本文件**故意不调用** `Dictionary(uniqueKeysWithValues:)` —— 重复键会 SIGTRAP 打死测试进程，
//   把「断言失败」变成「崩溃」，所以 TC-10 用集合基数判定表达同一个契约。
// ============================================================================

// MARK: - 夹具工厂（沿用仓内「本地工厂」约定，见 NarrativeStructureEngineTests 的 seg()）

/// 定宽十六进制 ⇒ uuidString 的字典序 == 数值序，tie-break 的期望值才可手算
private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
}

/// Core Data 的 referenceDate 与 Date(timeIntervalSinceReferenceDate:) 同为 2001-01-01
private let t0 = 812_267_661.826909

/// 约定：项目用 id(100...)、视频用 id(200...)、关联行用 id(1...)，三者不重叠，
/// 否则「项目 1 的编号」这类断言会因为 UUID 相同而失去意义。
private func row(_ pv: Int, project p: Int, video v: Int, at offset: Double) -> ProjectVideoAssociation {
    ProjectVideoAssociation(pvID: id(pv), projectID: id(100 + p), videoID: id(200 + v),
                            addedAt: Date(timeIntervalSinceReferenceDate: t0 + offset))
}

private func dangling(_ pv: Int, project p: Int?, video v: Int?, at offset: Double = 0) -> ProjectVideoAssociation {
    ProjectVideoAssociation(pvID: id(pv),
                            projectID: p == nil ? nil : id(100 + p!),
                            videoID: v == nil ? nil : id(200 + v!),
                            addedAt: Date(timeIntervalSinceReferenceDate: t0 + offset))
}

private func groupKey(_ r: ProjectVideoAssociation) -> String {
    "\(r.projectID?.uuidString ?? "nil")/\(r.videoID?.uuidString ?? "nil")"
}

private func groups(_ rows: [ProjectVideoAssociation]) -> Set<String> {
    Set(rows.map(groupKey))
}

private func keptPerGroup(_ rows: [ProjectVideoAssociation]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for r in rows { counts[groupKey(r), default: 0] += 1 }
    return counts
}

private func resolvable(_ rows: [ProjectVideoAssociation]) -> [ProjectVideoAssociation] {
    rows.filter { $0.projectID != nil && $0.videoID != nil }
}

@Suite("项目-视频关联去重（挂载层集合语义）")
struct ProjectVideoDedupTests {

    // MARK: TC-01 / TC-02 空与最小

    @Test("TC-01 空输入：不删任何行、无编号")
    func emptyInput() {
        let out = ProjectVideoDedup.deduplicate([])
        #expect(out.deleted.isEmpty)
        #expect(out.retained.isEmpty)
        #expect(out.untouched.isEmpty)
        #expect(out.retainedVideos(inProject: id(101)).isEmpty)
        #expect(out.videoNoByVideoID(inProject: id(101)).isEmpty)
    }

    @Test("TC-02 单条关联：保留、不删、编号为 1")
    func singleRow() {
        let out = ProjectVideoDedup.deduplicate([row(1, project: 1, video: 7, at: 0)])
        #expect(out.deleted.isEmpty)
        #expect(out.retained.count == 1)
        #expect(out.videoNoByVideoID(inProject: id(101)) == [id(207): 1])
    }

    // MARK: TC-03 / TC-04 组内留最早

    @Test("TC-03 同组两行：留 addedAt 较早的，删较晚的")
    func twoRowsKeepEarliest() {
        let early = row(1, project: 1, video: 7, at: 0.0)
        let late = row(2, project: 1, video: 7, at: 0.178)   // 实测肇因两行相差 0.177204 秒
        let out = ProjectVideoDedup.deduplicate([early, late])
        #expect(out.deleted == [late.pvID])
        #expect(out.retained.map(\.pvID) == [early.pvID])
    }

    @Test("TC-04 同组三行：只留最早一条，删掉其余两条")
    func threeRowsKeepOnlyEarliest() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 1, video: 7, at: 5.0),
                    row(3, project: 1, video: 7, at: 2.5)]
        let out = ProjectVideoDedup.deduplicate(rows)
        #expect(out.deleted == [id(2), id(3)])
        #expect(out.retained.count == 1)
        #expect(out.retained[0].pvID == id(1))
    }

    // MARK: TC-05 输入顺序无关（防「按数组顺序留首条」的假实现）

    @Test("TC-05 乱序输入：删除集合与保留顺序都相同")
    func inputOrderDoesNotMatter() {
        let canonical = [row(1, project: 1, video: 7, at: 0.0),   // 最早
                         row(2, project: 1, video: 8, at: 1.0),
                         row(3, project: 1, video: 7, at: 2.0)]   // 与 1 同组、较晚
        let shuffled = [canonical[2], canonical[0], canonical[1]]
        let a = ProjectVideoDedup.deduplicate(canonical)
        let b = ProjectVideoDedup.deduplicate(shuffled)
        #expect(a.deleted == b.deleted)
        #expect(a.deleted == [id(3)])
        #expect(a.retained.map(\.pvID) == b.retained.map(\.pvID))
        #expect(a.videoNoByVideoID(inProject: id(101)) == b.videoNoByVideoID(inProject: id(101)))
    }

    // MARK: TC-06 INV-T：tie-break 必须确定（否则 video_no 跨启动漂移）

    @Test("TC-06 addedAt 完全相等：按 pvID.uuidString 字典序留首条，编号稳定")
    func tieBreakIsDeterministic() {
        let smaller = row(2, project: 1, video: 7, at: 0.5)
        let larger = row(9, project: 1, video: 7, at: 0.5)     // 与 smaller 同一 addedAt
        #expect(smaller.addedAt == larger.addedAt)                 // 夹具自证：真的构成 tie
        #expect(smaller.pvID.uuidString < larger.pvID.uuidString)   // 期望值来源：字典序

        let ab = ProjectVideoDedup.deduplicate([smaller, larger])
        let ba = ProjectVideoDedup.deduplicate([larger, smaller])
        #expect(ab.deleted == [larger.pvID])
        #expect(ba.deleted == [larger.pvID])                        // 与传入顺序无关
        #expect(ab.retained.map(\.pvID) == ba.retained.map(\.pvID))
        #expect(ab.videoNoByVideoID(inProject: id(101)) == [id(207): 1])
    }

    // MARK: TC-07 INV-E：跨项目不得误伤（最危险的一条）

    @Test("TC-07 同一 video 关联到不同项目：一条都不能删，各自有各自编号")
    func sameVideoInTwoProjectsIsNotDuplicate() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 2, video: 7, at: 0.0),   // 同 video、不同 project
                    row(3, project: 2, video: 8, at: 1.0)]
        let out = ProjectVideoDedup.deduplicate(rows)
        #expect(out.deleted.isEmpty)
        #expect(out.retained.count == 3)
        #expect(out.retainedVideos(inProject: id(101)) == [id(207)])
        #expect(out.videoNoByVideoID(inProject: id(101)) == [id(207): 1])
        // 编号口径是「项目内」，两个项目各自从 1 起
        #expect(out.videoNoByVideoID(inProject: id(102)) == [id(207): 1, id(208): 2])
    }

    // MARK: TC-08 INV-B：每组至少留一条（挡住孤儿 GC 删用户文件）

    @Test("TC-08 只有重复行的极端输入：每组保留数恰好为 1，绝不归零")
    func everyGroupKeepsExactlyOne() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 1, video: 7, at: 0.1),
                    row(3, project: 1, video: 7, at: 0.2),
                    row(4, project: 1, video: 8, at: 0.3)]
        let out = ProjectVideoDedup.deduplicate(rows)
        let inputGroups = groups(rows)
        #expect(groups(out.retained) == inputGroups)                 // 组没少
        for (_, count) in keptPerGroup(out.retained) { #expect(count == 1) }
        #expect(out.retained.count == inputGroups.count)
        // 每个 video 至少还剩一条关联 ⇒ 引用计数不可能归零 ⇒ 磁盘文件不会被孤儿 GC 收走
        for video in Set(rows.compactMap(\.videoID)) {
            #expect(out.retained.contains { $0.videoID == video })
        }
    }

    // MARK: TC-09 INV-D：幂等（测规则本身，不是测 UserDefaults 开关）

    @Test("TC-09 对已净数据再跑一次：删 0 条、保留集不变")
    func secondRunDeletesNothing() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 1, video: 7, at: 0.1),
                    row(3, project: 1, video: 8, at: 0.2),
                    row(4, project: 2, video: 8, at: 0.2),
                    row(5, project: 1, video: 7, at: 0.3)]
        let first = ProjectVideoDedup.deduplicate(rows)
        #expect(first.deleted.count == 2)
        let second = ProjectVideoDedup.deduplicate(first.retained)
        #expect(second.deleted.isEmpty)
        #expect(second.retained.map(\.pvID) == first.retained.map(\.pvID))
        #expect(second.videoNoByVideoID(inProject: id(101)) == first.videoNoByVideoID(inProject: id(101)))
    }

    // MARK: TC-10 INV-G：编号连续、唯一（这就是原来崩的那处的契约）

    @Test("TC-10 编号从 1 起、连续无跳号、videoID 键唯一")
    func numberingIsContiguousAndUnique() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 1, video: 7, at: 0.1),
                    row(3, project: 1, video: 8, at: 0.2),
                    row(4, project: 1, video: 9, at: 0.3),
                    row(5, project: 1, video: 8, at: 0.4)]
        let out = ProjectVideoDedup.deduplicate(rows)
        let map = out.videoNoByVideoID(inProject: id(101))
        let ordered = out.retainedVideos(inProject: id(101))
        #expect(ordered.count == 3)                                  // 三个不同视频
        #expect(Set(ordered).count == ordered.count)                 // 键唯一 ⇒ 原崩溃点不再可能 trap
        #expect(map.values.sorted() == [1, 2, 3])                    // 连续、从 1 起、无跳号
        #expect(ordered.enumerated().allSatisfy { map[$0.element] == $0.offset + 1 })  // 编号与列表同序
    }

    // MARK: TC-11 INV-H / R7：悬挂行不删、不留、不编号

    @Test("TC-11 悬挂关联（video 或 project 取不到）：既不删也不计入编号")
    func danglingRowsAreNeitherDeletedNorNumbered() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 1, video: 8, at: 0.1),
                    dangling(3, project: 1, video: nil),      // video 取不到
                    dangling(4, project: nil, video: 9)]      // project 取不到
        let out = ProjectVideoDedup.deduplicate(rows)
        #expect(out.deleted.isEmpty)                             // 不顺手删（recoverFromDisk 可能接回去）
        #expect(out.untouched == [id(3), id(4)])                 // 明确记为「不动」
        #expect(out.retained.map(\.pvID) == [id(1), id(2)])      // 不进保留序列
        #expect(out.retained.count == 2)                         // 悬挂行没把计数撑大
        #expect(out.videoNoByVideoID(inProject: id(101)) == [id(207): 1, id(208): 2])
        #expect(out.videoNoByVideoID(inProject: UUID()).isEmpty) // 未知项目 ⇒ 空，不是崩
        #expect(out.retainedVideos(inProject: UUID()).isEmpty)
    }

    // MARK: TC-12 混合场景

    @Test("TC-12 重复组 + 唯一组 + 另一项目同名视频：恰好删 1 条")
    func mixedScenario() {
        let rows = [row(1, project: 1, video: 7, at: 0.0),
                    row(2, project: 1, video: 7, at: 0.178),   // 重复 ⇒ 该删
                    row(3, project: 1, video: 8, at: 0.2),     // 唯一
                    row(4, project: 2, video: 8, at: 0.3)]     // 同 video 另一项目 ⇒ 不能删
        let out = ProjectVideoDedup.deduplicate(rows)
        #expect(out.deleted == [id(2)])
        #expect(out.retained.count == 3)
        #expect(out.retainedVideos(inProject: id(101)) == [id(207), id(208)])
        #expect(out.videoNoByVideoID(inProject: id(102)) == [id(208): 1])
    }

    // MARK: TC-13 规模（PERF-01：启动迁移路径，历史上「每次启动同步跑」拖慢过冷启动）

    @Test("TC-13 1000 行 = 250 组各 4 条：结果正确，且耗时不随规模爆增")
    func scaleOn1000Rows() {
        let small = scaleRows(count: 100)      // 25 组
        let large = scaleRows(count: 1000)     // 250 组
        let t1 = Date()
        _ = ProjectVideoDedup.deduplicate(small)
        let smallElapsed = Date().timeIntervalSince(t1)

        let t2 = Date()
        let out = ProjectVideoDedup.deduplicate(large)
        let largeElapsed = Date().timeIntervalSince(t2)

        #expect(groups(out.retained).count == 250)
        for (_, count) in keptPerGroup(out.retained) { #expect(count == 1) }
        #expect(out.retained.count + out.deleted.count == large.count)
        #expect(out.videoNoByVideoID(inProject: id(101)).values.sorted() == Array(1...250))
        // 判据是**相对**上界而不是拍的毫秒数：数据 10 倍 ⇒ 耗时不该超 40 倍（n log n 期望约 11 倍，留 4 倍余量）。
        // 这条只挡"O(n²)/主线程卡死"级别的实现；真实毫秒数要在首次跑绿后回填进计划。
        #expect(largeElapsed < max(smallElapsed * 40, 0.2),
                "1000 行耗时 \(largeElapsed)s 相对 100 行的 \(smallElapsed)s 增长异常")
    }

    // MARK: TC-14 手写确定性伪随机属性测试（不引外部依赖，Package.swift dependencies 为空）

    @Test("TC-14 固定种子随机数据：INV-B 每组留 1 / 留最早 / INV-D 幂等 / INV-F 与输入顺序无关")
    func propertyBasedWithSeededGenerator() {
        var rng = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
        var rows: [ProjectVideoAssociation] = []
        for i in 0..<900 {
            // pvID 由行号唯一化 ⇒ 不会偶然撞出同一个 pvID 让断言失去意义（撞车概率曾约 4.5%）
            rows.append(ProjectVideoAssociation(
                pvID: id(i + 1),
                projectID: id(100 + Int(rng.next() % 4) + 1),
                videoID: id(200 + Int(rng.next() % 30) + 1),
                addedAt: Date(timeIntervalSinceReferenceDate: t0 + Double(rng.next() % 10_000) / 1000.0)))
        }
        // 夹具自检：必须有重复组，否则整条用例空过（假绿）
        let inputGroups = groups(rows)
        #expect(rows.count > inputGroups.count, "夹具没造出重复组，这条用例无意义")
        #expect(inputGroups.count > 1, "夹具只造出一组，跨项目/跨视频的性质没被走到")

        let out = ProjectVideoDedup.deduplicate(rows)
        // 期望值全部由**输入**推出，不由函数输出推出 ⇒ 不是自证恒真
        #expect(groups(out.retained) == inputGroups)
        #expect(Set(out.retained.map(\.pvID)).count == out.retained.count)
        for g in inputGroups { #expect(out.retained.contains { groupKey($0) == g }) }
        let keptIDs = Set(out.retained.map(\.pvID))
        let inputIDs = Set(resolvable(rows).map(\.pvID))
        #expect(out.deleted.isDisjoint(with: keptIDs))
        #expect(keptIDs.union(out.deleted) == inputIDs)                 // R4
        #expect(out.untouched.isEmpty)                                  // 夹具里没有悬挂行
        // 「留最早」的无 oracle 表达：每条被删的行，同组里必须存在一条更早（或 tie 时字典序更小）的保留行
        let byGroup = Dictionary(grouping: out.retained, by: groupKey)
        for deleted in rows where out.deleted.contains(deleted.pvID) {
            let mates = byGroup[groupKey(deleted)] ?? []
            #expect(mates.contains { keeper in
                keeper.addedAt < deleted.addedAt
                    || (keeper.addedAt == deleted.addedAt && keeper.pvID.uuidString < deleted.pvID.uuidString)
            }, "删掉了 \(deleted.pvID) 但同组没有更早的保留行")
        }
        // INV-D 幂等
        #expect(ProjectVideoDedup.deduplicate(out.retained).deleted.isEmpty)
        // INV-F 打乱再跑
        var rng2 = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)
        var shuffled = rows
        for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let j = Int(rng2.next() % UInt64(i + 1))
            shuffled.swapAt(i, j)
        }
        let out2 = ProjectVideoDedup.deduplicate(shuffled)
        #expect(out2.deleted == out.deleted)
        #expect(out2.retained.map(\.pvID) == out.retained.map(\.pvID))
    }

    // MARK: TC-15 真实存量快照（MIG-01）

    @Test("TC-15 线上库快照 6 行（1 组重复）：恰好删较晚那条，另一项目的同名视频不动")
    func productionSnapshotBaseline() {
        // 取自 .scratch/db-v3/MixCut.store（store+wal+shm 的只读副本，未碰运行库），计划 §0.2 第 4 条：
        // ZPROJECTVIDEO 共 6 行，重复组 = (project 19bf…09cb, video eb96…92f8)，两行 addedAt 差 0.177204 秒
        let prjA = UUID(uuidString: "19BF3727-7D1E-4703-8B68-8FDE366A09CB")!
        let prjB = UUID(uuidString: "6C1B0212-3B22-4401-A1E7-CD5D10C91432")!
        let vid1 = UUID(uuidString: "32435718-B019-4C3F-8C6E-12D3D47E10B2")!
        let vid2 = UUID(uuidString: "EB96722D-8D0D-4787-9825-1E3DA9FB92F8")!
        let vid3 = UUID(uuidString: "69768557-8901-4EEA-87C1-D36209434F04")!
        let vid4 = UUID(uuidString: "92037D18-7D83-4A98-B502-07C525991FE4")!
        let dupID = UUID(uuidString: "E7931D11-5E74-4EFC-B642-6EE15D296243")!
        func real(_ s: String, _ p: UUID, _ v: UUID, _ t: Double) -> ProjectVideoAssociation {
            ProjectVideoAssociation(pvID: UUID(uuidString: s)!, projectID: p, videoID: v,
                                    addedAt: Date(timeIntervalSinceReferenceDate: t))
        }
        let rows = [
            real("E36E3608-8F9F-4B73-97B4-29F3FC9BAA2F", prjA, vid1, 812_267_661.826909),
            real("3CF282AC-0C10-4CD9-B815-C61B7D5D1BB3", prjA, vid2, 812_267_662.051408),  // 较早 ⇒ 留
            real("65C5FB7B-F3B0-409C-A59F-7A9AB6FF4840", prjA, vid3, 812_267_662.122584),
            real("EC62E7B6-B616-4AFF-A24C-F2DDCA6B4A6E", prjA, vid4, 812_267_662.179988),
            real("E7931D11-5E74-4EFC-B642-6EE15D296243", prjA, vid2, 812_267_662.228612),  // 较晚 ⇒ 该删
            real("3D82ECD7-B269-407B-BC28-09F6A523B0C3", prjB, vid3, 812_279_134.428786),  // 另一项目 ⇒ 不动
        ]
        let out = ProjectVideoDedup.deduplicate(rows)
        #expect(out.deleted == [dupID])
        #expect(out.retained.count == 5)
        #expect(out.videoNoByVideoID(inProject: prjA) == [vid1: 1, vid2: 2, vid3: 3, vid4: 4])
        #expect(out.retainedVideos(inProject: prjA).count == 4)     // 概览「已导入视频」5 → 4 的同源判据
        #expect(out.videoNoByVideoID(inProject: prjB) == [vid3: 1])
    }
}

// MARK: - 夹具与随机源

/// TC-13 用的规模夹具：count 行、每 4 行一组（同 project），视频数 = count/4
private func scaleRows(count: Int) -> [ProjectVideoAssociation] {
    var rows: [ProjectVideoAssociation] = []
    rows.reserveCapacity(count)
    for i in 0..<(count / 2) {
        let video = i % (count / 4)
        rows.append(row(1 + i, project: 1, video: video + 1, at: Double(i) * 0.001))
        rows.append(row(1 + count / 2 + i, project: 1, video: video + 1, at: Double(i) * 0.001 + 0.0005))
    }
    return rows
}

/// 测试内部的确定性随机源（不引外部依赖，保证可复现）
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
