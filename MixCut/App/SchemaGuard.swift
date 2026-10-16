import Foundation
import SQLite3
import SwiftData

/// 开库结果三态。**刻意不把"schema 门拦住"和"库真的坏了"合并成一个 catch** ——
/// 既有代码里开库失败会一路掉进内存模式，并弹出「请删除 …/Suncut.store 后重启应用」。
/// 那道防线拦住的正是那种事故，若复用同一条路径，等于**教用户删掉它正在保护的库**。
enum StoreOpenOutcome {
    /// 正常开库成功。
    case opened(ModelContainer)
    /// 库真的坏了（非 schema 原因）：沿用内存模式降级，但文案不再指引删库。
    case degradedInMemory(ModelContainer, message: String)
    /// schema 门拒绝开库：改前备份已生成，必须给得出回退路径。
    case refusedBySchemaGate(message: String)
}

/// 开库前的 schema 指纹门 + 改前备份 + 启动账本。
///
/// 三道职责同住一个文件，因为它们共用同一份 sidecar，且都必须**赶在 `ModelContainer` 之前**发生：
/// 1. **指纹门**：`Schema` 元数据 → 描述行 → 指纹，与上次成功开库的比对；
/// 2. **变更分类**：只增 ⇒ 备份后照常开；有行消失 ⇒ 删字段/改类型/改名/改关系，
///    这些 Apple 明确要求自定义迁移，没有对应 stage 时**拦住不开**；
/// 3. **账本**：描述行 + `doneSteps` + `lastRunAt` 写在同一份 JSON —— 刻意不再发明第二批
///    `UserDefaults` 键，否则"状态散落多处"这个本次要消除的根因会换个地方长回来。
///
/// 防线位置的理由：无 VersionedSchema 时 schema 不兼容的后果是**重建空库**
/// （`CLAUDE.md`「已知问题 · Schema 版本」那条历史记录下来的团队实测；
/// 这里刻意不写行号 —— 那节内容改写过，行号引用当天就会腐烂），
/// 既有兜底 `recoverFromDisk()` 只能从视频文件反推项目结构，台词/方案/配音变体全拿不回。
enum SchemaGuard {

    /// sidecar 的内容。存**描述行本身**而不是指纹值：集合差要拿行来算，
    /// 而且指纹可以从行重算，反过来不行（写坏的指纹值无从还原成行）。
    struct Ledger: Codable, Equatable {
        var lines: [String]
        var updatedAt: Date
        var doneSteps: [String]
        var lastRunAt: [String: Date]
        /// 写下这份记录的那个程序的版本。**必须是 Optional**：盘上已有的 sidecar 没有这个键，
        /// 换成非可选会让整份 JSON 解码失败 ⇒ `readLedger` 读成 `.unreadable` ⇒ 这道门在这次启动帮不上忙
        /// （自 §6-3 起不再是**静默**：会留一行日志加一份改前备份，但仍照常开库 —— 见 `LedgerRead` 的说明）。
        var appVersion: String?

        init(lines: [String] = [], updatedAt: Date = Date(),
             doneSteps: [String] = [], lastRunAt: [String: Date] = [:],
             appVersion: String? = nil) {
            self.lines = lines
            self.updatedAt = updatedAt
            self.doneSteps = doneSteps
            self.lastRunAt = lastRunAt
            self.appVersion = appVersion
        }

        var fingerprint: SchemaFingerprint { SchemaFingerprint(descriptorLines: lines) }
    }

