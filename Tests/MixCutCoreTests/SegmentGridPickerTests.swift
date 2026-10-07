import Foundation
import Testing
@testable import MixCutCore

/// SegmentGridPicker 选择器纯逻辑测试（GP-1 ~ GP-13）+ SchemeFocus（SF-1 ~ SF-5）。
struct SegmentGridPickerTests {

    private let vidA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let vidB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private let segs: [GridPickerSegment] = [
        GridPickerSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                          videoID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                          videoName: "视频A", sourceRaw: "curated", duration: 2.4,
                          segmentIndex: "seg_101",
                          tagNames: ["噱头引入", "痛点"], text: "苹果梨都吃腻了，想找水分大的"),
        GridPickerSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                          videoID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                          videoName: "视频A", sourceRaw: "selfShot", duration: 3.1,
                          segmentIndex: "seg_102",
                          tagNames: ["行动号召"], text: "点击小黄车下单"),
        GridPickerSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                          videoID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
                          videoName: "视频B", sourceRaw: "curated", duration: 5,
                          segmentIndex: "seg_201",
                          tagNames: ["效果展示"], text: "回购三次都一样甜"),
        GridPickerSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                          videoID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
                          videoName: "视频B", sourceRaw: "", duration: 2.6,
                          segmentIndex: "seg_202",
                          tagNames: ["噱头引入"], text: "Unrelated English Line"),
    ]

    private var id101: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000101")! }
    private var id102: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000102")! }
    private var id201: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000201")! }
    private var id202: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000202")! }

    private func ids(_ r: [GridPickerSegment]) -> Set<UUID> { Set(r.map(\.id)) }

    // MARK: GP-1 搜索

    @Test func GP1_searchMatchesSubstringCaseInsensitive() {
        #expect(ids(SegmentGridPicker.filter(segs, .init(searchText: "小黄车"))) == [id102])
        #expect(ids(SegmentGridPicker.filter(segs, .init(searchText: "english"))) == [id202])
        #expect(ids(SegmentGridPicker.filter(segs, .init(searchText: "都"))) == [id101, id201])
    }

    @Test func GP2_searchBlankOrWhitespaceIsNoFilter() {
        #expect(SegmentGridPicker.filter(segs, .init(searchText: "")).count == 4)
        #expect(SegmentGridPicker.filter(segs, .init(searchText: "   ")).count == 4)
        #expect(SegmentGridPicker.filter(segs, .init(searchText: "  小黄车  ")).count == 1)
    }

    // MARK: GP-3 来源

    @Test func GP3_sourceFiltersExactAndUnclassifiedEmptyRaw() {
        #expect(ids(SegmentGridPicker.filter(segs, .init(sourceRaw: "selfShot"))) == [id102])
        #expect(ids(SegmentGridPicker.filter(segs, .init(sourceRaw: ""))) == [id202])  // 未分类
        #expect(ids(SegmentGridPicker.filter(segs, .init(sourceRaw: "curated"))) == [id101, id201])
    }

    // MARK: GP-4 视频

    @Test func GP4_videoFilterKeepsAllSegmentsOfThatVideoOnly() {
        #expect(ids(SegmentGridPicker.filter(segs, .init(videoID: vidA))) == [id101, id102])
        #expect(ids(SegmentGridPicker.filter(segs, .init(videoID: vidB))) == [id201, id202])
    }

    // MARK: GP-5 标签交集

    @Test func GP5_requiredTagsUseAnyHitIntersection() {
        #expect(ids(SegmentGridPicker.filter(segs, .init(requiredTags: ["噱头引入"])))
                == [id101, id202])
        // 多标签所求：分镜任一命中即可
        #expect(ids(SegmentGridPicker.filter(segs, .init(requiredTags: ["行动号召", "效果展示"])))
                == [id102, id201])
        // 零交集
        #expect(SegmentGridPicker.filter(segs, .init(requiredTags: ["信任背书"])).isEmpty)
        // 空标签集合=不过滤
        #expect(SegmentGridPicker.filter(segs, .init(requiredTags: [])).count == 4)
    }

    // MARK: GP-6 四维可交换

    @Test func GP6_fourDimensionsComposeAsIntersection() {
        let one = SegmentGridPicker.filter(segs, .init(
            searchText: "甜", sourceRaw: "curated", videoID: vidB, requiredTags: ["效果展示"]))
        // 逐维独立子集再交集
        let bySearch = SegmentGridPicker.filter(segs, .init(searchText: "甜"))
        let bySource = SegmentGridPicker.filter(segs, .init(sourceRaw: "curated"))
        let byVideo = SegmentGridPicker.filter(segs, .init(videoID: vidB))
        let byTag = SegmentGridPicker.filter(segs, .init(requiredTags: ["效果展示"]))
        let manual = ids(bySearch).intersection(ids(bySource)).intersection(ids(byVideo)).intersection(ids(byTag))
        #expect(ids(one) == manual)
        #expect(ids(one) == [id201])
    }

    // MARK: GP-7 计数同源

    @Test func GP7_tagMatchedCountMatchesTagOnlyFilter() {
        let tags: Set = ["噱头引入"]
        let count = SegmentGridPicker.tagMatchedCount(segs, requiredTags: tags)
        #expect(count == SegmentGridPicker.filter(segs, .init(requiredTags: tags)).count)
        // 空标签：标签匹配数=全部
        #expect(SegmentGridPicker.tagMatchedCount(segs, requiredTags: []) == 4)
        // 加了搜索后网格更少，但标签匹配统计仍是标签维口径（2）
        #expect(SegmentGridPicker.tagMatchedCount(segs, requiredTags: tags) == 2)
        #expect(SegmentGridPicker.filter(segs, .init(searchText: "english", requiredTags: tags)).count == 1)
    }

    // MARK: GP-8 视频分组

    @Test func GP8_videoGroupsAggregateByFirstSeenOrderAndCount() {
        let groups = SegmentGridPicker.videoGroups(segs)
        #expect(groups.map(\.id) == [vidA, vidB])
        #expect(groups.map(\.count) == [2, 2])
        #expect(groups.first?.name == "视频A")
        #expect(SegmentGridPicker.videoGroups([]).isEmpty)
    }

    // MARK: GP-9/10/11 占用

    private let scene1 = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private let scene2 = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

    @Test func GP9_occupancyIsSegmentGranularOtherSegmentSameVideoUnaffected() {
        // 仅 A 视频的 101 被 scene1 占用；同视频的 102 不应被标记
        let claimed: [UUID: GridPickerClaim] = [
            id101: .init(sceneID: scene1, sceneOrder: 1, sceneTag: "噱头引入"),
        ]
        let occ = SegmentGridPicker.occupancy(claimed: claimed, currentSlotSceneID: scene2)
        #expect(Set(occ.map(\.segmentID)) == [id101])
        #expect(occ.first?.sceneOrder == 1)
    }

    @Test func GP10_occupancyExemptsCurrentSlotOwnClaim() {
        let claimed: [UUID: GridPickerClaim] = [
            id101: .init(sceneID: scene1, sceneOrder: 1, sceneTag: "噱头引入"),
            id102: .init(sceneID: scene2, sceneOrder: 2, sceneTag: "行动号召"),
        ]
        // 当前在 scene1 挑选：它自己的 101 豁免，只剩 scene2 的 102
        let occ = SegmentGridPicker.occupancy(claimed: claimed, currentSlotSceneID: scene1)
        #expect(Set(occ.map(\.segmentID)) == [id102])
        // 无当前段：全部可见
        #expect(SegmentGridPicker.occupancy(claimed: claimed, currentSlotSceneID: nil).count == 2)
    }

    @Test func GP11_occupancyCarriesOrderAndTag() {
        let claimed: [UUID: GridPickerClaim] = [
            id201: .init(sceneID: scene2, sceneOrder: 3, sceneTag: "效果展示"),
        ]
        let occ = SegmentGridPicker.occupancy(claimed: claimed, currentSlotSceneID: scene1)
        #expect(occ.first?.sceneOrder == 3)
        #expect(occ.first?.sceneTag == "效果展示")
    }

    // MARK: GP-12 空输入

    @Test func GP12_emptySegmentsAllOpsReturnEmpty() {
        #expect(SegmentGridPicker.filter([], .init()).isEmpty)
        #expect(SegmentGridPicker.videoGroups([]).isEmpty)
        #expect(SegmentGridPicker.occupancy(claimed: [:], currentSlotSceneID: nil).isEmpty)
    }

    // MARK: GP-13 不重复

    @Test func GP13_segmentAppearsOnceEvenWithMultipleMatchingTags() {
        // 101 同时有两个标签，且同时命中搜索，结果仍只一次
        let r = SegmentGridPicker.filter(segs, .init(
            searchText: "腻", requiredTags: ["噱头引入", "痛点"]))
        let list = r.filter { $0.id == id101 }
        #expect(list.count == 1)
    }
}

