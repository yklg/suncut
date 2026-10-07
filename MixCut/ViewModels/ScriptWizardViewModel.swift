import Foundation
import SwiftData

/// 产品脚本成片向导的视图模型 —— 单模态状态机，全程绑定单个项目，禁止跨项目。
///
/// 阶段（互斥，枚举驱动）：
/// setup（方向/结构模式）→ structure（结构草稿可编辑）→ matching（分镜匹配/手工选片/冲突）
/// → review（正向：逐槽检索写作后确认；逆向：原文确认；引用可展开、可改文案重校验）
/// → materialize 成功结束。
@Observable
@MainActor
final class ScriptWizardViewModel {

    enum Stage: Equatable {
        case setup, structure, matching, review, finished
    }

    enum DirectionChoice: Equatable { case forward, reverse }
    enum StructureChoice: Equatable { case template, aiAuto }

    /// 匹配页每个场景一行投影。
    struct MatchRow: Identifiable {
        let id: UUID           // scene id
        let order: Int
        let tag: String
        let targetDuration: Double
        var status: SceneMatchStatus
        /// 同标签候选（不含时长过滤，供快速选）。
        var candidates: [Segment]
        var scene: ScriptScene
    }

    /// 确认页每场景的校验标记。
    struct ReviewMark: Equatable {
        var complianceIssues: [ComplianceChecker.Issue]
        var grounding: GroundingChecker.Report
        /// 是否要求事实落地校验：正向 true（AI 依资料新撰）；
        /// 逆向 false（用户粘贴原文，无资料可引，见 ScriptGroundingGate）。
        var groundingRequired: Bool
    }

    // MARK: State

    let boundProjectID: UUID
    let project: Project
    let product: Product?

    var stage: Stage = .setup
    var direction: DirectionChoice = .forward
    var structureChoice: StructureChoice = .template

    var drafts: [ScriptStructureDraft] = []
    var pastedText: String = ""

    var flowPhase: ScriptFlowPhase = .idle
    var errorMessage: String?
    var infoMessage: String?

    var script: ScriptDocument?
    var matchRows: [MatchRow] = []
    var conflictSegmentIDs: Set<UUID> = []

    /// sceneID → 最近校验标记（写作完成后初始化一次）。
    var reviewMarks: [UUID: ReviewMark] = [:]

    /// 标识符优先的解边投影（跨边关系经 LiveModelIDIndex 读 persistentModelID，
    /// 不 fault backing——第三起 SIGTRAP 证明先 fault 再检查不可靠）。
    private var lookup: ReviewLookup?

    /// sceneID → 已锁定分镜的纯 UUID 快照（不持模型关系）。
    /// 素材真删广播到达时，关系边可能已被 nullify，回退判据只信这份快照
    /// （同 DubbingJobRegistry.targetSegmentIDs 的存活策略；W3 契约）。
    private var sceneToSegmentID: [UUID: UUID] = [:]

    private var context: ModelContext?

    /// 跨边读取的收口投影（构建于活 fetch 结果，之后视图只读纯值）。
    struct ReviewLookup {
        let index: LiveModelIDIndex
        let segmentByUUID: [UUID: Segment]
        let productByUUID: [UUID: Product]
        let chunkByUUID: [UUID: KnowledgeChunk]
        let documentByUUID: [UUID: KnowledgeDocument]
        let videoByUUID: [UUID: Video]
    }

    // MARK: Init

