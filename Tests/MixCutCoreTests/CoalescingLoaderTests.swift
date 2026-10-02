import Foundation
import Testing
@testable import MixCutCore

/// CoalescingLoader 三条并发语义的回归测试（素材库滚动性能依赖它们，见该类型头注释）。
/// 用 Gate/Counter actor 做确定性同步，不靠 sleep 猜时序。

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor Counter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

struct CoalescingLoaderTests {
    @Test("同 key 并发：work 只执行一次，两个调用方拿到同一结果")
    func coalescesConcurrentWork() async {
        let loader = CoalescingLoader<String, Int>()
        let gate = Gate()
        let counter = Counter()

        func startCall() -> Task<Int?, Never> {
            Task {
                await loader.value(for: "k") {
                    _ = await counter.increment()
                    await gate.wait()
                    return 42
                }
            }
        }

        let a = startCall()
        let b = startCall()
        // 给两个调用方时间进入共享等待；Gate 未开之前 work 必挂起。
        try? await Task.sleep(nanoseconds: 30_000_000)
        await gate.open()

        let (va, vb) = await (a.value, b.value)
        #expect(va == 42)
        #expect(vb == 42)
        #expect(await counter.count == 1, "同 key 的并发调用必须合并为一次 work")
    }

    @Test("单个调用方取消不杀共享工作；工作完成后槽位释放，下次调用重新执行")
    func consumerCancellationDoesNotCancelSharedWork() async {
        let loader = CoalescingLoader<String, Int>()
        let gate = Gate()
        let counter = Counter()

        let survivor = Task {
            await loader.value(for: "k") {
                _ = await counter.increment()
                await gate.wait()
                return 42
            }
        }
        let canceller = Task {
            await loader.value(for: "k") {
                _ = await counter.increment()
                await gate.wait()
                return 42
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        canceller.cancel()
        await gate.open()

        let value = await survivor.value
        #expect(value == 42, "被取消的等待者不能杀死共享工作，幸存等待者必须拿到结果")
        #expect(await counter.count == 1)

        // 完成后槽位应已释放：新调用重新执行一次 work（缓存命中与否由缓存层自己判断）。
        let second = await loader.value(for: "k") {
            _ = await counter.increment()
            return 7
        }
        #expect(second == 7)
        #expect(await counter.count == 2)
    }

    @Test("invalidate 取消在飞工作；下次取值重新执行 work")
    func invalidateCancelsInflightWork() async {
        let loader = CoalescingLoader<String, Int>()
        let counter = Counter()

        func cancellableWork(_ result: Int) -> @Sendable () async -> Int? {
            {
                _ = await counter.increment()
                // 非throwing 闭包：用 try? 响应协作式取消，被 invalidate 后返回 nil。
                try? await Task.sleep(nanoseconds: 200_000_000)
                return Task.isCancelled ? nil : result
            }
        }

        let inflight = Task { await loader.value(for: "k", work: cancellableWork(1)) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await loader.invalidate("k")
        let cancelled = await inflight.value
        #expect(cancelled == nil, "invalidate 后在飞工作应被取消并返回 nil")

        let retried = await loader.value(for: "k", work: cancellableWork(1))
        #expect(retried == 1, "invalidate 后下一次取值必须重新执行 work")
        #expect(await counter.count == 2)
    }

    @Test("invalidateAll 取消全部在飞工作")
    func invalidateAllCancelsEverything() async {
        let loader = CoalescingLoader<String, Int>()

        func work() -> @Sendable () async -> Int? {
            {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return Task.isCancelled ? nil : 1
            }
        }

        let a = Task { await loader.value(for: "a", work: work()) }
        let b = Task { await loader.value(for: "b", work: work()) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await loader.invalidateAll()
        let (ra, rb) = await (a.value, b.value)
        #expect(ra == nil)
        #expect(rb == nil)
    }
}
