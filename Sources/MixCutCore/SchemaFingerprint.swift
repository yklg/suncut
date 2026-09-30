import Foundation
import CryptoKit

/// SwiftData schema 的指纹，以及「这次开库之前必须先留一份可回退备份」的判据。
///
/// 为什么要有这个类型：本工程的库从来没有 `VersionedSchema`，schema 不兼容时 SwiftData 的行为是
/// **静默重建空库**（`CLAUDE.md` 的「Schema 变更必须先备份数据库」一节记的就是这件事，而那条命令
/// 指向的 `default.store` 早就是死文件）。真出事后的兜底是 `MixCutApp.recoverFromDisk()` —— 那是
/// 事后从磁盘上的视频文件反推项目结构，台词、方案、配音变体一律拿不回来。
///
/// 所以这里把防线从「事后恢复」挪到「开库前」：只要指纹变了，就先把整组 `.store`/`-wal`/`-shm`
/// 复制成一份带时间戳与指纹对的备份，再让 `ModelContainer` 去开库。判错方向的代价是不对称的 ——
/// 多备一份只花磁盘，少备一份花的是用户的素材成果。
///
/// 可测性约束：`swift test` 只有 `MixCutCore` 这一个可测 target，碰不到 `MixCut/` 里任何一行，
/// 因此这里**只吃字符串行**，不 import SwiftData。`Schema.entities` → 描述行的翻译留在 App 侧。
public struct SchemaFingerprint: Sendable, Equatable, Hashable, CustomStringConvertible {

    /// 归一化后的 sha256 前 16 位十六进制。
    public let value: String

    /// 参与指纹的描述行数（0 行是**非法**输入，见 `init(descriptorLines:)` 的说明）。
    public let lineCount: Int

    /// 用**归一化 + 转义**后的描述行算指纹：去空白、去空行、去重、按字典序排序。
    ///
    /// 排序与去重是这条判据能用的前提 —— 否则「把 `@Model` 里两个字段的声明顺序换个位置」这种
    /// 对存储毫无影响的改动也会被判成 schema 变更，备份门就会在无关提交上反复触发，
    /// 很快被人当成噪音绕过。
    ///
    /// **转义不是防御性装饰，是堵碰撞**：拼行拿 `\n` 当分隔符，若描述行自身含换行，
    /// `["a","b\nc"]` 与 `["a\nb","c"]` 会拼成同一个串 ⇒ 两个不同 schema 撞同一指纹 ⇒ **漏判**。
    /// 这条判据的全部职责就是"变了必须翻"，所以先转义反斜杠、再转义换行与回车（顺序见 `escaped`）。
    ///
    /// 空输入（0 行）刻意**不**给一个"看起来正常"的哈希：那会让"忘了注册模型"这种装配错误
    /// 伪装成"schema 没变"，正是要防的那类事故。这里让它显式抛不出、但留下 `lineCount == 0`
    /// 供上层判定；`SchemaGuard` 遇到 0 行一律按"指纹不可信"处理，不写记录、不建备份、不开库。
    public init(descriptorLines: [String]) {
        let normalized = Set(
            descriptorLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map(SchemaFingerprint.escaped)
        ).sorted()

        let digest = SHA256.hash(data: Data(normalized.joined(separator: "\n").utf8))
        self.value = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        self.lineCount = normalized.count
    }

