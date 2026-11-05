import Foundation

// ============================================================================
// 画面窗口（B 块）—— 纯派生，住在 Core
// 计划真源：~/.qoder-cn/plans/mossy-sea-elk.md §二 B 块 11–15
//
// ## 要解决的是什么
//
// A 块把配音语速固定成"一颗值贯穿全片"之后，配音不再被 atempo 压进分镜 ⇒
// **配音可以比原分镜画面长**。今天这是硬错：`DubLengthGate` 直接拒了那条文案
// （「超字闸」）。B 块的做法是**画面接长**而不是把声音压回去：
// 超出分镜尾帧的部分，往源视频后面续帧；续到源片末尾还差，才判差额（差额插空镜是后置档）。
//
// ## 三条已拍的纪律（本文件不许违反）
//
// 1. **不留尾帧定格**：`AlignmentPlan.swift:64` 与本仓 `tpad=stop_mode=clone` 那一支
//    （`FrameCountAligner.pad(repeatLast:)`、`ShotCompositionService.swift:120-127`）
//    就是重复末帧 ⇒ 窗口派生**不复用** `.pad` 那一支，只借 `.trim`／`.none` 的形状。
// 2. **不重复用同一分镜**补差额。
// 3. **秒→帧只走 `FrameTime`**（全仓唯一口径，见 `FrameTimeSingleSourceGuardTests` 的 FT-01：
//    任何新的裸 `* fps` 不在名册里就红）。所以本文件里**一颗 `* fps` 都不许出现**，
//    要换算就调 `FrameTime.frame(seconds:fps:)`。理由不是洁癖：本仓 2026-10-19 真实事故
//    是"档位→宽高"规则抄了 7 份 ⇒ 41 条成片 480×854 被千川拒收，且没有一处代码知道自己算出了 480。
//
// ## 帧号口径
//
// 与 `Segment` 一致：`frameCount = endFrame - startFrame`（`MixCut/Models/Segment.swift:346`），
// 交付时长闸也是按 `(endFrame - startFrame)/fps` 累加（`DubExportService.swift:462-465`）。
// ⇒ 窗口**不能**缩到比分镜还短，否则同一段素材在"画面裁剪"与"时长闸"两处会给出不同长度。
// ============================================================================

/// 一个分镜在某条配音下**实际该占多少帧**。
public struct PictureWindow: Equatable, Sendable {

    /// 窗口与分镜原区间的关系。三态而不是布尔：
    /// `shortByBroll` 是"接不住"的那一档，它决定超字闸该不该花钱之前就把文案拒掉。
    public enum Mode: String, Codable, Equatable, Sendable {
        /// dub 装得进原分镜 ⇒ 窗口就是分镜本身（**最常见**，也是 A 块之前的唯一形态）
        case unchanged
        /// 往前续帧接住了，无差额
        case extended
        /// 续到源片末尾仍差 `shortfallFrames` ⇒ 需要插空镜/相邻素材，否则这条配音装不下
        case shortByBroll
    }

    /// 窗口起点。本轮恒等于分镜 `startFrame`（计划 B 块第 12 条）；
    /// 界面手改起点是 B 块第 14 条，届时由 `SchemeSegment` 存**覆盖值**，不在此处存派生值。
    public let startFrame: Int
    /// 窗口尾帧（开区间口径，同 `Segment.endFrame`）
    public let endFrame: Int
    /// `endFrame - startFrame`
    public let frames: Int
    /// 接住这条配音所需的帧数（已含"不短于原分镜"这一地板）
    public let requiredFrames: Int
    /// `requiredFrames - frames`，0 表示接得住
    public let shortfallFrames: Int
    public let mode: Mode

    /// 窗口秒数。**只用于显示与音频对齐**；帧号才是真相（本仓帧化重构的公理）。
    public func seconds(fps: Double) -> Double { FrameTime.seconds(frame: frames, fps: fps) }
}

public enum PictureWindowPolicy {

