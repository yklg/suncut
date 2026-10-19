import Foundation

// MARK: - 导出画布尺寸的唯一真源

/// 导出档位。**全部尺寸常量的唯一住所** —— App 侧不许再出现第二份。
///
/// 为什么必须住在 Core（2026-10-19）：同一条"档位→宽高"的规则原先抄了 7 份
/// （`DubExportService.resolution`、`ExportService.performExport`、`FFmpegRunner.concat` 的兜底、
/// `ShotCompositionService.compose` 的默认参数、`VariantBatchExportService` 走的不带 scale 的
/// `cutSegment`、`exportSingleSegment` 把单段自身宽高当 maxWidth 喂入、MCP 不传 config 落到默认档）。
/// 抄到第 7 份那天，两条腿对"这次导出是多少乘多少"的答案就可以不一样 —— 而本应用批量导出的
/// 41 条成片因此整批被千川拒收，全程没有任何一处知道产物是 480 宽。
///
/// 判据住在视图/服务内部还有个副作用：`MixCut/**` 不参与 SwiftPM 编译，
/// 写在里面的尺寸规则**根本无法被 `swift test` 覆盖**。下沉即可测。
public enum DeliveryTier: String, CaseIterable, Identifiable, Sendable {
    case original = "原始分辨率"
    case p1080 = "1080p"
    case p720 = "720p"

    public var id: String { rawValue }
}

/// 输出画布。宽高之外只多带一个 ffmpeg 滤镜用的字符串形状，避免三个调用点各拼一遍。
public struct DeliveryCanvas: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// ffmpeg `scale` / `pad` 用的 "宽:高"（冒号分隔，不是 `x`）。
    public var filterString: String { "\(width):\(height)" }

    /// 档位 + 本批素材最大宽高 → 画布。**全应用唯一一处"档位→尺寸"的换算**。
    ///
    /// - `.original`：原样透出素材最大宽/高，只把奇数向上取偶（见 `evenUp`）。
    ///   素材宽高都缺（导入未跑完 / 探测失败）时退回 1080×1920，**不产出 0×0** ——
    ///   0 宽画布会让 ffmpeg 的 `scale=0:0` 直接失败，而失败点离真正的原因隔着三层。
    /// - 固定档：一律 9:16 竖屏画布。
    ///
    /// ⚠️ 固定档**刻意不随素材横竖翻转**。旧 `ExportService` 那份拷贝里写着
    /// `maxWidth > maxHeight ? "1920:1080" : "1080:1920"`，而旧 `DubExportService` 那份不认横屏 ——
    /// 两份"重复实现"的行为其实不一致，这正是重复的代价。本产品的素材全部是 9:16 竖屏信息流
    /// （`CLAUDE.md`「视频显示比例」），横屏分支在现网数据上不可达，收敛时统一到竖屏。
    public static func size(tier: DeliveryTier,
                            sourceMaxWidth: Int,
                            sourceMaxHeight: Int) -> DeliveryCanvas {
        switch tier {
        case .original:
            let w = sourceMaxWidth > 0 ? evenUp(sourceMaxWidth) : fallbackWidth
            let h = sourceMaxHeight > 0 ? evenUp(sourceMaxHeight) : fallbackHeight
            return DeliveryCanvas(width: w, height: h)
        case .p1080:
            return DeliveryCanvas(width: 1080, height: 1920)
        case .p720:
            return DeliveryCanvas(width: 720, height: 1280)
        }
    }

    /// 素材宽高都探测不到时的兜底画布。
    static let fallbackWidth = 1080
    static let fallbackHeight = 1920

    /// 奇数向上取偶。`yuv420p` 的色度次采样要求宽高都是偶数，奇数会让 ffmpeg 要么报错、
    /// 要么自行降采样到另一种像素格式 —— 两种都比"取偶"更难查。
    public static func evenUp(_ n: Int) -> Int { (n + 1) / 2 * 2 }

    /// 导出面板的回显。**与 `size()` 同处产出** —— 这样"面板说的"和"真算出来的"不可能是两套话。
    ///
    /// 原先面板只有一个裸 `Picker("分辨率")`，从头到尾不告诉你这档实际输出多少乘多少；
    /// 于是 480p 被选中时屏上一个字都没变，41 条报废品就这么导出去了。
    /// 若把这句话拼在 `ExportView` 里，它就是第八份尺寸抄本 —— 所以拼装在 Core。
    ///
    /// ⚠️ `.original` 档下，若调用方没有素材最大宽高就**不许猜**：面板自己再遍历一遍素材，
    /// 就是"两处算同一件事、可以各说各话"—— 那正是本次事故的形状。此时如实说"导出时现算"。
    public static func readout(target: DeliveryTargetID, tier: DeliveryTier,
                               sourceMaxWidth: Int? = nil, sourceMaxHeight: Int? = nil) -> String {
        // 能不能提前报出确切画布：固定档一定能；`.original` 只有拿到素材最大宽高才能，
        // 而面板拿不到（它若为此再遍历一遍素材，就又造出第八份算尺寸的抄本）。
        let known: (width: Int, height: Int)?
        switch tier {
        case .p1080, .p720:
            let c = size(tier: tier, sourceMaxWidth: 0, sourceMaxHeight: 0)
            known = (c.width, c.height)
        case .original:
            if let w = sourceMaxWidth, let h = sourceMaxHeight, w > 0, h > 0 {
                let c = size(tier: .original, sourceMaxWidth: w, sourceMaxHeight: h)
                known = (c.width, c.height)
            } else {
                known = nil
            }
        }

        let head: String
        if let c = known {
            head = "\(target.label) · 将输出 \(c.width)×\(c.height)"
        } else {
            head = "\(target.label) · 输出＝本方案素材最大宽高（面板不预测，导出时现算）"
        }
        guard let c = known else { return head }
        switch target.spec.judge(width: c.width, height: c.height) {
        case .ok:
            return head + "（平台已证放行）"
        case .rejected(let reason):
            return head + "（\(reason.evidence.date) 已被平台证明不可投放，导出会被拦下）"
        case .unproven:
            // 「未核验」既不是「不合格」也不是「没问题」—— 屏幕上必须说清是前者。
            return head + "（该尺寸尚无平台一手记录，能否放行未核验）"
        }
    }
}

