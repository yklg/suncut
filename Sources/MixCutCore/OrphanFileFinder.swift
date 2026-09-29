import Foundation

/// 找出"磁盘上存在但数据库已无任何记录引用"的孤儿文件（供延后删除 GC 使用）。
/// 安全原则：判断不确定时保守不删——只返回明确未被引用的。
public enum OrphanFileFinder {
    /// 归一化路径：去末尾斜杠 + 小写（macOS APFS 默认大小写不敏感）
    private static func normalize(_ path: String) -> String {
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
}
