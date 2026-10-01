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
        }
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
        textSource: TranscriptSource = .unknownLegacy
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
