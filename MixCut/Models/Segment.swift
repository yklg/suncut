import Foundation
import SwiftData

/// 分镜"当前生效画面"来源（就地替换的单一真源）。播放/缩略图/导出统一读它。
struct EffectivePicture: Sendable {
    let videoPath: String
    let startTime: Double
    let endTime: Double
    let startFrame: Int
    let endFrame: Int
    let fps: Double
    let thumbnailPath: String?
    let isReplaced: Bool
}

/// 语义类型（来自 segment_types_definition.md）
enum SemanticType: String, Codable, CaseIterable, Identifiable {
    case hook = "噱头引入"
    case painPoint = "痛点"
    case solution = "产品方案"
    case results = "效果展示"
    case socialProof = "信任背书"
    case priceAnchor = "价格对比"
    case promotion = "活动福利"
    case callToAction = "行动号召"
    case productPositioning = "产品定位"
    case usageEducation = "产品使用教育"
    case transition = "过渡"
    /// 空镜 —— **机器专属标签**：只由 `EmptyLensPolicy` 的判定写入，
    /// ⚠️ **不许**出现在任何 AI prompt 的可选标签列表里（那条判据见 `EmptyLensTagBoundaryTests`）。
    /// 理由：空镜是"这段音频里没有人说话"，而模型只拿到文本，看幻觉文本是看不出静音的；
    /// 让它可选，等于给它一条凭文本编造静音结论的口子。判据本身也不靠模型：
    /// 吃的是 silencedetect 的有声占比与 whisper 的固定幻觉套话。
    /// 为什么写成标签而不是"留空"：留空会被两处 `if types.isEmpty → [.transition]` 兜底
    /// 和启动期 `UPDATE … WHERE ZSEMANTICTYPESDATA IS NULL` 那条补数据 SQL 重新盖章成「过渡」——
    /// 三处默认值都会把"被拦下"这件事静默撤销掉（2026-11-04 实读发现）。
    /// 写成标签还顺带满足"可见、可筛、可手改（＝翻案入口）"，且不动 schema。
    case emptyShot = "空镜"

    var id: String { rawValue }

    /// 显示颜色标签（SwiftUI Color name）
    var colorName: String {
        switch self {
        case .hook: return "red"
        case .painPoint: return "orange"
        case .solution: return "blue"
        case .results: return "green"
        case .socialProof: return "purple"
        case .priceAnchor: return "yellow"
        case .promotion: return "pink"
        case .callToAction: return "mint"
        case .productPositioning: return "teal"
        case .usageEducation: return "indigo"
        case .transition: return "gray"
        case .emptyShot: return "brown"
        }
    }
}

/// 「切换一颗语义标签」的结果。UI、批量、MCP 三方共用同一判据 —— 不许在调用方各写一遍
/// "摘到空就拦"，那正是它此前散在三处的形状。
enum SemanticToggleOutcome: Equatable {
    case added
    case removed
    /// 摘掉它会破「至少保留 1 个语义类型」。**调用方必须出声**：
    /// 今天 `SegmentLibraryViewModel.toggleSemanticType` 判掉之后什么都不做，
    /// 用户体感就是「按钮点了没反应」（2026-11-06 症状②的成因之一）。
    case refusedKeepAtLeastOne
}

extension SemanticType {

    /// 「至少要保留 1 个语义类型」这句文案的唯一真源：界面 Toast 与 MCP 的 `note` 共用。
    /// 之前它在 VM 与 MCP 两处各写一遍字面串，改文案会只改到一半。
    static let keepAtLeastOneMessage = "至少要保留 1 个语义类型"

    /// AI 可指派标签 —— **从 Core 的 `SemanticRoster.aiAssignable` 派生**，不是第二份名册。
    ///
    /// 方向是 Core → App：`AgentToolCatalog` / `SlotRetrievalIntent` 住在 Core，看不见这颗枚举，
    /// 所以唯一真源只能落在那边（见 `EmptyLensPolicy.swift` 里的 `SemanticRoster` 注释）。
    /// `SemanticTagWriteRuleTests` 的 SR-7 钉的是这条映射**无损**：颗数相等、每颗都解析得动、
    /// 且差集恰好是机器标签「空镜」。任何一边漂了都会红。
    static var aiAssignableTypes: [SemanticType] {
        SemanticRoster.aiAssignable.compactMap(SemanticType.init(rawValue:))
    }

    /// 手改「空镜」的代价提示（唯一文案真源，展开态 chip 与右键菜单共用）。
    static let emptyShotWarningMessage = "这段有台词：标成空镜会被当成补差额的插片素材，再点一次确认"

