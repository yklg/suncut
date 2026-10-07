import Foundation

// ============================================================================
// 方案焦点定位（纯逻辑）—— 物化完成后自动跳转到「混剪方案」并选中新方案。
//
// 为什么下沉 Core：导航通知可能携带陈旧/跨项目的 schemeID（物化后用户快速切项目、
// 方案已被删除等）。「在当前项目的方案树里能不能定位到、定位到哪个容器第几行」
// 必须是可单测的纯判定，VM 只负责调用结果、绝不自己写查找（P1-2）。
// ============================================================================

public enum SchemeFocus {

    /// 一棵方案容器树（AI 策略 / 自定义组合 / 脚本成片 / 叙事结构）的纯值投影。
    public struct Tree: Equatable, Sendable {
        public let strategyID: UUID
        /// 树内方案按展示顺序排列的 id（顺序 = variationIndex 升序）。
        public let orderedSchemeIDs: [UUID]

        public init(strategyID: UUID, orderedSchemeIDs: [UUID]) {
            self.strategyID = strategyID
            self.orderedSchemeIDs = orderedSchemeIDs
        }
    }

    /// 定位结果：方案所在容器 + 它在容器内的行号（0 起，供选中/滚动）。
    public struct Location: Equatable, Sendable {
        public let strategyID: UUID
        public let schemeIndex: Int
        public init(strategyID: UUID, schemeIndex: Int) {
            self.strategyID = strategyID; self.schemeIndex = schemeIndex
        }
    }

    /// 在当前项目的方案树集合中定位某个方案。
    /// - 找不到（跨项目陈旧事件、已删除、空树）一律返回 nil——调用方必须静默保留原选中态。
    public static func locate(_ schemeID: UUID, in trees: [Tree]) -> Location? {
        for tree in trees {
            if let idx = tree.orderedSchemeIDs.firstIndex(of: schemeID) {
                return Location(strategyID: tree.strategyID, schemeIndex: idx)
            }
        }
        return nil
    }
}
