import SwiftUI

/// 撤销事务中心 —— 商业 to C 软件的「撤销浮条」模式（剪映 / Gmail「撤回」同款）。
///
/// 两类事务走同一条通道（`UndoGraceMachine` 是唯一的判据来源）：
/// - **延迟删除**（`schedule`）：调用方先在**界面上隐藏**该项，登记一对
///   `commit`（真正落库删除，并交回「这次少了哪些 id」）/ `undo`（放回界面）。
///   到点、被顶掉、被 flush → 执行 commit，随后由**本中心**经 `GraphBroadcast` 广播那份台账（前案刀 2：谁删谁广播）；
///   点撤销 → 执行 undo。
/// - **批量覆盖**（`scheduleUndoOnly`）：改动已落库，只登记 `undo`，到点什么都不做。
///
/// 关键：**永不依赖 SwiftData 内置 UndoManager**（它一挂删除就崩）。恢复是「放回」而非「重建」，
/// 因为宽限期内对象根本没被真删，最可靠。
///
/// ⚠️ 本类型是撤销浮条**可见性的唯一主人**：`visibleTicket` 只在状态机 `armed` 时有值。
/// 浮条显示时长与事务存活时长因此天然相等 —— 以前浮条归 `ToastCenter` 管、事务归自己管，
/// 「切项目把事务 flush 掉了、屏上撤销条还活着且可点」会让 `undo()` 把已真删对象放回界面。
/// 撤销条也不再经由 `ToastCenter` 上屏，所以普通提示顶不掉它 —— 宽限期多长都不再是「被顶掉」的问题，
/// 时长本身是纯产品档位（见 `graceSeconds`）。
///
/// 同一时刻只维护一个 pending：新事务登记前会先把上一个 `settle`（删除类即刻真删），
/// 并在**新浮条文案里交代**旧的那条已怎么着了，避免静默消失；切项目 / 数据重载前一律 `flushNow()`，
/// 避免「界面隐藏但数据库未删」在重载后又冒出来。
@MainActor
@Observable
final class PendingDeletionCenter {
    static let shared = PendingDeletionCenter()
    private init() {}

    /// 宽限期秒数（撤销浮条停留时长 + 真删延迟）。一颗数兼这两个职责，改它=同时改「能反悔多久」。
    /// 历史：首版 5 秒 → 1.3（`83ba40b`，2026-10-01）拉到 300，理由是当时撤销条还归 `ToastCenter` 管，
    /// 5 秒内必然被别的提示顶掉。**那半病因已经由专用槽位 `UndoSlot` 治好了**（普通提示顶不掉它），
    /// 所以时长本身可以回到 5 秒 —— 由 2026-10-03 的决定拍板。
    /// ⚠️ 这颗值被 `scripts/check_undo_guards.sh` 的 UG-G04 钉住，改它必须同批改那颗门的期望值与
    /// `selftest_undo_guards.sh` 的 M4 变异方向，否则门会在真仓上红。
    static let graceSeconds: Double = 5

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
    /// 真删义务。**闭包交回「这次图上少了哪些 id」**（`GraphChange`），由本中心在 commit 落地后统一广播 ——
    /// 广播点因此只有两处（`finish` / `settle`），而不是每条删除链各记一遍"别忘了发通知"。
    /// 返回空台账 = 不发广播（保持接入前的原行为，见各调用方的注释）。
    @ObservationIgnored private var commits: [UUID: () -> GraphChange] = [:]
    @ObservationIgnored private var undos: [UUID: () -> Void] = [:]
    @ObservationIgnored private var tickerTask: Task<Void, Never>?

    /// 登记一次延迟删除。调用方需在调用前已把该项从界面隐藏。
    /// - Parameters:
    ///   - message: 浮条文案（如「已删除分镜」）
    ///   - commit: 宽限期结束、被顶掉或被 flush 时执行——真正 `context.delete` + 保存，
    ///             并把**在 delete 之前**取到的被删 id 装进 `GraphChange` 交回来（空台账则不广播）
    ///   - undo: 点「撤销」时执行——把隐藏的项放回界面
    func schedule(message: String, commit: @escaping () -> GraphChange, undo: @escaping () -> Void) {
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

    private func arm(_ ticket: UndoTicket, commit: (() -> GraphChange)?, undo: @escaping () -> Void) {
        // 顶掉上一枚：先把它了结（删除类即刻真删），再登记新的，顺序不能反 ——
        // 反过来会让上一枚的 commit 在新事务的闭包表里被误清。
        let lost = machine.arm(ticket)
        let lostChange = lost.map { settle($0) } ?? GraphChange()

        commits[ticket.id] = commit
        undos[ticket.id] = undo
        stripMessage = UndoGraceMachine.armMessage(lost: lost, next: ticket)
        publish()
        startTicker(for: ticket)
        // 广播要等**新事务登记完毕**之后再发（把广播搬进中心时自己引进的窗口，台账 §25 记着）：
        // 观察者里只要有谁走到 `flushNow()`（`ProjectViewModel.selectedProject.didSet` 就挂着一条），
        // 而那一刻 `commits[ticket.id]` 还是空的 ⇒ 新那枚的真删义务被"执行"成一次空调用 ——
        // 用户刚点的删除既不真删也不可撤销，界面已隐藏、库里还留着，重启后它又冒出来。
        Self.broadcast(ifNeeded: lostChange)
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
        var change = GraphChange()
        if let owed, let made = commits[owed.id]?() { change = made }
        dropClosures(for: id)
        publish()
        Self.broadcast(ifNeeded: change)
    }

    /// 被新事务顶掉时的了结：只补真删，**不动定时器**（新的那枚正在用）。
    /// 台账交回给调用方发，不在这里发 —— 见 `arm` 里那条顺序注释。
    private func settle(_ lost: UndoTicket) -> GraphChange {
        let change = lost.needsCommitOnSettle ? (commits[lost.id]?() ?? GraphChange()) : GraphChange()
        dropClosures(for: lost.id)
        return change
    }

    /// 真删落地 ⇒ 广播。空台账**不发**：接入前这些链一次都不发，
    /// 无脑补成"无载荷 = 全量重载"会把已修完的切页骨架闪烁重新引回来。
    /// 顺序也不能提前：commit 里的 `safeSave()` 已经跑完，此刻库里确实少了这些 id，
    /// 剪枝才不存在"剪早了、读回来还是活的"的窗口。
    private static func broadcast(ifNeeded change: GraphChange) {
        guard !change.isEmpty else { return }
        GraphBroadcast.post(change)
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
            // 登记当帧就要有读数：只等 ticker 第一跳的话，浮条会先闪一下 0:00 再跳到满档（0:05）
            secondsLeft = machine.secondsLeft(now: Date())
        } else {
            visibleTicket = nil
            stripMessage = ""
            secondsLeft = 0
        }
    }
}
