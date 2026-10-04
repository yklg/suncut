import Foundation
import SwiftData

extension PersistentModel {
    /// 对象是否已从上下文摘除（= 已被 `delete` 或被级联删掉）。
    ///
    /// 这是「**正在被移除的那个视图自己还会重算一次 body**」那一类崩溃的唯一判据 ——
    /// 投影剪枝拦不住它：删除时 SwiftData 会给这个仍存活的内存对象发变更通知，
    /// 于是那个视图在消失前又被求值一遍，此时读任何持久属性都命中 SwiftData 内部断言（EXC_BREAKPOINT）。
    /// 原先这判据散在 4 处各写各的（`ImportView` 的卡片、`ShotEditViewModel` 两处、
    /// `SegmentPropertiesSection` 的两处撤销循环），收到这里当唯一真源，别再新增第五处写法。
    ///
    /// ⚠️ 跨关系边界的读取请用下面的 `isGoneFromGraph` / `live`：单看 `modelContext` 只覆盖
    /// 「你自己手上这颗对象」，管不到从一条 to-one 边上跨过来的那颗。
    var isDroppedFromContext: Bool { modelContext == nil }

    /// 图是否已经不认这颗对象 —— **两个独立信号的析取**（保守档：任一说不行就不行）。
    ///
    /// - `isDeleted`：SwiftData 的一等 API（macOS 14+），`delete` 打的标记。**不能单用**：
    ///   物理移除要等 save，未 save 前这条记录**仍会出现在 fetch 结果里**，
    ///   而且别的引用还可能让它在持久化之后**翻回 false**。
    /// - `modelContext == nil`：对象已从上下文摘除（含被级联删掉）。
    ///
    /// 本仓原先只认后者，于是第二起同族崩就发生在「跨一条 to-one 边读到已真删的 `Project` 的 `id`」
    /// （`SegmentPickerDrawer.swift:106`，SIGTRAP）。教训是判据得站在**取持久属性之前**那一处，
    /// 不能等崩了再回到报错行补。
    /// ⚠️ 两信号的**充分性还没在本仓实测**（五格矩阵未跑，见计划 `docs/superpowers/plans/2026-10-04-…:§4`）。
    ///    若测出某格两信号都 false 而读 `.id` 仍 trap，第三信号是 `modelContext !== 期望的读写 context`。
    var isGoneFromGraph: Bool { isDeleted || modelContext == nil }

    /// 跨关系边界的**唯一过门写法**：先证明还活着，才准 fault 任何持久属性。
    ///
    /// 刻意只返回对象、不提供 `liveID` 这种"顺手把 id 也取了"的形态 ——
    /// SDK 给 `PersistentModel` 的默认 `id` 是 `PersistentIdentifier`，而本仓的模型各自声明了
    /// `@Attribute(.unique) var id: UUID`，泛型里取 `Self.ID` 会在两类模型之间漂移。
    var live: Self? { isGoneFromGraph ? nil : self }
}

extension Optional where Wrapped: PersistentModel {
    /// 跨边读取的标准形态：`video.ownerProject.live?.id`（只扁平一层，不留 Optional 套 Optional）。
    var live: Wrapped? { flatMap { $0.live } }
}

// MARK: - 跨边解边的 App 侧具象（逻辑本体在 MixCutCore.LiveIDIndex）

/// 跨边解边索引：Key = `PersistentIdentifier`（结构性标识）。
///
/// 跨 to-one 边的**唯一推荐写法**：fetch 全部相关模型 → 从活结果构建索引 →
/// `index.uuid(for: owner.relationship)`。目标已真删时，fault 复活的空壳查无映射 ⇒ nil，
/// 不读空壳的业务列（`.live` 探针在此相位双 false，已被第三起 SIGTRAP 证伪）。
typealias LiveModelIDIndex = LiveIDIndex<PersistentIdentifier>

extension LiveIDIndex where Key == PersistentIdentifier {
    /// 从活 fetch 结果批量登记。
    ///
    /// `id` 显式传入：泛型上下文里 `PersistentModel.id` 是框架的 `PersistentIdentifier`，
    /// 与各模型自定义的 `@Attribute(.unique) var id: UUID` 漂移（前案 §1.3 已证）。
    mutating func insert<T: PersistentModel>(_ models: [T], id: (T) -> UUID) {
        for model in models {
            reserve(model.persistentModelID, uuid: id(model))
        }
    }

