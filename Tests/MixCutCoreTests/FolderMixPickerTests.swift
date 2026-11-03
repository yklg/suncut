import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// FolderMixPicker 判据（组合级不重复 · 第二轮改判）
// 计划真源：~/.qoder-cn/plans/northern-slope-widgeon.md A 段 + 「测试覆盖差距矩阵」FMX-01…11
//          台账：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md D23/D30/D31/D35/D36
//
// ## 口径变了，所以这一族大半重写
//
// 「不重复」从**素材级会话内不回放**改成**组合级**：同一素材允许在不同条里复现，
// 整行「类别→素材」搭配才必须互不相同。旧机理（游标 + 跳过规则 + 两级账本 + Feistel
// + cycle-walking）换成 **Floyd 无放回抽样 + 混合基数解码 + 素材签名账本**。
//
// 〔已作废的旧用例，别再照抄回来〕P2/P2b/P3/P3b（R2/R3 素材级不回放族）、
// P6/P6b（默认档下"同 id 落两类"不可达，断言搬到行内撞身份那一族）、
// P7「前缀一致」（Floyd 每批独立随机集，数学上不可能成立）、
// P7c/P10/P10b/P10c/P10d（min → 乘积、used → 签名集）。
// 文件头原来那段"批内 resetCategories 恒为空"的推导整段作废 —— 那颗字段已经不存在了。
//
// ## 这一族的特殊之处：被测对象是随机源
//
// 判据一律写成「性质 + 同解对照」，不写「某个 seed 抽出第几条」这种 golden 值 ——
// 只有 P12/P13/P13b 那三条锁 SplitMix64 本身，必须逐字钉住（从旧 private 副本迁移时
// 无从证明同算法）。
//
// ## 判别式设计（防"判据因错误原因通过"）
//
//   • FMX-01 必须**发满整个空间**（`radix=[2,2]` 只有 4 个组合）—— 抽样测不出"耗尽"这条；
//   • FMX-02 钉的是**随机数消耗次数**（Floyd 的构造性保证 2k−1，与 population 无关）：
//     实现被换回朴素"重取到不重复为止"时，这一条必红，且不需要读任何内部状态；
//   • FMX-03/04 钉**分布**（成员均匀 + 截断无偏）。容差按 6σ 给，见函数里的注释；
//     这两条是 D35 那条外部经验的唯一机器证据 —— 打散被删掉时界面上只会表现为
//     "翻来覆去就开头那几个"，人眼要看好几轮才发现。
// ============================================================================

struct FolderMixPickerTests {

    // MARK: 夹具

    /// 默认档：identityKey = path（一个文件只有一个父目录 ⇒ 跨目录同内容算两条）。
    private func cand(_ key: String, _ category: String,
                      duration: Double? = 10, path: String? = nil) -> FolderMixCandidate {
        FolderMixCandidate(identityKey: key, category: category, name: "\(key).mp4",
                           path: path ?? "\(category)/\(key).mp4", duration: duration)
    }

    private func pool(_ pairs: [(String, [String])]) -> [String: [FolderMixCandidate]] {
        var out: [String: [FolderMixCandidate]] = [:]
        for (category, keys) in pairs {
            out[category] = keys.map { cand($0, category) }
        }
        return out
    }

    /// 钩子 3 / 信任背书 2 / 卖点 1 ⇒ 乘积 = 6；再加一个空类（不占额度）
    private var fixtures: [String: [FolderMixCandidate]] {
        pool([("钩子", ["h1", "h2", "h3"]), ("信任背书", ["t1", "t2"]),
              ("卖点", ["m1"]), ("空类", [])])
    }
    private let ordered = ["钩子", "信任背书", "卖点"]
    private var allEnabled: Set<String> { ["钩子", "信任背书", "卖点", "空类"] }

    private func space(_ source: [String: [FolderMixCandidate]]? = nil,
                       cats: [String]? = nil,
                       enabled: Set<String>? = nil) -> FolderMixComboSpace {
        FolderMixComboSpace(candidatesByCategory: source ?? fixtures,
                            orderedCategories: cats ?? ordered,
                            enabled: enabled ?? allEnabled)
    }

