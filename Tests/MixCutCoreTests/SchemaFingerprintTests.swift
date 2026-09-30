import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 批 0（schema 安全地基）—— SwiftData 改前备份门的判据
//
// 本文件锁定的接口（实现必须逐字满足，否则这些用例不算通过）：
//
//   public struct SchemaFingerprint: Sendable, Equatable, Hashable {
//       public let value: String        // sha256 前 16 位十六进制
//       public let lineCount: Int       // 归一化后的行数
//       public init(descriptorLines: [String])
//   }
//   public enum SchemaGateDecision: Equatable {
//       case noPriorRecord, unchanged
//       case changed(previous: SchemaFingerprint, current: SchemaFingerprint)
//       case untrustworthy(SchemaFingerprint?)
//   }
//   public func decideSchemaGate(recorded: SchemaFingerprint?, current: SchemaFingerprint) -> SchemaGateDecision
//   public func schemaBackupDirectoryName(storeName:previous:current:timestamp:calendar:) -> String
//
// 规则：
//   R1 归一化 = 去首尾空白 + 去空行 + 去重 + 字典序排序。声明顺序、重复行、缩进差异都不得改变指纹，
//      否则无关提交也会触发备份门，门很快会被人当噪音绕过。
//   R2 指纹取 sha256 前 16 位十六进制，且**锚定外部算好的摘要值**（下面 TC-02/03 的期望串来自
//      `printf ... | shasum -a 256`，不是从实现里读回来的）—— 判据不能跟着实现一起改。
//   R3 0 行输入是「装配出错」（模型没注册进 `Schema`），不得当成「schema 没变」。
//   R4 四档互斥，且**可信度判定先于比对**：current 为 0 行时即使 recorded 为 nil 也走 `.untrustworthy`，
//      不许退化成 `.noPriorRecord`（那会把空指纹写进记录，之后真正的 schema 变更再也触发不了备份门）。
//   R5 备份名时间戳固定 UTC + `en_US_POSIX`，与本机时区/locale 无关。
//   R6 反向对照：加/删一个字段必须翻指纹。这条是整个备份门的立命之本 —— 翻不动就等于没有门。
//
// 为什么值得单独建这道门：本工程无 VersionedSchema，schema 不兼容时 SwiftData 静默重建空库；
// 事后兜底 `MixCutApp.recoverFromDisk()` 只能从磁盘视频反推项目结构，台词/方案/配音变体全拿不回来。
// 判错方向代价不对称：多备一份只花磁盘，少备一份花的是用户的素材成果。
// ============================================================================

private let twoLines = ["Project.name:String:opt=false", "Video.path:String:opt=true"]

@Test("TC-01 R1 归一化：乱序/重复/空白三写法同指纹")
func normalizationMakesOrderAndDuplicationIrrelevant() {
    let shuffled = ["Video.path:String:opt=true", "Project.name:String:opt=false"]
    let duplicated = twoLines + twoLines
    let padded = twoLines.map { "  \($0)  " }
    let blanked = twoLines + ["", "   "]

    #expect(SchemaFingerprint(descriptorLines: shuffled) == SchemaFingerprint(descriptorLines: twoLines))
    #expect(SchemaFingerprint(descriptorLines: duplicated) == SchemaFingerprint(descriptorLines: twoLines))
    #expect(SchemaFingerprint(descriptorLines: padded) == SchemaFingerprint(descriptorLines: twoLines))
    #expect(SchemaFingerprint(descriptorLines: blanked) == SchemaFingerprint(descriptorLines: twoLines))
    // 行数按归一化后计：重复与空行都不该被数进去
    #expect(SchemaFingerprint(descriptorLines: duplicated).lineCount == 2)
    #expect(SchemaFingerprint(descriptorLines: blanked).lineCount == 2)
}

@Test("TC-02 R2 指纹值锚定：期望串由 shasum 外部算得")
func fingerprintMatchesExternallyComputedDigest() {
    // printf 'Project.name:String:opt=false\nVideo.path:String:opt=true' | shasum -a 256
    //   → cb05eb408e90739d...（取前 16 位）
    #expect(SchemaFingerprint(descriptorLines: twoLines).value == "cb05eb408e90739d")
}

