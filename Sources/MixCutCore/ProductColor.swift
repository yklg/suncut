import Foundation

/// 产品的自动配色序号（纯逻辑，无 UI 依赖）。
///
/// 为什么用稳定散列而不是「产品数组下标」：下标法在产品被删除/重排后，
/// 后续所有产品颜色整体漂移——用户已经靠颜色记住「绿色=牙贴」，颜色一变认知就断。
/// id 散列让每个产品在创建那一刻颜色就固定，永不因其他产品的增删而变化。
public enum ProductColor {
    /// UI 色板数量（ProductPalette.colors 必须有同数元素）
    public static let paletteCount = 6

    /// - Returns: 颜色序号 0..paletteCount-1；默认产品返回 nil（UI 侧 nil 渲染灰色）
    public static func colorIndex(forProductID id: UUID, isDefault: Bool) -> Int? {
        guard !isDefault else { return nil }
        // FNV-1a 32 位散列（与 uuid 大小写无关：先 lowercase）
        var hash: UInt32 = 0x811C9DC5
        for byte in id.uuidString.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return Int(hash % UInt32(paletteCount))
    }
}