// MARK: - 平台判定证据

/// 一条**一手**平台判定记录：某个尺寸在某个日期被某条真实通道放行 / 拒收。
public struct PlatformVerdictRecord: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 可回溯的来源（接口回包路径、面板红字原文）。不写"听说"、不写"按规范推断"。
    public let source: String
    /// 取证日期，`yyyy-MM-dd`。平台判据会变，没有日期的证据等于没有证据。
    public let date: String

    public init(width: Int, height: Int, source: String, date: String) {
        self.width = width
        self.height = height
        self.source = source
        self.date = date
    }
}

/// 一条**已被一手证据证明**的画幅规则。
///
/// 为什么需要它（而不是只靠逐尺寸名册）：逐尺寸名册只能拦住"我们恰好传过的那个尺寸"，
/// 而素材尺寸是连续的 —— `.original` 档会把素材自己的宽高原样透出去，
/// 素材库里现成有 704×1248、480×960、720×960 三颗非 9:16 的，下一批还会有别的。
/// 拦住**一类**形状要靠规则，规则必须有证据，没证据的一律不立。
public enum AspectRule: String, Sendable, CaseIterable, Equatable {
    /// 画幅必须**精确** 9:16（整数交叉相乘，零容差）。
    ///
    /// 证据（2026-10-19 用户实传千川「上传视频」面板，五格对照小样）：
    /// `1080×1620`（2:3）被拒，红字「素材尺寸**比例**不符合规范」；
    /// 同批 `900×1600`（精确 9:16、宽度 900）**放行**。
    /// 而 `486×864`（精确 9:16、宽 486）被拒时红字是「素材尺寸（**宽度**）不符合规范」——
    /// **两条报错措辞不同 ⇒ 平台是两条互相独立的校验**，本规则只对应"比例"那一条。
    case exactNineSixteen

    public func isSatisfied(width: Int, height: Int) -> Bool {
        switch self {
        case .exactNineSixteen:
            return width > 0 && height > 0 && width * 16 == height * 9
        }
    }

    public var label: String {
        switch self {
        case .exactNineSixteen: return "画幅必须精确 9:16"
        }
    }

