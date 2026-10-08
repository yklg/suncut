import SwiftUI
import SwiftData

struct SettingsView: View {
    /// 设置标签页；默认「通用」——配音/视频处理等常用配置打开即见，API Key 配一次后很少再动。
    enum SettingsTab: Hashable { case api, general, agent }

    @Environment(\.dismiss) private var dismiss
    @State private var settingsTab: SettingsTab = .general
    @State private var selectedProvider: AIProviderType = KeychainHelper.activeProvider
    @State private var apiKey: String = ""
    /// 文本智能卡的操作结果（保存/测试连接），只在本卡操作行内显示——
    /// 禁止再与千问卡共享状态（曾导致千问保存失败的错误显示到文本卡）。
    @State private var apiKeyNotice: (ok: Bool, message: String)?
    @State private var isAPIKeySaved = false
    @State private var showAPIKey = false
    @State private var selectedModel: String = ""
    @State private var thinkingEnabled = false
    @State private var customBaseURL: String = ""
    @State private var customModelName: String = ""
    @State private var relayBaseURL: String = ""
    @State private var relayPlatform: RelayPlatform = KeychainHelper.relayPlatform

    // 语音与画面服务（千问 DashScope）独立于上方「文本智能」选择器的编辑状态
    @State private var qwenAPIKey: String = ""
    @State private var showQwenKey: Bool = false
    @State private var isQwenKeySaved = false
    /// 语音与画面卡的操作结果，只在本卡操作行内显示（与 apiKeyNotice 物理隔离）。
    @State private var qwenSaveNotice: (ok: Bool, message: String)?
    @State private var isDownloadingModel = false
    @State private var modelDownloadError: String?
    @State private var downloadProgress: DownloadProgress?
    @State private var downloadTask: Task<Void, Never>?
    /// 模型探测结果（档位 / 来自哪个根 / 未使用的其他档 / L2~L4 提示）。界面只显示它，不在这里做判定。
    @State private var modelReport = ModelReport(selected: nil, selectedTier: nil, usable: false, issues: [])
    /// 只读布尔：Key 的任何片段都不进界面，读 Keychain 也放后台队列。
    @State private var hasCloudKey = false
    @AppStorage(ASRSettings.preferenceKey) private var asrPreferenceRaw = ""

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AgentGateway.enabledKey) private var agentEnabled = true
    @AppStorage(AgentGateway.portKey) private var agentPort = Int(AgentGateway.defaultPort)
    @State private var selectedAgentClient: AgentClientSnippet = .claudeCode

    /// 全局默认配音音色（VoiceChoiceCoder 串；空=未配置）。
    @State private var globalVoiceID: String = VoicePreferences.globalDefaultChoice?.voiceID ?? ""
    /// M1b：音色选择器弹窗（中立 VoicePickerSheet；全局默认的写入仍在本页收口）。
    @State private var showVoicePicker = false
    /// 试听用进程级共享服务（播放器挂在单例上，避免临时对象释放导致播放即止）。
    @State private var auditionPlayer = VoiceAuditionPlayer.shared
    /// M3：原始音频缓存用量（nil = 尚未扫盘，UI 显示进度指示）。
    @State private var cacheUsage: RawAudioCacheStore.Usage?

    // MARK: - M2 我的复刻音色库
    /// 复刻音色库读侧。@Query 让 SwiftData 在库变化时自动刷新列表（增删改后 UI 立即跟上）。
    @Query(sort: \VoiceProfile.createdAt) private var cloneProfiles: [VoiceProfile] = []
    /// 写入收口 VM（视图不直写 SwiftData 字段）。
    @State private var cloneVM = VoiceCloneViewModel()
    @State private var showCloneWizard = false
    @State private var cloneKeyFingerprint: String = ""
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏 + 关闭按钮
            HStack {
                Text("设置")
                    .font(DesignTokens.Typography.bodyLargeEmphasis)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(DesignTokens.Typography.headline)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭设置")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            TabView(selection: $settingsTab) {
                apiKeySettings
                    .tabItem {
                        Label("API", systemImage: "key")
                    }
                    .tag(SettingsTab.api)

                generalSettings
                    .tabItem {
                        Label("通用", systemImage: "gear")
                    }
                    .tag(SettingsTab.general)

                agentSettings
                    .tabItem {
                        Label("Agent", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(SettingsTab.agent)
            }
        }
        .frame(width: 500, height: 470)
        .onAppear {
            loadProviderState()
            refreshASRState()
            refreshCloneKeyFingerprint()
            Task { await refreshCacheUsage() }
        }
        .sheet(isPresented: $showVoicePicker) {
            VoicePickerSheet(
                title: "全局默认音色",
                contextLine: "所有项目的改写配音与「产品脚本成片」默认使用该音色",
                current: VoicePreferences.globalDefaultChoice,
                allowsClear: true,
                clearLabel: "未配置（不自动配音）",
                onPick: { choice in
                    // 全局默认唯一写入点（空 choice = 清除）；与 globalVoiceID 试听态同源更新。
                    VoicePreferences.globalDefaultRaw = choice.map { VoiceChoiceCoder.encode($0) }
                    globalVoiceID = choice?.voiceID ?? ""
                    showVoicePicker = false
                },
                onClose: { showVoicePicker = false })
        }
        // M2：注册向导（从「我的复刻音色库」的[注册新音色] 发起）。
        .sheet(isPresented: $showCloneWizard) {
            CloneWizardView(
                onRegistered: { showCloneWizard = false },
                onCancel: { showCloneWizard = false })
        }
    }

    /// 复刻音色的 Key 指纹（决定库内哪些音色置灰）。
    ///
    /// 指纹本身只是一次 Keychain 读取 + SHA256，不该在打开设置页的主线程上做。
    /// `VoiceCloneViewModel` 是 `@MainActor`，故这里用 `Task { }`（继承 MainActor）
    /// 而**不是** `Task.detached` —— 后者在非隔离上下文调主actor 方法既不成立、
    /// 也会让「指纹从哪来」这件事分散在两个隔离域里。指纹是给 UI 读的，同actor 最简单。
    private func refreshCloneKeyFingerprint() {
        Task { cloneKeyFingerprint = VoiceCloneViewModel.currentKeyFingerprint() }
    }

    /// 模型探测放后台队列：stat + 读 4 字节文件头虽然便宜，也不该占设置页 opening 的主线程。
    private func refreshASRState() {
        Task.detached(priority: .utility) {
            let report = ASRService.modelReport()
            let cloudKey = ASRSettings.hasCloudKey
            await MainActor.run {
                modelReport = report
                hasCloudKey = cloudKey
            }
        }
    }

    /// 当前"逐段重听"实际会走哪条 —— 直接问决策表，不在界面里复制规则。
    /// 传 `storedPreference`（从没设过时是 nil）而不是 `preference`，让"没设过"与"选了自动"
    /// 在规则层合流；界面自己再判一次默认值，就会出现第三个默认值。
    private var segmentRetakeDecision: EngineDecision {
        ASREngineDecision.decide(purpose: .segmentTextRetake,
                                 preference: ASRSettings.storedPreference,
                                 hasCloudKey: hasCloudKey,
                                 local: LocalASRState(usable: modelReport.usable,
                                                      tier: modelReport.selectedTier))
    }

    /// 绑定：存的是 raw（没设过 ⇒ 空串 ⇒ 由规则层回落默认），显示的是生效值。
    private var asrPreference: Binding<ASRPreference> {
        Binding(
            get: { ASRPreference(rawValue: asrPreferenceRaw) ?? ASRPolicy.defaultPreference },
            set: { asrPreferenceRaw = $0.rawValue }
        )
    }

    /// 「large-v3（2.9 GB）· 来自你下载的文件夹 · 另检测到 base（未使用）」
    private var modelDetailText: String {
        guard let selected = modelReport.selected else { return "未检测到语音模型" }
        let tier = modelReport.selectedTier ?? "档位未识别"
        var text = "\(tier)（\(formatBytes(selected.byteCount))）· 来自\(selected.root.displayName)"
        let others = modelReport.detected.dropFirst().compactMap {
            WhisperModelCatalog.tier(ofFileName: $0.fileName) ?? $0.fileName
        }
        if !others.isEmpty {
            text += " · 另检测到 \(others.joined(separator: "、"))（未使用）"
        }
        return text
    }

    /// L2/L3/L4 的提示。**只提示，不否决**（红线 R2）：这里任何一条都不改变"已就绪"。
    /// 措辞取自 `ModelIssue.userText`（与 `get_asr_status` 同一份，不在界面里复写）。
    private var modelHintLines: [String] {
        modelReport.issues.map(\.userText)
    }

    /// 决策结论的界面呈现。一句话说明白：这个开关**只管逐段重听**，
    /// 整片听写恒走本机（云端没有字级时间戳），别让用户以为改了它就能把整片送云端。
    private var routeSummary: String {
        switch segmentRetakeDecision {
        case .use(let engine, let reason):
            return "\(engine.displayName) · \(reason)（整片听写不受此项影响）"
        case .refused(let reason):
            return "走不通：\(reason)"
        }
    }

    private var downloadButtonTitle: String {
        let size = WhisperModelCatalog.expectedBytes(forTier: ASRPolicy.engineTier)
            .map { " (~\(formatBytes($0)))" } ?? ""
        return "下载 \(ASRPolicy.engineTier)\(size)"
    }

    // MARK: - API Key 设置
    private var apiKeySettings: some View {
        Form {
            Section("文本智能（分镜分析 / 方案生成 / 台词改写 · 六选一）") {
                Picker("提供商", selection: $selectedProvider) {
                    ForEach(AIProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: selectedProvider) { _, newValue in
                    KeychainHelper.activeProvider = newValue
                    loadProviderState()
                }
            }

            Section("\(selectedProvider.displayName) 配置") {
                HStack(spacing: DesignTokens.Spacing.compact) {
                    if showAPIKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignTokens.Typography.labelMono)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showAPIKey.toggle()
                        if showAPIKey {
                            if let realKey = KeychainHelper.getAPIKey(for: selectedProvider) {
                                apiKey = realKey
                            }
                        } else {
                            if isAPIKeySaved {
                                apiKey = "••••••••••••••••••••"
                            }
                        }
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showAPIKey ? "隐藏密钥" : "显示密钥")
                }

                if selectedProvider == .custom {
                    TextField("API 地址", text: $customBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .font(DesignTokens.Typography.labelMono)

                    TextField("模型名称", text: $customModelName, prompt: Text("gpt-4o"))
                        .textFieldStyle(.roundedBorder)
                        .font(DesignTokens.Typography.labelMono)
                } else {
                    if selectedProvider == .claudeRelay {
                        TextField("网关地址", text: $relayBaseURL,
                                  prompt: Text("https://your-relay.example.com/v1"))
                            .textFieldStyle(.roundedBorder)
                            .font(DesignTokens.Typography.labelMono)

                        Text("要求兼容 OpenAI 协议的转发网关地址")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.tertiary)

                        Picker("平台", selection: $relayPlatform) {
                            ForEach(RelayPlatform.allCases) { platform in
                                Text(platform.displayName).tag(platform)
                            }
                        }
                        .onChange(of: relayPlatform) { _, newValue in
                            KeychainHelper.relayPlatform = newValue
                            // 切换平台后将模型重置为新平台的默认模型
                            selectedModel = newValue.defaultModel
                            KeychainHelper.setSelectedModel(selectedModel, for: .claudeRelay)
                        }
                    }

                    Picker("模型", selection: $selectedModel) {
                        ForEach(selectedProvider.models, id: \.self) { model in
                            Text(selectedProvider.modelDisplayName(model)).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { _, newValue in
                        KeychainHelper.setSelectedModel(newValue, for: selectedProvider)
                    }

                    if selectedProvider.supportsThinkingToggle(model: selectedModel) {
                        Toggle("深度思考", isOn: $thinkingEnabled)
                            .onChange(of: thinkingEnabled) { _, newValue in
                                KeychainHelper.setThinkingEnabled(newValue, for: selectedProvider)
                            }
                        Text("开启后模型先推理再作答，效果更好但更慢、消耗更多 tokens。对分镜分析、方案生成、台词改写等所有 AI 调用生效")
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.secondary)
                    }
                }

                KeyManagementActionBar(
                    saveTitle: "保存",
                    isSaved: isAPIKeySaved,
                    canSave:
                        // Key 已保存（显示为掩码）时**仍可保存**——接口地址 / 模型名是独立可改的。
                        // 原先掩码态一律禁用，导致自定义提供商存过 Key 后再也改不了地址和模型名。
                        !(apiKey.isEmpty && !isAPIKeySaved)
                        && !(selectedProvider == .custom && (customBaseURL.isEmpty || customModelName.isEmpty))
                        && !(selectedProvider == .claudeRelay && relayBaseURL.isEmpty)
                        && endpointURLProblem == nil,
                    onSave: saveAPIKey,
                    onClear: clearAPIKey,
                    // 测试连接：Key 填错 / 过期 / 没开通模型权限，以前要等导入流水线跑到
                    // 第 5 步 AI 分析（十几分钟后）才暴露。这里花 1 秒当场验明。
                    onTest: {
                        let started = Date()
                        let provider = AIProviderManager.createProvider(for: selectedProvider)
                        _ = try await provider.generateText(prompt: "ping")
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        return "连接正常 · \(selectedProvider.displayName) · \(ms)ms"
                    },
                    notice: $apiKeyNotice)

                // 地址填错时**当场说明为什么不能保存**，而不是把保存按钮灰掉让用户干瞪眼
                if let problem = endpointURLProblem {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignTokens.Palette.Status.warning)
                        Text(problem)
                            .font(DesignTokens.Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }

            // MARK: 语音与画面服务（独立于上方文本智能）
            Section("语音与画面服务（阿里云百炼 DashScope · 独立 Key）") {
                // Key 输入行（复用上方交互模式，但状态独立）
                HStack(spacing: DesignTokens.Spacing.compact) {
                    if showQwenKey {
                        TextField("千问 API Key", text: $qwenAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(DesignTokens.Typography.labelMono)
                    } else {
                        SecureField("千问 API Key", text: $qwenAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button {
                        showQwenKey.toggle()
                        if showQwenKey {
                            qwenAPIKey = KeychainHelper.dashScopeKey ?? qwenAPIKey
                        } else if isQwenKeySaved {
                            qwenAPIKey = "••••••••••••••••••••"
                        }
                    } label: {
                        Image(systemName: showQwenKey ? "eye.slash" : "eye")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showQwenKey ? "隐藏密钥" : "显示密钥")
                }

                // 能力对照：这把 Key 能解锁的四项能力
                capabilityRow(title: "原声克隆",
                              detail: "自动复刻原主播嗓音（qwen-voice-enrollment + qwen3-tts-vc）")
                capabilityRow(title: "TTS 配音合成",
                              detail: "用克隆嗓音为改写台词生成配音")
                capabilityRow(title: "云端语音识别",
                              detail: "可选；本地 Whisper 已就绪时无需使用")
                capabilityRow(title: "AI 画面替换",
                              detail: "Wan2.5 视频编辑接口")

                // 同 Key 身份声明：Key 按提供商身份存储，文本智能选千问时与此处是同一把。
                Text("千问 Key 同时服务上方文本智能（提供商选「千问」时）与本区域四项能力，是同一把 Key，任一处保存两边同时生效。")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 共存说明
                Text("此 Key 与上方「文本智能」所选厂商相互独立、可同时配置：例如文本用 DeepSeek，配音/画面用千问，互不影响。")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 操作行（与上方文本智能卡共用同一组件：顺序/样式/结果行单一真源）
                KeyManagementActionBar(
                    saveTitle: "保存千问 Key",
                    isSaved: isQwenKeySaved,
                    canSave: !qwenAPIKey.isEmpty && !qwenAPIKey.starts(with: "•"),
                    onSave: saveQwenKey,
                    onClear: clearQwenKey,
                    // 媒体 Key 与文本「千问」是同一把钥匙，ping DashScope 即验证账户 Key 有效性
                    onTest: {
                        let started = Date()
                        let provider = AIProviderManager.createProvider(for: .qwen)
                        _ = try await provider.generateText(prompt: "ping")
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        return "连接正常 · 千问 DashScope · \(ms)ms"
                    },
                    notice: $qwenSaveNotice)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 语音/画面能力对照行：绿色对勾 + 能力标题 + 三级色说明。
    @ViewBuilder
    private func capabilityRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DesignTokens.Typography.caption.weight(.medium))
                Text(detail)
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 千问 Key 操作

    private func saveQwenKey() {
        // 与 saveAPIKey 同口径：trim 防复制带入空格/换行导致每次调用 401。
        let trimmed = qwenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.starts(with: "•") else { return }
        do {
            try KeychainHelper.saveAPIKey(trimmed, for: .qwen)
            isQwenKeySaved = true
            qwenAPIKey = "••••••••••••••••••••"
            qwenSaveNotice = nil
            MixLog.info("千问 API Key 已保存（语音与画面服务）")
        } catch {
            // 结果只进本卡，禁止再写共享变量（曾串到上方文本卡显示）
            qwenSaveNotice = (false, "保存失败：\(FriendlyError.reason(for: error))")
        }
    }

    private func clearQwenKey() {
        try? KeychainHelper.removeAPIKey(for: .qwen)
        isQwenKeySaved = false
        qwenAPIKey = ""
        showQwenKey = false
        qwenSaveNotice = nil
    }

    // MARK: - 通用设置
    private var generalSettings: some View {
        Form {
            Section("配音") {
                // M1b：音色行（当前值副标题 + 试听 + [更改] 弹中立选择器），不再用 80 项系统 Menu。
                LabeledContent {
                    HStack(spacing: 8) {
                        Button {
                            // M2：传**音色身份**（含引擎/型号），不再传裸 voiceId ——
                            // 裸 id 让播放器无从判断该用 CosyVoice 还是 qwen 客户端，
                            // 导致复刻音色试听必然失败且错误文案被误诊。
                            if let ch = VoicePreferences.globalDefaultChoice {
                                auditionPlayer.play(ch)
                            } else {
                                auditionPlayer.playPreset(globalVoiceID)   // 未配置 ⇒ 明确报错
                            }
                        } label: {
                            Label(auditionPlayer.isAuditioning ? "试听中…" : "试听",
                                  systemImage: "play.circle")
                        }
                        .controlSize(.small)
                        .disabled(globalVoiceID.isEmpty || auditionPlayer.isAuditioning)
                        Button("更改") { showVoicePicker = true }
                            .controlSize(.small)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全局默认音色")
                        Text(globalVoiceID.isEmpty
                             ? "未配置（不自动配音）"
                             : VoiceCatalog.displayName(id: globalVoiceID))
                            .font(DesignTokens.Typography.microRegular)
                            .foregroundStyle(.secondary)
                        if let err = auditionPlayer.lastError {
                            Text(err)
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }

                Text("所有项目的改写配音与「产品脚本成片」默认使用该音色，直接合成、无需逐视频克隆。项目可在概览页单独覆盖；已克隆原声的视频仍保留其克隆音色。")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // M3：原始音频缓存用量与清理。放在「存储」外的「配音」区，
                // 因为它是配音成本的一部分（命中即省一次 TTS 计费）。
                Divider()
                LabeledContent("原始音频缓存") {
                    HStack(spacing: 8) {
                        if let usage = cacheUsage {
                            Text(usage.fileCount == 0
                                 ? "暂无缓存"
                                 : "\(usage.fileCount) 项 · \(formatBytes(usage.bytes))"
                                 + (usage.isOverBudget ? "（超上限）" : ""))
                                .font(DesignTokens.Typography.microRegular)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Button("刷新") { Task { await refreshCacheUsage() } }
                            .controlSize(.small)
                        Button("清空") {
                            Task { await clearRawAudioCache() }
                        }
                        .controlSize(.small)
                        .disabled(cacheUsage?.fileCount ?? 0 == 0)
                    }
                }
                Text("缓存的是 TTS 原始音频（同一段文案换分镜重生成时可直接复用，省一次合成计费）；每个分镜仍按各自时长单独对齐。已生成配音是独立的成品文件，清空缓存不影响它们。")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // M2：我的复刻音色库。放在「配音」区里，因为它就是配音音色的一部分。
                Divider()
                CloneLibrarySection(
                    profiles: cloneProfiles,
                    currentKeyFingerprint: cloneKeyFingerprint.isEmpty ? nil : cloneKeyFingerprint,
                    onRegister: { showCloneWizard = true },
                    onDelete: { profile, scope in
                        Task { await cloneVM.delete(profile, scope: scope, context: modelContext) }
                    },
                    onRename: { profile, name in cloneVM.rename(profile, to: name) })
            }

            Section("视频处理") {
                LabeledContent("FFmpeg") {
                    let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil, inDirectory: "bin") != nil
                        || Bundle.main.path(forResource: "ffmpeg", ofType: nil) != nil
                    let system = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
                        .contains { FileManager.default.fileExists(atPath: $0) }
                    dependencyStatus(installed: bundled || system, installHint: "已内置于应用中")
                }

                LabeledContent("Whisper") {
                    dependencyStatus(installed: ASRService.isAvailable, installHint: "已内置于应用中")
                }

                Picker("台词重听引擎", selection: asrPreference) {
                    ForEach(ASRPreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }

                LabeledContent("当前生效") {
                    Text(routeSummary)
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("语音模型") {
                    if modelReport.usable {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                            HStack(spacing: DesignTokens.Spacing.tight) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(DesignTokens.Typography.label)
                                    .foregroundStyle(.green)
                                Text(modelDetailText)
                                    .font(DesignTokens.Typography.label)
                            }
                            ForEach(modelHintLines, id: \.self) { hint in
                                Text(hint)
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if isDownloadingModel {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                            if let p = downloadProgress, p.totalBytes > 0 {
                                ProgressView(value: p.fraction)
                                    .controlSize(.small)
                                    .frame(width: 200)
                                HStack(spacing: 6) {
                                    Text(String(format: "%.1f%%", p.fraction * 100))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text("\(formatBytes(p.receivedBytes)) / \(formatBytes(p.totalBytes))")
                                        .font(DesignTokens.Typography.microMono)
                                        .foregroundStyle(.secondary)
                                    if p.bytesPerSecond > 0 {
                                        Text("• \(formatBytes(Int64(p.bytesPerSecond)))/s")
                                            .font(DesignTokens.Typography.microMono)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                HStack(spacing: DesignTokens.Spacing.tight) {
                                    ProgressView().controlSize(.small)
                                    Text("连接中…").font(DesignTokens.Typography.label).foregroundStyle(.secondary)
                                }
                            }
                            Button("取消") {
                                downloadTask?.cancel()
                            }
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                            HStack(spacing: DesignTokens.Spacing.tight) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.orange)
                                Text("语音识别需要先下载模型")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button(downloadButtonTitle) {
                                downloadWhisperModel()
                            }
                            .controlSize(.small)
                            if let error = modelDownloadError {
                                Text(error)
                                    .font(DesignTokens.Typography.microRegular)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }

            Section("存储") {
                LabeledContent("数据目录") {
                    Text(FileHelper.appSupportDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }

                Button {
                    NSWorkspace.shared.open(FileHelper.appSupportDirectory)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "folder")
                            .font(DesignTokens.Typography.caption)
                        Text("在 Finder 中打开")
                            .font(DesignTokens.Typography.label)
                    }
                }
                .controlSize(.small)
            }

            Section("系统信息") {
                let hw = HardwareProfile.shared

                LabeledContent("芯片型号") {
                    Text(hw.chipDisplayName)
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("CPU 核心数") {
                    if hw.isAppleSilicon && hw.performanceCores > 0 && hw.performanceCores < hw.physicalCores {
                        Text("\(hw.physicalCores) 核（\(hw.performanceCores) 性能 + \(hw.physicalCores - hw.performanceCores) 效率）")
                            .font(DesignTokens.Typography.label)
                    } else {
                        Text("\(hw.physicalCores) 核")
                            .font(DesignTokens.Typography.label)
                    }
                }
                LabeledContent("内存") {
                    Text("\(hw.memoryGB) GB")
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("Media Engine") {
                    Text(hw.mediaEngineDescription)
                        .font(DesignTokens.Typography.label)
                }
                LabeledContent("GPU 编码加速") {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: hw.videoToolboxAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hw.videoToolboxAvailable ? .green : .red)
                        Text(hw.videoToolboxAvailable ? "VideoToolbox" : "无")
                            .font(DesignTokens.Typography.label)
                    }
                }
                LabeledContent("Whisper 后端") {
                    Text(hw.whisperBackend)
                        .font(DesignTokens.Typography.label)
                }
            }

            Section("并发策略") {
                LabeledContent("同时分析视频数") {
                    Text(ConcurrencyPolicy.explainAnalyze())
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时导出视频数") {
                    Text(ConcurrencyPolicy.explainExport())
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("同时 ASR 数") {
                    Text(ConcurrencyPolicy.explainASR())
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
            }

            Section("版本") {
                LabeledContent("应用版本") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("使用引导") {
                    Button {
                        hasCompletedOnboarding = false
                        dismiss()
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "questionmark.circle")
                                .font(DesignTokens.Typography.caption)
                            Text("重新查看")
                                .font(DesignTokens.Typography.label)
                        }
                    }
                    .controlSize(.small)
                }

                LabeledContent("键盘快捷键") {
                    Button {
                        dismiss()
                        // 延迟 让 dismiss 完成再发通知
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NotificationCenter.default.post(name: .mixCutShowShortcuts, object: nil)
                        }
                    } label: {
                        HStack(spacing: DesignTokens.Spacing.tight) {
                            Image(systemName: "keyboard")
                                .font(DesignTokens.Typography.caption)
                            Text("查看")
                                .font(DesignTokens.Typography.label)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Agent 接入设置

    /// 各 Agent 客户端的注册片段。MCP 没有一条通用注册命令，
    /// 但核心信息只有服务地址一个；JSON（mcpServers 格式）是事实标准。
    enum AgentClientSnippet: String, CaseIterable, Identifiable {
        case url = "服务地址（通用）"
        case claudeCode = "Claude Code"
        case cursorJSON = "Cursor / Cline / Claude Desktop（JSON）"
        case codex = "Codex CLI / 桌面版"
        case workbuddy = "WorkBuddy（腾讯）"
        case geminiCLI = "Gemini CLI"
        case vscode = "VS Code Copilot"

        var id: String { rawValue }

        private static func endpoint(_ port: Int) -> String {
            "http://127.0.0.1:\(port)/mcp"
        }

        func snippet(port: Int) -> String {
            let url = Self.endpoint(port)
            switch self {
            case .url:
                return url
            case .claudeCode:
                return "claude mcp add --transport http \(Brand.mcpServerName) \(url)"
            case .cursorJSON:
                return """
                {
                  "mcpServers": {
                    "\(Brand.mcpServerName)": { "url": "\(url)" }
                  }
                }
                """
            case .codex:
                return """
                [mcp_servers.\(Brand.mcpServerName)]
                command = "npx"
                args = ["-y", "mcp-remote", "\(url)"]
                """
            case .workbuddy:
                return """
                {
                  "mcpServers": {
                    "\(Brand.mcpServerName)": { "url": "\(url)", "transport": "http" }
                  }
                }
                """
            case .geminiCLI:
                return """
                {
                  "mcpServers": {
                    "\(Brand.mcpServerName)": { "httpUrl": "\(url)" }
                  }
                }
                """
            case .vscode:
                return """
                {
                  "servers": {
                    "\(Brand.mcpServerName)": { "type": "http", "url": "\(url)" }
                  }
                }
                """
            }
        }

        var hint: String {
            switch self {
            case .url:
                return "支持 MCP（Streamable HTTP）的客户端只需要这个地址；不懂 MCP 的 Agent 也可以直接对它 POST JSON-RPC。"
            case .claudeCode:
                return "在终端里执行这条命令即可。"
            case .cursorJSON:
                return "合并进对应配置：Cursor 是项目下 .cursor/mcp.json；Cline 在扩展的 MCP 设置里；Claude Desktop 在 设置→连接器。"
            case .codex:
                return "追加到 ~/.codex/config.toml，CLI 和桌面版共用这份配置（桌面版改完重启 app 生效）。Codex 走 stdio，用 mcp-remote 桥接，需要 Node.js。"
            case .workbuddy:
                return "在 WorkBuddy 的 MCP 设置（mcp.json 或可视化 MCP 配置界面）里添加。"
            case .geminiCLI:
                return "合并进 ~/.gemini/settings.json。"
            case .vscode:
                return "写入项目下 .vscode/mcp.json。"
            }
        }
    }

    /// 注册后的验证指令：用户复制给 Agent 执行，能返回项目清单即代表链路通了
    private static let agentVerifyPrompt = "请调用 \(Brand.mcpServerName) 的 list_projects 工具，列出我的所有项目，每行输出：项目名｜状态｜视频数｜分镜数。"

    private var agentSettings: some View {
        Form {
            Section("本机 Agent 接入（MCP）") {
                Toggle("启用 Agent 服务", isOn: $agentEnabled)
                    .onChange(of: agentEnabled) { _, _ in
                        AgentGateway.shared.restartFromSettings()
                    }
                TextField("端口", value: $agentPort, format: .number.grouping(.never))
                    .onSubmit { AgentGateway.shared.restartFromSettings() }
                    .disabled(!agentEnabled)
                Text("服务只监听 127.0.0.1，仅本机可访问。改端口后回车生效。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
            Section("注册到 Agent 客户端") {
                Picker("客户端", selection: $selectedAgentClient) {
                    ForEach(AgentClientSnippet.allCases) { client in
                        Text(client.rawValue).tag(client)
                    }
                }
                .pickerStyle(.menu)

                HStack(alignment: .top) {
                    Text(selectedAgentClient.snippet(port: agentPort))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selectedAgentClient.snippet(port: agentPort), forType: .string)
                    }
                }
                Text(selectedAgentClient.hint)
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
            Section("注册后验证（把这句话复制给 Agent 执行）") {
                HStack(alignment: .top) {
                    Text(Self.agentVerifyPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.agentVerifyPrompt, forType: .string)
                    }
                }
                Text("预期返回：你的项目清单，与 \(Brand.displayName) 侧边栏一致（含状态、视频数、分镜数）。能列出来即注册成功；若 Agent 说找不到工具或连接失败，确认 \(Brand.displayName) 正在运行、端口一致后重试。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
            Section("可以这样指挥 Agent（仅示例，按你的实际项目和分镜说）") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("「把项目一里 1 号视频的 3 到 5 号分镜标签改成痛点，字幕换成纯色遮挡，结尾都延 10 帧」")
                    Text("「把这个文件夹里的 20 条视频导入新项目跑分析，失败的汇总告诉我」")
                    Text("「用 1 号视频的 1、2 号分镜加 2 号视频的 4 号分镜组个方案，导出到桌面」")
                }
                .font(DesignTokens.Typography.label)
                Text("视频编号看素材导入页卡片左上角的「N 号」徽章，分镜编号看分镜卡片的 # 号；一句话可以带多个操作，Agent 会自己拆解执行。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
            Section("Agent 能调用的功能（\(AgentToolCatalog.all.count) 个）") {
                ForEach(AgentToolCatalog.all, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.system(.caption, design: .monospaced))
                        Text(tool.description)
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Text("以上是 Agent 的全部权限边界：不能拆分分镜、不能做画面替换变体。删除项目需 Agent 二次确认（先返回影响预览）；删除分镜/视频/项目执行后无撤销。")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func dependencyStatus(installed: Bool, installHint: String) -> some View {
        if installed {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "checkmark.circle.fill")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.green)
                Text("已安装")
                    .font(DesignTokens.Typography.label)
            }
        } else {
            HStack(spacing: DesignTokens.Spacing.tight) {
                Image(systemName: "xmark.circle.fill")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(.red)
                Text(installHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 操作

    private func loadProviderState() {
        isAPIKeySaved = KeychainHelper.hasAPIKey(for: selectedProvider)

        // 历史保存的 model ID 可能已被新版本移除，回退到 defaultModel
        let stored = KeychainHelper.selectedModel(for: selectedProvider)
        if selectedProvider == .custom {
            selectedModel = stored
        } else if selectedProvider.models.contains(stored) {
            selectedModel = stored
        } else {
            selectedModel = selectedProvider.defaultModel
            KeychainHelper.setSelectedModel(selectedModel, for: selectedProvider)
        }

        thinkingEnabled = KeychainHelper.thinkingEnabled(for: selectedProvider)
        customBaseURL = KeychainHelper.customBaseURL
        customModelName = KeychainHelper.customModelName
        relayBaseURL = KeychainHelper.relayBaseURL
        relayPlatform = KeychainHelper.relayPlatform
        showAPIKey = false
        if isAPIKeySaved {
            apiKey = "••••••••••••••••••••"
        } else {
            apiKey = ""
        }

        // 千问 Key 状态独立于 selectedProvider：切厂商不影响其载入，避免切走再切回状态丢失。
        isQwenKeySaved = KeychainHelper.hasAPIKey(for: .qwen)
        showQwenKey = false
        qwenAPIKey = isQwenKeySaved ? "••••••••••••••••••••" : ""
    }

    /// 接口地址填得不对时的具体说明；没问题返回 nil。
    ///
    /// 在**保存前**就拦下来。否则地址错了要等到导入流水线跑到 AI 分析那步才炸，
    /// 报错还只是一句"连接失败，请检查网络"，把排查方向完全带偏。
    private var endpointURLProblem: String? {
        let raw: String
        switch selectedProvider {
        case .custom:      raw = customBaseURL
        case .claudeRelay: raw = relayBaseURL
        default:           return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }   // 空由 disabled 条件另行处理

        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return "接口地址需要以 https:// 开头（例如 https://api.example.com/v1）"
        }
        guard let url = URL(string: trimmed), url.host?.isEmpty == false else {
            return "接口地址格式不合法，请检查是否有多余的空格或中文字符"
        }
        if trimmed.hasSuffix("/chat/completions") || trimmed.hasSuffix("/messages") {
            return "这里只填根地址（通常以 /v1 结尾），不要带 /chat/completions 或 /messages"
        }
        return nil
    }

    private func saveAPIKey() {
        // ⚠️ 必须 trim：从网页复制 Key 极易带上尾部空格或换行，
        // 存进去之后每一次 AI 调用都会 401，而错误信息只会说"Key 无效"，
        // 用户肉眼看输入框里的 Key 明明是对的，根本查不出问题。
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // 接口地址与模型名即使不改 Key 也要能单独保存（见下方 saveEndpointConfig 的说明）
        saveEndpointConfig()

        guard !trimmedKey.isEmpty, !trimmedKey.starts(with: "•") else { return }
        do {
            try KeychainHelper.saveAPIKey(trimmedKey, for: selectedProvider)
            isAPIKeySaved = true
            MixLog.info("API Key 已保存: provider=\(selectedProvider.displayName)")
            apiKey = "••••••••••••••••••••"
            apiKeyNotice = nil
        } catch {
            // 保存失败以前只写日志，界面上「已保存」的绿标不出现但没有任何原因
            apiKeyNotice = (false, "保存失败：\(FriendlyError.reason(for: error))")
        }
    }

    /// 保存接口地址 / 模型名 / 网关平台。
    ///
    /// ⚠️ 必须与 Key 的保存**解耦**。原先这些只在 `saveAPIKey` 里落盘，而保存成功后
    /// `apiKey` 会变成掩码 `••••`，`saveAPIKey` 开头又 `guard !starts(with:"•")` 直接返回 ——
    /// 于是用「自定义 / 转发网关」的用户存过 Key 之后就**再也改不了接口地址和模型名**，
    /// 只能先清除 Key 再重新粘贴一遍。
    private func saveEndpointConfig() {
        if selectedProvider == .custom {
            KeychainHelper.customBaseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainHelper.customModelName = model
            KeychainHelper.setSelectedModel(model, for: .custom)
        }
        if selectedProvider == .claudeRelay {
            KeychainHelper.relayBaseURL = relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainHelper.relayPlatform = relayPlatform
        }
    }

    private func clearAPIKey() {
        try? KeychainHelper.removeAPIKey(for: selectedProvider)
        isAPIKeySaved = false
        apiKey = ""
    }

    private func downloadWhisperModel() {
        isDownloadingModel = true
        modelDownloadError = nil
        downloadProgress = nil
        downloadTask = Task { @MainActor in
            do {
                let asr = ASRService()
                // 不下传 modelName：档位由 ASRPolicy 定（红线 R3），界面这里不留第二个档位选择
                _ = try await asr.downloadModelIfNeeded(
                    onProgress: { progress in
                        Task { @MainActor in
                            downloadProgress = progress
                        }
                    }
                )
                refreshASRState()
            } catch is CancellationError {
                modelDownloadError = "已取消"
            } catch {
                modelDownloadError = error.localizedDescription
            }
            isDownloadingModel = false
            downloadProgress = nil
            downloadTask = nil
        }
    }

    /// 把字节数格式化为 KB / MB / GB
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    // MARK: - M3 原始音频缓存

    /// 扫盘刷新用量读数。
    private func refreshCacheUsage() async {
        cacheUsage = await RawAudioCacheStore.shared.usage()
    }

    /// 清空缓存。缓存与成品配音解耦（成品是独立自包含的 m4a），故可全清。
    private func clearRawAudioCache() async {
        _ = await RawAudioCacheStore.shared.clearAll()
        await refreshCacheUsage()
    }

}

// MARK: - Key 管理操作行（两张 Key 卡片唯一真源）

/// 「已保存 + 保存/测试连接/清除 + 结果提示」操作行。
///
/// 文本智能卡与语音画面卡必须共用本组件：此前两处手写复制后各自演化，出现按钮顺序相反、
/// 蓝底/白底不一、其中一卡缺测试连接，且共享 @State 导致错误串卡显示。
/// 顺序与样式契约恒定，由 SettingsKeyActionBarGuardTests 源码守卫健在。
fileprivate struct KeyManagementActionBar: View {
    typealias Notice = (ok: Bool, message: String)

    let saveTitle: String
    let isSaved: Bool
    let canSave: Bool
    let onSave: () -> Void
    let onClear: () -> Void
    /// 返回成功文案；nil = 本卡不提供「测试连接」。
    var onTest: (() async throws -> String)?
    /// 父视图持有的保存结果（按卡各自一份 @State，禁止跨卡共享）。
    @Binding var notice: Notice?

    /// 测试过程与结果由组件自持，不上升到父视图。
    @State private var isTesting = false
    @State private var testResult: Notice?

    /// 保存类提示优先；无保存提示时显示最近一次测试结果。
    private var shown: Notice? { notice ?? testResult }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: DesignTokens.Spacing.compact) {
                if isSaved {
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(.green)
                        Text("已保存")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                // 顺序恒定：保存 → 测试连接 → 清除；统一白底 bordered/small（不依赖 Form 默认样式）
                Button(saveTitle, action: onSave)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canSave)

                if isSaved, let onTest {
                    Button {
                        Task { await runTest(onTest) }
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTesting)
                }

                if isSaved {
                    Button("清除", role: .destructive, action: onClear)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let shown {
                HStack(spacing: 6) {
                    Image(systemName: shown.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(shown.ok
                                         ? DesignTokens.Palette.Status.success
                                         : DesignTokens.Palette.Status.warning)
                    Text(shown.message)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(shown.ok ? .secondary : .primary)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
    }

    private func runTest(_ work: () async throws -> String) async {
        isTesting = true
        // 开测先清旧提示：保存提示与测试结果同槽，避免上一条结果误导本次判定
        notice = nil
        testResult = nil
        do {
            testResult = (true, try await work())
        } catch {
            testResult = (false, FriendlyError.reason(for: error))
        }
        isTesting = false
    }
}
