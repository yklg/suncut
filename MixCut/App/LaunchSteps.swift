import Foundation
import SwiftData

// 没有 `import MixCutCore`：本工程 `MixCutCore` 的源码是**逐文件手工编进 App target** 的
// （`project.pbxproj` 里那几十条 PBXBuildFile），所以 `LaunchStep` / `decideStep` 与 App 代码同模块，
// 加了 import 反而编不过。

/// 启动链的**清单与驱动**。"这颗该不该跑、能不能跑"由 `MixCutCore.decideStep` 判，
/// 这里只提供声明（`steps`）和每颗的实际动作（`bodies`）。
///
/// 为什么要有这个文件：19 颗一次性 fixup 以前平铺在 `MixCutApp.init` 里，
/// "跑过没有"散在十来颗 `didXxx_v1` 键上，执行顺序只写在注释里靠人记 —— 于是没人能回答
/// "前一颗失败后，后面那些还跑不跑"。删文件的孤儿 GC 就挂在 `recoverFromDisk` 后面，
/// 而那颗当时是 `try? save()` + 无条件写成功键（见 `recoverFromDisk` 的改动说明）。
///
/// **本轮刻意只搬"判定"，不搬"记账"**（裁定：`UserDefaults` 仍是真源）：
/// - executor 只**读** `didXxx_v1` 与 `lastOrphanGCAt` 来出 verdict，不写任何键；
/// - 12 颗 `once` 的 body 仍在自己写键，搬一颗摘一颗，每搬一颗跑一次启动。
/// 若现在就由 executor 统一写键，异步那颗（缩略图重生）会把"只是排上了队"记成"已成功"，
/// 直接违反 `LaunchStepLedger` 顶部那条契约。
///
/// `onFailure` 与 `requires` 的分工要说清楚，免得后人误读：真正拦住后续的是 **`requires`**
/// （前序没进 `succeededThisLaunch` ⇒ `blocked`）；`onFailure` 声明的是失败的严重档，
/// 决定日志等级与"这颗值不值得让后续停"。
@MainActor
enum LaunchPlan {