    /// 画面**可续到的最远帧** —— 生成侧（超字闸）与导出侧（窗口裁剪）共用这一颗。
    ///
    /// 为什么必须只有一处：两侧口径一分叉，就会出现"生成时放行、导出时装不下"，
    /// 而那时用户看到的是一条已经花过 TTS 费用的配音废掉 —— 比一开始就拒更糟。
    /// （2026-10 那起「档位→宽高」抄 7 份 ⇒ 41 条成片被拒收，就是同一类错的代价。）
    ///
    /// 口径：
    /// - **替换画面**（合成片整段）：只有自己那几帧，往后没有"源片剩余"可续 ⇒ 上界就是它自己。
    ///   拿原视频长度当上界会裁出不存在的帧。
    /// - **原视频**：`video.duration`（容器时长）换算的帧号。它可以**小于**分镜尾帧
    ///   （两次测量的浮点误差），那种脏数据由 `derive` 里"分镜长度是地板"那条兜住，
    ///   不在这里 max —— 在这里 max 会让两处地板写法不一致。
    ///
    /// ⚠️ 第三个上界 `siblingStartFrame`（必填，无默认值）：**同一颗源视频被切成多个分镜时，
    /// 后一分镜的起点**。一条素材不只有一个分镜，这是这个产品的常态（导入即切分），
    /// 所以"往源片后面续帧"真正的天花板往往不是源片末尾，而是**下一格分镜的脸**。
    /// 漏掉这一层会得到什么：seg1 的画面从 [0,100) 接长成 [0,200)，而 seg2 本来就是 [100,200)
    /// ⇒ 同一段画面在成片里连播两遍（用户看到的卡顿），而所有判据当时都是绿的
    /// —— 本仓 2026-11-05 就是这么被一条写错的断言放过去的（BR-4 原版把重叠当"无耦合"钉死了）。
    /// 传 nil 的含义是"该源视频在本段之后没有别的分镜"，由调用方显式表态。
    public static func capacityEndFrame(pictureIsReplaced: Bool,
                                        pictureEndFrame: Int,
                                        sourceDurationSeconds: Double,
                                        fps: Double,
                                        siblingStartFrame: Int?) -> Int {
        let hardCeiling = pictureEndFrame
        guard !pictureIsReplaced else {
            // 替换画面（合成片）自己就是产物，既没有"后续帧"也没有同素材兄弟分镜可言
            return hardCeiling
        }
        guard fps.isFinite, fps > 0, sourceDurationSeconds.isFinite, sourceDurationSeconds > 0 else {
            return hardCeiling
        }
        var cap = FrameTime.frame(seconds: sourceDurationSeconds, fps: fps)
        if let sibling = siblingStartFrame, sibling > pictureEndFrame {
            cap = min(cap, sibling)
        } else if let sibling = siblingStartFrame {
            // 兄弟分镜紧贴在后面（sibling <= 本段尾帧）⇒ 一格可续画面都没有
            return hardCeiling
        }
        return cap
    }

    /// 窗口可触及的**最远帧** = 源片末尾，但不低于画面自己的尾帧。
    ///
    /// 这条地板只写这一次：`capacityFrames` 与 `derive` 都从这里取，
    /// 两处各写一遍 `max` 就是两个真源（本仓为这类事付过账）。
    /// 为什么需要地板：`video.duration` 与画面帧号来自两次测量，浮点误差能让源片"末尾"
    /// 落在画面尾帧之前 —— 那时若直接按源长夹，一条完全正常的分镜会被悄悄缩短几帧。
    private static func allowedEndFrame(sourceEndFrame: Int, pictureEndFrame: Int) -> Int {
        max(sourceEndFrame, pictureEndFrame)
    }

    /// 解析槽位的**窗口起点**：手改覆盖值优先，没有就用分镜自己的起点帧。
    ///
    /// 覆盖值**只许 ≤ 分镜起点**（只能往前挪，不能往后挪），超出的部分在这里就地夹掉。
    /// 理由不是保守，是形状：起点往后挪会让本槽的画面区间盖进下一槽的画面里 ——
    /// 同一段源画面在成片中连续出现两次，看起来就是卡顿；而"重复用同一分镜"这条
    /// 是用户已经拍死不许的做法（计划 B 块第 13 条）。往前挪不会造成这种重叠，
    /// 它只是多带一点前摇，代价是容量变小（可续到源片末尾的余量变少），
    /// 那个代价会由 `derive` 如实报成 `.shortByBroll` 并被导出前拦下 —— 退化是可见的。
    ///
    /// 传进来的是**画面自己的帧空间**：替换画面(合成片)的起点本来就是 0，
    /// 覆盖值对它同样只能 ≤ 0 ⇒ 实际等于不可挪，这是对的 —— 合成片没有"前摇"可取。
    ///
    /// - Returns: 解析后的起点帧 + **被夹前的原值**（nil = 未被夹）。
    ///   为什么不回传"夹掉几帧"：负数那格用差值表达会退化 —— `-20 → 0` 的差是 `-20`，
    ///   取 `max(0, …)` 就成了 0 ⇒ 等于没报告（PW-16 第一次跑就抓出这一点）。
    ///   有了原值，界面与日志都能直说"你填 X、实际用 Y"，而不是默默改用户填的数。
    public static func resolveWindowStart(override: Int?,
                                         segmentStartFrame: Int) -> (startFrame: Int, clampedFrom: Int?) {
        guard let override else { return (segmentStartFrame, nil) }
        let start = max(0, min(override, segmentStartFrame))
        return (start, start == override ? nil : override)
    }

