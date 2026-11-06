import Foundation
import SwiftData

/// 分镜筛选条件
struct SegmentFilter {
    var semanticTypes: Set<SemanticType> = []
    var positionTypes: Set<PositionType> = []
    var sourceVideoID: UUID?
    var minQualityScore: Double = 0
    var searchText: String = ""
    /// 素材来源筛选；nil = 全部
    var source: SegmentSource? = nil
}

/// 按视频分组的分镜；`video == nil` 表示「自建分镜」聚合组（多个自建载体视频合并为一组）
struct VideoSegmentGroup: Identifiable {
    let video: Video?
    /// **筛选后**可见的分镜。刻意不叫 `segments` —— 那是 `Video` 上的 SwiftData 关系名，
    /// 同名会让「读这份投影」与「fault 模型关系」在源码里长得一模一样，守卫分不开、人也会看错。
    let visibleSegments: [Segment]
    var isSelfBuilt: Bool { video == nil }
    /// 「自建分镜」聚合组的固定 id / 编号 key
    static let selfBuiltID = UUID(uuidString: "5E1FBEE7-0000-0000-0000-000000000001")!
    var id: UUID { video?.id ?? Self.selfBuiltID }
}

/// 分镜素材库 ViewModel
@MainActor
@Observable
final class SegmentLibraryViewModel {
    var segments: [Segment] = []
    var filteredSegments: [Segment] = []

    /// 选中状态机（pinned 持久 + hovered 临时）；纯逻辑在 MixCutCore，VM 只持值
    private var selectionState = SegmentSelectionState()
    /// 当前生效选中（pinned 优先），下游原有接口不变
    var selectedSegment: Segment? {
        guard let id = selectionState.resolvedID else { return nil }
        return segmentByID[id]
    }
    /// Inspector 关闭按钮判定所需：当前是否持久选中
    var pinnedSegmentID: UUID? { selectionState.pinnedID }
    /// hover 自动选中是否被当前宽度允许（由视图按 libraryWidth 计算后下发）
    private(set) var hoverSelectionAllowed: Bool = true

    // MARK: 选中变更（转发给状态机）

    /// 点击持久选中
    func pin(_ segment: Segment) {
        selectionState.pin(segment.id)
    }

    /// hover 临时选中（仅非多选、且当前宽度允许时调用方触发）
    func setHoveredSegmentID(_ id: UUID?) {
        selectionState.setHovered(id)
    }

    /// 收起 Inspector
    func clearPinned() {
        selectionState.clearPinned()
    }

    /// 视图随宽度变化更新 hover 门禁结果
    func setHoverSelectionAllowed(_ allowed: Bool) {
        guard hoverSelectionAllowed != allowed else { return }
        hoverSelectionAllowed = allowed
        // 新宽度不再允许且当前仅靠 hover 选中 → 释放临时选中（持久 pinned 不受影响）
        if !allowed, selectionState.pinnedID == nil {
            selectionState.setHovered(nil)
        }
    }
    /// 右键"分镜头替换"请求的分镜（驱动 ShotEditSheet 弹出）
    var shotEditRequestSegment: Segment?
    /// 右键"拆分"请求的分镜（驱动 SplitSegmentSheet 弹出）
    var splitRequestSegment: Segment?
    var filter = SegmentFilter()
    var sortByQuality = false
    var isGridView = true

    /// 骨架屏判据：手上有没有「这个项目」的分镜数据。
    /// 住在 VM 而不是视图，是因为视图实例每次切模块都被销毁重建，自持 `@State isLoading` 会让换模块也上一帧骨架。
    private(set) var readiness = ProjectDataReadiness()

    /// 微调后触发预览播放的回调信号
    var previewRequest: SegmentPreviewRequest?

    /// 播放激活门禁：「当前激活分镜」状态与「是否放行新播放」判定的唯一真源。
    private var activationGate = PlaybackActivationGate()

    /// 当前正在播放的分镜 ID（全局唯一，确保只有一个播放）。
    /// 只读暴露 gate 状态，写入统一经 requestPlay / stopCurrentPlayback。
    var playingSegmentID: UUID? { activationGate.activeSegmentID }

    /// 请求播放某个分镜（自动停止其他播放）。
    /// - Parameter intent：ensureActive（默认，幂等——hover/点击）或 restart（强制重播——边界微调）。
    func requestPlay(segment: Segment, from startTime: Double? = nil, to endTime: Double? = nil,
                     intent: PlaybackActivationIntent = .ensureActive) {
        // Gate 单点去重：同一分镜重复的 ensureActive 在此被吞，不产生第二个播放信号。
        guard activationGate.request(segmentID: segment.id, intent: intent) else { return }
        let from = startTime ?? segment.startTime
        let to = endTime ?? segment.endTime
        previewRequest = SegmentPreviewRequest(
            segmentID: segment.id,
            from: from,
            to: to
        )
    }