    /// 行内转义。**反斜杠必须最先替换** —— 否则 `"a\\nb"`（真含一个反斜杠 + "nb"）会被二次转义，
    /// 与换行转义出来的 `"a\nb"` 撞成同一串，刚堵上的碰撞从另一侧再开出来。
    static func escaped(_ line: String) -> String {
        line.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    public var description: String { value }
}

/// 开库前该做什么。三档互斥，且每档对应一个**具体动作**，不留"视情况而定"。
public enum SchemaGateDecision: Sendable, Equatable {
    /// 数据目录里还没有指纹记录：首次带门启动。只写指纹，不建备份（此时没有"改前"状态可留）。
    case noPriorRecord
    /// 指纹一致：什么都不做。
    case unchanged
    /// 指纹变了：**开库前**必须完成一份备份。
    case changed(previous: SchemaFingerprint, current: SchemaFingerprint)
    /// 任一侧指纹来自 0 行描述 —— 装配出错（模型没注册进 `Schema`），不能拿它当判据。
    case untrustworthy(SchemaFingerprint?)
}

/// 判定本次开库要不要先备份。
///
/// 判据顺序有讲究：先验可信度再比对。0 行指纹和"没有记录"都走不到 `changed`，否则一次装配
/// 失误就会在真库上生成一份垃圾备份，还会顺手把指纹写成空集的稳定值 —— 那之后真正的 schema
/// 变更就再也触发不了备份门了。
public func decideSchemaGate(
    recorded: SchemaFingerprint?,
    current: SchemaFingerprint
) -> SchemaGateDecision {
    if current.lineCount == 0 { return .untrustworthy(recorded) }
    guard let recorded else { return .noPriorRecord }
    if recorded.lineCount == 0 { return .untrustworthy(recorded) }
    if recorded == current { return .unchanged }
    return .changed(previous: recorded, current: current)
}

/// 指纹变了，变成的是哪一种。
///
/// 为什么需要这一层：光有"变了"这一个档，"拒开库"要么永不触发（一律照常开）、要么永远触发
/// （一律拒），都没有用。真正能落地的判据是**描述行的集合差**：
/// - 只增不减 ⇒ 大概率是"加可选字段/加实体"，轻量迁移能吃掉，备份后照常开库；
/// - 有行消失 ⇒ 删字段、改类型、改属性名、改关系，这些 Apple 明确要求自定义迁移
///   （`MigrationStage.custom`），没有对应 stage 时**必须拦住**，不能让它去重建库。
///
/// ⚠️ 两个已知不完备，都写在这里而不是藏在实现里：
/// 1. 新增**必需且无默认值**的字段会落在 `.additionsOnly`，但轻量迁移不一定过得去 ——
///    那种失败会落到 App 侧的降级分支，所以那条分支的文案**不许教用户删库**。
/// 2. `#Index` 变更**根本不进描述行**（`Entity.indices` 要 macOS 15+，本工程部署目标 14.0）
///    ⇒ 索引变更会被判成 `.identical`。
public enum SchemaChangeKind: Equatable, Sendable {
    case identical
    case additionsOnly(added: [String])
    case destructive(removed: [String], added: [String])

    /// 是否允许"备份之后照常开库"。
    public var isLightweightCompatible: Bool {
        if case .destructive = self { return false }
        return true
    }
}

/// 按**归一化后的行集**做差，判定变更种类。
///
/// 归一化口径必须与 `SchemaFingerprint.init(descriptorLines:)` 完全一致（去空白、去空行、去重），
/// 否则会出现"指纹说没变、分类说有变"这种自相矛盾的读数 —— 那比错判更难查。
public func classifySchemaChange(before: [String], after: [String]) -> SchemaChangeKind {
    func normalized(_ lines: [String]) -> Set<String> {
        Set(lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
    }
    let old = normalized(before)
    let new = normalized(after)

    let removed = old.subtracting(new).sorted()
    let added = new.subtracting(old).sorted()

    if removed.isEmpty && added.isEmpty { return .identical }
    if removed.isEmpty { return .additionsOnly(added: added) }
    return .destructive(removed: removed, added: added)
}

/// 备份**目录**名。做成纯函数是为了能断言命名规则本身 —— 备份散落在数据目录里，名字看不懂就等于没有。
///
/// 形状：`<库名>.<时间戳>.<改前指纹>-to-<改后指纹>.backup`
///
/// 为什么是目录而不是单个 `.sqlite3` 文件：库跑在 WAL 模式下，只拷 `.store` 会漏掉 `-wal` 里已提交
/// 但尚未 checkpoint 的事务 —— 那意味着"改前备份"本身是半份库，回退回去比不清库好不了多少。
/// 所以三件套（`.store` / `.store-wal` / `.store-shm`）必须一起进这个目录。
///
/// 时间戳固定在 UTC + `en_US_POSIX`，不带本机时区与 locale：备份是拿来回退的，文件名必须
/// 在任何机器上都排得开、读得懂。
public func schemaBackupDirectoryName(
    storeName: String,
    previous: SchemaFingerprint,
    current: SchemaFingerprint,
    timestamp: Date,
    calendar: Calendar = calibratedUTCCalendar()
) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(storeName).\(formatter.string(from: timestamp)).\(previous.value)-to-\(current.value).backup"
}

/// 显式给一套 UTC 公历，避免 `Calendar.current` 在农历/佛历 locale 的机器上格式化出别的东西。
public func calibratedUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}
