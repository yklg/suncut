import Foundation

/// 找出"磁盘上存在但数据库已无任何记录引用"的孤儿文件（供延后删除 GC 使用）。
/// 安全原则：判断不确定时保守不删——只返回明确未被引用的。
public enum OrphanFileFinder {
    /// 归一化路径：去末尾斜杠 + 小写（macOS APFS 默认大小写不敏感）。
    /// internal 而非 public：`MissingMaterialFinder` 必须共用这一颗 —— 两条轴各写一套归一，
    /// 同一个文件在两侧会被认成两个，那正是 GC 误删的形状。
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased()
    }

    /// - Parameters:
    ///   - onDisk: 磁盘上扫描到的文件绝对路径
    ///   - referenced: 数据库记录引用到的路径集合
    /// - Returns: onDisk 中未被引用的路径（保持 onDisk 原始顺序与原始字符串）
    public static func orphanFiles(onDisk: [String], referenced: Set<String>) -> [String] {
        let refNorm = Set(referenced.map(normalize))
        return onDisk.filter { !refNorm.contains(normalize($0)) }
    }

    /// 供破坏性回收（GC）使用的保守入口：只有「引用集可信」时才给出可删清单。
    /// 不可信的两种形态：引用集为空、或引用集与磁盘零交集 —— 都说明判断依据本身出了问题
    /// （库打不开退到内存模式、目录迁移尚未改写路径、路径前缀变更等），此时按清单全删不可逆。
    public static func safeOrphanFiles(onDisk: [String], referenced: Set<String>) -> [String] {
        guard !onDisk.isEmpty else { return [] }
        let refNorm = Set(referenced.map(normalize))
        // 零交集即视为判断依据不可信，不交给调用方任何可删清单
        guard onDisk.contains(where: { refNorm.contains(normalize($0)) }) else { return [] }
        return orphanFiles(onDisk: onDisk, referenced: referenced)
    }

    /// 内容哈希目录名：`.../Videos/<64 位十六进制>/<文件>` 的倒数第二段。
    ///
    /// 为什么要它：`normalize` 只做「去尾斜杠 + 小写」，比的是**整条路径**。一旦库里的
    /// `localPath` 前缀漂移（品牌目录改名、外置卷、同步盘），同一条内容就会在库侧与盘侧
    /// 拼成两个坐标 —— 这正是 `TC-OF-15` 那条已知局限的形状：只要有一条路径碰巧同写法，
    /// 保守门就整批放行，其余在用文件全进可删清单（2026-10-04 日志里 GC 一次删 151 个）。
    /// 视频库是**内容寻址**的：目录名就是 SHA-256。因此「这颗哈希目录下有没有库内引用」
    /// 是一条比路径字符串更硬的判据 —— 路径前缀漂了也能认出来。
    public static func contentHashDirectoryName(inVideoPath path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2 else { return nil }
        let dir = String(comps[comps.count - 2])
        guard dir.count == 64, dir.allSatisfy(\.isHexDigit) else { return nil }
        return dir.lowercased()
    }

    /// 在保守门之上再加一道**目录级保护**：列在 `protectedDirectoryNames` 里的内容哈希目录，
    /// 其下文件一律不进可删清单。调用方从「全部 `Video.contentHash`」与「`localPath` 里能解析出的
    /// 哈希目录名」两处构集合 —— 路径漂移的那批因此仍被认成在用。
    ///
    /// 作用面刻意只到「目录名」这一级：它不猜文件是否存在、不读写盘，纯值函数照样可单测。
    /// 拦不住什么：不属于任何内容哈希目录的文件（缩略图、分镜头产物）仍只走路径比对——
    /// 那些轴的库侧命名不含哈希，扩不出第二条坐标；这条门只负责视频正文这一档。
    public static func safeOrphanFiles(onDisk: [String], referenced: Set<String>,
                                       protectedDirectoryNames: Set<String>) -> [String] {
        let safe = safeOrphanFiles(onDisk: onDisk, referenced: referenced)
        guard !protectedDirectoryNames.isEmpty else { return safe }
        let protected = Set(protectedDirectoryNames.map { $0.lowercased() })
        return safe.filter { path in
            let comps = path.split(separator: "/", omittingEmptySubsequences: true)
            guard comps.count >= 2 else { return true }
            return !protected.contains(String(comps[comps.count - 2]).lowercased())
        }
    }
}