    /// 停止当前播放
    func stopCurrentPlayback() {
        activationGate.clear()
    }

    private var modelContext: ModelContext?
    private let ffmpeg = FFmpegRunner()
    private var thumbRegenTask: Task<Void, Never>?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 加载项目的所有分镜
    func loadSegments(for project: Project) {
        // 重载前先把待删除项真正删除，避免「界面已隐藏但数据库未删」在重载后又冒出来
        PendingDeletionCenter.shared.flushNow()
        // 切项目铁律：清空多选 / 预览 / 选中状态（避免 A 项目状态残留到 B）
        selectionState.clearAll()
        isSelectionMode = false
        selectedSegmentIDs.removeAll()
        selectionOrderedIDs.removeAll()
        previewRequest = nil
        activationGate.clear()

        var allSegments: [Segment] = []
        for video in project.videos {
            allSegments.append(contentsOf: video.displayableSegments)   // 决议 K9 那颗唯一出口
        }
        segments = allSegments
        applyFilter()   // applyFilter 内部会调用 recomputeAllDerived
        readiness.markLoaded(for: project.id)
        MixLog.info("[Readiness] 分镜数据已就绪 project=\(project.id) segs=\(segments.count)")
    }

    /// 从投影里剪掉已真删的分镜 —— 广播带 id 时走这里，**不重新 fetch**。
    ///
    /// 为什么单独开一颗而不是复用 `loadSegments(for:)`：那颗的首行是 `PendingDeletionCenter.shared.flushNow()`，
    /// 而本方法是在 `GraphBroadcast.post` 的**同步栈**里被调用的 —— 再走一次 flushNow 就会执行下一个待删事务
    /// 并再次广播，等于自己把自己递归掉（前案 §10 健壮-1，P0）。
    /// 派生数组一律交给既有的 `applyFilter()`（内部 `recomputeAllDerived`）重算，不在这里另写一套分组。
    func pruneDeletedSegments(_ ids: Set<UUID>) {
        guard !ids.isEmpty, segments.contains(where: { ids.contains($0.id) }) else { return }
        segments.removeAll { ids.contains($0.id) }
        selectedSegmentIDs.subtract(ids)
        selectionOrderedIDs.removeAll { ids.contains($0) }
        applyFilter()
    }

    // MARK: - 批量导出多选

    /// 是否处于多选模式
    var isSelectionMode: Bool = false

    /// 已选分镜 ID 集合
    var selectedSegmentIDs: Set<UUID> = []

    /// 每视频内的分镜编号映射（按 startTime 升序，每视频独立 1-based）
    /// 缓存到 stored property，避免 SwiftUI 重绘时反复重算
    private(set) var numberByVideo: [UUID: [UUID: Int]] = [:]

    /// 每个分组**未筛选**的全部分镜（配音批量作用域的定义域）。
    ///
    /// ⚠️ 与 `numberByVideo` 必须由**同一次分组**产出（见 `recomputeNumberByVideo`）：
    /// 分组 key 的口径（自建分镜合并进 `selfBuiltID`）只要两处各算一遍就会分叉，
    /// 而分叉的表征是「按钮说作用于这个视频，实际改写的是另一批分镜」。
    /// 刻意不等于筛选结果 —— 用 `visibleSegments` 当定义域会让筛选悄悄缩窄批量范围，
    /// 而上屏文案仍然写着「本视频 N 个分镜」（会说假话那一类）。
    private(set) var unfilteredSegmentsByGroupID: [UUID: [Segment]] = [:]

    /// 按界面分组 key 把未筛选的全部分镜归类（编号与定义域共用这一次遍历）。
    private func groupByDisplayKey(_ segs: [Segment]) -> [UUID: [Segment]] {
        var byKey: [UUID: [Segment]] = [:]
        for seg in segs {
            guard let video = seg.video else { continue }
            // 自建分镜统一归到「自建分镜」组的 key；其余按各自视频
            let key = video.isUserUploaded ? VideoSegmentGroup.selfBuiltID : video.id
            byKey[key, default: []].append(seg)
        }
        return byKey
    }

    /// 取得分镜在所属视频内的编号；找不到返回 0
    func number(for segment: Segment) -> Int {
        guard let video = segment.video else { return 0 }
        let key = video.isUserUploaded ? VideoSegmentGroup.selfBuiltID : video.id
        return numberByVideo[key]?[segment.id] ?? 0
    }