@Test("TC-03 R3 空输入的指纹是空集摘要，且 lineCount 如实报 0")
func emptyInputIsDistinguishable() {
    let empty = SchemaFingerprint(descriptorLines: [])
    // sha256("") 前 16 位
    #expect(empty.value == "e3b0c44298fc1c14")
    #expect(empty.lineCount == 0)
    // 但它必须 ≠ 任何非空集合 —— 否则"忘了注册模型"会伪装成"schema 没变"
    #expect(empty != SchemaFingerprint(descriptorLines: twoLines))
    // 只含空白行的输入等价于空输入（归一化后 0 行）
    #expect(SchemaFingerprint(descriptorLines: ["", "  "]).lineCount == 0)
}

@Test("TC-04 R6 反向对照：加一个字段必须翻指纹")
func addingOneFieldChangesFingerprint() {
    let before = SchemaFingerprint(descriptorLines: twoLines)
    let after = SchemaFingerprint(descriptorLines: twoLines + ["Project.quality:Int:opt=true"])
    #expect(before != after)
    // printf 'Project.name:String:opt=false\nProject.quality:Int:opt=true\nVideo.path:String:opt=true' | shasum -a 256
    #expect(after.value == "d14d91d343142a73")
    // 可选性翻转也要翻指纹：它是存储层真变了（列的 NOT NULL 约束）
    let flipped = SchemaFingerprint(descriptorLines: ["Project.name:String:opt=true", "Video.path:String:opt=true"])
    #expect(flipped != before)
}

@Test("TC-05 R4 分档：无记录/一致/不一致三档各归位")
func gateThreeBasicOutcomes() {
    let current = SchemaFingerprint(descriptorLines: twoLines)
    #expect(decideSchemaGate(recorded: nil, current: current) == .noPriorRecord)
    #expect(decideSchemaGate(recorded: current, current: current) == .unchanged)

    let other = SchemaFingerprint(descriptorLines: twoLines + ["Project.quality:Int:opt=true"])
    #expect(decideSchemaGate(recorded: other, current: current) == .changed(previous: other, current: current))
}

@Test("TC-06 R4 优先级：0 行先于比对，不得退化成 noPriorRecord")
func untrustworthyBeatsEverythingElse() {
    let empty = SchemaFingerprint(descriptorLines: [])
    let real = SchemaFingerprint(descriptorLines: twoLines)

    // current 0 行 + recorded 为 nil ⇒ 必须是 untrustworthy，写成 noPriorRecord 就把空指纹落盘了
    #expect(decideSchemaGate(recorded: nil, current: empty) == .untrustworthy(nil))
    // current 0 行 + recorded 有值 ⇒ 仍先判不可信，不进 changed（否则一次装配失误就污染备份目录）
    #expect(decideSchemaGate(recorded: real, current: empty) == .untrustworthy(real))
    // recorded 侧是历史上写坏的空指纹 ⇒ 同样不可信，不能当"变了"来处理
    #expect(decideSchemaGate(recorded: empty, current: real) == .untrustworthy(empty))
}

// 刻意用中性库名 `data.store`：身份字面量守卫（`BrandIdentityTests`）禁止品牌名出现在 Brand.swift 之外，
// 而本函数对 storeName 是纯透传，换成中性名不削弱任何断言。
@Test("TC-07 R5 备份名：形状与 UTC 时刻都由外部锚定")
func backupFileNameShapeAndUTC() {
    let previous = SchemaFingerprint(descriptorLines: twoLines)
    let current = SchemaFingerprint(descriptorLines: twoLines + ["Project.quality:Int:opt=true"])
    let utcMidnight2026 = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01T00:00:00Z

    #expect(
        schemaBackupDirectoryName(
            storeName: "data.store", previous: previous, current: current, timestamp: utcMidnight2026
        ) == "data.store.20260101-000000.cb05eb408e90739d-to-d14d91d343142a73.backup"
    )
    // UTC 边界：这一秒在 +08:00 本机时区会格式化成 2026-01-01 07:59:59 —— 出现那种串就说明吃了本机时区
    #expect(
        schemaBackupDirectoryName(
            storeName: "data.store", previous: previous, current: current,
            timestamp: Date(timeIntervalSince1970: 1_767_225_599)
        ).contains(".20251231-235959.")
    )
}

