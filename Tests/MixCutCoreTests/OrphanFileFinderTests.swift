import Foundation
import Testing
@testable import MixCutCore

@Test func orphan_returnsFilesNotReferenced() {
    let onDisk = ["/v/a.mp4", "/v/b.mp4", "/t/x.jpg"]
    let referenced: Set<String> = ["/v/a.mp4", "/t/x.jpg"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4"])
}

@Test func orphan_emptyWhenAllReferenced() {
    let onDisk = ["/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: ["/v/a.mp4"]).isEmpty)
}

@Test func orphan_normalizesTrailingSlashAndCase() {
    // 末尾斜杠 + 大小写差异应视为同一路径（macOS 默认大小写不敏感）
    let onDisk = ["/V/A.mp4/"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced).isEmpty)
}

@Test func orphan_allUnreferencedReturnedInInputOrder() {
    let onDisk = ["/v/b.mp4", "/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: []) == ["/v/b.mp4", "/v/a.mp4"])
}

// MARK: - safeOrphanFiles：破坏性回收的保守入口
// 上面那条是 orphanFiles（纯查询）的既有契约，保持不变；
// 下面几条守的是「GC 何时不该动手」。

@Test func safeOrphan_refusesWhenReferencedEmpty() {
    // 库打不开 / 退到内存模式时，引用集会是空的 —— 此时全删不可逆
    let onDisk = ["/v/a.mp4", "/t/x.jpg"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: []).isEmpty)
}

@Test func safeOrphan_refusesWhenZeroOverlap() {
    // 目录迁移改名的现场：DB 里 34 个路径仍指旧前缀，磁盘已在新目录 → 零交集
    let onDisk = ["/new/Videos/a.mp4", "/new/Thumbnails/x.jpg"]
    let referenced: Set<String> = ["/old/Videos/a.mp4", "/old/Thumbnails/x.jpg"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced).isEmpty)
}

@Test func safeOrphan_stillReclaimsWhenReferenceSetIsTrustworthy() {
    // 反向防线：有交集时照常给出孤儿，不能退化成「永远返回空」的假守卫
    let onDisk = ["/v/a.mp4", "/v/b.mp4", "/v/c.mp4"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4", "/v/c.mp4"])
}

@Test func safeOrphan_overlapCheckHonoursNormalization() {
    // 交集判定必须与 orphanFiles 用同一套归一（大小写 + 末尾斜杠），否则会误判成零交集
    let onDisk = ["/V/A.mp4/", "/v/b.mp4"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4"])
}

@Test func safeOrphan_emptyOnDiskYieldsEmpty() {
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: [], referenced: ["/v/a.mp4"]).isEmpty)
}

// 以下两条沿用仓里较新的约定（TC 号 + 中文标题）；本文件上半段是历史无标题写法，不跟。

@Test("TC-OF-10 素材名带中文与空格不得被误判成孤儿（真仓文件名就是这形状）")
func chineseAndSpaceNamesAreNotOrphans() {
    // 现场形状：~/Library/Application Support/Suncut/Videos/{hash}/视频库 (3).mp4
    let disk = "/Users/x/Library/Application Support/Suncut/Videos/ab12cd/视频库 (3).mp4"
    #expect(OrphanFileFinder.orphanFiles(onDisk: [disk], referenced: [disk]).isEmpty)
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: [disk], referenced: [disk]).isEmpty)
}

@Test("TC-OF-11 NFC 与 NFD 两种写法必须认成同一条路径（钉住「用 Swift 的字符串等价」这个前提）")
func nfcAndNFDAreTheSamePath() {
    // macOS 的 APFS 把落盘文件名正规化成 NFD（é = e + U+0301），而库里的路径可能来自 NFC 的来源
    // （手输、别的机器同步、JSON 里存的原始串）。两种写法若被认成两个文件，后果不是误报而是**数据丢失**：
    // 在用的文件被判成孤儿 ⇒ GC 直接 removeItem。
    //
    // 今天它安全，靠的是 Swift 的 String ==/Hasher 按 **Unicode 正规等价** 比较（不是字节比较）。
    // 这条用例钉的就是这个前提：谁哪天把比较换成 utf8 字节、字典序或自造 folding，它先红。
    let nfc = "/v/caf\u{E9}.mp4"
    let nfd = "/v/cafe\u{301}.mp4"
    #expect(nfc.utf8.count != nfd.utf8.count,
            "夹具若连字节数都一样，本条什么都测不到 ⇒ 先让它红")
    #expect(nfc == nfd, "前提破了：Swift 字符串不再按正规等价比较，下面的孤儿判定也就不安全了")
    #expect(OrphanFileFinder.orphanFiles(onDisk: [nfd], referenced: [nfc]).isEmpty,
            "在用文件被判成孤儿 ⇒ 会被 GC 删掉")
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: [nfd], referenced: [nfc]).isEmpty,
            "保守门的交集判定也不许被编码差异骗成零交集")
}