    /// 手改「空镜」的代价闸（**事前告知**，界面与右键两处宿主共用同一份判据，不许各写一遍）。
    ///
    /// 为什么要有它：`Project.brollSupplies` 的入池条件只看标签、不看台词是否为空
    /// （那颗属性自己的注释就写着「带台词的段插进来会让画面与别段口播撞叙事」）。
    /// **摘掉**空镜标签是设计内的正解（人不认可机器判断 ⇒ 该段重新进入逐段重听队列，
    /// 见 `SegmentTranscribeOutcome.shouldAutoRetake` 的说明）；**手动打上**则没有任何背书，
    /// 会把一段真有口播的画面送进导出成片的插片池。所以只在"加上"这一侧提示。
    ///
    /// ⚠️ 定位（2026-11-06 说清）：这颗闸**不是唯一防线** —— 绕过界面的写入（MCP
    /// `set_semantic_types`、旧库补标、将来的新入口）它拦不到。真正的防线在读侧
    /// `BrollPolicy.acceptsAsSupply(text:taggedAsEmptyShot:)`。这颗留着是为了让用户
    /// **在点的那一下就知道代价**，而不是等导出时才发现成片少画面。
    static func confirmationNeededForEmptyShot(on segment: Segment, adding type: SemanticType) -> Bool {
        type == .emptyShot
            && !segment.semanticTypes.contains(.emptyShot)
            && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 最小值不变式（唯一判据）。
    static func meetsMinimum(_ types: [SemanticType]) -> Bool { !types.isEmpty }

    /// 保序去重。入参带重复是可达的（覆盖式写入、历史数据、AI 归一化追加），
    /// 而旧写法用 `firstIndex` 只删第一个 ⇒ 用户点两次"取消"还剩一个。
    static func deduplicated(_ types: [SemanticType]) -> [SemanticType] {
        var seen = Set<SemanticType>()
        var out: [SemanticType] = []
        for t in types where seen.insert(t).inserted { out.append(t) }
        return out
    }

    /// 切换 `target`：不在集里追加到末尾，在集里就摘掉；摘到空则拒绝。
    ///
    /// 顺序：不重排既有数组（数组是**插入序**，卡片标签行与收起态回显都按它排），
    /// 新增项追加在末尾。编辑器 chip 遍历的 `allCases` 是另一件事，两者别混。
    /// 拒绝时返回的也是去重后的原集合：入参本来就脏的话，顺带自愈一次。
    static func toggled(_ current: [SemanticType],
                        adding target: SemanticType)
        -> (outcome: SemanticToggleOutcome, next: [SemanticType]) {
        let base = deduplicated(current)
        guard let idx = base.firstIndex(of: target) else {
            return (.added, base + [target])
        }
        guard base.count > 1 else {
            return (.refusedKeepAtLeastOne, base)
        }
        var next = base
        next.remove(at: idx)
        return (.removed, next)
    }
}

/// 收起态「已命中」回显的宽度预算（纯算术）。
///
/// ⚠️ 这些数字是**几何常量 + 字宽估算**，不是像素实测：CJK 按 1 字 ≈ 1 em 估，
/// 再用 `safetyMargin` 兜估算误差。之所以写成算术而不是直接写「最多 2 颗」，
/// 是因为这颗面板的宽度契约（340 / 14 / 312）已被 `BoundaryAdjustLayout` 钉住 ——
/// 面板宽度或字号一改，可见颗数必须跟着变，而不是留下一个当时刚好合适、
/// 后来悄悄截断的魔数（那正是 `BoundaryAdjustLayoutTests` 拦的那一族）。
enum CategoryEchoBudget {
    /// Inspector 定宽（`SegmentVariantInspector` 的 `.frame(width:)`）
    static let inspectorWidth: Double = 340
    /// 面板内容左右内距（同 `BoundaryAdjustLayout.inspectorHorizontalPadding`）
    static let horizontalPadding: Double = 14
    /// 分区标题行的图标位宽与间距（`CollapsibleInspectorSection`）
    static let iconWidth: Double = 14
    static let iconGap: Double = 6
    /// 「分类」两颗 12pt
    static let titleWidth: Double = 24
    /// 回显颗间距（同卡片标签行的 FlowLayout 口径）
    static let chipGap: Double = 3
    static let chevronWidth: Double = 9
    /// 字宽估算的兜底余量
    static let safetyMargin: Double = 12
    /// `DesignTokens.Typography.micro` 字号
    static let chipFontSize: Double = 10
    /// `SemanticTypeTag` 的水平内距 7×2
    static let semanticHPadding: Double = 14
    /// `PositionTypeTag` 的水平内距 5×2
    static let positionHPadding: Double = 10
    /// 「+N」那颗的估宽
    static let moreChipWidth: Double = 22

    /// 回显能占的宽度：标题行总宽减去图标、标题、箭头与两份间距，再扣掉估算余量。
    static var availableWidth: Double {
        inspectorWidth - horizontalPadding * 2
        - iconWidth - iconGap - titleWidth - iconGap - chevronWidth - safetyMargin
    }

    static func chipWidth(_ label: String, hPadding: Double = semanticHPadding) -> Double {
        Double(label.count) * chipFontSize + hPadding
    }

    /// 回显颗数的**上限**（用户 2026-11-06 拍板「最多 2 颗 + +N」）。
    ///
    /// ⚠️ 这颗与下面的宽度预算是**两道独立的闸**，别混成一颗：
    ///   · `maxVisibleLimit` 是产品决定 —— 面板再宽也不铺第 3 颗，避免标题行变拥挤；
    ///   · `availableWidth` 是几何下限保护 —— 面板变窄或标签名变长时，可见数会**退到 1**，
    ///     而不是把第 2 颗截断成半个词。
    /// 按今天的名册与 340pt 面板算，宽度预算给的是 3（短名集合实测能给到 5），
    /// 所以今天生效的是这颗上限；预算那条要等面板变窄或文案变长才咬得住 ——
    /// 它不是装饰，`SemanticTagWriteRuleTests` 里有两条分别钉这两半边，摘掉任一道都会红。
    static let maxVisibleLimit = 2

