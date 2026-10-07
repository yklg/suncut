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
    /// 用户选中的**源文件**路径（用户挑了哪个文件），与「样本是否合规」无关。
    @State private var pickedPath: String?
    @State private var pickedDisplayName = ""
    /// 已通过校验的合规样本 —— **样本合规性的唯一真源**。
    ///
    /// 为什么不能靠 `pickedPath != nil && durationOK`：
    /// 那两个量会**脱钩**。失败路径曾把 `pickedPath` 置 nil 却保留 `durationSeconds`，
    /// 于是「时长读数」仍停在上一份合规样本的值上；一旦 `pickedPath` 恢复非 nil
    /// （重跑校验 / 重选又选了短样本），`canRegister` 就会**误判为可注册** ⇒ 注册门被绕过。
    @State private var preparedSample: CloneRegistrationService.PreparedSample?
    @State private var durationSeconds: Double = 0
    @State private var consent = false
    @State private var phase: Phase = .idle
    /// 样本类错误（就近显示在样本检查区）。
    @State private var sampleErrorText: String?
    /// 注册类错误（显示在末尾；来自服务端）。
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
                    // 显示条件只看「用户选了文件」，**不**看合规状态——
                    // 校验失败时样本信息必须仍在（否则用户看到「刚选了文件怎么又变未选择」，
                    // 且没法就地改名、看不到建议区间）。
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
                .padding(DesignTokens.Padding.page)
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        // 尺寸唯一真源。**不再叠加 `.frame(width:)`** —— 那是本次错位的根因：
        // 硬性宽度与sheetContainerFrame 的 minWidth 语义相反，系统夹到 min 后
        // 内容仍按硬宽度排版 ⇒ 溢出被裁（标题与关闭按钮各切掉一半）。
        // 宽度取三者同值，对齐 VoicePickerSheet 的既有范式。
        .sheetContainerFrame(minWidth: 460, idealWidth: 460, maxWidth: 460,
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
        .padding(DesignTokens.Padding.page)
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
        // ⭐ 重选必须**先清掉上一份样本的合规状态**。否则在新样本校验完成前，
        // `preparedSample` 仍是上一份的 ⇒ `canRegister` 为真 ⇒ 用户能在
        // 「新样本还没验完」的窗口里点注册，注册的是**上一份的音频**。
        // 这是「读路径不做无证据修正」纪律在 UI 侧的对应：状态必须与事实同步。
        preparedSample = nil
        durationSeconds = 0
        sampleErrorText = nil
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
            // 样本类错误**就近显示**：与「建议 10–20 秒」同区。
            // 早前它落在最外层 VStack 末尾（授权勾选下方），用户要来回扫
            // 才能把「太短了」和「建议区间」对上。
            if let sampleErrorText {
                Text(sampleErrorText)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, DesignTokens.Spacing.tight)
    }

    /// 样本是否已通过校验 —— **只认 `preparedSample`**，不看 `durationSeconds`。
    ///
    /// 早前用 `durationSeconds` 的区间判定，而它在校验失败时**不会被重置**，
    /// 于是「时长读数」可能停在上一份合规样本的值上 ⇒ 注册门被绕过。
    private var durationOK: Bool { preparedSample != nil }

    private var durationCheckSymbol: String {
        if phase == .preparing { return "clock" }
        return durationOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var durationCheckColor: Color {
        (phase != .preparing && durationOK) ? .green : .orange
    }

    /// 准备合规样本（裁切 + 校验）。
    ///
    /// 状态写入约定（这组语义是本次修复的核心，改动时三处必须同批）：
    /// - `pickedPath`：**用户选了哪个源文件**。失败时**保留**（否则用户看到
    ///   「刚选了文件怎么又变回未选择」，且没法就地改名）；
    /// - `preparedSample`：**样本是否合规**的唯一真源，失败时置 nil；
    /// - `durationSeconds`：**纯展示值**，失败时归零（不归零会显示上一份的残留时长）。
    private func prepareSample() async {
        guard let src = pickedPath else { return }
        phase = .preparing
        errorText = nil
        sampleErrorText = nil
        do {
            let sample = try await CloneRegistrationService().prepareSample(from: src)
            preparedSample = sample
            pickedPath = sample.path
            durationSeconds = sample.durationSeconds
            phase = .idle
            if sample.wasTrimmed {
                // 如实告知被裁过（用户上传的原始声音已被裁短，注册用的是中段）。
                MixLog.info("[CloneWizard] 样本已裁切至 \(String(format: "%.1f", sample.durationSeconds))s")
            }
        } catch {
            phase = .idle
            preparedSample = nil
            durationSeconds = 0
            sampleErrorText = FriendlyError.reason(for: error)
            // pickedPath 刻意保留：让样本信息与名称输入框继续可见，用户可就地改或重选。
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

    /// 注册门。样本维度**只看 `preparedSample`**（合规与否的唯一真源），
    /// 刻意不看 `pickedPath` / `durationSeconds` —— 后两者会脱钩，曾导致
    /// 「校验失败后时长残留旧值」把注册门绕过去。
    private var canRegister: Bool {
        preparedSample != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && consent && phase != .preparing && phase != .registering
    }

    private func register() async {
        guard let sample = preparedSample else { return }
        phase = .registering
        errorText = nil
        sampleErrorText = nil
        let vm = VoiceCloneViewModel()
        await vm.register(displayName: name,
                         samplePath: sample.path,
                         sampleDuration: sample.durationSeconds,
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