import Foundation
import SwiftData

/// 脚本物化服务 —— 把 matched 脚本原子地落成一条可编辑/导出的 MixScheme。
///
/// 原子契约（v3.4 · M3，硬约束）：
/// 1. 物化前全量终检：每场景必须已锁定分镜、分镜不重复、文案无极限词/占位、
///    文案硬事实在所引片段中落地；
/// 2. 方案、方案分镜、配音文案三类对象**全部在内存构建**，连同
///    `ScriptDocument → .materialized + realizedScheme` 的状态迁移一起，
///    **单次 save** 提交——任一环节失败 `rollback()`，脚本留在 `.matched`，
///    方案系对象计数为 0，不存在半成品；
/// 3. 成功后脚本整树冻结（终态），编辑归 MixScheme / SegmentDub。
@MainActor
enum MaterializationService {

    enum MaterializeError: LocalizedError {
        case notMatched
        case unmatchedScene(Int)
        case missingSegment(Int)
        case duplicateSegments
        case emptyText(Int)
        case compliance([String])
        case grounding([String])
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .notMatched:            return "脚本尚未完成匹配，无法物化"
            case .unmatchedScene(let i): return "第 \(i) 段尚未匹配分镜"
            case .missingSegment(let i): return "第 \(i) 段匹配的分镜已不存在，请重新匹配"
            case .duplicateSegments:     return "存在分镜被多个段落重复使用，请先解决冲突"
            case .emptyText(let i):      return "第 \(i) 段文案为空，请补全文案后再物化"
            case .compliance(let msgs):  return "文案存在合规问题：\(msgs.joined(separator: "；"))"
            case .grounding(let msgs):   return "文案存在无依据事实：\(msgs.joined(separator: "；"))"
            case .saveFailed(let m):     return "物化保存失败：\(m)"
            }
        }
    }

    /// 物化入口。
    /// - Parameters:
    ///   - script: 必须处于 `.matched`
    ///   - context: 主 ModelContext（唯一写面）
    @discardableResult
    static func materialize(
        script: ScriptDocument,
        context: ModelContext
    ) throws -> MixScheme {
        guard script.status == .matched else { throw MaterializeError.notMatched }

        let scenes = script.scenes.sorted { $0.order < $1.order }
        let provenance: TranscriptSource = script.direction == .reverse
            ? .userScriptReverse : .productScript

        // MARK: 1. 终检

        var segmentIDs: [UUID] = []
        var complianceMessages: [String] = []

        for scene in scenes {
            guard case .matched = scene.matchStatus else {
                throw MaterializeError.unmatchedScene(scene.order)
            }
            guard let segment = scene.matchedSegment else {
                throw MaterializeError.missingSegment(scene.order)
            }
            // 空文案是原子边界的最后一道（VM 按钮门禁可被绕过，服务层必须自守）。
            if scene.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MaterializeError.emptyText(scene.order)
            }
            segmentIDs.append(segment.id)
            for issue in ComplianceChecker.scan(scene.text) {
                complianceMessages.append("第 \(scene.order) 段：\(ComplianceChecker.describe(issue))")
            }
        }
        guard Set(segmentIDs).count == segmentIDs.count else {
            throw MaterializeError.duplicateSegments
        }
        guard complianceMessages.isEmpty else {
            throw MaterializeError.compliance(complianceMessages)
        }

        // Grounding 终检：文案经用户编辑后可能引入新事实，按引用 chunk 重算。
        // 方向门（ScriptGroundingGate，M4）：逆向文案是用户粘贴的原文、无资料可引，
        // grounding 只约束正向 AI 新撰文案；逆向的合规层在上面已无条件执行。
        let citedChunkIDs = Set(scenes.flatMap(\.citationChunkIDs))
        let chunkByID = fetchChunks(ids: citedChunkIDs, context: context)
        // 引用出处文档投影（全量活 fetch + 标识符解边；无引用时为空）。
        let documents = (try? context.fetch(FetchDescriptor<KnowledgeDocument>())) ?? []
        var documentIndex = LiveModelIDIndex()
        documentIndex.insert(documents, id: \.id)
        let documentByID = Dictionary(documents.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        if ScriptGroundingGate.requiresExternalEvidence(script.direction) {
            var groundingMessages: [String] = []
            for scene in scenes {
                let sources = scene.citationChunkIDs.compactMap { chunkByID[$0]?.content }
                let report = GroundingChecker.check(text: scene.text, sources: sources)
                if !report.isGrounded {
                    groundingMessages.append(
                        "第 \(scene.order) 段无依据：\(report.unsupportedFacts.joined(separator: "、"))")
                }
            }
            if !groundingMessages.isEmpty {
                throw MaterializeError.grounding(groundingMessages)
            }
        }

        // MARK: 2. 全对象内存构建

        // 归属：脚本方案必须落在项目的「产品脚本成片」容器组内，否则方案页/导出页枚举不到
        //（strategy=nil 孤儿是本修复的根因）。project 为终检必需，显式解包不隐式兜底。
        guard let project = script.project else { throw MaterializeError.notMatched }
        let group = Self.ensureScriptGroup(project: project, context: context)

        let scheme = MixScheme(
            name: script.title,
            style: "产品脚本成片",
            description: "由脚本「\(script.title)」物化",
            targetAudience: "",
            narrativeStructure: scenes.map(\.tag).joined(separator: " → "))
        scheme.schemeIndex = "script_\(UUID().uuidString.prefix(8))"
        scheme.project = project
        scheme.strategy = group
        // 组内连续序号（与自定义组合 createCustomScheme 的命名口径对称）。
        scheme.variationIndex = group.orderedSchemes.count + 1
        scheme.audioTrackPolicy = .dubOnly
        scheme.estimatedDuration = scenes.reduce(0) { $0 + $1.targetDuration }

        context.insert(scheme)

        for scene in scenes {
            guard let segment = scene.matchedSegment else {
                throw MaterializeError.missingSegment(scene.order)
            }
            // 空壳 index 避开该分镜现存改写版（普通克隆/预置 dub 已占用的 index），
            // 从最大值 +1 起分配——否则后续绑定/effectiveDubVariants 去重会撞号覆盖。
            // 同 Segment 多段命中在终检已拦，每场景在此独立分配即可。
            let variantIndex = ScriptDubIndexAllocator.nextIndex(
                occupied: segment.segmentDubs.map(\.textVariantIndex))

            // 配音文案载体：文本/引用此刻落 SegmentDub，音色与音频在方案详情里后续生成。
            let dub = SegmentDub(
                segment: segment,
                voiceId: "",
                voiceProvider: "qwen",
                textVariantIndex: variantIndex,
                rewrittenText: scene.text)
            dub.setProvenance(provenance)
            dub.citations = scene.citationChunkIDs.map { chunkID in
                // 出处快照经标识符解边（不直接 chunk.document?.title fault backing——
                // 悬空边 fault 是第三起 SIGTRAP 的根因，同 G22 纪律）。
                let title = documentTitle(for: chunkByID[chunkID],
                                          index: documentIndex, documents: documentByID)
                let url = documentSourceURL(for: chunkByID[chunkID],
                                            index: documentIndex, documents: documentByID)
                return CitationDescriptor(
                    chunkID: chunkID,
                    documentTitle: title,
                    sourceURL: url)
            }
            context.insert(dub)

            let link = SchemeSegment(position: scene.order)
            link.scheme = scheme
            link.segment = segment
            link.selectedSegmentDubId = dub.id
            context.insert(link)
        }

        // MARK: 3. 状态迁移与单次提交（迁移也在 save 前，保证同生共死）

        guard script.transition(to: .materialized, realizedScheme: scheme) else {
            context.rollback()
            throw MaterializeError.notMatched
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw MaterializeError.saveFailed(error.localizedDescription)
        }
        return scheme
    }

    // MARK: - Helpers

    /// 获取（不存在则创建）项目唯一的「产品脚本成片」容器组。
    ///
    /// 第三类策略容器，与 SchemeViewModel.createCustomScheme 的 isCustomGroup 容器对称：
    /// - 懒建：不随项目创建预建，避免给不用脚本成片的项目制造空数据/存量迁移；
    /// - 容器与本次物化 scheme 在调用方同一次 save 提交，失败一起回滚，不留空容器；
    /// - 唯一持久化创建点（UI 空态组是 SchemeViewModel 的内存占位，不可落库）。
    private static func ensureScriptGroup(project: Project, context: ModelContext) -> MixStrategy {
        if let existing = project.strategies.first(where: { $0.isScriptGroup }) {
            return existing
        }
        let group = MixStrategy(
            name: "产品脚本成片",
            style: "产品脚本成片",
            description: "知识库写文案 / 粘贴逆向文案，逐段锁定分镜 · 全新配音",
            targetAudience: "",
            narrativeStructure: "",
            targetDuration: 0
        )
        group.isScriptGroup = true
        group.project = project
        project.strategies.append(group)
        context.insert(group)
        return group
    }

    /// 按引用 id 取 chunk 行（跨边 document 只在此读）。
    private static func fetchChunks(ids: Set<UUID>, context: ModelContext) -> [UUID: KnowledgeChunk] {
        guard !ids.isEmpty else { return [:] }
        let all = (try? context.fetch(FetchDescriptor<KnowledgeChunk>())) ?? []
        let picked = all.filter { ids.contains($0.id) }
        return Dictionary(picked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// chunk → 所属资料标题（标识符解边；chunk 缺失/文档悬空/标题空 ⇒ 兜底名）。
    private static func documentTitle(
        for chunk: KnowledgeChunk?,
        index: LiveModelIDIndex,
        documents: [UUID: KnowledgeDocument]
    ) -> String {
        guard let chunk,
              let docID = index.uuid(for: chunk.document),
              let title = documents[docID]?.title,
              !title.isEmpty else { return "未命名资料" }
        return title
    }

    /// chunk → 所属资料 URL（标识符解边；悬空 ⇒ nil）。
    private static func documentSourceURL(
        for chunk: KnowledgeChunk?,
        index: LiveModelIDIndex,
        documents: [UUID: KnowledgeDocument]
    ) -> String? {
        guard let chunk, let docID = index.uuid(for: chunk.document) else { return nil }
        return documents[docID]?.sourceURL
    }
}
