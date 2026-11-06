import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// CHURN · 一次改标签会让多少行**结构上必然重出**（R6 的重绘那一半）
//
// ## 为什么这一组值得存在
//
// `SegmentTapCostMeasurementTests` 量到的是模型侧：0.974 ms(35段) / 4.325 ms(480段)。
// 那一半回答"applyFilter 有多贵"，回答不了"SwiftUI 因此重画多少东西"。
//
// 本仓的行投影是刻意设计过的（`LibraryRowLayout` 把分组拍平成单层序列，行身份是
// `r-<组UUID>-<行序>` 这种**与内容无关**的稳定字符串）。于是"重绘多少"这件事
// 有一个可以在**不开 Instruments** 的前提下算出来的结构上界：
//
//   行身份不变 **且** 载荷逐字不变 ⇒ 那一行的 `SegmentCard` 值全等 ⇒ `.equatable()` 跳过 body。
//   载荷换人 ⇒ 那一行必然重出。
//
// 所以这一组给的是**重绘次数的结构上界**，不是耗时。它证明不了"无卡顿"，
// 但能证明"无筛选时改标签，网格零结构变化"这一件具体的事 —— 而那正是
// 判断"要不要把 recomputeAllDerived 拆开"最关键的先验。
//
// ## 台架
//   行投影复用视图里那三行映射（`groupedSegments.map { LibraryGroupRef(...) }`），
//   筛选/排序全部由真 VM 完成 ⇒ 不是"抄一份算法自己跟自己对账"。
// ============================================================================

private let churnFps = 25.0

/// 复刻 `SegmentLibraryView.libraryRows` 的那三行投影（身份与载荷都取下来以便对账）。
@MainActor
private func churnRows(vm: SegmentLibraryViewModel, columnCount: Int, isGrid: Bool) -> [LibraryRow] {
    let refs = vm.groupedSegments.map {
        LibraryGroupRef(id: $0.id, segmentIDs: $0.visibleSegments.map(\.id))
    }
    return LibraryRowLayout.rows(for: refs, columnCount: columnCount, isGrid: isGrid)
}

/// 两次行序列之间，**载荷发生变化**的行数 —— 即"结构上必然重出"的行数。
private func churnedRowCount(before: [LibraryRow], after: [LibraryRow]) -> Int {
    var changed = 0
    for row in after {
        guard let match = before.first(where: { $0.id == row.id }) else {
            changed += 1        // 新增身份 ⇒ 必然重出
            continue
        }
        if match != row { changed += 1 }
    }
    // 消失的身份同样要算（那一行不再存在，也是结构变化）
    changed += before.filter { old in !after.contains(where: { $0.id == old.id }) }.count
    return changed
}

@MainActor
private func churnWorld(segmentCount: Int) throws
    -> (Project, [Segment], ModelContext, ModelContainer, SegmentLibraryViewModel) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let project = Project(name: "CHURN-项目")
    ctx.insert(project)
    let video = Video(name: "CHURN-源", localPath: "/tmp/churn-fake.mov")
    video.duration = Double(segmentCount) * 2
    video.fps = churnFps
    video.width = 1080
    video.height = 1920
    ctx.insert(video)
    _ = ProjectVideo.associate(project: project, video: video, in: ctx)

    var segs: [Segment] = []
    segs.reserveCapacity(segmentCount)
    for i in 0..<segmentCount {
        // 奇数段带 .hook，偶数段不带 ⇒ 可以构造"筛选命中态下摘掉标签"那一档
        let types: [SemanticType] = i % 2 == 1 ? [.hook, .painPoint] : [.painPoint]
        let seg = Segment(segmentIndex: String(format: "seg_%04d", i + 1),
                          startTime: Double(i) * 2, endTime: Double(i) * 2 + 2,
                          text: "台词 \(i)", semanticTypes: types, positionType: .middle)
        seg.startFrame = FrameTime.frame(seconds: Double(i) * 2, fps: churnFps)
        seg.endFrame = FrameTime.frame(seconds: Double(i) * 2 + 2, fps: churnFps)
        seg.video = video
        ctx.insert(seg)
        segs.append(seg)
    }
    try ctx.save()

    let vm = SegmentLibraryViewModel()
    vm.setModelContext(ctx)
    vm.segments = segs
    vm.applyFilter()
    return (project, segs, ctx, container, vm)
}

@Suite("CHURN · 改标签引起的行结构变化")
struct SegmentLibraryRowChurnTests {

    @Test("CHURN-1 无筛选 + 默认排序：改一颗标签，行序列**零结构变化**（网格不重排）")
    @MainActor
    func tagTapUnderNoFilterCausesZeroRowChurn() throws {
        let w = try churnWorld(segmentCount: 40)
        defer { withExtendedLifetime(w) {} }
        let vm = w.4

        let before = churnRows(vm: vm, columnCount: 3, isGrid: true)
        #expect(!before.isEmpty, "行序列是空的 ⇒ 计数器在遍历空集，这条判据没在测东西")

        vm.toggleSemanticType(for: w.1[3], type: .results)

        let after = churnRows(vm: vm, columnCount: 3, isGrid: true)
        let churned = churnedRowCount(before: before, after: after)
        #expect(churned == 0, "无筛选下改标签导致 \(churned) 行结构变化 ⇒ 网格会整片重出，那 recomputeAllDerived 拆不拆就不是问题了，先查为什么排序被扰动")
        // 身份序列也必须逐字相同（不只是载荷相同）
        #expect(before.map(\.id) == after.map(\.id), "行身份序列变了 ⇒ ForEach 会做身份差分")
    }