    /// 写下这份记录的程序是谁。**只进诊断文案与日志，不参与任何判定** ——
    /// 拿版本号去决定开不开库，等于把这道防线交给一个可能几年不动的 `CFBundleShortVersionString`。
    /// 它存在的理由是：`lines` 是单调棘轮（每次成功开库都覆盖成当前二进制的 schema），
    /// 所以"有行消失"这一个形状同时覆盖了两种处置完全相反的情形 ——
    /// ①跑的是更旧的程序／旧构建产物（数据比程序新，不是数据危险）；
    /// ②代码真的删改了字段（必须补自定义迁移）。光看描述行分不开，版本号才分得开。
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知版本"
    }

    /// 给人看的时间：本地时区。备份名里的时间戳刻意用 UTC（要排得开、跨机读得懂），
    /// 而界面上的这些时间是拿来对照"我上次是什么时候用的"，用本地时间才对得上。
    static func humanDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 本次运行的程序是**什么时候产出的**（按产物文件时间推断）。
    /// 光有版本号不够用：开发期 `CFBundleShortVersionString` 常年不动，2026-10-11 实测过相差 6 天的
    /// 两个构建同为 0.11.0 —— 只有这个时间能把"跑的是旧产物"与"真删了字段"分开。
    /// （写成"某年某次实测"是有意的：具体号是当时的读数，不是"版本号永远不动"这条主张。）
    ///
    /// 口径必须与工装的前置 U05 同源：取 `Contents/MacOS/` 下**最早**那颗。Xcode 16 的 Debug
    /// 真身在 `*.debug.dylib`、主二进制只是 58K stub，只读主二进制会在半截构建时印出一个
    /// 比真身更新的时间 —— 那等于给一条已经堵掉的洞重新开门。
    /// 装包与拷贝可能改写文件时间，所以它**只进诊断文案，不参与任何判定**。
    static var currentBuildDateText: String {
        guard let exe = Bundle.main.executableURL else { return "取不到" }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: exe.deletingLastPathComponent(), includingPropertiesForKeys: Array(keys))) ?? []
        var oldest: Date?
        for url in (siblings.isEmpty ? [exe] : siblings) {
            guard let mtime = (try? url.resourceValues(forKeys: keys))?.contentModificationDate else { continue }
            if let current = oldest {
                if mtime < current { oldest = mtime }
            } else {
                oldest = mtime
            }
        }
        return oldest.map { humanDateText($0) } ?? "取不到"
    }

    // MARK: - 描述行

    /// 把 `Schema` 翻成参与指纹的描述行。
    ///
    /// 覆盖：实体名、父实体、属性名/类型/可选/唯一/是否 transient、关系的目标实体、删除规则、
    /// 反向属性名、级联唯一约束组。
    /// **唯一覆盖不到的是 `Entity.indices`（`#Index`）** —— 它要 macOS 15+，本工程部署目标 14.0。
    /// 所以"指纹没变"只能读成"除索引外的 schema 没变"，这句写在这里免得被当成全保证。
    static func descriptorLines(from schema: Schema) -> [String] {
        var lines: [String] = []
        for entity in schema.entities {
            lines.append("\(entity.name)|superentity=\(entity.superentityName ?? "-")")

            for attribute in entity.attributes {
                lines.append("\(entity.name).\(attribute.name)"
                    + "|type=\(String(describing: attribute.valueType))"
                    + "|optional=\(attribute.isOptional)"
                    + "|unique=\(attribute.isUnique)"
                    + "|transient=\(attribute.isTransient)")
            }

            for relationship in entity.relationships {
                lines.append("\(entity.name).\(relationship.name)"
                    + "|to=\(relationship.destination)"
                    + "|delete=\(relationship.deleteRule)"
                    + "|inverse=\(relationship.inverseName ?? "-")")
            }

            for constraint in entity.uniquenessConstraints where !constraint.isEmpty {
                lines.append("\(entity.name)|uniqueGroup=\(constraint.sorted().joined(separator: "+"))")
            }
        }
        return lines
    }

    // MARK: - sidecar

    /// 与库同目录、同名加后缀：跟着数据根一起被搬、一起被备份。
    static func ledgerURL(storeURL: URL) -> URL {
        storeURL.appendingPathExtension("launch-ledger")
    }

    /// 读 sidecar 的三种结果。**"没有文件"与"有文件但读不出来"绝不能同形** ——
    /// 两者都回 `nil` 时，一份写坏的记录会让这道门**永久失明**，而且没有任何一行日志说它失明过
    /// （`2026-10-01` 那份计划拍 D-1 时查出来的原话）。分开的同时不改判定：
    /// 读不出来仍按"无记录"开库 —— 让一个坏 JSON 变成打不开的应用是另一档风险，已单独拍掉（§6-3）。
    enum LedgerRead {
        case absent
        case readable(Ledger)
        case unreadable(reason: String)
    }

    static func readLedger(storeURL: URL) -> LedgerRead {
        let url = ledgerURL(storeURL: storeURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .readable(try decoder.decode(Ledger.self, from: Data(contentsOf: url)))
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
    }

    /// 只在**开库成功后**调用。写失败不致命（下次启动会多备份一次），但必须留日志。
    @discardableResult
    static func writeLedger(storeURL: URL, lines: [String], previous: Ledger?) -> Bool {
        var ledger = previous ?? Ledger()
        ledger.lines = lines
        ledger.updatedAt = Date()
        ledger.appVersion = currentAppVersion
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(ledger).write(to: ledgerURL(storeURL: storeURL), options: .atomic)
            return true
        } catch {
            MixLog.error("启动账本写入失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 备份

    /// 需要一起搬走的库文件族：主文件 + WAL 两件套 + 账本本身。
    ///
    /// 三件套必须一起：库跑 WAL 模式，只拷主文件会漏掉 `-wal` 里已提交未 checkpoint 的事务
    /// （实测现网 `.store` 348KB 而 `.store-wal` 2.16MB —— 最近的写入几乎都在 WAL 里）。
    static func storeFamily(storeURL: URL) -> [URL] {
        let base = storeURL.path
        return [storeURL,
                URL(fileURLWithPath: base + "-wal"),
                URL(fileURLWithPath: base + "-shm"),
                ledgerURL(storeURL: storeURL)]
    }

    /// 生成一份改前备份目录。命名里的两个指纹就是"从哪变到哪"，出问题时不用猜。
    static func performBackup(storeURL: URL, previous: SchemaFingerprint, current: SchemaFingerprint,
                              now: Date = Date()) throws -> URL {
        let parent = storeURL.deletingLastPathComponent()
        let name = schemaBackupDirectoryName(storeName: storeURL.lastPathComponent,
                                             previous: previous, current: current, timestamp: now)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        for source in storeFamily(storeURL: storeURL) where FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source,
                                             to: directory.appendingPathComponent(source.lastPathComponent))
        }
        return directory
    }

    /// 备份自证：能被打开且 `integrity_check` 返回 `ok` 才算一份有效退路。
    static func verifyBackup(directory: URL, storeURL: URL) -> Bool {
        let copy = directory.appendingPathComponent(storeURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: copy.path) else { return false }
        return runIntegrityCheck(on: copy)
    }

    /// 生成备份**并自证**，只把自证过的那份交回；自证不过就删掉它（留一份打不开的"退路"比没有更坏）。
    /// 两处调用共用这一颗：`.changed` 那一格和"账本读不出来"那一格 —— 同一件事不写两遍。
    private static func verifiedBackup(storeURL: URL, previous: SchemaFingerprint,
                                       current: SchemaFingerprint) -> URL? {
        do {
            let made = try performBackup(storeURL: storeURL, previous: previous, current: current)
            guard verifyBackup(directory: made, storeURL: storeURL) else {
                try? FileManager.default.removeItem(at: made)
                MixLog.error("schema 门：改前备份校验未通过，已删除该份备份")
                return nil
            }
            // 刚做出来的这份必须立刻进保留策略：拒开那一格走不到 `open`，不在这里裁就没人裁了。
            pruneBackups(storeURL: storeURL)
            return made
        } catch {
            MixLog.error("schema 门：改前备份失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 备份族的保留策略：**每个族各留最近 `keeping` 份**，两个族各自数，不许互相冒充份额。
    ///
    /// · `*.backup` —— 门在"结构有变更"或"账本读不出来"时做的全族快照；
    /// · `*.pre-dangling-*.bak{,-wal,-shm}` —— 悬空边修复自己那份退路。§6-1 之后它站在门后，
    ///   但**必须留着**：普通启动（schema 未变）时门一份备份都不做，这一族是那次 UPDATE 唯一的退路。
    ///   同一次修复产生的三件共享同一个时间戳 ⇒ 按时间戳**成组**计数，绝不把一组裁成半组。
    ///
    /// 为什么敢连"拒开"那一格也裁（v1.6 之前这儿的口径是"攒多份是故意的"）：§6-1 之后拒开那次
    /// 根本没碰库，连续几次拒开做出来的备份内容逐字节相同，丢掉较老的那些不损失任何退路。
    /// 读不出来的旧口径之所以成立，是因为那时修库跑在门之前 —— 每份备份装的确实是不同的盘上状态。
    static func pruneBackups(storeURL: URL, keeping: Int = 3) {
        let parent = storeURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil) else { return }
        let stem = storeURL.lastPathComponent

        let door = entries
            .filter { $0.lastPathComponent.hasPrefix(stem + ".") && $0.lastPathComponent.hasSuffix(".backup") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in door.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: stale)
        }

        // 修复族：时间戳取不出来的一律不动（宁可少删，也不把一组三份删成半组）。
        var stamps: Set<String> = []
        for url in entries {
            if let stamp = danglingStamp(url.lastPathComponent, stem: stem) { stamps.insert(stamp) }
        }
        for stale in stamps.sorted(by: >).dropFirst(keeping) {
            for url in entries where danglingStamp(url.lastPathComponent, stem: stem) == stale {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 从 `Suncut.store.pre-dangling-<stamp>.bak-wal` 这类名字里取出 `<stamp>`；取不出回 nil。
    private static func danglingStamp(_ name: String, stem: String) -> String? {
        guard name.hasPrefix(stem + ".pre-dangling-"),
              let head = name.range(of: ".pre-dangling-"),
              let tail = name.range(of: ".bak", range: head.upperBound..<name.endIndex) else { return nil }
        let stamp = name[head.upperBound..<tail.lowerBound]
        return stamp.allSatisfy(\.isNumber) ? String(stamp) : nil
    }

    private static func runIntegrityCheck(on fileURL: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
    }

    // MARK: - 门在这（判定 + 改前备份，与"真的开库"分家）

    /// 门发出的**通行证**：证明「这个 URL 已被 schema 门判过；若结构有变更，已生成一份自证通过的改前备份」。
    ///
    /// `init` 刻意是 `fileprivate` ⇒ 全仓只有本文件（也就是 `evaluate`）铸造得出它。这不是装饰：
    /// 悬空边修复的写盘入口收一个 `GatePermit`，于是"门还没判就去改库"在**编译期**就不成立，
    /// 不再靠 `MixCutApp.init` 里那句注释维持 —— 口径取自本仓自己的标准
    /// （git log 的话：「把『先落盘再判空』变成构造不出来的形状」；顺序 lint 只挡得住记得跑它的人）。
    ///
    /// 通行证**绑定 URL**：拿 A 库的通行证去写 B 库会被 `allows(writingTo:)` 在运行期拒掉 ——
    /// 否则门等于发一张通用许可证，"过了门"这件事和"改的是哪颗库"就脱钩了。
    struct GatePermit {
        let storeURL: URL
        let lines: [String]
        let previousLedger: Ledger?

        fileprivate init(storeURL: URL, lines: [String], previousLedger: Ledger?) {
            self.storeURL = storeURL
            self.lines = lines
            self.previousLedger = previousLedger
        }

        /// 这张通行证授权写的是不是 `url` 那颗库。
        func allows(writingTo url: URL) -> Bool {
            url.standardizedFileURL.path == storeURL.standardizedFileURL.path
        }
    }

    /// `evaluate` 的产物。判定与开库分家的唯一理由：中间那一步写盘修复必须既能拿到通行证、
    /// 又不能靠**再判一次**来拿 —— 同一个结论有两个来源，中间只要有任何东西碰过盘，两者就能分叉。
    enum Verdict {
        case proceed(GatePermit)
        case refused(message: String)
    }

    /// 第一步：算指纹、比账本、分类变更，必要时生成**且校验**改前备份。**不建容器、不写账本。**
    static func evaluate(schema: Schema, storeURL: URL) -> Verdict {
        let lines = descriptorLines(from: schema)
        let current = SchemaFingerprint(descriptorLines: lines)
        let read = readLedger(storeURL: storeURL)
        var ledger: Ledger?
        if case .readable(let recorded) = read { ledger = recorded }
        if case .unreadable(let reason) = read {
            // 判定仍是"无记录"，但不许**静默**：留一行日志 + 先做一份自证过的改前备份。
            // 这一格只要"万一 schema 同时真变了，用户手里仍有退路"，不要"拦住启动"（坏 JSON 不该让应用打不开）。
            MixLog.error("schema 门：启动账本读不出来 ⇒ 本次按无记录处理"
                + "（\(ledgerURL(storeURL: storeURL).path)）：\(reason)")
            _ = verifiedBackup(storeURL: storeURL,
                               previous: SchemaFingerprint(descriptorLines: []), current: current)
        }
        let decision = decideSchemaGate(recorded: ledger?.fingerprint, current: current)

        func issued() -> Verdict {
            .proceed(GatePermit(storeURL: storeURL, lines: lines, previousLedger: ledger))
        }
        func refused(_ message: String) -> Verdict {
            .refused(message: message)
        }

        switch decision {
        case .unchanged, .noPriorRecord:
            return issued()

        case .untrustworthy(let recorded):
            // 描述行 0 条 = 模型没注册进 Schema。这是装配失误，不是"schema 没变"，
            // 也不能拿它去覆盖账本 —— 一旦写空，这道门就永久废掉了。
            let note = recorded == nil ? "本次未取到任何模型定义" : "上次记录与本次取值均不可信"
            MixLog.error("schema 门：不可信指纹（\(note)），拒绝开库")
            return refused("""
                未能读取应用的数据结构定义（\(note)）。

                这通常是程序自身的问题而不是数据坏了，因此这次启动没有改动你的库文件。
                请退回上一个版本并反馈；不要删除任何文件。
                """)

        case .changed(let previousFP, let currentFP):
            let kind = classifySchemaChange(before: ledger?.lines ?? [], after: lines)
            let backupDirectory = verifiedBackup(storeURL: storeURL, previous: previousFP, current: currentFP)

            if kind.isLightweightCompatible, backupDirectory != nil {
                MixLog.info("schema 只增行变更（+\(kind.addedCount) 项），已生成改前备份，照常开库")
                return issued()
            }

            if case .destructive(let removed, let added) = kind {
                let path = backupDirectory?.path ?? "（本次未能生成备份，请勿删除任何文件）"
                let recorder = ledger.map {
                    "\($0.appVersion ?? "更早的版本（那份记录里没留版本号）") 于 \(Self.humanDateText($0.updatedAt))"
                } ?? "上一次成功开库"
                let running = "\(Self.currentAppVersion)，产出时间 \(Self.currentBuildDateText)"
                MixLog.error("schema 门：检测到不可自动迁移的变更（消失 \(removed.count) 行 / 新增 \(added.count) 行），拒绝开库；"
                    + "记录由 \(recorder) 写下，本次运行的程序是 \(running)")
                return refused("""
                    这次启动没有打开数据库（你的库文件没有被改动）。

                    这份库的数据结构记录由 \(recorder) 写下；本次运行的程序是 \(running)。
                    消失的定义 \(removed.count) 项、新增 \(added.count) 项，例如：
                    \(removed.prefix(3).joined(separator: "\n"))

                    改前备份：\(path)

                    先分清是哪一种，两种处置完全相反：
                    · 本次跑的是更旧的程序或旧的构建产物（自动化脚本、手动装回老版本）——
                      判据就是上面两个时间：本次程序的产出时间早于那份记录写下的时间。
                      换回写下那份记录的那个版本就能继续用，不需要补迁移。
                      装回更老的其他版本同样打不开：这份记录只留最后一次成功开库的数据结构。
                    · 本次跑的确实是新代码 —— 那是真删改过字段，
                      需要补一条自定义迁移（AppSchemaV2 + MigrationStage.custom）才允许升级开库。

                    要回到改动前的状态：把上面那份备份目录里的文件原样放回数据目录，
                    代价是丢掉那之后新增的内容。任何情况下都不要删除库文件。
                    """)
            }

            // 兼容变更但备份没成 —— 此时不许"赌一把"开库：没有退路的变更正是清库事故的原场。
            return refused("""
                数据结构有变更，但改前备份没能生成（磁盘满 / 权限 / 目录不可写），因此这次启动没有打开数据库。

                请腾出空间或换到可写位置后重试；不要删除任何文件。
                """)
        }
    }

    /// 第二步：拿着通行证才真的开库、记账本、裁剪备份。
    ///
    /// **没有任何办法绕过门调用它** —— 唯一的入参 `GatePermit` 只有 `evaluate` 发得出。
    /// 拿到通行证之后、这里之前允许写盘的那一步（悬空边修复）就在 `MixCutApp.init` 里，
    /// 位置由 `PreContainerPlan` 名册 + `check_schema_ledger_guards.sh` SL-15 钉住。
    static func open(permit: GatePermit, schema: Schema) -> StoreOpenOutcome {
        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: permit.storeURL)])
            _ = writeLedger(storeURL: permit.storeURL, lines: permit.lines, previous: permit.previousLedger)
            // 两个裁剪时刻共用同一颗 `pruneBackups`（策略只有一个出处）：
            // `verifiedBackup` 里那次管"刚做了门备份"的场合（含拒开），这里这次管
            // "普通启动里修库写了盘"的场合 —— 那一格门根本不做备份，`.pre-dangling` 族只能在这裁。
            pruneBackups(storeURL: permit.storeURL)
            return .opened(container)
        } catch {
            return degradeToMemory(schema: schema, cause: error)
        }
    }

    /// 被门拦住时给 UI 用的**内存**容器：只为把错误面板画出来，绝不碰盘上那个库。
    ///
    /// 最后一道 `try!` 是明知不优雅仍留下的：`App.modelContainer` 是非可选存储属性，
    /// 连内存容器都建不起来时没有任何办法渲染界面。留日志是为了让那次崩溃在诊断报告里
    /// 至少留下一行原因，而不是无声退出。
    static func placeholderContainer(schema: Schema) -> ModelContainer {
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [memory]) {
            return container
        }
        MixLog.error("连内存容器都建不起来，界面无法渲染 —— 这是最后手段的强制解包")
        return try! ModelContainer(for: schema)
    }

    /// 真·库损坏的降级路径。保留"内存模式"这个既有行为，但**不再指引删库**。
    private static func degradeToMemory(schema: Schema, cause: Error) -> StoreOpenOutcome {
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: [memoryConfig])
            return .degradedInMemory(container, message: """
                数据库暂时打不开，本次以临时模式运行（关闭后不保存任何改动）。

                原因：\(cause.localizedDescription)

                你的库文件仍在原处，不要删除它 —— 删除会让素材记录与已生成的配音、方案彻底无法找回。
                请重启应用重试；若反复出现，请从「设置 → 关于」导出诊断报告并反馈。
                """)
        } catch {
            // 连内存模式都起不来：不再 try!（那会当场崩掉整个进程，用户连一句原因都看不到）。
            MixLog.error("数据库完全无法初始化：\(error.localizedDescription)")
            return .refusedBySchemaGate(message: """
                数据库无法打开，临时模式也起不来，这次启动没有加载任何数据。

                原因：\(error.localizedDescription)

                库文件没有被改动，不要删除它。请反馈这条信息以便排查。
                """
            )
        }
    }
}

private extension SchemaChangeKind {
    /// 只用于日志与文案的计数，不参与任何判定。
    var addedCount: Int {
        switch self {
        case .identical: return 0
        case .additionsOnly(let added): return added.count
        case .destructive(let removed, let added): return removed.count + added.count
        }
    }
}
