import Foundation

// ============================================================================
// 方案选中策略（纯逻辑）—— 数据重载后「该选中谁」的唯一裁决口。
//
// 为什么下沉 Core：物化跳转事故的根因是「刷新快照数据」与「重置选中」绑死在
// SchemeViewModel.loadSchemes 里，且一次性焦点令牌会被跨 tab 导航时的第一次
// 重载（ContentView 收到通知立即触发）消费掉，随后 SchemeListView.onAppear 的
// 第二次重载走硬编码默认（strategies.createdAt 最早 = 随项目出生的空「自定义组合」），
// 把新方案选中覆盖成空白页。选中策略必须脱离 SwiftUI appear/通知时序、可单测。
//
// 优先级（见 resolve）：
//   1. 焦点令牌在新树中命中 → 选中它（物化后跳转的新方案，最高优先级）；
//   2. 同项目重载且当前选中方案仍在新树中 → 保持（任意次数 onAppear/数据重载幂等，不抢选中）；
//   3. 默认 → 按展示顺序选第一棵「非空」容器的第一个方案（空容器一律跳过）；
//   4. 全空 → 清空选中。
// 焦点令牌在树中找不到（跨项目陈旧事件 / 方案已删）→ 静默丢弃，继续走 2/3/4。
// ============================================================================

public enum SchemeSelection {

    /// 重载后的选中裁决。
    public enum Decision: Equatable, Sendable {
        /// 选中指定容器内的指定方案（VM 负责按 id 从新加载的图中取模型对象，不握旧快照引用）。
        case select(strategyID: UUID, schemeID: UUID)
        /// 保持重载前的选中（仅在同项目且方案仍存在时由策略给出）。
        case keep
        /// 清空选中（无任何可选方案）。
        case clear
    }

    /// 重载前选中态的纯值投影（避免 Core 依赖 SwiftData 模型）。
    public struct Current: Equatable, Sendable {
        public let strategyID: UUID?
        public let schemeID: UUID?

        public init(strategyID: UUID?, schemeID: UUID?) {
            self.strategyID = strategyID
            self.schemeID = schemeID
        }
    }

    /// 裁决「本次数据重载后应选谁」。纯函数：相同输入必相同输出，无副作用。
    ///
    /// - Parameters:
    ///   - pendingFocus: 物化后待聚焦的方案 id。非 nil 即为一次性意图——调用方在调用后
    ///     必须无条件清空令牌（命中走 select；陈旧则在此静默丢弃，落连续性/默认裁决）。
    ///   - current: 重载前的选中态投影。
    ///   - trees: 新数据按 **UI 展示顺序** 构造的容器树（VM 用
    ///     orderedStrategiesForDisplay + narrativeTemplates 构造；空容器保留、由策略跳过）。
    ///   - isSameProject: 本次重载是否与上次同一项目（VM 用 lastLoadedProjectID 判定）。
    ///     切项目/首载为 false——绝不跨项目保留选中。
    public static func resolve(
        pendingFocus: UUID?,
        current: Current,
        trees: [SchemeFocus.Tree],
        isSameProject: Bool
    ) -> Decision {
        // 1) 焦点优先：物化跳转意图压过一切既有选中。
        if let focusID = pendingFocus,
           let location = SchemeFocus.locate(focusID, in: trees) {
            return .select(strategyID: location.strategyID, schemeID: focusID)
        }
        // 焦点为 nil 或在新树中定位失败（陈旧/已删/跨项目）：令牌由调用方清空，向下继续。

        // 2) 同项目连续性：当前方案仍在新树中就保持——同项目的重复 loadSchemes
        //    （onAppear、undo 全量重载、立即消费分支）因此幂等，不再把选中夺回默认。
        if isSameProject,
           let currentSchemeID = current.schemeID,
           SchemeFocus.locate(currentSchemeID, in: trees) != nil {
            return .keep
        }

        // 3) 默认：展示序第一棵非空容器的首个方案。
        //    绝不能按 createdAt 取首个策略——空「自定义组合」随项目创建、createdAt 最早，
        //    选它必然得到 selectedScheme = nil 的空白页。
        for tree in trees where !tree.orderedSchemeIDs.isEmpty {
            return .select(strategyID: tree.strategyID, schemeID: tree.orderedSchemeIDs[0])
        }

        // 4) 所有容器皆空（或无容器）：合法空态。
        return .clear
    }
}
