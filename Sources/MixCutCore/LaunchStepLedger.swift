import Foundation

/// 启动链步骤的账本判据 —— "这颗该不该跑、能不能跑"的唯一来源。
///
/// 为什么要有这个类型：本工程的"数据形状变更"一直是**再挂一颗一次性函数 + 再发明一个 bool**，
/// 账本散在十来个 `didXxx_v1` 键里，执行顺序只写在注释里靠人记。后果是每次 schema 出事只能再加一颗，
/// 而没人能回答"这颗失败后，后面那些还跑不跑"。
///
/// 这里把两件事分开：
/// - **判该不该跑**是纯逻辑，住在这里，可 `swift test`（本工程只有 `MixCutCore` 一个可测 target，
///   `swift test` 物理上碰不到 `MixCut/` 里任何一行）；
/// - **跑什么**是 App 侧闭包，不进这里。
///
/// ⚠️ 一条必须与 App 侧共同成立的契约：**`doneKeys` 只在步骤成功时才写**。
/// 若 App 侧无条件写 done，`once` 的"上次已成功"语义就是假的，`blocked` 也会跟着失真。
public enum StepCadence: Equatable, Sendable, Hashable {
    /// 带键的"跑成功过一次就不再跑"。`key` 必须是**现有 `UserDefaults` 键名原样**搬进来 ——
    /// 重命名或重置会让老用户把已跑过的迁移再跑一遍。
    case once(key: String)
    /// 每次启动都跑（幂等自愈类，如按注册表回填标记、清 quarantine 属性）。
    case everyLaunch
    /// 按小时节流（如孤儿 GC：以前每次启动同步跑，直接拖慢冷启动）。
    case throttled(key: String, hours: Double)

    /// 该节律记账用的键。`everyLaunch` 无键 ⇒ 它不参与"跑过没有"的判定。
    public var ledgerKey: String? {
        switch self {
        case .once(let key): return key
        case .throttled(let key, _): return key
        case .everyLaunch: return nil
        }
    }
}

/// 这颗失败时整条链怎么办。**刻意不给默认值** —— 现状是每颗各自吞错，
/// 形式化顺序而不形式化失败传播，等于把最坏路径写进新机制。
public enum StepFailure: Equatable, Sendable {
    /// 停下：后续所有（直接或间接）依赖它的步骤一律判 `blocked`。
    /// 删文件类步骤（GC / 临时件清理）的前序必须是这一档，否则会把还在盘上的素材判成孤儿。
    case haltChain
    /// 记警告后继续：仅适用于"这次没成也不影响后面正确性"的优化型步骤。
    case continueWithWarning
}

/// 一颗启动步骤的声明。
public struct LaunchStep: Equatable, Sendable {

    /// 步骤 id，链内唯一，`requires` 用它引用。
    public let id: String
    public let cadence: StepCadence
    /// 必须先成功的步骤 id。数组顺序即执行顺序，所以这里只允许引用**排在自己前面**的 id。
    public let requires: [String]
    public let onFailure: StepFailure

    public init(id: String, cadence: StepCadence, requires: [String] = [], onFailure: StepFailure) {
        self.id = id
        self.cadence = cadence
        self.requires = requires
        self.onFailure = onFailure
    }
}

/// 单颗步骤的判定结果。四档互斥，且每档对应一个**具体动作**。
public enum StepVerdict: Equatable, Sendable {
    /// 该跑。
    case run
    /// `once` 已有成功记录 ⇒ 不跑。
    case skipAlreadyDone
    /// `throttled` 未到间隔 ⇒ 不跑。
    case skipNotYetDue
    /// 有前序未成功 ⇒ 不跑，且**不许降级成 skip**：这是"别删文件"的档。
    case blocked(missing: [String])
}

/// 账本当前状态。
public struct LedgerState: Equatable, Sendable {

    /// 已成功跑过的节律键。
    public var doneKeys: Set<String>
    /// 各节律键上次执行时间（`throttled` 用）。
    public var lastRunAt: [String: Date]

    public init(doneKeys: Set<String> = [], lastRunAt: [String: Date] = [:]) {
        self.doneKeys = doneKeys
        self.lastRunAt = lastRunAt
    }
}