    /// 按名册原序尽量多铺，装不下的折算成「+N」。
    ///
    /// 位置胶囊与「+N」胶囊**先留位再装语义**：多标签分镜很常见，若把位置挤没，
    /// 就等于用新症状换掉旧症状。`overflow == 0` 时其实不画「+N」，
    /// 这里仍然给它留位 —— 宁可少铺一颗，也不要"屏上刚好排满、加一颗标签就截断"。
    ///
    /// `width` / `limit` 开成入参不是为了配置化，是为了让上面那**两道独立的闸**都能被真码测到：
    /// 默认值就是屏上那一档，测试则用极窄 / 极宽两端把"会退化到 1 而不是截断"这条性质钉住。
    static func slice(_ current: [SemanticType],
                      width: Double = availableWidth,
                      limit: Int = maxVisibleLimit)
        -> (shown: [SemanticType], overflow: Int) {
        guard !current.isEmpty else { return ([], 0) }
        var used = chipWidth("开头", hPadding: positionHPadding) + moreChipWidth
        var shown: [SemanticType] = []
        for type in current {
            guard shown.count < limit else { break }
            let cost = chipWidth(type.rawValue) + chipGap
            guard used + cost <= width else { break }
            used += cost
            shown.append(type)
        }
        return (shown, current.count - shown.count)
    }
}

/// 位置类型
enum PositionType: String, Codable, CaseIterable, Identifiable {
    case opening = "开头"
    case middle = "中间"
    case ending = "结尾"

    var id: String { rawValue }
}

@Model
final class Segment: Identifiable {
    @Attribute(.unique) var id: UUID
    var segmentIndex: String   // seg_001 格式
    // 边界「真相」：以帧号存储（永不差帧）。startTime/endTime 是 = 帧号/fps 的精确派生缓存，
    // 仅供显示和未改造的读取点用，编辑一律走 setFrameRange / adjust*Frame。
    var startFrame: Int = 0
    var endFrame: Int = 0
    var startTime: Double      // 派生缓存：FrameTime.seconds(frame: startFrame, fps: video.fps)
    var endTime: Double        // 派生缓存：FrameTime.seconds(frame: endFrame, fps: video.fps)
    /// 台词。**唯一写入口是 `setText(_:source:)`**（红线 R8）—— setter 收到类内，
    /// 类外再写 `segment.text = …` 直接编译不过，防止"10 个搬运规则各写一遍"重新长回来。
    private(set) var text: String
    /// 台词来源（`TranscriptSource.rawValue`）。默认 `unknownLegacy`：
    /// 旧库升级上来的行、以及任何没人记过的行都只能是它，**不许**默认成某个引擎（第 2 期"默认值冒充数据"那一族）。
    private(set) var textSourceRaw: String = TranscriptSource.unknownLegacy.rawValue
    var semanticTypesData: Data?  // [SemanticType] 编码存储（可多个）
    var positionType: PositionType
    var confidence: Double
    var qualityScore: Double
    var visualDescription: String?
    var thumbnailPath: String?

    /// 关键词
    var keywordsData: Data?  // [String] 编码存储

    // MARK: 解码缓存（不持久化）
    // 见文件末尾 `DecodedCache` 的说明：用引用盒承载，避免在 getter 里回填时触发变更通知。
    @Transient private var semanticTypesCache = DecodedCache<[SemanticType]>()
    @Transient private var keywordsCache = DecodedCache<[String]>()
    /// 替换画面文件存在性缓存：`(已查过的路径, 是否存在)`，避免渲染路径上反复 `stat()`。
    @Transient private var replacedExistsCache = DecodedCache<(path: String, exists: Bool)>()

    /// 数据质量详情
    var qualityReasoning: String?

    /// 素材来源 raw（SegmentSource.rawValue）。**默认 "" = 未分类**（存量数据迁移契约，
    /// 见 SegmentSource.unclassified）。读侧一律用计算属性 `source`，禁止直接 parse 本字段。
    var sourceRaw: String = ""

    /// 素材来源读侧唯一入口：未知/空值回退「未分类」（不猜、不冒充搬运）。
    var source: SegmentSource {
        SegmentSource(rawValue: sourceRaw) ?? .unclassified
    }

    /// 素材来源唯一写入口（与 setText 同纪律：收口到一个方法，便于批量/撤销与未来加日志）。
    func setSource(_ source: SegmentSource) {
        sourceRaw = source.rawValue
    }

    var video: Video?

    @Relationship(deleteRule: .cascade, inverse: \SchemeSegment.segment)
    var schemeSegments: [SchemeSegment] = []

    /// 配音变体池（每个 = 该分镜的一个 改写版×音色 变体）
    @Relationship(deleteRule: .cascade, inverse: \SegmentDub.segment)
    var segmentDubs: [SegmentDub] = []

    /// 分镜头（物理镜头）列表：进入"分镜头替换"工作区时按需切分并持久化
    @Relationship(deleteRule: .cascade, inverse: \PhysicalShot.parentSegment)
    var physicalShots: [PhysicalShot] = []