@Test("TC-08 R5 本机时区无关：注入非 UTC 日历也不改结果")
func backupFileNameIgnoresInjectedCalendar() {
    let previous = SchemaFingerprint(descriptorLines: ["A.x:Int:opt=false", "B.y:Int:opt=false", "C.z:Int:opt=false"])
    let current = SchemaFingerprint(descriptorLines: ["A.x:Int:opt=false", "B.y:Int:opt=false", "C.z:Int:opt=false", "D.w:Int:opt=false"])
    // 期望串外部锚定：sha256 前三行 → ea744a476781261b；加 D.w → a893cdf9e422d730
    let ts = Date(timeIntervalSince1970: 1_767_225_600)

    let withDefault = schemaBackupDirectoryName(storeName: "data.store", previous: previous, current: current, timestamp: ts)
    var shanghai = Calendar(identifier: .gregorian)
    shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let withShanghai = schemaBackupDirectoryName(
        storeName: "data.store", previous: previous, current: current, timestamp: ts, calendar: shanghai
    )

    #expect(withDefault == "data.store.20260101-000000.ea744a476781261b-to-a893cdf9e422d730.backup")
    #expect(withShanghai == withDefault)
}

@Test("TC-09 指纹可当字典键用（sidecar 读写要能存 Set/字典）")
func fingerprintIsHashable() {
    let set: Set<SchemaFingerprint> = [
        SchemaFingerprint(descriptorLines: twoLines),
        SchemaFingerprint(descriptorLines: twoLines),
        SchemaFingerprint(descriptorLines: ["only"]),
    ]
    #expect(set.count == 2)
}

// ============================================================================
// D-1 追加（test-coverage-expander 阶段 C 实例化，2026-09-30）
//
// 每条回溯到一条一般规则，编号 SF-10~15，对应覆盖矩阵里的缺口：
//   SF-10 IN-05 换行/反斜杠不得造成行集碰撞（曾为破口：`joined(separator:"\n")` 让两组不同行集撞同一指纹，已修）
//   SF-11 IN-05 CJK 实体名与含尖括号的类型名
//   SF-12 INV-01 反向对照：实体改名必须翻指纹（改名是迁移，不是噪音）
//   SF-13 IN-06 等价类：同实体内两属性互换类型必须翻（归一化只按整行排序，不该吞掉配对关系）
//   SF-14 IN-03 规模：1000 行仍与顺序无关、耗时不爆（形状照抄 `ProjectVideoDedupTests` TC-05/TC-13）
//   SF-15 SEC-01 备份名不得泄漏登录名或带目录分隔（关联批 2.4 脱敏）
//
// ⚠️ 效力上限（同源复算守卫的通病，写在这里免得被当成"门已全绿"）：
// 这批用例只保证「同一套行集 → 同一个指纹」与「这几类改动会翻指纹」，
// **不保证**「所有真实 schema 变更都会翻指纹」—— 后者取决于 App 侧
// `SchemaGuard.descriptorLines(from:)` 的翻译是否完整。现装：属性类型/可选/唯一/transient、
// 父实体、关系目标与删除规则与反向名、唯一约束组都进指纹；**`#Index` 进不去**
// （`Entity.indices` 要 macOS 15+，本工程部署目标 14.0）⇒ 索引变更不翻指纹。
// 那半边由批 0 的 0-C 守卫与克隆库实测兜，不在本文件。
// ============================================================================

