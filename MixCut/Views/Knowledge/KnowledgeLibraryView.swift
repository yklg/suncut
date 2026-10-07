import SwiftUI
import UniformTypeIdentifiers

/// 知识库管理页（产品脚本成片的事实来源）。
///
/// 布局：顶部面板式标题 + 右侧操作（上传 / 粘贴 / 补向量）；文档列表行展示来源、字数、
/// 片段与向量状态、启用开关、删除；空态用引导卡片（无骨架屏）。
struct KnowledgeLibraryView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = KnowledgeLibraryViewModel()

    @State private var showPasteSheet = false
    @State private var activeFlow: ExternalFlow?
    @State private var documentToDelete: KnowledgeDocument?
    @State private var showScriptWizard = false

    /// 外部资料获取的单 sheet 流程（输入 → 进度 → 确认，避免多 sheet 冲突）。
    enum ExternalFlow: String, Identifiable {
        case research, link
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DesignTokens.Padding.page)
                .padding(.vertical, 12)
                .background(.bar)

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            Divider()

            if viewModel.documents.isEmpty {
                emptyState
            } else {
                documentList
            }
        }
        .task(id: project.id) {
            viewModel.setModelContext(modelContext)
            viewModel.load(for: project)
        }
        .sheet(isPresented: $showPasteSheet) {
            pasteSheet
        }
        .sheet(isPresented: $showScriptWizard) {
            ScriptWizardView(project: project)
        }
        .sheet(item: $activeFlow) { flow in
            ExternalFlowSheet(flow: flow, viewModel: viewModel) {
                activeFlow = nil
            }
        }
        .alert("确认删除文档", isPresented: Binding(
            get: { documentToDelete != nil },
            set: { if !$0 { documentToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { documentToDelete = nil }
            Button("删除", role: .destructive) {
                if let doc = documentToDelete { viewModel.delete(doc) }
                documentToDelete = nil
            }
        } message: {
            if let doc = documentToDelete {
                Text("将删除「\(doc.title)」及其全部 \(doc.chunkCount) 个片段，此操作不可撤销。")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("知识库")
                    .font(DesignTokens.Typography.title)
                Text(statSummary)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                showScriptWizard = true
            } label: {
                Label("生成脚本", systemImage: "wand.and.stars")
            }
            Button {
                presentFilePanel()
            } label: {
                Label("上传文档", systemImage: "square.and.arrow.down")
            }
            Button {
                showPasteSheet = true
            } label: {
                Label("粘贴文本", systemImage: "doc.on.clipboard")
            }
            Button {
                activeFlow = .research
            } label: {
                Label("AI 调研", systemImage: "globe")
            }
            Button {
                activeFlow = .link
            } label: {
                Label("电商链接", systemImage: "link")
            }
            Button {
                Task { await viewModel.embedPendingVectors() }
            } label: {
                Label("补向量", systemImage: "sparkles")
            }
            .help("为尚未生成向量的片段补做嵌入（需千问 Key）")
        }
    }

    private var statSummary: String {
        let docs = viewModel.documents.count
        let chunks = viewModel.documents.reduce(0) { $0 + $1.chunkCount }
        let vectors = viewModel.totalEmbeddedCount
        return "\(docs) 篇 · \(chunks) 片段 · \(vectors) 已向量化"
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(DesignTokens.Typography.label)
            Spacer()
            Button("关闭") { viewModel.errorMessage = nil }
                .font(DesignTokens.Typography.micro)
        }
        .padding(.horizontal, DesignTokens.Padding.page)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - List

    private var documentList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.documents) { document in
                    KnowledgeDocumentRow(
                        document: document,
                        embeddedCount: viewModel.embeddedCount(for: document),
                        onToggle: { viewModel.toggleEnabled(document) },
                        onDelete: { documentToDelete = document }
                    )
                }
            }
            .padding(DesignTokens.Padding.page)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("知识库还是空的")
                .font(DesignTokens.Typography.sectionTitle)
            Text("上传产品资料、电商详情、说明文档，或直接粘贴文本。\nAI 写脚本时只会引用这里的内容。")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("上传文档") { presentFilePanel() }
                    .buttonStyle(.borderedProminent)
                Button("粘贴文本") { showPasteSheet = true }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Panel

    private func presentFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .plainText, .pdf, .sourceCode,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "md") ?? .plainText
        ]
        panel.prompt = "加入知识库"
        panel.message = "选择产品资料（txt / md / pdf / docx）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await viewModel.ingestFiles(urls: panel.urls) }
    }
}

