import Foundation
import Testing
@testable import MixCutCore

/// ProductOwnershipBackfill 规则测试（B1-B5）。
/// 夹具约定沿用 ProjectVideoDedupTests：项目 id(100+)、视频 id(200+)、关联行 id(1+)，
/// 时间用相对 t0 的偏移，手算期望不靠数组下标。
struct ProductOwnershipBackfillTests {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
    }
    private let t0 = 812_267_661.0
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

    @Test("B1 同一视频多项目关联 → addedAt 最早的项目")
    func earliestProjectWins() {
        let map = ProductOwnershipBackfill.ownerProjectIDByVideoID([
            row(1, project: 0, video: 0, at: 30),
            row(2, project: 1, video: 0, at: 10),
            row(3, project: 2, video: 0, at: 20),
        ])
        #expect(map[id(200)] == id(101))
    }

    @Test("B2 addedAt 平局 → projectID 字典序最小，不依赖输入顺序")
    func tieBreakByProjectID() {
        // 同刻关联给项目 2 与项目 1（故意把大的放前面）→ 必须选 101
        let map = ProductOwnershipBackfill.ownerProjectIDByVideoID([
            row(1, project: 2, video: 0, at: 10),
            row(2, project: 1, video: 0, at: 10),
        ])
        #expect(map[id(200)] == id(101))
    }

    @Test("B3 悬挂行不参与；只有悬挂行的视频不进结果")
    func danglingRowsIgnored() {
        let map = ProductOwnershipBackfill.ownerProjectIDByVideoID([
            dangling(1, project: nil, video: 0, at: 5),
            dangling(2, project: 1, video: nil, at: 6),
            row(3, project: 1, video: 1, at: 7),
        ])
        #expect(map[id(200)] == nil, "视频 200 只有悬挂行，不应被回填")
        #expect(map[id(201)] == id(101))
    }

    @Test("B4 与 Dedup 衔接：喂入 retained（每组一条）结果正确；重复行也不影响取最早")
    func worksWithDedupOutputAndDuplicates() {
        let raw: [ProjectVideoAssociation] = [
            row(1, project: 1, video: 0, at: 30),
            row(2, project: 1, video: 0, at: 99),   // 同 (project,video) 重复脏行
            row(3, project: 0, video: 0, at: 10),
        ]
        let deduped = ProjectVideoDedup.deduplicate(raw).retained
        let map = ProductOwnershipBackfill.ownerProjectIDByVideoID(deduped)
        #expect(map[id(200)] == id(100))
        // 直接喂未 dedup 的脏输入，自防御结果一致
        let mapRaw = ProductOwnershipBackfill.ownerProjectIDByVideoID(raw)
        #expect(mapRaw == map)
    }

    @Test("B5 幂等：输出是确定性映射，多视频各归各位且再次计算不变")
    func idempotentAndMultiVideo() {
        let input: [ProjectVideoAssociation] = [
            row(1, project: 0, video: 0, at: 10),
            row(2, project: 1, video: 1, at: 5),
            row(3, project: 2, video: 2, at: 8),
        ]
        let first = ProductOwnershipBackfill.ownerProjectIDByVideoID(input)
        let second = ProductOwnershipBackfill.ownerProjectIDByVideoID(input)
        #expect(first == second)
        #expect(first == [id(200): id(100), id(201): id(101), id(202): id(102)])
    }
}
