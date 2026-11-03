import Foundation

// ============================================================================
// 「一条覆盖整片的机器段」形状判据（纯值 + 纯函数）。
//
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md
//          Step 2 的 P0-1 块（〔已闭合 2026-10-20，R14〕）与 R18/R21
//
// 它只回答一个问题，而这个问题今天是**承重判定**：
//   母体链首跑（`analyzeVideo`）该不该先删掉已有分镜？
// 旧写法把入参写死成 `clearsExistingSegments: false`，而 `false` 安全的前提是
// 「首跑此刻没有旧分镜可退」—— 这条前置**从没被写下来**。文件夹混剪第一次让它不成立：
// C 的载体停在 `.imported`（所以 `:418` 判定为"需要分析"）却已经带着一条整片段，
// 传 `false` 就变成"旧整片段不删 + 新切分段追加"⇒ 一条素材同时挂着两种分镜（计划 R14 实读结论）。
//
// 判据形态复用仓内既有先例 `MixCut/App/MixCutApp.swift:295-304` 的 `byShape`
// （自建分镜标记自愈），那里用的容差就是 `start < 0.01` 与 `|end − duration| < 0.2`。
// **不**照抄 `byShape` 的全部条件：它还带 `asrSentencesData == nil` 与缩略图同源两颗，
// 那两颗服务的是"识别受损的自建载体"，与本判定无关；把它们混进来等于让一个判据管两件事。
//
// 接口锁定（WholeClipShapeTests 依赖这些形状）：
//   public struct WholeClipSegmentShape { startTime: Double, endTime: Double }
//   public enum WholeClipShape {
//       static let startTolerance: Double        // = 0.01
//       static let endTolerance: Double          // = 0.2
//       static func isWholeClip(segments:videoDuration:) -> Bool
//   }
//
// 规则：
//   W1 段数必须恰好 1：0 段（真·首跑）不必清；≥2 段是"已经有一份切分"，那是重跑链
//      （`:362-367` 显式传 `true`）的管辖范围，首跑不许替它决定去留。
//   W2 起点贴零（`0 ≤ start < startTolerance`）；W3 终点贴满全片（差 < `endTolerance`）。
//      ⚠ 这里比先例 `byShape` **多一个下界** `start ≥ 0`：先例写的是 `start < 0.01`，
//      负起点也会被它认成整片段（那是"标记自愈"，宁可多恢复一颗）；而本判定的动作是
//      **删旧段**，把一个边界被手工拖到 0 之前的段当成机器整片段删掉，就不是自愈而是毁数据。
//      两个判据动作不同、下界不同，是刻意的，不是抄漏。
//   W4 时长或边界读不出来 ⇒ 判"不是整片段"（保守：不清旧段）。
//      ⚠ 这条**不靠额外的 isFinite 预检**，而且这件事是变异腿实测出来的：
//      原实现里那两道 `.isFinite` 预检删掉之后，W4 的 7 条断言一条都不红 ——
//      因为拒收本来就是这么发生的：
//        · NaN 与任何数比较都是 false ⇒ `videoDuration > 0` 当场拦下；
//        · ±infinity 走得远一点，但 `|end − ∞| < 0.2` 不可能成立（两端同为 ∞ 时相减得 NaN，同样 false）；
//        · 段边界 NaN 过不了 `start ≥ 0` 或终点比较，段边界 ∞ 过不了终点比较。
//      留着预检就是"看起来有防御、其实没有一条判据能证明它在起作用"的哑弹，所以删掉；
//      留下的 `videoDuration > 0` 的价值是**标出前置**（终点比较将来若被改写，它仍拦 NaN），
//      不是"多一道保险"。别为它再补一句"isFinite 已覆盖"这种没人验过的话。
//   W5 只认形状，不认来源：这条判据**分不开** C 与 B（自建分镜也是"一条覆盖整片的段"），
//      也分不开 C 与"母体链跑过整片保留规则"的视频。三者在该判据下同侧时的行为是
//      "清掉旧整片段、按母体链重新切分"，对这三种载体都是正确处置（C 无台词、B 的台词
//      来自它自己的文件而母体链会重听、整片保留本就是同一形状）—— 这是 ④ 方案公开接受的
//      代价，不是被掩盖的缺陷（计划 R18 的代价表第②格）。
//
// 非空洞性论证（实现写错时哪条测试红）：
//   - 段数判成 `<= 1`（空段也判真）    → W1a 红：真·首跑会白删一次
//   - 起点写成 `== 0`                 → W2b 红：0.005 这种浮点残差判假
//   - 起点下界被删掉                   → W2 的负起点对照红（先例没有下界，本判定必须有）
//   - 终点用 `>= duration`            → W3b 红：短 0.1 秒的整片段判假 ⇒ 混存回来了
//   - W4 这一族**没有配套的单独变异刀**，是实测后的决定而不是漏网：删掉 `isFinite` 预检、
//     甚至删掉 `videoDuration > 0`，NaN/∞ 的读数都不变（拒收发生在比较链上）。
//     W4 的 7 条断言因此是"契约钉"而不是"实现钉"：它们钉的是**下一次改写比较链时不许翻绿**。
//     能被刀区分的是终点比较（X5/X6）与段数判定（X2）、起点两侧（X3/X4）。
//   - 容差被顺手改成 0（严格相等）    → W2b/W3a 红
// ============================================================================

/// 一条分镜的形状投影（只有边界两个数 —— 判定不需要更多，多给就会多想）。
public struct WholeClipSegmentShape: Equatable, Sendable {
    public let startTime: Double
    public let endTime: Double

    public init(startTime: Double, endTime: Double) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

public enum WholeClipShape {
    /// 起点容差。出处：`MixCutApp.swift:300` 的 `seg.startTime < 0.01`。
    public static let startTolerance: Double = 0.01
    /// 终点容差。出处：`MixCutApp.swift:301` 的 `abs(seg.endTime - video.duration) < 0.2`。
    /// 0.2 秒不是拍的：帧边界由 `Segment.setFrameRange` 反推回秒时会带一帧的量化误差
    /// （30fps 下一帧 ≈ 0.033s），而 `commitWholeVideo` 用的 endFrame 是 `rounded()` 的整数帧。
    public static let endTolerance: Double = 0.2

    /// 是否"恰好一条覆盖整片的段"。`true` ⇒ 母体链首跑必须先清掉它再重建（否则混存）。
    public static func isWholeClip(segments: [WholeClipSegmentShape],
                                   videoDuration: Double) -> Bool {
        guard segments.count == 1 else { return false }                       // W1
        guard videoDuration > 0 else { return false }                          // W4
        let seg = segments[0]
        return seg.startTime >= 0                                                  // W2b
            && seg.startTime < startTolerance                                      // W2
            && abs(seg.endTime - videoDuration) < endTolerance                     // W3
    }
}
