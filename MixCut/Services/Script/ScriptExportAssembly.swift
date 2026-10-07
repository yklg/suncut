import Foundation
import SwiftData
import AppKit

/// 已物化脚本 → 导出投影装配（方案详情的「导出脚本 .txt/.md」使用）。
///
/// 跨边纪律（同 G22）：`ScriptDocument.realizedScheme` 与 `KnowledgeChunk.document`
/// 一律经 `LiveModelIDIndex` 标识符解边，不直接 fault 关系目标——悬空边 fault 空壳
/// 读业务列是第三起 SIGTRAP 的根因。
@MainActor
enum ScriptExportAssembly {

    /// 反查方案背后的冻结脚本并构造导出投影。
    /// - Returns: 脚本方案返回投影；原片方案（无 realizedScript）/脚本已缺失 ⇒ nil。
    static func draft(for scheme: MixScheme, context: ModelContext) -> ScriptExportDraft? {
        let documents = (try? context.fetch(FetchDescriptor<ScriptDocument>())) ?? []
        guard !documents.isEmpty else { return nil }

        var schemeIndex = LiveModelIDIndex()
        schemeIndex.insert([scheme], id: \.id)

        guard let document = documents.first(where: { doc in
            schemeIndex.uuid(for: doc.realizedScheme) == scheme.id
        }) else { return nil }

        let chunks = (try? context.fetch(FetchDescriptor<KnowledgeChunk>())) ?? []
        let docs = (try? context.fetch(FetchDescriptor<KnowledgeDocument>())) ?? []
        var documentIndex = LiveModelIDIndex()
        documentIndex.insert(docs, id: \.id)
        let docByUUID = Dictionary(docs.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let chunkByUUID = Dictionary(chunks.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })

        let scenes = document.scenes
            .sorted { $0.order < $1.order }
            .map { scene -> ScriptExportScene in
                let citations: [ScriptExportCitation] = scene.citationChunkIDs.map { chunkID in
                    let chunk = chunkByUUID[chunkID]
                    let docID = chunk.flatMap { documentIndex.uuid(for: $0.document) }
                    let title = docID.flatMap { docByUUID[$0]?.title } ?? "未命名资料"
                    let url = docID.flatMap { docByUUID[$0]?.sourceURL }
                    return ScriptExportCitation(documentTitle: title, sourceURL: url)
                }
                return ScriptExportScene(order: scene.order, tag: scene.tag,
                                         duration: scene.targetDuration,
                                         text: scene.text, citations: citations)
            }

        // 产品边同样标识符解边（悬空也不阻塞导出，产品名仅为抬头）。
        var productIndex = LiveModelIDIndex()
        let products = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        productIndex.insert(products, id: \.id)
        let productName = productIndex.uuid(for: document.product)
            .flatMap { id in products.first { $0.id == id }?.name }

        return ScriptExportDraft(title: document.title,
                                 direction: document.direction,
                                 productName: productName,
                                 scenes: scenes)
    }

    /// 弹保存面板并把脚本写成文本文件；成功/失败均给 toast（向导确认页与方案详情共用）。
    static func saveViaPanel(_ draft: ScriptExportDraft, format: ScriptTextExportFormat) {
        let text = ScriptTextExporter.render(draft, format: format)
        let panel = NSSavePanel()
        panel.title = "导出脚本（\(format.fileExtension.uppercased())）"
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let baseName = draft.title.components(separatedBy: illegal).joined(separator: "_")
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                ToastCenter.shared.show("脚本已导出", icon: "checkmark.seal.fill", style: .success)
            } catch {
                ToastCenter.shared.show("导出失败：\(error.localizedDescription)",
                                        icon: "exclamationmark.triangle.fill", style: .error)
            }
        }
    }
}
