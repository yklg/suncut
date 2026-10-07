import Foundation
import Testing
@testable import MixCutCore

/// SchemeSelection 选中策略纯逻辑测试（SS-1 ~ SS-10）。
///
/// 复现的事故：逆向文案物化后跨 tab 跳转，第一次 loadSchemes 消费掉焦点令牌选中新方案，
/// SchemeListView.onAppear 的第二次 loadSchemes 走硬编码默认，选到随项目出生的空
/// 「自定义组合」容器 → 右栏空白，用户以为物化失败。
struct SchemeSelectionTests {

    // 容器：AI 策略组（有方案）/ 产品脚本成片组（物化落点）/ 自定义组合（空，随项目出生）
    private let aiGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let scriptGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let customGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private let narrativeGroup = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!

    private let aiScheme1 = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let aiScheme2 = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let newScriptScheme = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private let oldScriptScheme = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    private let narrativeScheme = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    private let deletedScheme = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
    private let staleFocus = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!

    /// 事故现场的标准树（展示序：AI → 脚本成片 → 自定义组合[空]）。
    private var accidentTrees: [SchemeFocus.Tree] {
        [
            .init(strategyID: aiGroup, orderedSchemeIDs: [aiScheme1, aiScheme2]),
            .init(strategyID: scriptGroup,
                  orderedSchemeIDs: [oldScriptScheme, newScriptScheme]),
            .init(strategyID: customGroup, orderedSchemeIDs: []),
        ]
    }

    @Test func SS1_focusHits_overridesValidCurrentSelection() {
        // 即使当前选中有效（AI 方案），焦点命中也必须压过它——物化后落点是新脚本方案。
        let decision = SchemeSelection.resolve(
            pendingFocus: newScriptScheme,
            current: .init(strategyID: aiGroup, schemeID: aiScheme1),
            trees: accidentTrees,
            isSameProject: true)
        #expect(decision == .select(strategyID: scriptGroup, schemeID: newScriptScheme))
    }

    @Test func SS2_focusHits_nonFirstTree_returnsCorrectContainerAndScheme() {
        // 焦点落在第三组之类的靠后容器也要精确定位（locate 复用，防只在第一棵树找）。
        let trees = accidentTrees + [.init(strategyID: narrativeGroup,
                                           orderedSchemeIDs: [narrativeScheme])]
        let decision = SchemeSelection.resolve(
            pendingFocus: narrativeScheme,
            current: .init(strategyID: nil, schemeID: nil),
            trees: trees,
            isSameProject: true)
        #expect(decision == .select(strategyID: narrativeGroup, schemeID: narrativeScheme))
    }

    @Test func SS3_staleFocusSameProject_fallsBackToKeep() {
        // 焦点陈旧（跨项目事件/已删）但同项目重载、现选中仍在 → 保持，不跳到默认。
        let decision = SchemeSelection.resolve(
            pendingFocus: staleFocus,
            current: .init(strategyID: aiGroup, schemeID: aiScheme2),
            trees: accidentTrees,
            isSameProject: true)
        #expect(decision == .keep)
    }

    @Test func SS4_staleFocusCrossProject_fallsBackToDefaultNotKeep() {
        // 陈旧焦点 + 跨项目重载：即使旧选中 id 恰好还在新树（极小概率）也不许 keep——
        // 此用例旧选中不在新树，落默认；与 SS7 共同钉死切项目铁律。
        let decision = SchemeSelection.resolve(
            pendingFocus: staleFocus,
            current: .init(strategyID: customGroup, schemeID: deletedScheme),
            trees: accidentTrees,
            isSameProject: false)
        #expect(decision == .select(strategyID: aiGroup, schemeID: aiScheme1))
    }

