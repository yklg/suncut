import Foundation

// ============================================================================
// 空镜承接（B 块差额的后置档）—— 纯函数，住在 Core
//
// ## 要解决的是什么
//
// 画面窗口往源片后面续帧的天花板是**同素材下一格分镜的起点**（见 `PictureWindow.swift`
// 的 `siblingStartFrame`），所以一条素材中间那几格的余量常常是 0。配音比"分镜 + 可续画面"
// 还长时，只剩两条路：把后续分镜整体后挪（等于重排边界）或**插一段无关画面**把声音垫满。
// 2026-11-05 拍的是后者 ⇒ 本文件。
//
// ## 四条不许违反的纪律
//
// 1. **只吃「空镜」标签 + 台词不构成叙事的段**：带口播的段插进来会让画面与别段撞叙事。
//    「空镜」是机器标签（`EmptyLensPolicy` 唯一写入方），不是人挑的内容分类。
//    ⚠️ 2026-11-06 补：光看标签拦不住手改（Inspector chip / 右键 / MCP 三条路都能给人打上
//    「空镜」），但**不能**简单要求"台词为空"——名单层命中的段文本**必然非空**
//    （`EmptyLensPolicy.knownHallucinationHit` 对空文本直接返回 nil），旧库补标产出的合法供给
//    正是"文本 = whisper 幻觉套话"那种段。入池口径因此是 `acceptsAsSupply(text:taggedAsEmptyShot:)`。
// 2. **同一段画面不许在成片里出现两遍**：与本格窗口帧区间重叠的同源供给要剔除；
//    每片供给**至多用一次**（跨槽位也只用一次），这条由 `consumed` 记账。
//    （这条不是理论风险 —— B 块第一版就是因为漏了同源重叠被 BR-4 抓到的。）
// 3. **确定性**：这里不许引入随机（全仓的随机点只有 `DubbingViewModel.swift:655` 抽音色风格
//    和一处测试自己打乱输入，都与选片无关）。排序键 = 分镜编号 → 起点帧，
//    同一库必然得到同一个 plan，重导同一条片子不会换画面 —— 换了就没法复现，也没法判回归。
// 4. **秒→帧只走 `FrameTime`**（FT-01 名册口径，同 `PictureWindow.swift:20`）。
//
// ## 为什么插空镜不是"把成片变长"
//
// 插进去的帧只填**配音已经要用而画面不够**的那段时间：槽位最终时长 = max(画面, 配音) = 配音。
// 所以补满时总时长不因空镜而增加；增加的是"无关画面"的观感成本，那正是这条档位买的东西。
// 接不满 ⇒ 返回 `filled == false`，调用方**必须继续拦**（不许默默用半段空镜出一条音画不同步的片子）。
// ============================================================================

/// 一条**可拿来补差额**的空镜供给（值型，由 App 层从模型图里取好再喂进来）。
public struct BrollSupply: Equatable, Sendable {
    /// 分镜编号（`Segment.segmentIndex`）—— 确定性排序键与"只用一次"的去重键。
    public let label: String
    public let videoPath: String
    /// 开区间帧口径，同 `Segment.startFrame/endFrame`
    public let startFrame: Int
    public let endFrame: Int
    /// 这条供给自己素材的帧率（帧数换算成秒要用它，不是槽位的帧率）
    public let fps: Double
    /// 同源判定键：同一条源视频的 contentHash；替换画面用它自己的路径（合成片与原片不是同一份像素）
    public let sourceKey: String

    public init(label: String, videoPath: String, startFrame: Int, endFrame: Int,
                fps: Double, sourceKey: String) {
        self.label = label; self.videoPath = videoPath
        self.startFrame = startFrame; self.endFrame = endFrame
        self.fps = fps; self.sourceKey = sourceKey
    }

    public var frames: Int { max(0, endFrame - startFrame) }

    /// 这条供给能贡献几秒（按它自己的帧率）。
    public func seconds() -> Double { FrameTime.seconds(frame: frames, fps: fps) }
}

/// 规划后**实际要插**的一片画面（可能被截短）。
public struct BrollPiece: Equatable, Sendable {
    public let videoPath: String
    public let startFrame: Int
    public let endFrame: Int
    public let fps: Double

    public init(videoPath: String, startFrame: Int, endFrame: Int, fps: Double) {
        self.videoPath = videoPath; self.startFrame = startFrame
        self.endFrame = endFrame; self.fps = fps
    }