    /// 重新计算 numberByVideo 与未筛选定义域（仅在 segments 变化时调用）
    private func recomputeNumberByVideo() {
        let byKey = groupByDisplayKey(segments)
        unfilteredSegmentsByGroupID = byKey
        var result: [UUID: [UUID: Int]] = [:]
        for (key, segs) in byKey {
            // 自建分镜组按创建时间编号（整片 startTime 都是 0），其余按 startTime
            let sorted = key == VideoSegmentGroup.selfBuiltID
                ? segs.sorted { $0.createdAt < $1.createdAt }
                : segs.sorted { $0.startTime < $1.startTime }
            var map: [UUID: Int] = [:]
            for (i, seg) in sorted.enumerated() {
                map[seg.id] = i + 1
            }
            result[key] = map
        }
        numberByVideo = result
    }

    /// 用户勾选先后顺序（与 selectedSegmentIDs 同步维护）
    /// 注意：Set 本身无序，所以单独用一个 [UUID] 记录"第一次勾选 → 最后一次勾选"的顺序
    /// 给「组合为方案」用：用户期望按勾选顺序拼接，不是按视频+时间排序
    var selectionOrderedIDs: [UUID] = []

    /// 最后一次单独勾选的分镜 —— ⇧+点击做范围多选时的锚点。
    private var lastToggledID: UUID?

    func toggleSelection(_ segment: Segment) {
        if selectedSegmentIDs.contains(segment.id) {
            selectedSegmentIDs.remove(segment.id)
            selectionOrderedIDs.removeAll { $0 == segment.id }
        } else {
            selectedSegmentIDs.insert(segment.id)
            selectionOrderedIDs.append(segment.id)
        }
        lastToggledID = segment.id
    }

    /// 界面上分镜的**视觉先后顺序**（按视频分组后拼接）。
    /// ⚠️ 不能直接用 `filteredSegments` —— 它是筛选/排序后的**扁平**顺序，
    /// 而界面是按视频分组渲染的，两者不一致会导致 ⇧+点击选到用户看不见的分镜。
    private var visualOrder: [Segment] {
        groupedSegments.flatMap(\.visibleSegments)
    }

    /// ⇧+点击：从上次勾选的分镜到当前分镜之间**整段选中**（Finder / 邮件同款手感）。
    /// 范围按界面上看到的顺序取，所见即所得。没有锚点时退化为普通单选。
    func extendSelection(to segment: Segment) {
        let order = visualOrder
        guard let anchorID = lastToggledID,
              let anchorIdx = order.firstIndex(where: { $0.id == anchorID }),
              let targetIdx = order.firstIndex(where: { $0.id == segment.id })
        else {
            toggleSelection(segment)
            return
        }
        let range = anchorIdx <= targetIdx ? anchorIdx...targetIdx : targetIdx...anchorIdx
        for seg in order[range] where !selectedSegmentIDs.contains(seg.id) {
            selectedSegmentIDs.insert(seg.id)
            selectionOrderedIDs.append(seg.id)
        }
        // 锚点保持不动，便于反复 ⇧+点击调整范围
    }

    /// 全选当前筛选后可见的所有分镜（顺序 = 当前 filteredSegments 渲染顺序）
    func selectAllVisible() {
        let ids = filteredSegments.map(\.id)
        selectedSegmentIDs = Set(ids)
        selectionOrderedIDs = ids
    }

    /// 反选（针对当前筛选后可见的所有分镜）
    /// 反选后的顺序按 filteredSegments 渲染顺序重建（无法保留"勾选先后"语义）
    func invertSelectionVisible() {
        let visible = Set(filteredSegments.map(\.id))
        let newSelection = visible.subtracting(selectedSegmentIDs)
        selectedSegmentIDs = newSelection
        selectionOrderedIDs = filteredSegments.map(\.id).filter { newSelection.contains($0) }
    }

    func clearSelection() {
        selectedSegmentIDs.removeAll()
        selectionOrderedIDs.removeAll()
    }

    /// 一键清除全部筛选条件（供「没有符合条件的分镜」空状态的出口按钮用）。
    /// 只重置筛选，不动多选状态与已加载数据。
    func clearFilters() {
        filter = SegmentFilter()   // 搜索词也在 filter 里，一并重置
        applyFilter()
    }

    /// 进入/退出多选模式（退出时自动清空已选）
    func setSelectionMode(_ enabled: Bool) {
        isSelectionMode = enabled
        if !enabled {
            selectedSegmentIDs.removeAll()
            selectionOrderedIDs.removeAll()
        }
    }

    /// 当前已选的分镜列表（按视频 + startTime 排序）
    /// **用途：批量导出**（同一视频按时间走拼接顺序合理）
    /// 不要用于"组合为方案"，那个要用 orderedSelectedSegments
    var selectedSegments: [Segment] {
        let selected = segments.filter { selectedSegmentIDs.contains($0.id) }
        return selected.sorted { a, b in
            let aVid = a.video?.id.uuidString ?? ""
            let bVid = b.video?.id.uuidString ?? ""
            if aVid != bVid { return aVid < bVid }
            return a.startTime < b.startTime
        }
    }

