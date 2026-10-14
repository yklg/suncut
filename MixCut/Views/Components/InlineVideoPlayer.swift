import SwiftUI
import AVKit

/// 原地视频播放器：缩略图态 ↔ 播放态 切换，自带可拖动进度条
struct InlineVideoPlayer: View {
    let videoPath: String
    let thumbnailPath: String?
    let aspectRatio: CGFloat

    /// 播放身份（调用方保证同列表唯一，用 video.id）。
    var playbackID: String = ""
    /// 播放设备协调器：同一列表同一时刻只允许一个播放；nil = 不参与协调、行为完全独立。
    var coordinator: PlaybackCoordinator? = nil

    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isSeeking = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 0) {
            if isPlaying, let player {
                // 视频画面
                PlayerRepresentable(player: player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 自定义控制栏
                controlBar(player: player)
            } else {
                thumbnailView
                    .overlay {
                        Button {
                            startPlayback()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("播放")
                    }
            }
        }
        // 唯一播放互斥：协调器的活跃身份变成「别的播放器」时，本卡立即停止回缩略图。
        .onChange(of: coordinator?.activePlaybackID) { _, newID in
            // 协调器存在 + 活跃身份已不是我 + 我正在播 → 立即停止（点新视频即停旧）
            guard coordinator != nil, newID != playbackID, isPlaying else { return }
            stopPlayback()
        }
        .onDisappear {
            // stopPlayback 内部统一 deactivate（覆盖删除/离开/换页所有销毁路径）
            stopPlayback()
        }
    }

    // MARK: - 控制栏（进度条 + 按钮）

    private func controlBar(player: AVPlayer) -> some View {
        HStack(spacing: 6) {
            // 播放/暂停
            Button {
                if player.timeControlStatus == .playing {
                    player.pause()
                } else {
                    // 若已定格在结尾，先回到开头再播
                    if duration > 0 && currentTime >= duration - 0.05 {
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    player.play()
                }
            } label: {
                Image(systemName: player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.timeControlStatus == .playing ? "暂停" : "播放")

            // 当前时间
            Text(formatTime(currentTime))
                .font(DesignTokens.Typography.microMono)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .lineLimit(1)
                .monospacedDigit()   // 10 分钟以上是 "12:34" 共 5 字符，28pt 装不下会截断

            // 可拖动进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 3)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: progressWidth(in: geo.size.width), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            currentTime = fraction * duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            let targetTime = CMTime(seconds: fraction * duration, preferredTimescale: 600)
                            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                            isSeeking = false
                        }
                )
            }
            .frame(height: 16)

            // 总时长
            Text(formatTime(duration))
                .font(DesignTokens.Typography.microMono)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
                .lineLimit(1)
                .monospacedDigit()

            // 停止按钮
            Button {
                stopPlayback()
            } label: {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭播放")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return totalWidth * CGFloat(currentTime / duration)
    }

    // MARK: - 缩略图

    @ViewBuilder
    private var thumbnailView: some View {
        AsyncCachedImage(
            path: thumbnailPath,
            placeholder: {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
            },
            imageContent: { image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        )
    }

    // MARK: - 播放控制

    private func startPlayback() {
        // 纵深防御（不是主修点）：主修在 `MaterialAvailabilityStore` 那条对账轴上 —— 界面对完过账
        // 之后这张卡根本不会实例化播放器。这一颗兜的是"对账还没跑到 / 刚被移走"的窗口期：
        // 播一个不在的文件只会得到一条事后归因的失败，而用户需要的是路径与恢复动作。
        // ⚠️ 顺序硬约束：`isPlaying = true` 必须在这个检查**之后**（连 coordinator 也在之后，
        //    否则拒绝播放一个死文件会把别的卡正在播的那路给挤掉）。
        guard FileHelper.isMaterialFilePresent(path: videoPath) else {
            ToastCenter.shared.show(
                MissingMaterialCopy.fullMessage(fileName: URL(fileURLWithPath: videoPath).lastPathComponent),
                icon: "exclamationmark.triangle.fill", style: .warning)
            return
        }
        // 抢占播放身份：协调器会让其它正在播放的卡片经 onChange 停止
        if let coordinator, !playbackID.isEmpty {
            coordinator.activate(playbackID)
        }
        let url = URL(fileURLWithPath: videoPath)
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        isPlaying = true

        // 获取总时长
        if let item = newPlayer.currentItem {
            Task {
                let dur = try? await item.asset.load(.duration)
                if let dur {
                    await MainActor.run {
                        duration = CMTimeGetSeconds(dur)
                    }
                }
            }
        }

        // 定时更新当前播放时间
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isSeeking {
                currentTime = CMTimeGetSeconds(time)
            }
        }

        newPlayer.play()

        // 播放结束：定格在最后一帧（不回缩略图），便于确认末帧画面。再次点播放会从头重播。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { _ in
            // NotificationCenter block 静态为 nonisolated，统一切回 MainActor
            // （queue: .main 只在运行时保证，编译器不可见）
            Task { @MainActor in
                player?.pause()
                // R3：自然播完后画面定格末帧（现有表现不变），但释放「唯一播放」占位
                coordinator?.deactivate(playbackID)
            }
        }
    }

    private func stopPlayback() {
        if let observer = timeObserver, let p = player {
            p.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        // 统一兜底：任何销毁路径（抢占停止/离开/删除）都释放自己的占位。
        // 若占位已属于别的播放器，deactivate 是 no-op。
        coordinator?.deactivate(playbackID)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// 纯画面播放视图（无内建控件）
struct PlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