    private func batch(count: Int,
                       s: FolderMixComboSpace,
                       ledger: FolderMixComboLedger = FolderMixComboLedger(),
                       seed: UInt64 = 0x1234_5678_9ABC_DEF0,
                       from source: [String: [FolderMixCandidate]]? = nil) throws -> FolderMixBatchResult {
        var rng = SplitMix64(seed: seed)
        return try FolderMixPicker.drawMany(candidatesByCategory: source ?? fixtures,
                                            space: s, ledger: ledger, count: count, rng: &rng)
    }

    // MARK: R1 同 seed 幂等

    @Test("P1 同 seed 同输入 ⇒ 逐字同解（含 shortfall 清单与每行 ordinal）")
    func sameSeedSameAnswer() throws {
        let a = try batch(count: 4, s: space(), seed: 42)
        let b = try batch(count: 4, s: space(), seed: 42)
        #expect(a.rows.map(\.ordinal) == b.rows.map(\.ordinal))
        #expect(a.rows.map(\.signature) == b.rows.map(\.signature))
        #expect(a.shortfall.map(\.reason) == b.shortfall.map(\.reason))
        // 换 seed 必须真的换解（否则"同解"是恒真）
        let c = try batch(count: 4, s: space(), seed: 43)
        #expect(c.rows.map(\.signature) != a.rows.map(\.signature),
                "换 seed 还逐字同解 ⇒ 抽样根本没用到 rng")
    }

    // MARK: R4 空类与未勾选类

    @Test("P4 空类不进乘积、不出现在 picks；它在排列里的位置不改变其他类别取数")
    func emptyCategoryTakesNoQuota() throws {
        let withEmptyFirst = space(cats: ["空类", "钩子", "信任背书", "卖点"])
        let withEmptyLast = space(cats: ["钩子", "信任背书", "卖点", "空类"])
        #expect(withEmptyFirst.total == 6 && withEmptyLast.total == 6)
        #expect(withEmptyFirst.skippedEmpty == ["空类"])
        let rows = try batch(count: 3, s: withEmptyFirst, seed: 7).rows
        #expect(rows.allSatisfy { $0.picks.count == 3 }, "空类混进了 picks")
        #expect(rows.allSatisfy { !$0.picks.contains { $0.category == "空类" } })
        // 同一 seed、同一参与集 ⇒ 空类站哪儿都不该改变解（R4 的可复现面）
        let sameSeedAtEnd = try batch(count: 3, s: withEmptyLast, seed: 7).rows
        #expect(sameSeedAtEnd.map(\.signature) == rows.map(\.signature))
    }

    @Test("P4c 取消勾选一个类别 ⇒ 乘积掉到剩余各类之积，且该类的 picks 一格不剩")
    func uncheckingShrinksSpace() throws {
        #expect(space().total == 6)
        let off = space(enabled: ["钩子", "信任背书"])
        #expect(off.total == 6)                       // 3×2，卖点被剔出乘积
        #expect(off.excluded == ["卖点"])
        let rows = try batch(count: 2, s: off, seed: 11).rows
        #expect(rows.allSatisfy { $0.picks.count == 2 })
        #expect(rows.allSatisfy { !$0.picks.contains { $0.category == "卖点" } })
    }

    // MARK: R5 顺序

    @Test("P5 picks 顺序恒等于参与集顺序，与候选池顺序无关")
    func picksFollowParticipantOrder() throws {
        let shuffledPool = pool([("钩子", ["h3", "h1", "h2"]), ("信任背书", ["t2", "t1"]),
                                 ("卖点", ["m1"])])
        let rows = try batch(count: 4, s: space(shuffledPool), seed: 5, from: shuffledPool).rows
        for row in rows {
            #expect(row.picks.map(\.category) == ["钩子", "信任背书", "卖点"])
        }
        // 反序排列 ⇒ picks 顺序跟着反（拼接顺序就是用户排的序，D4）
        let reversed = try batch(count: 3, s: space(cats: ["卖点", "信任背书", "钩子"]), seed: 5).rows
        #expect(reversed.allSatisfy { $0.picks.map(\.category) == ["卖点", "信任背书", "钩子"] })
    }

    // MARK: D23 组合级不重复（旧 P7b 的期望值在这里**反转**）

    @Test("P7b 一批之内组合两两不同，但**允许**同一素材跨条复现（旧断言的反面）")
    func combosAreDistinctMaterialsMayRepeat() throws {
        // 3×2×1 = 6 个组合，发 6 条 ⇒ 签名两两不同
        let rows = try batch(count: 6, s: space(), seed: 99).rows
        #expect(rows.count == 6)
        let signatures = rows.map(\.signature)
        #expect(Set(signatures).count == 6, "组合出现重复：\(signatures)")
        // 卖点只有 1 条素材 ⇒ 它必然在 6 条里复现 6 次。旧口径会把这判成缺陷。
        let maiCount = rows.filter { $0.picks.contains { $0.category == "卖点" } }.count
        #expect(maiCount == 6, "卖点类被当成'已用尽'而少发了条数 ⇒ 素材级不回放又回来了")
    }

    @Test("FMX-01 小空间发满 ⇒ 恰好 M 条互不相同，第 M+1 条开始报耗尽（抽样测不出这条）")
    func exhaustWholeSpace() throws {
        let tiny = pool([("A", ["a1", "a2"]), ("B", ["b1", "b2"])])   // M = 4
        let s = space(tiny, cats: ["A", "B"], enabled: ["A", "B"])
        #expect(s.total == 4)
        var ledger = FolderMixComboLedger()
        var seen = Set<[String]>()
        var issued = 0
        var rng = SplitMix64(seed: 2026)
        while let row = FolderMixPicker.draw(candidatesByCategory: tiny, space: s,
                                             ledger: ledger, rng: &rng) {
            issued += 1
            _ = ledger.commit(signature: row.signature)
            seen.insert(row.signature)
            #expect(issued <= 4, "已发出超过组合总数 ⇒ 不重复被击穿（第 \(issued) 条）")
        }
        #expect(issued == 4, "发满前就停了：实得 \(issued)，应 4")
        #expect(seen.count == 4)
        #expect(ledger.remaining(in: s) == 0)
        let over = try? batch(count: 5, s: s, seed: 1)
        #expect(over == nil, "count > 组合总数必须走拒绝档，不许静默给 4 条")
    }

    // MARK: FMX-02 终止性（Floyd 的构造性保证）

    /// 计数型随机源：把"消耗了几次"变成可断言的读数（`FolderMixRandom` 存在的唯一理由）。
    private final class CountingRandom: FolderMixRandom {
        var calls = 0
        private var inner = SplitMix64(seed: 0xB0_00)
        func nextInt(upperBound: Int) -> Int {
            calls += 1
            return inner.nextInt(upperBound: upperBound)
        }
    }

    @Test("FMX-02 随机数消耗 = 2k−1 次，且与 population 无关（朴素重取法在这里必红）")
    func floydConsumesExactlyTwoKMinusOne() {
        for population in [5, 50, 5_000, 20_000] {
            for k in [1, 3, 5] {
                guard k <= population else { continue }
                var rng = CountingRandom()
                let out = FolderMixPicker.sampleDistinctOrdinals(count: k, population: population,
                                                                 rng: &rng)
                #expect(out.count == k)
                #expect(Set(out).count == k, "同批出现重复序号：\(out)")
                // k 次取样 + (k−1) 次 Fisher-Yates 打散
                #expect(rng.calls == 2 * k - 1,
                        "population=\(population) k=\(k) 时消耗 \(rng.calls) 次，应 \(2 * k - 1) 次 —— 消耗随 population 涨就是换回了「重取到不重复为止」")
            }
        }
    }

    @Test("FMX-02b 空/越界入参不发随机数")
    func degenerateInputsUseNoRandomness() {
        var rng = CountingRandom()
        let zero = FolderMixPicker.sampleDistinctOrdinals(count: 0, population: 10, rng: &rng)
        let over = FolderMixPicker.sampleDistinctOrdinals(count: 11, population: 10, rng: &rng)
        let emptyPop = FolderMixPicker.sampleDistinctOrdinals(count: 5, population: 0, rng: &rng)
        #expect(zero.isEmpty)
        #expect(over.isEmpty, "count > population 时不许硬抽")
        #expect(emptyPop.isEmpty)
        #expect(rng.calls == 0, "退化入参却消耗了 \(rng.calls) 次随机数")
    }

    // MARK: FMX-03/04 分布（D35 打散腿的机器证据）

    @Test("FMX-03 大样本下每个候选被选中的次数同阶（成员分布均匀）")
    func membershipIsUniform() throws {
        // 单类 4 个候选 ⇒ M = 4，一次发满 4 条；跑 200 个 seed ⇒ 每个候选期望 200 次
        let one = pool([("A", ["a1", "a2", "a3", "a4"])])
        let s = space(one, cats: ["A"], enabled: ["A"])
        #expect(s.total == 4)
        var counts: [String: Int] = [:]
        for seed: UInt64 in stride(from: 1 as UInt64, through: 200, by: 1) {
            var rng = SplitMix64(seed: seed)
            let batch = try FolderMixPicker.drawMany(candidatesByCategory: one, space: s,
                                                     ledger: FolderMixComboLedger(),
                                                     count: 4, rng: &rng)
            #expect(batch.rows.count == 4, "发满 4 条却只给了 \(batch.rows.count) 条")
            for row in batch.rows {
                for pick in row.picks { counts[pick.identityKey, default: 0] += 1 }
            }
        }
        let total = counts.values.reduce(0, +)
        #expect(total == 200 * 4, "样本量对不上：\(total)")
        let expected = total / 4
        for key in ["a1", "a2", "a3", "a4"] {
            let got = counts[key] ?? 0
            // ±25% 的宽容差：这里要抓的是"偏向文件夹开头"那种量级（成倍差），不是抽样噪声
            #expect(abs(got - expected) < expected / 4,
                    "\(key) 被选中 \(got) 次，均值 \(expected) —— 偏离超过 25%")
        }
    }

    @Test("FMX-04 截断无偏：序号 0（每类第一条）不是常客，且小 k 时前缀不被优先发出")
    func truncationOrderIsUnbiased() throws {
        // 4 类各 2 条 ⇒ M=16；每次只要 1 条。若不打散，Floyd 的升序输出会让
        // "ordinal 小"的组合（= 靠前的候选）在截断时系统性地先出现。
        let bin = pool([("A", ["a1", "a2"]), ("B", ["b1", "b2"]),
                        ("C", ["c1", "c2"]), ("D", ["d1", "d2"])])
        let s = space(bin, cats: ["A", "B", "C", "D"], enabled: ["A", "B", "C", "D"])
        #expect(s.total == 16)
        var firstSlotHits = 0
        var draws = 0
        for seed: UInt64 in stride(from: 1 as UInt64, through: 400, by: 1) {
            var rng = SplitMix64(seed: seed &* 7_919 &+ 13)
            guard let row = FolderMixPicker.draw(candidatesByCategory: bin, space: s,
                                                 ledger: FolderMixComboLedger(),
                                                 rng: &rng) else { continue }
            draws += 1
            // 每一类都抽到"该类的第 1 条"⇒ 就是 decode(0) 那一族组合
            if row.picks.allSatisfy({ $0.identityKey.hasSuffix("1") }) { firstSlotHits += 1 }
        }
        #expect(draws == 400)
        // 期望 400/16 = 25 次。没打散的话这一格会接近 400（ordinal 0 每次都是第一个候选）。
        #expect(firstSlotHits < draws / 8,
                "「全是各类第一条」的组合出现 \(firstSlotHits)/\(draws) 次 ⇒ 截断顺序有偏（打散腿失效）")
    }

    // MARK: FMX-05 双射

    @Test("P17 序号 → 行的公开入口与 drawMany 共用同一份解码（rehydrate 走的这颗）")
    func rowFromOrdinalMatchesTheDrawnRow() throws {
        let s = space()
        var seed = SplitMix64(seed: 7)
        let batch = try FolderMixPicker.drawMany(candidatesByCategory: fixtures, space: s,
                                                 ledger: FolderMixComboLedger(), count: 4,
                                                 rng: &seed)
        for row in batch.rows {
            #expect(FolderMixPicker.row(forOrdinal: row.ordinal, candidatesByCategory: fixtures,
                                        space: s) == row,
                    "同一序号在两条路径上解出不同的行 ⇒ 持久化回来的预览与当场抽的不是同一批")
        }
        // 越界与空空间都必须给 nil（不许取模回绕 —— 那是把旧序号挂到别的素材上）
        #expect(FolderMixPicker.row(forOrdinal: s.total, candidatesByCategory: fixtures, space: s) == nil)
        #expect(FolderMixPicker.row(forOrdinal: -1, candidatesByCategory: fixtures, space: s) == nil)
    }

    @Test("FMX-05 小空间全枚举：decode 两两不同、encode 是它的逆、越界给 nil 不取模")
    func bijectionRoundTrips() {
        let s = space()
        #expect(s.total == 6)
        var decoded = [[Int]]()
        for index in 0..<s.total {
            guard let ordinals = s.decode(index: index) else {
                Issue.record("decode(\(index)) 意外为 nil"); continue
            }
            decoded.append(ordinals)
            #expect(s.encode(ordinals: ordinals) == index, "encode∘decode 不闭合于 \(index)")
        }
        #expect(Set(decoded).count == 6, "decode 不是单射：\(decoded)")
        #expect(s.decode(index: 6) == nil, "越界必须 nil，取模会把越界伪装成合法解")
        #expect(s.decode(index: -1) == nil)
        #expect(s.encode(ordinals: [0, 0, 2]) == nil, "radix 越界的 ordinals 不该被编码")
        // 混合基数的位序：第一个参与类别是最高位 ⇒ decode(0) 全是 0
        #expect(s.decode(index: 0) == [0, 0, 0])
        #expect(s.decode(index: 5) == [2, 1, 0])
    }

    @Test("P16 组合总数饱和：溢出给 Int.max + isSaturated，绝不回绕成负数")
    func productSaturatesInsteadOfWrapping() {
        // 2.1e6 的三次方 ≈ 9.26e18 > Int.max(9.22e18) ⇒ 恰好越界
        let big = [2_100_000, 2_100_000, 2_100_000]
        let got = FolderMixComboSpace.product(ofRadixes: big)
        #expect(got.saturated, "该饱和却没报")
        #expect(got.total == Int.max, "饱和值应是 Int.max，实得 \(got.total)")
        // 负腿：回绕（`&*`）会给出一个**正的小数或负数**，两种都比"报不准"危险
        var wrapped = 1
        for r in big { wrapped = wrapped &* r }
        #expect(wrapped != Int.max, "回绕值与饱和值相同 ⇒ 这条判据抓不到 N4")
        // 没越界时必须精确
        let exact = FolderMixComboSpace.product(ofRadixes: [20, 20, 10, 5])
        #expect(exact.total == 20_000 && !exact.saturated)
        #expect(FolderMixComboSpace.product(ofRadixes: []).total == 0)
    }

    @Test("P16b 参与集为空（全没勾 / 全空类）⇒ total 0，且 drawMany 走拒绝档不是崩")
    func emptyParticipantSetIsZeroNotCrash() {
        let s = space(enabled: [])
        #expect(s.total == 0 && s.participants.isEmpty)
        var rng = SplitMix64(seed: 1)
        do {
            let got = try FolderMixPicker.drawMany(candidatesByCategory: fixtures, space: s,
                                                   ledger: FolderMixComboLedger(),
                                                   count: 1, rng: &rng)
            Issue.record("空参与集该抛 noParticipants，实得 \(got.rows.count) 行")
        } catch let error as FolderMixPickerError {
            #expect(error == .noParticipants, "抛错了档：\(error)")
        } catch { Issue.record("抛的不是 FolderMixPickerError：\(error)") }
    }

    // MARK: FMX-06/07/08 签名账本

    @Test("FMX-06 跨批不重复：先 commit 一批，再以同 seed 重抽 ⇒ 与新批零交集")
    func committedSignaturesAreExcludedAcrossBatches() throws {
        var ledger = FolderMixComboLedger()
        let first = try batch(count: 3, s: space(), seed: 5)
        #expect(first.rows.count == 3)
        for row in first.rows { _ = ledger.commit(signature: row.signature) }
        // 同 seed 再来一次：Floyd 会给出同一批**序号**，但签名层必须把它们全挡掉
        let second = try batch(count: 3, s: space(), ledger: ledger, seed: 5)
        let repeated = Set(second.rows.map(\.signature)).intersection(Set(first.rows.map(\.signature)))
        #expect(repeated.isEmpty, "同 seed 重抽把已发出的组合又发了一遍：\(repeated)")
    }

    @Test("FMX-07 预览不消耗组合：drawMany 只读账本，remaining 只随 commit 变化")
    func previewDoesNotConsume() throws {
        var ledger = FolderMixComboLedger()
        let s = space()
        let before = ledger.remaining(in: s)
        for _ in 0..<5 {
            let b = try batch(count: 3, s: s, ledger: ledger, seed: 8)
            #expect(ledger.issuedCount == 0, "drawMany 写了账本 ⇒ 预览开始消耗组合")
            #expect(ledger.remaining(in: s) == before)
            #expect(b.rows.count == 3)
        }
        for row in try batch(count: 3, s: s, ledger: ledger, seed: 8).rows {
            _ = ledger.commit(signature: row.signature)
        }
        #expect(ledger.issuedCount == 3)
        #expect(ledger.remaining(in: s) == before - 3,
                "remaining 不是由签名集大小推的（实得 \(ledger.remaining(in: s))）")
    }

    @Test("FMX-08 commit 幂等：重复签名不涨计数")
    func commitIsIdempotent() {
        var ledger = FolderMixComboLedger()
        let first = ledger.commit(signature: ["a1", "b1", "m1"])
        let second = ledger.commit(signature: ["a1", "b1", "m1"])
        #expect(first)
        #expect(!second, "重复 commit 该返回 false")
        #expect(ledger.issuedCount == 1)
        #expect(ledger.contains(signature: ["a1", "b1", "m1"]))
        #expect(!ledger.contains(signature: ["a1", "b1"]))
    }

    // MARK: R8 拒绝档

    @Test("P8 三档拒绝：count<1、无参与类别、count>组合总数 —— 全部抛错不静默截断")
    func rejectionTiers() {
        let r0 = try? batch(count: 0, s: space(), seed: 1)
        let r1 = try? batch(count: 1, s: space(enabled: []), seed: 1)
        let r7 = try? batch(count: 7, s: space(), seed: 1)          // M = 6
        #expect(r0 == nil, "count<1 没被拒")
        #expect(r1 == nil, "无参与类别没被拒")
        #expect(r7 == nil, "count>组合总数没被拒")
        do {
            _ = try batch(count: 7, s: space(), seed: 1)
            Issue.record("超限没抛错")
        } catch let error as FolderMixPickerError {
            guard case .countExceedsCombinationSpace(let requested, let total) = error else {
                Issue.record("抛错了档：\(error)"); return
            }
            #expect(requested == 7 && total == 6)
        } catch { Issue.record("抛的不是 FolderMixPickerError：\(error)") }
    }

    @Test("P8b 边界恰好等于组合总数时放行（边界不是拒绝）")
    func exactTotalIsAllowed() throws {
        let rows = try batch(count: 6, s: space(), seed: 3).rows
        #expect(rows.count == 6)
    }

    @Test("FMX-11 单次抽取超硬预算 ⇒ 先拒绝，不先分配")
    func perDrawBudgetRejectsFirst() {
        let big = pool([("A", (1...9).map { "a\($0)" }), ("B", (1...9).map { "b\($0)" }),
                        ("C", (1...9).map { "c\($0)" }), ("D", (1...9).map { "d\($0)" })])
        let s = space(big, cats: ["A", "B", "C", "D"], enabled: ["A", "B", "C", "D"])
        #expect(s.total > FolderMixLimits.maxRowsPerDraw)
        var rng = SplitMix64(seed: 1)
        do {
            _ = try FolderMixPicker.drawMany(candidatesByCategory: big, space: s,
                                             ledger: FolderMixComboLedger(),
                                             count: FolderMixLimits.maxRowsPerDraw + 1, rng: &rng)
            Issue.record("超预算却没拒")
        } catch let error as FolderMixPickerError {
            guard case .tooManyRowsPerDraw(let requested, let budget) = error else {
                Issue.record("抛错了档：\(error)"); return
            }
            #expect(requested == FolderMixLimits.maxRowsPerDraw + 1 && budget == FolderMixLimits.maxRowsPerDraw)
        } catch { Issue.record("抛的不是 FolderMixPickerError：\(error)") }
    }

    // MARK: D31 精确识别两态

    @Test("P14 精确识别：同内容跨目录 ⇒ 默认档 radix 不掉；行内撞身份的行不发、记进差额")
    func preciseIdentityCollidesOnlyWithinRow() throws {
        // 口播/20 与 展示/20 是同一内容（同一个 identityKey），各在自己类别里
        let shared = "H-DUP"
        let source: [String: [FolderMixCandidate]] = [
            "口播": [cand("a1", "口播"), cand(shared, "口播", path: "口播/20.mp4")],
            "展示": [cand("b1", "展示"), cand(shared, "展示", path: "展示/20.mp4")],
        ]
        let s = space(source, cats: ["口播", "展示"], enabled: ["口播", "展示"])
        // 类内去重 ⇒ 每类仍是 2 条 ⇒ 组合总数 4，**不因为跨目录重复而掉**（R49 的口径）
        #expect(s.total == 4, "跨目录同内容把 radix 打掉了 ⇒ 与 D31 的类内口径不符（实得 \(s.total)）")

        // 4 个组合里有 1 个是"两边都取那条重复素材"⇒ 它不许被发出去，要被记进差额
        var emittedDupes = 0
        var collisionNotes = 0
        for seed: UInt64 in 1..<300 {
            var rng = SplitMix64(seed: seed &* 31 &+ 7)
            let batch = try FolderMixPicker.drawMany(candidatesByCategory: source, space: s,
                                                     ledger: FolderMixComboLedger(),
                                                     count: 4, rng: &rng)
            for row in batch.rows where Set(row.picks.map(\.identityKey)).count != row.picks.count {
                emittedDupes += 1
            }
            collisionNotes += batch.shortfall.filter { !$0.categories.isEmpty }.count
        }
        #expect(emittedDupes == 0, "把'同一行两段同素材'发了出去 \(emittedDupes) 次 ⇒ R6 失效")
        #expect(collisionNotes > 0, "撞身份的组合被静默吞掉了：既没发也没报（差额清单恒空）")

        // 极端形状：两个类别只有同一条素材 ⇒ 唯一组合就是撞的 ⇒ 必须"0 条 + 逐条原因"
        let onlyShared: [String: [FolderMixCandidate]] = [
            "口播": [cand(shared, "口播", path: "口播/20.mp4")],
            "展示": [cand(shared, "展示", path: "展示/20.mp4")],
        ]
        let os = space(onlyShared, cats: ["口播", "展示"], enabled: ["口播", "展示"])
        #expect(os.total == 1)
        var rng2 = SplitMix64(seed: 5)
        let alone = try FolderMixPicker.drawMany(candidatesByCategory: onlyShared, space: os,
                                                 ledger: FolderMixComboLedger(), count: 1, rng: &rng2)
        #expect(alone.rows.isEmpty, "唯一组合会连着放同一段素材，却仍被发了出去")
        #expect(alone.shortfall.contains { $0.reason.contains("行内同素材") },
                "没给原因：\(alone.shortfall.map(\.reason))")
    }

    // MARK: R9 同类替补

    @Test("P9 替补只在同一类别内换素材，其他类别的 picks 逐字不动")
    func substituteStaysWithinCategory() throws {
        let s = space()
        guard let row = try batch(count: 1, s: s, seed: 17).rows.first else {
            Issue.record("抽不出一条"); return
        }
        let before = row
        var ledger = FolderMixComboLedger()
        _ = ledger.commit(signature: row.signature)
        var rng = SplitMix64(seed: 23)
        // 故意替补**中间那一类**（slot 1）：只打 slot 0 的话，"顺手把第 0 类也换了"
        // 这种刀在判据眼里是 no-op（N10 第一轮就是这么漏过去的）。
        guard let after = FolderMixPicker.substitute(row: row, category: "信任背书",
                                                     unusableKeys: [],
                                                     candidatesByCategory: fixtures,
                                                     space: s, ledger: ledger, rng: &rng) else {
            Issue.record("2 条候选里替补不出任何一条"); return
        }
        #expect(after.picks.count == before.picks.count)
        #expect(after.picks[0].identityKey == before.picks[0].identityKey, "钩子类被一起换了")
        #expect(after.picks[2].identityKey == before.picks[2].identityKey, "卖点类被一起换了")
        #expect(after.picks[1].identityKey != before.picks[1].identityKey, "信任背书类没换东西")
        #expect(!ledger.contains(signature: after.signature), "替补出来的组合是已发出过的")
        // 替补后的行必须还能被 encode 回一个合法 ordinal（ordinal 与 picks 同源，不许各算一套）
        let backIntoSpace = (0..<after.picks.count).allSatisfy { after.picks[$0].category == s.participants[$0] }
        #expect(backIntoSpace, "替补把 picks 与参与集的对应关系弄断了")
        #expect(after.ordinal >= 0 && after.ordinal < s.total, "替补后的 ordinal 越界：\(after.ordinal)")
    }

    @Test("P9b 该类已无可用候选 ⇒ 替补返回 nil，由调用方摘行并写明原因")
    func substituteGivesUpWhenCategoryIsEmpty() {
        let s = space()
        let row = FolderMixComboRow(ordinal: 0, picks: [cand("h1", "钩子"), cand("t1", "信任背书"),
                                                        cand("m1", "卖点")])
        var rng = SplitMix64(seed: 3)
        let nil1 = FolderMixPicker.substitute(row: row, category: "钩子",
                                              unusableKeys: ["h1", "h2", "h3"],
                                              candidatesByCategory: fixtures, space: s,
                                              ledger: FolderMixComboLedger(), rng: &rng)
        #expect(nil1 == nil, "整类都被判不可用还硬换")
        let nil2 = FolderMixPicker.substitute(row: row, category: "不存在的类",
                                              unusableKeys: [], candidatesByCategory: fixtures,
                                              space: s, ledger: FolderMixComboLedger(), rng: &rng)
        #expect(nil2 == nil)
    }

    // MARK: 时长口径（决定 6）

    @Test("P15 时长读不到的候选 duration 是 nil，不是 0")
    func unknownDurationIsNilNotZero() throws {
        let source: [String: [FolderMixCandidate]] = [
            "A": [cand("a1", "A", duration: nil), cand("a2", "A", duration: 12)],
        ]
        let s = space(source, cats: ["A"], enabled: ["A"])
        let rows = try batch(count: 2, s: s, seed: 4, from: source).rows
        #expect(rows.contains { $0.picks.contains { $0.duration == nil } },
                "两格都抽完了却没出现未知时长 ⇒ nil 被吃掉了")
        #expect(!rows.contains { $0.picks.contains { $0.duration == 0 } },
                "未知时长被写成了 0 秒")
    }

    // MARK: SplitMix64 算法锁定（逐字不动，迁移同算法的证据）

    @Test("P12 SplitMix64 输出序列逐字锁定（与 ProjectVideoDedupTests 原先那份 private 副本同算法）")
    func splitMix64GoldenStream() {
        var rng = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)
        #expect(rng.nextUInt64() == 0x1619_22C6_45CE_50E8)
        #expect(rng.nextUInt64() == 0xAD76_0CAF_A169_7B60)
        #expect(rng.nextUInt64() == 0x3501_FF44_902C_A50D)
        #expect(rng.nextUInt64() == 0x417C_B9A8_26D8_31DF)
        // 推进过的 rng 与同 seed 的新实例不同解 ⇒ 证明确实是「随调用推进的状态」
        #expect(rng.state != SplitMix64(seed: 0x1234_5678_9ABC_DEF0).state)
    }

    @Test("P13 nextInt 走拒绝采样：upperBound 接近 Int64 上限时与朴素 `%` 必然分叉")
    func nextIntRejectsInsteadOfModuloBias() {
        let ub = 5_000_000_000_000_000_000
        var rng = SplitMix64(seed: 0xCAFE_BABE_1234_5678)
        var got: [Int] = []
        for _ in 0..<6 { got.append(rng.nextInt(upperBound: ub)) }
        // 期望值由 SplitMix64 流 + 拒绝规则（r ≤ UInt64.max − UInt64.max % ub）独立复算得出。
        // ub=5e18 时拒绝率约 18.7%，第 3 个读数就已经分叉：写成 `%` 的实现这里给
        // 0x2FB1BB97C1450A51，而那个流值越过了 limit、本应被拒绝掉。
        let expected: [Int] = [
            0x26EDDCC49192094F, 0x0C8B6C1615753A15, 0x12075D8E2259E5EE,
            0x07FDE05EEF62CDB1, 0x1E0EB45D9BC3820C, 0x3CC434CC83EA4D96,
        ]
        #expect(got == expected)
        #expect(expected[2] != 0x2FB1BB97C1450A51, "分叉对照值要立住：它是朴素 `%` 会给的第 3 个读数")
    }

    @Test("P13b nextInt 值域与覆盖：每个桶都被打到，且从不越界")
    func nextIntRangeAndCoverage() {
        for ub in [1, 2, 3, 7, 64] {
            var rng = SplitMix64(seed: UInt64(ub) &* 7_919)
            var seen = Set<Int>()
            for _ in 0..<2_000 {
                let v = rng.nextInt(upperBound: ub)
                #expect(v >= 0 && v < ub, "upperBound=\(ub) 时越界读数 \(v)")
                seen.insert(v)
            }
            #expect(seen.count == ub, "upperBound=\(ub) 只打到 \(seen.count) 个桶 ⇒ 随机源退化成常数")
        }
    }
}