    public var frames: Int { max(0, endFrame - startFrame) }

    public func seconds() -> Double { FrameTime.seconds(frame: frames, fps: fps) }
}

/// 一个槽位的补差额**需求**（本格窗口与配音的关系）。
public struct BrollDemand: Equatable, Sendable {
    /// 画面接长之后还差多少秒（> 0 才需要插）
    public let neededSeconds: Double
    /// 容差：与生成侧超字闸同一颗（`DubLengthGate.measuredToleranceSeconds`），差这么多就当已接满
    public let toleranceSeconds: Double
    /// 本格自己那条分镜的编号 —— 不许拿它当空镜（纪律 2）
    public let slotSegmentLabel: String
    /// 本格窗口用的源与帧区间 —— 同源供给里与它重叠的必须剔除（纪律 2）
    public let windowSourceKey: String
    public let windowStartFrame: Int
    public let windowEndFrame: Int

    public init(neededSeconds: Double, toleranceSeconds: Double, slotSegmentLabel: String,
                windowSourceKey: String, windowStartFrame: Int, windowEndFrame: Int) {
        self.neededSeconds = neededSeconds; self.toleranceSeconds = toleranceSeconds
        self.slotSegmentLabel = slotSegmentLabel
        self.windowSourceKey = windowSourceKey
        self.windowStartFrame = windowStartFrame; self.windowEndFrame = windowEndFrame
    }
}

public enum BrollPolicy {

    /// 入池口径（纪律 1 的可执行形态）：这段**作为插片画面**会不会与宿主格的口播叙事冲突。
    ///
    /// 两道读侧证据，满足任一即放行：
    ///   ① 台词归一后为空 —— 没有话可撞；
    ///   ② 名单层就地复算仍判空镜 —— 文本是 whisper 在静音上幻觉出来的那类套话，
    ///      它**不是**真口播。这条是必须的：机器判出的合法空镜段文本往往非空（见文件头纪律 1 的 ⚠️），
    ///      只按 ① 筛会把旧库补标产出的供给全部踢掉，差额承接又变回空池。
    ///
    /// 为什么用 `phraseOnlyVerdict(...).isEmptyLens` 而不是 `EmptyLensPolicy.shouldSuppressTag(...)`：
    /// 后者带"拦打标"那颗闸（:377-397），那颗闸只管**要不要写标签**，不该决定**已存在的画面能不能用**；
    /// 把两件事绑在一起，关闸就会静默清空插片池。
    ///
    /// 结构性事实：`BrollSupply` 不携带台词（只有 label/帧区间/fps/sourceKey），所以一旦进了池，
    /// 下游**无法再判一次**"有没有口播"——这道闸只能建在入池处。
    /// 第三道证据 `voicedFraction`（来自持久化的静音区间，读侧现算）补的是前两道够不到的那一类：
    /// **纯音乐/杂音上被幻觉出一句非套话的话**（例：他库里那条被判"没人说话"却被认成
    /// 「Zither Harp」的素材）。那种段文本非空、名单也不命中 ⇒ 只认前两道的池子会把它踢出去，
    /// 而它恰恰是最该拿来垫差间的画面。
    ///
    /// 阈值不在这儿写：走 `EmptyLensPolicy.energyConvicts`（与拦打标同一个数）。
    /// 没有这份证据的段（旧素材未探测、或人工打标签）仍然只看前两道 ⇒ 并行线那条
    /// "手改标签也不许入池"的口子一寸没放宽。
    public static func acceptsAsSupply(text: String, taggedAsEmptyShot: Bool,
                                       voicedFraction: Double? = nil) -> Bool {
        guard taggedAsEmptyShot else { return false }
        if EmptyLensPolicy.energyConvicts(voicedFraction: voicedFraction) { return true }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return EmptyLensPolicy.phraseOnlyVerdict(text).isEmptyLens
    }

    /// 单槽最多插几片。为什么要封顶：一个槽位插七八片空镜，成片就变成快切空镜集锦，
    /// 观感比"声音压在下一格画面上"更差；封顶后接不满会照实报 `filled == false` 继续拦。
    public static let maxPiecesPerSlot = 4

    /// 规划结果。
    public struct Plan: Equatable, Sendable {
        public let pieces: [BrollPiece]
        /// 这些片段实际贡献的秒数（各自帧率换算后求和）
        public let coveredSeconds: Double
        /// 是否接满（含容差）
        public let filled: Bool