// MARK: - SchemeFocus（SF-1 ~ SF-5）

struct SchemeFocusTests {
    private func sid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-1111-0000-0000-%012X", n, n))!
    }
    private func gid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-2222-0000-0000-%012X", n, n))!
    }

    @Test func SF1_locateReturnsTreeAndIndex() {
        let trees = [
            SchemeFocus.Tree(strategyID: gid(1), orderedSchemeIDs: [sid(1), sid(2)]),
            SchemeFocus.Tree(strategyID: gid(2), orderedSchemeIDs: [sid(3)]),
        ]
        #expect(SchemeFocus.locate(sid(3), in: trees)
                == SchemeFocus.Location(strategyID: gid(2), schemeIndex: 0))
        #expect(SchemeFocus.locate(sid(2), in: trees)
                == SchemeFocus.Location(strategyID: gid(1), schemeIndex: 1))
    }

    @Test func SF2_unknownSchemeAcrossProjectsReturnsNil() {
        let trees = [SchemeFocus.Tree(strategyID: gid(1), orderedSchemeIDs: [sid(1)])]
        #expect(SchemeFocus.locate(sid(99), in: trees) == nil)
    }

    @Test func SF3_deletedSchemeReturnsNil() {
        let trees = [SchemeFocus.Tree(strategyID: gid(1), orderedSchemeIDs: [sid(1)])]
        #expect(SchemeFocus.locate(sid(2), in: trees) == nil)
    }

    @Test func SF4_emptyTreesReturnNil() {
        #expect(SchemeFocus.locate(sid(1), in: []) == nil)
    }

    @Test func SF5_matchesByExactIDNotPositionWhenTreesShareShape() {
        // 两棵树都有「第 1 行」，只能按 id 精确归属
        let trees = [
            SchemeFocus.Tree(strategyID: gid(1), orderedSchemeIDs: [sid(1)]),
            SchemeFocus.Tree(strategyID: gid(2), orderedSchemeIDs: [sid(2)]),
        ]
        #expect(SchemeFocus.locate(sid(2), in: trees)?.strategyID == gid(2))
    }
}
