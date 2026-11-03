import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 生成期编排状态机判据（FMX-18 / FMX-19 + 失败档 A/B/C + 环境级短路）
//
// 这三条原本是「I 层」（只能在 `FolderMixViewModel` 里跑，而 `swift test` 编不到 App target）。
// 计划里拍的是①案：把纯决策抽成 Core 值类型，让它们降成 U 层 —— 于是"抽中才建库"、
// "生成复用预览行"、"替不动就摘行并报名"这三件事进了日常门，不再靠真机回归时靠人记。
//
// 非空洞性（配在 `.scratch/fm_mutate_step5.py`，逐把读数登记台账）：
//   - `ingestTask` 改成"所有参与类别都建库"            → FMX-18 红（notBuilt 空、多建 0 视频空壳）
//   - `ingestTask` 把余量写成常量不封顶                → FMX-18b 红（radix=2 的小空间超额备货）
//   - `resolve` 改成重抽而不是原地补                  → FMX-19 红（输出行与输入行逐字不同）
//   - `resolve` 不看 unusable 集合                    → 档 A 红（坏素材照样留着）
//   - 去掉行内撞身份那一路                            → 档 C 红
//   - 摘行时把 categories 留空                        → NAMING 红（界面写不出"哪一类替不动"）
//   - 环境级短路不设阈值 / `.other` 也计数            → SHORT-1 / SHORT-2 红
//
// FMX-20「停止 ≠ 删除的终态」**不在这里测**，结案给既有三件更硬的：
//   全仓真删名册 `TombstoneReadGuardTests` G12（54 颗逐文件名册，多一处直删就双红）
//   + `ClipIngestReadoutCharacterizationTests` CR-5（service 内零 `context.delete(`）
//   + 真机端到端第 9 步。这里再造一条"没有删除动作"的判据是同一事实的第四份抄本。
// ============================================================================

struct FolderMixOrchestrationTests {

    private func cand(_ key: String, _ category: String) -> FolderMixCandidate {
        FolderMixCandidate(identityKey: key, category: category, name: "\(key).mp4",
                           path: "\(category)/\(key).mp4", duration: 10, byteSize: 1_000)
    }

    private func pool(_ pairs: [(String, [String])]) -> [String: [FolderMixCandidate]] {
        var out: [String: [FolderMixCandidate]] = [:]
        for (category, keys) in pairs { out[category] = keys.map { cand($0, category) } }
        return out
    }

    /// 钩子 3 / 背书 2 / 卖点 2，另有一类"参与但这一批一条都没抽中"
    private var fixtures: [String: [FolderMixCandidate]] {
        pool([("钩子", ["h1", "h2", "h3"]), ("背书", ["t1", "t2"]),
              ("卖点", ["m1", "m2"]), ("落选类", ["x1", "x2"])])
    }
    private let ordered = ["钩子", "背书", "卖点", "落选类"]

    /// 大池夹具（54/52/43，照真机现场量级）。
    /// 为什么必须有它：默认那批小池（每类 2–4 颗、抽中 2–3 颗）里**前缀恰好等于全池**，
    /// 「清单取前缀而不是取抽中集」这个洞在形状上看不见 —— FMX-18d 单独用小池跑时，
    /// 台架刀 K1-a（摘掉先装抽中集）一条都不红（2026-10-22 实测登记）。
    private var bigPool: [String: [FolderMixCandidate]] {
        pool([("钩子", (1...54).map { "h\($0)" }),
              ("背书", (1...52).map { "t\($0)" }),
              ("卖点", (1...43).map { "m\($0)" })])
    }

    private func spaceOf(enabled: [String] = ["钩子", "背书", "卖点"],
                         source: [String: [FolderMixCandidate]]? = nil) -> FolderMixComboSpace {
        FolderMixComboSpace(candidatesByCategory: source ?? fixtures,
                            orderedCategories: ordered, enabled: Set(enabled))
    }

    /// 真抽一批行（走 `drawMany`，不手搓行 —— 手搓的行不代表页面能看到的那批）
    private func draw(_ count: Int, seed: UInt64 = 7,
                      ledger: FolderMixComboLedger = FolderMixComboLedger(),
                      source: [String: [FolderMixCandidate]]? = nil,
                      enabled: [String] = ["钩子", "背书", "卖点"]) throws -> [FolderMixComboRow] {
        var rng = SplitMix64(seed: seed)
        return try FolderMixPicker.drawMany(candidatesByCategory: source ?? fixtures,
                                            space: spaceOf(enabled: enabled, source: source),
                                            ledger: ledger, count: count,
                                            rng: &rng).rows
    }

    /// 把**整个候选池**标成可用（= "抽中集 ∪ 余量"都入库并解析成功了）。
    /// 为什么不是只标抽中的那几颗：`resolve` 的口径是"没出现在 resolution 里的键 = 不可用"，
    /// 只标抽中颗会让替补无处可换，测出来的就不是替补而是摘行。
    private func allUsable(_ source: [String: [FolderMixCandidate]]? = nil)
        -> [String: FolderMixResolution] {
        var out: [String: FolderMixResolution] = [:]
        for group in (source ?? fixtures).values {
            for candidate in group { out[candidate.identityKey] = .usable(candidate.identityKey) }
        }
        return out
    }

