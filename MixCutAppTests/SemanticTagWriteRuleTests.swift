import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// STR · 语义标签规则的穷举与退化
//
// ## 为什么要有这一组
//
// `SemanticType.toggled` 与 `CategoryEchoBudget.slice` 是本轮新立的两颗纯函数：
// 前者是「至少保留 1 个语义类型」这条不变式的唯一判据（界面、批量、MCP 三方共用），
// 后者决定收起态回显铺几颗标签。两颗都是**有限小域**：
// 12 个 case 的子集只有 2^12 = 4096 个，× 12 个切换目标 = 49152 组。
//
// 域这么小，穷举就比随机属性测试（PBT）更强也更便宜 —— 引 SwiftCheck 那类依赖
// 会把"可枚举的完备性"换成"跑了一千个随机样本"，是负收益。所以这一组全部穷举。
//
// ## 两条反恒绿腿（不是装饰）
//
// 1. **TC-STR-03**：同一套穷举喂给两棵故意写错的对照实现，必须都判出违规。
//    少了这条，TC-STR-02 可能只是在遍历一个恒真的比较。
// 2. **TC-STR-06**：回显颗数由**两道独立的闸**决定 —— 产品上限 2 颗、几何预算兜底。
//    今天生效的是上限（预算按短名能给到 3 颗），所以两道闸各钉一半：
//    摘掉上限会铺出 3 颗；摘掉预算会在窄面板上把第 2 颗截成半个词。
//
// ## 台架
//   纯函数，无容器、无进程级单例 ⇒ 不需要 `.serialized`。
//   ⚠️ 字符串里一律用「」不用 ASCII 双引号 —— 本文件第一版就是因为中文里嵌了 `"`
//   而整文件语法不过（这类坑在本仓已经记过一次）。
// ============================================================================

private let strAll = SemanticType.allCases

/// 把 0..<4096 的掩码展开成一个标签子集（按 `allCases` 原序，保证可复现）。
private func strSubset(_ mask: Int) -> [SemanticType] {
    var out: [SemanticType] = []
    for (i, type) in strAll.enumerated() where mask & (1 << i) != 0 { out.append(type) }
    return out
}

/// toggled 的函数形状 —— 抽出来是为了让**同一套穷举**既能打真码、也能打对照的错码。
/// 对照腿若另写一套遍历，它就证不了真码那条不是恒绿。
private typealias StrToggler = (_ current: [SemanticType], _ target: SemanticType)
    -> (outcome: SemanticToggleOutcome, next: [SemanticType])

/// 全域穷举，返回违规样本（最多留 5 条，够定位就行）。
private func strSweep(_ impl: StrToggler) -> [String] {
    var bad: [String] = []
    for mask in 0..<(1 << strAll.count) {
        let current = strSubset(mask)
        for target in strAll {
            let r = impl(current, target)
            var why: String?

            if current.contains(target) {
                if current.count == 1 {
                    if r.outcome != .refusedKeepAtLeastOne { why = "唯一标签被摘掉了（最小值破了）" }
                    else if r.next != current { why = "拒绝却没原样返回" }
                } else {
                    if r.outcome != .removed { why = "该判成 removed" }
                    else if r.next != current.filter({ $0 != target }) { why = "摘错了元素或重排了顺序" }
                }
            } else {
                if r.outcome != .added { why = "该判成 added" }
                else if r.next != current + [target] { why = "新增没追加在末尾（顺序被动过）" }
            }

            // 全域不变式：输出不许含重复，长度只许 ±1 或 0。
            if Set(r.next).count != r.next.count { why = (why ?? "") + "；输出含重复" }
            if abs(r.next.count - current.count) > 1 { why = (why ?? "") + "；长度跳了不止 1" }

            if let why, bad.count < 5 {
                bad.append("mask=\(mask) 目标=\(target.rawValue)：\(why)")
            }
        }
    }
    return bad
}

@Suite("STR · 语义标签规则的穷举与退化")
struct SemanticTagWriteRuleTests {

