import Foundation
import SwiftData

/// 方案浏览 ViewModel
@MainActor
@Observable
final class SchemeViewModel {
    var strategies: [MixStrategy] = []
    var selectedStrategy: MixStrategy?
    var selectedScheme: MixScheme?
    var isGenerating = false

    // 配音（P5）：生成方案时的音色模式
    var generationVoiceMode: VoiceMode = .unified
    var generationUnifiedVoiceId: String?
    /// 叙事结构变体生成中（独立于 AI 方案生成的 isGenerating，避免误禁用工具栏「生成」按钮）
    var isNarrativeGenerating = false
    var generationProgress: String = ""
    var errorMessage: String?
    /// 本次生成中失败的策略（名称 + 人话原因），供界面如实展示"哪几个没生成、为什么"。
    /// ⚠️ 用独立 id 而不是拿 name 当 ForEach 的 id —— AI 生成的策略名可能重复，
    /// 重复 id 会让 SwiftUI 的列表渲染错乱。
    struct FailedStrategy: Identifiable {
        let id = UUID()
        let name: String
        let reason: String
    }
    var failedStrategies: [FailedStrategy] = []

    /// 会话内真删分镜的剪枝信号（状态机本体在 MixCutCore，纯值类型 + PS-1~5 单测）。
    /// ContentView 唯一广播路由分发已删 id；持有快照的抽屉按 version 变化本地剪枝。
    private var pruneSignals = SegmentPruneSignals()
    var pruneVersion: Int { pruneSignals.version }
    var prunedSegmentIDs: Set<UUID> { pruneSignals.ids }
    func notePrunedSegments(_ ids: Set<UUID>) {
        pruneSignals.note(ids)
    }

    private var modelContext: ModelContext?
    private let schemeService = SchemeGenerationService()

    /// 方案 id → 脚本创作方向（仅产品脚本物化方案有条目）。
    /// 经冻结 ScriptDocument.realizedScheme 标识符解边（不 fault backing）；
    /// 方案列表的「产品脚本/逆向文案」标签的唯一数据源。
    private(set) var scriptDirectionBySchemeID: [UUID: ScriptDirection] = [:]

    /// 物化完成后待聚焦选中的方案 id（跨 loadSchemes 的清空-重载闭环保留）。
    /// 通知可能早于 SchemeListView appear；loadSchemes 末尾消费，**消费即清空**。
    /// 定位失败（跨项目陈旧事件/已删）静默丢弃且不改选中——判定在 Core SchemeFocus.locate。
    private(set) var pendingFocusSchemeID: UUID?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 上次装载数据所属项目（同项目重载连续性判据；nil = 本进程尚未装载过）。
    /// 切项目铁律靠它：isSameProject=false 时策略绝不保留旧项目选中。
    private var lastLoadedProjectID: UUID?

    /// 加载项目的所有策略和方案。
    ///
    /// 「刷新快照数据」与「选中谁」彻底分开：选中裁决全部下沉 Core SchemeSelection.resolve
    /// （焦点 → 同项目连续性 → 展示序第一非空容器 → 全空清空），本方法只做投影与应用。
    /// 禁止再在此写 `strategies.first` 式硬编码默认——空「自定义组合」随项目一起创建、
    /// createdAt 最早，旧默认必选空组导致右栏空白（G-S9 守卫钉死此回归）。
    func loadSchemes(for project: Project) {
        // 重载前先把待删除项真正删除，避免隐藏项在重载后又冒出来
        PendingDeletionCenter.shared.flushNow()

        let previous = SchemeSelection.Current(strategyID: selectedStrategy?.id,
                                               schemeID: selectedScheme?.id)
        let isSameProject = lastLoadedProjectID == project.id
        let focus = pendingFocusSchemeID

        strategies = project.strategies.sorted { $0.createdAt < $1.createdAt }

        // 选中树必须覆盖 UI 上全部可选容器：AI → 产品脚本成片（含内存占位）→ 自定义组合，
        // 再并底部「自定义结构」分组——否则叙事结构变体的选中在同项目 keep 时会定位不到。
        // 空容器（含内存占位脚本组）保留在树里，由策略层负责跳过。
        let groupsForSelection = orderedStrategiesForDisplay + narrativeTemplates
        let trees = groupsForSelection.map {
            SchemeFocus.Tree(strategyID: $0.id, orderedSchemeIDs: $0.orderedSchemes.map(\.id))
        }
        let decision = SchemeSelection.resolve(pendingFocus: focus,
                                               current: previous,
                                               trees: trees,
                                               isSameProject: isSameProject)
        // 焦点令牌一次即焚：命中已转 select；陈旧（跨项目/已删）也吞掉，
        // 防后续同项目重载被过期意图反复夺选。
        pendingFocusSchemeID = nil
        applySelection(decision, previous: previous, groups: groupsForSelection)

        lastLoadedProjectID = project.id
        refreshScriptProjections()
    }