    /// 清单顺序**即执行顺序**，与改造前 `MixCutApp.init` 里的调用顺序逐颗一致。
    /// 改这里就是改启动行为，只能一颗一颗动。
    static let steps: [LaunchStep] = [
        // 库里存的绝对路径必须赶在任何"拿路径当文件在不在依据"的步骤之前改写干净。
        // 它现在会**如实报失败**（读表失败 / 存盘失败 / 有值以旧前缀开头却没被改写），
        // 所以孤儿 GC 可以直接把它挂成前序 —— 未改写完就跑 GC，等于把在用素材判成孤儿删掉。
        LaunchStep(id: "rewriteStoredPathPrefixes", cadence: .everyLaunch, onFailure: .haltChain),

        LaunchStep(id: "removeQuarantine", cadence: .everyLaunch, onFailure: .continueWithWarning),
        LaunchStep(id: "migrateWhisperModels", cadence: .everyLaunch, onFailure: .continueWithWarning),

        LaunchStep(id: "fixMissingSemanticTypes", cadence: .once(key: "didFixMissingSemanticTypes_v1"),
                   onFailure: .continueWithWarning),
        // 按注册表 + 特征回填自建分镜标记：误启动旧版会把列删掉重建，所以每启动都要自愈，不是 once。
        LaunchStep(id: "restoreSelfBuiltFlags", cadence: .everyLaunch, onFailure: .continueWithWarning),

        LaunchStep(id: "purgeLegacyQwenDubs", cadence: .once(key: "didPurgeLegacyQwenDubs_v1"),
                   onFailure: .continueWithWarning),
        LaunchStep(id: "purgeLongRefClones", cadence: .once(key: "didPurgeLongRefClones_v1"),
                   onFailure: .continueWithWarning),
        LaunchStep(id: "resetSchemeDubSelection", cadence: .once(key: "didResetSchemeDubSelection_v1"),
                   onFailure: .continueWithWarning),
        LaunchStep(id: "cleanExistingTranscripts", cadence: .once(key: "didCleanTranscripts_v1"),
                   onFailure: .continueWithWarning),
        LaunchStep(id: "backfillSegmentFrames", cadence: .once(key: "didBackfillSegmentFrames_v1"),
                   onFailure: .continueWithWarning),
        LaunchStep(id: "migrateToProjectVideoRelation", cadence: .once(key: "didMigrateProjectVideo_v1"),
                   onFailure: .continueWithWarning),

        // 从磁盘恢复丢失的项目/视频：恢复出来的行要落库，GC 才知道那些文件不是孤儿。
        LaunchStep(id: "recoverFromDisk", cadence: .once(key: "didRecoverFromDisk_v1"),
                   requires: ["rewriteStoredPathPrefixes"], onFailure: .haltChain),
        // 恢复路径也会创建关联行 ⇒ 去重必须排在恢复之后（`check_association_guards.sh` TC-19f 钉这条序）
        LaunchStep(id: "dedupProjectVideoAssociations", cadence: .once(key: "didDedupProjectVideoAssociations_v1"),
                   requires: ["recoverFromDisk"], onFailure: .haltChain),

        LaunchStep(id: "resetStaleAnalyzingStatus", cadence: .everyLaunch, onFailure: .continueWithWarning),
        LaunchStep(id: "ensureCustomGroupStrategy", cadence: .once(key: "didEnsureCustomGroupStrategy_v1"),
                   onFailure: .continueWithWarning),
        // 产品/来源归属回填。ownerProject 按最早 ProjectVideo 选项目，必须在去重之后跑，
        // 否则可能回填到将被删掉的重复关联（dedup 是 once，历史成功也算依赖满足）。
        LaunchStep(id: "backfillProductOwnership",
                   cadence: .once(key: "didBackfillProductOwnership_v1"),
                   requires: ["dedupProjectVideoAssociations"],
                   onFailure: .continueWithWarning),
        // 后台一次性重生缩略图。账本此刻**看不到它的成败**（异步），
        // 所以它不进任何前序；将来要收口就把它改成"排上队"与"跑完了"两颗。
        LaunchStep(id: "regenerateSegmentThumbnails", cadence: .once(key: "didRegenerateSegmentThumbnailsToFirstFrame_v1"),
                   onFailure: .continueWithWarning),
        LaunchStep(id: "migrateGlobalSubtitleFontRatio", cadence: .once(key: "didMigrateSubtitleFontRatioToSegment_v1"),
                   onFailure: .continueWithWarning),

        // ⚠️ 删文件的两颗。GC 的未引用判据是"库内引用集合"，所以三条前序少任何一条都可能判错。
        LaunchStep(id: "orphanGC", cadence: .throttled(key: "lastOrphanGCAt", hours: 24),
                   requires: ["rewriteStoredPathPrefixes", "recoverFromDisk", "dedupProjectVideoAssociations"],
                   onFailure: .continueWithWarning),
        LaunchStep(id: "purgeStaleTempFiles", cadence: .everyLaunch, onFailure: .continueWithWarning),
    ]

    /// 每颗的实际动作。返回值 `true` = **这颗这次没有报告失败**（不是"做了改动"）。
    ///
    /// 目前只有三颗有真信号（路径改写 / 恢复 / 去重），其余的 body 内部仍各自吞错，
    /// 一律回 `true`。这必须写成这样而不是假装都会失败：`requires` 只在有真信号的边上才有效。
    static let bodies: [String: (ModelContainer) -> Bool] = [
        "rewriteStoredPathPrefixes": { MixCutApp.rewriteStoredPathPrefixes(container: $0) },
        "removeQuarantine": { _ in MixCutApp.removeQuarantineFromBundleBinaries(); return true },
        "migrateWhisperModels": { _ in FileHelper.migrateWhisperModelsToAppSupport(); return true },
        "fixMissingSemanticTypes": { MixCutApp.fixMissingSemanticTypes(container: $0); return true },
        "restoreSelfBuiltFlags": { MixCutApp.restoreSelfBuiltFlags(container: $0); return true },
        "purgeLegacyQwenDubs": { MixCutApp.purgeLegacyQwenDubs(container: $0) },
        "purgeLongRefClones": { MixCutApp.purgeLongRefClones(container: $0) },
        "resetSchemeDubSelection": { MixCutApp.resetSchemeDubSelectionToOriginal(container: $0) },
        "cleanExistingTranscripts": { MixCutApp.cleanExistingTranscripts(container: $0) },
        "backfillSegmentFrames": { MixCutApp.backfillSegmentFrames(container: $0) },
        "migrateToProjectVideoRelation": { MixCutApp.migrateToProjectVideoRelation(container: $0) },
        "recoverFromDisk": { MixCutApp.recoverFromDisk(container: $0) },
        "dedupProjectVideoAssociations": { MixCutApp.dedupProjectVideoAssociations(container: $0) },
        "resetStaleAnalyzingStatus": { MixCutApp.resetStaleAnalyzingStatus(container: $0); return true },
        "ensureCustomGroupStrategy": { MixCutApp.ensureCustomGroupStrategy(container: $0) },
        "backfillProductOwnership": { MixCutApp.backfillProductOwnership(container: $0); return true },
        "regenerateSegmentThumbnails": { container in
            Task { await MixCutApp.regenerateSegmentThumbnailsToFirstFrame(container: container) }
            return true
        },
        "migrateGlobalSubtitleFontRatio": { MixCutApp.migrateGlobalSubtitleFontRatio(container: $0); return true },
        "orphanGC": { MixCutApp.scheduleOrphanGCIfDue(container: $0); return true },
        "purgeStaleTempFiles": { _ in MixCutApp.purgeStaleTempFiles(); return true },
    ]