    /// 跨边标准入口：只取边目标的 persistentModelID（结构性、不加载 backing）再查索引。
    func uuid(for model: (any PersistentModel)?) -> UUID? {
        uuid(for: model?.persistentModelID)
    }
}

extension ModelContext {
    /// 批量删除 —— **第一件事就是快照**。
    ///
    /// `for x in model.someToMany { context.delete(x) }` 是在遍历一条活的 to-many 关系的同时改它，
    /// 本仓 `ImportViewModel.swift:277` 早就把这条写成「必须先 `Array(...)` 快照，直接迭代行为未定义」，
    /// 但那是靠人记的注释；这颗 API 让「忘记快照」构造不出来：传进来的关系数组在进入函数那一行就已经是值拷贝。
    ///
    /// ⚠️ 刻意不用官方的 `delete(model:where:)`：那是存储层批量删，不会动内存里已 materialize 的对象，
    /// 用在这里只会**制造更多**待读的死对象。
    func delete<S: Sequence>(_ objects: S) where S.Element: PersistentModel {
        for object in Array(objects) { delete(object) }
    }

    /// 安全保存，失败时记录日志而非静默吞掉错误。
    @discardableResult
    func safeSave(file: String = #file, line: Int = #line) -> Bool {
        do {
            try save()
            return true
        } catch {
            let fileName = (file as NSString).lastPathComponent
            MixLog.error("数据库保存失败 [\(fileName):\(line)]: \(error.localizedDescription)")
            return false
        }
    }

    /// 保存并在失败时告知用户。
    ///
    /// ⚠️ 用于「改动很贵或很难重做」的场景（重识别台词、已计费的配音产物、合成结果等）：
    /// 这些地方以前是 `try? save()` 紧跟一句成功提示 —— 保存失败时用户仍看到"成功"，
    /// 重启后改动却消失了，属于最难排查的一类问题。
    /// - Returns: 是否保存成功；调用方据此决定是否弹成功提示。
    @MainActor
    @discardableResult
    func saveOrWarn(_ whatFailed: String, file: String = #file, line: Int = #line) -> Bool {
        if safeSave(file: file, line: line) { return true }
        ToastCenter.shared.show("\(whatFailed)保存失败，改动可能在重启后丢失。请重试；日志见 \(MixLog.logFileURL.path)",
                                icon: "exclamationmark.triangle.fill", style: .warning, duration: 5)
        return false
    }
}

// MARK: - 删项目：入边结算 + 真删的唯一咽喉（刀 9）

/// `deleteProjectSettlingOwnerEdges(_:)` 的读数。字段都是**给调用方交代用的**，不是预留扩展位。
struct ProjectDeletionOutcome {
    /// 因为"没有其它项目引用"而被连带删掉的视频名（MCP 的 `videos_deleted_globally` 直接吃它）
    var deletedVideoNames: [String] = []
    /// `Video.ownerProject` 被改指到仍在世的合作项目的颗数
    var repointedVideos: Int = 0
    /// 找不到任何仍在世的归属、只能置 nil 的颗数（读侧按 R4 回退默认产品）
    var clearedOwners: Int = 0
    /// 落盘失败 ⇒ 内存已改、库里没改。调用方**不要**再广播，否则界面剪枝与库各说一套。
    var saveFailed: Bool = false
    /// 这次从图上摘掉了哪些 id（给唯一发布口 `GraphBroadcast`）。`saveFailed` 时调用方必须丢弃它。
    var change = GraphChange()
}