// MARK: - TC-OF-12：符号链接前缀（仓里另一条回收链已为这件事立过契约）

@Test("TC-OF-12 /var 与 /private/var 是同物：整批拼写差异由零交集门兜住，混合拼写今天仍会误判（红钉）")
func symlinkedSpellingVariants() {
    // macOS 上 /var 是 /private/var 的符号链接。本仓在另一条回收链上踩过并立了契约：
    // `CloneSampleReaper.swift:51/69` —— 路径比较必须走 standardizedFileURL，否则 /private/var 与
    // /var 的差异会误删在用样本（由 CS-2b 钉住）。orphan 这条轴只做「去尾斜杠 + 小写」，没走那颗契约。
    let viaVar = "/var/folders/ab/v/a.mp4"
    let viaPrivate = "/private/var/folders/ab/v/a.mp4"
    let shared = "/v/in_use.mp4"

    // ① 整批都是同物的两种写法（外置卷 / 同步盘 / 迁移未改写的现场）⇒ 库与盘没有共同坐标，
    //    零交集门必须一个都不交给 GC。
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: [viaPrivate], referenced: [viaVar]).isEmpty,
            "全拼写差异下按清单回收会把在用文件删光")

    // ② 混合现场：有一条两边同写法 ⇒ 门放行，于是"同物两种写法"那条被判成孤儿。
    //    这条是**当前真实行为**的取证（不是认可它）：补齐 standardizedFileURL 时它会红，
    //    逼一次摘标 —— 与 TombstoneReadGuardTests 里 withKnownIssue 的用法同一条纪律。
    let orphans = OrphanFileFinder.safeOrphanFiles(
        onDisk: [viaPrivate, shared, "/v/truly_orphan.mp4"], referenced: [viaVar, shared])
    #expect(orphans == [viaPrivate, "/v/truly_orphan.mp4"],
            "今天它俩都被当成孤儿：期望值若变了，说明归一化补了标准化，请连同本条一起改")
    withKnownIssue("normalize 不做 standardizedFileURL ⇒ 同物两种写法被认成两个文件，在用文件进可删清单（对照 CloneSampleReaper 的既有契约）") {
        #expect(!orphans.contains(viaPrivate), "在用文件被判成孤儿 ⇒ GC 会 removeItem 掉它")
    }
}

// MARK: - TC-OF-13 / 14：不变量与门的形状（固定夹具，故意不做随机 property 版）
// 复制 SplitMix64 等于制造第二份真源（WhisperModelCatalogTests.swift:38 记着这条裁定），
// 所以这里用「按下标轮转四种形状」的确定性夹具 —— 同样可复现，且期望值能手算。

/// 四种形状轮转：真孤儿 / 两边同写法 / 只有大小写差 / 只有末尾斜杠差
private func corpus(_ count: Int) -> (onDisk: [String], referenced: Set<String>) {
    var onDisk: [String] = []
    var referenced: Set<String> = []
    for i in 0..<count {
        let base = "/v/\(i).mp4"
        switch i % 4 {
        case 0: onDisk.append(base)                                  // 真孤儿
        case 1: onDisk.append(base); referenced.insert(base)         // 在用，两边同写法
        case 2: onDisk.append("/V/\(i).MP4"); referenced.insert(base) // 只有大小写差
        default: onDisk.append(base + "/"); referenced.insert(base)   // 只有末尾斜杠差
        }
    }
    return (onDisk, referenced)
}

/// 期望值用**测试自己的一把尺子**算，不叫被测函数代劳 —— 否则它归一化写错也测不出（恒真形态）。
private func independentlyNormalized(_ path: String) -> String {
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p.lowercased()
}

