import Foundation

/// 台词（`Segment.text`）的**来源与不覆盖规则**（计划 §3.3，红线 R8）。
///
/// 为什么住在这儿而不是 `Segment` 里：工程只有 application target，`MixCut/Models/` 没有单测面；
/// 规则留在那个字段旁边就等于没测（同第 1、2 期的"可测面 = 下沉深度"）。
/// `Segment.setText(_:source:)` 只是本模块的调用者。
public enum TranscriptSource: String, CaseIterable, Sendable {
    /// 旧数据·未记录来源。新列的**唯一**默认值 —— 不许默认成任何真实来源，
    /// 否则库里那些 base 年代整片切出来的台词会被冒充成"重听来的"（第 2 期 S4 那一族）。
    case unknownLegacy
    /// 整片听写后按时间切到这一段
    case fullVideoSlice
    /// 自建分镜：用户上传文件整听
    case uploadedClip
    /// 逐段重听（本机 whisper）
    case segmentLocal
    /// 逐段重听（云端 paraformer）
    case segmentCloud
    /// 界面手改
    case manualEdit
    /// MCP / Agent 写入
    case agentEdit
    /// 启动批量清洗改写
    case cleaned
    /// 边界调整导致的段间搬字
    case boundaryShift
    // MARK: 产品脚本成片（v3.4）
    /// AI 基于资料新撰写的配音文案
    case aiRewrite
    /// 产品资料驱动的脚本
    case productScript
    /// 粘贴文案逆向结构化
    case userScriptReverse
}

public struct TextUpdate: Equatable, Sendable {
    /// 该不该落笔
    public let shouldWrite: Bool
    /// 落笔后的来源；不落笔时 = 原来源
    public let source: TranscriptSource
    /// 被覆盖掉的那条原来源；不落笔时为 nil
    public let previousSource: TranscriptSource?
    /// **要去写的那个值**（已去两端空白）；不写时为 nil。
    ///
    /// 为什么把值也返回出去：trim 本身就是规则的一部分（"两端空白算没变"）。
    /// 如果只返回 `shouldWrite`，调用方得再 trim 一次 —— 两处 trim 一旦写法不同，
    /// "内容没真变"的判据和实际落库的值就对不上了。写不写、写什么，必须同一个出处。
    public let textToWrite: String?

    public init(shouldWrite: Bool, source: TranscriptSource, previousSource: TranscriptSource?,
                textToWrite: String? = nil) {
        self.shouldWrite = shouldWrite
        self.source = source
        self.previousSource = previousSource
        self.textToWrite = textToWrite
    }
}

public enum TextProvenance {

    /// 决定"这次写入要不要发生、来源该记成什么"。
    ///
    /// 三条硬规则：
    /// 1. **空文本一律不写** —— 今天 `ImportViewModel` 把空识别当成功返回，这条把它挡住
    /// 2. **内容没真变不写**（两端空白去掉后相等即视为没变）—— 防启动清洗把手改台词的来源刷成 `cleaned`
    /// 3. 写入时 `previousSource` 记的是**同一段**的原来源；搬字只可能是 `boundaryShift`，
    ///    接口上根本没有"邻段来源"这个入参 ⇒ 结构上就继承不了
    public static func resolve(current: String,
                               currentSource: TranscriptSource,
                               incoming: String,
                               writer: TranscriptSource) -> TextUpdate {
        let oldText = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newText.isEmpty else {
            return TextUpdate(shouldWrite: false, source: currentSource, previousSource: nil, textToWrite: nil)
        }
        guard newText != oldText else {
            return TextUpdate(shouldWrite: false, source: currentSource, previousSource: nil, textToWrite: nil)
        }
        return TextUpdate(shouldWrite: true, source: writer, previousSource: currentSource, textToWrite: newText)
    }

    /// 新列落库时的默认值（唯一允许"不知道"的一档）。
    public static let legacyDefault: TranscriptSource = .unknownLegacy

    /// 给用户看的说法。`unknownLegacy` 必须是中性描述，不是错误。
    public static func displayLabel(of source: TranscriptSource) -> String {
        switch source {
        case .unknownLegacy:  return "旧数据·未记录来源"
        case .fullVideoSlice: return "整片听写切片"
        case .uploadedClip:   return "上传片段整听"
        case .segmentLocal:   return "逐段重听（本机）"
        case .segmentCloud:   return "逐段重听（云端）"
        case .manualEdit:     return "手动编辑"
        case .agentEdit:      return "Agent 写入"
        case .cleaned:        return "乱码清洗"
        case .boundaryShift:  return "边界调整搬字"
        case .aiRewrite:      return "AI 新撰文案"
        case .productScript:  return "产品资料脚本"
        case .userScriptReverse: return "粘贴文案逆向"
        }
    }
}
