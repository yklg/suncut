import Foundation

// ============================================================================
// 段级克隆参考窗口（M2）
//
// ## 为什么需要这个文件
//
// 旧实现按**整段视频**克隆：参考音恒取人声轨开头 6 秒
// （`VocalSeparationService.referenceClip` 的 ffmpeg 参数无 `-ss`）。
// ⇒ 同一视频里**跨说话人**的分镜拿到同一个音色。
// 实测（`~/Library/Application Support/Suncut/Stems/`，自相关估基频）：
// 某 58.8 秒视频 0~18 秒是男声（125~156 Hz）、21 秒后是女声（200~256 Hz），
// 而旧实现恒取前 6 秒 ⇒ 选女声段却克隆出男声。
//
// 仓库里早有反证：手动复刻链路刻意取中段、注释明写「避开开头/结尾的静音与寒暄」
// （`CloneRegistrationService.trimDuration`），但自动克隆链路取的是开头。
//
// ## 两条不可协商的规则
//
// 1. **只向后取**：`[startFrame, startFrame + maxSeconds]`。
//    **绝不向前扩展** —— 向前必然侵入前一分镜，而那正是本缺陷的病根。
//    「宁可样本短，也不能跨界」：跨界等于换一种更隐蔽的失败模式。
// 2. **纯函数、无 IO、无 SwiftData**：可完整单测，且不污染 Core 的「无 App 依赖」边界。
// ============================================================================

/// 克隆参考音的时间窗口（帧为唯一真相；秒只是派生展示）。
public struct CloneReferenceWindow: Equatable, Sendable {
    public let startFrame: Int
    public let endFrame: Int

    public init(startFrame: Int, endFrame: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    public var frameCount: Int { max(0, endFrame - startFrame) }

    public func seconds(fps: Double) -> Double {
        fps > 0 ? Double(frameCount) / fps : 0
    }
}

/// 窗口规划 + 复用判据（唯一真源）。
public enum WindowPlanner {

    /// 参考音最长秒数。
    ///
    /// ## 为什么是 6秒（实测依据，不是拍脑袋）
    ///
    /// `DubbingViewModel.ensureClonedVoice` 的注释记录了实测：
    /// 18 秒长参考含多句原话，qwen 克隆 TTS 会间歇性「续读参考里的内容」
    /// 把下一段的词混进配音（18s → clean 1/3；6s → clean 5/5）。
    ///
    /// ⚠️ 更长还会增加「参考里含男声、克隆出男声」的概率（本缺陷的机制）。
    public static let maxReferenceSeconds: Double = 6

    /// 复用判据的重叠阈值比例。
    ///
    /// 候选窗口与已有窗口重叠 ≥ `min(两者时长) × 本值` ⇒ 判为同一说话人。
    /// 0.5 = 「重叠超过任一方的一半」⇒ 中段说话人切换（各占一半）不会被误判为同一人。
    public static let reuseOverlapRatio: Double = 0.5

    /// 为一个分镜规划参考音窗口。
    ///
    /// - Parameters:
    ///   - startFrame: 分镜起始帧。**窗口永不早于它**（规则 1）。
    ///   - fps: 用于把 `maxReferenceSeconds` 换算成帧。
    ///   - videoFrameCount: 视频总帧数，用于夹住末尾（不知道会算出越界的 endFrame）。
    ///   - hasVoice: 该分镜时间范围内**是否检出语音**。false ⇒ 返回 nil
    ///     （纯 BGM/静音不该送去克隆，否则服务端会静默兜底成默认音色）。
    /// - Returns: nil = 不可克隆（零长分镜 / 无语音 / 帧率非法）。
    public static func planWindow(startFrame: Int,
                                  fps: Double,
                                  videoFrameCount: Int,
                                  hasVoice: Bool = true) -> CloneReferenceWindow? {
        guard hasVoice, fps > 0, startFrame < videoFrameCount else { return nil }
        let span = Int((maxReferenceSeconds * fps).rounded())
        guard span > 0 else { return nil }
        // 只向后取，且夹在视频末尾内。
        let end = min(startFrame + span, videoFrameCount)
        guard end > startFrame else { return nil }
        return CloneReferenceWindow(startFrame: startFrame, endFrame: end)
    }

    /// 两个窗口的重叠比例（相对于**较短**的那个）。
    ///
    /// - Returns: 0~1。不重叠返回 0；零长窗口返回 0。
    public static func overlapRatio(_ a: CloneReferenceWindow,
                                    _ b: CloneReferenceWindow) -> Double {
        let overlap = min(a.endFrame, b.endFrame) - max(a.startFrame, b.startFrame)
        guard overlap > 0 else { return 0 }
        let shorter = min(a.frameCount, b.frameCount)
        guard shorter > 0 else { return 0 }
        return Double(overlap) / Double(shorter)
    }

    /// 候选窗口能否复用某个已注册窗口的音色。
    ///
    /// - Parameters:
    ///   - candidate: 待判定的新窗口。
    ///   - existing: 该视频已注册音色的窗口列表（段级 `cloneWindowStartFrame/EndFrame`）。
    /// - Returns: 命中的可复用窗口；无可复用返回 nil（调用方需注册新音色）。
    ///
    /// ## 为什么用「时间重叠」而不是「基频聚类」
    ///
    /// 时间重叠是**免费**的：分镜边界本来就是说话人切换的近似，且判定是纯整数帧运算、
    /// 可完整单测。基频聚类更准，但需要新增 DSP（本仓目前零基频分析代码）+ 分析结果落库。
    ///
    /// ⚠️ **已知代价**：同一个人连续说话被切成两段短分镜时，两窗口不重叠 ⇒ 漏复用
    /// （多注册一次 = 多花一点钱）。这个代价是**可控且显式**的，
    /// 而基频方案要引入的复杂度与维护成本是**持续**的。
    public static func reusableWindow(candidate: CloneReferenceWindow,
                                      among existing: [CloneReferenceWindow]) -> CloneReferenceWindow? {
        for w in existing where overlapRatio(candidate, w) >= reuseOverlapRatio {
            return w
        }
        return nil
    }

    /// 帧 ↔ 秒互转（复用本仓既有口径，避免两处各算一遍）。
    ///
    /// ⚠️ 与 `FrameTime.seconds` 同口径：`max(0, frame) / fps`。
    public static func seconds(frame: Int, fps: Double) -> Double {
        fps > 0 ? Double(max(0, frame)) / fps : 0
    }
}