    // MARK: - 就地画面替换（分镜头 AI 替换产物）

    /// 替换画面合成 mp4 路径；nil = 尚无替换画面
    var replacedPictureVideoPath: String?
    /// 替换画面缩略图路径
    var replacedPictureThumbnailPath: String?
    /// 替换画面实际帧数（合成时探测存下，供帧区间消费点用）
    var replacedPictureFrameCount: Int = 0
    /// 当前生效哪版画面（仅当存在替换画面时有意义）
    var pictureShowsReplaced: Bool = false

    var createdAt: Date

// MARK: - 配音改写相关（P1）

/// 是否"保留原声"（明星出镜镜头 = true，不可重配）
    var isVoiceLocked: Bool = false

    // MARK: - 混剪内部整片段（计划 2026-10-22 第三轮 笔 K2，决议 K2 甲-隐）

    /// 这条段是不是**文件夹混剪为"整片直拼"补建出来的内部段**。
    ///
    /// 为什么需要这颗字段：混剪要的是"这一条视频 + 它的整片时长"，而建方案的入口只吃 `Segment`
    /// ⇒ 对当年按分镜导入的素材（75% 的主力），库里没有一条覆盖全片的段，混剪只能整批判档 B。
    /// 补建一条是最小改法，但那条**不是用户的创作物**，不该出现在他手工维护的分镜素材库里，
    /// 也不该参与与混剪无关的 AI 方案候选池 —— 这颗字段就是那条界线。
    ///
    /// ⚠ 它回答的是「这条段是谁建的、能不能算进用户手工分镜」，**不回答素材来源**
    ///   （自拍/搬运那颗是 `sourceRaw` + `SegmentSource`，不许复用：两个问题一个字段 = 两个答案会漂）。
    /// ⚠ 带默认值的存储字段 ⇒ SwiftData **轻量兼容**（`classifySchemaChange` 走 additionsOnly，
    ///   门只做"改前备份 + 加列"，`AppSchemaV1` 与 stages 都不动 —— 判据源 `CLAUDE.md:476`）。
    ///   回退不是"装回旧版 App"（sidecar 指纹是单调棘轮，`CLAUDE.md:486` 已实测证伪），
    ///   而是把 `*.backup` 那四件原样放回。
    /// ⚠ 可见性口径只走 `Video.displayableSegments` / `Project.displayableSegments` 那一颗出口
    ///   （决议 K9），**不许在界面各写一遍 filter**；导出/删除咽喉/启动修复必须**含**它（门 T-33 反腿）。
    var mixInternalWholeClip: Bool = false

    // MARK: - 段级克隆音色（M2：按分镜时间范围克隆，而非按整段视频）

    /// 本分镜的克隆音色 id（qwen-vc）。nil = 未克隆。
    ///
    /// ## 为什么不复用 `Video.clonedVoiceId`（M2 变更）
    ///
    /// 旧实现按**视频**克隆一次，参考音恒取人声轨开头 6 秒
    /// （`VocalSeparationService.referenceClip` 参数无 `-ss`）⇒
    /// 同一视频里**跨说话人**的分镜会拿到同一个音色。
    /// 实测某个 58.8 秒视频：0~18 秒是男声（125~156 Hz）、21 秒后是女声（200~256 Hz），
    /// 而旧实现恒取前 6 秒 ⇒ 选女声段却克隆出男声。
    ///
    /// ⚠️ **存量兼容**：旧库的分镜这里为 nil，读侧须回落到 `video.clonedVoiceId`
    /// （见 `SegmentDub.effectiveDubVariants` 的段级优先/ 视频级回落）。
    var clonedVoiceId: String?

    /// 注册时**实际送出**的参考音窗口起始帧（-1 = 无记录）。
    ///
    /// 必须存窗口而不只是 voiceId：这是「这个分镜能否复用已注册音色」的**唯一依据**
    /// ——缺了它，复用判据会退化成「全视频共用一个」（= 旧 bug）或「每分镜都注册一次」（= 计费 ×N）。
    var cloneWindowStartFrame: Int = -1

    /// 窗口终点帧（同上，-1 = 无记录）。
    var cloneWindowEndFrame: Int = -1

    /// 注册该音色时的千问 API Key 指纹。
    ///
    /// ## 为什么从 UserDefaults 挪进模型字段
    ///
    /// 旧实现是 `UserDefaults` 键 `clonedVoiceKeyFP_{videoHash}`
    /// （`DubbingViewModel.ensureClonedVoice`）⇒ 按分镜后键数量会 × 分镜数。
    /// 挪进字段后由SwiftData 承载，随分镜生命周期一起清理。
    var cloneKeyFingerprint: String = ""

    /// 原版是否参与导出组合（默认参与）；配合 SegmentDub.participatesInCombination 收敛组合数
    var originalParticipatesInCombination: Bool = true

    /// 原片该分镜是否有硬字幕，需要遮挡
    var hasHardSubtitle: Bool = false

    /// 遮挡矩形（归一化 0~1，原点左上），默认底部带状区
    var maskX: Double = 0.0
    var maskY: Double = 0.80
    var maskWidth: Double = 1.0
    var maskHeight: Double = 0.12