/// 判定一颗步骤该不该跑。
///
/// 判定顺序是判据的一部分，写死在这里：
/// 1. **先判 `blocked`**（安全档优先）—— 前序没成就别谈"要不要跑"，尤其别谈"要不要删文件"；
/// 2. 再判节律（`once` 已跑过 / `throttled` 未到点）。
/// 反过来写会让"已跑过的 GC"在前序失败时判成 `skipAlreadyDone` —— 结论相同但**归因错了**，
/// 日志里看不出是"前序挂了"，正是最难查的那类静默。
///
/// 前序是否算"已成功"的口径：本次启动成功过（在 `succeededThisLaunch` 里），
/// 或它是 `once` 且历史上成功过（键在 `state.doneKeys` 里）。`everyLaunch` / `throttled` 的前序
/// 必须是本次成功的 —— 跨启动继承会把"上次崩在中途"当成成功。
public func decideStep(
    _ step: LaunchStep,
    in plan: [LaunchStep],
    state: LedgerState,
    succeededThisLaunch: Set<String>,
    now: Date
) -> StepVerdict {
    let missing = step.requires.filter { dependencyIsSatisfied($0, in: plan, state: state, succeededThisLaunch: succeededThisLaunch) == false }
    if !missing.isEmpty { return .blocked(missing: missing.sorted()) }

    switch step.cadence {
    case .once(let key):
        return state.doneKeys.contains(key) ? .skipAlreadyDone : .run
    case .everyLaunch:
        return .run
    case .throttled(let key, let hours):
        guard let last = state.lastRunAt[key] else { return .run }
        return now.timeIntervalSince(last) >= hours * 3600 ? .run : .skipNotYetDue
    }
}

/// 依赖是否已满足。plan 里查不到的 id 一律判"未满足"（`validateOrder` 会另报装配错误）。
private func dependencyIsSatisfied(
    _ dependencyID: String,
    in plan: [LaunchStep],
    state: LedgerState,
    succeededThisLaunch: Set<String>
) -> Bool {
    if succeededThisLaunch.contains(dependencyID) { return true }
    guard let dep = plan.first(where: { $0.id == dependencyID }) else { return false }
    if case .once(let key) = dep.cadence { return state.doneKeys.contains(key) }
    return false
}

/// 清单自身的装配校验。**返回非空即装配错误**，不是警告。
///
/// 为什么这条必须存在：`requires` 是字符串 id，拼错一个字母时那条例外约束就**静默失效** ——
/// 而顺序约束正是这次改造要买的东西。宁可当场炸，不能到用户机器上静默。
public func validateLaunchPlan(_ plan: [LaunchStep]) -> [String] {
    var problems: [String] = []

    var seen: Set<String> = []
    for step in plan where !seen.insert(step.id).inserted {
        problems.append("id 重复：\(step.id)")
    }

    for step in plan {
        for dep in step.requires {
            if dep == step.id {
                problems.append("\(step.id) 依赖自己")
                continue
            }
            guard let index = plan.firstIndex(where: { $0.id == dep }) else {
                problems.append("\(step.id) 的 requires 指向不存在的步骤：\(dep)")
                continue
            }
            if index >= plan.firstIndex(where: { $0.id == step.id })! {
                problems.append("\(step.id) 的依赖 \(dep) 排在后面 —— 数组顺序即执行顺序")
            }
        }
    }

    return problems
}

/// 某颗失败后，哪些步骤应当被连带判 `blocked`（传递闭包，含间接依赖）。
///
/// 只给 `haltChain` 的失败者算闭包；`continueWithWarning` 的前序不拦后面。
public func downstreamOfHalt(
    failedID: String,
    in plan: [LaunchStep]
) -> Set<String> {
    guard let failed = plan.first(where: { $0.id == failedID }), failed.onFailure == .haltChain else { return [] }

    var halted: Set<String> = [failedID]
    var changed = true
    while changed {
        changed = false
        for step in plan where !halted.contains(step.id) {
            if step.requires.contains(where: { halted.contains($0) }) {
                halted.insert(step.id)
                changed = true
            }
        }
    }
    return halted
}
