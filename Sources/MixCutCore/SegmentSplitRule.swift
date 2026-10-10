import Foundation

/// 分镜**拆分**的合法性规则（纯函数，可单测）。
///
/// 为什么必须住在 Core：这条规则原来只写在 `SplitSegmentSheet` 的私有变量里，
/// 而 MCP 的 `split_segment` 要判同一件事。判据写在某个视图内部 ⇒ 第二条腿只能复制一份，
/// 复制那天起两条腿对"这个点能不能拆"的答案就可以不一样（一个是 UI 拦、一个是静默切出 0 帧段）。
public enum SegmentSplitRule {

    /// 拆开后每一段至少留这么多秒 —— 再短就没有"画面"可言了。
    public static let minimumSliceSeconds: Double = 0.3

    /// 每段最少帧数。`max(1, …)` 不是保险丝：低帧率下 0.3s 会取整成 0 帧，
    /// 那等于允许切出一个零宽度的分镜。
    public static func minFrames(fps: Double) -> Int {
        max(1, Int((minimumSliceSeconds * fps).rounded()))
    }

    /// 合法拆分点区间；`nil` = 这段太短，根本没有合法拆分点。
    ///
    /// 与旧 UI 写法逐字等价（`hi <= lo` 视为无解），改这里等于同时改两条腿。
    public static func legalCutRange(startFrame: Int, endFrame: Int,
                                     fps: Double) -> ClosedRange<Int>? {
        let need = minFrames(fps: fps)
        let lo = startFrame + need
        let hi = max(startFrame + need, endFrame - need)
        return hi > lo ? lo...hi : nil
    }

    /// 这个帧号能不能作为拆分点。
    public static func isLegalCut(_ cutFrame: Int, startFrame: Int, endFrame: Int,
                                  fps: Double) -> Bool {
        legalCutRange(startFrame: startFrame, endFrame: endFrame, fps: fps)?.contains(cutFrame) ?? false
    }

    /// 给人看的失败原因：把合法区间报出来，调用方（尤其是 Agent）才能自己改正后重试，
    /// 而不是收到一句"无法拆分"再猜。
    public static func refusal(startFrame: Int, endFrame: Int, fps: Double) -> String {
        if let range = legalCutRange(startFrame: startFrame, endFrame: endFrame, fps: fps) {
            return "拆分点必须落在 \(range.lowerBound)~\(range.upperBound) 帧之间"
                + "（拆开后每段不少于 \(String(format: "%.1f", minimumSliceSeconds)) 秒）"
        }
        let seconds = Double(endFrame - startFrame) / max(fps, 1)
        return String(format: "这段只有 %.2fs，拆开后每段不足 %.1f 秒，没有合法拆分点",
                      seconds, minimumSliceSeconds)
    }
}