    @Test("TC-STR-01 名册前提：语义类型恰好 12 颗（穷举空间由它决定）")
    func rosterSizeIsWhatTheSweepAssumes() {
        // 这颗不是复刻 ETB-1，而是本文件的**前提自检**：名册一变，下面的 `1 << count`
        // 与所有期望颗数都要跟着重算，先让它响亮地失败而不是悄悄少扫一半。
        #expect(strAll.count == 12, "名册变成 \(strAll.count) 颗 ⇒ 本文件的穷举空间与期望值都要重算")
    }

    @Test("TC-STR-02 穷举 4096 子集 × 12 目标：真码零违规")
    func toggledPassesExhaustiveSweep() {
        let bad = strSweep(SemanticType.toggled)
        #expect(bad.isEmpty,
                "toggled 在 \(1 << strAll.count) 个子集 × \(strAll.count) 个目标上有违规：\(bad)")
    }

    @Test("TC-STR-03 反向对照：同一套穷举必须咬中两棵写错的实现")
    func theSweepActuallyHasTeeth() {
        // 错码一：摘「最后一个」而不是摘目标 ⇒ 应被"摘错了元素或重排了顺序"抓到。
        let removesWrongOne: StrToggler = { current, target in
            if current.contains(target) {
                guard current.count > 1 else { return (.refusedKeepAtLeastOne, current) }
                var next = current
                next.removeLast()
                return (.removed, next)
            }
            return (.added, current + [target])
        }
        // 错码二：不拦最小值 ⇒ 应被"唯一标签被摘掉了"抓到。
        let ignoresMinimum: StrToggler = { current, target in
            if let idx = current.firstIndex(of: target) {
                var next = current
                next.remove(at: idx)
                return (.removed, next)
            }
            return (.added, current + [target])
        }
        #expect(!strSweep(removesWrongOne).isEmpty,
                "穷举咬不住「摘错元素」⇒ TC-STR-02 的绿是恒绿，这条判据没在测东西")
        #expect(!strSweep(ignoresMinimum).isEmpty,
                "穷举咬不住「不拦最小值」⇒ 同上")
    }

    @Test("TC-STR-04 保序去重：幂等、不重排、长度不增，且重复一次就清干净")
    func deduplicationIsIdempotentAndOrderPreserving() {
        let dirty: [SemanticType] = [.hook, .painPoint, .hook, .emptyShot, .painPoint]
        let clean = SemanticType.deduplicated(dirty)
        #expect(clean == [.hook, .painPoint, .emptyShot],
                "去重把顺序动了或没清干净：\(clean.map(\.rawValue))")
        #expect(SemanticType.deduplicated(clean) == clean, "去重不幂等")
        #expect(SemanticType.deduplicated(dirty).count <= dirty.count)

        // 旧写法（firstIndex 只删第一个）在这种脏数据上要点两次才取消得掉；
        // 新判据先自愈再判，所以一次就彻底取消。
        let (outcome, next) = SemanticType.toggled([.hook, .hook], adding: .hook)
        #expect(outcome == .refusedKeepAtLeastOne,
                "脏数据自愈后应落到「唯一标签」那一档，实得 \(outcome)")
        #expect(next == [.hook], "脏数据没被一次清成一颗：\(next.map(\.rawValue))")
    }

    @Test("TC-STR-05 meetsMinimum 只认空集这一件事")
    func meetsMinimumIsExactlyNonEmpty() {
        #expect(!SemanticType.meetsMinimum([]), "空集被判成满足最小值")
        for type in strAll {
            #expect(SemanticType.meetsMinimum([type]), "\(type.rawValue) 单颗应满足最小值")
        }
    }

    @Test("TC-STR-06 回显颗数由两道独立的闸决定：产品上限 2 与几何预算")
    func echoCountHasTwoIndependentGates() {
        // 上限那一半：三颗短名，宽度预算本装得下，但产品拍板最多 2 颗。
        let threeShort: [SemanticType] = [.painPoint, .transition, .emptyShot]
        let capped = CategoryEchoBudget.slice(threeShort)
        #expect(capped.shown.count == 2,
                "产品上限没生效（铺出 \(capped.shown.count) 颗）⇒ 标题行会比用户拍的更拥挤")
        #expect(capped.overflow == 1, "被上限挤掉的那颗必须折进 +N，实得 \(capped.overflow)")

        // 预算那一半：把上限放开，同一组输入按宽度能铺 3 颗 ⇒ 证明那个 2 是上限给的、不是预算给的。
        let uncapped = CategoryEchoBudget.slice(threeShort, limit: 99)
        #expect(uncapped.shown.count == 3,
                "放开上限后仍铺不满 3 颗 ⇒ 今天真正在生效的是预算而不是上限，那上面那条断言就白设了")
        #expect(uncapped.overflow == 0)

        // 退化腿：面板给窄（120pt）时必须退到 1 颗，而不是把第 2 颗截成半个词。
        let narrow = CategoryEchoBudget.slice(strAll, width: 120, limit: 99)
        #expect(narrow.shown.count == 1,
                "窄预算下铺了 \(narrow.shown.count) 颗 ⇒ 预算不兜底，屏上会出现截断标签")
        // 再窄到一颗语义都装不下时，shown 为 0 但 overflow 必须等于全量（一颗都不许"丢"）。
        let starved = CategoryEchoBudget.slice(strAll, width: 100, limit: 99)
        #expect(starved.shown.isEmpty && starved.overflow == strAll.count,
                "预算耗尽时读数不守恒：shown=\(starved.shown.count) overflow=\(starved.overflow)")
    }

    @Test("TC-STR-07 availableWidth 是真算出来的，不是抄来的数")
    func availableWidthIsDerivedNotCopied() {
        // ⚠️ 逐颗写成 Double 字面量并拆开：一整条 `340 - 14 * 2 - …` 再标成 Double，
        // 编译器会对每个字面量做重载决议直到超时（实测报 "unable to type-check this
        // expression in reasonable time"）。拆成具名子项既快也好读哪一项动了会怎样。
        let panel: Double = 340
        let hPad: Double = 14
        let icon: Double = 14
        let gap: Double = 6
        let title: Double = 24
        let chevron: Double = 9
        let margin: Double = 12
        let independent = panel - hPad * 2 - icon - gap - title - gap - chevron - margin
        #expect(CategoryEchoBudget.availableWidth == independent,
                "实得 \(CategoryEchoBudget.availableWidth)，独立重算 \(independent) ⇒ 有一边被改成了手填值")
        // 字长必须参与：名字长的标签比名字短的重。
        #expect(CategoryEchoBudget.chipWidth("产品使用教育") > CategoryEchoBudget.chipWidth("痛点"))
        // 位置胶囊的水平内距比语义胶囊轻（它占的是固定预留位）。
        #expect(CategoryEchoBudget.chipWidth("开头", hPadding: CategoryEchoBudget.positionHPadding)
                < CategoryEchoBudget.chipWidth("开头"))
    }

    @Test("TC-STR-08 穷举全部 4096 子集的回显：颗数守恒、shown 是原序前缀、永不超上限")
    func echoSliceOverEverySubset() {
        var problems: [String] = []
        for mask in 0..<(1 << strAll.count) {
            let current = strSubset(mask)
            let r = CategoryEchoBudget.slice(current)
            if r.shown.count + r.overflow != current.count {
                problems.append("mask=\(mask) 不守恒：shown=\(r.shown.count) overflow=\(r.overflow) 共 \(current.count)")
            }
            if r.shown.count > CategoryEchoBudget.maxVisibleLimit {
                problems.append("mask=\(mask) 铺了 \(r.shown.count) 颗，超上限")
            }
            // shown 必须是 current 的**前缀**（不许挑、不许重排）—— 否则与卡片标签行对不上眼。
            if Array(current.prefix(r.shown.count)) != r.shown {
                problems.append("mask=\(mask) shown 不是原序前缀")
            }
            if problems.count >= 5 { break }
        }
        #expect(problems.isEmpty, "回显切片有违规：\(problems)")
    }

    @Test("TC-STR-09 空镜代价闸：只在「有台词 + 尚未标空镜 + 正要加上」这一档响")
    func emptyShotGateFiresOnExactlyOneEquivalenceClass() {
        // 三维等价类：是否空镜 × 是否已有空镜 × 台词是否为空。各档取一例逐一对表。
        // ① 有台词、尚未标空镜 ⇒ 除「空镜」以外的 11 颗都不该响。
        let speaking = Segment(segmentIndex: "gate_001", startTime: 0, endTime: 2,
                               text: "这颗橙子汁水多", semanticTypes: [.painPoint],
                               positionType: .middle)
        for target in strAll {
            #expect(SemanticType.confirmationNeededForEmptyShot(on: speaking, adding: target)
                        == (target == .emptyShot),
                    "有台词段加「\(target.rawValue)」时闸门读数不对")
        }
        // ② 已经标了空镜 ⇒ 再点是「摘掉」，那是设计内的否决入口，不许拦。
        let already = Segment(segmentIndex: "gate_002", startTime: 0, endTime: 2,
                              text: "这颗橙子汁水多", semanticTypes: [.emptyShot],
                              positionType: .middle)
        #expect(!SemanticType.confirmationNeededForEmptyShot(on: already, adding: .emptyShot),
                "摘掉已有空镜被拦了 ⇒ 给「人不认可机器判断」这条正解加了门槛")
        // ③ 空台词 ⇒ 合法供给，不需要确认。
        let silent = Segment(segmentIndex: "gate_003", startTime: 0, endTime: 2,
                             text: "", semanticTypes: [.painPoint], positionType: .middle)
        #expect(!SemanticType.confirmationNeededForEmptyShot(on: silent, adding: .emptyShot),
                "空台词段打空镜被拦了 ⇒ 正当的补标路径被挡")
        // ④ 纯空白台词也算空 ⇒ 走 ③ 那一档（trim 后判，不是判长度）。
        let blank = Segment(segmentIndex: "gate_004", startTime: 0, endTime: 2,
                            text: "   \n ", semanticTypes: [.painPoint], positionType: .middle)
        #expect(!SemanticType.confirmationNeededForEmptyShot(on: blank, adding: .emptyShot),
                "纯空白台词被当成有台词 ⇒ 给正当路径加了门槛")
    }

    @Test("SR-7 App 侧派生无损：aiAssignableTypes 与枚举的差集恰好是那颗机器标签")
    func aiAssignableTypesDerivesLosslesslyFromTheCoreRoster() {
        // Core → App 这条派生链只有在"每颗名字都解析得动"时才成立。
        // 用 compactMap 静默丢掉一颗的话，屏上会少一类而编译不报错 —— 这条就是拦这个。
        let derived = SemanticType.aiAssignableTypes
        #expect(derived.count == SemanticRoster.aiAssignable.count,
                "名册 \(SemanticRoster.aiAssignable.count) 颗只映射出 \(derived.count) 颗 ⇒ 有名字对不上枚举，compactMap 把它悄悄丢了（多半是改了 rawValue 没改 Core 那侧）")
        #expect(Set(derived).count == derived.count, "派生结果有重复")
        #expect(!derived.contains(.emptyShot), "机器标签出现在 AI 可指派集里 ⇒ 违反 ETB-2 的排除前提")
        // 差集必须**恰好**是那一颗：将来加第 13 类时这条会红，逼一次"它归谁写"的判断。
        let missing = Set(SemanticType.allCases).subtracting(derived)
        #expect(missing == Set([SemanticType.emptyShot]),
                "allCases 与 aiAssignableTypes 的差集是 \(missing.map(\.rawValue))，应为仅「空镜」")
        // 每颗都要能被 `SegmentCommitter` 归一化的第一道（精确 rawValue 匹配）接住。
        for type in derived {
            #expect(SemanticType(rawValue: type.rawValue) == type,
                    "\(type.rawValue) 的 rawValue 反查失败 ⇒ MCP/prompt 回传会降级成 .transition")
        }
    }
}
