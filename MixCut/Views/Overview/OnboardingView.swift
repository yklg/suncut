import SwiftUI

/// 首次启动 4 步使用引导
/// 通过 @AppStorage("hasCompletedOnboarding") 持久化是否已完成
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: Int = 0
    /// 6 步：欢迎 → 模型下载 → API Key → 导入 → 生成 → Agent（模型页为首次启动下载入口）。
    private let totalSteps = 6
    /// 模型状态读 installer 唯一宿主；"稍后"由 ContentView 的 dismissedModelStep 管。
    @State private var modelInstaller = WhisperModelInstaller.shared
    @AppStorage(Brand.dismissedModelStepKey) private var dismissedModelStep = false
    /// 本页是否从"老用户单步弹窗"进来（只看模型一步，跳过其余）。
    let modelOnlyMode: Bool

    init(modelOnlyMode: Bool = false, onComplete: @escaping () -> Void) {
        self.modelOnlyMode = modelOnlyMode
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .id(step)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 500)
    }

    // MARK: - 步骤内容

    @ViewBuilder
    private var content: some View {
        if modelOnlyMode {
            // 老用户单步：只显示模型下载页，其余步骤不出现
            modelPage
        } else {
            switch step {
            case 0: welcomePage
            case 1: modelPage
            case 2: apiKeyPage
            case 3: importPage
            case 4: generatePage
            case 5: agentPage
            default: EmptyView()
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 22) {
            BrandLogo(size: 56)

            VStack(spacing: 6) {
                Text("欢迎使用 \(Brand.displayName)")
                    .font(.system(size: 24, weight: .bold))
                Text(Brand.tagline)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                OnboardingBullet(icon: "scissors", color: .blue,
                                 text: "AI 自动按语义切分视频镜头")
                OnboardingBullet(icon: "wand.and.stars", color: .purple,
                                 text: "智能排列组合生成差异化广告视频")
                OnboardingBullet(icon: "square.and.arrow.up", color: .green,
                                 text: "一键批量导出为可用的 MP4 视频")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 模型下载页（首启引导第 2 步 / 老用户单步）。四态 UI 全读 installer 唯一宿主。
    private var modelPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 50))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("第 2 步 · 下载语音识别模型")
                    .font(.system(size: 22, weight: .bold))
                Text("首次使用需下载约 1 GB 的本地识别模型，之后离线可用、台词不上传云端")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                switch modelInstaller.phase {
                case .downloading, .verifying:
                    VStack(spacing: 10) {
                        if let p = modelInstaller.progress, p.totalBytes > 0 {
                            ProgressView(value: p.fraction).controlSize(.small)
                            HStack {
                                Text(String(format: "%.1f%%", p.fraction * 100))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text("\(ByteCountFormatter.string(fromByteCount: p.receivedBytes, countStyle: .binary)) / \(ByteCountFormatter.string(fromByteCount: p.totalBytes, countStyle: .binary))")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                            Text("连接国内镜像…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                        }
                        Button("取消") { modelInstaller.cancel() }.controlSize(.small)
                    }
                default:
                    if modelInstaller.needsDownload {
                        OnboardingBullet(icon: "arrow.down.circle", color: .blue,
                                         text: "国内镜像下载，支持断点续传")
                        OnboardingBullet(icon: "checkmark.shield", color: .green,
                                         text: "下载后自动校验体积与内容完整性")
                        OnboardingBullet(icon: "hand.raised", color: .orange,
                                         text: "可稍后在「设置 → 通用」里下载")
                        Button {
                            modelInstaller.start()
                        } label: {
                            Label("开始下载 \(ASRPolicy.engineTier)", systemImage: "arrow.down.circle.fill")
                                .font(DesignTokens.Typography.labelStrong)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        if case .failed(let error) = modelInstaller.phase {
                            Text(error)
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    } else {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("语音模型已就绪，可以开始使用了")
                                .font(DesignTokens.Typography.body)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .onAppear { modelInstaller.refresh() }
    }

    private var apiKeyPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("第一步 · 配置 AI Key")
                    .font(.system(size: 22, weight: .bold))
                Text("\(Brand.displayName) 需要大模型完成语义分析与混剪策略")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                OnboardingBullet(icon: "1.circle.fill", color: .blue,
                                 text: "打开「设置 → API」")
                OnboardingBullet(icon: "2.circle.fill", color: .blue,
                                 text: "选择提供商：千问 / MiniMax / Claude / 自定义")
                OnboardingBullet(icon: "3.circle.fill", color: .blue,
                                 text: "粘贴 API Key 并保存")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            SettingsLink {
                Label("打开设置...", systemImage: "gear")
                    .font(DesignTokens.Typography.labelStrong)
            }
            .controlSize(.small)
        }
    }

    private var importPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 50))
                .foregroundStyle(.blue)

            VStack(spacing: 6) {
                Text("第二步 · 导入广告素材")
                    .font(.system(size: 22, weight: .bold))
                Text("新建项目后把视频拖进来，剩下交给 AI")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                OnboardingBullet(icon: "waveform", color: .blue,
                                 text: "Whisper 本地识别台词（不上传云端）")
                OnboardingBullet(icon: "rectangle.split.3x1", color: .blue,
                                 text: "镜头切分 + I-frame 精准边界对齐")
                OnboardingBullet(icon: "tag.fill", color: .blue,
                                 text: "AI 自动标注语义：产品展示、口播、卖点…")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("💡 语音识别模型在第一步已下载到本地，识别全程离线、台词不上传")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var generatePage: some View {
        VStack(spacing: 18) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 50))
                .foregroundStyle(.purple)

            VStack(spacing: 6) {
                Text("第三步 · 生成方案并导出")
                    .font(.system(size: 22, weight: .bold))
                Text("AI 先制定策略，再挑选具体分镜，批量混剪")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                OnboardingBullet(icon: "list.bullet.clipboard", color: .purple,
                                 text: "在「混剪方案」点「生成方案」")
                OnboardingBullet(icon: "sparkles", color: .purple,
                                 text: "AI 自动制定风格、受众、叙事结构")
                OnboardingBullet(icon: "square.and.arrow.up.fill", color: .green,
                                 text: "在「导出」批量输出 MP4 视频文件")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        }
    }

    private var agentPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 50))
                .foregroundStyle(.teal)

            VStack(spacing: 6) {
                Text("进阶 · 让 AI Agent 替你操作")
                    .font(.system(size: 22, weight: .bold))
                Text("把 Claude Code、Codex 等 AI 助手接进来，一句话完成批量操作")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                OnboardingBullet(icon: "link", color: .teal,
                                 text: "打开「设置 → Agent」，把注册配置复制进你的 AI 助手")
                OnboardingBullet(icon: "text.bubble", color: .teal,
                                 text: "像聊天一样下指令：「把项目一里 1 号视频的 3 到 5 号分镜标签改成痛点，结尾都延 10 帧」")
                OnboardingBullet(icon: "number", color: .teal,
                                 text: "视频编号看卡片上的「N 号」徽章，分镜编号看 # 号，报编号即可、不用说文件名")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(DesignTokens.Palette.Alpha.subtle * 2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("🎬 准备好了，开始你的第一个项目吧")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 底部控制

    private var footer: some View {
        HStack {
            Button("跳过") {
                if modelOnlyMode { dismissedModelStep = true }
                onComplete()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(DesignTokens.Typography.label)

            Spacer()

            if !modelOnlyMode {
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { idx in
                        Circle()
                            .fill(idx == step ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                            .animation(DesignTokens.Motion.transition, value: step)
                    }
                }
            }

            Spacer()

            HStack(spacing: DesignTokens.Spacing.compact) {
                if !modelOnlyMode && step > 0 {
                    Button("上一步") {
                        withAnimation(DesignTokens.Motion.transition) { step -= 1 }
                    }
                    .controlSize(.regular)
                }

                if modelOnlyMode {
                    // 老用户单步：点"完成"即标记稍后（永久不再自动弹，入口转入侧栏/设置页）
                    Button("完成") {
                        dismissedModelStep = true
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                } else if step < totalSteps - 1 {
                    // 模型步骤的"下一步"允许跳过（稍后可在设置页下载）
                    Button(step == 1 ? "下一步（可稍后下载）" : "下一步") {
                        withAnimation(DesignTokens.Motion.transition) { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("开始使用 \(Brand.displayName)") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - 子组件

private struct OnboardingBullet: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.normal) {
            Image(systemName: icon)
                .font(DesignTokens.Typography.bodyLarge)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(text)
                .font(DesignTokens.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
