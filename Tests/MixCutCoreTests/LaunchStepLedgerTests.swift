import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 批 0 · 0-A 启动步骤账本的判据用例（LL-01~07 + 优先级与顺序无关两条）
//
// 本文件锁定的接口：
//   enum StepCadence { once(key:), everyLaunch, throttled(key:hours:) ; var ledgerKey: String? }
//   enum StepFailure { haltChain, continueWithWarning }
//   struct LaunchStep { id, cadence, requires, onFailure }
//   enum StepVerdict { run, skipAlreadyDone, skipNotYetDue, blocked(missing:) }
//   struct LedgerState { doneKeys, lastRunAt }
//   func decideStep(_:in:state:succeededThisLaunch:now:) -> StepVerdict
//   func validateLaunchPlan(_) -> [String]
//   func downstreamOfHalt(failedID:in:) -> Set<String>
//
// 规则：
//   R1 `blocked` 优先于一切节律判定 —— 前序没成就别谈"要不要跑"，尤其别谈"要不要删文件"。
//      反过来写会让"已跑过的 GC"在前序失败时判成 skip*，结论相同但**归因错了**，日志里看不出是前序挂了。
//   R2 依赖"已成功"的口径：本次成功（在 succeededThisLaunch 里），或它是 `once` 且历史上成功过
//      （键在 doneKeys 里）。`everyLaunch` / `throttled` 的前序**不许跨启动继承** ——
//      那会把"上次崩在中途"当成成功。
//   R3 `haltChain` 失败才向传递闭包扩散（含间接依赖）；`continueWithWarning` 不拦后面。
//   R4 `validateLaunchPlan` 抓四种装配错误：id 重复 / 自依赖 / requires 指向不存在的 id /
//      依赖排在后面（数组顺序即执行顺序）。合法清单必须返回空 —— 正向对照，防这条判据恒真。
//   R5 `throttled` 的到点判定用 `>=`，三点法钉住边界。
//   R6 `blocked.missing` 必须排序 ⇒ `requires` 列表内部顺序不许影响结论。
//
// ⚠️ 契约（App 侧必须配合，本文件测不到）：`doneKeys` **只在步骤成功时才写**。
// 无条件写 done 会让 R1/R2 的语义整体失真 —— 这条挂在 §3.6 的克隆库实测与 0-C 守卫上。
// ============================================================================

private let t0 = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01T00:00:00Z

/// 形状照抄现网启动链的关键段：开库 → 前缀改写 → 磁盘恢复 → 关联去重 → 孤儿 GC。
/// 注释里那三条"必须排在…之前/之后"的约束（`MixCutApp.swift:23-24,58-59,68-69`）在这里变成数据。
private let chain: [LaunchStep] = [
    LaunchStep(id: "openStore", cadence: .everyLaunch, onFailure: .haltChain),
    LaunchStep(id: "rewritePrefixes", cadence: .everyLaunch, requires: ["openStore"], onFailure: .haltChain),
    LaunchStep(id: "recoverFromDisk", cadence: .once(key: "didRecoverFromDisk_v1"),
               requires: ["rewritePrefixes"], onFailure: .haltChain),
    LaunchStep(id: "dedupAssociations", cadence: .once(key: "didDedupProjectVideoAssociations_v1"),
               requires: ["recoverFromDisk"], onFailure: .haltChain),
    LaunchStep(id: "thumbnailRegen", cadence: .once(key: "didRegenerateSegmentThumbnailsToFirstFrame_v1"),
               requires: ["openStore"], onFailure: .continueWithWarning),
    LaunchStep(id: "orphanGC", cadence: .throttled(key: "lastOrphanGCAt", hours: 24),
               requires: ["recoverFromDisk", "dedupAssociations"], onFailure: .continueWithWarning),
]

private func step(_ id: String) -> LaunchStep { chain.first { $0.id == id }! }