    /// 遮挡样式（MaskStyle.rawValue：blur/solid/dim）
    var maskStyleRaw: String = "blur"

    /// 烧录字幕字号比例（相对画面宽度）。
    ///
    /// ⚠️ **逐分镜独立**：每个分镜可以有自己的字号，改一个不影响其它分镜。
    /// 想统一时用弹层里的「应用到本视频所有分镜」，作用域也仅限该视频。
    /// （早期这是个全局 UserDefaults 设置，导致改一处等于改全部视频的全部分镜，语义不对。）
    var subtitleFontRatio: Double = SubtitleFontSize.defaultRatio

    /// 遮挡矩形（桥接四个归一化 Double）
    ///
    /// ⚠️ 高度下限读**本分镜自己的** `subtitleFontRatio`：拖拽、MCP 写 mask、"应用到本视频所有分镜"、
    /// 撤销四条写路径全走这个 setter，闸口只设这一处就都盖住了。不这么做的后果不是崩溃而是自我欺骗 ——
    /// 带能拖到 38px，而该档字号烧出来的字幕块有 ~119px，于是"开了纯色遮挡"的卡片导出后原字幕还在。
    var maskRect: SubtitleMaskRect {
        get { SubtitleMaskRect(x: maskX, y: maskY, width: maskWidth, height: maskHeight) }
        set {
            let c = newValue.clamped(
                minHeight: SubtitleMaskRect.minimumHeight(fontRatio: subtitleFontRatio))
            maskX = c.x; maskY = c.y; maskWidth = c.width; maskHeight = c.height
        }
    }

    /// 遮挡样式
    var maskStyle: MaskStyle {
        get { MaskStyle(rawValue: maskStyleRaw) ?? .blur }
        set { maskStyleRaw = newValue.rawValue }
    }

    /// 「字幕处理」这一档（直接烧录/模糊虚化/纯色遮挡），桥接 `hasHardSubtitle` + `maskStyle`。
    ///
    /// ⚠️ 这条映射以前裸写在网格卡的 view 里（`SegmentDubControls` 的 binding），
    /// 列表行现在也要能改同一档 ⇒ 写第二份就会分叉（一处改了另一处显示旧值）。
    /// 收在这里与 `maskStyle`/`maskRect` 同一层：它们本来就是同一组桥接属性。
    /// 读法与导出侧 `SubtitleMaskMode.from(hasHardSubtitle:maskStyleRaw:)` 用的是同一对字段。
    var subtitleTreatment: SubtitleTreatment {
        get { SubtitleTreatment.from(hasHardSubtitle: hasHardSubtitle, maskStyle: maskStyle) }
        set {
            hasHardSubtitle = newValue.needsMask
            if let style = newValue.maskStyle { maskStyle = style }
        }
    }

    /// 设定本分镜的烧录字号：夹到合法区间 + 记为新分镜的默认值（老素材/新素材不割裂）。
    /// 不保存 —— 保存时机归调用方（卡片改一次存一次，拖滑条时另有去抖）。
    func setSubtitleFontRatio(_ ratio: Double) {
        let v = SubtitleFontSize.clamp(ratio)
        subtitleFontRatio = v
        SubtitleFontSize.rememberPreferred(v)
    }

    /// 语义类型（支持多个）
    ///
    /// ⚠️ 性能：该属性在列表/筛选/搜索路径上被高频访问（每敲一个搜索字符会遍历全部分镜），
    /// 原实现每次 get 都新建 `JSONDecoder` 并全量解码。这里用 `DecodedCache` 惰性缓存，
    /// 仅在 setter 里失效；缓存盒是引用类型，回填不会触发 SwiftData 属性变更通知。
    ///
    /// ⚠️ 短路条件**必须带上 `key == semanticTypesData`**（约束 #4）：只判 `value` 有没值，
    /// 会让命中那次求值完全不碰被跟踪的 `semanticTypesData`，Observation 依赖登记不上，
    /// 于是「在卡片菜单里改标签 → 标签行不动」。键化同时让绕开 setter 的写入下次 get 自愈。
    var semanticTypes: [SemanticType] {
        get {
            if let cached = semanticTypesCache.value, semanticTypesCache.key == semanticTypesData {
                return cached
            }
            let decoded = (try? JSONCoding.decoder.decode([SemanticType].self,
                                                          from: semanticTypesData ?? Data())) ?? []
            semanticTypesCache.value = decoded
            semanticTypesCache.key = semanticTypesData
            return decoded
        }
        set {
            semanticTypesData = try? JSONCoding.encoder.encode(newValue)
            semanticTypesCache.value = newValue
            semanticTypesCache.key = semanticTypesData
        }
    }

    /// 主语义类型（第一个，兼容旧代码）
    /// ⚠️ Deprecated：旧版单字段，set 时会悄悄丢弃其他类型（多类型已迁移到 `semanticTypes`）
    /// 新代码请用 `segment.semanticTypes` 读写完整多类型；只读首项请用 `semanticTypes.first ?? .transition`
    @available(*, deprecated, message: "use semanticTypes (set 会丢失非首项)")
    var semanticType: SemanticType {
        get { semanticTypes.first ?? .transition }
        set {
            if semanticTypes.isEmpty {
                semanticTypes = [newValue]
            } else {
                var types = semanticTypes
                types[0] = newValue
                semanticTypes = types
            }
        }
    }

