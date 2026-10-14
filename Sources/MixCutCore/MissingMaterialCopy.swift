import Foundation

/// 「源文件不在了」这句话的**唯一真源**。
///
/// 为什么要单独抽出来：这句话今天散在三处（导出汇总、批量导出弹窗、ffmpeg 失败分类），
/// 三套措辞说的是同一件事，用户却要从三种说法里自己认出"哦，是同一个问题"。
/// **统一的是措辞，不是呈现通道** —— 各通道该用 Toast、错误态还是汇总行仍由各自决定，
/// 这里只提供句子本身（把 `DubbingViewModel.errorState` 强改成 Toast 那种越界不在本文件范围）。
public enum MissingMaterialCopy {

    /// 卡片/列表上的短标签（不带文件名，位置窄）。
    public static let shortLabel = "源文件已不存在"

    /// 带恢复路径的完整句：说清"可能发生了什么"与"用户能做什么"，不止报丧。
    /// - Parameter fileName: 只报文件名，不报整条路径 —— 完整路径由视图自己另起一行给，
    ///   混进这句话里会让它在窄栏被截断，而路径正是用户找回文件唯一需要的东西。
    public static func fullMessage(fileName: String) -> String {
        "\(shortLabel)：\(fileName) 可能已被删除或移动。放回原处后点「重新检查」即可恢复。"
    }

    /// 批量汇总里的那一句（导出/批量导出用）：条数在前、动作在后。
    /// 用它而不是各页自己拼，是因为"跳过几条"与"为什么跳"必须同一种说法，
    /// 而**通道语义不动** —— 导出仍然是"跳过并如实报 N 条"，不会被统一成弹窗或 Toast。
    public static func batchSkipped(count: Int) -> String {
        "\(count) 个\(shortLabel)被跳过"
    }

    /// ffmpeg 失败分类用的那一句。**结论与界面侧不同**（这里要的是"重新导入"，不是"放回原处"），
    /// 所以单列一档；短标签仍取自同一真源 ⇒ 既挡住"同一件事两种叫法"，也挡住
    /// "把两种不同结论强行说成一种"（方案批 5 明令只统一措辞骨架）。
    public static let needsReimport = "\(shortLabel)，请重新导入该素材。"
}