    /// 把 Core 选中裁决映射回模型对象：一律按 id 从本次新加载的图里重取，不握重载前的旧引用。
    private func applySelection(_ decision: SchemeSelection.Decision,
                                previous: SchemeSelection.Current,
                                groups: [MixStrategy]) {
        switch decision {
        case .select(let strategyID, let schemeID):
            guard let group = groups.first(where: { $0.id == strategyID }),
                  let scheme = group.orderedSchemes.first(where: { $0.id == schemeID }) else {
                selectedStrategy = nil
                selectedScheme = nil
                return
            }
            selectedStrategy = group
            selectedScheme = scheme
        case .keep:
            // 策略已保证同项目且 schemeID 在树中；此处仍防御式重取（取不到则安全清空）。
            guard let schemeID = previous.schemeID,
                  let group = groups.first(where: { $0.orderedSchemes.contains { $0.id == schemeID } }),
                  let scheme = group.orderedSchemes.first(where: { $0.id == schemeID }) else {
                selectedStrategy = nil
                selectedScheme = nil
                return
            }
            selectedStrategy = group
            selectedScheme = scheme
        case .clear:
            selectedStrategy = nil
            selectedScheme = nil
        }
    }

    /// 请求物化后聚焦某方案（由 ContentView 收到 .mixCutFocusScheme 通知时调用）。
    /// 不直接选中：作为一次性意图在下一次 loadSchemes 经 SchemeSelection 统一裁决，
    /// 这样「立即消费」与「SchemeListView.onAppear 装载」谁先谁后结果都一致。
    func requestFocus(schemeID: UUID) {
        pendingFocusSchemeID = schemeID
    }

    /// 重建「方案 → 脚本方向」投影（全量活 fetch + 标识符解边；脚本方案数量少）。
    func refreshScriptProjections() {
        guard let modelContext else { return }
        let documents = (try? modelContext.fetch(FetchDescriptor<ScriptDocument>())) ?? []
        guard !documents.isEmpty else {
            if !scriptDirectionBySchemeID.isEmpty { scriptDirectionBySchemeID = [:] }
            return
        }
        let schemes = (try? modelContext.fetch(FetchDescriptor<MixScheme>())) ?? []
        var index = LiveModelIDIndex()
        index.insert(schemes, id: \.id)
        var map: [UUID: ScriptDirection] = [:]
        for document in documents {
            if let schemeID = index.uuid(for: document.realizedScheme) {
                map[schemeID] = document.direction
            }
        }
        scriptDirectionBySchemeID = map
    }

    /// dubOnly 方案的新配音就绪度（纯值读数：已生成音频的槽位数 / 总槽位数）。
    /// 计算放 VM 而不是视图：视图层跨模型关系读取有 G08 名册守卫（零新增）。
    func dubbingReadiness(for scheme: MixScheme) -> (ready: Int, total: Int) {
        let ordered = scheme.orderedSegments
        var ready = 0
        for ss in ordered {
            guard let id = ss.selectedSegmentDubId,
                  let path = ss.segment?.segmentDubs.first(where: { $0.id == id })?.audioFilePath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            ready += 1
        }
        return (ready, ordered.count)
    }

    /// 所有方案的扁平列表（兼容旧接口）
    var schemes: [MixScheme] {
        strategies.flatMap(\.orderedSchemes)
    }

    /// AI 生成的策略（排除三类容器：自定义组合 / 自定义叙事结构 / 产品脚本成片）。
    /// 新增容器类型必须在此显式排除——G-S7 守卫钉死此三字段组合。
    var aiStrategies: [MixStrategy] {
        strategies.filter { !$0.isCustomGroup && !$0.isNarrativeTemplate && !$0.isScriptGroup }
    }

    /// 当前项目的"自定义组合"策略容器
    var customGroup: MixStrategy? {
        strategies.first { $0.isCustomGroup }
    }

    /// 用户自定义叙事结构（侧边栏"自定义结构"分组下展示）
    var narrativeTemplates: [MixStrategy] {
        strategies.filter { $0.isNarrativeTemplate }
    }

    /// 已持久化的「产品脚本成片」容器（首个脚本物化时由 MaterializationService 懒建）。
    private var persistedScriptGroup: MixStrategy? {
        strategies.first { $0.isScriptGroup }
    }

    /// 「产品脚本成片」容器：持久化容器优先；缺失时返回**内存占位组**（不 insert、不参与任何 save）。
    /// 使空组与「＋新建脚本成片」入口对存量/新建项目恒定可见；占位由工厂构造，见 makeScriptPlaceholder()。
    var scriptGroup: MixStrategy {
        persistedScriptGroup ?? Self.makeScriptPlaceholder()
    }

    /// 内存占位组（禁落库）。
    /// !! 非持久化对象：禁止 context.insert/delete/save；deleteStrategy 对其必须直接 return（G-S7 守卫）。
    static func makeScriptPlaceholder() -> MixStrategy {
        let placeholder = MixStrategy(
            name: "产品脚本成片",
            style: "产品脚本成片",
            description: "知识库写文案 / 粘贴逆向文案，逐段锁定分镜 · 全新配音",
            targetAudience: "",
            narrativeStructure: "",
            targetDuration: 0
        )
        placeholder.isScriptGroup = true
        // 刻意不 insert：它是 UI 占位，首个脚本物化时 MaterializationService 才建真实容器。
        return placeholder
    }

    /// 列表渲染用的有序策略：AI 策略 → 产品脚本成片 → 自定义组合。
    /// （自定义叙事结构 narrativeTemplates 仍由列表底部独立分组渲染。）
    var orderedStrategiesForDisplay: [MixStrategy] {
        aiStrategies + [scriptGroup] + (customGroup.map { [$0] } ?? [])
    }