@Test("SF-10 IN-05 换行与反斜杠都不许造成行集碰撞（转义修法已落）")
func newlineAndBackslashMustNotCollide() {
    let groupA = SchemaFingerprint(descriptorLines: ["a", "b\nc"])
    let groupB = SchemaFingerprint(descriptorLines: ["a\nb", "c"])

    // 转义前这两组会拼成同一个串、撞成同一指纹 `ea7fb08b7a2dc461` —— 那是**漏判**，
    // 而这条判据的全部职责就是"schema 变了必须翻"。
    // 期望值外部锚定：printf 'a\nb\\nc' → c4fb71d81abfc0c6 ；printf 'a\\nb\nc' → 5ec202c920bdbd2f
    #expect(groupA.value == "c4fb71d81abfc0c6")
    #expect(groupB.value == "5ec202c920bdbd2f")
    #expect(groupA != groupB)
    #expect(groupA.lineCount == 2 && groupB.lineCount == 2)

    // 反向对照，专抓转义顺序被改错的下次改动：先换行后反斜杠会让下面两条撞在一起。
    // 左：4 个字符 a \ n b      右：3 个字符 a LF b
    #expect(SchemaFingerprint(descriptorLines: ["a\\nb"]) != SchemaFingerprint(descriptorLines: ["a\nb"]))
}

@Test("SF-11 IN-05 CJK 与尖括号类型名：乱序等值、改类型翻值，摘要由 shasum 锚定")
func cjkAndAngleBracketTypeNames() {
    let cjk = ["分镜.字段:Swift.Optional<Foundation.Data>", "项目.名称:String"]
    // printf '分镜.字段:Swift.Optional<Foundation.Data>\n项目.名称:String' | shasum -a 256
    #expect(SchemaFingerprint(descriptorLines: cjk).value == "f38a6d2e1eec35e6")
    #expect(SchemaFingerprint(descriptorLines: cjk.reversed()) == SchemaFingerprint(descriptorLines: cjk))
    // 只改类型不改名字 ⇒ 必须翻（Optional→非 Optional 是存储层变更）
    let narrowed = ["分镜.字段:Foundation.Data", "项目.名称:String"]
    #expect(SchemaFingerprint(descriptorLines: narrowed) != SchemaFingerprint(descriptorLines: cjk))
}

@Test("SF-12 反向对照：实体改名必须翻指纹")
func entityRenameMustFlipFingerprint() {
    let before = SchemaFingerprint(descriptorLines: ["Segment.x:Int:opt=false"])
    let after = SchemaFingerprint(descriptorLines: ["Shot.x:Int:opt=false"])
    // 两侧摘要均外部算得：printf 'Segment.x:Int:opt=false' → dc6c2489a90d04ff
    //                     printf 'Shot.x:Int:opt=false'    → 33cccb9b51dfebc0
    #expect(before.value == "dc6c2489a90d04ff")
    #expect(after.value == "33cccb9b51dfebc0")
    #expect(before != after)
}

@Test("SF-13 等价类：同实体内两属性互换类型必须翻，不得被整行排序吞掉配对关系")
func swappingTypesBetweenPropertiesMustFlip() {
    let original = ["P.a:Int:opt=false", "P.b:String:opt=false"]
    let swapped = ["P.a:String:opt=false", "P.b:Int:opt=false"]
    // printf 'P.a:Int:opt=false\nP.b:String:opt=false'    → 050952caf8c37288
    // printf 'P.a:String:opt=false\nP.b:Int:opt=false'    → 76d332eda1077afd
    #expect(SchemaFingerprint(descriptorLines: original).value == "050952caf8c37288")
    #expect(SchemaFingerprint(descriptorLines: swapped).value == "76d332eda1077afd")
    #expect(SchemaFingerprint(descriptorLines: original) != SchemaFingerprint(descriptorLines: swapped))
}

@Test("SF-14 规模：1000 行仍与声明顺序无关，且耗时不爆（Debug 口径的上限断言，非基准）")
func thousandLinesStayOrderIndependentAndBounded() {
    let lines = (0..<1000).map { "E\($0 % 10).p\($0):Int:opt=false" }
    #expect(lines.count == Set(lines).count)   // 生成器本身不许产出重复行，否则这条测的是去重

    let start = Date()
    let forward = SchemaFingerprint(descriptorLines: lines)
    let backward = SchemaFingerprint(descriptorLines: Array(lines.reversed()))
    let elapsed = Date().timeIntervalSince(start)

    #expect(forward.lineCount == 1000)
    #expect(forward == backward)
    // 只是"别退化成 O(n²) 或做多余 IO"的下限护栏；真实耗时以量级计，不当性能结论用
    #expect(elapsed < 2.0)
}

