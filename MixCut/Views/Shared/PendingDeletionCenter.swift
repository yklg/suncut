import SwiftUI

/// 撤销事务中心 —— 商业 to C 软件的「撤销浮条」模式（剪映 / Gmail「撤回」同款）。
///
/// 两类事务走同一条通道（`UndoGraceMachine` 是唯一的判据来源）：
/// - **延迟删除**（`schedule`）：调用方先在**界面上隐藏**该项，登记一对
///   `commit`（真正落库删除）/ `undo`（放回界面）。到点、被顶掉、被 flush → 执行 commit；点撤销 → 执行 undo。
/// - **批量覆盖**（`scheduleUndoOnly`）：改动已落库，只登记 `undo`，到点什么都不做。
///
/// 关键：**永不依赖 SwiftData 内置 UndoManager**（它一挂删除就崩）。恢复是「放回」而非「重建」，
/// 因为宽限期内对象根本没被真删，最可靠。
///
/// ⚠️ 本类型是撤销浮条**可见性的唯一主人**：`visibleTicket` 只在状态机 `armed` 时有值。
/// 浮条显示时长与事务存活时长因此天然相等 —— 以前浮条归 `ToastCenter` 管、事务归自己管，
/// 「切项目把事务 flush 掉了、屏上撤销条还活着且可点」会让 `undo()` 把已真删对象放回界面。
/// 撤销条也不再经由 `ToastCenter` 上屏，所以普通提示顶不掉它（宽限期 5 分钟才有意义）。
///
/// 同一时刻只维护一个 pending：新事务登记前会先把上一个 `settle`（删除类即刻真删），
/// 并在**新浮条文案里交代**旧的那条已怎么着了，避免静默消失；切项目 / 数据重载前一律 `flushNow()`，
/// 避免「界面隐藏但数据库未删」在重载后又冒出来。
@MainActor
@Observable
final class PendingDeletionCenter {
    static let shared = PendingDeletionCenter()
    private init() {}

    /// 宽限期秒数（撤销浮条停留时长 + 真删延迟）。5 秒时撤销条几乎必然被别的提示顶掉，
    /// 拆出专用槽位后才有意义，故按 1.3 的要求拉到 5 分钟。
    static let graceSeconds: Double = 300

    /// 倒计时刷新间隔（秒）。0.2s 足够让 mm:ss 读数不跳秒、又不至于每帧重绘。
    static let tickerInterval: Double = 0.2

    // MARK: 视图读的投影（只有 armed 时非空）

    /// 当前挂在屏上的撤销事务。nil = 撤销槽不渲染。
    private(set) var visibleTicket: UndoTicket?
    /// 浮条正文（含「上一条已确认删除」的交代）。
    private(set) var stripMessage: String = ""
    /// 剩余秒数，供 A5-1 的文字倒计时。
    private(set) var secondsLeft: Double = 0

    @ObservationIgnored private var machine = UndoGraceMachine()
    @ObservationIgnored private var commits: [UUID: () -> Void] = [:]
    @ObservationIgnored private var undos: [UUID: () -> Void] = [:]
    @ObservationIgnored private var tickerTask: Task<Void, Never>?

    /// 登记一次延迟删除。调用方需在调用前已把该项从界面隐藏。
    /// - Parameters:
    ///   - message: 浮条文案（如「已删除分镜」）
    ///   - commit: 宽限期结束、被顶掉或被 flush 时执行——真正 `context.delete` + 保存
    ///   - undo: 点「撤销」时执行——把隐藏的项放回界面
    func schedule(message: String, commit: @escaping () -> Void, undo: @escaping () -> Void) {
        arm(UndoTicket(kind: .deletion, message: message, actionTitle: "撤销删除",
                       graceSeconds: Self.graceSeconds, armedAt: Date()),
            commit: commit, undo: undo)
    }

