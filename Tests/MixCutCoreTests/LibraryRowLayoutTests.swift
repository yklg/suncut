import Foundation
import Testing
@testable import MixCutCore

struct LibraryRowLayoutTests {
    private let g1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let g2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func ids(_ n: Int, prefix: Int = 0) -> [UUID] {
        (0..<n).map { i in
            // 确定性的 UUID：字节末位随 prefix/i 变化
            UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                         UInt8((prefix >> 8) & 0xFF), UInt8((prefix << 8 | i) & 0xFF)))
        }
    }

    @Test("网格模式：按列切块，末行不足列数不补位")
    func gridChunksWithoutPadding() {
        let rows = LibraryRowLayout.rows(
            for: [LibraryGroupRef(id: g1, segmentIDs: ids(5))],
            columnCount: 2, isGrid: true
        )
        // header + ceil(5/2)=3 卡片行
        guard rows.count == 4 else { Issue.record("应为 4 行，实得 \(rows.count)"); return }
        #expect(rows[0] == .header(groupID: g1))
        #expect(rows[1].id == "r-\(g1.uuidString)-0")
        guard case .cards(_, 0, let r0) = rows[1] else { Issue.record(); return }
        guard case .cards(_, 1, let r1) = rows[2] else { Issue.record(); return }
        guard case .cards(_, 2, let r2) = rows[3] else { Issue.record(); return }
        #expect(r0.count == 2)
        #expect(r1.count == 2)
        #expect(r2.count == 1, "末行只保留真实数量，不补空")
    }

    @Test("列表模式：每个分镜独占一行，忽略列数")
    func listModeOneSegmentPerRow() {
        let rows = LibraryRowLayout.rows(
            for: [LibraryGroupRef(id: g1, segmentIDs: ids(3))],
            columnCount: 4, isGrid: false
        )
        let cardRows = rows.filter {
            if case .cards = $0 { return true }
            return false
        }
        #expect(rows.count == 4)
        #expect(cardRows.allSatisfy {
            if case .cards(_, _, let sids) = $0 { return sids.count == 1 }
            return false
        })
    }

    @Test("列数 ≤0 clamp 到 1；单元素组正常")
    func clampsColumnCountAndHandlesSingle() {
        let rows = LibraryRowLayout.rows(
            for: [LibraryGroupRef(id: g1, segmentIDs: ids(1))],
            columnCount: 0, isGrid: true
        )
        #expect(rows.count == 2)
        guard case .cards(_, _, let sids) = rows[1] else { Issue.record(); return }
        #expect(sids.count == 1)
    }

    @Test("空组不产任何行")
    func emptyGroupsProduceNoRows() {
        let rows = LibraryRowLayout.rows(
            for: [
                LibraryGroupRef(id: g1, segmentIDs: []),
                LibraryGroupRef(id: g2, segmentIDs: ids(1)),
            ],
            columnCount: 2, isGrid: true
        )
        #expect(rows.map(\.id) == ["h-\(g2.uuidString)", "r-\(g2.uuidString)-0"])
    }

    @Test("多组：行 id 带组前缀且行序各自从 0 起，全局不撞 id")
    func idsAreNamespacedPerGroup() {
        let rows = LibraryRowLayout.rows(
            for: [
                LibraryGroupRef(id: g1, segmentIDs: ids(3, prefix: 1)),
                LibraryGroupRef(id: g2, segmentIDs: ids(2, prefix: 2)),
            ],
            columnCount: 2, isGrid: true
        )
        #expect(rows.map(\.id) == [
            "h-\(g1.uuidString)",
            "r-\(g1.uuidString)-0",
            "r-\(g1.uuidString)-1",
            "h-\(g2.uuidString)",
            "r-\(g2.uuidString)-0",
        ])
        #expect(Set(rows.map(\.id)).count == rows.count, "行 id 必须全局唯一")
    }

    @Test("筛选/排序变化：同位置行 id 稳定（身份随组+行序，不随内容）")
    func rowIdentityStableAcrossContentChange() {
        let all = LibraryRowLayout.rows(
            for: [LibraryGroupRef(id: g1, segmentIDs: ids(4))],
            columnCount: 2, isGrid: true
        )
        // 筛选掉第一个分镜，列数不变：第一行 id 不变，只是承载的 id 变了。
        let filtered = LibraryRowLayout.rows(
            for: [LibraryGroupRef(id: g1, segmentIDs: Array(ids(4).dropFirst()))],
            columnCount: 2, isGrid: true
        )
        #expect(filtered.map(\.id) == ["h-\(g1.uuidString)", "r-\(g1.uuidString)-0", "r-\(g1.uuidString)-1"])
        #expect(all.map(\.id).first == filtered.map(\.id).first)
    }

    @Test("列数变化：内容顺序守恒（按列切块再拼回等于原顺序）")
    func orderPreservedAcrossColumnReflow() {
        let segs = ids(7)
        for cols in 1...5 {
            let rows = LibraryRowLayout.rows(
                for: [LibraryGroupRef(id: g1, segmentIDs: segs)],
                columnCount: cols, isGrid: true
            )
            let flattened: [UUID] = rows.flatMap {
                if case .cards(_, _, let sids) = $0 { return sids }
                return []
            }
            #expect(flattened == segs, "列数 \(cols) 重排后分镜顺序必须守恒")
        }
    }
}