    init(
        segmentIndex: String,
        startTime: Double,
        endTime: Double,
        text: String,
        semanticTypes: [SemanticType],
        positionType: PositionType,
        qualityScore: Double = 8.0,
        textSource: TranscriptSource = .unknownLegacy,
        source: SegmentSource = .unclassified
    ) {
        self.id = UUID()
        self.segmentIndex = segmentIndex
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.textSourceRaw = textSource.rawValue
        self.positionType = positionType
        self.confidence = 0.8
        self.qualityScore = qualityScore
        self.createdAt = Date()
        self.semanticTypes = semanticTypes
        self.sourceRaw = source.rawValue
        // 新分镜跟随用户最后一次设定的字号（没设过则用出厂默认），
        // 避免"老素材是调好的值、新导入的却回落到默认"这种看起来像 bug 的不一致。
        self.subtitleFontRatio = SubtitleFontSize.preferredRatioForNewSegments
    }

    /// 时长（保证非负）
    var duration: Double {
        max(0, endTime - startTime)
    }

    /// 分镜帧数
    var frameCount: Int { max(0, endFrame - startFrame) }

    /// **同素材**里排在本段之后的最近分镜起点 —— 画面窗口可续的天花板（B 块）。
    ///
    /// 一条源视频会被切成多个分镜，所以"往后续帧"能吃到的余量往往不是源片末尾，
    /// 而是下一格分镜的脸。漏掉这层的后果（本仓 2026-11-05 实测）：前一段接长到
    /// [0,200) 而后一段本来就是 [100,200) ⇒ 同一段画面在成片里连播两遍。
    ///
    /// nil = 本段之后没有别的分镜了（通常是最后一段）⇒ 可以放心续到源片末尾。
    ///
    /// ⚠️ 条件是 `>=`，不是 `>`：导入即切分出来的分镜本来就该首尾相接，
    /// 用 `>` 会把"紧贴的下一格"读成"没有兄弟"，于是照旧续进它的画面 ——
    /// 这个差一在 2026-11-05 被 BR-4 当场抓出（当时段2 起点 100 恰等段1 尾帧 100）。
    ///
    /// ⚠️ 走 `displayableSegments` 这颗可见性唯一出口，不裸读 `video.segments`：
    ///   ① 混剪内部整片段(`mixInternalWholeClip`)那类隐藏行不是一段真剪辑，拿它当"下一格"
    ///      会把可续余量误算成 0，画面白白接不长；
    ///   ② 本仓真删后读关系集合出过 SIGTRAP（守卫 G08 守的就是这一族），可见性收口
    ///      一律走这颗出口，新增读点必须同轮在 `TombstoneReadGuardTests.baseline` 登记。
    /// 读侧与写侧（生成超字闸、导出窗口）都只从这里取，别各写一遍 filter。
    var nextSameSourceStartFrame: Int? {
        guard let video else { return nil }
        return video.displayableSegments
            .filter { $0.id != id && $0.startFrame >= endFrame }
            .map(\.startFrame).min()
    }

    /// 台词来源的读侧。存量字符串认不出时按 `unknownLegacy` 处理 —— 猜一个引擎名，
    /// 就是把"不知道"伪装成数据（本项目已定过的纪律）。
    var textSource: TranscriptSource {
        TranscriptSource(rawValue: textSourceRaw) ?? .unknownLegacy
    }

    /// `Segment.text` 的**唯一写入口**（红线 R8）。规则本体在 `MixCutCore/TextProvenance`（有单测），
    /// 这里只把规则结论落到 SwiftData 字段上。
    ///
    /// 空识别结果、以及"去掉两端空白后其实没变"的两次请求，都会原样返回而**一个字都不写** ——
    /// 于是 `text` 与 `textSource` 一起守住（今天的实现是"识别失败也照盖"，手改的台词会静默变成本机识别结果）。
    /// - Returns: 本次请求的结论（含没写的情形），调用方据此决定 Toast / 计数 / 是否 save
    @discardableResult
    func setText(_ incoming: String, source: TranscriptSource) -> TextUpdate {
        let update = TextProvenance.resolve(current: text, currentSource: textSource,
                                            incoming: incoming, writer: source)
        guard update.shouldWrite, let next = update.textToWrite else { return update }
        text = next
        textSourceRaw = update.source.rawValue
        return update
    }

    /// 以帧号为准设置边界，并同步秒缓存（fps 来自所属视频）。所有边界编辑都应走这里。
    func setFrameRange(startFrame: Int, endFrame: Int, fps: Double) {
        let changed = (startFrame != self.startFrame || endFrame != self.endFrame)
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = FrameTime.seconds(frame: startFrame, fps: fps)
        self.endTime = FrameTime.seconds(frame: endFrame, fps: fps)
        // 边界变了 → 替换画面（内嵌原音频与长度）即失效，清除，避免导出错音画。
        if changed && replacedPictureVideoPath != nil {
            invalidateReplacedPicture()
        }
    }