    /// 已选分镜总时长（秒）。仅求和，避开 selectedSegments 的建数组+排序+uuidString 分配
    /// （多选工具栏常驻，任意重绘都会读它）。
    var selectedDuration: Double {
        segments.reduce(0.0) { selectedSegmentIDs.contains($1.id) ? $0 + $1.duration : $0 }
    }

    /// 当前已选的分镜列表（按"勾选先后顺序"）
    /// **用途：组合为方案**（用户期望按勾选顺序拼接）
    var orderedSelectedSegments: [Segment] {
        // 键唯一性由上游保证：`segments` 来自 `Project.associatedVideos`（挂载层唯一出口）。
        // 这里用冲突策略而不是 uniqueKeysWithValues —— 真修点在 Project，不在本文件；
        // 万一将来又有别的路径把同一分镜塞两次，宁可少算一条也不能打死进程。
        let lookup = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selectionOrderedIDs.compactMap { lookup[$0] }
    }

    /// 每个语义类型对应的镜头数量（基于全部 segments，不随筛选变化）
    /// 缓存到 stored property
    private(set) var countByType: [SemanticType: Int] = [:]
    /// 每种素材来源的分镜数（基于全部 segments，含未分类）
    private(set) var countBySource: [SegmentSource: Int] = [:]

    /// 按视频分组的筛选结果
    /// 缓存到 stored property（每次 filteredSegments 变化时重算）
    private(set) var groupedSegments: [VideoSegmentGroup] = []

    /// 扁平渲染行按 id 回查模型用的字典，与 `segments`/`groupedSegments` 在同一次
    /// recomputeAllDerived 中更新——保证视图里「行投影」与「模型查找」看到同一批数据。
    /// 视图层禁止强解：重认台词/删除撤销等异步回写可能让两相位短暂不一致。
    private(set) var segmentByID: [UUID: Segment] = [:]
    private(set) var groupByID: [UUID: VideoSegmentGroup] = [:]

