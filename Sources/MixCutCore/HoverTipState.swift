import Foundation

/// 悬停说明（HoverTip）的显隐状态机。
///
/// 值类型、可 Sendable：与 ``PlaybackActivationGate`` 同一范式——MixCutCore 不依赖 SwiftUI /
/// Observation，交互契约由可完整推演的状态迁移承担。
///
/// 职责边界：状态机**只管契约，不管计时**。驻留时长（例如 500ms）由视图层的 Task 承担，
/// 到点后把当初 ``hoverBegan()`` 返回的 token 回传给 ``succeed(_:)``。单调递增的 token 保证：
/// 指针移动/离开会让旧计时立即作废，**同一时刻只有最新一次 hover 能点亮说明**。
public struct HoverTipState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 指针不在区域内（或从未进入）。
        case idle
        /// 指针在区域内，驻留计时中。
        case waiting
        /// 驻留已到点，说明可见。
        case visible
    }

    public private(set) var phase: Phase = .idle
    private var token: UInt64 = 0

    public init() {}

    /// 说明当前是否可见。
    public var isVisible: Bool { phase == .visible }

    /// 指针进入区域（或在区域内移动后重新开始驻留）。
    ///
    /// - Returns: 本次驻留的令牌；旧令牌立即失效。
    @discardableResult
    public mutating func hoverBegan() -> UInt64 {
        token &+= 1
        phase = .waiting
        return token
    }

    /// 驻留到点。仅当令牌仍是最新令牌时才点亮；过期令牌（移动/离开后回来的旧计时）被吞掉。
    public mutating func succeed(_ token: UInt64) {
        guard token == self.token else { return }
        phase = .visible
    }

    /// 指针离开：立即复位，所有在途计时作废。
    public mutating func hoverEnded() {
        token &+= 1
        phase = .idle
    }
}