@Test("LL-01 前序未成功 ⇒ 删文件类步骤判 blocked，不许跑")
func blockedWhenPredecessorHasNotSucceeded() {
    // 只成功跑了 openStore：rewritePrefixes 没成 ⇒ recoverFromDisk 及其下游全拦
    let verdict = decideStep(step("recoverFromDisk"), in: chain, state: LedgerState(),
                             succeededThisLaunch: ["openStore"], now: t0)
    #expect(verdict == .blocked(missing: ["rewritePrefixes"]))

    // GC 依赖的两颗都没成 ⇒ 拦，且列出的是缺失集
    let gc = decideStep(step("orphanGC"), in: chain, state: LedgerState(),
                        succeededThisLaunch: ["openStore"], now: t0)
    #expect(gc == .blocked(missing: ["dedupAssociations", "recoverFromDisk"]))
}

@Test("LL-01b 正向对照：前序真成功 ⇒ 同一颗判 run（否则 R1 会变成永远拦）")
func runsWhenPredecessorsSucceeded() {
    let verdict = decideStep(step("recoverFromDisk"), in: chain, state: LedgerState(),
                             succeededThisLaunch: ["openStore", "rewritePrefixes"], now: t0)
    #expect(verdict == .run)
}

@Test("LL-02 装配错误四种都抓得住，合法清单必须返回空")
func validateLaunchPlanCatchesAssemblyErrors() {
    #expect(validateLaunchPlan(chain).isEmpty)      // 正向对照

    let unknownDep = [LaunchStep(id: "a", cadence: .everyLaunch, onFailure: .haltChain),
                      LaunchStep(id: "b", cadence: .everyLaunch, requires: ["aX"], onFailure: .haltChain)]
    #expect(validateLaunchPlan(unknownDep).contains("b 的 requires 指向不存在的步骤：aX"))

    let duplicated = [LaunchStep(id: "a", cadence: .everyLaunch, onFailure: .haltChain),
                      LaunchStep(id: "a", cadence: .everyLaunch, onFailure: .haltChain)]
    #expect(validateLaunchPlan(duplicated).contains("id 重复：a"))

    let selfDep = [LaunchStep(id: "a", cadence: .everyLaunch, requires: ["a"], onFailure: .haltChain)]
    #expect(validateLaunchPlan(selfDep).contains("a 依赖自己"))

    let reversed = [LaunchStep(id: "first", cadence: .everyLaunch, requires: ["second"], onFailure: .haltChain),
                    LaunchStep(id: "second", cadence: .everyLaunch, onFailure: .haltChain)]
    #expect(validateLaunchPlan(reversed).contains("first 的依赖 second 排在后面 —— 数组顺序即执行顺序"))
}

@Test("LL-03 once 幂等：跑过的键不再跑，重复判定结论不变")
func onceIsIdempotent() {
    let state = LedgerState(doneKeys: ["didRecoverFromDisk_v1"])
    let succeeded: Set<String> = ["openStore", "rewritePrefixes"]

    let first = decideStep(step("recoverFromDisk"), in: chain, state: state, succeededThisLaunch: succeeded, now: t0)
    let again = decideStep(step("recoverFromDisk"), in: chain, state: state, succeededThisLaunch: succeeded, now: t0)
    #expect(first == .skipAlreadyDone)
    #expect(again == first)
}

@Test("LL-05 throttled 三点法：23:59:59 不跑、整 24h 跑、24:01 跑")
func throttledBoundaryThreePoints() {
    let state = LedgerState(lastRunAt: ["lastOrphanGCAt": t0])
    let succeeded: Set<String> = ["openStore", "rewritePrefixes", "recoverFromDisk", "dedupAssociations"]
    func verdictAt(_ offset: TimeInterval) -> StepVerdict {
        decideStep(step("orphanGC"), in: chain, state: state, succeededThisLaunch: succeeded,
                   now: t0.addingTimeInterval(offset))
    }
    #expect(verdictAt(24 * 3600 - 1) == .skipNotYetDue)
    #expect(verdictAt(24 * 3600) == .run)
    #expect(verdictAt(24 * 3600 + 60) == .run)
    // 从未跑过 ⇒ 没有上次时间戳，该跑
    #expect(decideStep(step("orphanGC"), in: chain, state: LedgerState(),
                       succeededThisLaunch: succeeded, now: t0) == .run)
}