    private func resolve(_ rows: [FolderMixComboRow],
                         _ resolution: [String: FolderMixResolution],
                         ledger: FolderMixComboLedger = FolderMixComboLedger(),
                         source: [String: [FolderMixCandidate]]? = nil,
                         enabled: [String] = ["钩子", "背书", "卖点"],
                         seed: UInt64 = 11) -> FolderMixGenerateOutcome {
        var rng = SplitMix64(seed: seed)
        return FolderMixGeneratePlanner.resolve(rows: rows,
                                                candidatesByCategory: source ?? fixtures,
                                                resolution: resolution,
                                                space: spaceOf(enabled: enabled, source: source),
                                                ledger: ledger, rng: &rng)
    }

    // ── FMX-18：只为真被抽中的类别建库（D26 的生成期那一半）──

    @Test("FMX-18 入库任务只覆盖被抽中的类别；参与但没抽中的那颗一颗都不建，且要点名")
    func ingestTaskCoversOnlyDrawnCategories() throws {
        let rows = try draw(2)
        let task = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: fixtures,
                                                       space: spaceOf(enabled: ordered),
                                                       reservePerCategory: { _, _ in 3 })
        #expect(task.categoriesBuilt == ["钩子", "背书", "卖点"], "多建一颗就是多一个 0 视频空壳项目")
        #expect(task.categoriesNotBuilt == ["落选类"],
                "没抽中的类别必须点名出来，界面才解释得了『侧栏为什么少了这一格』")
        for batch in task.batches {
            #expect(Set(batch.paths).count == batch.paths.count,
                    "\(batch.category) 的路径清单有重复 ⇒ 同一份文件拷两遍")
            // provenance：清单里必须是候选的**真实路径**。默认档 identityKey 恰好等于路径，
            // 所以把键当路径写在这里今天不会暴露；只有「精确识别」打开（键 = 校验和）才会红
            // —— 一条都拷不到，然后整批被当成"入库失败"摘光。这条断言就是为了不在那时才发现。
            let realPaths = Set((fixtures[batch.category] ?? []).map(\.path))
            #expect(Set(batch.paths).isSubset(of: realPaths),
                    "\(batch.category) 的入库清单混进了非路径的东西")
            #expect(batch.paths.count <= 2 + 3)
        }
        #expect(task.totalPaths > 0)
    }

    @Test("FMX-18b 余量按「还剩几条」封顶：radix=2 的小空间不许备出比候选还多的份")
    func reserveIsClampedByRemainingCandidates() throws {
        let rows = try draw(2)
        let task = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: fixtures,
                                                       space: spaceOf(enabled: ordered),
                                                       reservePerCategory: { _, _ in 99 })
        let selling = task.batches.first { $0.category == "卖点" }
        #expect(selling?.paths.count == 2,
                "radix=2 却备了 \(selling?.paths.count ?? -1) 条 ⇒ 计划 B 段那条公式被写成了常量")
    }

    @Test("FMX-18c 不传注入缝时走 `FolderMixLimits.substituteReserve` 那颗公式（默认档不许超额备货）")
    func defaultReserveUsesTheSingleFormula() throws {
        let rows = try draw(2)
        let injected = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: fixtures,
                                                           space: spaceOf(enabled: ordered),
                                                           reservePerCategory: { _, _ in 99 })
        let defaulted = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: fixtures,
                                                            space: spaceOf(enabled: ordered))
        // 卖点 radix=2：无论传多大，都不会超过"这一类一共几条"
        #expect(injected.batches.first { $0.category == "卖点" }?.paths.count == 2)
        #expect(defaulted.totalPaths == injected.totalPaths,
                "默认公式与注入 99 条读数不同 ⇒ 说明有一侧根本没封顶")
    }

    // ── FMX-18d/18e：抽中集必须在入库清单里（计划 2026-10-22 第三轮 笔 K1）──
    //
    // 这两条存在的理由：FMX-18 一族只核「建哪几类、去重、条数上限、是真实路径」，全是数量与来源，
    // **没有一条把「抽中的那几颗」和「清单」对上** ⇒ 上一版按池子顺序取前缀也能全绿，真机却一条
    // 方案都出不来（交回 32 = 4×(5+3)、没找到 173）。这是本判据族第三次「因错误原因通过」。

    @Test("FMX-18d 每行每格抽中的那颗，路径必须在该类的入库清单里")
    func ingestListContainsEveryDrawnCandidate() throws {
        // 条数 5、池子 54/52/43 ⇒ 真机那次就是在这个形状上出不来（计划 5 条一条没出）。
        let rows = try draw(5, seed: 7, source: bigPool)
        let task = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: bigPool,
                                                       space: spaceOf(enabled: ["钩子", "背书", "卖点"],
                                                                      source: bigPool),
                                                       reservePerCategory: { _, _ in 3 })
        let built = Dictionary(uniqueKeysWithValues: task.batches.map { ($0.category, Set($0.paths)) })
        var drawnPaths: [String] = []
        for row in rows {
            for pick in row.picks {
                drawnPaths.append(pick.path)
                #expect(built[pick.category]?.contains(pick.path) == true,
                        "第 \(row.ordinal) 行的「\(pick.category)」抽中了 \(pick.path) 却没进该类入库清单 ⇒ 它根本没入库，join 只能报「没找到」")
            }
        }
        #expect(drawnPaths.count == 15, "夹具自证：5 行 × 3 类 = 15 次抽中，实得 \(drawnPaths.count)")
    }

    @Test("FMX-18e 条数 ≪ 池子（日常用法）：20 组种子逐组都要装全抽中集，且不超上限")
    func drawnSetSurvivesWhenRequestedCountIsTinyVersusPool() throws {
        // 上一批夹具每类只有 2–4 颗、抽中 2–3 颗 ⇒ 前缀恰好等于全池，这个洞在形状上看不见。
        // 这里照真机现场量级造池（54/52/43），条数压到 5，再扫 20 组种子 ⇒ 抽中颗必然散在池子各处。
        let big = pool([("钩子", (1...54).map { "h\($0)" }),
                        ("背书", (1...52).map { "t\($0)" }),
                        ("卖点", (1...43).map { "m\($0)" })])
        for seedValue in 1...20 {
            let rows = try draw(5, seed: UInt64(seedValue), source: big)
            let task = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: big,
                                                           space: spaceOf(enabled: ["钩子", "背书", "卖点"],
                                                                          source: big),
                                                           reservePerCategory: { _, _ in 3 })
            let built = Dictionary(uniqueKeysWithValues: task.batches.map { ($0.category, Set($0.paths)) })
            for row in rows {
                for pick in row.picks {
                    #expect(built[pick.category]?.contains(pick.path) == true,
                            "seed=\(seedValue) 抽中的 \(pick.path) 没进「\(pick.category)」清单 ⇒ 前缀写法又回来了")
                }
            }
            for batch in task.batches {
                #expect(Set(batch.paths).count == batch.paths.count,
                        "seed=\(seedValue) 的 \(batch.category) 清单有重复 ⇒ 同一份文件拷两遍")
                // 条数只钉**上界**，不钉等号：`drawnPerCategory` 数的是出现次数，跨行重复抽中同一条时
                // 它大于不同键的个数，而清单按键去重 ⇒ 实际条数是浮动值（写死等号就是造一条会假红的判据）。
                #expect(batch.paths.count <= 5 + 3,
                        "seed=\(seedValue) 的 \(batch.category) 备了 \(batch.paths.count) 条，超了 抽中+余量 的上限")
            }
        }
    }

    @Test("FMX-18f 大池下默认公式必须与注入 99 不同（证明默认那条真在走 substituteReserve，不是恒等）")
    func defaultFormulaDiffersFromInjectedOnBigPool() throws {
        // 小池夹具证不了这件事：`min(公式, pool.count − drawn)` 把两侧都夹成同一个数 ⇒
        // 「默认 = 那颗公式」这条断言在池子只有 2–3 颗时是**恒真**的（台架刀实测：把默认值写死成
        // `{ _, _ in 3 }` 时 18c 一条都不红）。所以钉公式必须有一个「还剩很多条」的池子。
        let big = pool([("钩子", (1...54).map { "h\($0)" })])   // 单类大池：只测公式那一条
        let rows = try draw(5, seed: 3, source: big, enabled: ["钩子"])
        let space = spaceOf(enabled: ["钩子"], source: big)
        let defaulted = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: big,
                                                            space: space)
        let injected = FolderMixGeneratePlanner.ingestTask(rows: rows, candidatesByCategory: big,
                                                           space: space, reservePerCategory: { _, _ in 99 })
        let hook = try #require(defaulted.batches.first { $0.category == "钩子" })
        // 期望值由那颗公式自己算，不在这里把 3 抄第二遍（抄了就成了判据里的第二个真源）。
        let expected = 5 + FolderMixLimits.substituteReserve(radix: 54, alreadyDrawn: 5)
        #expect(expected == 8, "夹具自证：radix 54、已抽 5 时公式该给 3，实得 \(expected - 5)")
        #expect(hook.paths.count == expected,
                "默认档备了 \(hook.paths.count) 条，期望 抽中 5 + 公式 \(expected - 5)")
        #expect(injected.batches.first { $0.category == "钩子" }?.paths.count == 54,
                "注入 99 时该把整池都装上（装不满说明封顶被写死了两处）")
    }

    // ── FMX-19：generate 复用预览行，绝不重抽 ──

    @Test("FMX-19 全部可用时，输出行与传入的预览行逐字相同（生成不许换一批）")
    func generateReusesThePreviewedRows() throws {
        let rows = try draw(3)
        let out = resolve(rows, allUsable())
        #expect(out.rows == rows, "预览一批、生成另一批是用户直接看得见的那件错事")
        #expect(out.shortfalls.isEmpty)
        #expect(out.substitutionCount == 0, "没问题时不该动手替补")
    }

    // ── 失败七档里的 A/B/C（G1–G3）──

    @Test("档 A 入库失败 ⇒ 同类别内换一条，其他类别的 picks 逐字不动（R9）")
    func ingestFailureSubstitutesWithinItsCategory() throws {
        // 只喂一行：多行夹具里三行可能共用同一颗坏素材，换完后彼此撞签名 ⇒ 摘行是**对的**，
        // 但那会让这条判据测到别的东西上（本仓踩过的"判据因错误原因通过/失败"同族）。
        let rows = try draw(1)
        let victim = rows[0].picks[0]
        var resolution = allUsable()
        resolution[victim.identityKey] = .failed(victim.identityKey, .ingestFailed)
        let out = resolve(rows, resolution)
        #expect(out.rows.count == 1, "换得动就不该摘行")
        let fixed = out.rows[0]
        #expect(fixed.picks[0].identityKey != victim.identityKey)
        #expect(fixed.picks[0].category == victim.category, "替补不许跨类别动手")
        #expect(Array(fixed.picks.dropFirst()) == Array(rows[0].picks.dropFirst()),
                "除那一格以外，其余各格必须逐字不动")
        #expect(out.substitutionCount == 1)
    }

    @Test("档 B 在库里但没有整片段 ⇒ 换得动就留着，换不动时原因里报的是这一档不是档 A")
    func missingWholeClipIsItsOwnCode() throws {
        // 背书这一类只剩那颗坏素材 ⇒ 档 B 换不动 ⇒ 摘行文案要带 noWholeClipSegment
        let source = pool([("钩子", ["h1", "h2"]), ("背书", ["t1"]), ("卖点", ["m1"])])
        let rows = try draw(1, source: source)
        let victim = rows[0].picks[1]
        var resolution = allUsable(source)
        resolution[victim.identityKey] = .failed(victim.identityKey, .noWholeClipSegment)
        let out = resolve(rows, resolution, source: source)
        #expect(out.rows.isEmpty)
        #expect(out.shortfalls.count == 1)
        #expect(out.shortfalls[0].reason.contains(FolderMixFailureCode.noWholeClipSegment.rawValue),
                "档位被糊成通用文案 ⇒ 用户与排障者都看不见『是缺整片段，不是没拷进来』")
        #expect(out.shortfalls[0].categories == ["背书"])
    }

    @Test("档 C 一行里两段指向同一素材 ⇒ 换得动就换，两类都只剩这一颗时摘行并点名")
    func duplicateInRowIsSubstitutedOrDropped() {
        // 正照：背书这一类还有 t1 ⇒ 换掉撞进来的那一格，行留着
        let loose = pool([("钩子", ["same"]), ("背书", ["t1"]), ("卖点", ["m1"])])
        let rowLoose = FolderMixComboRow(ordinal: 0,
                                        picks: [cand("same", "钩子"), cand("same", "背书"),
                                                cand("m1", "卖点")])
        let usableAll = allUsable(loose)
        let kept = resolve([rowLoose], usableAll, source: loose)
        #expect(kept.rows.count == 1, "背书这一类还有 t1 时该换得动")
        #expect(Set(kept.rows[0].picks.map(\.identityKey)).count == 3, "换完必须行内不再撞")

        // 负照：两类都只有同一颗 ⇒ 无处可换 ⇒ 摘行、报档 C
        let tight = pool([("钩子", ["same"]), ("背书", ["same"]), ("卖点", ["m1"])])
        let dropped = resolve([rowLoose], usableAll, source: tight)
        #expect(dropped.rows.isEmpty)
        #expect(dropped.shortfalls.count == 1)
        #expect(dropped.shortfalls[0].reason.contains("档 C"))
    }

    @Test("NAMING 一类整体不可用 ⇒ 每条摘行都要报出『是哪一类』，且序号互不相同")
    func droppedRowsAreNamedByCategory() throws {
        let rows = try draw(3)
        var resolution = allUsable()
        for key in ["h1", "h2", "h3"] { resolution[key] = .failed(key, .ingestFailed) }
        let out = resolve(rows, resolution)
        #expect(out.rows.isEmpty)
        #expect(out.shortfalls.count == 3)
        #expect(out.shortfalls.allSatisfy { $0.categories.contains("钩子") })
        #expect(Set(out.shortfalls.map(\.requestedIndex)).count == 3,
                "序号全记成同一条 ⇒ 界面写不出『计划 3 / 实得 0』")
    }

    @Test("替补不许换回一个已经发出去的组合（跨批不重复优先于凑满条数）")
    func substitutionCannotEmitAnIssuedSignature() throws {
        let rows = try draw(3)
        var ledger = FolderMixComboLedger()
        for row in rows { _ = ledger.commit(signature: row.signature) }
        let victim = rows[0].picks[0]
        var resolution = allUsable()
        resolution[victim.identityKey] = .failed(victim.identityKey, .ingestFailed)
        let out = resolve(rows, resolution, ledger: ledger)
        // 钩子有 3 颗、背书 2、卖点 2 ⇒ 换一种搭配仍有未发出的解；但**已发出的那一条绝不能重出**
        #expect(out.rows.allSatisfy { !rows.dropFirst().map(\.signature).contains($0.signature) },
                "产出了与上一批同签名的组合 = 用户拿到的方案里有重复的")
        #expect(out.shortfalls.isEmpty || out.shortfalls[0].reason.contains("已发出"))
    }

    @Test("覆盖面：resolution 里没出现过的键当不可用（替补不许换进一个从没入库的素材）")
    func keysMissingFromResolutionAreUnusable() throws {
        let rows = try draw(1)
        let victim = rows[0].picks[0]
        // 只标这一行里**除 victim 之外**的那几颗 —— victim 所在类别的其他候选都没进 resolution
        var thin: [String: FolderMixResolution] = [:]
        for pick in rows[0].picks where pick.identityKey != victim.identityKey {
            thin[pick.identityKey] = .usable(pick.identityKey)
        }
        thin[victim.identityKey] = .failed(victim.identityKey, .ingestFailed)
        let out = resolve(rows, thin)
        #expect(out.rows.isEmpty, "换进一个没解析过的键 = 方案指向库里不存在的段（导出静默丢段的形状）")
        #expect(out.shortfalls[0].categories.contains(victim.category))
    }

    // ── 环境级短路（计划 D 段第 2 条）──

    @Test("SHORT-1 连续三条同因失败就短路整批，之后一直报该短路")
    func systemicFailureShortCircuits() {
        // `#expect` 的首参是 autoclosure ⇒ 里面不能调 mutating 成员（本仓实测坑，提一次记一次）
        var ledger = FolderMixGeneratePlanner.FailureLedger()
        let first = ledger.note(.diskShortfall)
        let second = ledger.note(.diskShortfall)
        let third = ledger.note(.diskShortfall)
        #expect(!first)
        #expect(!second)
        #expect(third)
        #expect(ledger.abortCode == .diskShortfall)
        let afterAbort = ledger.note(.unreadable)
        #expect(afterAbort, "已经短路了就一直为真，调用方不必自己再判一次")
    }

    @Test("SHORT-2 换因即重新计数、兜底码 `.other` 永不短路")
    func streakResetsOnDifferentCodeAndOtherNeverAborts() {
        var ledger = FolderMixGeneratePlanner.FailureLedger()
        let u1 = ledger.note(.unreadable)
        let u2 = ledger.note(.unreadable)
        let switched = ledger.note(.ingestFailed)
        let u3 = ledger.note(.unreadable)
        #expect(!u1)
        #expect(!u2)
        #expect(!switched, "换了原因还累加 = 把两类无关失败判成同一场故障")
        #expect(!u3, "换回来之后从头计数：两条同因不等于一场环境级故障")
        #expect(ledger.abortCode == nil)
        var others = FolderMixGeneratePlanner.FailureLedger()
        for _ in 0..<10 { _ = others.note(.other) }
        #expect(others.abortCode == nil, "兜底码参与短路 ⇒ 归因错位会把正常批整批掐掉")
    }

    @Test("CODES 一档一码：rawValue 互不相同，且只有环境级那三码可以短路")
    func codesArePerTierAndOnlySystemicOnesAbort() {
        // 名册改成 allCases（R4 实测：这里原先手抄七颗，上一轮新增的 notIngested 根本没进册
        // ⇒ 名册说七档、真身八档，新加档位不表态也没人报警）。手抄名册就是第二真源。
        let all = FolderMixFailureCode.allCases
        #expect(all.count == 9, "档位总数实得 \(all.count)，登记为 9（含 materialMissing）⇒ 加一档必须同时更新这条与文案腿")
        #expect(Set(all.map(\.rawValue)).count == all.count,
                "两颗码同值 = \(all.count) 档里有两档没法区分（FMX-09 说的就是归因错位）")
        // 一档一句人话，且句间两两不同（覆盖评估 TC-K4：加档时忘了写 shortfallText 会编译不过，
        // 但"文案抄成一句"只有这条能抓）。
        let texts = all.map { $0.shortfallText }
        #expect(texts.allSatisfy { !$0.isEmpty }, "有档的人话文案是空串")
        #expect(Set(texts).count == texts.count, "两档共用同一句人话 = 红字分不开，用户只能猜")
        #expect(all.filter(\.isSystemic).map(\.rawValue) == ["diskShortfall", "unreadable", "noPermission"],
                "素材级三码（换一条就行）与兜底码一旦参与短路，就会在一盘正常素材里掐掉整批")

        var ledger = FolderMixGeneratePlanner.FailureLedger()
        for _ in 0..<8 { _ = ledger.note(.ingestFailed) }
        #expect(ledger.abortCode == nil)
    }

    // ── 计划 B 段那条公式：余量随剩余候选收缩 ──

    @Test("LIMITS 余量公式：radix 大时给 3，radix 小时给剩多少备多少，抽光了给 0")
    func substituteReserveFormula() {
        #expect(FolderMixLimits.substituteReserve(radix: 20, alreadyDrawn: 2) == 3)
        #expect(FolderMixLimits.substituteReserve(radix: 4, alreadyDrawn: 2) == 2)
        #expect(FolderMixLimits.substituteReserve(radix: 2, alreadyDrawn: 2) == 0)
        #expect(FolderMixLimits.substituteReserve(radix: 1, alreadyDrawn: 5) == 0, "不许为负")
    }

    // MARK: JOIN 族 · 与库对接的键（计划 2026-10-22 笔 J1）
    //
    // 这一族的存在理由：上一轮 1306 条判据全绿，真机第 5 步却一条方案都出不来 ——
    // 因为"混剪候选 ↔ 库里那一行"这颗键从来没有被判据碰过（`FolderMixResolveTests` 的
    // FMX-14 是拿夹具自己约定的键，键与路径同域，所以键错位时它照样绿）。
    // 所以这一族的**夹具形状是硬定义**：素材路径在用户目录里，库内路径是拷贝落地的
    // `<应用程序支持>/videos/<校验和>/<文件名>`，两颗**互不为前缀**（JOIN-0 就是钉这件事）。

    // 根目录用中性占位（身份字面量只能住 Brand.swift，由 BrandIdentityTests 钉），
    // 但形状必须是真的：`…/videos/<内容校验和>/<文件名>` —— 这族判据靠的就是这颗形状。
    private let joinLibraryRoot = "/Users/anyone/Library/Application Support/App/videos"

    /// 库里那一行的真实形状（拷贝落地，带校验和目录段）
    private func joinLibraryPath(hash: String, name: String) -> String {
        "\(joinLibraryRoot)/\(hash)/\(name)"
    }

    /// 候选那侧的真实形状（用户素材目录里的绝对路径）
    private func joinMaterialPath(category: String, name: String) -> String {
        "/Users/x/素材/\(category)/\(name)"
    }

    private func joinCand(category: String, name: String) -> FolderMixCandidate {
        let path = joinMaterialPath(category: category, name: name)
        return FolderMixCandidate(identityKey: path, category: category, name: name,
                                  path: path, duration: 12, byteSize: 5_000)
    }

    @Test("JOIN-0 夹具自检：素材路径与库内路径必须分处两个域（键约定不许由夹具凭空发明）")
    func joinFixturesLiveInTwoDomains() {
        let material = joinMaterialPath(category: "爆点", name: "钩子A.mp4")
        let library = joinLibraryPath(hash: "ab12cd34ef56", name: "钩子A.mp4")
        #expect(library != material)
        #expect(!library.hasPrefix(material) && !material.hasPrefix(library),
                "两颗键一旦同域，这一族就退化成自洽的假绿 —— 真机那种错位看不见")
        #expect(library.contains("/videos/"), "库内那行必须带上拷贝落地的 videos 段，否则不像生产形状")
        #expect(!material.contains("/videos/"), "素材那侧不该出现库内段")
    }

    @Test("JOIN-1 主腿：入库交回的路径命中 ⇒ 可用，且段 id 落到键表上（本缺陷的复现腿）")
    func ingestedPathResolvesToSegment() {
        let candidate = joinCand(category: "爆点", name: "钩子A.mp4")
        let videoID = UUID()
        let segmentID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: segmentID, filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(outcome.resolution[candidate.path]?.isUsable == true)
        #expect(outcome.segmentIDByKey[candidate.identityKey] == segmentID,
                "键→段 id 这张表建不起来，建方案那头就会报「已经不在素材库里」")
        #expect(outcome.hitCount == 1 && outcome.notIngestedCount == 0)
        // 复现腿的另一半：库里那行的路径与候选路径**不同**，所以任何"拿 localPath 反查"
        // 的写法在这份夹具上必然落空（台架 K1 就是把取键换成名字/库内路径，这条要红）。
        #expect(joinLibraryPath(hash: "ab12cd34ef56", name: candidate.name) != candidate.path)
    }

    @Test("JOIN-2 档 B：交回里有这条、但那行没有覆盖整片的段 ⇒ 报 noWholeClipSegment，不许报入库失败")
    func ingestedRowWithoutWholeClipIsTierB() {
        let candidate = joinCand(category: "爆点", name: "钩子A.mp4")
        let videoID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: nil, filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(outcome.resolution[candidate.path]?.failureCode == .noWholeClipSegment)
        #expect(outcome.noWholeClipCount == 1)
        #expect(outcome.failedIngestCount == 0, "档 B 说成档 A = 让用户去查磁盘，而那一步其实全成功了")
        #expect(outcome.segmentIDByKey.isEmpty)
    }

    @Test("JOIN-3 档 A：该路径带着入库失败码 ⇒ 用自己的那颗码，不被兜底改写成「没找到」")
    func ingestFailureKeepsItsOwnCode() {
        let candidate = joinCand(category: "卖点", name: "m1.mp4")
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["卖点": [candidate]],
            ingested: [],
            shapes: [:],
            failureCodeBySourcePath: [candidate.path: .diskShortfall])
        #expect(outcome.resolution[candidate.path]?.failureCode == .diskShortfall)
        #expect(outcome.failedIngestCount == 1 && outcome.notIngestedCount == 0)
        #expect(outcome.resolution[candidate.path]?.failureCode?.isSystemic == true,
                "环境级码一旦在这里被换成素材级码，短路整批那条逻辑就再也触发不了")
    }

    @Test("JOIN-4 新码：既没交回、也没有失败码 ⇒ notIngested（文案要能读出「入库后没找到」）")
    func missingFromIngestedGetsItsOwnCode() {
        let candidate = joinCand(category: "爆点2", name: "t7.mp4")
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点2": [candidate]], ingested: [], shapes: [:],
            failureCodeBySourcePath: [:])
        #expect(outcome.resolution[candidate.path]?.failureCode == .notIngested)
        #expect(outcome.notIngestedCount == 1 && outcome.failedIngestCount == 0)
        #expect(!FolderMixFailureCode.notIngested.isSystemic, "素材级新码不许参与短路")
    }

    @Test("JOIN-5 重复交回：同一颗路径两次 ⇒ 取有形状的那条并计数，不静默后写覆盖")
    func duplicateIngestPrefersShapedRowAndCounts() {
        let candidate = joinCand(category: "爆点", name: "钩子A.mp4")
        let dead = UUID()
        let live = UUID()
        let segmentID = UUID()
        // 顺序故意"先坏后好"：后写覆盖的写法会选中 dead，那条方案就建不出来
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: dead),
                       FolderMixIngestedRow(sourcePath: candidate.path, videoID: live)],
            shapes: [dead: FolderMixRowShape(videoID: dead, wholeClipSegmentID: nil, filePresent: true),
                     live: FolderMixRowShape(videoID: live, wholeClipSegmentID: segmentID, filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(outcome.segmentIDByKey[candidate.identityKey] == segmentID)
        #expect(outcome.duplicateIngestCount == 1, "重复必须被数出来（>0 不算错，但必须看得见）")
        #expect(outcome.ingestedCount == 2)
        // 反过来交一次（先好后坏）必须同解 —— 结果不许跟着数组顺序漂
        let reversed = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: live),
                       FolderMixIngestedRow(sourcePath: candidate.path, videoID: dead)],
            shapes: [dead: FolderMixRowShape(videoID: dead, wholeClipSegmentID: nil, filePresent: true),
                     live: FolderMixRowShape(videoID: live, wholeClipSegmentID: segmentID, filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(reversed == outcome, "同一批数据换个顺序就变结果 ⇒ 建出来的方案会随枚举顺序漂")
    }

    @Test("JOIN-6 只认入库交回的那批：同名但没交回的候选不许命中（不许拿全库大表或名字兜底）")
    func sameNameNotIngestedDoesNotResolve() {
        let ingestedOne = joinCand(category: "爆点", name: "钩子A.mp4")
        let other = joinCand(category: "卖点", name: "钩子A.mp4")   // 同名、不同目录、没入库
        let videoID = UUID()
        let segmentID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [ingestedOne], "卖点": [other]],
            ingested: [FolderMixIngestedRow(sourcePath: ingestedOne.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: segmentID, filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(outcome.resolution[ingestedOne.path]?.isUsable == true)
        #expect(outcome.resolution[other.path]?.failureCode == .notIngested,
                "按名字兜底会把这两颗同名素材并成一条 —— 那正是「替错素材」的形状")
        #expect(outcome.hitCount == 1 && outcome.notIngestedCount == 1)
    }

    @Test("JOIN-7 分界判据：同内容、不同文件名（去重命中那行叫别的名字）照样解析成功")
    func sameContentDifferentFileNameStillResolves() {
        // 现场：卖点/同款素材.mp4 与 爆点/钩子A.mp4 内容相同 ⇒ 入库走去重命中，
        // 库里那一行的 name 是第一次引入它的文件名（钩子A.mp4），
        // 而这一侧的候选叫「同款素材.mp4」。名字键在这里必然落空；记账键不受影响。
        let candidate = joinCand(category: "卖点", name: "同款素材.mp4")
        let rowLibraryName = "钩子A.mp4"
        let videoID = UUID()
        let segmentID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["卖点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: segmentID, filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(candidate.name != rowLibraryName, "夹具前提：两侧名字确实不同")
        #expect(outcome.resolution[candidate.path]?.isUsable == true,
                "这条腿就是甲案与乙案的分界：任何按名字反查的写法在这里必红")
        #expect(outcome.segmentIDByKey[candidate.identityKey] == segmentID)
    }

    @Test("TC-J7 整批中止时不许逐条谎报「入库后没找到」（磁盘预检没过报的是中止档）")
    func batchAbortAttributedToAbortCodeNotNotIngested() {
        let candidates = [joinCand(category: "爆点", name: "a.mp4"),
                          joinCand(category: "爆点", name: "b.mp4")]
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": candidates], ingested: [], shapes: [:],
            failureCodeBySourcePath: [:], batchAbortCode: .diskShortfall)
        #expect(Set(outcome.resolution.values.compactMap(\.failureCode)) == [.diskShortfall])
        #expect(outcome.notIngestedCount == 0, "50 条「没找到」会把人引去查素材，而真因是磁盘")
        #expect(outcome.failedIngestCount == 2)
    }

    @Test("TC-J8 摘掉的行不进取号账本：失败批不消耗组合，素材补齐后重跑同一批能全出")
    func shortfallsDoNotConsumeCombinations() throws {
        let rows = try draw(3)
        var resolution = allUsable()
        // 「钩子」这一类整类坏掉 ⇒ 每条抽中的行都含一格坏素材，替不动只能全摘
        for candidate in fixtures["钩子"] ?? [] {
            resolution[candidate.identityKey] = .failed(candidate.identityKey, .notIngested)
        }
        let ledger = FolderMixComboLedger()
        var rng = SplitMix64(seed: 11)
        let failed = FolderMixGeneratePlanner.resolve(rows: rows,
                                                      candidatesByCategory: fixtures,
                                                      resolution: resolution,
                                                      space: spaceOf(), ledger: ledger, rng: &rng)
        #expect(failed.rows.isEmpty, "整类不可用 ⇒ 一条都不该留下")
        #expect(failed.shortfalls.count == rows.count)
        #expect(ledger.issuedCount == 0, "没成功却记账 = 这批组合被白白烧掉（FMX-07 的另一半）")

        // 同一颗账本、同一批行，只把 resolution 修好 ⇒ 三条都要出得来
        var rng2 = SplitMix64(seed: 11)
        let healed = FolderMixGeneratePlanner.resolve(rows: rows,
                                                      candidatesByCategory: fixtures,
                                                      resolution: allUsable(),
                                                      space: spaceOf(), ledger: ledger, rng: &rng2)
        #expect(healed.rows.count == rows.count,
                "上一批失败如果消耗过签名，这里就会少几条 —— 那才是真机那种「越试越少」")
        #expect(healed.rows.map(\.ordinal) == rows.map(\.ordinal))
    }

    // ── JOIN-20…22：可用性进资格（计划 2026-10-22 第三轮 笔 K4，决议 K6/K7）──

    @Test("JOIN-20 交回里有这行、但库内文件不在盘上 ⇒ 报 materialMissing，不算命中")
    func missingLibraryCopyIsNotUsable() {
        let candidate = joinCand(category: "爆点", name: "钩子A.mp4")
        let videoID = UUID()
        let segmentID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: segmentID,
                                                filePresent: false)],
            failureCodeBySourcePath: [:])
        #expect(outcome.hitCount == 0, "文件都没了却算命中 ⇒ 建出来的方案导出必坏（比出不来更坏）")
        #expect(outcome.missingFileCount == 1)
        #expect(outcome.resolution[candidate.path]?.failureCode == .materialMissing)
        #expect(outcome.segmentIDByKey.isEmpty, "缺失档不许把段 id 递出去")
    }

    @Test("JOIN-21 缺失与无整片段同时成立 ⇒ 报缺失（先因先报，防归因再次错位）")
    func missingBeatsNoWholeClipTier() {
        let candidate = joinCand(category: "爆点", name: "钩子A.mp4")
        let videoID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: nil,
                                                filePresent: false)],
            failureCodeBySourcePath: [:])
        #expect(outcome.resolution[candidate.path]?.failureCode == .materialMissing,
                "报成 noWholeClipSegment 会把人引去查分镜导入通路，而真因是文件没了")
        #expect(outcome.noWholeClipCount == 0 && outcome.missingFileCount == 1)
    }

    @Test("JOIN-22 回归腿：filePresent 恒真时读数须与接进可用性之前逐字相同")
    func presentRowsAreUnaffected() {
        let candidate = joinCand(category: "爆点", name: "钩子A.mp4")
        let videoID = UUID()
        let segmentID = UUID()
        let outcome = FolderMixLibraryJoin.resolve(
            candidatesByCategory: ["爆点": [candidate]],
            ingested: [FolderMixIngestedRow(sourcePath: candidate.path, videoID: videoID)],
            shapes: [videoID: FolderMixRowShape(videoID: videoID, wholeClipSegmentID: segmentID,
                                                filePresent: true)],
            failureCodeBySourcePath: [:])
        #expect(outcome.hitCount == 1 && outcome.missingFileCount == 0
                    && outcome.notIngestedCount == 0 && outcome.noWholeClipCount == 0,
                "把可用的一条误判成缺失 ⇒ 可用性这一腿自己就成了新的错源")
    }

}
