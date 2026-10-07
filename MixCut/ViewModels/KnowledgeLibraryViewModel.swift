import Foundation
import SwiftData

/// 知识库页视图模型：按**当前项目所属产品**加载与管理 KnowledgeDocument。
///
/// - 数据隔离：只呈现 `product == project.product` 的文档（同产品下多个项目共享知识库）；
/// - 无骨架屏（走 ImportView 先例）：SwiftData 查询为实时权威源；
/// - 进度态使用枚举（无 isLoading Bool，对齐 G01）。
@Observable
@MainActor
final class KnowledgeLibraryViewModel {

    enum Phase: Equatable {
        case idle
        case ingesting
        case refreshingVectors
        case researching
        case resolvingLink
    }

    /// 已生成、待用户确认入库的外部内容（AI 调研 / 电商链接）。
    struct PendingExternal: Equatable {
        var kind: KnowledgeSource
        var title: String
        var body: String
        var sourceURL: String?
    }

    var phase: Phase = .idle
    var documents: [KnowledgeDocument] = []
    var errorMessage: String?
    /// 最近一次入库结果（用于短暂提示）。
    var lastOutcome: KnowledgeIngestService.Outcome?
    /// 待确认的外部内容（非 nil 时确认视图可保存）。
    var pendingExternal: PendingExternal?

    private var modelContext: ModelContext?
    /// 当前绑定的产品（由 load 时的 project 决定）。
    private(set) var boundProduct: Product?

    var isBusy: Bool { phase != .idle }

    /// 某文档中已生成向量的片段数（关系读取只允许出现在 VM，View 不直接读 `chunks`）。
    func embeddedCount(for document: KnowledgeDocument) -> Int {
        document.chunks.reduce(0) { $0 + ($1.embeddingData != nil ? 1 : 0) }
    }

    /// 全部文档中已向量化的片段总数。
    var totalEmbeddedCount: Int {
        documents.reduce(0) { $0 + embeddedCount(for: $1) }
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Load

    func load(for project: Project) {
        guard let context = modelContext else { return }
        boundProduct = project.product
        let productID = project.product?.id

        let descriptor = FetchDescriptor<KnowledgeDocument>(
            predicate: #Predicate { doc in
                doc.product?.id == productID
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        documents = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Ingest

    /// 从所选文件入库。
    func ingestFiles(urls: [URL]) async {
        guard let context = modelContext, let product = boundProduct else { return }
        phase = .ingesting
        errorMessage = nil
        defer { phase = .idle }

        for url in urls {
            do {
                let outcome = try await KnowledgeIngestService.ingest(
                    fileURL: url, product: product, source: .upload,
                    context: context)
                lastOutcome = outcome
            } catch {
                errorMessage = "「\(url.lastPathComponent)」\(error.localizedDescription)"
            }
        }
        refreshList()
    }

    /// 从手动粘贴的文本入库。
    func ingestPastedText(title: String, text: String) async {
        guard let context = modelContext, let product = boundProduct else { return }
        phase = .ingesting
        errorMessage = nil
        defer { phase = .idle }

        do {
            let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome = try await KnowledgeIngestService.ingest(
                title: finalTitle.isEmpty ? "手写资料 \(Date().formatted(.dateTime.month().day().hour().minute()))" : finalTitle,
                text: text,
                product: product,
                source: .manualPaste,
                context: context)
            lastOutcome = outcome
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshList()
    }

    // MARK: - Mutations

    func toggleEnabled(_ document: KnowledgeDocument) {
        document.isEnabled.toggle()
        try? modelContext?.save()
    }

    func delete(_ document: KnowledgeDocument) {
        do {
            try KnowledgeIngestService.delete(document, context: try requireContext())
            documents.removeAll { $0.id == document.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 对缺向量的文档补做嵌入（用户手动触发；未配 Key 给出提示）。
    func embedPendingVectors() async {
        guard let context = modelContext else { return }
        guard KeychainHelper.dashScopeKey != nil else {
            errorMessage = "未配置千问 API Key；向量路不可用时检索自动使用关键词单路"
            return
        }
        phase = .refreshingVectors
        errorMessage = nil
        defer { phase = .idle }

        for document in documents where document.chunks.contains(where: { $0.embeddingData == nil }) {
            _ = try? await KnowledgeIngestService.embedChunks(of: document, context: context)
        }
        refreshList()
    }

    // MARK: - External: AI Research & Ecommerce Link

    /// 运行 AI 联网调研，产出待确认内容（不直接入库，用户确认后才保存）。
    func prepareAIResearch(focus: String) async {
        guard let product = boundProduct else { return }
        phase = .researching
        errorMessage = nil
        defer { phase = .idle }

        let service = ProductResearchService()
        do {
            let report = try await service.research(
                productName: product.name,
                extraTopic: focus.trimmingCharacters(in: .whitespacesAndNewlines))
            let sourceList = report.sources.map { "[\($0.index)] \($0.title) \($0.url)" }
            let body = report.markdown + "\n\n---\n## 调研信源\n" + sourceList.joined(separator: "\n")
            let stamp = Date().formatted(.dateTime.year().month().day().hour().minute())
            pendingExternal = PendingExternal(
                kind: .aiResearch,
                title: "\(product.name) AI调研 \(stamp)",
                body: body, sourceURL: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 解析用户粘贴的单个产品链接，产出待确认内容。
    func prepareEcommerceLink(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .resolvingLink
        errorMessage = nil
        defer { phase = .idle }

        do {
            let text = try await URLTextFetcher().fetchText(from: trimmed)
            pendingExternal = PendingExternal(
                kind: .ecommerceLink,
                title: "链接资料 \(Date().formatted(.dateTime.month().day().hour().minute()))",
                body: text, sourceURL: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 保存当前待确认内容到知识库。
    func savePendingExternal() async {
        guard let context = modelContext, let pending = pendingExternal,
              let product = boundProduct else { return }
        phase = .ingesting
        errorMessage = nil
        defer { phase = .idle }

        do {
            let outcome = try await KnowledgeIngestService.ingest(
                title: pending.title,
                text: pending.body,
                product: product,
                source: pending.kind,
                sourceURL: pending.sourceURL,
                context: context)
            lastOutcome = outcome
            pendingExternal = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshList()
    }

    func discardPendingExternal() {
        pendingExternal = nil
    }

    // MARK: - Helpers

    private func requireContext() throws -> ModelContext {
        guard let context = modelContext else { throw IngestError.saveFailed }
        return context
    }

    private func refreshList() {
        guard let product = boundProduct, let context = modelContext else { return }
        let productID = product.id
        let descriptor = FetchDescriptor<KnowledgeDocument>(
            predicate: #Predicate { $0.product?.id == productID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        documents = (try? context.fetch(descriptor)) ?? []
    }
}
