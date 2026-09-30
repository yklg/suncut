import SwiftUI
import SwiftData
import SQLite3
import AppKit

/// 观察 NSUndoManager 状态变化，把 canUndo/canRedo/标题暴露为 @Observable 属性，
/// 让 SwiftUI 编辑菜单能实时刷新（SwiftUI 本身不观察 NSUndoManager）。
@Observable
final class UndoUIState {
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoTitle = "撤销"
    private(set) var redoTitle = "重做"

    @ObservationIgnored private let undoManager: UndoManager
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init(_ undoManager: UndoManager) {
        self.undoManager = undoManager
        refresh()
        // .NSUndoManagerCheckpoint 在每次注册/撤销/重做后都会发，覆盖最广；其余几个补足分组与撤销/重做时机
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerWillCloseUndoGroup,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: undoManager, queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            tokens.append(token)
        }
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func refresh() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        let u = undoManager.undoActionName
        let r = undoManager.redoActionName
        undoTitle = u.isEmpty ? "撤销" : "撤销 " + u
        redoTitle = r.isEmpty ? "重做" : "重做 " + r
    }
}

@main
struct MixCutApp: App {

    let modelContainer: ModelContainer
    private let initError: String?

    /// 全局撤销管理器：挂到 mainContext 后，SwiftData 自动登记增删改。
    /// 单一全局撤销栈（全 App 共享），levelsOfUndo = 0 不限层数。
    let appUndoManager: UndoManager

    /// 观察 NSUndoManager 通知，驱动编辑菜单撤销/重做的启用态与标题实时刷新。
    /// SwiftUI 不观察 NSUndoManager，若直接读 appUndoManager.canUndo，菜单是陈旧值 →
    /// 刚操作完按 ⌘Z 会因菜单项仍处禁用态而无效。用 @Observable 中转即可实时刷新。
    @State private var undoState: UndoUIState