    /// 画面**可续的帧数**：从画面起点算，最多还能取多少帧。
    ///
    /// 这是"容量"的唯一写法，两件事都只从这里出：
    /// - 导出侧由它换算窗口上界；
    /// - 生成侧（`DubbingViewModel` 的超字闸）用它算 `capacitySeconds` 喂闸。
    public static func capacityFrames(pictureStartFrame: Int,
                                      pictureEndFrame: Int,
                                      pictureIsReplaced: Bool,
                                      sourceDurationSeconds: Double,
                                      fps: Double,
                                      siblingStartFrame: Int?) -> Int {
        let cap = capacityEndFrame(pictureIsReplaced: pictureIsReplaced,
                                   pictureEndFrame: pictureEndFrame,
                                   sourceDurationSeconds: sourceDurationSeconds,
                                   fps: fps, siblingStartFrame: siblingStartFrame)
        return max(0, allowedEndFrame(sourceEndFrame: cap, pictureEndFrame: pictureEndFrame)
                      - pictureStartFrame)
    }

    /// 画面**可续长度（秒）**—— 生成侧超字闸的基准。
    ///
    /// 为什么单独有这颗而不是让 VM 自己写 `FrameTime.seconds(frame: capacityFrames(...))`：
    /// 2026-11-05 变异实测 —— 把 VM 里那一行换成 `let capacitySeconds = pictureSeconds`
    /// （即悄悄退回"以分镜时长为准"），钉形状的源码扫描判据**完全没红**：
    /// 两个调用点仍是 `capacitySeconds: capacitySeconds`，只是那颗变量不再是容量。
    /// 算术收进来之后，调用点只剩"调不调这一颗"可错，而那件事是可扫的。
    public static func capacitySeconds(pictureStartFrame: Int,
                                       pictureEndFrame: Int,
                                       pictureIsReplaced: Bool,
                                       sourceDurationSeconds: Double,
                                       fps: Double,
                                       siblingStartFrame: Int?) -> Double {
        guard fps.isFinite, fps > 0 else { return 0 }
        return FrameTime.seconds(frame: capacityFrames(pictureStartFrame: pictureStartFrame,
                                                       pictureEndFrame: pictureEndFrame,
                                                       pictureIsReplaced: pictureIsReplaced,
                                                       sourceDurationSeconds: sourceDurationSeconds,
                                                       fps: fps,
                                                       siblingStartFrame: siblingStartFrame), fps: fps)
    }

