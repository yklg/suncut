import Foundation

/// 视频级配音作业注册表。
///
/// 为什么它必须存在、且必须在 Core：
/// 一键改写/配音管线的忙碌状态按**视频**键控，但任务句柄曾经挂在**分镜视图子树**的
/// @State 里——切换分镜（.id(seg.id) 重建子树）会把同视频的付费管线连带取消。
/// 注册表把「引用计数 + 可取消句柄 + 进度槽位」收成单一真相，独立于任何视图生命周期，
/// 语义与 ``CoalescingLoader`` 一致：**消费者（视图/分镜切换）消失不杀共享工作，
/// 只有生命周期终结（用户停止 / 数据被删 / 换项目）才取消**。
///
/// 并发模型：标注 @MainActor，所有状态变更与 SwiftUI 同处一个隔离域；
/// 非 @Observable（MixCutCore 零 SwiftUI/Observation 依赖），UI 观察由宿主 ViewModel 投影。
@MainActor
public final class DubbingJobRegistry {

    /// 单个视频的槽位快照（不含 Task 本体，可安全给 UI 拷贝）。
    public struct Slot: Equatable, Sendable {
        public var refCount: Int = 0
        public var taskIDs: Set<UUID> = []
        public var targetSegmentIDs: Set<UUID> = []
        public var videoDisplayName: String = ""
        public var progress: DubbingJobProgress = .idle
        public var startedAt: Date?

        public init() {}
    }

    private var slots: [UUID: Slot] = [:]
    private var tasks: [UUID: [UUID: Task<Void, Never>]] = [:]

    /// 进程级共享实例：视频是进程级共享资源（UI、MCP 服务、导出共用同一份素材与付费音色），
    /// 忙碌互斥也必须是进程级——否则 UI 的 VM 与 MCP 工具各自持有的 VM 互不可见，
    /// 会对同一视频并发克隆（真机日志已实锤双份 `[Clone] 开始克隆原声`）。
    /// 保留 public init()：单测必须用独立实例，避免用例间共享状态互相污染。
    public static let shared = DubbingJobRegistry()

    /// 状态修订号：任意 begin/end/register/removeTask/cancel/setProgress 后自增。
    /// registry 不能是 @Observable（Core 零 SwiftUI/Observation 依赖），各 VM 通过它把
    /// 跨实例（MCP 改了 shared、UI VM 需要感知）的变化投影进自己的观察域。
    public private(set) var revision = 0
    private func bump() { revision &+= 1 }

    public init() {}

    // MARK: - 引用计数（忙碌语义）

    /// 进入忙碌。首个引用时建槽并记录开始时间；后续引用只 +1，不覆盖 startedAt。
    public func begin(_ videoID: UUID) {
        if slots[videoID] == nil {
            var slot = Slot()
            slot.startedAt = Date()
            slots[videoID] = slot
        }
        slots[videoID]?.refCount += 1
        bump()
    }

    /// 退出忙碌。归零即清整键（句柄/进度/计时一起走），杜绝幽灵忙碌与残留进度。
    /// 对未 begin 的键调用是安全的 no-op（防御管线异常路径重复 end）。
    public func end(_ videoID: UUID) {
        guard var slot = slots[videoID] else { return }
        slot.refCount -= 1
        if slot.refCount <= 0 {
            slots[videoID] = nil
            tasks[videoID] = nil
        } else {
            slots[videoID] = slot
        }
        bump()
    }

    public func isBusy(_ videoID: UUID) -> Bool {
        (slots[videoID]?.refCount ?? 0) > 0
    }

    /// 当前所有忙碌视频（派生值，UI 浮层以此为列表真源）。
    public var busyIDs: Set<UUID> {
        Set(slots.filter { $0.value.refCount > 0 }.keys)
    }

    public func slot(_ videoID: UUID) -> Slot? { slots[videoID] }

    // MARK: - 可取消句柄（UI 发起的作业才登记；MCP 直接 await 的管线无句柄、不可由 UI 停）

    /// 登记一个作业句柄。taskID 由调用方在 Task 创建前生成（供任务 defer 自摘除）。
    public func register(_ videoID: UUID,
                         taskID: UUID,
                         targets: Set<UUID>,
                         name: String,
                         task: Task<Void, Never>) {
        var slot = slots[videoID] ?? Slot()
        slot.taskIDs.insert(taskID)
        // 以本次登记为准（同一槽位上后发起的作业携带最新目标/名称快照）。
        slot.targetSegmentIDs = targets
        if !name.isEmpty { slot.videoDisplayName = name }
        if slot.startedAt == nil { slot.startedAt = Date() }
        slots[videoID] = slot
        tasks[videoID, default: [:]][taskID] = task
        bump()
    }

    /// 摘除自己的句柄。只按 (videoID, taskID) 精确摘除，**绝不清空整个槽位**
    /// （先结束的作业不得带走后登记作业的句柄）。
    /// 无引用计数且无剩余句柄的槽位即时清理（覆盖逐格配音这类不 beginBusy 的任务）。
    public func removeTask(_ videoID: UUID, taskID: UUID) {
        tasks[videoID]?[taskID] = nil
        guard var slot = slots[videoID] else { return }
        slot.taskIDs.remove(taskID)
        slots[videoID] = slot
        if slot.refCount <= 0 && slot.taskIDs.isEmpty {
            slots[videoID] = nil
            tasks[videoID] = nil
        }
        bump()
    }

    /// 是否存在可由 UI 停止的句柄（无句柄 = MCP 等自动化管线，停止按钮应置灰）。
    public func canStop(_ videoID: UUID) -> Bool {
        !(tasks[videoID]?.isEmpty ?? true)
    }

    /// 取消该视频的全部已登记句柄。refCount 不清（由管线 defer end 收口）。
    /// - Returns: 是否真的取消了至少一个句柄。
    @discardableResult
    public func cancel(_ videoID: UUID) -> Bool {
        guard let boxes = tasks[videoID], !boxes.isEmpty else { return false }
        for task in boxes.values { task.cancel() }
        bump()
        return true
    }

    /// 取消全部视频的已登记句柄（换项目用）。
    /// - Returns: 实际有句柄被取消的视频 id 集合（调用方据此决定是否提示）。
    @discardableResult
    public func cancelAll() -> Set<UUID> {
        var changed = Set<UUID>()
        for (videoID, boxes) in tasks where !boxes.isEmpty {
            for task in boxes.values { task.cancel() }
            changed.insert(videoID)
        }
        if !changed.isEmpty { bump() }
        return changed
    }

    // MARK: - 进度

    public func setProgress(_ videoID: UUID, _ progress: DubbingJobProgress) {
        guard slots[videoID] != nil else { return }
        slots[videoID]?.progress = progress
        bump()
    }

    /// 当前进度文案（派生）。
    public func progressText(_ videoID: UUID) -> String {
        slots[videoID]?.progress.phaseText ?? ""
    }

    /// 全部槽位的快照（删除广播取消判据批量评估用）。
    public func allSlots() -> [UUID: Slot] { slots }
}