    init(project: Project) {
        self.project = project
        self.boundProjectID = project.id
        self.product = project.product
        // 唯一删除广播的消费者（W3）：匹配/确认阶段已锁定分镜被真删 → 场景回退 unmatched。
        // target-action + nonisolated 跳板 hop 回 MainActor；处理在广播同步栈外执行，
        // 届时才允许 fetch/save（同 DubbingViewModel 的订阅纪律）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGraphChange(_:)),
            name: .mixCutDataDidUndo,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private nonisolated func handleGraphChange(_ note: Notification) {
        let payload: Any? = note.object
        Task { @MainActor [weak self] in
            self?.handleDataDeletion(payload)
        }
    }

    /// 真删广播处理（已 hop 出广播同步栈）：命中已锁定分镜的场景回退 unmatched。
    private func handleDataDeletion(_ payload: Any?) {
        guard let change = payload as? GraphChange else { return }
        let deletedSegmentIDs = change.idsDeleted(of: .segment)
        guard !deletedSegmentIDs.isEmpty, !matchRows.isEmpty, !sceneToSegmentID.isEmpty else { return }
        let affected = ScriptMatchRepair.affectedSceneIDs(
            sceneToSegment: sceneToSegmentID,
            deletedSegmentIDs: deletedSegmentIDs)
        guard !affected.isEmpty else { return }

        for row in matchRows where affected.contains(row.id) {
            row.scene.matchedSegment = nil
            row.scene.matchStatus = .unmatched
            sceneToSegmentID.removeValue(forKey: row.id)
        }
        // 重建 lookup（边已变）+ 重算冲突 + 同步行状态 + save。
        repairAfterDeletion()
        let inReview = stage == .review
        infoMessage = inReview
            ? "有 \(affected.count) 个段落的分镜已被删除，请返回匹配页重新选择后再物化"
            : "有 \(affected.count) 个段落的分镜已被删除，请重新选择"
        MixLog.info("[ScriptWizard] 素材真删回退 unmatched：\(affected.count) 个场景")
    }

    /// 删除回退后的收口（独立于手工改选：不覆盖 infoMessage 的删除提示语义）。
    private func repairAfterDeletion() {
        guard let context else { return }
        buildLookup()
        var used: [UUID: Int] = [:]
        for row in matchRows {
            guard let sid = matchedSegmentID(for: row) else { continue }
            used[sid, default: 0] += 1
        }
        conflictSegmentIDs = Set(used.filter { $0.value > 1 }.keys)
        for index in matchRows.indices {
            matchRows[index].status = matchRows[index].scene.matchStatus
        }
        syncSceneSegmentSnapshot()
        try? context.save()
    }

    func setContext(_ context: ModelContext) {
        self.context = context
    }

    // MARK: Computed

    var isBusy: Bool { flowPhase.isBusy }

    /// 正向模板的默认带货结构。
    static let defaultTemplate: [ScriptStructureDraft] = [
        .init(order: 1, tag: SemanticType.hook.rawValue, duration: 2.5, text: ""),
        .init(order: 2, tag: SemanticType.painPoint.rawValue, duration: 4.0, text: ""),
        .init(order: 3, tag: SemanticType.solution.rawValue, duration: 6.0, text: ""),
        .init(order: 4, tag: SemanticType.results.rawValue, duration: 5.0, text: ""),
        .init(order: 5, tag: SemanticType.socialProof.rawValue, duration: 4.0, text: ""),
        .init(order: 6, tag: SemanticType.callToAction.rawValue, duration: 3.0, text: ""),
    ]

    var draftsTotalDuration: Double {
        drafts.reduce(0) { $0 + $1.duration }
    }

    var matchedSceneCount: Int {
        matchRows.filter { $0.status == .matched }.count
    }

    /// 无冲突且全部锁定，才能进下一步。
    var matchingReady: Bool {
        !matchRows.isEmpty
            && matchRows.allSatisfy { $0.status == .matched }
            && conflictSegmentIDs.isEmpty
    }

    // MARK: Setup → Structure

    func enterStructure() {
        errorMessage = nil
        if direction == .forward && structureChoice == .template && drafts.isEmpty {
            drafts = Self.defaultTemplate
        }
        buildLookup()
        stage = .structure
    }

    func generateAIStructure() async {
        guard let product, flowPhase != .matching else { return }
        flowPhase = .matching
        errorMessage = nil
        defer { flowPhase = .idle }
        do {
            let target = project.videoCount > 0 ? 30.0 : 30.0
            drafts = try await StructureGenerationService.generate(
                productName: product.name, targetDuration: target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runReverseStructure() async {
        guard !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先粘贴需要结构化的文案"
            return
        }
        flowPhase = .matching
        errorMessage = nil
        defer { flowPhase = .idle }
        do {
            drafts = try await ReverseStructuringService.structure(pastedText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Structure edits

    func reorderDrafts() {
        for index in drafts.indices { drafts[index].order = index + 1 }
    }

    func moveDraft(_ draft: ScriptStructureDraft, offset: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        let target = index + offset
        guard drafts.indices.contains(target) else { return }
        drafts.swapAt(index, target)
        reorderDrafts()
    }

    func removeDraft(_ draft: ScriptStructureDraft) {
        drafts.removeAll { $0.id == draft.id }
        reorderDrafts()
    }

    func addDraft(tag: String) {
        drafts.append(.init(order: drafts.count + 1, tag: tag,
                            duration: 3.0,
                            text: direction == .reverse ? "" : ""))
    }

    // MARK: Match

    /// 结构定稿：插入 draft 脚本与场景（结构定稿即落库），执行匹配。
    func startMatching() async {
        guard let context, let product else {
            errorMessage = "当前项目缺少产品信息，无法生成脚本"
            return
        }
        guard !drafts.isEmpty else { errorMessage = "请先确定脚本结构"; return }

        let document = ScriptDocument(
            project: project,
            product: product,
            title: "\(product.name)脚本 \(Date().formatted(.dateTime.month().day().hour().minute()))",
            direction: direction == .reverse ? .reverse : .forward,
            structureMode: structureChoice == .aiAuto ? .aiAuto : .template,
            targetDuration: draftsTotalDuration,
            status: .draft)
        context.insert(document)

        for draft in drafts {
            let scene = ScriptScene(
                script: document,
                order: draft.order,
                tag: draft.tag,
                text: draft.text,
                targetDuration: draft.duration,
                matchStatus: .unmatched)
            context.insert(scene)
        }
        do {
            try context.save()
        } catch {
            errorMessage = "脚本草稿保存失败：\(error.localizedDescription)"
            return
        }
        script = document
        await runMatcher()
        stage = .matching
    }

    /// 重新执行匹配（不覆盖用户已手工锁定的选择）。
    func runMatcher() async {
        guard let script, let context else { return }
        flowPhase = .matching
        errorMessage = nil
        defer { flowPhase = .idle }

        let segments = projectSegments(context)
        let candidates = segments.map {
            ScriptMatcher.Candidate(
                id: $0.id,
                tags: $0.semanticTypes.map(\.rawValue),
                duration: $0.duration)
        }
        let scenes = script.scenes.sorted { $0.order < $1.order }
        let slots = scenes.map {
            ScriptMatcher.Slot(id: $0.id, order: $0.order, tag: $0.tag,
                               targetDuration: $0.targetDuration)
        }
        let outcome = ScriptMatcher.match(slots: slots, candidates: candidates)

        let segByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [MatchRow] = []

        for (scene, result) in zip(scenes, outcome.results) {
            let sameTag = segments
                .filter { $0.semanticTypes.map(\.rawValue).contains(scene.tag) }
                .sorted(by: segmentOrder)

            switch result {
            case .matched(let segmentID):
                scene.matchedSegment = segByID[segmentID]
                scene.matchStatus = .matched
            case .multiCandidate(let ids):
                scene.matchStatus = .multiCandidate
                var ordered = ids.compactMap { segByID[$0] }
                ordered.append(contentsOf: sameTag.filter { seg in !ids.contains(seg.id) })
                rows.append(MatchRow(
                    id: scene.id, order: scene.order, tag: scene.tag,
                    targetDuration: scene.targetDuration, status: .multiCandidate,
                    candidates: ordered, scene: scene))
                continue
            case .unmatched:
                scene.matchStatus = .unmatched
            }
            rows.append(MatchRow(
                id: scene.id, order: scene.order, tag: scene.tag,
                targetDuration: scene.targetDuration, status: scene.matchStatus,
                candidates: sameTag, scene: scene))
        }

        conflictSegmentIDs = Set(outcome.conflicts.map(\.segmentID))
        matchRows = rows.sorted { $0.order < $1.order }
        syncSceneSegmentSnapshot()
        try? context.save()

        if !conflictSegmentIDs.isEmpty {
            infoMessage = "存在分镜被多个段落同时命中，请手工改选后继续"
        }
    }

    /// 手工选择某场景的分镜。
    func selectSegment(_ segment: Segment, for row: MatchRow) {
        row.scene.matchedSegment = segment
        row.scene.matchStatus = .matched
        refreshAfterManualChange()
    }

    /// 清除某场景的选择。
    func clearSelection(for row: MatchRow) {
        row.scene.matchedSegment = nil
        row.scene.matchStatus = .unmatched
        refreshAfterManualChange()
    }

    private func refreshAfterManualChange() {
        guard let context else { return }
        buildLookup()
        // 重算冲突（同 segment 被多场景使用）；id 经解边索引解析，不 fault backing。
        var used: [UUID: Int] = [:]
        for row in matchRows {
            guard let sid = matchedSegmentID(for: row) else { continue }
            used[sid, default: 0] += 1
        }
        conflictSegmentIDs = Set(used.filter { $0.value > 1 }.keys)
        // 同步行状态。
        for index in matchRows.indices {
            matchRows[index].status = matchRows[index].scene.matchStatus
        }
        syncSceneSegmentSnapshot()
        try? context.save()
        infoMessage = conflictSegmentIDs.isEmpty ? nil : "仍有分镜被多个段落同时命中"
    }

    /// 重建「场景 → 锁定分镜」纯 UUID 快照（真删回退判据的唯一输入；W3）。
    private func syncSceneSegmentSnapshot() {
        var snapshot: [UUID: UUID] = [:]
        for row in matchRows {
            if let segmentID = matchedSegmentID(for: row) {
                snapshot[row.id] = segmentID
            }
        }
        sceneToSegmentID = snapshot
    }

    // MARK: Matching → Review

    /// 全部锁定后：正向先写作；逆向直接进确认。
    func proceedAfterMatching() async {
        guard matchingResumeGuard() else { return }
        if direction == .forward {
            await runWriting()
        } else {
            seedReviewMarks()
            stage = .review
        }
    }

    private func matchingResumeGuard() -> Bool {
        guard matchingReady else {
            errorMessage = "请先为所有段落锁定唯一分镜并解决冲突"
            return false
        }
        guard let script else { return false }
        do {
            guard let context else { return false }
            try context.save()
            if script.status == .draft {
                _ = script.transition(to: .matched)
                try context.save()
            }
            return true
        } catch {
            errorMessage = "状态保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func runWriting() async {
        // 不可能状态也要响（原 guard-else 无声返回是「点了没反应」的静默分支之一）。
        guard let context else {
            reportWritingFailure("写作启动失败：数据上下文缺失")
            return
        }
        guard let script else {
            reportWritingFailure("写作启动失败：脚本文档缺失")
            return
        }
        guard let product else {
            reportWritingFailure("写作启动失败：当前项目缺少产品信息")
            return
        }
        // 单一状态规则：进入写作即清旧错误（进度态与错误态互斥）。
        errorMessage = nil
        do {
            let results = try await ScriptWritingService.write(
                script: script, product: product, context: context) { [weak self] phase in
                    self?.flowPhase = phase
                }
            // 落回场景。
            let byID = Dictionary(results.map { ($0.sceneID, $0) }, uniquingKeysWith: { first, _ in first })
            for row in matchRows {
                guard let result = byID[row.id] else { continue }
                row.scene.setText(result.text)
                row.scene.citationChunkIDs = result.citationChunkIDs
            }
            try context.save()
            flowPhase = .ready
            seedReviewMarks()
            stage = .review
        } catch {
            reportWritingFailure(error.localizedDescription)
        }
    }

    /// 写作失败的统一收口：失败态 + 错误横幅（UI 的诊断读数）。
    private func reportWritingFailure(_ reason: String) {
        flowPhase = .failed(reason: reason)
        errorMessage = reason
    }

    /// 清除错误横幅（失败态同步回收；场景选择未被破坏，可直接点「开始写作」重试）。
    func dismissError() {
        errorMessage = nil
        if case .failed = flowPhase { flowPhase = .idle }
    }

    // MARK: Review

    private func seedReviewMarks() {
        guard context != nil else { return }
        buildLookup()
        for row in matchRows {
            reviewMarks[row.scene.id] = makeMark(for: row.scene)
        }
    }

    /// 编辑文案后重新校验该场景（手动按钮：保存 + 重建解边投影后重算）。
    func revalidate(sceneID: UUID) {
        guard let context, let row = matchRows.first(where: { $0.id == sceneID }) else { return }
        try? context.save()
        buildLookup()
        reviewMarks[sceneID] = makeMark(for: row.scene)
    }

    /// 编辑文案的增量重校验（W4）：TextEditor 每击触发。
    /// 不重 fetch —— 引用关系在编辑中未变，复用现有 lookup 投影；只跑纯函数校验，
    /// 物化按钮的解禁/禁用由此实时反映（逆向只跑合规；正向含 grounding）。
    func noteTextEdited(sceneID: UUID) {
        guard let row = matchRows.first(where: { $0.id == sceneID }) else { return }
        reviewMarks[sceneID] = makeMark(for: row.scene)
    }

    /// 单场景校验标记的唯一构造点：合规对两个方向无条件执行；
    /// grounding 经 ScriptGroundingGate 方向门（逆向用户原文豁免）。
    private func makeMark(for scene: ScriptScene) -> ReviewMark {
        let issues = ComplianceChecker.scan(scene.text)
        let requiresGrounding = script
            .map { ScriptGroundingGate.requiresExternalEvidence($0.direction) } ?? true
        guard requiresGrounding else {
            // 逆向：事实来源是用户本人，不做落地校验（空报告 = 无被判对象）。
            return .init(complianceIssues: issues,
                         grounding: .init(facts: [], unsupportedFacts: []),
                         groundingRequired: false)
        }
        let chunkByID = lookup?.chunkByUUID ?? [:]
        let sources = scene.citationChunkIDs.compactMap { chunkByID[$0]?.content }
        return .init(complianceIssues: issues,
                     grounding: GroundingChecker.check(text: scene.text, sources: sources),
                     groundingRequired: true)
    }

    // MARK: 标识符优先的跨边访问器（视图的唯一读数来源）

    /// 场景已选分镜的业务 UUID（经索引解析；悬空 ⇒ nil）。
    func matchedSegmentID(for row: MatchRow) -> UUID? {
        lookup?.index.uuid(for: row.scene.matchedSegment)
    }

    /// 分镜所属视频名（经解边索引纯 UUID 链；视图零跨 video 边，守 G08/G20）。
    /// 边悬空/视频缺失 →「未知视频」。
    func videoName(forSegmentID segmentID: UUID) -> String {
        guard let lookup,
              let segment = lookup.segmentByUUID[segmentID],
              let videoID = lookup.index.uuid(for: segment.video),
              let name = lookup.videoByUUID[videoID]?.name else {
            return "未知视频"
        }
        return name
    }

    /// 场景已选分镜的展示编号（seg_xxx；解析不出 ⇒ 占位）。
    func matchedSegmentIndexLabel(for row: MatchRow) -> String {
        guard let id = matchedSegmentID(for: row),
              let segment = lookup?.segmentByUUID[id] else { return "—" }
        return segment.segmentIndex
    }

    /// 向导绑定项目的产品名（经索引解析 project.product 边）。
    var boundProductName: String? {
        guard let lookup else { return nil }
        guard let id = lookup.index.uuid(for: project.product) else { return nil }
        return lookup.productByUUID[id]?.name
    }

    /// 引用按钮标题：引用片段所属资料名（经索引解析 chunk.document 边）。
    func citationTitle(for chunkID: UUID) -> String {
        guard let lookup, let chunk = lookup.chunkByUUID[chunkID] else { return "资料" }
        if let docID = lookup.index.uuid(for: chunk.document),
           let title = lookup.documentByUUID[docID]?.title {
            return title
        }
        return "资料"
    }

    /// 引用 popover 正文（chunk 自有列，纯值）。
    func citationContent(for chunkID: UUID) -> String {
        lookup?.chunkByUUID[chunkID]?.content ?? "原始片段不可用"
    }

    /// 引用片段所属资料的原始链接（经索引解析 chunk.document 边；悬空 ⇒ nil）。
    func citationSourceURL(for chunkID: UUID) -> String? {
        guard let lookup, let chunk = lookup.chunkByUUID[chunkID] else { return nil }
        if let docID = lookup.index.uuid(for: chunk.document) {
            return lookup.documentByUUID[docID]?.sourceURL
        }
        return nil
    }

    // MARK: 脚本导出（txt/md）

    /// 构造当前向导脚本的导出投影（纯值，渲染交 ScriptTextExporter）。
    /// 引用出处经 lookup 解边，不直接 fault chunk.document。
    func exportDraft() -> ScriptExportDraft? {
        guard let script else { return nil }
        let scenes = matchRows.sorted { $0.order < $1.order }.map { row in
            let citations = row.scene.citationChunkIDs.map { chunkID in
                ScriptExportCitation(documentTitle: citationTitle(for: chunkID),
                                     sourceURL: citationSourceURL(for: chunkID))
            }
            return ScriptExportScene(order: row.order, tag: row.tag,
                                     duration: row.targetDuration,
                                     text: row.scene.text, citations: citations)
        }
        return ScriptExportDraft(title: script.title, direction: script.direction,
                                 productName: product?.name, scenes: scenes)
    }

    /// 从全量活 fetch 构建解边投影（跨边关系只在此处读 persistentModelID）。
    private func buildLookup() {
        guard let context else { return }
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let projectVideos = (try? context.fetch(FetchDescriptor<ProjectVideo>())) ?? []
        let videos = (try? context.fetch(FetchDescriptor<Video>())) ?? []
        let segments = (try? context.fetch(FetchDescriptor<Segment>())) ?? []
        let documents = (try? context.fetch(FetchDescriptor<KnowledgeDocument>())) ?? []
        let chunks = (try? context.fetch(FetchDescriptor<KnowledgeChunk>())) ?? []

        var index = LiveModelIDIndex()
        index.insert(products, id: \.id)
        index.insert(projects, id: \.id)
        index.insert(projectVideos, id: \.id)
        index.insert(videos, id: \.id)
        index.insert(segments, id: \.id)
        index.insert(documents, id: \.id)
        index.insert(chunks, id: \.id)

        lookup = .init(
            index: index,
            segmentByUUID: Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            productByUUID: Dictionary(products.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            chunkByUUID: Dictionary(chunks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            documentByUUID: Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            videoByUUID: Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))

        // 选择器纯值投影随 lookup 一次性构建：匹配页每行/弹窗多次读取，禁止每次全表 fetch。
        // buildLookup 是匹配页数据的唯一重建口（进入结构/匹配、手改选择、真删回退、进确认），
        // 投影在此刷新即覆盖全部变更面。
        let projectVideoIDs = Set(project.associatedVideos.map(\.id))
        let videoNameByID = Dictionary(videos.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        pickerSegments = segments
            .filter { seg in
                guard let vid = index.uuid(for: seg.video) else { return false }
                return projectVideoIDs.contains(vid)
            }
            .sorted(by: segmentOrder)
            .map { seg in
                let videoID = index.uuid(for: seg.video)
                // 缩略图与 SegmentCardSnapshot 同口径：替换画面优先。
                let pic = seg.pictureShowsReplaced ? seg.replacedPictureThumbnailPath : seg.thumbnailPath
                return GridPickerSegment(
                    id: seg.id,
                    videoID: videoID ?? seg.id,            // 理论不悬空；给确定性非 nil 占位避免被全部视频漏掉
                    videoName: videoID.flatMap { videoNameByID[$0] } ?? "未知视频",
                    sourceRaw: seg.sourceRaw,
                    duration: seg.duration,
                    segmentIndex: seg.segmentIndex,
                    tagNames: seg.semanticTypes.map(\.rawValue),
                    text: seg.text,
                    thumbnailPath: pic)
            }
    }

    /// 全部场景校验通过才能物化。
    /// 逆向方向 grounding 豁免（ScriptGroundingGate）：只要求合规 + 非空。
    /// 匹配锁定是前提：确认阶段分镜被真删回退 unmatched 后，按钮必须立即禁用
    /// （否则点下去才由服务层抛错，用户无法从按钮状态读出"还不能成片"）。
    var materializeReady: Bool {
        matchRows.allSatisfy { row in
            guard row.status == .matched else { return false }
            guard let mark = reviewMarks[row.id] else { return false }
            let grounded = !mark.groundingRequired || mark.grounding.isGrounded
            return mark.complianceIssues.isEmpty && grounded
                && !row.scene.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var materializeWarnings: [String] {
        matchRows.compactMap { row in
            if row.status != .matched { return "第 \(row.order) 段尚未锁定分镜" }
            guard let mark = reviewMarks[row.id] else { return "第 \(row.order) 段尚未校验" }
            if !mark.complianceIssues.isEmpty {
                return "第 \(row.order) 段：" + mark.complianceIssues.map(ComplianceChecker.describe).joined(separator: "、")
            }
            if mark.groundingRequired, !mark.grounding.isGrounded {
                return "第 \(row.order) 段无依据事实：" + mark.grounding.unsupportedFacts.joined(separator: "、")
            }
            if row.scene.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "第 \(row.order) 段文案为空"
            }
            return nil
        }
    }

    /// 物化。成功返回新方案（供视图发焦点通知跳转到混剪方案页）；失败返回 nil 并落错误横幅。
    @discardableResult
    func materialize() -> MixScheme? {
        guard let context, let script else { return nil }
        do {
            let scheme = try MaterializationService.materialize(script: script, context: context)
            stage = .finished
            return scheme
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: 分镜网格选择器（中立 SegmentGridPicker 的向导侧适配）

    /// 当前打开选择器的场景行 id；nil=关闭。
    var pickerSlotID: UUID?
    /// 选择器筛选态（@Observable 属性，视图绑定）。
    var pickerFilter = GridPickerFilter()

    /// 选择器是否打开。
    var isPickerPresented: Bool { pickerSlotID != nil }

    /// 当前正在挑选的行。
    var pickerRow: MatchRow? {
        guard let id = pickerSlotID else { return nil }
        return matchRows.first { $0.id == id }
    }

    func openPicker(for row: MatchRow) {
        pickerSlotID = row.id
        // 初始筛选：标签预筛当前槽位标签；视频/来源/搜索默认全部。
        pickerFilter = GridPickerFilter(requiredTags: Set([row.tag]))
    }

    func closePicker() { pickerSlotID = nil }

    /// 选择器全部候选的纯值投影（当前项目分镜；含视频名/台词/标签/时长/来源）。
    /// 由 buildLookup 一次性构建并缓存（匹配页数据的唯一重建口），行卡/弹窗只读，零额外 fetch。
    private(set) var pickerSegments: [GridPickerSegment] = []

    /// 经纯函数过滤后的选择器网格数据（视图唯一来源）。
    func filteredPickerSegments() -> [GridPickerSegment] {
        SegmentGridPicker.filter(pickerSegments, pickerFilter)
    }

    /// 视频筛选 chips（全部 + 各视频计数）。
    func pickerVideoGroups() -> [GridPickerVideoGroup] {
        SegmentGridPicker.videoGroups(pickerSegments)
    }

    /// 「标签匹配 N 个」统计（仅标签维，与搜索/来源/视频选择独立，防数字说假话）。
    var pickerTagMatchedCount: Int {
        guard let row = pickerRow else { return pickerSegments.count }
        return SegmentGridPicker.tagMatchedCount(pickerSegments, requiredTags: Set([row.tag]))
    }

    /// 当前选择器的占用信息（除当前挑选段外，被其他段锁定的分镜）。
    func pickerOccupancy() -> [GridPickerOccupancy] {
        var claimed: [UUID: GridPickerClaim] = [:]
        for row in matchRows {
            guard let segID = matchedSegmentID(for: row) else { continue }
            claimed[segID] = GridPickerClaim(sceneID: row.id,
                                             sceneOrder: row.order,
                                             sceneTag: row.tag)
        }
        return SegmentGridPicker.occupancy(claimed: claimed, currentSlotSceneID: pickerSlotID)
    }

    /// 选择器内直接选中未占用分镜：走唯一收口 selectSegment。
    func pickerSelect(_ segmentID: UUID) {
        guard let row = pickerRow,
              let segment = lookup?.segmentByUUID[segmentID] else { return }
        selectSegment(segment, for: row)
        closePicker()
    }

    /// 选择器「移到本段」：先让原占用段回退未匹配，再给当前段选中。
    /// P1-3：只允许调用既有 clearSelection + selectSegment，不另写行/冲突更新。
    func pickerMoveSegment(_ segmentID: UUID) {
        guard let current = pickerRow,
              let ownerRow = matchRows.first(where: {
                  $0.id != current.id && matchedSegmentID(for: $0) == segmentID
              }),
              let segment = lookup?.segmentByUUID[segmentID] else { return }
        clearSelection(for: ownerRow)
        selectSegment(segment, for: current)
        closePicker()
    }

    // MARK: Cancel / Back（原段落）

    /// 回退到结构页（仅 draft 态允许；删除草稿行）。
    func backToStructure() {
        guard let context, let script, script.status == .draft else {
            errorMessage = "匹配已锁定，不能再修改结构"
            return
        }
        context.delete(script)   // scenes cascade
        try? context.save()
        self.script = nil
        matchRows = []
        conflictSegmentIDs = []
        sceneToSegmentID = [:]
        stage = .structure
    }

    /// 取消向导：任何未物化状态都删除脚本（matched 前后均按契约清除，不留半成品）。
    func cancel() {
        guard let context, let script else { stage = .setup; return }
        if script.status != .materialized {
            context.delete(script)
            try? context.save()
        }
        self.script = nil
        matchRows = []
        conflictSegmentIDs = []
        sceneToSegmentID = [:]
        stage = .setup
    }

    // MARK: Fetch helpers

    /// 当前项目关联视频下的全部分镜（跨边关系只在此读取）。
    private func projectSegments(_ context: ModelContext) -> [Segment] {
        let videoIDs = Set(project.associatedVideos.map(\.id))
        let all = (try? context.fetch(FetchDescriptor<Segment>())) ?? []
        return all.filter { segment in
            guard let videoID = segment.video?.id else { return false }
            return videoIDs.contains(videoID)
        }
        .sorted(by: segmentOrder)
    }

    private func segmentOrder(_ lhs: Segment, _ rhs: Segment) -> Bool {
        if lhs.segmentIndex != rhs.segmentIndex { return lhs.segmentIndex < rhs.segmentIndex }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
