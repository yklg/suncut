import Foundation

/// 撤销宽限事务的相位。
///
/// `armed` 是**浮条该不该在屏上的唯一判据** —— 这条不变量就是本类型存在的全部理由。
/// 现状（2026-10-01 之前）是浮条可见性归 `ToastCenter`、事务生命周期归 `PendingDeletionCenter`，
/// 两者只靠"时长取同一个常量"偶然对齐，于是「切项目把事务 flush 掉了、屏上撤销条还活着且可点」
/// 这条路能让 `undo()` 把**已经真删的对象**放回界面。宽限期从 5 秒改成 5 分钟后，
/// 这条路从"几乎撞不到"变成"日常会撞"，所以把不变量搬进类型，而不是在调用处加守卫。
public enum UndoPhase: String, Equatable, Sendable {
    /// 没有事务。
    case idle
    /// 宽限中 —— 只有这一相位浮条可见、「撤销」可点。
    case armed
    /// 用户点了撤销，事务已放回界面。
    case undone
    /// 到点了，真删义务已经交给调用方。
    case expired
    /// 被外部强制了结（切项目 / 数据重载 / 退出）。
    case flushed
}

/// 一枚撤销事务的**状态部分**。
///
/// ⚠️ 闭包（`commit` / `undo`）刻意不放进这里：本类型要能被 `swift test` 直接构造和比较，
/// 而闭包既不可 `Equatable` 也不可 `Sendable` 比较。闭包由 App 侧按 `id` 持有，
/// 谁从状态机手里拿到一枚 ticket，谁才有义务执行它对应的闭包 —— 见各转换方法的返回值。
public struct UndoTicket: Equatable, Identifiable, Sendable {
    /// 事务种类，决定"到点/被 flush 时要不要真删"。
    public enum Kind: String, Equatable, Sendable {
        /// 延迟删除：到点、被顶掉、被 flush 时**必须**执行 commit（真删）。
        case deletion
        /// 批量覆盖（遮挡区/字幕字号应用到所有分镜）：改动已经落库，
        /// 到点无事可做，只有用户主动撤销才回滚。
        case batchOverwrite
    }

    public let id: UUID
    public let kind: Kind
    /// 浮条正文，如「已删除分镜」。
    public let message: String
    /// 按钮文案，如「撤销删除」—— 具名是为了消除"同屏两枚都写着撤销、指向两件事"的歧义。
    public let actionTitle: String
    public let graceSeconds: Double
    public let armedAt: Date

    public init(id: UUID = UUID(), kind: Kind, message: String, actionTitle: String,
                graceSeconds: Double, armedAt: Date) {
        self.id = id
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.graceSeconds = graceSeconds
        self.armedAt = armedAt
    }

    /// 宽限截止时刻。
    public var deadline: Date { armedAt.addingTimeInterval(graceSeconds) }

    /// 到点后是否欠一次真删。
    public var needsCommitOnSettle: Bool { kind == .deletion }
}

/// 用户点「撤销」时，状态机给出的**唯一**结论。
///
/// 三个分支穷尽了"迟到点击"的所有形状：正常撤销、点击时恰好已过期、点击时屏上已不是这枚。
/// 注意 `.tooLate` 带着 commit —— 过期这件事可能正是这次点击触发的（主线程忙、定时器还没跑到），
/// 真删义务不能丢。
public enum UndoDecision: Equatable, Sendable {
    /// 事务仍在宽限内：执行 undo，把隐藏的项放回界面。
    case performUndo(UndoTicket)
    /// 点击时已过期：不许 undo，并补交真删义务（可能为 nil = 批量覆盖类不欠真删）。
    case tooLate(commit: UndoTicket?)
    /// 屏上已不是这枚 ticket（迟到的点击、或已被新事务顶掉、或已了结过）：什么都不做。
    /// 幂等靠这一支保证 —— 每枚 ticket 的真删义务只会被交出去一次。
    case stale
}

/// 撤销宽限事务的纯状态机。
public struct UndoGraceMachine: Equatable, Sendable {
    public private(set) var ticket: UndoTicket?
    public private(set) var phase: UndoPhase = .idle

    public init() {}

    /// 浮条可见 ⟺ `armed`。App 侧渲染撤销槽时**只**读这一个判据。
    public var isStripVisible: Bool { phase == .armed }

    /// 剩余秒数（A5-1 的文字倒计时读它）。非 armed 时为 0。
    public func secondsLeft(now: Date) -> Double {
        guard phase == .armed, let t = ticket else { return 0 }
        return max(0, t.graceSeconds - now.timeIntervalSince(t.armedAt))
    }

    /// 登记新事务。
    /// - Returns: 被顶掉的旧事务；调用方**必须立刻**了结它（`deletion` 类即刻真删）。返回 nil = 之前没挂着的事务。
    ///
    /// 同一时刻只维护一枚 ticket 是既有设计的延续：宽限期拉长到 5 分钟后，
    /// "连删两条"从边角变成常态，所以被顶掉的那条必须在文案里交代（见 `armMessage`），
    /// 不能像现在这样静默消失。
    public mutating func arm(_ next: UndoTicket) -> UndoTicket? {
        let lost = (phase == .armed) ? ticket : nil
        ticket = next
        phase = .armed
        return lost
    }

    /// 用户点「撤销」。只有"当前这枚、仍 armed、且没过期"三者同时成立才执行 undo。
    public mutating func requestUndo(id: UUID, now: Date) -> UndoDecision {
        guard phase == .armed, let current = ticket, current.id == id else { return .stale }
        if now < current.deadline {
            phase = .undone
            return .performUndo(current)
        }
        phase = .expired
        return .tooLate(commit: current.needsCommitOnSettle ? current : nil)
    }

    /// 计时到期。只有这张 ticket 仍是当前 armed 的那枚才生效。
    /// - Returns: 需要真删的事务；批量覆盖类返回 nil。**重复调用返回 nil**（义务只交一次）。
    public mutating func expire(id: UUID, now: Date) -> UndoTicket? {
        guard phase == .armed, let current = ticket, current.id == id, now >= current.deadline else { return nil }
        phase = .expired
        return current.needsCommitOnSettle ? current : nil
    }

    /// 外部强制了结（切项目 / 数据重载 / 退出）。
    /// - Parameter id: 传 nil = 了结当前那枚；传具体 id = 只了结那一枚（迟到的旧定时器不该顺手清掉新事务）。
    /// - Returns: 需要真删的事务；批量覆盖类或已了结过的返回 nil。
    public mutating func flush(id: UUID? = nil) -> UndoTicket? {
        guard phase == .armed, let current = ticket, id == nil || id == current.id else { return nil }
        phase = .flushed
        return current.needsCommitOnSettle ? current : nil
    }

    /// 顶掉旧事务时，新浮条要替旧的那条交代一句 —— 否则"前一条已即刻真删"在界面上完全不可见。
    public static func armMessage(lost: UndoTicket?, next: UndoTicket) -> String {
        guard let lost else { return next.message }
        switch lost.kind {
        case .deletion:
            return "\(next.message)（上一条「\(lost.message)」已确认删除）"
        case .batchOverwrite:
            return "\(next.message)（上一条「\(lost.message)」已生效）"
        }
    }
}
