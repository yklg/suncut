import Foundation
import Testing
@testable import MixCutCore

/// `DubStaleness.checkAll` 的契约测试（计划 v9 §10.4 组 4，TC-93…TC-97）
///
/// 本文件已从预览落地：在 `Tests/MixCutCoreTests/` 内、已编译、`swift test` 跑绿（2026-09-28）。
/// 与既有 `Tests/MixCutCoreTests/DubStalenessTests.swift` 的 5 条**互不覆盖**：那 5 条继续测 `check`，
/// 这里只测新增的"原台词"这一维与聚合入口。
///
/// 假定签名（关键点是**新字段带默认参数**，否则 `MixCut/` 里两处构造点会编译不过）：
/// ```
/// public struct DubSnapshot: Equatable, Sendable {
///     public init(recordedStartFrame: Int, recordedEndFrame: Int,
///                 recordedTextHash: String, recordedSourceTextHash: String = "")
/// }
/// public enum StalenessReason {  // 新增一档
///     ... case sourceTextChanged(current: String, recorded: String)
/// }
/// public enum DubStaleness {
///     public static func checkAll(snapshot: DubSnapshot,
///                                 currentStartFrame: Int,
///                                 currentEndFrame: Int,
///                                 currentRewrittenTextHash: String,
///                                 currentSourceTextHash: String) -> CheckResult
/// }
/// ```
///
/// 钉住的规则（红线 R8 的另一半 + 一般规则 R-f）：
/// - 重提取换掉**原台词**时必须能报出"原台词变了"，且这条原因**不与**"改写版变了"混成一条
/// - `recordedSourceTextHash == ""`（旧数据）⇒ **永不**产生 `sourceTextChanged`（无从判起，不许装懂）
/// - 未新增该维度时的行为与 `check` 完全一致（向后兼容，防我把老逻辑改坏）
///
/// 非空洞性对应：TC-97 是正向对照（什么都没变必须 `fresh`）；TC-94 断言只改写版变时原因里**没有**新档，
/// 若实现把两维并成一档，TC-93 与 TC-94 会同时失去意义 —— 所以两条都钉了"原因只有一条"。

@Suite("DubStaleness.checkAll：原台词变更与配音陈旧联动")
struct DubStalenessSourceTextTests {

    private let start = 300
    private let end = 460
    private let rewrittenHash = "hash-rewritten-A"
    private let sourceHash = "hash-original-A"

    private func result(snapshotSource: String,
                        currentRewritten: String,
                        currentSource: String,
                        startFrame: Int? = nil,
                        endFrame: Int? = nil) -> CheckResult {
        let snap = DubSnapshot(recordedStartFrame: start,
                               recordedEndFrame: end,
                               recordedTextHash: rewrittenHash,
                               recordedSourceTextHash: snapshotSource)
        return DubStaleness.checkAll(snapshot: snap,
                                     currentStartFrame: startFrame ?? start,
                                     currentEndFrame: endFrame ?? end,
                                     currentRewrittenTextHash: currentRewritten,
                                     currentSourceTextHash: currentSource)
    }

    private func reasons(_ result: CheckResult) -> [StalenessReason] {
        if case let .stale(list) = result { return list }
        return []
    }

    private func hasSourceTextReason(_ list: [StalenessReason]) -> Bool {
        list.contains { if case .sourceTextChanged = $0 { return true } else { return false } }
    }

    private func hasRewrittenReason(_ list: [StalenessReason]) -> Bool {
        list.contains { if case .textHashChanged = $0 { return true } else { return false } }
    }

    // MARK: TC-93 只原台词变

    @Test("TC-93 只原台词变（改写版没动）⇒ 恰好一条 sourceTextChanged")
    func onlyOriginalTextChanged() {
        let list = reasons(result(snapshotSource: sourceHash,
                                  currentRewritten: rewrittenHash,
                                  currentSource: "hash-original-B"))
        #expect(hasSourceTextReason(list), "重提取换了原台词却什么都没报，就是 v7 评审指出的'半架构'缺口")
        #expect(!hasRewrittenReason(list), "改写版没变，不该同时报 rewritten")
        #expect(list.count == 1, "原因条数应恰为 1，实际 \(list)")
    }

    // MARK: TC-94 只改写版变（老行为）

    @Test("TC-94 只改写版变 ⇒ 报 textHashChanged，不带新档")
    func onlyRewrittenChanged() {
        let list = reasons(result(snapshotSource: sourceHash,
                                  currentRewritten: "hash-rewritten-B",
                                  currentSource: sourceHash))
        #expect(hasRewrittenReason(list))
        #expect(!hasSourceTextReason(list), "原台词没变却报了新档，两维被并成一条了")
        #expect(list.count == 1, "原因条数应恰为 1，实际 \(list)")
    }

    // MARK: TC-95 两者都变

    @Test("TC-95 原台词与改写版都变 ⇒ 两条原因都在，且互不吞")
    func bothChanged() {
        let list = reasons(result(snapshotSource: sourceHash,
                                  currentRewritten: "hash-rewritten-B",
                                  currentSource: "hash-original-B"))
        #expect(list.count >= 2, "两条独立的变化被合成了一条：\(list)")
        #expect(hasRewrittenReason(list) && hasSourceTextReason(list))
    }

    // MARK: TC-96 旧数据不装懂（R-f）

    @Test("TC-96 旧 dub 的 recordedSourceTextHash 为空 ⇒ 永不报 sourceTextChanged")
    func legacyDubNeverClaimsSourceChanged() {
        let list = reasons(result(snapshotSource: "",
                                  currentRewritten: rewrittenHash,
                                  currentSource: "hash-original-B"))
        #expect(list.isEmpty,
                "旧数据没有记录原台词哈希，凭'无从判起'不该编出一条变化：\(list)")

