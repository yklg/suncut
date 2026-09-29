import Foundation

/// 一条「把旧数据目录里的一项搬到新目录」的指令。只带名字、不带绝对路径，便于单测。
public struct DirectoryMove: Equatable, Hashable {
    public let fromName: String
    public let toName: String

    public init(fromName: String, toName: String) {
        self.fromName = fromName
        self.toName = toName
    }
}

/// 数据目录一次性迁移的**决策 + 执行层**：只用 Foundation，因此能被 `swift test` 直接跑在临时目录上。
/// App 侧（`FileHelper`）只剩"取 Brand 的值、写完成标志、记日志"这一层薄壳。
public enum BrandDirectoryMigration {

    /// 一张搬迁清单。
    public struct Plan: Equatable {
        public let moves: [DirectoryMove]
        /// 留在旧目录不搬的条目（历史手工备份）
        public let keepBehind: [String]

        public init(moves: [DirectoryMove], keepBehind: [String]) {
            self.moves = moves
            self.keepBehind = keepBehind
        }
    }

    /// 执行结果。`collision`/`failed` 都必须让调用方**不写完成标志**，孤儿 GC 因此继续冻着。
    public enum Outcome: Equatable {
        /// 清单跑完，实际搬迁的条目数（0 = 没东西可搬，含"已经搬完了"的重入）
        case done(moved: Int)
        /// 新旧两处同名：不敢猜哪一份在用，停在原地
        case collision(name: String)
        /// 文件系统报错
        case failed(name: String, reason: String)
    }

    /// 留在旧目录、不搬过去的前缀：历史手工备份。搬走只会白白把回退料一起搬进新家。
    public static let keepBehindPrefix = "backup-"

    /// store 的 side-car 后缀，必须与库文件本体一起搬（少一个就会「库在、内容像空的」）。
    static let storeSidecarSuffixes = ["-wal", "-shm"]

    public static func plan(
        oldDirectoryName: String,
        newDirectoryName: String,
        legacyStoreFileName: String,
        storeFileName: String,
        entries: [String]
    ) -> Plan {
        let sameDirectory = oldDirectoryName == newDirectoryName
        var moves: [DirectoryMove] = []
        var keepBehind: [String] = []

        for entry in entries {
            if entry.hasPrefix(keepBehindPrefix) {
                // 只有真的在往另一个目录搬时，"留下不搬"才成立；同目录内没有留下可言
                if !sameDirectory { keepBehind.append(entry) }
                continue
            }
            let target = destinationName(
                for: entry,
                legacyStoreFileName: legacyStoreFileName,
                storeFileName: storeFileName
            )
            // 同目录且同名 ⇒ 这一步没有可做的事，不塞给执行器（阶段 3 未翻值时整张清单为空）
            if sameDirectory && target == entry { continue }
            moves.append(DirectoryMove(fromName: entry, toName: target))
        }
        moves.sort { ($0.fromName, $0.toName) < ($1.fromName, $1.toName) }
        keepBehind.sort()
        return Plan(moves: moves, keepBehind: keepBehind)
    }

    /// 按清单真搬。同卷 `moveItem` 是 rename，GB 级也瞬间完成，绝不用 `cp -R`。
    ///
    /// 幂等：源已经不在（上轮搬走了）就跳过，所以重入得到 `.done(moved: 0)`。
    /// 一旦撞上"新旧两处同名"或文件系统报错就立即返回，**不继续搬剩下的**，把现场留给人工。
    public static func execute(
        _ plan: Plan,
        oldDirectory: URL,
        newDirectory: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        var moved = 0
        for move in plan.moves {
            let src = oldDirectory.appendingPathComponent(move.fromName)
            let dst = newDirectory.appendingPathComponent(move.toName)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            if fileManager.fileExists(atPath: dst.path) { return .collision(name: move.toName) }
            do {
                try fileManager.moveItem(at: src, to: dst)
                moved += 1
            } catch {
                return .failed(name: move.fromName, reason: error.localizedDescription)
            }
        }
        return .done(moved: moved)
    }

    /// 只认「库本体 + 两个已知 side-car」这一种改名，其余一律原名搬走 —— 宁可少改不可猜。
    private static func destinationName(
        for entry: String,
        legacyStoreFileName: String,
        storeFileName: String
    ) -> String {
        if entry == legacyStoreFileName { return storeFileName }
        for suffix in storeSidecarSuffixes where entry == legacyStoreFileName + suffix {
            return storeFileName + suffix
        }
        return entry
    }
}

/// 库里存的绝对路径前缀改写。
public enum StoredPathPrefixRewriter {
    public static func rewrite(_ value: String, from oldPrefix: String, to newPrefix: String) -> String? {
        guard oldPrefix != newPrefix else { return nil }
        // 必须是「前缀 + 路径分隔符」才算命中：/…/OldNameBackup 不是 /…/OldName 底下的东西
        guard value.hasPrefix(oldPrefix), value.count > oldPrefix.count,
              value[value.index(value.startIndex, offsetBy: oldPrefix.count)] == "/" else { return nil }
        return newPrefix + value.dropFirst(oldPrefix.count)
    }
}

/// 换 bundle id 时**跨域设置导入**的放行面。
public enum LegacySettingsImport {
    /// 目录迁移标志：存"已迁到哪个目录名"
    public static let migratedToKey = "brandDirectoryMigratedTo"
    /// 设置导入标志：存"已从哪个域导入过"
    public static let importedFromKey = "settingsImportedFrom"

    /// 不许跨域的键。
    /// 两个标志属于目标域自己的判断 —— 从旧域继承过来会冒充"已经做过"，迁移就被静默跳过；
    /// `dismissedUpdateVersion` 是已删除的更新检查组件留下的孤儿键。
    public static let neverImportedKeys: Set<String> = [
        "dismissedUpdateVersion", migratedToKey, importedFromKey,
    ]

    public static func keysToImport(_ stored: Set<String>) -> Set<String> {
        stored.subtracting(neverImportedKeys)
    }
}