    init() {
        // 撤销管理器 + 其 UI 观察状态（必须最先初始化所有存储属性）
        let undoMgr = UndoManager()
        undoMgr.levelsOfUndo = 0
        appUndoManager = undoMgr
        _undoState = State(initialValue: UndoUIState(undoMgr))

        // 换 bundle id 之后新域是空的：先把旧域整域搬过来，再开库、再读任何设置。
        Self.importSettingsFromLegacyDomain()
        // 目录迁移必须赶在 ModelContainer 打开库文件之前完成（库本体也在被搬的目录里）。
        FileHelper.migrateToBrandDirectoryIfNeeded()

        // 强制浅色外观（AppKit + SwiftUI 同时生效）
        // 用 NSAppearance 设置而非 SwiftUI 的 .preferredColorScheme，
        // 后者只影响 SwiftUI 颜色环境，AppKit 嵌入的 NSTextField 仍读 system effectiveAppearance
        // 导致 NSColor.labelColor 在系统深色下返回白色，文字在浅色背景上完全不可见。
        DispatchQueue.main.async {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }

        let schema = Schema(versionedSchema: AppSchemaV1.self)
        let storeURL = FileHelper.mixCutStoreURL
        // 一次性迁移：旧版用共享的 default.store（会被其它非沙盒 App 清库），现改用专属库。
        // 仅当旧库确实是本 app 的数据时才搬迁 —— 必须赶在开库之前。
        Self.migrateDefaultStoreToDedicated()

        // 开库必须走 SchemaGuard：门（指纹比对 + 变更分类）→ 改前备份 → 才建 ModelContainer。
        // 三种结果分开处理，尤其**不**把"门拦住"与"库坏了"合并回同一条 catch —— 既有 catch 的文案
        // 会叫用户删库，被这道防线拦下的那次启动若复用它，等于教用户删掉它正保护的库。
        let openedContainer: ModelContainer
        switch SchemaGuard.openStore(schema: schema, storeURL: storeURL) {
        case .opened(let onDisk):
            openedContainer = onDisk
            initError = nil
        case .degradedInMemory(let inMemory, let message):
            // 真·库损坏：沿用内存模式降级，但不跑下面任何迁移 / GC / MCP —— 与改造前 catch 分支一致。
            initError = message
            modelContainer = inMemory
            return
        case .refusedBySchemaGate(let message):
            // 被门拦住：内存占位容器只为把错误面板画出来。下面所有步骤一律不跑 ——
            // 这是"你的数据没有被动过"这句话为真的前提。
            initError = message
            modelContainer = SchemaGuard.placeholderContainer(schema: schema)
            return
        }
        modelContainer = openedContainer

        do {
            // 19 颗一次性 fixup / 自愈 / GC 的顺序与前序约束，全在 `LaunchSteps.swift` 的清单里。
            // 这里不再平铺调用 —— 平铺时"谁必须在谁后面"只写在注释里靠人记，
            // 而删文件的孤儿 GC 恰好挂在会写坏成功键的那颗后面（数据丢失级）。
            LaunchPlan.run(container: modelContainer)

            // ⚠️ 不挂 SwiftData 内置 UndoManager：实测在本数据模型上，挂 undoManager 后
            // context.delete(...) 会同步触发 SwiftData 内部 _assertionFailure 崩溃（删 SchemeSegment
            // 时必崩，EXC_BREAKPOINT）。已知坑，关 autosave 也无效。撤销改用其它方案，详见下方说明。
            // appUndoManager 暂保留但不挂 context（菜单/快捷键因此为禁用态、不会误触发）。

            // Agent 接入：内嵌 MCP server（仅 127.0.0.1，可在设置中关闭）
            // —— 这两颗不是 fixup，是运行时接线，故意不进清单：清单作废时界面仍要能用 MCP 排查。
            AgentGateway.shared.configure(container: modelContainer)
            #if DEBUG
            DebugSelfTest.runIfRequested(container: modelContainer)
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            if let errorMsg = initError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("数据库异常")
                        .font(.title2.bold())
                    Text(errorMsg)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("复制错误信息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(errorMsg, forType: .string)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ContentView()
            }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(undoState.undoTitle) { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!undoState.canUndo)
                Button(undoState.redoTitle) { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!undoState.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建项目") {
                    NotificationCenter.default.post(name: .mixCutNewProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("项目概览") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.overview)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button("素材导入") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.importMedia)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button("分镜素材库") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.segmentLibrary)
                }
                .keyboardShortcut("3", modifiers: .command)
                Button("混剪方案") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.schemes)
                }
                .keyboardShortcut("4", modifiers: .command)
                Button("导出") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.export)
                }
                .keyboardShortcut("5", modifiers: .command)
                Button("BGM 库") {
                    NotificationCenter.default.post(name: .mixCutNavigate, object: NavigationItem.bgmLibrary)
                }
                .keyboardShortcut("6", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - 撤销 / 重做

    /// 执行撤销：回滚 → 落盘 → 通知当前视图重载
    private func performUndo() {
        guard appUndoManager.canUndo else { return }
        appUndoManager.undo()
        try? modelContainer.mainContext.save()
        NotificationCenter.default.post(name: .mixCutDataDidUndo, object: nil)
    }

    /// 执行重做：重放 → 落盘 → 通知当前视图重载
    private func performRedo() {
        guard appUndoManager.canRedo else { return }
        appUndoManager.redo()
        try? modelContainer.mainContext.save()
        NotificationCenter.default.post(name: .mixCutDataDidUndo, object: nil)
    }

    // MARK: - 数据修复

    /// 自建分镜标记自愈（每次启动执行，幂等）。
    /// 背景（2026-07-28 实际案例）：误启动旧版 App（schema 无 isUserUploaded 字段）时，
    /// Core Data 降级迁移会把该列删除；新版再启动重建列，所有行归零——自建分镜载体
    /// 因此丢失标记，混入素材导入页/成片列表。恢复分两路：
    /// 1) 注册表恢复：创建时记录在 UserDefaults 的载体 id（ImportViewModel.registerSelfBuiltVideo）
    /// 2) 特征回填：注册表诞生前已受损的行，用自建分镜独有特征识别——
    ///    仅 1 个分镜且覆盖整片、无整片 ASR 句子数据、分镜缩略图与视频缩略图同一路径、时长不超上限
    /// 局限：只兜「列值归零」；若整表被清、由 recoverFromDisk 从磁盘重建 Video（全新 UUID、无分镜），
    /// 注册表与特征均无法匹配，该场景不在本函数兜底范围内。
    @MainActor
    static func restoreSelfBuiltFlags(container: ModelContainer) {
        let ctx = container.mainContext
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else { return }

        let registered = Set(UserDefaults.standard.stringArray(forKey: ImportViewModel.selfBuiltRegistryKey) ?? [])
        var restored = 0

        for video in videos where !video.isUserUploaded {
            let byRegistry = registered.contains(video.id.uuidString)
            let byShape = video.segments.count == 1
                && video.asrSentencesData == nil
                && video.duration > 0
                && video.duration <= ImportViewModel.selfSegmentMaxDuration + 1
                && video.segments.first.map { seg in
                    seg.startTime < 0.01
                        && abs(seg.endTime - video.duration) < 0.2
                        && seg.thumbnailPath != nil
                        && seg.thumbnailPath == video.thumbnailPath
                } == true
            if byRegistry || byShape {
                video.isUserUploaded = true
                ImportViewModel.registerSelfBuiltVideo(video.id)   // 特征回填的也补进注册表
                restored += 1
            }
        }

        if restored > 0 {
            try? ctx.save()
            MixLog.info(" 已恢复 \(restored) 个自建分镜载体的 isUserUploaded 标记")
        }

        // 清理注册表中已不存在的视频 id（自建分镜被删除后的残留）
        let liveIDs = Set(videos.map { $0.id.uuidString })
        let current = UserDefaults.standard.stringArray(forKey: ImportViewModel.selfBuiltRegistryKey) ?? []
        let pruned = current.filter(liveIDs.contains)
        if pruned.count != current.count {
            UserDefaults.standard.set(pruned, forKey: ImportViewModel.selfBuiltRegistryKey)
        }
    }

    /// 为 semanticTypesData 为 NULL 的分镜填充默认值「过渡」
    /// 用户后续可通过"重新 AI 分析"获取正确的语义类型
    @MainActor
    static func fixMissingSemanticTypes(container: ModelContainer) {
        // 避免每次启动都执行 SQL 查询
        let fixKey = "didFixMissingSemanticTypes_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        guard let storeURL = container.configurations.first?.url else { return }

        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // 统计需要修复的行数
        var countStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM ZSEGMENT WHERE ZSEMANTICTYPESDATA IS NULL", -1, &countStmt, nil)
        var nullCount: Int32 = 0
        if sqlite3_step(countStmt) == SQLITE_ROW {
            nullCount = sqlite3_column_int(countStmt, 0)
        }
        sqlite3_finalize(countStmt)

        guard nullCount > 0 else {
            // 没有要修的行也是"这颗已经完成"，必须记账：以前这里直接 return，
            // 于是 `didFixMissingSemanticTypes_v1` 在现网从来没被写过，
            // 每次启动都要重跑一遍 SQL 统计 —— 正好违背函数开头那句"避免每次启动都执行 SQL 查询"。
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        // 编码默认值 ["过渡"]
        guard let defaultData = try? JSONEncoder().encode([SemanticType.transition]) else { return }

        let updateSQL = "UPDATE ZSEGMENT SET ZSEMANTICTYPESDATA = ? WHERE ZSEMANTICTYPESDATA IS NULL"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }

        _ = defaultData.withUnsafeBytes { buffer in
            sqlite3_bind_blob(updateStmt, 1, buffer.baseAddress, Int32(defaultData.count), nil)
        }

        if sqlite3_step(updateStmt) == SQLITE_DONE {
            let affected = sqlite3_changes(db)
            MixLog.info(" 已为 \(affected) 个分镜填充默认语义类型「过渡」，请对相关视频执行「重新 AI 分析」获取正确类型")
        }
        sqlite3_finalize(updateStmt)

        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// CosyVoice 迁移：删除 voiceId 非 CosyVoice 目录的旧配音变体（qwen Cherry/Ethan… 会被引擎拒绝报 418），
    /// 并把各视频已选音色里非法的 id 清掉。一次性执行，用户随后重选 CosyVoice 音色 + 重跑一键改写。
    ///
    /// - Returns: 这次有没有把改动**落库**。以前两趟 `if let … = try? fetch` 读失败就当"没有要清的"，
    ///   `try? ctx.save()` 吞掉存盘失败，最后仍无条件写成功键 —— 于是旧配音永久留在库里，
    ///   而用户每次重跑一键改写都会撞上那颗 418。失败现在不记账，下次启动重试。
    @discardableResult
    static func purgeLegacyQwenDubs(container: ModelContainer) -> Bool {
        let key = "didPurgeLegacyQwenDubs_v1"
        if UserDefaults.standard.bool(forKey: key) { return true }

        let ctx = ModelContext(container)
        let validIds = Set(CosyVoiceCatalog.all.map(\.id))

        guard let dubs = try? ctx.fetch(FetchDescriptor<SegmentDub>()) else {
            MixLog.error(" CosyVoice 迁移：读 SegmentDub 失败，本次不记成功键")
            return false
        }
        var removedDubs = 0
        for d in dubs where !validIds.contains(d.voiceId) {
            ctx.delete(d)
            removedDubs += 1
        }

        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else {
            MixLog.error(" CosyVoice 迁移：读 Video 失败，本次不记成功键")
            return false
        }
        var cleanedVideos = 0
        for v in videos {
            let filtered = v.selectedVoiceIds.filter { validIds.contains($0) }
            if filtered.count != v.selectedVoiceIds.count {
                v.selectedVoiceIds = filtered
                cleanedVideos += 1
            }
        }

        if (removedDubs > 0 || cleanedVideos > 0) && !ctx.safeSave() {
            MixLog.error(" CosyVoice 迁移：落库失败，本次不记成功键")
            return false
        }
        if removedDubs > 0 || cleanedVideos > 0 {
            MixLog.info(" CosyVoice 迁移：清理 \(removedDubs) 个旧 qwen 配音变体，重置 \(cleanedVideos) 个视频的非法音色选择")
        }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    /// 一次性迁移：清空用「18s 长参考」克隆出的旧音色。长参考含多句原话，会让 qwen 克隆 TTS
    /// 间歇性"续读参考内容"导致配音混进下一段（实测 18s→clean 1/3，6s→clean 5/5）。
    /// 清空后，用户下次「一键改写」会用 6s 短参考重新克隆。
    @discardableResult
    static func purgeLongRefClones(container: ModelContainer) -> Bool {
        let key = "didPurgeLongRefClones_v1"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let ctx = ModelContext(container)
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else {
            MixLog.error(" 长参考音色清理：读 Video 失败，本次不记成功键")
            return false
        }
        var cleared = 0
        for v in videos where (v.clonedVoiceId ?? "").isEmpty == false {
            v.clonedVoiceId = nil
            v.selectedVoiceIds = []
            cleared += 1
        }
        if cleared > 0 && !ctx.safeSave() {
            MixLog.error(" 长参考音色清理：落库失败，本次不记成功键")
            return false
        }
        if cleared > 0 {
            MixLog.info(" 已清空 \(cleared) 个旧长参考克隆音色，下次一键改写将用 6s 短参考重克隆")
        }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    /// 一次性迁移：把所有方案分镜的配音选择重置为原声（selectedSegmentDubId = nil）。
    /// 旧逻辑创建方案时默认预选了「改写A」，与「默认播原声、用户手动切」的产品意图不符。
    /// 重置后用户在分镜序列下拉里按需切换克隆改写版，之后的选择不会再被重置。
    @discardableResult
    static func resetSchemeDubSelectionToOriginal(container: ModelContainer) -> Bool {
        let key = "didResetSchemeDubSelection_v1"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let ctx = ModelContext(container)
        guard let segs = try? ctx.fetch(FetchDescriptor<SchemeSegment>()) else {
            MixLog.error(" 方案配音重置：读 SchemeSegment 失败，本次不记成功键")
            return false
        }
        var reset = 0
        for ss in segs where ss.selectedSegmentDubId != nil {
            ss.selectedSegmentDubId = nil
            reset += 1
        }
        if reset > 0 && !ctx.safeSave() {
            MixLog.error(" 方案配音重置：落库失败，本次不记成功键")
            return false
        }
        if reset > 0 {
            MixLog.info(" 已把 \(reset) 个方案分镜的配音选择重置为原声（默认原声）")
        }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    /// 一次性迁移：清掉「同一项目内同一视频挂了两份」的历史重复关联行。
    ///
    /// 肇因是旧导入逻辑只对"视频记录是否已存在"去重、不对"本项目是否已关联"去重，
    /// 导入两个内容相同、文件名不同的素材就会多出一行 —— 分镜素材库因此 SIGTRAP，
    /// 概览计数与 video_no 也会把同一素材算两次。
    ///
    /// ⚠️ 只删 ProjectVideo 关联行：绝不删 Video / Segment / 磁盘文件，
    ///    且每个 (project, video) 必定保留一条（规则与断言在 MixCutCore.ProjectVideoDedup）。
    ///    归零会让孤儿 GC 把用户的 .mp4 连带收走。
    /// ⚠️ 必须用 mainContext：子上下文里删行，已 faulting 出来的 project.projectVideos
    ///    不会同步移除，会变成"库里清了、界面没清"。
    @discardableResult
    static func dedupProjectVideoAssociations(container: ModelContainer) -> Bool {
        let key = "didDedupProjectVideoAssociations_v1"
        if UserDefaults.standard.bool(forKey: key) { return true }

        let context = container.mainContext
        guard let rows = try? context.fetch(FetchDescriptor<ProjectVideo>()) else {
            MixLog.error(" 关联去重：读取 ProjectVideo 失败，本次跳过")
            return false
        }
        let outcome = ProjectVideoDedup.deduplicate(rows.map {
            ProjectVideoAssociation(pvID: $0.id, projectID: $0.project?.id,
                                    videoID: $0.video?.id, addedAt: $0.addedAt)
        })
        let toDelete = rows.filter { outcome.deleted.contains($0.id) }
        for pv in toDelete { context.delete(pv) }
        if !toDelete.isEmpty {
            guard context.safeSave() else {
                MixLog.error(" 关联去重：删除未落库，本次不记成功键（下次启动重跑）")
                return false
            }
            MixLog.info(" 关联去重：删除 \(toDelete.count) 条重复的项目↔视频关联（视频、分镜、磁盘文件均未改动）")
        }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    /// 帧化迁移：现有分镜以秒存边界，按各自视频 fps 回填帧号（startFrame/endFrame）。
    /// 一次性执行；之后新建分镜直接走帧化创建。endFrame==0 视为未帧化。
    ///
    /// - Returns: 是否**回填完并落库**。以前 `try? save()` 吞掉落库失败照样写成功键，
    ///   而"所属视频缺有效 fps"被跳过的分镜也会随那颗键一起被永久放弃 —— 边界停在秒制上，
    ///   逐帧功能对这些分镜就是静默失效。现在这两种情况都不记账，下次启动重试。
    @discardableResult
    static func backfillSegmentFrames(container: ModelContainer) -> Bool {
        let fixKey = "didBackfillSegmentFrames_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return true }

        let context = container.mainContext
        guard let segments = try? context.fetch(FetchDescriptor<Segment>()) else {
            MixLog.error(" 帧化迁移：读 Segment 失败，本次不记成功键")
            return false
        }

        var fixed = 0
        var blocked = 0
        for seg in segments {
            if seg.endFrame != 0 { continue }   // 已帧化
            guard let fps = seg.video?.fps, fps > 0 else {
                blocked += 1
                continue
            }
            seg.backfillFramesFromSeconds()
            fixed += 1
        }
        if fixed > 0 && !context.safeSave() {
            MixLog.error(" 帧化迁移：落库失败，本次不记成功键")
            return false
        }
        if fixed > 0 {
            MixLog.info(" 帧化迁移：已为 \(fixed) 个分镜回填帧号")
        }
        if blocked > 0 {
            MixLog.error(" 帧化迁移：\(blocked) 个分镜因所属视频缺有效 fps 无法回填，本次不记成功键（下次启动重试）")
            return false
        }
        UserDefaults.standard.set(true, forKey: fixKey)
        return true
    }

    /// 清洗已有分镜台词中的乱码（U+FFFD）和多余空格
    /// 同时清洗 Video.transcript 和 ASR 数据
    @discardableResult
    static func cleanExistingTranscripts(container: ModelContainer) -> Bool {
        let fixKey = "didCleanTranscripts_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return true }

        let context = container.mainContext

        // 清洗 Segment.text
        let segDescriptor = FetchDescriptor<Segment>()
        guard let segments = try? context.fetch(segDescriptor) else {
            MixLog.error(" 台词清洗：读 Segment 失败，本次不记成功键")
            return false
        }
        var fixedCount = 0
        for seg in segments {
            let original = seg.text
            let cleaned = cleanText(original)
            if cleaned != original {
                // 清洗只在内容真变时落笔，并把来源记成 cleaned（红线 R8）。
                // 计数器跟 `shouldWrite` 走，不跟"我提交了什么"走。
                if seg.setText(cleaned, source: .cleaned).shouldWrite {
                    fixedCount += 1
                }
            }
        }
        if fixedCount > 0 {
            MixLog.info(" 已清洗 \(fixedCount) 个分镜的台词乱码")
        }

        // 清洗 Video.transcript
        let videoDescriptor = FetchDescriptor<Video>()
        guard let videos = try? context.fetch(videoDescriptor) else {
            MixLog.error(" 台词清洗：读 Video 失败，本次不记成功键")
            return false
        }
        for video in videos {
            if let transcript = video.transcript {
                let cleaned = cleanText(transcript)
                if cleaned != transcript {
                    video.transcript = cleaned
                }
            }
            // 清洗 ASR sentences
            var sentences = video.asrSentences
            var sentencesChanged = false
            for i in sentences.indices {
                let cleaned = cleanText(sentences[i].text)
                if cleaned != sentences[i].text {
                    sentences[i].text = cleaned
                    sentencesChanged = true
                }
            }
            if sentencesChanged {
                video.asrSentences = sentences
            }
        }

        guard context.safeSave() else {
            MixLog.error(" 台词清洗：落库失败，本次不记成功键")
            return false
        }
        UserDefaults.standard.set(true, forKey: fixKey)
        return true
    }

    /// 清洗文本：移除 U+FFFD 乱码、合并连续空格
    private static func cleanText(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\u{FFFD}", with: "")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 迁移旧版数据：为没有 ProjectVideo 关联的 Video 创建关联
    /// 旧版 Video 通过 SQLite 直接查 ZPROJECT 外键找到所属项目
    ///
    /// - Returns: 关联是否**真的建好并落库**。以前四条失败路（读表失败 / 取不到库路径 /
    ///   打不开 SQLite / `try? save()` 吞错）**都会写成功键** —— 于是这批 Video 永远没有
    ///   `projectVideos`，既在项目列表里看不见，也再没有第二次机会补上。
    ///   失败现在返回 `false` 且**不写键**，下次启动重试。
    @discardableResult
    static func migrateToProjectVideoRelation(container: ModelContainer) -> Bool {
        let fixKey = "didMigrateProjectVideo_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return true }

        let context = container.mainContext

        // 查找所有没有 ProjectVideo 关联的 Video
        let videoDescriptor = FetchDescriptor<Video>()
        guard let allVideos = try? context.fetch(videoDescriptor) else {
            MixLog.error(" 关联迁移：读 Video 表失败，本次不记成功键（下次启动重试）")
            return false
        }

        let orphanVideos = allVideos.filter { $0.projectVideos.isEmpty }
        guard !orphanVideos.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return true
        }

        // 通过 SQLite 查询旧的 Video→Project 外键关系
        guard let storeURL = container.configurations.first?.url else {
            MixLog.error(" 关联迁移：取不到库文件路径，本次不记成功键")
            return false
        }

        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK else {
            MixLog.error(" 关联迁移：打不开库文件，本次不记成功键")
            return false
        }
        defer { sqlite3_close(db) }

        // 查所有项目
        let projectDescriptor = FetchDescriptor<Project>()
        guard let allProjects = try? context.fetch(projectDescriptor) else {
            MixLog.error(" 关联迁移：读 Project 表失败，本次不记成功键")
            return false
        }

        // 建立 Z_PK → Project 的映射（SwiftData 内部用 Z_PK 作为行号）
        // 由于无法直接获取 Z_PK，使用 UUID 匹配
        var migratedCount = 0

        // 用 SQL 查询 ZVIDEO 表中的 ZPROJECT 外键
        // SwiftData 存储的外键列名通常是关系名大写
        var stmt: OpaquePointer?
        let sql = """
            SELECT v.ZIDENTIFIER, p.ZIDENTIFIER
            FROM ZVIDEO v
            LEFT JOIN ZPROJECT p ON v.ZPROJECT = p.Z_PK
            WHERE v.ZPROJECT IS NOT NULL
        """

        // 尝试查询（列名可能不同）
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // 建 UUID → Project 查找表
            var projectByUUID: [String: Project] = [:]
            for p in allProjects {
                projectByUUID[p.id.uuidString.uppercased()] = p
            }

            var videoByUUID: [String: Video] = [:]
            for v in orphanVideos {
                videoByUUID[v.id.uuidString.uppercased()] = v
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let videoIDPtr = sqlite3_column_text(stmt, 0),
                      let projectIDPtr = sqlite3_column_text(stmt, 1) else { continue }

                let videoUUID = String(cString: videoIDPtr).uppercased()
                let projectUUID = String(cString: projectIDPtr).uppercased()

                if let video = videoByUUID[videoUUID], let project = projectByUUID[projectUUID] {
                    let alreadyLinked = project.projectVideos.contains { $0.video?.id == video.id }
                    ProjectVideo.associate(project: project, video: video, in: context)
                    if !alreadyLinked { migratedCount += 1 }
                }
            }
            sqlite3_finalize(stmt)
        } else {
            // SQL 失败（可能列名不同），尝试用第一个项目兜底
            MixLog.info(" SQL 迁移查询失败，尝试将孤儿视频关联到第一个项目")
            if let firstProject = allProjects.first {
                for video in orphanVideos {
                    let alreadyLinked = firstProject.projectVideos.contains { $0.video?.id == video.id }
                    ProjectVideo.associate(project: firstProject, video: video, in: context)
                    if !alreadyLinked { migratedCount += 1 }
                }
            }
        }

        if migratedCount > 0 && !context.safeSave() {
            MixLog.error(" 关联迁移：落库失败，本次不记成功键（下次启动重试）")
            return false
        }
        if migratedCount > 0 {
            MixLog.info(" 已迁移 \(migratedCount) 个视频到 ProjectVideo 关联")
        }

        UserDefaults.standard.set(true, forKey: fixKey)
        return true
    }

    /// 清理上次未正常完成的中间态视频
    /// 启动时把所有处于 detectingScenes / transcribing / analyzing 的视频
    /// 标记为 failed 或 imported（取决于是否已有分镜数据），避免 UI 永久卡住"分析中"
    @MainActor
    static func resetStaleAnalyzingStatus(container: ModelContainer) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Video>()
        guard let videos = try? context.fetch(descriptor) else { return }
        var fixedCount = 0
        for v in videos {
            switch v.status {
            case .queued, .detectingScenes, .transcribing, .analyzing:
                if v.segments.isEmpty {
                    v.status = .failed
                    v.errorMessage = (v.errorMessage ?? "") + "\n[启动重置] 上次未完成的分析任务被中断，请点击重试"
                } else {
                    v.status = .completed
                }
                fixedCount += 1
            default:
                break
            }
        }
        // ⚠️ 只重置 Video 不够：Project 也会被置成 .importing / .generating，
        // 崩溃或强退后项目会**永久停在「生成中」**，用户既看不到出口也无法再次生成。
        var fixedProjects = 0
        if let projects = try? context.fetch(FetchDescriptor<Project>()) {
            for p in projects where p.status == .importing || p.status == .generating {
                // 有方案就算完成，否则回到就绪态；两者都能让用户继续操作
                p.status = p.schemeCount > 0 ? .completed : .ready
                fixedProjects += 1
            }
        }

        if fixedCount > 0 || fixedProjects > 0 {
            try? context.save()
            MixLog.info(" 启动时已重置 \(fixedCount) 个视频 / \(fixedProjects) 个项目的中间态状态")
        }
    }

    /// 为所有现有项目补上"自定义组合"策略容器（首次升级后执行一次）
    /// 新项目走 ProjectViewModel.createProject 同步创建，老项目走这里补
    ///
    /// - Returns: 补出来的策略是否**已落库**。以前 `try? context.save()` 吞掉失败后照样写成功键，
    ///   于是老项目永远没有「自定义组合」入口，而且再没有第二次机会补。
    @MainActor
    @discardableResult
    static func ensureCustomGroupStrategy(container: ModelContainer) -> Bool {
        let fixKey = "didEnsureCustomGroupStrategy_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return true }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? context.fetch(descriptor) else {
            MixLog.error(" 组合策略补建：读 Project 失败，本次不记成功键")
            return false
        }

        var addedCount = 0
        for project in projects {
            let hasCustomGroup = project.strategies.contains { $0.isCustomGroup }
            if !hasCustomGroup {
                let strategy = MixStrategy(
                    name: "自定义组合",
                    style: "",
                    description: "手动挑选分镜组合的方案",
                    targetAudience: "",
                    narrativeStructure: "",
                    targetDuration: 0
                )
                strategy.isCustomGroup = true
                strategy.project = project
                project.strategies.append(strategy)
                context.insert(strategy)
                addedCount += 1
            }
        }

        if addedCount > 0 && !context.safeSave() {
            MixLog.error(" 组合策略补建：落库失败，本次不记成功键")
            return false
        }
        if addedCount > 0 {
            MixLog.info(" 已为 \(addedCount) 个老项目补建「自定义组合」策略")
        }

        UserDefaults.standard.set(true, forKey: fixKey)
        return true
    }

    /// 一次性迁移：把 segment thumbnail 从「中间帧」重新生成为「首帧」
    /// 修复历史 bug: ImportViewModel 早期版本用 (start+end)/2 作为缩略图时间点，与用户「分镜首帧」直觉不符
    @MainActor
    static func regenerateSegmentThumbnailsToFirstFrame(container: ModelContainer) async {
        let fixKey = "didRegenerateSegmentThumbnailsToFirstFrame_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return }

        let context = container.mainContext
        let descriptor = FetchDescriptor<Segment>()
        guard let segments = try? context.fetch(descriptor), !segments.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        struct Job: Sendable {
            let segmentID: UUID
            let videoPath: String
            let firstFrameTime: Double
            let outputPath: String
        }

        let thumbDir = FileHelper.globalThumbnailDirectory
        var jobs: [Job] = []
        var segmentByID: [UUID: Segment] = [:]

        for segment in segments {
            guard let video = segment.video,
                  FileManager.default.fileExists(atPath: video.localPath) else { continue }
            if let oldPath = segment.thumbnailPath {
                try? FileManager.default.removeItem(atPath: oldPath)
            }
            let firstFrameTime = max(0, segment.startTime + 0.1)
            let outputPath = thumbDir.appendingPathComponent("seg_\(segment.id.uuidString).jpg").path
            jobs.append(Job(
                segmentID: segment.id,
                videoPath: video.localPath,
                firstFrameTime: firstFrameTime,
                outputPath: outputPath
            ))
            segmentByID[segment.id] = segment
        }

        guard !jobs.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return
        }

        MixLog.info(" 开始重生 \(jobs.count) 个分镜缩略图（中间帧 → 首帧）")

        let ffmpeg = FFmpegRunner()
        let results: [(UUID, String?)] = await withTaskGroup(of: (UUID, String?).self) { group in
            for job in jobs {
                group.addTask { [ffmpeg] in
                    do {
                        try await ffmpeg.generateThumbnail(
                            from: job.videoPath,
                            at: job.firstFrameTime,
                            to: job.outputPath
                        )
                        return (job.segmentID, job.outputPath)
                    } catch {
                        return (job.segmentID, nil)
                    }
                }
            }
            var out: [(UUID, String?)] = []
            for await r in group { out.append(r) }
            return out
        }

        var successCount = 0
        for (id, path) in results {
            if let segment = segmentByID[id], let path {
                segment.thumbnailPath = path
                successCount += 1
            }
        }
        try? context.save()
        ThumbnailCache.shared.clear()

        MixLog.info(" 完成重生 \(successCount)/\(jobs.count) 个分镜缩略图")
        UserDefaults.standard.set(true, forKey: fixKey)
    }

    /// 一次性迁移：把旧版共享的 default.store 搬到 MixCut 专属库。
    ///
    /// 背景：非沙盒 App 不指定库名时，SwiftData 默认库都落在共享路径
    /// `~/Library/Application Support/default.store`，会被本机其它非沙盒 SwiftData App
    /// 共用，schema 不符时互相清库导致数据丢失。改用专属库后需把老用户数据搬过去。
    ///
    /// 安全保证：仅当专属库尚不存在、且旧库确实含 MixCut 的 ZPROJECT 表时才搬迁，
    /// 避免把其它 App 的库误搬进来。连 -wal/-shm 一起复制，防止 WAL 中未合并数据丢失。
    private static func migrateDefaultStoreToDedicated() {
        let fm = FileManager.default
        let dest = FileHelper.mixCutStoreURL

        // 专属库已存在 → 已迁移过（或全新安装直接用新库），跳过
        if fm.fileExists(atPath: dest.path) { return }
        guard let legacy = FileHelper.legacyDefaultStoreURL,
              fm.fileExists(atPath: legacy.path) else { return }

        // 旧库必须确实是 MixCut 的库（含 ZPROJECT 表）才迁移
        guard sqliteHasTable(at: legacy.path, table: "ZPROJECT") else {
            MixLog.info("default.store 不含 \(Brand.legacyDisplayName) 数据（可能被其它 App 占用），跳过迁移，使用全新专属库")
            return
        }

        // 先复制主库；失败则清理残留并 return，下次启动干净重试。
        // 关键：绝不能留下截断的主库文件——否则下次启动 fileExists 为 true 被误判
        // "已迁移"，SwiftData 打开损坏库进入内存模式，用户数据看似全丢。
        do {
            try fm.copyItem(at: legacy, to: dest)
        } catch {
            MixLog.error("迁移主数据库失败，已回滚残留，下次启动重试: \(error.localizedDescription)")
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: dest.path + suffix)
            }
            return
        }

        // 主库已就位，再复制 WAL/SHM 保留未合并数据。这两个失败可容忍（SwiftData 会重建），
        // 此时主库已是完整状态，不影响数据安全。
        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: legacy.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: URL(fileURLWithPath: dest.path + suffix))
            } catch {
                MixLog.error("迁移数据库 \(suffix) 失败（可容忍）: \(error.localizedDescription)")
            }
        }
        MixLog.info("已把 default.store 迁移到专属库 \(Brand.storeFileName)")
    }

    /// 用 SQLite C API 只读检查某 sqlite 文件是否含指定表。
    /// 不经 SwiftData 打开，避免 schema 不符时被清库。
    private static func sqliteHasTable(at path: String, table: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        // table 为代码内常量（"ZPROJECT"）；额外做标识符白名单校验，杜绝任何注入可能
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(table)' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 清除 bundle 内 FFmpeg/whisper 二进制及 dylib 的 quarantine 属性
    /// DMG 分发后 macOS 会给所有文件打上 com.apple.quarantine，导致 ad-hoc 签名的二进制无法执行
    static func removeQuarantineFromBundleBinaries() {
        guard let binURL = Bundle.main.resourceURL?.appendingPathComponent("bin") else { return }
        let binPath = binURL.path
        guard FileManager.default.fileExists(atPath: binPath) else { return }

        // 用 xattr -cr 递归清除整个 bin 目录的 quarantine
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", binPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MixLog.error("清除 quarantine 失败: \(error)")
        }
    }

    /// 从磁盘恢复丢失的项目和视频
    /// 当 schema 变更导致数据库被清空时，扫描旧项目目录自动重建
    @discardableResult
    static func recoverFromDisk(container: ModelContainer) -> Bool {
        let fixKey = "didRecoverFromDisk_v1"
        if UserDefaults.standard.bool(forKey: fixKey) { return true }

        let context = container.mainContext

        // 检查数据库是否为空
        let projectDesc = FetchDescriptor<Project>()
        let existingProjects = (try? context.fetch(projectDesc)) ?? []
        if !existingProjects.isEmpty {
            // 数据库有数据，不需要恢复
            UserDefaults.standard.set(true, forKey: fixKey)
            return true
        }

        // 扫描旧项目目录
        let projectsDir = FileHelper.appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil
        ) else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return true
        }

        // 收集所有去重的视频文件路径（按文件名去重）
        var uniqueVideos: [String: URL] = [:]  // fileName → URL
        var projectVideoMap: [String: [String]] = [:]  // projectDirName → [fileName]

        for dir in projectDirs {
            let dirName = dir.lastPathComponent
            guard dirName != ".DS_Store" else { continue }

            let videosDir = dir.appendingPathComponent("Videos")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: videosDir,
                includingPropertiesForKeys: nil
            ) else { continue }

            let videoFiles = files.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["mp4", "mov", "avi", "mkv", "m4v"].contains(ext)
            }

            if !videoFiles.isEmpty {
                projectVideoMap[dirName] = videoFiles.map(\.lastPathComponent)
                for file in videoFiles {
                    if uniqueVideos[file.lastPathComponent] == nil {
                        uniqueVideos[file.lastPathComponent] = file
                    }
                }
            }
        }

        guard !uniqueVideos.isEmpty else {
            UserDefaults.standard.set(true, forKey: fixKey)
            return true
        }

        MixLog.info(" 发现 \(uniqueVideos.count) 个视频文件，开始恢复...")

        // 创建一个恢复项目
        let project = Project(name: "恢复的项目")
        project.status = .ready
        context.insert(project)

        // 为每个唯一视频创建 Video 实体
        for (fileName, fileURL) in uniqueVideos {
            let video = Video(name: fileName, localPath: fileURL.path)
            video.status = .imported  // 需要重新分析
            video.contentHash = ImportViewModel.computeFileHash(path: fileURL.path)
            context.insert(video)

            ProjectVideo.associate(project: project, video: video, in: context)
        }

        // 存不下就**不写成功键**：这批 Video 只活在内存里，重启后磁盘上那些文件会被判成孤儿。
        guard context.safeSave() else {
            MixLog.error(" 磁盘恢复落库失败，本次不记成功键（下次启动重跑，孤儿 GC 已被清单拦住）")
            return false
        }
        MixLog.info(" 已恢复 \(uniqueVideos.count) 个视频到「恢复的项目」，请重新执行 AI 分析")

        UserDefaults.standard.set(true, forKey: fixKey)
        return true
    }

    /// 启动时孤儿文件 GC：收集所有 Video/Segment 记录引用到的文件路径，
    /// 删除全局视频/缩略图目录里「已无任何记录引用」的孤儿文件。
    ///
    /// 配合「删除只删记录」：删除操作不再 inline 删磁盘文件，下次启动由本方法统一回收，
    /// 从而保证删除可被撤销恢复（撤销期间磁盘文件仍在）。
    ///
    /// ⚠️ 数据安全：referenced 必须收全（Video.localPath/thumbnailPath + Segment.thumbnailPath），
    /// 否则会误删在用文件。
    /// 一次性迁移：把旧的**全局**字幕字号继承到每个分镜。
    ///
    /// 字幕字号原本是存在 UserDefaults 里的全局设置（改一处 = 改所有视频的所有分镜），
    /// 后来改成逐分镜独立。若不迁移，老用户之前调好的字号会突然回落到默认值。
    @MainActor
    static func migrateGlobalSubtitleFontRatio(container: ModelContainer) {
        let doneKey = "didMigrateSubtitleFontRatioToSegment_v1"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }

        // 没有旧全局值就无需迁移（新用户直接用默认）
        guard let legacy = UserDefaults.standard.object(forKey: SubtitleFontSize.userDefaultsKey) as? Double else { return }
        let ratio = SubtitleFontSize.clamp(legacy)
        guard abs(ratio - SubtitleFontSize.defaultRatio) > 0.0001 else { return }

        let ctx = container.mainContext
        guard let segments = try? ctx.fetch(FetchDescriptor<Segment>()), !segments.isEmpty else { return }
        for seg in segments { seg.subtitleFontRatio = ratio }
        ctx.safeSave()
        MixLog.info("[Migration] 旧全局字幕字号 \(String(format: "%.1f%%", ratio * 100)) 已继承到 \(segments.count) 个分镜")
    }

    /// 清理临时目录中的过期中间产物。
    ///
    /// 切片、PCM、TTS wav、合成中间文件都落在 tempDirectory。虽然各流程大多有清理，
    /// 但异常分支（抛错 / 取消 / 崩溃）会漏删，且以前**没有任何兜底清理**，
    /// 长期使用会持续占盘。这里在启动后台清掉超过 24 小时的残留（正在进行的任务不会被误删）。
    @MainActor
    static func purgeStaleTempFiles() {
        Task.detached(priority: .background) {
            let dir = FileHelper.tempDirectory
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            var freed: Int64 = 0
            var count = 0
            for url in items {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate, modified < cutoff else { continue }
                freed += Int64(values.fileSize ?? 0)
                try? FileManager.default.removeItem(at: url)
                count += 1
            }
            if count > 0 {
                let mb = Double(freed) / 1024 / 1024
                MixLog.info("[TempPurge] 已清理 \(count) 个过期临时文件，释放 \(String(format: "%.1f", mb))MB")
            }
        }
    }

    /// 换 bundle id 后新域是空的，所以把旧域的**全部**键搬进新域。
    ///
    /// 不能写白名单：`api_key_*` / `selected_model_*` / `thinking_enabled_*` 是按 provider 动态拼的，
    /// 静态枚举只能列出字面量键，必然漏 API Key。标志存"从哪个域导入过"，
    /// 于是整域拷贝最多重复一次，且换品牌之后会自动再做一次。
    private static func importSettingsFromLegacyDomain() {
        guard Brand.legacyBundleID != Brand.bundleID else { return }   // 还没翻名字：整段空转
        let doneKey = LegacySettingsImport.importedFromKey
        guard UserDefaults.standard.string(forKey: doneKey) != Brand.bundleID else { return }

        // 只搬"用户真存过的"键。`UserDefaults(suiteName:).dictionaryRepresentation` 会把系统全局域
        // （AppleLanguages / NSLanguages / 拼写检查状态 …）和本进程的启动参数一起吐出来 ——
        // 演练实测多带进 30 个键。这些东西一旦被持久化进新域，将来改代码默认值或用户改系统语言都对老用户失效。
        // 持久域的内容就在 ~/Library/Preferences/<bundleID>.plist，读它。
        let plistPath = NSHomeDirectory() + "/Library/Preferences/\(Brand.legacyBundleID).plist"
        guard let raw = FileManager.default.contents(atPath: plistPath),
              let object = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil),
              let stored = object as? [String: Any] else {
            MixLog.error("[BrandMigration] 读不到旧域 \(Brand.legacyBundleID).plist —— 本次不导入设置（旧域未被改动，可人工恢复）")
            return
        }
        let keys = LegacySettingsImport.keysToImport(Set(stored.keys))
        for key in keys {
            if let value = stored[key] { UserDefaults.standard.set(value, forKey: key) }
        }
        UserDefaults.standard.set(Brand.bundleID, forKey: doneKey)
        MixLog.info("[BrandMigration] 从旧域 \(Brand.legacyBundleID) 导入设置 \(keys.count) 项")
    }

    /// 一次性改写库里存的绝对路径前缀（旧数据目录 → 当前数据目录）。
    /// 幂等：只有仍以旧前缀开头的值才动，重复启动不会来回改。
    ///
    /// - Returns: 这次**有没有**留下仍指着旧前缀的值。`false` 会拦住孤儿 GC ——
    ///   未改写完就按"库内引用"判孤儿，等于把还在盘上、只是路径没对上的在用素材删掉。
    @MainActor
    @discardableResult
    static func rewriteStoredPathPrefixes(container: ModelContainer) -> Bool {
        let base = FileHelper.appSupportBaseDirectory.path
        let oldPrefix = "\(base)/\(Brand.legacyDataDirectoryName)"
        let newPrefix = "\(base)/\(Brand.dataDirectoryName)"
        guard oldPrefix != newPrefix else { return true }

        let ctx = container.mainContext
        var rewritten = 0
        var uncovered = 0

        /// 读→判→写。`uncovered` 专门接住"看着像旧路径、但改写规则没命中"的值，不让它静默过去。
        func apply(_ read: () -> String?, _ write: (String) -> Void) {
            guard let value = read() else { return }
            if let fixed = StoredPathPrefixRewriter.rewrite(value, from: oldPrefix, to: newPrefix) {
                write(fixed)
                rewritten += 1
            } else if value.hasPrefix(oldPrefix) {
                uncovered += 1
            }
        }

        // 三张表都必须**读到**才算改写完成：以前是 `(try? fetch) ?? []`，
        // 读失败会伪装成"没有要改的行"，改写静默空转一趟还被记成成功。
        guard let videos = try? ctx.fetch(FetchDescriptor<Video>()) else {
            MixLog.error("[BrandMigration] 读 Video 表失败，本次前缀改写未完成")
            return false
        }
        for video in videos {
            apply({ video.localPath }, { video.localPath = $0 })
            apply({ video.thumbnailPath }, { video.thumbnailPath = $0 })
        }
        guard let segments = try? ctx.fetch(FetchDescriptor<Segment>()) else {
            MixLog.error("[BrandMigration] 读 Segment 表失败，本次前缀改写未完成")
            return false
        }
        for segment in segments {
            apply({ segment.thumbnailPath }, { segment.thumbnailPath = $0 })
            apply({ segment.replacedPictureVideoPath }, { segment.replacedPictureVideoPath = $0 })
            apply({ segment.replacedPictureThumbnailPath }, { segment.replacedPictureThumbnailPath = $0 })
            for shot in segment.physicalShots {
                apply({ shot.thumbnailPath }, { shot.thumbnailPath = $0 })
                for variant in shot.variants {
                    apply({ variant.resultVideoPath }, { variant.resultVideoPath = $0 })
                    apply({ variant.thumbnailPath }, { variant.thumbnailPath = $0 })
                }
            }
        }
        // 配音音频不在 GC 扫的那 5 棵树里，但路径同样存在库内，改写必须带上
        guard let dubs = try? ctx.fetch(FetchDescriptor<SegmentDub>()) else {
            MixLog.error("[BrandMigration] 读 SegmentDub 表失败，本次前缀改写未完成")
            return false
        }
        for dub in dubs {
            apply({ dub.audioFilePath }, { dub.audioFilePath = $0 })
        }
        guard ctx.safeSave() else {
            MixLog.error("[BrandMigration] 前缀改写落库失败，本次改写未记账")
            return false
        }

        MixLog.info("[BrandMigration] 路径前缀改写 \(rewritten) 个值（\(oldPrefix) → \(newPrefix)）")
        if uncovered > 0 {
            MixLog.error("[BrandMigration] 有 \(uncovered) 个值以旧前缀开头却没被改写 —— 字段清单不全，需人工核对")
            return false
        }
        return true
    }

    /// 按需调度孤儿文件 GC：距上次执行满 24 小时才跑，且延后到启动之后，避免拖慢冷启动。
    @MainActor
    static func scheduleOrphanGCIfDue(container: ModelContainer) {
        // 迁移没落地就绝不回收：此时库里的路径还指着旧目录，"未引用"判定全都不可信。
        // 且**不写 lastOrphanGCAt** —— 否则等于把这枚雷顺延 24 小时，跳过原因就从日志里消失了。
        guard FileHelper.isBrandDirectoryMigrationComplete else {
            MixLog.info("[OrphanGC] 品牌目录迁移未完成，本次跳过且不记时间戳")
            return
        }
        let key = "lastOrphanGCAt"
        let interval: TimeInterval = 24 * 60 * 60
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard last == 0 || now - last >= interval else {
            MixLog.info("[OrphanGC] 距上次不足 24h，本次启动跳过")
            return
        }
        Task { @MainActor in
            // 让首屏先渲染出来，再做这件重活
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            runOrphanGC(container: container)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        }
    }

    @MainActor
    private static func runOrphanGC(container: ModelContainer) {
        let ctx = container.mainContext
        var referenced = Set<String>()
        if let videos = try? ctx.fetch(FetchDescriptor<Video>()) {
            for v in videos {
                referenced.insert(v.localPath)
                if let t = v.thumbnailPath { referenced.insert(t) }
            }
        }
        if let segs = try? ctx.fetch(FetchDescriptor<Segment>()) {
            for s in segs {
                if let t = s.thumbnailPath { referenced.insert(t) }
                // 就地替换画面：生效中的合成片/缩略图受保护，不被回收
                if let p = s.replacedPictureVideoPath { referenced.insert(p) }
                if let t = s.replacedPictureThumbnailPath { referenced.insert(t) }
                // 分镜头缩略图 + 变体产物
                for shot in s.physicalShots {
                    if let t = shot.thumbnailPath { referenced.insert(t) }
                    for v in shot.variants {
                        if let p = v.resultVideoPath { referenced.insert(p) }
                        if let t = v.thumbnailPath { referenced.insert(t) }
                    }
                }
            }
        }
        FileHelper.collectOrphanFiles(referencedPaths: referenced)
    }
}
