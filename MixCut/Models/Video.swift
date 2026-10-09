import Foundation
import SwiftData

/// 视频处理状态
enum VideoStatus: String, Codable, CaseIterable {
    case imported = "imported"                  // 已导入
    case queued = "queued"                      // 等待分析槽位（已排队但未轮到）
    case detectingScenes = "detecting_scenes"   // 镜头检测中
    case transcribing = "transcribing"          // ASR 识别中
    case analyzing = "analyzing"                // AI 语义分析中
    case completed = "completed"                // 处理完成
    case failed = "failed"                      // 处理失败
}

/// ASR 字级时间戳
struct ASRWord: Codable, Hashable {
    let word: String
    let start: Double
    let end: Double
}

/// ASR 原生句子（Whisper segment 级）
struct ASRSentence: Codable, Hashable {
    var text: String
    let start: Double
    let end: Double
}

@Model
final class Video: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var localPath: String
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var status: VideoStatus
    var errorMessage: String?

    /// ASR 识别结果
    var transcript: String?
    var asrWordsData: Data?      // [ASRWord] 编码存储
    var asrSentencesData: Data?  // [ASRSentence] Whisper 原生句子

    // MARK: - 片级听写来源（计划 §3.8）

    /// 上面两个**文本载体**是哪台引擎、哪档模型、什么时候跑出来的。
    /// 三个字段全空 = **未记录**（本轮之前的旧行就是这个状态）—— 拿默认值冒充某台引擎，
    /// 就是第 2 期"默认值冒充数据"那一族。
    /// ⚠️ 取舍写在这儿：`asrWordsData` 只承载字级时间戳、**不写台词文本**，所以本轮不给它标来源。
    var asrEngineRaw: String = ""
    var asrModelTier: String = ""
    var asrRunAt: Date?

    /// 读侧：认不出的存量字符串按"未记录"处理。
    var asrEngine: ASREngine? { ASREngine(rawValue: asrEngineRaw) }

    /// 只有**真的跑了一次片级听写**才调用（唯一写点）。
    func recordASRRun(engine: ASREngine, tier: String?) {
        asrEngineRaw = engine.rawValue
        asrModelTier = tier ?? ""
        asrRunAt = Date()
    }

    /// 清空 ASR 文本时同步清来源：留着"上次是谁跑的"，会让人以为那段文本还在库里。
    func clearASRRun() {
        asrEngineRaw = ""
        asrModelTier = ""
        asrRunAt = nil
    }

    /// 配音选定音色 id（≤3），JSON 编码
    var selectedVoiceIdsData: Data?

    // MARK: 解码缓存（不持久化，见 Segment.swift 末尾 `DecodedCache` 说明）
    @Transient private var asrWordsCache = DecodedCache<[ASRWord]>()
    @Transient private var asrSentencesCache = DecodedCache<[ASRSentence]>()
    @Transient private var selectedVoiceIdsCache = DecodedCache<[String]>()

    /// 配音全局语速（CosyVoice rate，基准 1.0，范围 0.7~1.3）。SwiftData 加字段，默认 1.0。
    var dubSpeechRate: Double = 1.0

    /// 原声克隆音色 id（qwen3-tts-vc）。nil = 尚未克隆。SwiftData 加字段。
    var clonedVoiceId: String?

    /// M1b：true = 用户在该视频上显式选择「跟随全局/项目音色」，改写时压制历史克隆声、
    /// 零克隆直合成（透传给 VoiceResolver.LegacyInput.suppressVideoClone）。
    /// false = 存量行为（有克隆声仍优先克隆）；只影响此后新生成，不自动重生旧音频。
    /// 带默认值轻量迁移，旧库打开即 false。
    var voiceFollowsGlobal: Bool = false

    /// 文件内容哈希（SHA-256），用于全局去重
    var contentHash: String?

    /// 分镜规划改写留痕：这条视频的切分被哪条规则动过（「整片保留」/「过碎合并」）。
    /// nil = 规划层原样放行。可选字段 ⇒ 轻量迁移就地加列，`AppSchemaV1`/`stages` 都不用动
    /// （见 `SchemaVersions.swift` 末尾「以后加字段时改哪里」）。
    var segmentationGuardNote: String?

    /// 规划层动手之前 AI 实际返回的分镜条数。
    /// 必须单独存：区间一旦并回去就反推不出来，不留这列就答不出「模型本来切了几段」。
    /// 整片保留时保持 nil —— 那次根本没调模型，写 0 会是假话。
    var aiOriginalSegmentCount: Int?

    /// true = 用户自建分镜的载体视频（分镜库「自建分镜」分类）。SwiftData 加字段，默认 false，旧数据自动为普通视频。
    var isUserUploaded: Bool = false

    /// **导入事实**：这条视频是在哪个项目里导入的（写定后不随复用变化）。
    /// 视频可被多个项目关联（projectVideos 多对多），但「它最初为哪个产品而来」只有一个答案：
    /// 产品归属实时经 `ownerProject.product` 推导，未来项目改属产品时视频归属自动跟随，无需冗余同步。
    /// nil 仅可能出现在 backfill 之前；读侧（ProductOwnershipBackfill/Catalog）回退到最早关联项目。
    /// 全局去重复用已有视频时**不得覆写**它。
    var ownerProject: Project?

    /// 该视频切出的分镜默认继承的素材来源 raw（SegmentSource.rawValue）。
    /// 只作用于**此后新切的分镜**，改动不回溯已有分镜。读侧用 `Video.defaultSource`。
    var defaultSourceRaw: String = SegmentSource.curated.rawValue

    /// 读侧唯一入口：未知 raw 回退「搬运」（导入默认口径），与分镜的「未分类」回退刻意不同。
    var defaultSource: SegmentSource {
        SegmentSource(rawValue: defaultSourceRaw) ?? .curated
    }

    /// 缩略图路径
    var thumbnailPath: String?

    /// 安全书签数据（用于沙盒访问）
    var bookmarkData: Data?

    @Relationship(deleteRule: .cascade, inverse: \ProjectVideo.video)
    var projectVideos: [ProjectVideo] = []

    @Relationship(deleteRule: .cascade, inverse: \Segment.video)
    var segments: [Segment] = []

    var createdAt: Date

    init(name: String, localPath: String) {
        self.id = UUID()
        self.name = name
        self.localPath = localPath
        self.duration = 0
        self.width = 0
        self.height = 0
        self.fps = 0
        self.status = .imported
        self.createdAt = Date()
    }

    /// 关联的项目列表
    var projects: [Project] {
        projectVideos.compactMap(\.project)
    }

    /// 被多少个项目引用
    var referenceCount: Int { projectVideos.count }

    /// 解码 ASR 字级时间戳
    ///
    /// ⚠️ 性能：ASR blob 可达 20KB+，逐句字幕 / 边界对齐等路径会反复访问；做惰性解码缓存。
    /// ⚠️ 短路条件必须带 `key == asrWordsData`（Segment.swift `DecodedCache` 约束 #4）：
    /// 只判 `value` 有没值，命中那次求值就完全不碰被跟踪字段，SwiftUI 的 Observation 依赖登记不上。
    /// 代价是每次 get 多一次 20KB 的字节比较（约微秒级），相对省掉的整段 JSON 解码是零头。
    var asrWords: [ASRWord] {
        get {
            if let cached = asrWordsCache.value, asrWordsCache.key == asrWordsData { return cached }
            let decoded = (try? JSONCoding.decoder.decode([ASRWord].self,
                                                          from: asrWordsData ?? Data())) ?? []
            asrWordsCache.value = decoded
            asrWordsCache.key = asrWordsData
            return decoded
        }
        set {
            asrWordsData = try? JSONCoding.encoder.encode(newValue)
            asrWordsCache.value = newValue
            asrWordsCache.key = asrWordsData
        }
    }

    /// 解码 Whisper 原生句子
    ///
    /// ⚠️ 同上：短路条件带 `key`（约束 #4）。
    var asrSentences: [ASRSentence] {
        get {
            if let cached = asrSentencesCache.value, asrSentencesCache.key == asrSentencesData { return cached }
            let decoded = (try? JSONCoding.decoder.decode([ASRSentence].self,
                                                          from: asrSentencesData ?? Data())) ?? []
            asrSentencesCache.value = decoded
            asrSentencesCache.key = asrSentencesData
            return decoded
        }
        set {
            asrSentencesData = try? JSONCoding.encoder.encode(newValue)
            asrSentencesCache.value = newValue
            asrSentencesCache.key = asrSentencesData
        }
    }

    /// 选定的 TTS 音色 id（≤3）
    ///
    /// ⚠️ 同上：短路条件带 `key`（约束 #4）。这一处是**活的**消费面：
    /// `SegmentVariantInspector` 在 body 里读 `segment.video?.selectedVoiceIds`，
    /// 音色换完而变体池不跟着换，就是标签那次同一个病。
    var selectedVoiceIds: [String] {
        get {
            if let cached = selectedVoiceIdsCache.value, selectedVoiceIdsCache.key == selectedVoiceIdsData {
                return cached
            }
            let decoded = (try? JSONCoding.decoder.decode([String].self,
                                                          from: selectedVoiceIdsData ?? Data())) ?? []
            selectedVoiceIdsCache.value = decoded
            selectedVoiceIdsCache.key = selectedVoiceIdsData
            return decoded
        }
        set {
            selectedVoiceIdsData = try? JSONCoding.encoder.encode(newValue)
            selectedVoiceIdsCache.value = newValue
            selectedVoiceIdsCache.key = selectedVoiceIdsData
        }
    }

    /// 分辨率描述
    var resolution: String {
        "\(width)×\(height)"
    }
}