extension ModelContext {
    /// 真删一颗 `Project` 的**唯一入口**。取代此前 `ProjectViewModel.deleteProject` 的 commit 与
    /// `MCPToolHandlers.deleteProject` 那**两份复制粘贴实现**（后者 `:613` 的注释自己都写着"与前者逻辑一致"）。
    ///
    /// 顺序全部写死在这里，调用方无从倒置：
    /// 1. **先结算入边** —— 必须早于 `delete`：`projectVideos` 是 cascade 删的（`Project.swift:28`），
    ///    删完就再也查不出"还有哪些项目共享这颗 Video"，重选归属的输入集就空了。
    /// 2. 再 `delete(project)`（级联带走 `ProjectVideo`/`MixStrategy`/`MixScheme`/`SchemeSegment`）。
    /// 3. 补删没有任何其它引用的 `Video` 与它的 `Segment`（这条判定只能在**cascade 落盘之后**做，故中间那次 save 不能省）。
    /// 4. 收尾 `safeSave()`；两次落盘任一失败都记进 `saveFailed`（不重试、不广播）。
    ///
    /// 为什么要结算、不能让框架代劳：判据矩阵实测（`DocsPlan:§23` 的 ④/④′/⑩′/⑬ 四格，含盘侧）——
    /// SwiftData 会在 save 时把 `Video.ownerProject` 这条悬空边**置 nil 并落盘**，
    /// 而 `LaunchSteps.swift:70` 的回填是 `.once` 台账、永不二次生效 ⇒ **每删一次项目就永久抹掉一次导入事实**。
    /// 结算口径与启动回填**同源**（`ProductOwnershipBackfill.ownerProjectIDByVideoID`，B1-B5 有单测），
    /// 这里不重写"取最早可解析关联"的规则；解析不出归属的视频保持 nil，读侧 R4 回退默认产品。
    ///
    /// ⚠️ 只结算 `Video.ownerProject` **一条**边：模型层共 13 条裸 to-one 边（实测穷举，见 `TombstoneReadGuardTests` G13），
    ///    其余 12 条的入边尚未结算 ⇒ 那部分是**在册欠账**（G18 名册），别读成"入边问题已收口"。
    @MainActor
    @discardableResult
    func deleteProjectSettlingOwnerEdges(_ project: Project) -> ProjectDeletionOutcome {
        var outcome = ProjectDeletionOutcome()
        // 幂等：已经被删过（或被级联摘掉）就不再来一遍 —— 重复调用会把已死的边再读一次。
        guard !project.isGoneFromGraph else { return outcome }
        let projectName = project.name
        // ① 两份名单都要在删之前拿：`project.videos` 走的是会被 cascade 清掉的关系。
        let referencedVideos = project.videos
        let ownedByProject = (((try? fetch(FetchDescriptor<Video>())) ?? []) as [Video])
            .filter { $0.ownerProject === project }     // 指针比较，不 fault 目标对象的持久列

        // ② 结算入边：把"本项目参与的关联"从算最早归属的输入里摘掉（projectID 置 nil ⇒ B3 天然不参与）。
        if !ownedByProject.isEmpty {
            let associationRows = (try? fetch(FetchDescriptor<ProjectVideo>())) ?? []
            let associations = associationRows.map {
                ProjectVideoAssociation(pvID: $0.id,
                                        projectID: $0.project === project ? nil : $0.project?.id,
                                        videoID: $0.video?.id,
                                        addedAt: $0.addedAt)
            }
            let ownerMap = ProductOwnershipBackfill.ownerProjectIDByVideoID(associations)
            let successors = Dictionary(((try? fetch(FetchDescriptor<Project>())) ?? [])
                .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            for video in ownedByProject {
                if let successor = ownerMap[video.id].flatMap({ successors[$0] }), successor !== project {
                    video.ownerProject = successor
                    outcome.repointedVideos += 1
                } else {
                    video.ownerProject = nil
                    outcome.clearedOwners += 1
                }
            }
        }

        // ③ 真删。**这次 save 不能省，也不能挪到后面**：cascade 是在落盘时才把 `ProjectVideo` 摘掉的，
        //    而下一步的判定读的正是 `video.projectVideos.isEmpty` —— 合并在末尾一次 save 会让它永远为 false，
        //    一颗孤儿视频都判不出来（第⑭格实测抓到过：合并前 2 颗视频都留着、`videos_deleted_globally` 空）。
        delete(project)
        outcome.change.noteDeleted([project.id], of: .project)
        let projectSaved = safeSave()
        for video in referencedVideos where video.projectVideos.isEmpty {
            // id 一律在 delete **之前**取：delete 之后再从关系数组里读 `.id` 本身就是一次墓碑读
            // （前案 §3 刀 2 第 164 行写的同一条纪律）。
            let segments = Array(video.segments)
            outcome.change.noteDeleted(Set(segments.map(\.id)), of: .segment)
            outcome.change.noteDeleted([video.id], of: .video)
            delete(segments)
            delete(video)
            outcome.deletedVideoNames.append(video.name)
        }

        // ④ 收尾落盘；失败只记日志、不重试、不广播（见 `ProjectDeletionOutcome.saveFailed`）。
        outcome.saveFailed = !projectSaved || !safeSave()
        MixLog.info("[GraphSettle] 删项目《\(projectName)》：入边改指 \(outcome.repointedVideos) 颗、"
                    + "置空 \(outcome.clearedOwners) 颗；连带删无引用视频 \(outcome.deletedVideoNames.count) 颗"
                    + (outcome.saveFailed ? " —— **保存失败，内存与库暂不一致**" : ""))
        return outcome
    }
}