@Test("TC-OF-13 不变量：孤儿必是磁盘清单的子集、且与引用集归一后不相交（四种规模同一条尺子）",
      arguments: [1, 4, 12, 200])
func orphanOutputHonoursBothInvariants(_ count: Int) {
    let (onDisk, referenced) = corpus(count)
    let refNorm = Set(referenced.map(independentlyNormalized))
    let orphans = OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced)

    // INV-子集：返回的每个字符串都原样来自输入清单（不返回归一化后的值，也不凭空造路径）
    #expect(Set(orphans).isSubset(of: Set(onDisk)), "造出了磁盘清单之外的路径")
    // INV-不相交：报出去的孤儿绝不能被库引用着（引用着 = 在用 = 删了就是数据丢失）
    for path in orphans {
        #expect(!refNorm.contains(independentlyNormalized(path)), "在用文件被判成孤儿：\(path)")
    }
    // 非空洞性：期望孤儿数可手算（i % 4 == 0 的那些），不是"函数返回多少就算多少"
    #expect(orphans.count == (count + 3) / 4, "实得 \(orphans.count) 条，应为 i%4==0 那批")
    // 大小写差与末尾斜杠差都必须认成同物（那两种形状在真仓里成批出现）
    #expect(!orphans.contains(where: { $0.hasPrefix("/V/") || $0.hasSuffix("/") }),
            "写法差异被当成两个文件 ⇒ 在用文件进可删清单")
    // 保序
    #expect(orphans == onDisk.filter { !refNorm.contains(independentlyNormalized($0)) })
}

@Test("TC-OF-14 保守门的形状：safe ⊆ orphan；有交集时两者相等；零交集时 safe 空而 orphan = 整盘")
func safeGateShapeIsSubsetAndNotAlwaysEmpty() {
    let (onDisk, referenced) = corpus(200)
    let raw = OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced)
    let safe = OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced)
    // 门只会收紧，不会另造清单
    #expect(Set(safe).isSubset(of: Set(raw)))
    // 引用集可信（有交集）⇒ 门不得吞掉任何一条真孤儿（否则"守卫"退化成"永不咬人"）
    #expect(safe == raw, "有交集时 safe 应当等于 raw，实得 safe=\(safe.count) raw=\(raw.count)")

    // 零交集那一侧：raw 会把**全部**磁盘文件交出去（包括在用的），safe 必须交空
    let migrated = OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: ["/old/prefix/0.mp4"])
    #expect(migrated == onDisk, "raw 轴上这就是全删的形状 —— 所以 GC 只准走 safe")
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk,
                                             referenced: ["/old/prefix/0.mp4"]).isEmpty)

    // 幂等：同一引用集再跑一次，清单不再变化（GC 若分批跑，第二次不该捞到新的）
    #expect(OrphanFileFinder.orphanFiles(onDisk: raw, referenced: referenced) == raw)
}

@Test("TC-OF-15 「几乎零交集」今天整体放行：门只看有没有交集，不看交集多大（已知局限钉）")
func nearZeroOverlapIsWholesaleTrusted() {
    // 目录迁移改到一半的现场：磁盘 200 条全已在新目录，库里 199 条还写着旧前缀、只有 1 条改写完了。
    // 那 199 条**正在用** —— 是同一批文件，只是库里的路径没跟上。
    let stale = (1...199).map { "/old/Videos/\($0).mp4" }       // 库里没改写的旧前缀
    let current = (1...199).map { "/new/Videos/\($0).mp4" }     // 磁盘上的同一批文件
    let migrated = "/new/Videos/migrated.mp4"                   // 唯一改写完了的那条
    let onDisk = current + [migrated]
    let referenced = Set(stale + [migrated])

    // 今天的行为：那一条命中就足以让门放行 ⇒ 199 个在用文件整批进可删清单
    let safe = OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced)
    #expect(safe.count == 199,
            "实得 \(safe.count)：门一开就是整批，不是只放行那条真该删的")

    // 对照 `safeOrphan_refusesWhenZeroOverlap`（钉"全错"那一端）：一条都不剩时门确实咬得住。
    // 两条并排才看得出缺的是哪一端 —— 差的那一条命中，整批就放行。
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: current, referenced: Set(stale)).isEmpty,
            "零交集那一侧的门不能因为本条而失效")

    withKnownIssue("保守门只判「有没有交集」，不判交集多大 ⇒ 部分可信被当成全可信（1/200 也算可信）。批 1 的反向轴已改用逐条排除（MissingMaterialFinder.excludedRecords）正是为了避开这一形状；orphan 侧尚未同源。补齐后本条会因「不再有问题」而红 ⇒ 摘标并把上面那条整批放行的取证一起改掉") {
        #expect(safe.isEmpty, "引用集只有 1/200 与磁盘同源时，本不该交出任何可删清单")
    }
}

