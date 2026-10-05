import SwiftUI

/// 配音作业进度 UI 集合（三档同源 DubbingJobProgress）：
/// - ``DubbingCompactProgress``：视频标题行紧凑档（确定条/不定 spinner + 文案 + 计时 + 停止）
/// - ``DubbingRegularProgress``：检查器完整档（三阶段指示 + 进度条 + 全文 + 计时 + 停止）
/// - ``DubbingJobsOverlay``：素材库底部常驻浮层（切换素材/滚动后进度仍可见可停）
///
/// 视觉纪律：白底、浅色阴影、品牌蓝 #1677ff；不加描边/背景色/额外配色；图标统一 SF Symbols。

// MARK: - 已等待时长（mm:ss，每秒重绘，VM 不起 Timer）

private struct ElapsedTime: View {
    let startedAt: Date?

    private static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(startedAt.map { context.date.timeIntervalSince($0) } ?? 0))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - 停止按钮

private struct StopJobButton: View {
    let canStop: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle")
                .font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(canStop ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!canStop)
        .help(canStop ? "停止改写（已完成内容保留）" : "自动化任务运行中，无法在此停止")
        .accessibilityLabel("停止改写")
    }
}

// MARK: - compact（DubSettingsBar 标题行）

struct DubbingCompactProgress: View {
    let videoID: UUID
    @Bindable var vm: DubbingViewModel
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.compact) {
            if let slot = vm.jobSlot(videoID: videoID), let fraction = slot.progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 112)
                    .tint(.accentColor)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(vm.progressText(videoID: videoID))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(vm.progressText(videoID: videoID))
            ElapsedTime(startedAt: vm.jobSlot(videoID: videoID)?.startedAt)
            StopJobButton(canStop: vm.canStopJob(videoID: videoID), action: onStop)
        }
    }
}

// MARK: - 阶段指示（regular 与浮层卡片共用）

private struct PhaseTrack: View {
    let activePhase: DubbingPhase
    let mini: Bool

    private func state(_ phase: DubbingPhase) -> PhaseState {
        let order = DubbingPhase.pipelineOrder
        let activeIndex = order.firstIndex(of: activePhase) ?? 0
        let selfIndex = order.firstIndex(of: phase) ?? 0
        if selfIndex < activeIndex { return .done }
        if selfIndex == activeIndex { return .active }
        return .todo
    }

    private enum PhaseState { case done, active, todo }

    var body: some View {
        HStack(spacing: mini ? 4 : 6) {
            ForEach(Array(DubbingPhase.pipelineOrder.enumerated()), id: \.element) { index, phase in
                if index > 0 {
                    Rectangle()
                        .fill(state(phase) == .todo ? Self.todoColor : Color.green.opacity(0.35))
                        .frame(width: mini ? 14 : 22, height: 1.5)
                }
                HStack(spacing: mini ? 4 : 6) {
                    ZStack {
                        Circle()
                            .fill(fillColor(for: state(phase)))
                            .frame(width: mini ? 13 : 17, height: mini ? 13 : 17)
                        if state(phase) == .done {
                            Image(systemName: "checkmark")
                                .font(.system(size: mini ? 7 : 8.5, weight: .bold))
                                .foregroundStyle(.white)
                        } else if !mini {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(state(phase) == .active ? .white : Color.secondary)
                        }
                    }
                    Text(phase.displayName)
                        .font(mini ? .system(size: 10) : .caption2)
                        .foregroundStyle(state(phase) == .todo ? Color.secondary :
                                        state(phase) == .active ? Color.accentColor : Color.primary.opacity(0.75))
                        .fontWeight(state(phase) == .active ? .semibold : .regular)
                }
            }
        }
    }

    private func fillColor(for s: PhaseState) -> Color {
        switch s {
        case .done: return Color.green
        case .active: return Color.accentColor
        case .todo: return Self.todoColor
        }
    }

    /// 未开始档位的中性灰（不加系统语义色以外的配色，企业风浅灰）。
    private static let todoColor = Color(red: 0.89, green: 0.90, blue: 0.92)
}

// MARK: - regular（检查器 340pt）

struct DubbingRegularProgress: View {
    let videoID: UUID
    @Bindable var vm: DubbingViewModel
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PhaseTrack(activePhase: vm.jobSlot(videoID: videoID)?.progress.phase ?? .prepareClone, mini: false)
            if let slot = vm.jobSlot(videoID: videoID), let fraction = slot.progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(vm.progressText(videoID: videoID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ElapsedTime(startedAt: vm.jobSlot(videoID: videoID)?.startedAt)
                StopJobButton(canStop: vm.canStopJob(videoID: videoID), action: onStop)
            }
            Text("切换到其它素材不会中断本任务；进度也可在页面底部浮层查看。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 常驻浮层

struct DubbingJobsOverlay: View {
    @Bindable var vm: DubbingViewModel
    let onStop: (UUID) -> Void

    /// 跨实例变化同步：MCP 等其他 VM 改的是同一个 shared registry，
    /// 本 VM 不会被直接通知；每秒把 registry.revision 拉进观察域，变化时浮层 ≤1s 呈现。
    private let pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                ForEach(vm.activeJobVideoIDs(), id: \.self) { videoID in
                    DubbingJobCard(videoID: videoID, vm: vm) { onStop(videoID) }
                }
            }
            .padding(.bottom, 18)
        }
        .onReceive(pollTimer) { _ in vm.syncJobsRevision() }
        // 容器自身透传点击，仅卡片可交互（不挡网格操作）。
        .allowsHitTesting(false)
    }
}

private struct DubbingJobCard: View {
    let videoID: UUID
    @Bindable var vm: DubbingViewModel
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(vm.jobSlot(videoID: videoID)?.videoDisplayName ?? "改写任务")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .help(vm.jobSlot(videoID: videoID)?.videoDisplayName ?? "")
                Spacer(minLength: 4)
                StopJobButton(canStop: vm.canStopJob(videoID: videoID), action: onStop)
            }
            PhaseTrack(activePhase: vm.jobSlot(videoID: videoID)?.progress.phase ?? .prepareClone, mini: true)
            if let slot = vm.jobSlot(videoID: videoID), let fraction = slot.progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 8) {
                Text(vm.progressText(videoID: videoID))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(vm.progressText(videoID: videoID))
                Spacer()
                ElapsedTime(startedAt: slotStartedAt)
            }
        }
        .padding(12)
        .frame(width: 288)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        .allowsHitTesting(true)
    }

    private var slotStartedAt: Date? { vm.jobSlot(videoID: videoID)?.startedAt }
}
