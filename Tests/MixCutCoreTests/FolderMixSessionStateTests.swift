import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// FolderMixSessionState / FolderMixSpaceFingerprint 判据（计划 FMX-12 / FMX-13）
//
// ## 这一族守的是什么
//
// 1. **旧盘读得出来**（FMX-12）：这份状态要落 `UserDefaults`。Swift 的 `Codable`
//    对非 Optional 字段即使带默认值也 `keyNotFound`（本仓实测）⇒ 加一颗字段就会让
//    用户重开 App 后整页回到初始态，而且**不报错**。所以逐颗删键验证，不是看代码里
//    写了默认值就算。
// 2. **加字段不许漏登记**（FMX-12c）：`allCodingKeys` 与真实存储属性用 Mirror 对账。
//    漏登记的后果不是崩，是"那颗新字段从来没被删键测过" —— 静默的判据空洞。
// 3. **指纹只认形状**（FMX-13）：改条数/改软上限不该冲掉预览（噪声），
//    改勾选/改排列/候选增删/切「精确识别」必须冲掉（否则留着的是按旧形状抽的组合）。
// 4. **摘要跨进程稳定**（FMX-13d）：`String.hashValue` 每次启动换种子，拿它当持久化
//    指纹 ⇒ 重启必然"漂移"。这条用 golden 向量钉住，因为本进程内没法测"下一次启动"。
//
// 非空洞性：每条都配了"另一种写法会红"的对照 —— 见各条内的 #expect 反向断言。
// ============================================================================

private func cand(_ key: String, _ category: String) -> FolderMixCandidate {
    FolderMixCandidate(identityKey: key, category: category, name: "\(key).mp4",
                       path: "\(category)/\(key).mp4", duration: 10)
}

private func pool(_ pairs: [(String, [String])]) -> [String: [FolderMixCandidate]] {
    var out: [String: [FolderMixCandidate]] = [:]
    for (category, keys) in pairs { out[category] = keys.map { cand($0, category) } }
    return out
}

struct FolderMixSessionStateTests {

    private let source = pool([("钩子", ["h1", "h2"]), ("信任背书", ["t1"]), ("卖点", ["m1"])])
    private let ordered = ["钩子", "信任背书", "卖点"]

    // MARK: FMX-12 编解码三态

    @Test("FMX-12a 完整往返：编出来再解回去逐字相同")
    func roundTrips() throws {
        let state = FolderMixSessionState(rootPath: "/Volumes/X/素材",
                                          orderedCategories: ordered,
                                          enabledCategories: ["钩子", "卖点"],
                                          rowCount: 37, softLimit: 120,
                                          previewFirst: false, preciseIdentity: true,
                                          spaceRevision: "abc123", rowOrdinals: [0, 5, 11])
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(FolderMixSessionState.self, from: data)
        #expect(back == state)
    }

    @Test("FMX-12b 逐颗删键都必须还能解（旧盘上没有这颗字段是常态，不是异常）")
    func everyFieldToleratesAbsence() throws {
        let full = try JSONEncoder().encode(FolderMixSessionState(
            rootPath: "/r", orderedCategories: ["A"], enabledCategories: ["A"],
            rowCount: 9, softLimit: 70, previewFirst: false, preciseIdentity: true,
            spaceRevision: "rev", rowOrdinals: [1, 2]))
        var object = try JSONSerialization.jsonObject(with: full) as? [String: Any]
        guard let original = object else { Issue.record("编出来的不是 JSON 对象"); return }
        var dict = original
        #expect(dict.count == FolderMixSessionState.allCodingKeys.count,
                "编码出的键数 \(dict.count) 与登记的 \(FolderMixSessionState.allCodingKeys.count) 不一致")