// MARK: - TC-MA-10：orphan 轴与 missing 轴对同一坐标永不相交
// 依赖方案批 1 的 `MissingMaterialFinder`（`kindled-cloud-robin.md` 批 1）。两条轴共用
// `OrphanFileFinder.normalize` 那一颗；各写一套归一，同一个文件在两侧会被认成两个。

private func materialID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
}

@Test("TC-MA-10 两条轴永不相交：missing 报的路径绝不在 orphan 清单里，且两轴各自都得真的报出东西")
func twoAxesNeverOverlapOnSameCoordinate() {
    var records: [MaterialRecordPath] = []
    var onDisk: [String] = []
    for i in 0..<12 {
        switch i % 3 {
        case 0:
            // 库里有、盘上也在 ⇒ 两条轴都不该出声
            records.append(MaterialRecordPath(id: materialID(i), path: "/v/used\(i).mp4"))
            onDisk.append("/v/used\(i).mp4")
        case 1:
            // 库里有、盘上没了 ⇒ missing 轴的靶子
            records.append(MaterialRecordPath(id: materialID(i), path: "/v/gone\(i).mp4"))
        default:
            // 盘上有、库里无 ⇒ orphan 轴的靶子
            onDisk.append("/v/unrecorded\(i).mp4")
        }
    }
    let present = Set(onDisk.map(independentlyNormalized))
    let scan = MissingMaterialFinder.missingIDs(
        records: records,
        probe: { present.contains(independentlyNormalized($0)) ? .present : .absent },
        trustedPrefixes: ["/v"])
    let orphans = OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: Set(records.map(\.path)))

    // 相交性要落在**同一坐标**上比：把 missing 的 id 换回它的路径
    let missingPaths = Set(records.filter { scan.missingIDs.contains($0.id) }.map(\.path))
    #expect(missingPaths.isDisjoint(with: Set(orphans)),
            "同一条路径既被判缺又被判可回收 ⇒ 两条轴的归一或口径分家了")

    // 非空洞性：两轴都必须真的报出东西，否则"不相交"是恒真（空集与谁都不相交）
    #expect(!scan.missingIDs.isEmpty && !orphans.isEmpty,
            "missing=\(scan.missingIDs.count) orphan=\(orphans.count)，夹具没造出靶子")
    #expect(scan.missingIDs.count == 4 && orphans.count == 4, "i%3 轮转下每档各 4 条")
    #expect(!scan.degraded && scan.excludedRecords == 0 && scan.unreadableRecords == 0,
            "可信前缀内、探针明确 ⇒ 不该出现降级或排除")

    // 口径一致性：同一个文件在两侧的写法不同（大小写 + 末尾斜杠）⇒ 两轴都不许出声。
    let sameFileOtherSpelling: [MaterialRecordPath] = [
        MaterialRecordPath(id: materialID(999), path: "/V/Case.MP4")
    ]
    let scan2 = MissingMaterialFinder.missingIDs(
        records: sameFileOtherSpelling,
        probe: { independentlyNormalized($0) == "/v/case.mp4" ? .present : .absent },   // APFS 大小写不敏感的等价模拟
        trustedPrefixes: ["/v"])
    #expect(scan2.missingIDs.isEmpty, "写法差异不该让在用的素材判成丢失")
    // 空集有两种来源：真的都在、还是整条被判不可信。下面这两句把它俩分开 ——
    // 两轴若各写一套归一，这条记录会落到可信前缀外（excluded/degraded）而不是被判成在用。
    #expect(!scan2.degraded, "不可信 ≠ 在用：degraded 也返回空集")
    #expect(scan2.excludedRecords == 0, "写法差异不该让记录落到可信前缀之外")
    #expect(OrphanFileFinder.orphanFiles(onDisk: ["/v/case.mp4/"],
                                        referenced: ["/V/Case.MP4"]).isEmpty,
            "同一颗归一在 orphan 侧必须给同样的结论")
}
