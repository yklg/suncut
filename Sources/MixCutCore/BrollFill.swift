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
// 1. **只吃打了「空镜」标签的分镜**：带台词的段插进来会让画面与别段的口播撞叙事。
//    「空镜」是机器标签（`EmptyLensPolicy` 唯一写入方），不是人挑的内容分类。
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
