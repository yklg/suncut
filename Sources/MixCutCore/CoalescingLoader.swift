import Foundation

/// 按 key 合并并发工作的异步加载器。
///
/// 语义契约（被 ThumbnailCache 使用，素材库滚动性能依赖这三条）：
/// 1. **同 key 合并**：对同一 key 的并发 `value(for:)` 只执行一次 `work`，所有调用方共享同一结果；
/// 2. **消费者取消不杀共享工作**：单个调用方的 Task 被取消（如视图滚出屏）不会取消在飞的 `work`，
///    工作跑完后结果仍可写入缓存，服务随后滚回来的其他消费者；
/// 3. **invalidate 杀在飞工作**：`invalidate(_:)` 取消该 key 在飞任务并丢弃槽位，
///    下一次 `value(for:)` 会重新执行 `work`（缩略图失效重生用）。
///
/// 不限制 `Value` 为 `Sendable`：调用方负责保证取到值后只在其归属上下文（如 @MainActor）使用。
public actor CoalescingLoader<Key: Hashable, Value> {
    /// 在飞/刚完成尚未清理的工作。完成后由发起方在 actor 上做 compare-and-remove，
    /// 不长期持有结果（缓存层另有自己的存储，避免值被双份持有）。
    private var tasks: [Key: Task<Value?, Never>] = [:]

    public init() {}

    /// 取 key 对应的值；同 key 并发调用共享一次 `work`。
    ///
    /// - Parameters:
    ///   - priority: 共享工作的调度优先级（可视区用 `.userInitiated`，后台预热用 `.utility`）；
    ///     若该 key 已有在飞工作则沿用先发起那次的优先级（高优先级调用方的等待会通过优先级捐赠提升它）。
    ///   - work: 实际取值工作（如后台降采样解码）。需自行响应协作式取消，
    ///     被 invalidate 后应尽快返回 nil。
    public func value(
        for key: Key,
        priority: TaskPriority = .userInitiated,
        work: @Sendable @escaping () async -> Value?
    ) async -> Value? {
        if let existing = tasks[key] {
            return await existing.value
        }
        // 非结构化任务：生命周期由本 loader 的字典管理，独立于任一调用方的取消。
        let task = Task.detached(priority: priority) { () -> Value? in
            await work()
        }
        tasks[key] = task
        let result = await task.value
        // compare-and-remove：只清自己发起的槽位，不清掉 invalidate 后已换上来的新工作。
        if tasks[key] == task { tasks[key] = nil }
        return result
    }

    /// 取消并丢弃该 key 的在飞工作；下次取值会重新执行 work。
    public func invalidate(_ key: Key) {
        tasks.removeValue(forKey: key)?.cancel()
    }

    /// 取消并丢弃全部在飞工作（清空缓存/换项目时用）。
    public func invalidateAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }
}