// MARK: - Document Row

private struct KnowledgeDocumentRow: View {
    let document: KnowledgeDocument
    let embeddedCount: Int
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sourceIcon)
                .font(.system(size: 16))
                .foregroundStyle(document.isEnabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(DesignTokens.Typography.bodyEmphasis)
                    .foregroundStyle(document.isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(document.source.displayLabel)
                        .font(DesignTokens.Typography.micro)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                    Text("\(document.wordCount) 字")
                    Text("\(document.chunkCount) 片段")
                    Text("\(embeddedCount)/\(document.chunkCount) 向量")
                        .foregroundStyle(embeddedCount == document.chunkCount ? Color.secondary : Color.orange)
                }
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { document.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .help(document.isEnabled ? "参与检索" : "已停用")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除文档")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var sourceIcon: String {
        switch document.source {
        case .upload:         return "doc.text"
        case .aiResearch:     return "sparkles"
        case .ecommerceLink:  return "cart"
        case .manualPaste:    return "doc.on.clipboard"
        }
    }
}

// MARK: - Paste Sheet

extension KnowledgeLibraryView {

    var pasteSheet: some View {
        PasteTextSheet { title, text in
            Task { await viewModel.ingestPastedText(title: title, text: text) }
        }
    }
}

/// 手动粘贴文本的弹窗。
struct PasteTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    let onSubmit: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴文本到知识库")
                .font(DesignTokens.Typography.sectionTitle)

            Text("标题（可选）")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)
            TextField("如：产品规格参数", text: $title)
                .textFieldStyle(.roundedBorder)

            Text("内容")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(DesignTokens.Typography.body)
                .frame(height: 240)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("加入知识库") {
                    onSubmit(title, text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - External Flow Sheet（AI 调研 / 电商链接）

/// 单 sheet 三阶段：输入 → 进度 → 确认入库。
private struct ExternalFlowSheet: View {
    let flow: KnowledgeLibraryView.ExternalFlow
    @Bindable var viewModel: KnowledgeLibraryViewModel
    let onClose: () -> Void

    @State private var topicInput = ""
    @State private var urlInput = ""

    private var isBusy: Bool {
        viewModel.phase == .researching || viewModel.phase == .resolvingLink
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let pending = viewModel.pendingExternal {
                reviewContent(pending)
            } else {
                inputContent
            }
        }
        .frame(width: 560, height: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label(flow == .research ? "AI 联网调研" : "读取产品链接",
                  systemImage: flow == .research ? "globe" : "link")
                .font(DesignTokens.Typography.bodyEmphasis)
            Spacer()
            Button {
                viewModel.discardPendingExternal()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    // MARK: Input

    @ViewBuilder private var inputContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(Color.orange)
            }

            if flow == .research {
                Text("围绕当前产品自动联网搜索并综合成带来源的资料。可补充一个关注点（可选）：")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                TextField("例如：适合敏感肌、和某竞品对比", text: $topicInput)
                    .textFieldStyle(.roundedBorder)
                Text("需在设置中配置博查 API Key；未配置时将提示。")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.secondary)
            } else {
                Text("粘贴单个产品页链接，系统将最佳努力读取正文；需要登录或验证的页面会引导你改为手动粘贴。")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            HStack {
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(flow == .research ? "正在联网调研…" : "正在读取链接…")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Button("开始") {
                    Task {
                        if flow == .research {
                            await viewModel.prepareAIResearch(focus: topicInput)
                        } else {
                            await viewModel.prepareEcommerceLink(urlInput)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || (flow == .link && urlInput.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(16)
    }

    // MARK: Review

    private func reviewContent(_ pending: KnowledgeLibraryViewModel.PendingExternal) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green)
                Text("已生成，请确认后加入知识库").font(DesignTokens.Typography.caption)
                Spacer()
                if let url = pending.sourceURL {
                    Text(url).font(DesignTokens.Typography.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            ScrollView {
                Text(pending.body)
                    .font(DesignTokens.Typography.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }

            Divider()
            HStack {
                Text("将保存为：\(pending.title)")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("放弃") {
                    viewModel.discardPendingExternal()
                    onClose()
                }
                Button("加入知识库") {
                    Task {
                        await viewModel.savePendingExternal()
                        onClose()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }
}
