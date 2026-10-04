import SwiftUI

/// 全局 Toast 状态管理（@Observable 单例）—— **只管瞬时提示**。
///
/// 撤销浮条不在这里：它的事务生命周期归 `PendingDeletionCenter`（判据是 `UndoGraceMachine` 的
/// `armed`），经由 `UndoSlot` 上屏。以前两者抢同一个 `current`，任何一条 2.2 秒的普通提示
/// 都会把正在倒计时的撤销条顶掉，宽限期就成了装饰。
@Observable
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    var current: ToastPayload?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, icon: String = "checkmark.circle.fill",
              style: InlineBanner.Style = .success, duration: Double = 2.2) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            current = ToastPayload(id: UUID(), text: text, icon: icon, style: style)
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(DesignTokens.Motion.transition) {
                self?.current = nil
            }
        }
    }

    /// 立即清除当前 Toast。
    func dismiss() {
        dismissTask?.cancel()
        withAnimation(DesignTokens.Motion.transition) {
            current = nil
        }
    }
}

struct ToastPayload: Identifiable, Equatable {
    let id: UUID
    let text: String
    let icon: String
    let style: InlineBanner.Style
}

/// 应用根视图叠加：第一行撤销槽（常驻，绑事务），第二行普通提示槽（2.2s 自动消失）。
struct ToastOverlay: View {
    @State private var toastCenter = ToastCenter.shared
    @State private var undoCenter = PendingDeletionCenter.shared

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.compact) {
            if let ticket = undoCenter.visibleTicket {
                UndoSlotView(ticket: ticket, message: undoCenter.stripMessage,
                             secondsLeft: undoCenter.secondsLeft)
            }
            if let payload = toastCenter.current {
                NoticeSlotView(payload: payload)
            }
            Spacer()
                .allowsHitTesting(false)
        }
    }
}

/// 撤销槽：正文 + 具名撤销按钮 + 剩余时间。
///
/// 只有 `PendingDeletionCenter` 判定 armed 时才存在，所以按钮点下去必然还在宽限内
/// （过期瞬间由状态机收回浮条）。`allowsHitTesting` 这里必须为真 —— 它是唯一可点的槽。
private struct UndoSlotView: View {
    let ticket: UndoTicket
    let message: String
    let secondsLeft: Double

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: "trash.fill")
                .font(DesignTokens.Typography.bodyEmphasis)
                .foregroundStyle(InlineBanner.Style.warning.color)
            Text(message)
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(.primary.opacity(0.85))
            Text("· \(Self.countdown(secondsLeft))")
                .font(DesignTokens.Typography.labelStrong)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider()
                .frame(height: 14)
            Button {
                PendingDeletionCenter.shared.undoTapped()
            } label: {
                Text(ticket.actionTitle)
                    .font(DesignTokens.Typography.labelEmphasis)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(
            Capsule().stroke(InlineBanner.Style.warning.color.opacity(0.15), lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
        .padding(.top, 50)
    }

    /// mm:ss，向上取整 ⇒ 刚登记显示满档（现在 `graceSeconds=5` ⇒ 0:05），最后一秒显示 0:01 而不是 0:00。
    static func countdown(_ seconds: Double) -> String {
        let whole = Int((seconds).rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// 普通提示槽：纯告知，无按钮，因此不参与命中测试（不会挡住下层交互）。
private struct NoticeSlotView: View {
    let payload: ToastPayload

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            Image(systemName: payload.icon)
                .font(DesignTokens.Typography.bodyEmphasis)
                .foregroundStyle(payload.style.color)
            Text(payload.text)
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(
            Capsule().stroke(payload.style.color.opacity(0.15), lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