    /// 立这条规则所依据的那一手记录。规则不许无证据存在。
    public var evidence: PlatformVerdictRecord {
        switch self {
        case .exactNineSixteen:
            return PlatformVerdictRecord(
                width: 1080, height: 1620,
                source: "千川上传面板红字「素材尺寸比例不符合规范，请检查后重新上传」；同批 900×1600（精确 9:16）放行",
                date: "2026-10-19")
        }
    }
}

/// 被拒的具体理由 —— 分得很细，是因为"这个尺寸我们亲手传过并被拒"和
/// "这个尺寸没传过但违反了某条已证规则"是两种强度不同的知识，报错时必须分开说。
public enum RejectionReason: Sendable, Equatable {
    case thisSizeProvenRejected(PlatformVerdictRecord)
    case violatesProvenRule(rule: AspectRule, evidence: PlatformVerdictRecord)

    public var evidence: PlatformVerdictRecord {
        switch self {
        case .thisSizeProvenRejected(let record): return record
        case .violatesProvenRule(_, let evidence): return evidence
        }
    }
}

/// 一个尺寸对某个交付目标的判定结果。
public enum Deliverability: Sendable, Equatable {
    case ok
    case rejected(reason: RejectionReason)
    /// 没有任何一手记录或已证规则覆盖这个形状。**既不能当成"可以投放"，也不许拿它硬拦用户** ——
    /// 它是"我们还不知道"，不是"没问题"。
    case unproven
}

/// 交付目标：产物要交给谁、对方已经证明接受/拒绝过哪些尺寸、以及已证的画幅规则。
///
/// ⚠️ **宽度下限仍未写进来**。2026-10-19 的五格对照只把它夹到 **(486, 900]**：
/// `486×864`（精确 9:16）被拒、`900×1600` 放行。中间那一格 `720×1280` 是**决定性的**，
/// 因为 720p 是导出面板上现成的一个档位 —— 它过不了就说明那一档得下架。
/// 在 F 格读数回来之前，这里不许出现任何 `minWidth`。
/// 同批被证伪的是「标准分辨率白名单」假设：`900×1600` 不是任何标准档却过了。
public struct DeliverySpec: Sendable, Equatable {
    public let name: String
    public let provenAccepted: [PlatformVerdictRecord]
    public let provenRejected: [PlatformVerdictRecord]
    public let aspectRules: [AspectRule]

    public init(name: String,
                provenAccepted: [PlatformVerdictRecord],
                provenRejected: [PlatformVerdictRecord],
                aspectRules: [AspectRule] = []) {
        self.name = name
        self.provenAccepted = provenAccepted
        self.provenRejected = provenRejected
        self.aspectRules = aspectRules
    }

    /// 巨量千川 · 竖屏投放。
    ///
    /// 注：用户同日实传还放行过 2160×3840，但那是"源素材都能上传成功"这句口述
    /// 减去几条例外后的**推论**，没有逐条对着平台读数核过，因此不进 `provenAccepted`。
    /// 720×1280 同样仍是推论 —— 它是 F 格要证的那一颗（见类型文档注释）。
    public static let qianchuanVertical = DeliverySpec(
        name: "巨量千川 · 竖屏投放",
        provenAccepted: [
            PlatformVerdictRecord(
                width: 1080, height: 1920,
                source: "千川开放平台 video/get 回包（账户自有素材库，120 条 width/height 全为此尺寸）",
                date: "2026-10-12"),
            PlatformVerdictRecord(
                width: 900, height: 1600,
                source: "千川「上传视频」面板实传放行（进度条走完＋绿勾，无红字）。这一格同时证伪了「标准分辨率白名单」假设 —— 900×1600 不是任何标准档",
                date: "2026-10-19")
        ],
        provenRejected: [
            PlatformVerdictRecord(
                width: 480, height: 854,
                source: "千川「上传视频」面板红字：素材尺寸（宽度）不符合规范，请检查后重新上传（本批 41 条整批）",
                date: "2026-10-19"),
            PlatformVerdictRecord(
                width: 480, height: 960,
                source: "同上，用户实传源素材 爆点/下载 (20).mp4",
                date: "2026-10-19"),
            PlatformVerdictRecord(
                width: 704, height: 1248,
                source: "同上，用户实传源素材 爆点2/01ea1a41803d77ce4f0370019e7690161f_309.mp4",
                date: "2026-10-19"),
            PlatformVerdictRecord(
                width: 486, height: 864,
                source: "千川「上传视频」面板红字：素材尺寸（宽度）不符合规范（五格对照 B 格；它是**精确 9:16**，所以拒它的是宽度那条校验，不是比例）",
                date: "2026-10-19")
        ],
        aspectRules: [.exactNineSixteen])