    /// 作废就地替换画面（改边界 / 调整分镜头分区时调用）。旧文件留给孤儿 GC 回收。
    func invalidateReplacedPicture() {
        replacedPictureVideoPath = nil
        replacedPictureThumbnailPath = nil
        replacedPictureFrameCount = 0
        pictureShowsReplaced = false
        invalidateReplacedExistsCache()
    }

    /// 清空「替换画面文件是否存在」的缓存。
    ///
    /// ⚠️ 合成替换画面时输出路径是**确定性**的（hash + segmentId），重新合成后路径不变，
    /// 仅靠"路径变了才重查"会读到过期结果。因此**任何写 `replacedPictureVideoPath` 或
    /// 增删该文件的地方，都必须调用本方法**。
    func invalidateReplacedExistsCache() {
        replacedExistsCache.value = nil
    }

    // MARK: - 当前生效画面（就地替换的单一真源）

    /// 分镜当前应展示/导出的画面来源：有替换画面且生效时用替换片(整段)，否则用原源视频的帧区间。
    /// ⚠️ 性能：本属性在渲染路径上被高频访问（卡片 body、以及播放进度条的每一帧），
    /// 原实现每次都做 `FileManager.fileExists` 系统调用 —— 播放时每秒可达 20 次 `stat()`。
    /// 文件存在性改为**惰性缓存**：路径不变就只查一次；路径变化（切换替换画面/重新合成）自动重查。
    var effectivePicture: EffectivePicture {
        if pictureShowsReplaced,
           let p = replacedPictureVideoPath,
           Self.replacedFileExists(path: p, cache: replacedExistsCache) {
            let d = duration
            let fc = max(1, replacedPictureFrameCount)
            return EffectivePicture(videoPath: p, startTime: 0, endTime: d,
                                    startFrame: 0, endFrame: fc,
                                    fps: d > 0 ? Double(fc) / d : (video?.fps ?? 30),
                                    thumbnailPath: replacedPictureThumbnailPath, isReplaced: true)
        }
        return EffectivePicture(videoPath: video?.localPath ?? "",
                                startTime: startTime, endTime: endTime,
                                startFrame: startFrame, endFrame: endFrame,
                                fps: video?.fps ?? 30,
                                thumbnailPath: thumbnailPath, isReplaced: false)
    }

    /// 画面来源的**同源判定键**（空镜承接用）：替换画面用它自己的路径（合成片与原片不是同一份像素），
    /// 原视频用 contentHash，没哈希时退回路径。
    ///
    /// 口径只这一处：供给侧（`Project.brollSupplies`）与窗口侧（导出/投影）必须用同一颗键，
    /// 否则 BrollPolicy 那条"同一段画面不许播两遍"的剔除会瞎。
    var pictureSourceKey: String {
        let ep = effectivePicture
        return ep.isReplaced ? ep.videoPath : (video?.contentHash ?? ep.videoPath)
    }

    /// 用所属视频的 fps，把当前秒边界 round 成帧号回填（迁移/兜底用）
    func backfillFramesFromSeconds() {
        let fps = video?.fps ?? 0
        guard fps > 0 else { return }
        startFrame = FrameTime.frame(seconds: startTime, fps: fps)
        endFrame = FrameTime.frame(seconds: endTime, fps: fps)
        // 同步秒缓存到精确帧栅格点
        startTime = FrameTime.seconds(frame: startFrame, fps: fps)
        endTime = FrameTime.seconds(frame: endFrame, fps: fps)
    }