    /// 导出页用：所有含方案的策略。占位脚本组无方案，扁平后不贡献条目（无需特判）；
    /// 真实脚本容器物化后自动出现在这里，dubOnly 组合链路即导出可见。
    var exportableStrategies: [MixStrategy] {
        orderedStrategiesForDisplay + narrativeTemplates
    }

    // MARK: - 构建分镜目录（全局唯一 ID）

    /// 在 MainActor 上构建分镜目录和 ID 映射
    /// ID 格式：V{视频序号}_{分镜序号}，确保跨视频全局唯一
    private func buildSegmentCatalog(_ segments: [Segment]) -> SegmentCatalog {
        // 按视频分组，建立视频别名
        var videoNames: [String] = []
        var videoIndexMap: [String: Int] = [:]

        for seg in segments {
            let name = seg.video?.name ?? "unknown"
            if videoIndexMap[name] == nil {
                videoIndexMap[name] = videoNames.count + 1
                videoNames.append(name)
            }
        }

        // 视频别名
        let aliases = videoNames.enumerated().map { i, name in
            "V\(i + 1) = \(name)"
        }.joined(separator: "\n")

        // 按视频分组、按时间排序（确保 ID 稳定）
        let sortedSegments = segments.sorted { a, b in
            let aName = a.video?.name ?? ""
            let bName = b.video?.name ?? ""
            if aName != bName { return aName < bName }
            return a.startTime < b.startTime
        }

        // 构建目录表格和 ID 映射
        var idMap: [String: Segment] = [:]
        var infoMap: [String: SegmentInfo] = [:]
        var catalogLines: [String] = []
        var segCountPerVideo: [String: Int] = [:]

        for seg in sortedSegments {
            let videoName = seg.video?.name ?? "unknown"
            let vIdx = videoIndexMap[videoName] ?? 1
            let segNum = (segCountPerVideo[videoName] ?? 0) + 1
            segCountPerVideo[videoName] = segNum

            let globalId = String(format: "V%d_%02d", vIdx, segNum)
            idMap[globalId] = seg

            let types = seg.semanticTypes.map(\.rawValue)
            let dur = String(format: "%.1f", seg.duration)
            let pos = seg.positionType.rawValue

            infoMap[globalId] = SegmentInfo(
                duration: seg.duration,
                types: types,
                text: seg.text,
                position: pos
            )

            catalogLines.append("\(globalId)|\(pos)|\(types.joined(separator: ","))|\(dur)s|\(seg.text)")
        }

        let catalog = catalogLines.joined(separator: "\n")
        return SegmentCatalog(catalogText: catalog, videoAliases: aliases, idMap: idMap, infoMap: infoMap)
    }

    // MARK: - 生成

    /// 自动计算策略数量
    private func strategyCount(for targetTotal: Int) -> Int {
        if targetTotal <= 30 { return 3 }
        if targetTotal <= 80 { return 4 }
        return 5
    }