    @Test func SS5_sameProjectRepeatedLoad_keepsSelection() {
        // 事故核心：onAppear 的第二次（第 N 次）同项目重载必须幂等保持，
        // 不能再把已聚焦的新方案夺成默认。
        let first = SchemeSelection.resolve(
            pendingFocus: newScriptScheme,
            current: .init(strategyID: nil, schemeID: nil),
            trees: accidentTrees, isSameProject: true)
        #expect(first == .select(strategyID: scriptGroup, schemeID: newScriptScheme))

        // 令牌已被调用方清空；第二次重载只带当前选中。
        let second = SchemeSelection.resolve(
            pendingFocus: nil,
            current: .init(strategyID: scriptGroup, schemeID: newScriptScheme),
            trees: accidentTrees,
            isSameProject: true)
        #expect(second == .keep)
    }

    @Test func SS6_sameProjectButCurrentSchemeDeleted_fallsBackToDefault() {
        let decision = SchemeSelection.resolve(
            pendingFocus: nil,
            current: .init(strategyID: scriptGroup, schemeID: deletedScheme),
            trees: accidentTrees,
            isSameProject: true)
        #expect(decision == .select(strategyID: aiGroup, schemeID: aiScheme1))
    }

    @Test func SS7_crossProjectOrFirstLoad_ignoresCurrentAndSelectsDefault() {
        // 首载（current 全 nil、isSameProject=false）与切项目走同一裁决。
        let emptyCurrent = SchemeSelection.Current(strategyID: nil, schemeID: nil)
        let firstLoad = SchemeSelection.resolve(
            pendingFocus: nil, current: emptyCurrent,
            trees: accidentTrees, isSameProject: false)
        #expect(firstLoad == .select(strategyID: aiGroup, schemeID: aiScheme1))

        // 切项目：上一个项目的选中必须被无视。
        let switched = SchemeSelection.resolve(
            pendingFocus: nil,
            current: .init(strategyID: scriptGroup, schemeID: newScriptScheme),
            trees: accidentTrees,
            isSameProject: false)
        #expect(switched == .select(strategyID: aiGroup, schemeID: aiScheme1))
    }

    @Test func SS8_allTreesEmpty_clearsSelection() {
        let trees = [
            SchemeFocus.Tree(strategyID: customGroup, orderedSchemeIDs: []),
            SchemeFocus.Tree(strategyID: scriptGroup, orderedSchemeIDs: []),
        ]
        let decision = SchemeSelection.resolve(
            pendingFocus: nil,
            current: .init(strategyID: customGroup, schemeID: nil),
            trees: trees,
            isSameProject: false)
        #expect(decision == .clear)
    }

    @Test func SS9_emptyStrategySelectedWithoutScheme_skipsToFirstNonEmpty() {
        // 旧实现的病灶：strategies.first 是随项目出生的空自定义组，selectedScheme=nil。
        // 同项目重载时只有空组「选中态」（schemeID=nil）→ 不许 keep，跳到第一非空组。
        let decision = SchemeSelection.resolve(
            pendingFocus: nil,
            current: .init(strategyID: customGroup, schemeID: nil),
            trees: accidentTrees,
            isSameProject: true)
        #expect(decision == .select(strategyID: aiGroup, schemeID: aiScheme1))
    }

    @Test func SS10_defaultSkipsLeadingEmptyContainers_inDisplayOrder() {
        // 直接回归图一：展示序第一棵是空 AI 区（尚未生成）、第二棵才是脚本成片组时，
        // 默认必须跳过空容器落到新物化方案，而不是清空或选空组。
        let trees: [SchemeFocus.Tree] = [
            .init(strategyID: aiGroup, orderedSchemeIDs: []),
            .init(strategyID: scriptGroup, orderedSchemeIDs: [newScriptScheme]),
            .init(strategyID: customGroup, orderedSchemeIDs: []),
        ]
        let decision = SchemeSelection.resolve(
            pendingFocus: nil,
            current: .init(strategyID: nil, schemeID: nil),
            trees: trees, isSameProject: false)
        #expect(decision == .select(strategyID: scriptGroup, schemeID: newScriptScheme))
    }
}