        public static let empty = Plan(pieces: [], coveredSeconds: 0, filled: true)
    }

    /// 可用的供给（先把不可用的剔掉，再去排序键）。
    ///
    /// 剔除条件按纪律 1/2/4：非空镜由调用方筛（模型层），这里剔的是**结构性不可用**——
    /// 零帧、帧率不成立、与本格窗口同源重叠、就是本格自己。
    public static func eligible(_ supplies: [BrollSupply], for demand: BrollDemand) -> [BrollSupply] {
        supplies
            .filter { $0.frames > 0 && $0.fps.isFinite && $0.fps > 0 }
            .filter { $0.label != demand.slotSegmentLabel }
            .filter { !overlapsWindow($0, demand) }
            .sorted { lhs, rhs in
                lhs.label != rhs.label ? lhs.label < rhs.label : lhs.startFrame < rhs.startFrame
            }
    }

    /// 与本格窗口**帧区间重叠**的同源供给 = 同一段画面播两遍 ⇒ 剔掉。
    /// 只判同源：不同素材的画面重叠是巧合不是重复（替换片的 sourceKey 是它自己的路径，天然不判）。
    private static func overlapsWindow(_ supply: BrollSupply, _ demand: BrollDemand) -> Bool {
        guard supply.sourceKey == demand.windowSourceKey else { return false }
        return supply.startFrame < demand.windowEndFrame && demand.windowStartFrame < supply.endFrame
    }

    /// 规划：按确定性顺序取片，截到"刚好补齐"，记占用账。
    ///
    /// - Parameter consumed: 本条成片**已用过**的供给 label（跨槽位共享的一本账，调用方持有）。
    ///   用掉的整片都算占用，哪怕这次只截了它前半段 —— 半段复用会让同一条空镜在成片里出现两次。
    public static func plan(_ demand: BrollDemand,
                            supplies: [BrollSupply],
                            consumed: inout Set<String>) -> Plan {
        guard demand.neededSeconds > demand.toleranceSeconds else { return .empty }
        let queue = eligible(supplies, for: demand).filter { !consumed.contains($0.label) }

        var pieces: [BrollPiece] = []
        var covered = 0.0
        var remaining = demand.neededSeconds

        for supply in queue {
            guard remaining > demand.toleranceSeconds else { break }
            guard pieces.count < maxPiecesPerSlot else { break }
            // 秒→帧一律 FrameTime（round 到最近帧），取不满整片就截
            let want = FrameTime.frame(seconds: remaining, fps: supply.fps)
            let take = min(supply.frames, max(0, want))
            guard take > 0 else { continue }
            let piece = BrollPiece(videoPath: supply.videoPath,
                                   startFrame: supply.startFrame,
                                   endFrame: supply.startFrame + take,
                                   fps: supply.fps)
            pieces.append(piece)
            covered += piece.seconds()
            remaining = demand.neededSeconds - covered
            consumed.insert(supply.label)
        }
        return Plan(pieces: pieces, coveredSeconds: covered,
                    filled: remaining <= demand.toleranceSeconds)
    }

    /// 供给池**一共**还能给多少秒（生成侧超字闸要把它算进容量时用）。
    ///
    /// 口径：只算单槽可插的上限（`maxPiecesPerSlot` 封顶后的前 N 片），**不做跨槽记账** ——
    /// 生成一条配音时还不知道别的槽会先吃掉谁。所以这颗数是**乐观值**：
    /// 用它放宽生成闸之后，导出侧仍可能因账被吃光而拦下来。
    /// ⚠️ 因此它只能当"要不要花钱合成"的参考，不能当"一定接得住"的承诺。
    public static func poolSeconds(_ supplies: [BrollSupply], for demand: BrollDemand) -> Double {
        eligible(supplies, for: demand)
            .prefix(maxPiecesPerSlot)
            .reduce(0.0) { $0 + $1.seconds() }
    }
}

/// 滤镜图里一片画面的位置：`BrollPiece` 的**渲染态**（视频路径已换成 ffmpeg 输入序号）。
public struct PicturePieceSource: Equatable, Sendable {
    public let inputIndex: Int
    public let startFrame: Int
    public let endFrame: Int
    /// 这片自己素材的帧率（帧号在它自己的时间轴上，归一化到槽位帧率由滤镜做）
    public let fps: Double

