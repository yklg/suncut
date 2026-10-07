import Foundation

/// `dubOnly` 声音策略的导出组合判据（纯逻辑，可单测）。
///
/// 与 `keepOriginal` 的笛卡尔积组合（每槽「原声 + 各配音版」）不同，
/// 产品脚本成片方案在物化时已经为每个槽位唯一绑定了新配音（`selectedSegmentDubId`）：
/// 既不允许原声回退（`AudioTrackPolicy.allowsOriginalFallback == false`），
/// 也不存在多版本组合——导出组合恒为一条，每槽唯选绑定的配音。
/// 任一槽位缺绑定/缺音频即整条不可导，由 App 层按槽位结构化报错，绝不补原声。
public enum DubOnlyExportPolicy {

    /// 计算 dubOnly 方案的唯一组合选择。
    /// - Parameter orderedSelectedDubIDs: 与方案槽位对齐的已绑定配音 id（nil = 该槽未绑定）
    /// - Returns: 全部槽位都有绑定时，返回唯一组合（原样对齐）；任一缺失 ⇒ nil（不可导）。
    public static func singleComboChoices(orderedSelectedDubIDs: [UUID?]) -> [UUID?]? {
        guard !orderedSelectedDubIDs.isEmpty,
              orderedSelectedDubIDs.allSatisfy({ $0 != nil }) else { return nil }
        return orderedSelectedDubIDs
    }

    /// 未绑定配音的槽位序号（position 从 1 起，供错误提示直接定位「第 N 段」）。
    public static func unboundPositions(_ orderedSelectedDubIDs: [UUID?]) -> [Int] {
        orderedSelectedDubIDs.enumerated().compactMap { offset, id in
            id == nil ? offset + 1 : nil
        }
    }
}