    /// 按清单跑完这一轮。**开库成功之后**才允许调用 —— 门拦住或降级时一行都不该走。
    static func run(container: ModelContainer) {
        let problems = validateLaunchPlan(steps)
        if !problems.isEmpty {
            // 拼错的 id / 重复 id / 依赖排在后面 —— 全是装配错误。
            // DEBUG 当场炸；Release 不炸进程，但**整轮清单作废**（不是跳过那一颗）：
            // 清单不可信时继续跑，就等于回到"顺序靠人记"那个被这次改造换掉的根因。
            MixLog.error("[LaunchLedger] 清单装配错误，本次启动不跑任何步骤：\(problems.joined(separator: "；"))")
            #if DEBUG
            fatalError("启动清单装配错误：\(problems.joined(separator: "；"))")
            #endif
            return
        }

        var state = ledgerState()
        var succeeded: Set<String> = []
        let now = Date()
        var ran = 0
        var alreadyDone = 0
        var notYetDue = 0
        var blockedCount = 0

        for step in steps {
            switch decideStep(step, in: steps, state: state, succeededThisLaunch: succeeded, now: now) {
            case .run:
                guard let body = bodies[step.id] else {
                    // 清单里有、动作里没有：validateLaunchPlan 管不到 bodies，所以这里补一道。
                    // 静默跳过一颗迁移比崩溃更糟，直接判这一轮不可信。
                    MixLog.error("[LaunchLedger] \(step.id) 在清单里但没有动作 —— 本次不跑后续步骤")
                    return
                }
                ran += 1
                if body(container) {
                    succeeded.insert(step.id)
                } else {
                    switch step.onFailure {
                    case .haltChain:
                        MixLog.error("[LaunchLedger] \(step.id) 失败，依赖它的所有步骤本次被拦住")
                    case .continueWithWarning:
                        MixLog.error("[LaunchLedger] \(step.id) 失败，继续后续步骤")
                    }
                }
            case .blocked(let missing):
                blockedCount += 1
                MixLog.error("[LaunchLedger] \(step.id) 未跑：前序未成功 \(missing.joined(separator: ", "))")
            case .skipAlreadyDone:
                alreadyDone += 1
            case .skipNotYetDue:
                // 单独记一行：`scheduleOrphanGCIfDue` 里那句"跳过原因必须留在日志里"的纪律，
                // 在账本接管判定之后由这里接手 —— 否则节流一生效，GC 为什么没跑就又没人能回答了。
                notYetDue += 1
                MixLog.info("[LaunchLedger] \(step.id) 未到节流间隔，本次跳过")
            }
        }
        MixLog.info("[LaunchLedger] 本轮 \(steps.count) 颗：跑 \(ran) / 已记账 \(alreadyDone) / 未到期 \(notYetDue) / 被拦 \(blockedCount)")
    }

