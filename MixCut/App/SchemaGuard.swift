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

        init(lines: [String] = [], updatedAt: Date = Date(),
             doneSteps: [String] = [], lastRunAt: [String: Date] = [:]) {
            self.lines = lines
            self.updatedAt = updatedAt
            self.doneSteps = doneSteps
            self.lastRunAt = lastRunAt
        }

        var fingerprint: SchemaFingerprint { SchemaFingerprint(descriptorLines: lines) }
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

    static func readLedger(storeURL: URL) -> Ledger? {
        guard let data = try? Data(contentsOf: ledgerURL(storeURL: storeURL)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Ledger.self, from: data)
    }

    /// 只在**开库成功后**调用。写失败不致命（下次启动会多备份一次），但必须留日志。
    @discardableResult
    static func writeLedger(storeURL: URL, lines: [String], previous: Ledger?) -> Bool {
        var ledger = previous ?? Ledger()
        ledger.lines = lines
        ledger.updatedAt = Date()
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

    /// 只保留最近 `keeping` 份。命名里的时间戳是 UTC 定长格式，字典序即时间序。
    static func pruneBackups(storeURL: URL, keeping: Int = 3) {
        let parent = storeURL.deletingLastPathComponent()
        let prefix = storeURL.lastPathComponent + "."
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil) else { return }
        let backups = entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(".backup") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in backups.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: stale)
        }
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

    // MARK: - 开库（门在这）

    /// 门 + 备份 + 开库的完整一次尝试。**必须在建 `ModelContainer` 之前**走这里。
    static func openStore(schema: Schema, storeURL: URL) -> StoreOpenOutcome {
        let lines = descriptorLines(from: schema)
        let current = SchemaFingerprint(descriptorLines: lines)
        let ledger = readLedger(storeURL: storeURL)
        let decision = decideSchemaGate(recorded: ledger?.fingerprint, current: current)

        func config() -> ModelConfiguration {
            ModelConfiguration(schema: schema, url: storeURL)
        }
        func openNormally() -> StoreOpenOutcome {
            do {
                let container = try ModelContainer(for: schema, configurations: [config()])
                _ = writeLedger(storeURL: storeURL, lines: lines, previous: ledger)
                pruneBackups(storeURL: storeURL)
                return .opened(container)
            } catch {
                return degradeToMemory(schema: schema, cause: error)
            }
        }

        switch decision {
        case .unchanged, .noPriorRecord:
            return openNormally()

        case .untrustworthy(let recorded):
            // 描述行 0 条 = 模型没注册进 Schema。这是装配失误，不是"schema 没变"，
            // 也不能拿它去覆盖账本 —— 一旦写空，这道门就永久废掉了。
            let note = recorded == nil ? "本次未取到任何模型定义" : "上次记录与本次取值均不可信"
            MixLog.error("schema 门：不可信指纹（\(note)），拒绝开库")
            return .refusedBySchemaGate(message: """
                未能读取应用的数据结构定义（\(note)）。

                这通常是程序自身的问题而不是数据坏了，因此这次启动没有改动你的库文件。
                请退回上一个版本并反馈；不要删除任何文件。
                """)

        case .changed(let previousFP, let currentFP):
            let kind = classifySchemaChange(before: ledger?.lines ?? [], after: lines)
            let backupDirectory: URL?
            do {
                let made = try performBackup(storeURL: storeURL, previous: previousFP, current: currentFP)
                backupDirectory = verifyBackup(directory: made, storeURL: storeURL) ? made : nil
                if backupDirectory == nil {
                    try? FileManager.default.removeItem(at: made)
                    MixLog.error("schema 门：改前备份校验未通过，已删除该份备份")
                }
            } catch {
                backupDirectory = nil
                MixLog.error("schema 门：改前备份失败 \(error.localizedDescription)")
            }

            if kind.isLightweightCompatible && backupDirectory != nil {
                MixLog.info("schema 只增行变更（+\(kind.addedCount) 项），已生成改前备份，照常开库")
                return openNormally()
            }

            if case .destructive(let removed, let added) = kind {
                let path = backupDirectory?.path ?? "（本次未能生成备份，请勿删除任何文件）"
                MixLog.error("schema 门：检测到不可自动迁移的变更（消失 \(removed.count) 行 / 新增 \(added.count) 行），拒绝开库")
                return .refusedBySchemaGate(message: """
                    这次升级改动了数据结构，且没有可用的自动迁移，已拒绝打开数据库（你的库文件没有被改动）。

                    消失的定义 \(removed.count) 项、新增 \(added.count) 项，例如：
                    \(removed.prefix(3).joined(separator: "\n"))

                    改前备份：\(path)
                    回退办法：装回上一个版本即可继续使用；若确认要升级，需要为这次变更补一条自定义迁移。
                    """)
            }

            // 兼容变更但备份没成 —— 此时不许"赌一把"开库：没有退路的变更正是清库事故的原场。
            return .refusedBySchemaGate(message: """
                数据结构有变更，但改前备份没能生成（磁盘满 / 权限 / 目录不可写），因此这次启动没有打开数据库。

                请腾出空间或换到可写位置后重试；不要删除任何文件。
                """)
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
