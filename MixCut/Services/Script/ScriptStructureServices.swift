import Foundation

/// 结构草稿中的单个场景（向导结构页的编辑单元）。
struct ScriptStructureDraft: Equatable, Identifiable {
    let id = UUID()
    var order: Int
    var tag: String
    var duration: Double
    /// 逆向：用户原文（逐字保留）；正向 AI 自动结构：空，写作阶段才填。
    var text: String
}

// MARK: - Reverse

/// 逆向结构化服务：粘贴文案 → 本机逐句切行（原文不动）→ LLM 仅打标签 → 按字数估时长。
@MainActor
enum ReverseStructuringService {

    enum StructureError: LocalizedError {
        case emptyText
        case missingPrompt
        case llmFailed(String)
        case lineCountMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .emptyText:      return "请先粘贴需要结构化的文案"
            case .missingPrompt: return "逆向结构化提示词模板缺失"
            case .llmFailed(let m): return "AI 结构化失败：\(m)"
            case .lineCountMismatch(let e, let a):
                return "AI 返回行数不符（期望 \(e)，实际 \(a)），请重试"
            }
        }
    }

    private static let promptLoader = PromptLoader()
    private static let validTags = Set(SemanticType.allCases.map(\.rawValue))

    static func structure(_ raw: String) async throws -> [ScriptStructureDraft] {
        let lines = PastedScriptLines.lines(in: raw)
        guard !lines.isEmpty else { throw StructureError.emptyText }

        guard let template = promptLoader.loadPrompt(named: "reverse_structuring_prompt") else {
            throw StructureError.missingPrompt
        }
        let numbered = lines.map { "\($0.index). \($0.text)" }.joined(separator: "\n")
        let prompt = """
        \(template)

        【待标注文案】（共 \(lines.count) 行，输出行数必须一致）
        \(numbered)
        """

        let provider = AIProviderManager.currentProvider()
        let response: String
        do {
            response = try await provider.generateText(prompt: prompt)
        } catch {
            throw StructureError.llmFailed(APIErrorClassifier.friendly(error))
        }

        let tagged: [ScriptResponseParser.TaggedLine]
        do {
            tagged = try ScriptResponseParser.parseTagging(response)
        } catch {
            throw StructureError.llmFailed("响应解析失败（\(error)），请重试")
        }
        guard tagged.count == lines.count else {
            throw StructureError.lineCountMismatch(expected: lines.count, actual: tagged.count)
        }

        // 行号对齐映射；非法标签回退「过渡」（不猜、不丢行）。
        let tagByIndex = Dictionary(tagged.map { ($0.index, $0.tag) }, uniquingKeysWith: { first, _ in first })
        return lines.map { line in
            let rawTag = tagByIndex[line.index] ?? SemanticType.transition.rawValue
            let tag = validTags.contains(rawTag) ? rawTag : SemanticType.transition.rawValue
            let duration = SpeechDuration.estimate(
                characterCount: line.text.filter { !$0.isWhitespace && !$0.isNewline }.count)
            return ScriptStructureDraft(
                order: line.index, tag: tag,
                duration: max(0.8, duration), text: line.text)
        }
    }
}

// MARK: - Forward AI Auto Structure

/// 正向 AI 自动结构服务：产品名 + 目标时长 → LLM 给出带标签和时长的槽位结构。
@MainActor
enum StructureGenerationService {

    enum StructureError: LocalizedError {
        case missingPrompt
        case llmFailed(String)
        case invalidStructure

        var errorDescription: String? {
            switch self {
            case .missingPrompt:     return "结构生成提示词模板缺失"
            case .llmFailed(let m):  return "AI 生成结构失败：\(m)"
            case .invalidStructure:  return "AI 返回的结构无效（标签或时长缺失），请重试"
            }
        }
    }

    private static let promptLoader = PromptLoader()
    private static let validTags = Set(SemanticType.allCases.map(\.rawValue))

    static func generate(productName: String, targetDuration: Double) async throws -> [ScriptStructureDraft] {
        guard let template = promptLoader.loadPrompt(named: "structure_generation_prompt") else {
            throw StructureError.missingPrompt
        }
        let prompt = """
        \(template)

        【产品名称】\(productName)
        【目标总时长】\(String(format: "%.0f", targetDuration)) 秒
        """

        let provider = AIProviderManager.currentProvider()
        let response: String
        do {
            response = try await provider.generateText(prompt: prompt)
        } catch {
            throw StructureError.llmFailed(APIErrorClassifier.friendly(error))
        }

        let slots: [ScriptResponseParser.StructureSlot]
        do {
            slots = try ScriptResponseParser.parseStructure(response)
        } catch {
            throw StructureError.llmFailed("响应解析失败（\(error)），请重试")
        }

        // 标签非法的槽位回退「过渡」；时长 ≤0 用口播经验兜底。
        let drafts = slots.enumerated().map { position, slot -> ScriptStructureDraft in
            let tag = validTags.contains(slot.tag) ? slot.tag : SemanticType.transition.rawValue
            return ScriptStructureDraft(
                order: position + 1,
                tag: tag,
                duration: slot.duration > 0 ? slot.duration : 3.0,
                text: "")
        }
        guard !drafts.isEmpty else { throw StructureError.invalidStructure }
        return drafts
    }
}