    public init(inputIndex: Int, startFrame: Int, endFrame: Int, fps: Double) {
        self.inputIndex = inputIndex; self.startFrame = startFrame
        self.endFrame = endFrame; self.fps = fps
    }
}

// MARK: - 跨槽占用账（生成侧容量用）

/// 一条方案**按槽位顺序**重放占用账，算出目标格**实际**还能垫几秒空镜。
///
/// ## 为什么不能只算本槽
///
/// 空镜的纪律是"每片整条片子只许用一次"。逐格各自许诺整个池子会得到：每一格在生成时
/// 都"接得住"，导出时却因为账被吃光而拦下来 —— 那时 TTS 费用已经花掉了。
/// 这是本仓最贵的一类两处口径分叉（同 PW-12 那条跨接缝不变式），所以生成侧必须用
/// **与 `DubExportInput.from` 完全同一个重放顺序**（槽位顺序 + 同一本 `consumed` 账）。
///
/// ## 收缩规则
///
/// 设 h(x) = 「把目标格的需求当成 x 重放一遍后，**所有有需求的槽**都接得住」。
/// x 越大越难成立（单调），所以可垫量 = 满足 h 的最大 x。
/// 若 h(0) 都不成立（别的槽今天就已经接不住），返回 **0** —— 池子已经赔光了，
/// 再往这一格灌长文案只会多拦一条片子，不给虚假承诺。
public enum SchemeBrollBudget {

    /// - Parameters:
    ///   - demands: 按槽位顺序排列的需求。非目标格填**其现有配音**算出的差额（没配音填 0）。
    ///   - targetIndex: 目标格下标。
    ///   - granularitySeconds: 收缩步长，由调用方传（一般是一帧的秒数）；必填、无默认值 ——
    ///     写死一个步长就等于让不同帧率的方案用同一个精度。
    public static func brollSecondsAvailable(demands: [BrollDemand],
                                             targetIndex: Int,
                                             supplies: [BrollSupply],
                                             granularitySeconds: Double) -> Double {
        guard demands.indices.contains(targetIndex),
              granularitySeconds.isFinite, granularitySeconds > 0 else { return 0 }
        var base = demands
        base[targetIndex] = BrollDemand(neededSeconds: 0,
                                        toleranceSeconds: demands[targetIndex].toleranceSeconds,
                                        slotSegmentLabel: demands[targetIndex].slotSegmentLabel,
                                        windowSourceKey: demands[targetIndex].windowSourceKey,
                                        windowStartFrame: demands[targetIndex].windowStartFrame,
                                        windowEndFrame: demands[targetIndex].windowEndFrame)
        guard replayAllFilled(base, supplies: supplies) else { return 0 }

        let target = demands[targetIndex]
        guard target.neededSeconds > target.toleranceSeconds else { return 0 }
        // 上界：本槽需求，且不超过"整池能给的量"（否则二分白跑）
        let poolTotal = supplies.filter { $0.frames > 0 && $0.fps > 0 }
            .reduce(0.0) { $0 + $1.seconds() }
        var high = min(target.neededSeconds, poolTotal)
        var low = 0.0
        var best = 0.0
        while low <= high {
            let mid = (low + high) / 2
            var trial = demands
            trial[targetIndex] = BrollDemand(neededSeconds: mid,
                                            toleranceSeconds: target.toleranceSeconds,
                                            slotSegmentLabel: target.slotSegmentLabel,
                                            windowSourceKey: target.windowSourceKey,
                                            windowStartFrame: target.windowStartFrame,
                                            windowEndFrame: target.windowEndFrame)
            if replayAllFilled(trial, supplies: supplies) {
                best = mid
                low = mid + granularitySeconds
            } else {
                high = mid - granularitySeconds
            }
        }
        // 容差以内的需求**一片都不占**（`BrollPolicy` 就是这么跳过的）⇒ 归零，
        // 别把二分步长的残渣（0.025 这类）当"能垫半帧"报给调用方。
        return best > target.toleranceSeconds ? best : 0
    }

    /// 重放一遍占用账，看**所有有需求的槽**是否都接得住。
    private static func replayAllFilled(_ demands: [BrollDemand], supplies: [BrollSupply]) -> Bool {
        var consumed = Set<String>()
        for demand in demands where demand.neededSeconds > demand.toleranceSeconds {
            let plan = BrollPolicy.plan(demand, supplies: supplies, consumed: &consumed)
            if !plan.filled { return false }
        }
        return true
    }
}