    @Test("CHURN-2 筛选命中态摘掉那颗：从被踢那一行起，后续行载荷平移（这才是真重出）")
    @MainActor
    func tagTapUnderActiveFilterShiftsTheTail() throws {
        let w = try churnWorld(segmentCount: 40)
        defer { withExtendedLifetime(w) {} }
        let vm = w.4

        vm.filter = SegmentFilter(semanticTypes: [.hook])
        vm.applyFilter()
        let visible = vm.filteredSegments
        #expect(visible.count == 20, "夹具前提：奇数段带 .hook，应命中 20 条，实得 \(visible.count)")

        let before = churnRows(vm: vm, columnCount: 2, isGrid: true)
        let victim = visible[5]                    // 组内第 6 条 ⇒ 第 3 行
        vm.toggleSemanticType(for: victim, type: .hook)   // 摘掉后只剩 .painPoint ⇒ 被筛掉
        let after = churnRows(vm: vm, columnCount: 2, isGrid: true)

        let churned = churnedRowCount(before: before, after: after)
        // 手算一遍（2 列，20 条可见 → 摘掉第 6 条变 19 条；行序列第 0 项是 header，卡行从 1 起）：
        //   前 10 个卡行：[v0,v1] [v2,v3] [v4,v5] [v6,v7] [v8,v9] [v10,v11] [v12,v13] [v14,v15] [v16,v17] [v18,v19]
        //   后 10 个卡行：[v0,v1] [v2,v3] [v4,v6] [v7,v8] [v9,v10] [v11,v12] [v13,v14] [v15,v16] [v17,v18] [v19]
        // ⇒ 卡行 0、1 载荷不变；victim 落在卡行 2，从它起尾巴整体平移 ⇒ 卡行 2..9 共 **8 行**必然重出。
        // 钉精确数字而不是 `> 0`：数字变了说明投影或排序口径变了，而 `> 0` 会一路放过。
        // （本条第一版写的是 3 —— 那是按"10 条可见"算的，夹具实际 20 条。错在我的算术，不在投影。）
        #expect(churned == 8,
                "预期 8 行平移，实得 \(churned) ⇒ 行投影的平移范围变了（前 \(before.count) 行 / 后 \(after.count) 行）")
        // 行数不变：20 条 10 个卡行、19 条在 2 列下仍是 10 个卡行（末行只剩一条）—— 别把"少一条"误当成"少一行"。
        #expect(after.count == before.count,
                "行数从 \(before.count) 变成 \(after.count) ⇒ 末行不足列数时补位规则被改动了")
        // 平移起点之前必须逐字不变：header + 卡行 0、1 = 前 3 项。
        let head = Array(before.prefix(3))
        let headAfter = Array(after.prefix(3))
        #expect(head == headAfter,
                "前 3 项（header + 头两个卡行）载荷也变了 ⇒ 平移起点不在被踢那一行，重出范围比预期大")
    }

    @Test("CHURN-3 反向对照：载荷计数器必须数得出人为改动（否则 CHURN-1 的 0 是恒真）")
    func churnCounterHasTeeth() {
        let g = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        let before = LibraryRowLayout.rows(for: [LibraryGroupRef(id: g, segmentIDs: [a, b, c])],
                                          columnCount: 1, isGrid: false)
        // 同一组、同样 3 条，但把中间那条换成 d ⇒ 身份不变、载荷换人
        let after = LibraryRowLayout.rows(for: [LibraryGroupRef(id: g, segmentIDs: [a, UUID(), c])],
                                         columnCount: 1, isGrid: false)
        #expect(before.map(\.id) == after.map(\.id), "对照组前提：身份序列应相同")
        #expect(churnedRowCount(before: before, after: after) == 1,
                "载荷换人却数不出重出 ⇒ CHURN-1 那个 0 没有意义")
        // 再验一腿"完全没动"必须数出 0，否则这个计数器是在乱报。
        #expect(churnedRowCount(before: before, after: before) == 0,
                "同一序列自己比竟然不是 0 ⇒ 计数器把恒等也算成变化")
    }

    @Test("CHURN-4 列表模式（每分镜一行）：无筛选下同样零结构变化")
    @MainActor
    func listModeHasZeroChurnToo() throws {
        let w = try churnWorld(segmentCount: 40)
        defer { withExtendedLifetime(w) {} }
        let vm = w.4

        let before = churnRows(vm: vm, columnCount: 1, isGrid: false)
        #expect(before.count >= 40, "列表模式应每段一行，实得 \(before.count)")

        vm.toggleSemanticType(for: w.1[0], type: .results)
        let after = churnRows(vm: vm, columnCount: 1, isGrid: false)
        #expect(churnedRowCount(before: before, after: after) == 0,
                "列表模式无筛选下改标签引起行重出 ⇒ 与 CHURN-1 同一族，先查排序")
    }
}