    /// 数据变化时统一重算所有派生属性
    private func recomputeAllDerived() {
        // 1) countByType（基于全部 segments）
        var counts: [SemanticType: Int] = [:]
        for type in SemanticType.allCases { counts[type] = 0 }
        for seg in segments {
            for t in seg.semanticTypes {
                counts[t, default: 0] += 1
            }
        }
        countByType = counts

        // 1b) countBySource（基于全部 segments，四类恒有键）
        var sourceCounts: [SegmentSource: Int] = [:]
        for source in SegmentSource.allCases { sourceCounts[source] = 0 }
        for seg in segments { sourceCounts[seg.source, default: 0] += 1 }
        countBySource = sourceCounts

        // 2) numberByVideo（基于全部 segments）
        recomputeNumberByVideo()

        // 3) groupedSegments（基于 filteredSegments）
        recomputeGroupedSegments()

        // 4) 扁平渲染的回查字典（与上面同源同批更新）
        segmentByID = Dictionary(segments.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        groupByID = Dictionary(groupedSegments.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
    }

    private func recomputeGroupedSegments() {
        var selfBuilt: [Segment] = []
        var videoMap: [UUID: (video: Video, visible: [Segment])] = [:]
        var videoOrder: [UUID] = []
        for seg in filteredSegments {
            guard let video = seg.video else { continue }
            if video.isUserUploaded { selfBuilt.append(seg); continue }
            if videoMap[video.id] == nil {
                videoMap[video.id] = (video: video, visible: [])
                videoOrder.append(video.id)
            }
            videoMap[video.id]?.visible.append(seg)
        }
        var groups: [VideoSegmentGroup] = []
        // 「自建分镜」聚合组置顶（组内按创建时间）
        if !selfBuilt.isEmpty {
            groups.append(VideoSegmentGroup(video: nil,
                                            visibleSegments: selfBuilt.sorted { $0.createdAt < $1.createdAt }))
        }
        groups += videoOrder.compactMap { id in
            guard let entry = videoMap[id] else { return nil }
            return VideoSegmentGroup(video: entry.video, visibleSegments: entry.visible)
        }
        groupedSegments = groups
    }

    /// 应用筛选条件
    func applyFilter() {
        var result = segments

        if !filter.semanticTypes.isEmpty {
            result = result.filter { seg in
                seg.semanticTypes.contains(where: { filter.semanticTypes.contains($0) })
            }
        }

        if !filter.positionTypes.isEmpty {
            result = result.filter { filter.positionTypes.contains($0.positionType) }
        }

        if let videoID = filter.sourceVideoID {
            result = result.filter { $0.video?.id == videoID }
        }

        if let source = filter.source {
            result = result.filter { $0.source == source }
        }

        if filter.minQualityScore > 0 {
            result = result.filter { $0.qualityScore >= filter.minQualityScore }
        }

        if !filter.searchText.isEmpty {
            let query = filter.searchText.lowercased()
            result = result.filter {
                $0.text.lowercased().contains(query) ||
                $0.keywords.contains(where: { $0.lowercased().contains(query) })
            }
        }

        if sortByQuality {
            result.sort { $0.qualityScore > $1.qualityScore }
        } else {
            result.sort { $0.startTime < $1.startTime }
        }

        filteredSegments = result
        recomputeAllDerived()
    }

    // MARK: 分类标签的唯一写入口（UI 侧）
    //
    // 判据本身在 `SemanticType.toggled`（界面、批量、MCP 三方共用同一份）。这里只负责三件事：
    // 撤销动作名、落库、派生刷新，以及把两种"静默"变成出声 ——
    //   ① 「至少保留一个」被拒时什么都不做（旧写法），用户体感是"点了没反应"；
    //   ② 落库失败被吞（视图侧的 `try? save()` 与 VM 侧的可选链都会吞）。
    // 视图拿不到 `modelContext`（它是 private），所以"只能走这里"有编译期护栏。

    /// 写入前：取上下文并登记撤销动作名。上下文缺失必须出声，不许静默丢掉这次点击。
    private func beginEdit(actionName: String) -> ModelContext? {
        guard let context = modelContext else {
            ToastCenter.shared.show("改动没存下来：数据库上下文未就绪",
                                    icon: "exclamationmark.triangle.fill", style: .warning)
            return nil
        }
        context.undoManager?.setActionName(actionName)
        return context
    }

    /// 写入后：落库（失败出声）+ 刷新筛选与派生计数。
    /// `applyFilter()` 内部会 `recomputeAllDerived()` ⇒ 顶部 chip 的计数与筛选结果同帧跟上。
    private func endEdit(_ context: ModelContext) {
        if !context.safeSave() {
            ToastCenter.shared.show("改动没能保存，重启后会丢",
                                    icon: "exclamationmark.triangle.fill", style: .warning)
        }
        applyFilter()
    }

    /// 切换分镜的语义类型（多选：添加或移除）。
    @discardableResult
    func toggleSemanticType(for segment: Segment, type: SemanticType) -> SemanticToggleOutcome {
        let (outcome, next) = SemanticType.toggled(segment.semanticTypes, adding: type)
        if outcome == .refusedKeepAtLeastOne {
            ToastCenter.shared.show(SemanticType.keepAtLeastOneMessage,
                                    icon: "exclamationmark.triangle.fill", style: .warning)
            return outcome
        }
        guard let context = beginEdit(actionName: "修改类型") else { return outcome }
        segment.semanticTypes = next
        endEdit(context)
        return outcome
    }

    /// 更新分镜的位置类型（单值，点即切换；`PositionType` 非 Optional ⇒ 没有"清空"这条路径）。
    @discardableResult
    func updatePositionType(for segment: Segment, to newType: PositionType) -> Bool {
        guard let context = beginEdit(actionName: "修改位置") else { return false }
        segment.positionType = newType
        endEdit(context)
        return true
    }

    /// 批量给选中的分镜**加上**某个语义类型（快照 + 5 秒撤销）。
    ///
    /// 只做"加"不做"删"：删会逐条撞「至少保留一个」，产出需要逐条结算与逐条播报的
    /// "部分成功"语义，收益不抵复杂度。形状逐字照 `applySourceToSelected`。
    func addSemanticTypeToSelected(_ type: SemanticType) {
        guard let context = modelContext else { return }
        let targets = selectedSegments
        guard !targets.isEmpty else { return }
        context.undoManager?.setActionName("修改类型")
        let snapshot: [(segment: Segment, types: [SemanticType])] =
            targets.map { ($0, $0.semanticTypes) }
        var changed = 0
        for seg in targets where !seg.semanticTypes.contains(type) {
            seg.semanticTypes = seg.semanticTypes + [type]
            changed += 1
        }
        guard changed > 0 else {
            ToastCenter.shared.show("选中的 \(targets.count) 个分镜都已经有「\(type.rawValue)」了",
                                    icon: "info.circle.fill", style: .info)
            return
        }
        context.safeSave()
        applyFilter()
        MixLog.info("[批量打标] 定义域 \(targets.count) 段，实际加上「\(type.rawValue)」\(changed) 段")

        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已给 \(changed) 个分镜加上「\(type.rawValue)」",
            actionTitle: "撤销批量打标",
            seconds: 5
        ) {
            for item in snapshot where !item.segment.isDroppedFromContext {
                item.segment.semanticTypes = item.types
            }
            context.safeSave()
            self.applyFilter()
        }
    }

    /// 批量设置选中分镜的位置（快照 + 5 秒撤销）。
    func setPositionTypeForSelected(_ position: PositionType) {
        guard let context = modelContext else { return }
        let targets = selectedSegments
        guard !targets.isEmpty else { return }
        context.undoManager?.setActionName("修改位置")
        let snapshot: [(segment: Segment, position: PositionType)] =
            targets.map { ($0, $0.positionType) }
        var changed = 0
        for seg in targets where seg.positionType != position {
            seg.positionType = position
            changed += 1
        }
        guard changed > 0 else {
            ToastCenter.shared.show("选中的 \(targets.count) 个分镜都已经是「\(position.rawValue)」了",
                                    icon: "info.circle.fill", style: .info)
            return
        }
        context.safeSave()
        applyFilter()
        MixLog.info("[批量改位置] 定义域 \(targets.count) 段，实际改为「\(position.rawValue)」\(changed) 段")

        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已把 \(changed) 个分镜的位置改为「\(position.rawValue)」",
            actionTitle: "撤销批量改位置",
            seconds: 5
        ) {
            for item in snapshot where !item.segment.isDroppedFromContext {
                item.segment.positionType = item.position
            }
            context.safeSave()
            self.applyFilter()
        }
    }