        // 但边界与改写版这两条既有维度照旧生效（防止我把老逻辑一起阉掉）
        let frameMoved = reasons(result(snapshotSource: "",
                                         currentRewritten: rewrittenHash,
                                         currentSource: sourceHash,
                                         startFrame: start + 5))
        #expect(frameMoved.contains { if case .startFrameChanged = $0 { return true } else { return false } },
                "新加一档的同时把原有的帧变化判定弄丢了：\(frameMoved)")
    }

    // MARK: TC-97 正向对照 + 向后兼容

    @Test("TC-97 什么都没变 ⇒ fresh（正向对照，防恒真判定）")
    func nothingChangedIsFresh() {
        let result = result(snapshotSource: sourceHash,
                            currentRewritten: rewrittenHash,
                            currentSource: sourceHash)
        if case .stale(let list) = result {
            Issue.record("干净输入被报陈旧：\(list)")
        }
        #expect(reasons(result).isEmpty)
    }

    @Test("TC-97b 未曾生成（recordedStartFrame = -1）⇒ 仍报 stale，与 check 的老行为一致")
    func neverGeneratedStaysStale() {
        let snap = DubSnapshot(recordedStartFrame: -1, recordedEndFrame: -1, recordedTextHash: "")
        let all = DubStaleness.checkAll(snapshot: snap,
                                        currentStartFrame: start,
                                        currentEndFrame: end,
                                        currentRewrittenTextHash: rewrittenHash,
                                        currentSourceTextHash: sourceHash)
        if case .fresh = all {
            Issue.record("从未生成过的配音被判 fresh，等于给用户一个假绿")
        }
        #expect(reasons(all).count >= 1)

        // 向后兼容：不引入新维时，checkAll 与既有 check 的结论必须逐字一致
        let legacy = DubStaleness.check(snapshot: DubSnapshot(recordedStartFrame: start,
                                                              recordedEndFrame: end,
                                                              recordedTextHash: rewrittenHash),
                                        currentStartFrame: start,
                                        currentEndFrame: end + 30,
                                        currentTextHash: rewrittenHash)
        let viaAll = DubStaleness.checkAll(snapshot: DubSnapshot(recordedStartFrame: start,
                                                                 recordedEndFrame: end,
                                                                 recordedTextHash: rewrittenHash,
                                                                 recordedSourceTextHash: ""),
                                           currentStartFrame: start,
                                           currentEndFrame: end + 30,
                                           currentRewrittenTextHash: rewrittenHash,
                                           currentSourceTextHash: sourceHash)
        #expect(legacy == viaAll, "老维度的结论被改动：\(legacy) vs \(viaAll)")
    }

    // MARK: TC-111 原因要能分人（计划 §6：'原台词变了'不许显示成'改写版变了'）

    @Test("TC-111 userText：两维措辞互不含对方关键词，且 unknownLegacy 那种'无从判起'不产生原因")
    func reasonsAreDistinguishableInUserText() {
        let sourceReason = StalenessReason.sourceTextChanged(current: "a", recorded: "b")
        let rewrittenReason = StalenessReason.textHashChanged(current: "a", recorded: "b")

        #expect(sourceReason.userText.contains("原台词"), "实际：\(sourceReason.userText)")
        #expect(rewrittenReason.userText.contains("改写"), "实际：\(rewrittenReason.userText)")
        // 关键：互不含对方的关键词 —— 否则界面上两条原因长得一样，判据等于没满足
        #expect(!sourceReason.userText.contains("改写"), "原台词那条串了改写版的措辞")
        #expect(!rewrittenReason.userText.contains("原台词"), "改写版那条串了原台词的措辞")
        #expect(sourceReason.userText != rewrittenReason.userText)

        // 四档原因都必须有非空、互不相同的人话（新增维度时忘了配措辞，这条会红）
        let all: [StalenessReason] = [
            .startFrameChanged(current: 1, recorded: 0),
            .endFrameChanged(current: 1, recorded: 0),
            rewrittenReason, sourceReason,
        ]
        let texts = all.map(\.userText)
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == all.count, "原因措辞撞车：\(texts)")

        // 旧数据（recordedSourceTextHash 为空）：只报原维度，绝不冒出"原台词变了"
        let hash = DubStaleness.textHash(of: "人参果很好")
        let legacyOnly = DubStaleness.checkAll(
            snapshot: DubSnapshot(recordedStartFrame: 10, recordedEndFrame: 20,
                                  recordedTextHash: "stale-hash", recordedSourceTextHash: ""),
            currentStartFrame: 10, currentEndFrame: 20,
            currentRewrittenTextHash: hash, currentSourceTextHash: hash)
        guard case .stale(let reasons) = legacyOnly else {
            Issue.record("改写版哈希不符，应当 stale；实际：\(legacyOnly)")
            return
        }
        // 断言的是**种类**而不是哈希载荷（载荷由实现算出，写死具体值就等于测我自己）
        #expect(reasons.count == 1, "旧数据只该报改写版那一维；实际：\(reasons.map(\.userText))")
        let rewrittenKinds = reasons.filter { if case .textHashChanged = $0 { return true }; return false }
        #expect(rewrittenKinds.count == 1, "期望恰好一条改写版原因，实际：\(reasons.map(\.userText))")
        #expect(!reasons.contains { if case .sourceTextChanged = $0 { return true }; return false },
                "recordedSourceTextHash 为空的旧数据不许凭空报'原台词变了'")
    }
}