    /// 真源是 `UserDefaults`（裁定）：`once` 读布尔键，`throttled` 读 `Date` 键。
    /// sidecar 里那份 `doneSteps`/`lastRunAt` 只是镜像，不参与判定。
    private static func ledgerState() -> LedgerState {
        let defaults = UserDefaults.standard
        var done: Set<String> = []
        var lastRun: [String: Date] = [:]
        for step in steps {
            switch step.cadence {
            case .once(let key):
                if defaults.bool(forKey: key) { done.insert(key) }
            case .throttled(let key, _):
                // 这颗键是 **unix 时间戳的 Double**（`scheduleOrphanGCIfDue` 一直是这么写的），
                // 不是 Date。读错类型会让账本判成"从没跑过"，GC 于是每次启动都跑 —— 那正是
                // 当初加节流要治的冷启动拖慢。
                let stamp = defaults.double(forKey: key)
                if stamp > 0 { lastRun[key] = Date(timeIntervalSince1970: stamp) }
            case .everyLaunch:
                break
            }
        }
        return LedgerState(doneKeys: done, lastRunAt: lastRun)
    }
}

/// 容器**之前**那一段的名册。与 `LaunchPlan.steps` 分列的唯一理由是签名：这一段还拿不到
/// `ModelContainer`（`LaunchPlan.run(container:)` 要求已有容器），结构上进不去那张清单。
///
/// **分界**（同时写进 `CLAUDE.md`，免得"两个真源"变成"两处各说一套"）：
/// · 容器**之后**的启动顺序，真源只有 `LaunchPlan.steps`；
/// · 容器**之前**的启动顺序，真源只有下面这张 `PreContainerPlan.steps`。
///
/// 顺序**即 `MixCutApp.init` 里的实际调用次序**，由 `check_schema_ledger_guards.sh` SL-15 逐颗
/// 按 `marker` 定位核对：漏一颗、换次序、或往"门之后 open 之前"塞一步 SQL 写盘，都会变红。
///
/// 这里刻意**不配 executor**（与 `LaunchPlan` 不同）：这一段每颗的失败处置都不一样 —— 门拦住要画面板
/// 并 `return`、修复失败只记日志继续、开库失败要降级内存，压成一种驱动语义反而把差别抹平。
/// 真正拦住了"修库跑在门之前"的也不是这张名册，而是类型：**`GatePermit` 只有
/// `SchemaGuard.evaluate` 造得出（`init` 是 fileprivate）**，所以那一格是编译错误。
/// 名册管的是另一格 —— 别的步骤别在这段偷偷写盘。
enum PreContainerPlan {

    /// `marker` 是 `MixCutApp.init` 里那一颗的**逐字**调用式。改调用写法必须同时改这里，
    /// 判据当场红是对的：那正是"两处各写一遍"要防的漂移。
    struct Step {
        let id: String
        let requires: [String]
        /// 会不会往库里写（SQL 级）。`true` ⇒ 必须排在 `schemaGate` 之后、且只能持 `GatePermit` 调用。
        /// 整档 copy 不算写库（不改已有内容），所以搬迁那颗是 `false`。
        let writesIntoStore: Bool
        let marker: String
    }

    static let steps: [Step] = [
        // 旧共享库 → 专属库的一次性搬迁：专属库已存在就直接跳过，从不改动已存在的库。
        Step(id: "migrateDefaultStore", requires: [], writesIntoStore: false,
             marker: "Self.migrateDefaultStoreToDedicated()"),
        // 门：算指纹、比账本、分类变更，必要时生成**且校验**改前备份；发通行证，但不建容器。
        Step(id: "schemaGate", requires: ["migrateDefaultStore"], writesIntoStore: false,
             marker: "SchemaGuard.evaluate(schema: schema, storeURL: storeURL)"),
        // 全段唯一被授权写库的一颗，必须持门发的通行证（详见 `DanglingEdgeRepair` 的说明）。
        Step(id: "danglingEdgeRepair", requires: ["schemaGate"], writesIntoStore: true,
             marker: "DanglingEdgeRepair.run(at: storeURL, permit: permit)"),
        // 真的建容器、写账本、裁剪备份。
        Step(id: "openStore", requires: ["schemaGate", "danglingEdgeRepair"], writesIntoStore: false,
             marker: "SchemaGuard.open(permit: permit, schema: schema)"),
    ]
}