    /// 生成混剪方案（新架构：策略 + 批量组合）
    func generateSchemes(
        for project: Project,
        targetVideoCount: Int = 50,
        customPrompt: String? = nil
    ) async {
        guard let context = modelContext else { return }

        // 上限 100
        let clampedTarget = min(targetVideoCount, 100)

        isGenerating = true
        errorMessage = nil
        failedStrategies = []
        project.status = .generating

        // 记录已成功落库的策略数：一旦 >0，即便后续步骤抛错，也说明「部分方案已存盘」，
        // 不能在 catch 里当成彻底失败把它们藏起来（对齐 Windows 侧「已生成却误报失败」的加固）。
        var persistedStrategyCount = 0

        do {
            let allSegments = project.videos.flatMap(\.segments)
            guard !allSegments.isEmpty else {
                errorMessage = "没有可用的分镜素材，请先导入并分析视频"
                project.status = .ready
                isGenerating = false
                return
            }

            // 构建分镜目录（全局唯一 ID + 表格格式）
            let catalog = buildSegmentCatalog(allSegments)
            let catalogText = catalog.catalogText
            let videoAliases = catalog.videoAliases
            // 批量组合那条路是按**别名**收回变体的，连贯性门要吃描述才判得了。
            // 来源键从"按视频摊开"那一步拿，不跨 `segment.video` 这条边（见 SegmentDescriptor.all）。
            let descriptorByID = Dictionary(uniqueKeysWithValues:
                project.videos.flatMap { video in
                    let key = "video:\(video.id.uuidString)"
                    return video.segments.map { SegmentDescriptor(from: $0, sourceKey: key) }
                }.map { ($0.id, $0) })
            var aliasToDescriptor: [String: SegmentDescriptor] = [:]
            for (alias, seg) in catalog.idMap {
                if let d = descriptorByID[seg.id] { aliasToDescriptor[alias] = d }
            }

            MixLog.info(" 分镜目录: \(catalog.idMap.count) 个片段, \(catalogText.count) 字符")

            let numStrategies = strategyCount(for: clampedTarget)
            let variationsPerStrategy = max(5, Int(ceil(Double(clampedTarget) / Double(numStrategies))))

            // Step 1: 生成策略
            generationProgress = "正在生成 \(numStrategies) 个方案策略..."
            let strategyResults = try await schemeService.generateStrategies(
                segments: allSegments,
                count: numStrategies,
                customPrompt: customPrompt
            )

            // Step 2: 所有策略并行生成组合
            generationProgress = "正在并行生成 \(strategyResults.count) 个策略的变体..."

            // 单个策略失败**不能静默吞掉**：以前只打一条 info 日志，用户只会发现"方案怎么变少了"，
            // 既不知道是哪个策略没生成，也不知道原因。这里把失败原因一并带回来，最后如实告知。
            struct StrategyOutcome {
                let index: Int
                let strategy: SchemeStrategy
                let compositions: [AICompactComposition]?
                let failure: String?
            }

            let outcomes: [StrategyOutcome] = await withTaskGroup(of: StrategyOutcome.self) { group in
                for (i, strategyResult) in strategyResults.enumerated() {
                    group.addTask { [schemeService, catalogText, videoAliases, aliasToDescriptor,
                                    variationsPerStrategy, customPrompt] in
                        do {
                            let compositions = try await schemeService.generateBatchCompositions(
                                strategy: strategyResult,
                                catalogText: catalogText,
                                videoAliases: videoAliases,
                                segmentByAlias: aliasToDescriptor,
                                variationCount: variationsPerStrategy,
                                customPrompt: customPrompt
                            )
                            return StrategyOutcome(index: i, strategy: strategyResult,
                                                   compositions: compositions, failure: nil)
                        } catch {
                            MixLog.error("策略「\(strategyResult.name)」生成失败: \(error)")
                            return StrategyOutcome(index: i, strategy: strategyResult, compositions: nil,
                                                   failure: FriendlyError.reason(for: error))
                        }
                    }
                }

                var results: [StrategyOutcome] = []
                var done = 0
                for await outcome in group {
                    results.append(outcome)
                    done += 1
                    let finished = done
                    await MainActor.run {
                        generationProgress = "已完成 \(finished)/\(strategyResults.count) 个策略..."
                    }
                }
                return results.sorted { $0.index < $1.index }
            }

            failedStrategies = outcomes.compactMap { o in
                o.failure.map { FailedStrategy(name: o.strategy.name, reason: $0) }
            }
            let allResults: [(Int, SchemeStrategy, [AICompactComposition])] = outcomes.compactMap { o in
                o.compositions.map { (o.index, o.strategy, $0) }
            }

            // 在主线程创建数据模型
            // 整批方案落库包成一组撤销：一次 ⌘Z 撤掉全部生成结果。
            // 此区段全程同步（AI 网络请求已在上方 await 完成），不跨 await，grouping 边界干净。
            // 用 defer 兜底 endUndoGrouping，避免中途 save 抛错导致 group 未闭合。
            let um = context.undoManager
            um?.beginUndoGrouping()
            um?.setActionName("生成方案")
            defer { um?.endUndoGrouping() }

            // 一个 composition = 一个方案(原分镜序列)。方案数有限、不再炸成变体视频；
            // 每个方案的「可生成变体组合数」只在详情页用一行字提示，导出仍是按选定组合的一条视频。
            for (i, strategyResult, compositions) in allResults {
                let strategy = MixStrategy(
                    name: strategyResult.name,
                    style: strategyResult.style,
                    description: strategyResult.description,
                    targetAudience: strategyResult.targetAudience,
                    narrativeStructure: strategyResult.narrativeStructure,
                    targetDuration: strategyResult.targetDuration
                )
                strategy.project = project
                context.insert(strategy)

                for (vi, comp) in compositions.enumerated() {
                    guard !comp.segments.isEmpty else { continue }
                    let matchedSegments = comp.segments.compactMap { catalog.idMap[$0] }
                    let totalDuration = matchedSegments.reduce(0.0) { $0 + $1.duration }

                    let scheme = MixScheme(
                        variationIndex: vi + 1,
                        schemeIndex: String(format: "scheme_%03d_%03d", i + 1, vi + 1),
                        name: comp.desc.isEmpty ? "\(strategyResult.name) #\(vi + 1)" : comp.desc,
                        style: strategyResult.style,
                        description: strategyResult.description,
                        targetAudience: strategyResult.targetAudience,
                        narrativeStructure: strategyResult.narrativeStructure
                    )
                    scheme.estimatedDuration = totalDuration
                    scheme.strategy = strategy
                    scheme.project = project
                    scheme.voiceMode = generationVoiceMode
                    scheme.unifiedVoiceId = generationUnifiedVoiceId
                    context.insert(scheme)

                    createSchemeSegments(segmentIDs: comp.segments, scheme: scheme,
                                         idMap: catalog.idMap, context: context)
                }

                try context.save()
                persistedStrategyCount += 1
                MixLog.info(" 策略「\(strategyResult.name)」: \(compositions.count) 个方案")
            }

            project.status = .completed
            project.updatedAt = Date()
            try context.save()

            loadSchemes(for: project)
            generationProgress = "生成完成：\(strategies.count) 个策略，共 \(schemes.count) 个方案"
            if failedStrategies.isEmpty {
                ToastCenter.shared.show("已生成 \(strategies.count) 个策略 · \(schemes.count) 个方案", icon: "sparkles", style: .success)
            } else {
                // 部分失败：说清楚成功几个、失败几个，失败明细在页面上的清单里
                ToastCenter.shared.show("已生成 \(schemes.count) 个方案，\(failedStrategies.count) 个策略未能生成",
                                        icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
            }
        } catch {
            // 已有策略成功落库 → 这是「部分成功后中断」，不能误报为彻底失败、也不能把已存盘的方案藏起来。
            if persistedStrategyCount > 0 {
                project.status = .completed
                project.updatedAt = Date()
                context.safeSave()
                loadSchemes(for: project)
                errorMessage = nil
                MixLog.info(" 方案已部分落库(\(persistedStrategyCount) 个策略)，但生成中途中断: \(error)")
                ToastCenter.shared.show("已生成 \(schemes.count) 个方案，但生成中途中断：\(error.localizedDescription)",
                                        icon: "exclamationmark.triangle.fill", style: .warning, duration: 4)
            } else {
                // ⚠️ 不要把 `String(describing: error)` 的枚举内存 dump 给用户看（那是日志的活）。
                errorMessage = "方案生成失败：\(FriendlyError.reason(for: error))"
                MixLog.error("方案生成失败原始错误: \(String(describing: error))")
                project.status = .ready
                context.safeSave()
            }
        }

        isGenerating = false
    }

    // MARK: - 分镜匹配（字典直接查找，单条视频用）

    /// 为单条方案创建有序 SchemeSegment，并取第一组合做配音分配（叙事模板/自定义方案用，不做变体展开）。
    private func createSchemeSegments(
        segmentIDs: [String],
        scheme: MixScheme,
        idMap: [String: Segment],
        context: ModelContext
    ) {
        let matched: [Segment] = segmentIDs.compactMap { idMap[$0] }
        if matched.count < segmentIDs.count {
            MixLog.info("[SV-09] 方案「\(scheme.name)」跳过未匹配分镜 \(segmentIDs.count - matched.count) 个")
        }
        // 默认全部播原声（selectedSegmentDubId = nil）；用户在分镜序列里按需手动切到克隆改写版。
        for (idx, seg) in matched.enumerated() {
            let ss = SchemeSegment(position: idx + 1, reasoning: "", positionReasoning: "")
            ss.scheme = scheme
            ss.segment = seg
            ss.selectedSegmentDubId = nil
            context.insert(ss)
        }
    }

    // MARK: - 删除

    /// 删除整个策略及其所有变体（延迟删除 + 撤销浮条）
    func deleteStrategy(_ strategy: MixStrategy) {
        guard modelContext != nil else { return }
        // P1-1：内存占位的「产品脚本成片」空组不在已加载 strategies 中（未落库），
        // 直接拒绝，禁止进入延迟删除/save 路径。
        guard strategies.contains(where: { $0 === strategy }) else { return }
        let id = strategy.id
        if selectedStrategy?.id == id {
            selectedStrategy = nil
            selectedScheme = nil
        }
        let idx = strategies.firstIndex { $0.id == id }
        strategies.removeAll { $0.id == id }   // 界面隐藏
        PendingDeletionCenter.shared.schedule(
            message: "已删除策略",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return GraphChange() }
                context.delete(strategy)
                context.safeSave()
                // 交回空台账 = 不广播：本 VM 的 `strategies` 已在 schedule 前摘掉这一项，
                // 而 `.strategy` 目前**没有第二双手**可剪（没登记进 `GraphEntity.prunable`，
                // 真记了反而会让每次删策略整页全量重载）。级联带走的 MixScheme/SchemeSegment 同理。
                // ⇒ 在册欠账见台账 §25「仍未闭合」第 1 条。
                return GraphChange()
            },
            undo: { [weak self] in
                guard let self else { return }
                if let idx, idx <= self.strategies.count { self.strategies.insert(strategy, at: idx) }
                else { self.strategies.append(strategy) }
            }
        )
    }

    /// 删除单个方案变体（延迟删除 + 撤销浮条）
    func deleteScheme(_ scheme: MixScheme) {
        guard modelContext != nil else { return }
        let schemeID = scheme.id
        let strategy = scheme.strategy
        if selectedScheme?.id == schemeID { selectedScheme = nil }
        // 界面隐藏：从内存关系摘除 + 重建数组触发刷新
        strategy?.schemes.removeAll { $0.id == schemeID }
        strategies = strategies.map { $0 }
        PendingDeletionCenter.shared.schedule(
            message: "已删除方案",
            commit: { [weak self] in
                guard let context = self?.modelContext else { return GraphChange() }
                // 脚本配音归属回收：仅在永久阶段（commit）执行——undo 只恢复界面关系、
                // 已删磁盘音频无法恢复。只删脚本族、被本方案绑定、且无其他存活方案引用的 dub。
                Self.reapScriptDubs(deleting: scheme, context: context)
                context.delete(scheme)
                context.safeSave()
                // 同 deleteStrategy：`strategies` 里的内存关系已在 schedule 前摘除，`.scheme` 尚无剪枝消费者
                return GraphChange()
            },
            undo: { [weak self] in
                guard let self else { return }
                strategy?.schemes.append(scheme)   // 放回关系
                self.strategies = self.strategies.map { $0 }
            }
        )
    }

    /// 脚本成片配音回收（删方案永久阶段）。
    /// 判据在 Core ScriptDubReap；这里只做模型→纯值投影与实际删除（记录+磁盘音频）。
    /// 跨边读取收口在本 VM（活 fetch + 标识符集合），不写 #Predicate 深链（G23）。
    private static func reapScriptDubs(deleting scheme: MixScheme, context: ModelContext) {
        let deletingBoundIDs = Set(scheme.schemeSegments.compactMap { $0.selectedSegmentDubId })
        guard !deletingBoundIDs.isEmpty else { return }

        // 其余存活方案仍绑定的全部 dub id（排除待删方案自身）。
        let allSchemes = (try? context.fetch(FetchDescriptor<MixScheme>())) ?? []
        let survivingBoundIDs = Set(
            allSchemes
                .filter { $0.id != scheme.id }
                .flatMap { $0.schemeSegments.compactMap { $0.selectedSegmentDubId } }
        )

        let dubs = (try? context.fetch(FetchDescriptor<SegmentDub>())) ?? []
        let candidates = dubs.filter {
            ScriptDubReap.scriptProvenanceRaws.contains($0.textProvenanceRaw)
        }
        let doomed = ScriptDubReap.reapableCandidates(
            provenanceScriptDubIDs: candidates.map(\.id),
            boundByDeletingSchemeIDs: deletingBoundIDs,
            referencedBySurvivingSchemeIDs: survivingBoundIDs)
        guard !doomed.isEmpty else { return }

        for id in doomed {
            guard let d = dubs.first(where: { $0.id == id }) else { continue }
            if let path = d.audioFilePath { try? FileManager.default.removeItem(atPath: path) }
            context.delete(d)
        }
        MixLog.info("[Scheme] 删除方案回收脚本配音 \(doomed.count) 条")
    }

    // MARK: - 分镜编辑

    /// 给 AI 方案打"已编辑"标记（自定义方案不打）
    private func markAsEdited(_ scheme: MixScheme) {
        let isCustom = scheme.strategy?.isCustomGroup == true
        guard !isCustom, !scheme.isManuallyEdited else { return }
        scheme.isManuallyEdited = true
    }

    /// 判断 segment 是否已在 scheme 中
    private func contains(_ segment: Segment, in scheme: MixScheme) -> Bool {
        let targetID = segment.id
        return scheme.schemeSegments.contains { $0.segment?.id == targetID }
    }

    /// 按当前 orderedSegments 顺序重新编号 position（1-based）
    private func renumberPositions(in scheme: MixScheme) {
        for (i, seg) in scheme.orderedSegments.enumerated() {
            seg.position = i + 1
        }
    }

    func moveSegment(in scheme: MixScheme, from source: Int, to destination: Int) {
        var ordered = scheme.orderedSegments
        guard source >= 0, source < ordered.count,
              destination >= 0, destination <= ordered.count else { return }

        modelContext?.undoManager?.setActionName("调整顺序")
        let moved = ordered.remove(at: source)
        let adjustedDest = destination > source ? destination - 1 : destination
        ordered.insert(moved, at: adjustedDest)

        for (i, seg) in ordered.enumerated() {
            seg.position = i + 1
        }

        markAsEdited(scheme)
        modelContext?.safeSave()
    }

    @discardableResult
    func removeSegment(_ schemeSeg: SchemeSegment, from scheme: MixScheme) -> Bool {
        guard let context = modelContext else { return false }
        guard scheme.schemeSegments.count > 1 else {
            ToastCenter.shared.show("方案至少保留 1 个分镜", icon: "exclamationmark.circle.fill")
            return false
        }

        context.undoManager?.setActionName("移除分镜")
        let deletedID = schemeSeg.id
        context.delete(schemeSeg)

        let remaining = scheme.orderedSegments.filter { $0.id != deletedID }
        for (i, seg) in remaining.enumerated() {
            seg.position = i + 1
        }

        markAsEdited(scheme)
        context.safeSave()
        return true
    }

    /// 在指定 position 处插入一个分镜（position 从 1 开始；position = N+1 表示追加到末尾）
    /// 返回 false 表示 segment 已在方案中（重复阻止）
    @discardableResult
    func insertSegment(_ segment: Segment, at position: Int, in scheme: MixScheme) -> Bool {
        guard let context = modelContext else { return false }

        if contains(segment, in: scheme) {
            ToastCenter.shared.show("该分镜已在方案中", icon: "exclamationmark.circle.fill")
            return false
        }

        context.undoManager?.setActionName("插入分镜")
        // 现有分镜在 position 及之后的全部后移一位
        for seg in scheme.orderedSegments where seg.position >= position {
            seg.position += 1
        }

        let newSchemeSeg = SchemeSegment(position: position)
        newSchemeSeg.segment = segment
        newSchemeSeg.scheme = scheme
        scheme.schemeSegments.append(newSchemeSeg)
        context.insert(newSchemeSeg)

        renumberPositions(in: scheme)
        markAsEdited(scheme)
        context.safeSave()
        return true
    }

    /// 替换某个 SchemeSegment 指向的具体 Segment
    /// 返回 false 表示新 segment 已在方案中（重复阻止）
    @discardableResult
    func replaceSegment(_ schemeSeg: SchemeSegment, with newSegment: Segment, in scheme: MixScheme) -> Bool {
        guard let context = modelContext else { return false }

        // 如果替换的是同一个，无需处理
        if schemeSeg.segment?.id == newSegment.id { return true }

        if contains(newSegment, in: scheme) {
            ToastCenter.shared.show("该分镜已在方案中", icon: "exclamationmark.circle.fill")
            return false
        }

        schemeSeg.segment = newSegment
        markAsEdited(scheme)
        context.safeSave()
        return true
    }

    // MARK: - 自定义叙事结构

    /// 当前项目库内"真实有分镜"的标签集合（供编辑器只列可选标签）
    func availableTags(in project: Project) -> [SemanticType] {
        let present = Set(project.videos.flatMap { $0.segments }.flatMap { $0.semanticTypes })
        return SemanticType.allCases.filter { present.contains($0) }
    }

    /// 新建一个空的叙事结构（isNarrativeTemplate strategy），返回它供编辑器编辑
    @discardableResult
    func createNarrativeStructure(in project: Project) -> MixStrategy {
        let strategy = MixStrategy(
            name: "新建叙事结构",
            style: "",
            description: "用户自定义叙事结构",
            targetAudience: "",
            narrativeStructure: "",
            targetDuration: 0
        )
        strategy.isNarrativeTemplate = true
        strategy.project = project
        project.strategies.append(strategy)
        modelContext?.insert(strategy)
        modelContext?.safeSave()
        loadSchemes(for: project)
        return strategy
    }

    /// 保存段位 + 重算 name
    func updateSlots(_ slots: [NarrativeSlot], for strategy: MixStrategy) {
        strategy.narrativeSlots = slots
        let name = NarrativeStructureEngine.structureName(for: slots)
        strategy.name = name.isEmpty ? "新建叙事结构" : name
        modelContext?.safeSave()
    }

    /// 中文序号（变体一/二/三…）
    private func chineseOrdinal(_ n: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if n <= 0 { return "零" }
        if n < 10 { return digits[n] }
        if n < 20 { return n == 10 ? "十" : "十" + digits[n % 10] }
        if n < 100 {
            let tens = n / 10
            let ones = n % 10
            return digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
        }
        return "\(n)"
    }

    /// 生成：组织 SegmentDescriptor/池/目录 → 调 service → 把通过的变体落成 MixScheme（命名"变体一/二…"）
    /// 生成叙事结构变体。
    ///
    /// 返回是否**真的生成出了方案**。以前返回 Void，且多条失败路径只弹 Toast 不设 errorMessage，
    /// 调用方靠 `errorMessage == nil` 判断成败 → 失败时编辑器照样关闭，
    /// 用户以为生成成功了，回到列表却一条新方案都没有。
    @discardableResult
    func generateNarrativeVariants(for strategy: MixStrategy, in project: Project, requested: Int) async -> Bool {
        guard let context = modelContext else { return false }

        let slots = strategy.narrativeSlots.sorted { $0.order < $1.order }
        guard !slots.isEmpty else {
            ToastCenter.shared.show("请先为叙事结构配置段位标签", icon: "exclamationmark.circle.fill")
            return false
        }

        isNarrativeGenerating = true
        errorMessage = nil

        defer { isNarrativeGenerating = false }

        // 1. 把项目下所有 Segment 映射为 SegmentDescriptor + 别名映射（沿用 V{n}_{nn} 规则）
        let allSegments = project.videos.flatMap(\.segments)
        guard !allSegments.isEmpty else {
            ToastCenter.shared.show("没有可用的分镜素材，请先导入并分析视频", icon: "exclamationmark.circle.fill")
            return false
        }

        let catalog = buildSegmentCatalog(allSegments)
        // alias → Segment（来自 catalog.idMap），反推 Segment.id → alias
        var idToAlias: [UUID: String] = [:]
        for (alias, seg) in catalog.idMap {
            idToAlias[seg.id] = alias
        }

        let descriptors: [SegmentDescriptor] = project.videos.flatMap { video in
            let key = "video:\(video.id.uuidString)"
            return video.segments.map { SegmentDescriptor(from: $0, sourceKey: key) }
        }

        // 2. 每段 candidatePool → topCandidates(30)，渲染每段目录文本
        var pools: [[SegmentDescriptor]] = []
        var catalogBySlot: [String] = []
        for slot in slots {
            let pool = NarrativeStructureEngine.topCandidates(
                NarrativeStructureEngine.candidatePool(for: slot, in: descriptors),
                limit: 30
            )
            pools.append(pool)
            let lines = pool.map { d -> String in
                let alias = idToAlias[d.id] ?? d.id.uuidString
                return "\(alias)|\(String(format: "%.1f", d.duration))s|\(d.text)"
            }.joined(separator: "\n")
            catalogBySlot.append(lines.isEmpty ? "（无候选）" : lines)
        }

        // 任一段候选为 0 → 中止
        if let emptyIdx = pools.firstIndex(where: { $0.isEmpty }) {
            ToastCenter.shared.show("第 \(emptyIdx + 1) 段没有匹配的分镜，请调整该段标签或补充素材",
                                    icon: "exclamationmark.triangle.fill")
            return false
        }

        // 3. 调 service 生成合法变体
        let variants: [[String]]
        do {
            variants = try await schemeService.generateNarrativeVariants(
                slots: slots,
                pools: pools,
                idAliasMap: idToAlias,
                catalogBySlot: catalogBySlot,
                requested: requested
            )
        } catch {
            errorMessage = "叙事结构变体生成失败：\(FriendlyError.reason(for: error))"
            ToastCenter.shared.show("生成失败，详情见编辑器内提示", icon: "exclamationmark.triangle.fill")
            return false
        }

        guard !variants.isEmpty else {
            errorMessage = "AI 没能排出符合这个叙事结构的组合。通常是某些段位的候选分镜太少、或标签限制太严。建议放宽段位标签、增加素材，或减少要生成的方案数量后重试。"
            ToastCenter.shared.show("未生成连贯变体", icon: "exclamationmark.triangle.fill")
            return false
        }

        // 4. 把通过的变体逐个落成 MixScheme（复用现有 SchemeSegment 建法）
        // 整批变体落库包成一组撤销：一次 ⌘Z 撤掉全部生成结果。此区段全程同步、不跨 await。
        let um = context.undoManager
        um?.beginUndoGrouping()
        um?.setActionName("生成方案")
        let existingCount = strategy.schemes.count
        for (vi, aliasSeq) in variants.enumerated() {
            let index = existingCount + vi + 1
            let scheme = MixScheme(
                variationIndex: index,
                schemeIndex: "narrative_\(UUID().uuidString.prefix(8))",
                name: "变体" + chineseOrdinal(index),
                style: strategy.style,
                description: strategy.strategyDescription,
                targetAudience: strategy.targetAudience,
                narrativeStructure: strategy.name
            )
            // 估算时长
            let matched = aliasSeq.compactMap { catalog.idMap[$0] }
            scheme.estimatedDuration = matched.reduce(0.0) { $0 + $1.duration }
            scheme.strategy = strategy
            scheme.project = project
            scheme.voiceMode = generationVoiceMode
            scheme.unifiedVoiceId = generationUnifiedVoiceId
            strategy.schemes.append(scheme)
            context.insert(scheme)

            createSchemeSegments(
                segmentIDs: aliasSeq,
                scheme: scheme,
                idMap: catalog.idMap,
                context: context
            )
        }

        um?.endUndoGrouping()
        context.safeSave()
        loadSchemes(for: project)
        selectedStrategy = strategy
        selectedScheme = strategy.orderedSchemes.first
        ToastCenter.shared.show("已生成 \(variants.count) 个变体", icon: "sparkles", style: .success)
        return true
    }

    // MARK: - 自定义方案创建

    /// 从分镜数组创建自定义方案（异步：先建占位，AI 反推后填充元信息）
    /// 失败兜底：name 保留默认「自定义 #N」，banner 提示用户
    @discardableResult
    func createCustomScheme(
        from segments: [Segment],
        in project: Project
    ) async -> MixScheme? {
        // 失败路径必须带原因：调用方要据此给用户可读的提示，不能静默返回 nil。
        guard let context = modelContext else {
            errorMessage = "数据存储未就绪，请重启应用后重试"
            return nil
        }
        guard !segments.isEmpty else {
            errorMessage = "没有选中任何分镜，无法组合为方案"
            return nil
        }
        errorMessage = nil

        // 确保 customGroup 存在（理论上一定有，双保险）
        let group: MixStrategy
        if let existing = project.strategies.first(where: { $0.isCustomGroup }) {
            group = existing
        } else {
            let g = MixStrategy(
                name: "自定义组合",
                style: "",
                description: "手动挑选分镜组合的方案",
                targetAudience: "",
                narrativeStructure: "",
                targetDuration: 0
            )
            g.isCustomGroup = true
            g.project = project
            project.strategies.append(g)
            context.insert(g)
            group = g
        }

        // 计算自定义方案序号
        let existingCustomCount = group.schemes.count
        let defaultName = "自定义 #\(existingCustomCount + 1)"

        // 创建方案
        let scheme = MixScheme(
            variationIndex: existingCustomCount + 1,
            schemeIndex: "custom_\(UUID().uuidString.prefix(8))",
            name: defaultName,
            style: "",
            description: "",
            targetAudience: "",
            narrativeStructure: ""
        )
        scheme.strategy = group
        scheme.project = project
        group.schemes.append(scheme)
        context.insert(scheme)

        // 创建 SchemeSegment 链接
        for (idx, seg) in segments.enumerated() {
            let ss = SchemeSegment(position: idx + 1)
            ss.segment = seg
            ss.scheme = scheme
            scheme.schemeSegments.append(ss)
            context.insert(ss)
        }

        context.safeSave()

        // AI 反推（失败不阻断）
        if let metadata = await schemeService.inferMetadata(for: segments) {
            scheme.name = metadata.name.isEmpty ? defaultName : metadata.name
            scheme.narrativeStructure = metadata.narrativeStructure
            scheme.targetAudience = metadata.targetAudience
            scheme.schemeDescription = metadata.schemeDescription
            scheme.style = metadata.style
            context.safeSave()
        } else {
            ToastCenter.shared.show("元信息生成失败，方案已保存为「\(defaultName)」",
                                    icon: "exclamationmark.triangle.fill")
        }

        // 重新加载策略以触发 UI 更新
        loadSchemes(for: project)
        selectedStrategy = group
        selectedScheme = scheme

        return scheme
    }
}