    /// 关键词
    ///
    /// ⚠️ 性能：同 `semanticTypes`，搜索时会对全部分镜访问此属性，故做惰性解码缓存。
    /// ⚠️ 短路条件同样必须带 `key`（约束 #4）。今天没有任何 view body 读它（只有
    /// `SegmentLibraryViewModel.applyFilter` 的搜索分支），所以这条是**消除同形隐患**，
    /// 不是修某个已上报的症状 —— 谁哪天在卡片上画关键词，就会立刻踩到标签那次同样的坑。
    var keywords: [String] {
        get {
            if let cached = keywordsCache.value, keywordsCache.key == keywordsData { return cached }
            let decoded = (try? JSONCoding.decoder.decode([String].self,
                                                          from: keywordsData ?? Data())) ?? []
            keywordsCache.value = decoded
            keywordsCache.key = keywordsData
            return decoded
        }
        set {
            keywordsData = try? JSONCoding.encoder.encode(newValue)
            keywordsCache.value = newValue
            keywordsCache.key = keywordsData
        }
    }
}

// MARK: - JSON 解码缓存支撑

/// 全局共享的 JSON 编解码器。
///
/// `JSONDecoder()` / `JSONEncoder()` 的构造并不便宜，而模型层的 `Data? + 计算属性` 模式
/// 在列表 / 筛选 / 搜索路径上每次访问都会新建一个，累积开销显著。
enum JSONCoding {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
}

extension Segment {
    /// 带缓存的文件存在性检查：路径与上次一致就直接复用结果，否则查一次并记住。
    /// 用于把 `effectivePicture` 从"每次渲染一次 `stat()`"降到"每个路径一次"。
    fileprivate static func replacedFileExists(path: String, cache: DecodedCache<(path: String, exists: Bool)>) -> Bool {
        if let c = cache.value, c.path == path { return c.exists }
        let exists = FileManager.default.fileExists(atPath: path)
        cache.value = (path, exists)
        return exists
    }
}

/// 解码结果缓存盒。
///
/// 之所以用 **引用类型**而不是直接放一个 `@Transient var` 值属性：
/// SwiftData / Observation 会跟踪属性**赋值**，若在计算属性的 getter 里回填一个被跟踪的属性，
/// 会在视图 body 求值期间触发变更通知，导致「Modifying state during view update」乃至重绘循环。
/// 盒子引用本身始终不变、只改内部 `value`，因此回填是完全静默的。
///
/// ⚠️ **泛型元数绝对不许改**（`DecodedCache<T>` 就是 `<T>`，一个不多一个不少）。
/// `SchemaGuard.descriptorLines` 会把每个属性的 `|type=…|transient=…` 写进 schema 指纹行，
/// `classifySchemaChange` 见到"消失行"就判 `.destructive`，而那条分支的处理是**拒绝打开用户的库**。
/// 换类型名 / 加一个泛型参数 ⇒ 老用户下次启动进不去。要加字段就往盒里加属性（如 `key`），
/// 属性名与个数变化不碰类型名，指纹逐字不变。
final class DecodedCache<T> {
    var value: T?
    /// 缓存键：底层 `*Data` 字段的**当前值**。见下方约束 #4 —— 短路条件必须带上它。
    /// `replacedExistsCache` 不用这个字段（它的键是路径，已在元组里）。
    var key: Data?
    init() {}
}

/// ⚠️ 使用约束（改代码前必读）
///
/// 以下前提必须一直成立，否则要么读到过期数据、要么视图根本不刷新，且**都不会有任何报错**：
///
/// 1. **禁止绕过 setter 直接写底层 `*Data` 字段**（如 `semanticTypesData = ...`）。
///    要改值一律走 `segment.semanticTypes = ...`。
///    确实绕不过的场合是存在的：`MixCutApp.fixMissingSemanticTypes` 就是用裸 SQLite 写
///    `ZSEMANTICTYPESDATA` 的（跑在 UI 之前）。约束 #4 的键化正是为了让这类写入**下次 get 自愈**。
/// 2. **禁止从另一个 ModelContext 写这些字段**。缓存盒是**每个实例一份**，别的 context 里的
///    另一个实例写的值不会让本实例的键失效。当前 `container.mainContext` 是唯一的读写面；
///    `MixCutApp` 里那几处 `ModelContext(container)` 只跑一次性迁移、不碰这些字段。
///    将来引入后台上下文 / CloudKit 同步去写它们，必须在此补跨上下文失效逻辑。
/// 3. 新增带缓存的字段时，务必同时提供显式失效入口
///    （参考 `Segment.invalidateReplacedExistsCache()`）；**用了 `key` 的盒，失效时值与键成对清**——
///    只清 `value` 会留下"键还在、值没了"的半空盒。`replacedExistsCache` 不走 `key`
///    （它的键是路径，已经在 `(path, exists)` 元组里），所以那里只清 `value` 是对的。
/// 4. **带缓存的 getter，其短路条件必须读一次底层被跟踪字段，并让返回值依赖它**
///    （写法：`if let cached = box.value, box.key == backingData { return cached }`）。
///    写成 `if let cached = box.value { return cached }` 会让本次求值**完全不碰** `*Data` ⇒
///    SwiftUI 的 Observation 依赖登记不上 ⇒ 改了值卡片不重绘。这不是理论风险：
///    `SegmentLibraryViewModel.recomputeAllDerived()` 会无条件遍历全库读 `semanticTypes`，
///    卡片首帧之前每个分镜的盒都已经被焐热，所以这条通道是**必然断**、不是偶发。
///    （2026-10「标签改了不显示」复盘的根因。）
///    丢弃式的 `_ = backingData` 不算满足本条：它不承重，下一个人会当死码清掉。
///    守卫见 `Tests/MixCutCoreTests/SegmentRenderFreshnessTests.swift` 的 G2。


/// 从 `Segment` 造叙事描述 —— **全仓只此一处**，且**不跨关系边**。
///
/// 为什么要收成工厂：`SegmentDescriptor(...)` 的逐字段构造此前在
/// `SchemeViewModel`（两处生成路径）与 `NarrativeStructureEditorView` 各写了一份，
/// 连贯性门要的 `sourceKey` / `startSeconds` 一加就是"三份同时改、漏一份就静默失能"。
///
/// 为什么 `sourceKey` 由调用方传进来：跨 to-one 边读 `segment.video` 属于
/// `TombstoneReadGuard` 那族（真删后读死对象 SIGTRAP），而 `.live` 形态又被 G22 明令禁止。
/// 调用方本来就是按视频摊开分镜的，它手里就有来源 —— 于是这条边一次都不跨。
extension SegmentDescriptor {
    init(from segment: Segment, sourceKey: String) {
        self.init(
            id: segment.id,
            tags: segment.semanticTypes.map(\.rawValue),
            text: segment.text,
            duration: segment.endTime - segment.startTime,
            quality: segment.qualityScore,
            sourceKey: sourceKey,
            startSeconds: segment.startTime
        )
    }
}
