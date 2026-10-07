import SwiftUI
import SwiftData

/// 复刻音色注册向导（M2）：选参考音频 → 质量校验 → 授权确认 → 注册。
///
/// ## 为什么是 sheet 而不是独立窗口
///
/// 这是「设置 → 我的复刻音色库」的从属流程，参数不多（一份音频 + 一个名字 + 一个勾选），
/// 独立窗口会让人失去「我正在设置里 configuring」的上下文。
///
/// ## 授权为什么放在最后一步且不可跳过
///
/// 授权勾选是**合规前置**，不是装饰。它放在流程末尾（用户已经选完音频、看过校验结果），
/// 但放在**注册动作之前**且勾选状态为false 时「注册」按钮直接禁用：
/// 让用户"到这一步才看到"是必要的 —— 他必须先知道要上传的是自己的声音。
/// 早于这一步就弹合规弹窗会被当成无关噪音直接划掉。
struct CloneWizardView: View {
    /// 注册成功（调用方随后 dismiss 本 sheet；列表靠 @Query 自动刷新，无需回传对象）。
    let onRegistered: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var sourceKind: CloneProfileKind = .upload
    @State private var pickedPath: String?
    @State private var pickedDisplayName = ""
    @State private var durationSeconds: Double = 0
    @State private var consent = false
    @State private var phase: Phase = .idle
    @State private var errorText: String?

    private enum Phase: Equatable {
        case idle
        case preparing
        case registering
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.normal) {
                    sourceSection
                    if pickedPath != nil { sampleSection }
                    consentSection
                    if let errorText {
                        Text(errorText)
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .sheetContainerFrame(minWidth: 480, idealWidth: 520, maxWidth: 560,
                             minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("注册复刻音色").font(DesignTokens.Typography.bodyEmphasis)
                Text("用你自己的声音做配音，之后任何项目都能直接用。")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignTokens.Spacing.normal)
    }

    // MARK: - 来源

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            Text("参考音频").font(DesignTokens.Typography.labelEmphasis)
            Picker("", selection: $sourceKind) {
                ForEach(CloneProfileKind.allCases, id: \.self) { k in
                    Text(k.displayName).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(phase == .preparing || phase == .registering)

            HStack(spacing: 10) {
                Button {
                    pickSourceFile()
                } label: {
                    Label("选择音频文件…", systemImage: "waveform")
                }
                .controlSize(.small)
                .disabled(phase == .preparing || phase == .registering)

                Text(pickedPath == nil
                     ? (sourceKind == .upload ? "未选择" : "请到素材库对视频点「提取参考音」")
                     : pickedDisplayName)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(pickedPath == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
            }
        }
    }

    private func pickSourceFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedPath = url.path
        pickedDisplayName = url.lastPathComponent
        errorText = nil
        // 名字默认取文件名（去扩展名），用户可改
        if name.isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
        Task { await prepareSample() }
    }

    // MARK: - 样本质量

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            Text("样本检查").font(DesignTokens.Typography.labelEmphasis)
            HStack(spacing: 10) {
                if phase == .preparing {
                    ProgressView().controlSize(.small)
                    Text("正在检查样本…")
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                } else {
                    Label(String(format: "时长 %.1f 秒", durationSeconds),
                          systemImage: durationCheckSymbol)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(durationCheckColor)
                    Spacer()
                    Text(String(format: "建议 %d–%d 秒",
                                Int(CloneSampleValidator.minDurationSeconds),
                                Int(CloneSampleValidator.maxDurationSeconds)))
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(.tertiary)
                }
            }
            TextField("音色名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(phase == .registering)
        }
        .padding(.top, DesignTokens.Spacing.tight)
    }

    private var durationOK: Bool {
        durationSeconds >= CloneSampleValidator.minDurationSeconds
            && durationSeconds <= CloneSampleValidator.maxDurationSeconds
    }
    private var durationCheckSymbol: String {
        if phase == .preparing { return "clock" }
        return durationOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var durationCheckColor: Color {
        (phase != .preparing && durationOK) ? .green : .orange
    }

    /// 准备合规样本（裁切+ 校验）。结果写进 `pickedPath`（可能换成裁切后的临时文件）。
    private func prepareSample() async {
        guard let src = pickedPath else { return }
        phase = .preparing
        errorText = nil
        do {
            let sample = try await CloneRegistrationService().prepareSample(from: src)
            pickedPath = sample.path
            durationSeconds = sample.durationSeconds
            phase = .idle
            if sample.wasTrimmed {
                // 如实告知被裁过（用户上传的原始声音已被裁短，注册用的是中段）。
                MixLog.info("[CloneWizard] 样本已裁切至 \(String(format: "%.1f", sample.durationSeconds))s")
            }
        } catch {
            phase = .idle
            errorText = FriendlyError.reason(for: error)
            pickedPath = nil      // 不合规 ⇒ 回到「未选择」态，避免用户以为可以直接注册
        }
    }

    // MARK: - 授权

    private var consentSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            Toggle(isOn: $consent) {
                Text("我确认拥有该声音的合法授权，并理解生成的音色会用于生成配音内容。")
                    .font(DesignTokens.Typography.microRegular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .disabled(phase == .registering)
            Text("未确认授权不能注册。授权确认时间会随音色记录一起留存。")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DesignTokens.Spacing.tight)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(phase == .registering)
            Button("注册") { Task { await register() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRegister)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canRegister: Bool {
        pickedPath != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && consent && durationOK && phase != .preparing && phase != .registering
    }

    private func register() async {
        guard let path = pickedPath else { return }
        phase = .registering
        errorText = nil
        let vm = VoiceCloneViewModel()
        await vm.register(displayName: name,
                         samplePath: path,
                         sampleDuration: durationSeconds,
                         consentAccepted: consent,
                         kind: sourceKind,
                         context: modelContext)
        if let m = vm.message, m.kind == .success {
            phase = .done
            onRegistered()
        } else {
            errorText = vm.message?.text
            phase = .idle
        }
    }
}