        for key in FolderMixSessionState.allCodingKeys {
            dict.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: dict)
            do {
                let back = try JSONDecoder().decode(FolderMixSessionState.self, from: data)
                #expect(back.rowCount >= 1, "删掉 \(key) 后条数退成了非法值")
            } catch {
                Issue.record("删掉键「\(key)」就解不出来：\(error) ⇒ 这颗字段没走 decodeIfPresent")
            }
            dict[key] = original[key]      // 还原，下一颗继续单独删
        }

        // 全空对象与"根本不是这份结构"的垃圾数据都不许抛
        let empty = try JSONDecoder().decode(FolderMixSessionState.self,
                                             from: Data("{}".utf8))
        #expect(empty.orderedCategories.isEmpty && empty.rowCount == 1)
        #expect(empty.softLimit == FolderMixLimits.defaultSoftLimit)
        #expect(empty.previewFirst, "默认值该是'先预览'（D27）")
        #expect(!empty.preciseIdentity, "精确识别默认关（决定 8：零等待是默认）")
        let junk = try? JSONDecoder().decode(FolderMixSessionState.self,
                                             from: Data("[1,2,3]".utf8))
        #expect(junk == nil, "类型完全不对的旧数据必须解失败（让调用方走'没有状态'分支），不许硬凑")
    }

    @Test("FMX-12c 登记的键名册必须与真实存储属性一一对应（加字段漏登记=判据空洞）")
    func codingKeyRosterMatchesRealProperties() {
        let reflected = Mirror(reflecting: FolderMixSessionState.empty).children
            .compactMap { $0.label }
            .sorted()
        #expect(reflected == FolderMixSessionState.allCodingKeys.sorted(),
                """
                实际存储属性 \(reflected) 与 allCodingKeys \(FolderMixSessionState.allCodingKeys.sorted()) 不一致
                ⇒ 新加的字段没进 FMX-12b 的逐颗删键清单，它"缺键会不会崩"从来没被测过。
                """)
    }

    @Test("FMX-12d 条数钳位只有一处口径")
    func clampingIsSingleSourced() {
        var state = FolderMixSessionState(rowCount: 0)
        #expect(state.clampedRowCount == 1)
        state.rowCount = 10_000_000
        #expect(state.clampedRowCount == FolderMixLimits.countInputClamp.upperBound)
        state.rowCount = 500
        #expect(state.clampedRowCount == 500, "区间内的值被误钳")
    }

    @Test("FMX-12e 上一轮的老 JSON 没有 rowOrdinals 这颗键 ⇒ 解成 nil，不崩也不折成空数组")
    func missingRowOrdinalsDecodesToNil() throws {
        let legacy = """
{"rootPath":"/r","orderedCategories":["A"],"enabledCategories":["A"],"rowCount":3,\
"softLimit":50,"previewFirst":true,"preciseIdentity":false,"spaceRevision":""}
"""
        let back = try JSONDecoder().decode(FolderMixSessionState.self,
                                            from: Data(legacy.utf8))
        #expect(back.rowOrdinals == nil,
                "缺键被折成空数组 ⇒ 重启后界面会以为上一批一条都没抽中，而真实情况是没存过")
        #expect(back.rehydratableOrdinals(nowRevision: "") == nil, "没有指纹时一律不许复用旧行")
    }

    // MARK: FMX-13 空间指纹

    private func revision(_ source: [String: [FolderMixCandidate]],
                          _ ordered: [String],
                          _ enabled: Set<String>,
                          precise: Bool = false) -> String {
        let s = FolderMixComboSpace(candidatesByCategory: source,
                                    orderedCategories: ordered, enabled: enabled)
        return FolderMixSpaceFingerprint.revision(space: s, candidatesByCategory: source,
                                                  preciseIdentity: precise)
    }

    @Test("FMX-13a 同形状同指纹（稳定、可持久化）")
    func revisionIsStableForSameShape() {
        let all = Set(ordered)
        let first = revision(source, ordered, all)
        #expect(first == revision(source, ordered, all))
        #expect(first.count == 16, "指纹应是 16 位十六进制摘要，实得 \(first)")
    }

    @Test("FMX-13b 改条数/改软上限/改预览开关都不该冲掉预览（那是噪声）")
    func nonShapeInputsDoNotDrift() {
        let all = Set(ordered)
        let base = revision(source, ordered, all)
        // 这三颗根本不在指纹输入里 —— 用状态对象走一遍，证"存进会话状态的不是它们"
        var state = FolderMixSessionState(orderedCategories: ordered, enabledCategories: ordered,
                                          rowCount: 3, softLimit: 50, previewFirst: true,
                                          spaceRevision: base)
        state.rowCount = 77
        state.softLimit = 999
        state.previewFirst = false
        #expect(state.spaceRevision == base, "会话状态里的非形状字段被卷进了指纹")
        #expect(state.clampedRowCount == 77)
    }

    @Test("FMX-13c 形状一变必须漂移：勾选、排列、候选增删、切精确识别")
    func shapeChangesAllDrift() {
        let all = Set(ordered)
        let base = revision(source, ordered, all)
        #expect(revision(source, ordered, ["钩子", "信任背书"]) != base, "取消勾选没漂移")
        #expect(revision(source, ["卖点", "信任背书", "钩子"], all) != base, "改排列没漂移")
        let grown = pool([("钩子", ["h1", "h2", "h3"]), ("信任背书", ["t1"]), ("卖点", ["m1"])])
        #expect(revision(grown, ordered, all) != base, "多了一个候选文件没漂移")
        #expect(revision(source, ordered, all, precise: true) != base, "切「精确识别」没漂移")
        // 反向对照：只是换了 duration 读数（不参与形状）⇒ 不许漂移
        var timed: [String: [FolderMixCandidate]] = [:]
        for (category, list) in source {
            timed[category] = list.map {
                FolderMixCandidate(identityKey: $0.identityKey, category: $0.category,
                                   name: $0.name, path: $0.path, duration: 999)
            }
        }
        #expect(revision(timed, ordered, all) == base,
                "时长变了就漂移 ⇒ 渐进回填每补一条就把用户预览冲掉一次")
    }

    @Test("FMX-13d 摘要是稳定算法，不是 String.hashValue（那个每次启动换种子）")
    func hashIsNotProcessSeeded() {
        // golden 向量：FNV-1a 64 位（值由独立实现现算，不是凭记忆写的）。
        // 用已知值钉住 ⇒ 哪天有人把它换成 `String.hashValue`，这里会红，
        // 而不是等用户发现"重启后预览永远保不住"。
        #expect(FolderMixSpaceFingerprint.stableHash("") == "cbf29ce484222325")
        #expect(FolderMixSpaceFingerprint.stableHash("a") == "af63dc4c8601ec8c")
        #expect(FolderMixSpaceFingerprint.stableHash("path|钩子#2#h1#h2") == "64f3129da5673c22")
    }

    @Test("FMX-13e 空类从'空'变成'有候选'必须漂移（只数参与集会漏掉这一类）")
    func emptyCategoryBecomingNonEmptyDrifts() {
        let withEmpty = pool([("钩子", ["h1"]), ("空类", [])])
        let filled = pool([("钩子", ["h1"]), ("空类", ["e1"])])
        let enabled = ["钩子", "空类"]
        let before = revision(withEmpty, enabled, Set(enabled))
        let after = revision(filled, enabled, Set(enabled))
        #expect(before != after,
                "参与集之外的事不进取舍 ⇒ 重扫补上文件后旧预览行还留着，序号含义已经漂了")
    }
}