@Test("SF-15 SEC-01 备份名是单个路径分量，且不含本机登录名")
func backupNameLeaksNothing() {
    let previous = SchemaFingerprint(descriptorLines: twoLines)
    let current = SchemaFingerprint(descriptorLines: twoLines + ["Project.quality:Int:opt=true"])
    let name = schemaBackupDirectoryName(
        storeName: "data.store", previous: previous, current: current,
        timestamp: Date(timeIntervalSince1970: 1_767_225_600)
    )

    #expect(!name.contains("/"))
    #expect((name as NSString).lastPathComponent == name)   // 本身就是一个分量，不带目录
    #expect(!name.contains(NSUserName()))           // 上游承诺诊断产物不泄漏登录名，备份名同理
    #expect(!name.contains("Users"))
}

// ============================================================================
// SC-01~05 · `classifySchemaChange` —— "拒开库"到底该不该拦的分类判据
//
// 光有"指纹变了"一档，拒开库要么永不触发要么永远触发。能落地的判据是描述行的**集合差**：
// 只增 ⇒ 备份后照常开；有行消失 ⇒ 删字段/改类型/改名/改关系，Apple 明确要求自定义迁移 ⇒ 拦。
// ============================================================================

private let baseLines = [
    "Project|superentity=-",
    "Project.name|type=String|optional=false|unique=false|transient=false",
    "Segment|superentity=-",
    "Segment.startFrame|type=Int|optional=false|unique=false|transient=false",
]

@Test("SC-01 同一套行 ⇒ identical，且允许照常开库")
func identicalIsCompatible() {
    let kind = classifySchemaChange(before: baseLines, after: baseLines)
    #expect(kind == .identical)
    #expect(kind.isLightweightCompatible)
}

@Test("SC-02 只增一行可选字段 ⇒ additionsOnly，并列出增的是什么")
func additionOnlyIsCompatible() {
    let addedLine = "Segment.batchNo|type=Int|optional=true|unique=false|transient=false"
    let kind = classifySchemaChange(before: baseLines, after: baseLines + [addedLine])
    #expect(kind == .additionsOnly(added: [addedLine]))
    #expect(kind.isLightweightCompatible)
}

@Test("SC-03 反向对照：改类型 = 一行消失 + 一行新增 ⇒ destructive，必须拦")
func typeChangeIsDestructive() {
    let after = baseLines.filter { !$0.hasPrefix("Segment.startFrame|") }
        + ["Segment.startFrame|type=String|optional=false|unique=false|transient=false"]
    let kind = classifySchemaChange(before: baseLines, after: after)
    guard case .destructive(let removed, let added) = kind else {
        Issue.record("改类型必须判 destructive，实得 \(kind)")
        return
    }
    #expect(removed.count == 1 && added.count == 1)
    #expect(!kind.isLightweightCompatible)
}

@Test("SC-04 删字段/删实体 ⇒ destructive 拦；整实体新增 ⇒ 兼容")
func removalAndAdditionOfEntities() {
    let dropped = baseLines.filter { !$0.hasPrefix("Segment") }
    #expect(!classifySchemaChange(before: baseLines, after: dropped).isLightweightCompatible)

    let newEntity = baseLines + ["ShotVariant|superentity=-",
                                 "ShotVariant.price|type=Double|optional=true|unique=false|transient=false"]
    let kind = classifySchemaChange(before: baseLines, after: newEntity)
    #expect(kind.isLightweightCompatible)
    if case .additionsOnly(let added) = kind {
        #expect(added.count == 2)
    } else {
        Issue.record("应判 additionsOnly，实得 \(kind)")
    }
}

@Test("SC-05 归一化口径必须与指纹一致：只改顺序/加空白不算变更")
func normalizationMatchesFingerprint() {
    let shuffledWithPadding = baseLines.reversed().map { "  \($0) " }
    #expect(classifySchemaChange(before: baseLines, after: shuffledWithPadding) == .identical)
    // 同一条输入下"指纹说没变"与"分类说 identical"必须同结论 —— 自相矛盾比错判更难查
    #expect(SchemaFingerprint(descriptorLines: baseLines) == SchemaFingerprint(descriptorLines: shuffledWithPadding))
}