    /// 不限：本地留档用，不承诺可投放。证据表与规则全空 ⇒ `judge` 恒返回 `.unproven`。
    public static let unrestricted = DeliverySpec(name: "不限（仅本地留档）",
                                                  provenAccepted: [],
                                                  provenRejected: [],
                                                  aspectRules: [])

    /// 未显式选定交付目标时的缺省目标。
    ///
    /// 本产品的产物就是千川/抖音投放素材，缺省到"不限"等于没有闸。
    /// 面板的「交付目标」选择器已落地（`ExportView`），所以这一颗现在只服务
    /// 无人值守入口（MCP 的 `export_scheme` 目前仍不传 config，见台账 §六-3）。
    public static let fallback: DeliverySpec = .qianchuanVertical

    /// 只对**已证**的形状表态；表是空的时候什么都不拦（见类型文档注释里的理由）。
    public func judge(width: Int, height: Int) -> Deliverability {
        if let hit = provenRejected.first(where: { $0.width == width && $0.height == height }) {
            return .rejected(reason: .thisSizeProvenRejected(hit))
        }
        // 规则查在 provenAccepted 之前：名册只能拦住"恰好传过的那几个尺寸"，
        // 而 .original 档透出的尺寸是连续的 —— 靠规则才拦得住没登记过的那一类。
        for rule in aspectRules where !rule.isSatisfied(width: width, height: height) {
            return .rejected(reason: .violatesProvenRule(rule: rule, evidence: rule.evidence))
        }
        if provenAccepted.contains(where: { $0.width == width && $0.height == height }) {
            return .ok
        }
        return .unproven
    }
}

/// 交付目标的可持久化标识（面板选择器与 `@AppStorage` 存的就是这颗）。
///
/// 为什么不让 `@AppStorage` 直接存 `DeliverySpec`：它是带两张证据表的 struct，
/// 一旦落盘，代码里的证据表更新后就会与用户存的旧副本分叉 —— 存的必须是"选了哪个目标"，
/// 证据表永远由代码现给。
public enum DeliveryTargetID: String, CaseIterable, Identifiable, Sendable {
    case qianchuanVertical
    case unrestricted

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .qianchuanVertical: return "巨量千川 · 竖屏投放"
        case .unrestricted:      return "不限（仅本地留档）"
        }
    }

    public var spec: DeliverySpec {
        switch self {
        case .qianchuanVertical: return .qianchuanVertical
        case .unrestricted:      return .unrestricted
        }
    }
}

/// 导出前闸的**唯一**判据。
///
/// 为什么也要住在 Core：闸若写在某个服务里，第二条导出腿（配音导出 / 普通导出 / MCP /
/// 单分镜）就只能再抄一遍 —— 而"抄第二遍"正是这次事故的成因。判据一份，各处只负责把它
/// 变成自己那层的错误类型。
public enum DeliveryGate {

    /// 返回 `nil` = 放行；返回文案 = 必须拦，且文案要能指到一手来源与日期。
    ///
    /// **只拦"已被平台证明拒收"的形状。** 「未核验」不是"不合格" —— 拿它拦用户就是
    /// 拿猜测当事实；平台判据的三个假设还没分离（见 `DeliverySpec` 的文档注释）。
    public static func rejectionMessage(for spec: DeliverySpec, width: Int, height: Int) -> String? {
        guard case .rejected(let reason) = spec.judge(width: width, height: height) else { return nil }
        let why: String
        switch reason {
        case .thisSizeProvenRejected:
            why = "该尺寸已被实传证明拒收"
        case .violatesProvenRule(let rule, _):
            why = "违反已证平台规则：\(rule.label)"
        }
        let record = reason.evidence
        return "输出画布 \(width)×\(height) 不可投放（\(why)；\(record.date)，平台原文：\(record.source)）。"
             + "请改用其它分辨率档位；若确需该尺寸，请选「不限（仅本地留档）」交付目标。"
    }
}
