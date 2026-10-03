import SwiftUI

/// 悬停说明的水平锚点。
///
/// 系统 help tag 由窗口负责定位，自制气泡需要自己决定横向落点：窄窗（360pt 最小卡宽）下
/// 居中气泡会越过 ScrollView 裁切边，因此靠左控件用 ``leading`` 向右展开，其余按位置选择。
enum HoverTipAnchor {
    case leading, center, trailing
}

/// 悬停说明修饰符：指针在控件上静止 `delay` 后显示简短气泡，移走 / 再移动立即复位。
///
/// 为什么不用系统 `.help`：本组件挂载在「hover 卡片延迟 280ms 才出现」的重子树内，
/// AppKit tracking rect 注册时鼠标已在区域内，驻留计时器永不启动；且嵌套 `.help` 不被官方
/// 支持。这里由 `MixCutCore.HoverTipState`（Sendable 值类型，token 契约）+ 视图层 Task 自持计时。
private struct HoverTipModifier: ViewModifier {
    let message: String
    var anchor: HoverTipAnchor = .center
    var delay: Duration = .milliseconds(500)

    @State private var state = HoverTipState()
    @State private var dwellTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .accessibilityHint(message)
            .onHover { hovering in
                if hovering { arm() } else { disarm() }
            }
            .onContinuousHover { phase in
                // 兜底：行挂载在光标下导致 onHover 漏报时，任意微动即补点亮；
                // 移动即重新驻留（连续移动中不显示，静止 delay 后才显示）。
                switch phase {
                case .active: arm()
                case .ended: disarm()
                }
            }
            .overlay(alignment: overlayAlignment) {
                if state.isVisible { bubble }
            }
            // 动画只绑定显隐值：气泡为 overlay 不参与布局，不外溢到其它视图。
            .animation(.easeOut(duration: 0.12), value: state.isVisible)
            .onDisappear {
                dwellTask?.cancel()
                dwellTask = nil
            }
    }

    private var overlayAlignment: Alignment {
        switch anchor {
        case .leading: Alignment(horizontal: .leading, vertical: .top)
        case .center: .top
        case .trailing: Alignment(horizontal: .trailing, vertical: .top)
        }
    }

    private var bubble: some View {
        Text(message)
            .font(DesignTokens.Typography.microRegular)
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            // overlay 给子视图的提案宽度等于锚点控件宽度（14pt 按钮 → 14pt），
            // 用 maxWidth + fixedSize 实现：短文案按理想宽收窄、长文案在 220pt 处换行。
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            }
            // overlay 纵向按 .top 对齐：把气泡锚点移到自身底部下方 5pt，
            // 气泡整体位于控件正上方（本行是卡片/列表行的末行，上方无裁切）。
            .alignmentGuide(.top) { $0.height + 5 }
            .allowsHitTesting(false)
    }

    private func arm() {
        dwellTask?.cancel()
        var snapshot = state
        let token = snapshot.hoverBegan()
        state = snapshot
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            var current = state
            current.succeed(token)
            state = current
        }
    }

    private func disarm() {
        dwellTask?.cancel()
        dwellTask = nil
        var snapshot = state
        snapshot.hoverEnded()
        state = snapshot
    }
}

extension View {
    /// 添加悬停说明：指针静止 `delay` 后显示简短气泡，移走立即消失。
    /// - Parameters:
    ///   - message: 只描述这个控件的短文案（HIG：tooltip 不承载概念长教学）。
    ///   - anchor: 气泡相对控件的水平锚点，窄窗防裁切。
    func hoverTip(_ message: String,
                  anchor: HoverTipAnchor = .center,
                  delay: Duration = .milliseconds(500)) -> some View {
        modifier(HoverTipModifier(message: message, anchor: anchor, delay: delay))
    }
}
