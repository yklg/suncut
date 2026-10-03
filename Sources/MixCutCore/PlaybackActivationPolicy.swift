import Foundation

/// 播放激活意图。
///
/// 两种意图是不同契约，必须由调用方显式声明：
/// - ``ensureActive``：确保分镜处于激活态——**幂等**。hover 延迟激活与点击播放使用；
///   对「当前已激活的同一分镜」重复请求是 no-op。
/// - ``restart``：强制重新播放一次——**有副作用**。边界微调后预览、定格后重播使用；
///   无论当前激活的是谁，恒产生新的播放信号。
public enum PlaybackActivationIntent: String, Sendable, Equatable {
    case ensureActive
    case restart
}

/// 播放激活的无状态判定（纯函数）。
///
/// 规则：
/// - ``PlaybackActivationIntent/restart`` 恒放行；
/// - ``PlaybackActivationIntent/ensureActive`` 仅当请求分镜不是当前激活分镜时放行。
public enum PlaybackActivationPolicy: Sendable {
    /// 一次激活请求是否应产生新的播放信号。
    public static func shouldEmit(activeSegmentID: UUID?,
                                  requestID: UUID,
                                  intent: PlaybackActivationIntent) -> Bool {
        switch intent {
        case .restart:
            return true
        case .ensureActive:
            return activeSegmentID != requestID
        }
    }
}

/// 播放激活门禁：「当前激活分镜」状态与「是否放行」判定的唯一真源。
///
/// 存在意义：若让调用方自己维护 active 状态、再调用无状态的
/// ``PlaybackActivationPolicy/shouldEmit(activeSegmentID:requestID:intent:)``，
/// 状态写入与判定分散两处，可能出现「状态已更新、判定仍用旧值」的漂移。
/// Gate 在放行时同步迁移 active，从结构上杜绝该可能。
///
/// 值类型、可 Sendable：每次 request 是一次明确的状态迁移，事件序列可被单测完整推演。
public struct PlaybackActivationGate: Equatable, Sendable {
    /// 当前激活分镜 ID；nil = 无激活（已停止）。
    public private(set) var activeSegmentID: UUID?

    public init(activeSegmentID: UUID? = nil) {
        self.activeSegmentID = activeSegmentID
    }

    /// 请求激活；返回是否产生了播放信号。
    /// 放行时 active 同步迁移为请求分镜；被去重时状态不变。
    @discardableResult
    public mutating func request(segmentID: UUID,
                                 intent: PlaybackActivationIntent) -> Bool {
        guard PlaybackActivationPolicy.shouldEmit(
            activeSegmentID: activeSegmentID,
            requestID: segmentID,
            intent: intent)
        else { return false }
        activeSegmentID = segmentID
        return true
    }

    /// 清除激活态（停止当前播放）。
    public mutating func clear() {
        activeSegmentID = nil
    }
}