    /// 派生窗口。纯函数：**不读库、不探测、不起进程**。
    ///
    /// 规则（逐条对应计划 B 块 11–15）：
    /// - 起点 = 分镜起点（第 12 条：超出分镜尾帧就往源视频后面续）。
    /// - 需求 = `max(分镜原帧数, dub 帧数)` ⇒ **配音短了也不把画面缩短**：
    ///   分镜长度仍然是地板。缩短会让同一素材在裁剪与时长闸两处口径分叉，
    ///   也会把 A 块的 `trailingSilence`（用静音铺满画面）变成"铺空气"。
    /// - 上界 = `max(sourceEndFrame, 分镜尾帧)`。为什么后头还要跟分镜尾比一次：
    ///   `video.duration` 与分镜帧区间来自两次测量（ffprobe 容器时长 vs 导入时算的帧号），
    ///   浮点误差能让源片"末尾"恰好落在分镜尾帧之前。若直接按源长夹，
    ///   就会把一条完全正常的分镜**缩短** —— 而且缩得只有几帧，屏上根本看不出来。
    /// - 差额 `> 0` ⇒ `.shortByBroll`，交超字闸在**花钱合成之前**把这条文案拒掉（B 块 13 的现行解）。
    ///
    /// - Returns: `nil` = 输入不成立（帧率非正/非有限、帧区间倒挂、dub 时长非有限）。
    ///   **不许**退化成"零长窗口"或"原分镜"：那是把"我算不出来"伪装成一条正常结论，
    ///   下游会照它裁出一段 0 帧画面。调用方拿到 nil 应当作"不扩窗"处理并上报。
    public static func derive(startFrame: Int,
                              endFrame: Int,
                              sourceEndFrame: Int,
                              dubSeconds: Double,
                              fps: Double) -> PictureWindow? {
        guard fps.isFinite, fps > 0 else { return nil }
        guard startFrame >= 0, endFrame > startFrame else { return nil }
        guard dubSeconds.isFinite, dubSeconds >= 0 else { return nil }

        let original = endFrame - startFrame
        let dubFrames = FrameTime.frame(seconds: dubSeconds, fps: fps)
        let required = max(original, dubFrames)

        // 上界 = 源片末尾；但**永不低于分镜自己的尾帧**（上面写的"分镜是地板"）。
        // ⚠️ 别把 `startFrame + required` 也塞进这里的 max —— 那样窗口永远等于需求、
        //    源片末尾那道夹住会变成永不生效的死代码（本函数第一版就错在这）。
        let allowedEnd = allowedEndFrame(sourceEndFrame: sourceEndFrame, pictureEndFrame: endFrame)
        let windowEnd = min(startFrame + required, allowedEnd)
        let frames = windowEnd - startFrame
        let shortfall = max(0, required - frames)

        let mode: PictureWindow.Mode
        if shortfall > 0 {
            mode = .shortByBroll
        } else if windowEnd > endFrame {
            mode = .extended
        } else {
            mode = .unchanged
        }
        return PictureWindow(startFrame: startFrame, endFrame: windowEnd, frames: frames,
                             requiredFrames: required, shortfallFrames: shortfall, mode: mode)
    }

    /// 差额是否**仍可交付**。
    ///
    /// 为什么要这一颗而不是"有差额就拒"：A 块的实测超字闸本来就容许 `measuredToleranceSeconds`
    /// （0.05s）的溢出，今天这类素材是能正常出片的。若导出改成"差额 > 0 即拒"，
    /// 就会把**今天能导的片子**当场变红 —— 那是回归，不是收紧。
    /// 所以导出侧的口径与生成侧对齐：容差折算成帧，落在容差内的差额按"画面就此收尾"处理。
    ///
    /// 容差是**入参**且无默认值：数字的唯一真源是 `DubLengthGate.measuredToleranceSeconds`，
    /// 在这里再写一个"看起来合理"的 0.05 就是第二份真源，两处一改就分叉。
    public static func isDeliverable(_ w: PictureWindow, fps: Double,
                                     toleranceSeconds: Double) -> Bool {
        guard w.shortfallFrames > 0 else { return true }
        guard fps.isFinite, fps > 0, toleranceSeconds.isFinite, toleranceSeconds >= 0 else { return false }
        let toleranceFrames = FrameTime.frame(seconds: toleranceSeconds, fps: fps)
        return w.shortfallFrames <= toleranceFrames
    }

    /// 差额文案的**唯一**格式化口径：卡片预警与导出失败清单必须同源。
    ///
    /// 两处各写一套 `String(format:)`，迟早一边写"差 2.0s"、另一边写"差 2.00s"，
    /// 用户会当成两个不同的问题。差额**帧**进、秒出，取整只住这一处。
    public static func shortfallText(shortfallFrames: Int, fps: Double) -> String {
        String(format: "配音差 %.2fs", FrameTime.seconds(frame: shortfallFrames, fps: fps))
    }

    /// 派生失败时的**保守回退**：窗口 == 画面自己的帧区间，即"不扩窗"。
    ///
    /// 为什么要有这颗而不是让调用方各写一份 `?? 原区间`：算不出来时"照原分镜导"与
    /// "顺手把画面缩短"是两种完全不同的选择，写散到各调用点必有一天选错。
    /// ⚠️ 它会把 `shortfallFrames` 报成 0（看着像"接得住"），所以调用方拿到 `derive` 的
    /// nil 时**必须同时上报**，不许静默换成这颗。
    public static func fallback(startFrame: Int, endFrame: Int) -> PictureWindow {
        let frames = max(0, endFrame - startFrame)
        return PictureWindow(startFrame: startFrame, endFrame: startFrame + frames,
                             frames: frames, requiredFrames: frames,
                             shortfallFrames: 0, mode: .unchanged)
    }
}