    /// 重置筛选
    func resetFilter() {
        filter = SegmentFilter()
        applyFilter()
    }

    // MARK: - 边界微调

    /// 调整开始帧（±frames），调整后从新起点播放预览
    func adjustStartFrame(for segment: Segment, by frames: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let newStart = max(0, segment.startFrame + frames)
        guard newStart < segment.endFrame - 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: newStart, endFrame: segment.endFrame, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()
        scheduleStartThumbnailRegen(for: segment)   // 开始边界变了 → 首帧缩略图重生

        let toFrame = min(newStart + Int((2 * fps).rounded()), segment.endFrame)
        requestPlay(segment: segment, from: segment.startTime, to: FrameTime.seconds(frame: toFrame, fps: fps),
                    intent: .restart)
    }

    /// 调整结束帧（±frames），调整后播放到结束
    func adjustEndFrame(for segment: Segment, by frames: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let maxFrame = segment.video.map { FrameTime.frame(seconds: $0.duration, fps: fps) } ?? Int.max
        let newEnd = min(maxFrame, segment.endFrame + frames)
        guard newEnd > segment.startFrame + 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: segment.startFrame, endFrame: newEnd, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()

        let fromFrame = max(segment.startFrame, newEnd - Int(fps.rounded()))
        requestPlay(segment: segment, from: FrameTime.seconds(frame: fromFrame, fps: fps), to: segment.endTime,
                    intent: .restart)
    }