@Test("LL-06 haltChain 向传递闭包扩散（含间接依赖），非依赖方照常")
func haltClosesOverTransitiveDownstream() {
    let halted = downstreamOfHalt(failedID: "recoverFromDisk", in: chain)
    #expect(halted == ["recoverFromDisk", "dedupAssociations", "orphanGC"])   // 间接依赖也算
    #expect(!halted.contains("thumbnailRegen"))                               // 它只依赖 openStore

    // continueWithWarning 的失败者不拦后面
    #expect(downstreamOfHalt(failedID: "thumbnailRegen", in: chain) == [])
    #expect(downstreamOfHalt(failedID: "orphanGC", in: chain) == [])
    // 查不到的 id ⇒ 空集，不炸
    #expect(downstreamOfHalt(failedID: "nope", in: chain) == [])
}

@Test("LL-07 口径钉死：once 前序跨启动满足；everyLaunch 前序本次没成就算未满足")
func onceDepInheritsButEveryLaunchDoesNot() {
    let state = LedgerState(doneKeys: ["didRecoverFromDisk_v1", "lastOrphanGCAt"])

    // recoverFromDisk 是 once 且已记成功 ⇒ dedup 的依赖满足，进入节律判定（它自己没键 ⇒ run）
    #expect(decideStep(step("dedupAssociations"), in: chain, state: state,
                       succeededThisLaunch: [], now: t0) == .run)

    // rewritePrefixes 是 everyLaunch：doneKeys 里塞什么都没用，本次没成功就是没成功
    let stateWithBogusKey = LedgerState(doneKeys: ["didRewritePrefixes_v1"])
    #expect(decideStep(step("rewritePrefixes"), in: chain, state: stateWithBogusKey,
                       succeededThisLaunch: ["openStore"], now: t0) == .run)
    #expect(decideStep(step("recoverFromDisk"), in: chain, state: LedgerState(),
                       succeededThisLaunch: ["openStore"], now: t0)
        == .blocked(missing: ["rewritePrefixes"]))
}

@Test("R1 优先级：blocked 先于 skipAlreadyDone / skipNotYetDue，归因不许丢")
func blockedBeatsEverySkip() {
    // once 已跑过 + 前序失败 ⇒ 必须报 blocked（不是 skipAlreadyDone）
    let onceDoneButBlocked = decideStep(step("recoverFromDisk"), in: chain,
                                        state: LedgerState(doneKeys: ["didRecoverFromDisk_v1"]),
                                        succeededThisLaunch: [], now: t0)
    #expect(onceDoneButBlocked == .blocked(missing: ["rewritePrefixes"]))

    // throttled 未到点 + 前序失败 ⇒ 必须报 blocked（不是 skipNotYetDue）
    let dueButBlocked = decideStep(step("orphanGC"), in: chain,
                                   state: LedgerState(lastRunAt: ["lastOrphanGCAt": t0]),
                                   succeededThisLaunch: [], now: t0)
    #expect(dueButBlocked == .blocked(missing: ["dedupAssociations", "recoverFromDisk"]))
}

@Test("R6 requires 内部顺序不许影响结论，missing 必须排序")
func missingSetIsSorted() {
    let shuffledDeps = LaunchStep(id: "orphanGC", cadence: .throttled(key: "lastOrphanGCAt", hours: 24),
                                  requires: ["dedupAssociations", "recoverFromDisk"], onFailure: .continueWithWarning)
    let a = decideStep(shuffledDeps, in: chain, state: LedgerState(), succeededThisLaunch: [], now: t0)
    let b = decideStep(step("orphanGC"), in: chain, state: LedgerState(), succeededThisLaunch: [], now: t0)
    #expect(a == b)
    if case .blocked(let missing) = a {
        #expect(missing == missing.sorted())
    } else {
        Issue.record("应判 blocked，实得 \(a)")
    }
}

@Test("ledgerKey 三档各归位（App 侧写账本要靠它）")
func ledgerKeyMapping() {
    #expect(StepCadence.once(key: "k1").ledgerKey == "k1")
    #expect(StepCadence.throttled(key: "k2", hours: 24).ledgerKey == "k2")
    #expect(StepCadence.everyLaunch.ledgerKey == nil)
}
