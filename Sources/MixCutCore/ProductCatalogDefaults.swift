import Foundation

/// 产品目录的内置常量。放在 MixCutCore 而非 App target：
/// backfill（App）、Catalog 投影（Core）、启动修补测试（Core 测试）需要**同一个**字面量，
/// 两边各抄一个 UUID 迟早漂移。
public enum ProductCatalogDefaults {
    /// 「默认产品」的固定哨兵 UUID（全 0xAB 段，肉眼可辨，且不与定宽测试夹具的 0/100/200 段冲突）。
    /// 存量项目与视频在首次升级时全部归入它。
    public static let defaultProductID = UUID(uuidString: "ABABABAB-0000-0000-0000-000000000001")!

    public static let defaultProductName = "默认产品"
}