    /// 根据当前时间范围重新从 ASR 提取台词（中心点匹配，避免跨段重复）
    private func reExtractText(for segment: Segment) {
        guard let video = segment.video else { return }
        let words = video.asrWords
        let matched = words.filter { w in
            let center = (w.start + w.end) / 2
            return center >= segment.startTime && center < segment.endTime
        }
        let text = matched.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // 这段字是从**整片听写**的字级结果里按时间切出来的，不是逐段重听
            segment.setText(text, source: .fullVideoSlice)
        }
    }

    /// 直接设置开始帧（输入框提交帧号）
    func setStartFrame(for segment: Segment, to newStart: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let clamped = max(0, newStart)
        guard clamped < segment.endFrame - 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: clamped, endFrame: segment.endFrame, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()
        scheduleStartThumbnailRegen(for: segment)   // 开始边界变了 → 首帧缩略图重生
        let toFrame = min(clamped + Int((2 * fps).rounded()), segment.endFrame)
        requestPlay(segment: segment, from: segment.startTime, to: FrameTime.seconds(frame: toFrame, fps: fps),
                    intent: .restart)
    }

    /// 直接设置结束帧（输入框提交帧号）
    func setEndFrame(for segment: Segment, to newEnd: Int) {
        guard let fps = segment.video?.fps, fps > 0 else { return }
        let maxFrame = segment.video.map { FrameTime.frame(seconds: $0.duration, fps: fps) } ?? Int.max
        let clamped = min(maxFrame, max(0, newEnd))
        guard clamped > segment.startFrame + 1 else { return }
        modelContext?.undoManager?.setActionName("修改边界")
        segment.setFrameRange(startFrame: segment.startFrame, endFrame: clamped, fps: fps)
        reExtractText(for: segment)
        modelContext?.safeSave()
        let fromFrame = max(segment.startFrame, clamped - Int(fps.rounded()))
        requestPlay(segment: segment, from: FrameTime.seconds(frame: fromFrame, fps: fps), to: segment.endTime,
                    intent: .restart)
    }

    /// 调「开始」边界后重生成首帧缩略图（debounce，避免连点 ±帧时反复抽帧卡顿）。
    /// 缩略图路径带 startFrame 保证唯一 → thumbnailPath 变化触发卡片重绘 + 缓存拿到新图。
    private func scheduleStartThumbnailRegen(for segment: Segment) {
        thumbRegenTask?.cancel()
        thumbRegenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.regenStartThumbnail(for: segment)
        }
    }

    private func regenStartThumbnail(for segment: Segment) async {
        guard let video = segment.video else { return }
        let fps = video.fps > 0 ? video.fps : 30
        let t = Double(segment.startFrame) / fps
        let path = FileHelper.globalThumbnailDirectory
            .appendingPathComponent("seg-\(segment.id.uuidString)-\(segment.startFrame).jpg").path
        do {
            try await ffmpeg.generateThumbnail(from: video.localPath, at: t, to: path)
            segment.thumbnailPath = path
            modelContext?.safeSave()
        } catch {
            MixLog.error("[Thumb] 边界调整后缩略图重生失败: \(error.localizedDescription)")
        }
    }

    /// 删除分镜（延迟删除 + 常驻撤销条：先隐藏，`PendingDeletionCenter.graceSeconds`（现 5 秒）内可撤销，不撤才真删）
    func deleteSegment(_ segment: Segment) {
        guard modelContext != nil else { return }
        let id = segment.id
        if selectionState.resolvedID == id { selectionState.clearAll() }
        // 界面隐藏（不真删）
        segments.removeAll { $0.id == id }
        selectedSegmentIDs.remove(id)
        selectionOrderedIDs.removeAll { $0 == id }
        applyFilter()
        PendingDeletionCenter.shared.schedule(
            message: "已删除分镜",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return GraphChange() }
                // `id` 是删之前就已经拿着的 UUID 值（:584），把它交给台账 ⇒ 广播能剪掉别的 VM 那份副本
                var change = GraphChange()
                change.noteDeleted([id], of: .segment)
                // 手动先删级联子项再删 Segment（避免自动级联的边角问题，与 deleteVideo 同款）
                for ss in Array(segment.schemeSegments) { context.delete(ss) }
                context.delete(segment)
                context.safeSave()
                return change
            },
            undo: { [weak self] in
                guard let self else { return }
                // 撤销这条腿是**绕过装载口的第二次写入**（计划第十节：只挂 loadSegments 会漏）。
                // 内部段本来就不该上屏 ⇒ 撤销时「少塞一条」是正确行为，不是丢数据。
                if !segment.mixInternalWholeClip {
                    self.segments.append(segment)   // 放回（applyFilter 会按质量/时间重新排序，与顺序无关）
                }
                self.applyFilter()
            }
        )
    }

    /// 批量标记素材来源（5 秒撤销，快照恢复旧 raw）
    func applySourceToSelected(_ source: SegmentSource) {
        guard let context = modelContext else { return }
        let targets = selectedSegments
        guard !targets.isEmpty else { return }
        context.undoManager?.setActionName("标记来源")
        let snapshot: [(segment: Segment, oldRaw: String)] = targets.map { ($0, $0.sourceRaw) }
        for seg in targets { seg.setSource(source) }
        context.safeSave()
        applyFilter()
        PendingDeletionCenter.shared.scheduleUndoOnly(
            message: "已把 \(targets.count) 个分镜标记为「\(source.displayName)」",
            actionTitle: "还原来源",
            seconds: 5
        ) {
            for (seg, oldRaw) in snapshot { seg.sourceRaw = oldRaw }
            context.safeSave()
        }
    }

    /// 批量删除当前选中的分镜（延迟删除 + 撤销浮条）
    func deleteSelectedSegments() {
        guard modelContext != nil else { return }
        let idsToDelete = selectedSegmentIDs
        let segs = segments.filter { idsToDelete.contains($0.id) }
        guard !segs.isEmpty else { return }
        // 界面隐藏（不真删）
        if let sel = selectionState.resolvedID, idsToDelete.contains(sel) { selectionState.clearAll() }
        segments.removeAll { idsToDelete.contains($0.id) }
        selectedSegmentIDs.removeAll()
        selectionOrderedIDs.removeAll()
        applyFilter()
        PendingDeletionCenter.shared.schedule(
            message: "已删除 \(segs.count) 个分镜",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return GraphChange() }
                // id 全部来自 `segs`（schedule 之前就已快照的数组），不在 delete 之后再读对象
                var change = GraphChange()
                change.noteDeleted(Set(segs.map(\.id)), of: .segment)
                for seg in segs {
                    for ss in Array(seg.schemeSegments) { context.delete(ss) }
                    context.delete(seg)
                }
                context.safeSave()
                return change
            },
            undo: { [weak self] in
                guard let self else { return }
                self.segments.append(contentsOf: segs.filter { !$0.mixInternalWholeClip })
                self.applyFilter()
            }
        )
    }

    // MARK: - 逐段重认台词

    /// 正在重认台词的分镜（控制按钮 loading / 禁用）
    var busyASRSegmentIDs: Set<UUID> = []

    /// 这个分镜的源视频文件，当前判为不可用吗？
    ///
    /// ⚠️ 判定与映射**必须留在 VM**，视图只收 Bool props：视图里读 `segment.video` 是一次跨边裸读，
    /// 会让 G08/G15 两张名册各多一条在册（方案批 5 第 3 条点名这件事）。传 props 语义一样，只碰一个文件。
    /// 这里也不自己问磁盘 —— 读的是批 4 那颗对账结果，两页因此共用同一个答案（判定唯一出口的**读侧**）。
    func isSourceMissing(for segment: Segment) -> Bool {
        guard let videoID = segment.video?.id else { return false }
        return MaterialAvailabilityStore.shared.missingVideoIDs.contains(videoID)
    }

    /// 重认单个分镜的台词。**用哪台引擎由门面问决策表**（红线 R4/R6），这里不复写规则。
    func reextractTranscript(_ segment: Segment, context: ModelContext) async {
        // 判定与措辞都改问唯一出口（批 5）：逐段重听与整片重认、导出、播放从此共用同一个答案。
        // ⚠️ 两颗 guard 分开写（合成一颗会让 `video` 在 else 里根本不在作用域内，xcodebuild 报
        //    cannot find 'video' —— 本轮实测）。分开的另一层意思：**取不到所属视频**与
        //    **文件不在**是两件事，从前合成一颗时前者也被报成"找不到原视频文件"，那是说谎。
        guard let video = segment.video else {
            MixLog.error("[重认台词] 分镜取不到所属视频（悬空关联），本次不处理")
            return
        }
        guard !video.localPath.isEmpty, FileHelper.isMaterialFilePresent(path: video.localPath) else {
            ToastCenter.shared.show(MissingMaterialCopy.fullMessage(fileName: video.name),
                                    icon: "exclamationmark.triangle.fill", style: .warning)
            return
        }
        guard !busyASRSegmentIDs.contains(segment.id) else { return }
        busyASRSegmentIDs.insert(segment.id)
        defer { busyASRSegmentIDs.remove(segment.id) }

        let fps = video.fps > 0 ? video.fps : 30
        let result = await SegmentTranscriber.shared.transcribe(SegmentTranscriber.Request(
            videoPath: video.localPath,
            segmentIndex: segment.segmentIndex,
            startSeconds: Double(segment.startFrame) / fps,
            endSeconds: Double(segment.endFrame) / fps,
            currentText: segment.text,
            currentSource: segment.textSource))

        guard let text = result.textToWrite, let source = result.sourceToWrite else {
            // 没拿到要写的值 ⇒ 一个字都不动（R8）。原因由门面给，界面不编。
            ToastCenter.shared.show(Self.noWriteToast(for: result),
                                    icon: "waveform.slash", style: .warning, duration: 6)
            return
        }
        segment.setText(text, source: source)
        // 保存失败时不能再报"成功"：台词要重新识别一次，用户必须知道没存上
        if context.saveOrWarn("台词") {
            ToastCenter.shared.show(Self.successToast(for: result))
        }
    }

    /// Toast 文案按**实际跑的引擎**生成（同一句话两边都说，就看不出走的是哪条路）。
    static func successToast(for result: SegmentTranscriber.Result) -> String {
        var line = "已用\(result.engine?.displayName ?? "识别引擎")重提取台词"
        if result.outcome == .unchanged { line = "重听结果与原台词一致，未改动" }
        if let tier = result.tier { line += "（\(tier)）" }
        if result.fallbackUsed { line += "（首选失败，已回落）" }
        return line
    }

    static func noWriteToast(for result: SegmentTranscriber.Result) -> String {
        let detail = result.reason.map { "：\($0)" } ?? ""
        switch result.outcome {
        case .emptyAudio: return "未识别到语音，保留原台词\(detail)"
        case .refused: return "这次没跑识别\(detail)，原台词保持不变"
        case .engineFailed, .bothEnginesFailed: return "重提取失败\(detail)，原台词保持不变"
        case .cancelled: return "已取消，原台词保持不变"
        case .unchanged, .replaced: return "原台词保持不变"
        }
    }

    /// 统计信息
    var statistics: (total: Int, byType: [SemanticType: Int], avgQuality: Double) {
        var byType: [SemanticType: Int] = [:]
        for seg in segments {
            for t in seg.semanticTypes {
                byType[t, default: 0] += 1
            }
        }
        let avg = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + $1.qualityScore } / Double(segments.count)
        return (segments.count, byType, avg)
    }
}

/// 预览播放请求（用于微调后触发播放器跳转）
struct SegmentPreviewRequest: Equatable {
    let segmentID: UUID
    let from: Double
    let to: Double
}
