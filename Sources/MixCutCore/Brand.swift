import Foundation

/// 应用身份的唯一真源。
///
/// 除本文件外，任何 .swift 源码（含测试）不得再出现身份字面量 ——
/// 由 `BrandIdentityTests` 用「小写短名 / `<数据目录>.store` / `appendingPathComponent("<数据目录>"`」
/// 三条判据机械守住。换品牌时只改「当前身份」这一组。
public enum Brand {

    // MARK: - 当前身份

    /// 小写短名。日志文件名、MCP 注册名、云端配音别名、自测临时文件名都由它派生。
    public static let shortName = "suncut"
    public static let bundleID = "com.suncut.app"
    public static let dataDirectoryName = "Suncut"
    public static let storeFileName = "Suncut.store"

    /// MCP 注册名 —— 就是小写短名，用户在客户端里看到的 server 键。
    public static var mcpServerName: String { shortName }

    /// 云端声音克隆的 `preferred_name` 兜底值（用户没起名字时）。
    public static var voiceAliasFallback: String { shortName }

    public static var logFileName: String { "\(shortName).log" }
    public static var logDirectoryComponent: String { "\(bundleID)/logs" }
    public static var aiFailDirectoryComponent: String { "\(bundleID)/ai-fail" }

    // MARK: - 显示身份（上屏给人看、或发给模型的措辞）

    /// 产品显示名：菜单栏、侧边栏、欢迎页、引导页、错误文案都读它。
    public static let displayName = "SunCut"

    /// 用户嘴上的简称，会写进发给模型的自我介绍。
    public static let abbrev = "SC"

    /// 一句话定位。欢迎页与引导页共用它 —— 同一句话写两遍就一定会漂。
    public static var tagline: String { "AI 驱动的广告视频混剪工具" }

    // MARK: - 历史身份

    // ⚠️ 下面这些值指的是**已经写在用户盘上的路径**，换品牌时绝不能跟着上面一起改：
    // 一改，老用户下载过的模型、迁移前的库文件就再也找不回来。

    /// 旧版 Caches 根：`~/Library/Caches/<此值>/whisper-models`。
    static let legacyCacheBundleID = "com.mixcut.app"

    /// 更早的构建把 whisper 模型放在 `~/.cache/<此值>/models`，现在只作为扫描来源读取。
    static let legacyShortName = "mixcut"

    /// 换品牌前的数据目录名与库文件名 —— 一次性迁移要读它们。
    static let legacyDataDirectoryName = "MixCut"
    static let legacyStoreFileName = "MixCut.store"

    /// 换品牌前的显示名与简称。只给「旧字样残留」守卫取值，不参与任何展示。
    static let legacyDisplayName = "MixCut"
    static let legacyAbbrev = "MC"

    /// 换品牌前的 bundle id：设置整域拷贝的**来源域**。新域是空的，不搬就等于用户设置全丢。
    static let legacyBundleID = "com.mixcut.app"

    static var legacyWhisperModelsComponent: String { "\(legacyCacheBundleID)/whisper-models" }
    static var legacyHomeCacheModelsComponent: String { ".cache/\(legacyShortName)/models" }
}