    /// 登记一次「只可撤销」的批量覆盖（遮挡区 / 字幕字号应用到所有分镜）。
    /// 这类改动当场已落库，所以没有真删义务：到点只是浮条收回。
    func scheduleUndoOnly(message: String, actionTitle: String, seconds: Double,
                          undo: @escaping () -> Void) {
        arm(UndoTicket(kind: .batchOverwrite, message: message, actionTitle: actionTitle,
                       graceSeconds: seconds, armedAt: Date()),
            commit: nil, undo: undo)
    }

    private func arm(_ ticket: UndoTicket, commit: (() -> Void)?, undo: @escaping () -> Void) {
        // 顶掉上一枚：先把它了结（删除类即刻真删），再登记新的，顺序不能反 ——
        // 反过来会让上一枚的 commit 在新事务的闭包表里被误清。
        let lost = machine.arm(ticket)
        if let lost { settle(lost) }

        commits[ticket.id] = commit
        undos[ticket.id] = undo
        stripMessage = UndoGraceMachine.armMessage(lost: lost, next: ticket)
        publish()
        startTicker(for: ticket)
    }

    /// 点「撤销」。三分支由 `UndoDecision` 穷尽，迟到的点击不会执行 undo。
    func undoTapped() {
        guard let ticket = machine.ticket else { return }
        switch machine.requestUndo(id: ticket.id, now: Date()) {
        case .performUndo:
            tickerTask?.cancel()
            tickerTask = nil
            undos[ticket.id]?()
            dropClosures(for: ticket.id)
            publish()
        case .tooLate(let owed):
            // 点的时候恰好已过期（主线程忙、定时器还没跑到）：不撤销，补真删。
            finish(owed: owed, id: ticket.id)
        case .stale:
            publish()
        }
    }

    /// 立即了结当前事务（真正删除）。在切项目 / 数据重载 / 退出前调用，
    /// 避免「界面已隐藏但数据库未删」在重载后又显示出来。无 pending 时是空操作。
    func flushNow() {
        guard let ticket = machine.ticket else { return }
        finish(owed: machine.flush(id: ticket.id), id: ticket.id)
    }

    private func finish(owed: UndoTicket?, id: UUID) {
        tickerTask?.cancel()
        tickerTask = nil
        if let owed { commits[owed.id]?() }
        dropClosures(for: id)
        publish()
    }

    /// 被新事务顶掉时的了结：只补真删，**不动定时器**（新的那枚正在用）。
    private func settle(_ lost: UndoTicket) {
        if lost.needsCommitOnSettle { commits[lost.id]?() }
        dropClosures(for: lost.id)
    }

    private func dropClosures(for id: UUID) {
        commits[id] = nil
        undos[id] = nil
    }

    /// 单一计时循环：每 0.2s 刷一次剩余秒数，到点自行 expire。
    /// 不再另起一条"真删定时器"——两条独立定时器正是过去显示与事务能各自走开的原因。
    private func startTicker(for ticket: UndoTicket) {
        tickerTask?.cancel()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.tickerInterval * 1_000_000_000))
                } catch {
                    return   // 被取消：新事务或了结已接管
                }
                guard let self, !Task.isCancelled else { return }
                guard self.machine.ticket?.id == ticket.id else { return }
                if Date() >= ticket.deadline {
                    self.finish(owed: self.machine.expire(id: ticket.id, now: Date()), id: ticket.id)
                    return
                }
                self.secondsLeft = self.machine.secondsLeft(now: Date())
            }
        }
    }

    /// 把状态机投影到可观察属性。可见性判据只此一处。
    private func publish() {
        if machine.isStripVisible {
            visibleTicket = machine.ticket
            // 登记当帧就要有读数：只等 ticker 第一跳的话，浮条会先闪一下 0:00 再跳到 5:00
            secondsLeft = machine.secondsLeft(now: Date())
        } else {
            visibleTicket = nil
            stripMessage = ""
            secondsLeft = 0
        }
    }
}
