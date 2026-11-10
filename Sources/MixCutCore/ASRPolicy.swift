import Foundation

/// ASR 这条线的**常量与规则**唯一宿主（计划 §3.1）。
///
/// 铁律：本文件（以及整个 `Sources/MixCutCore`）**不得读写 UserDefaults / Keychain / 磁盘**。
/// "当前偏好是什么"属状态，由 App 侧 `ASRSettings` 提供，并以**入参**传给 `ASREngineDecision`。
/// 这条边界由守卫守着（计划 §10.4 TC-86：`grep UserDefaults Sources/MixCutCore/` 必须为空）。
public enum ASRPolicy {

    /// 整片与逐段**恒用**同一档（用户裁定 2026-09-28）。不做"整片大档、逐段小档"的暗降级 ——
    /// 降级会让同库台词的来源不可追溯，且实测小档在同一段素材上写出 4 处错字与整段繁体。
    ///
    /// ⚠️ 2026-11-10 改用 `large-v3-q5_0` 是**量化**，不是上面那句说的**降档**。
    ///    权重仍是 large-v3，只是把 f16 权重压成 5-bit（3,095,033,483 → 1,081,140,203 字节），
    ///    文件头仍是 `ggml`、推理走同一张计算图。"小档写出 4 处错字"说的是 medium/small
    ///    那类**换了权重**的档位，与量化不是同一件事，别拿它反推这条改动是错的。
    ///    动因：包体 2.9GB 超过 GitHub Release 单附件 2GiB 上限，安装包进不了 Assets。
    public static let engineTier: String = "large-v3-q5_0"

    /// 该档对应的模型文件名（`WhisperModelCatalog` 的表键之一）。
    public static let engineFileName: String = "ggml-large-v3-q5_0.bin"

    /// 用户从没设过偏好时的默认档。**强制本地**：不花钱、不依赖凭据、结果可复现。
    public static let defaultPreference: ASRPreference = .local

    /// 逐段整批的批次策略上限（门面用；计划 §3.4）。
    /// 实测本机 large-v3 单段 9.6 秒音频耗时 4.5 秒，一条视频 17-20 段 ≈ 1.2-1.5 分钟。
    public static let perSegmentTimeoutSeconds: Double = 180
    public static let consecutiveFailureLimit: Int = 3

    // MARK: - 逐段重听的短窗退化对策（计划 v8，宽窗那条已整块删除）

    /// **简体风格锚**：与业务内容零交集的固定文本，喂给 whisper 的 `--prompt`。
    ///
    /// ⚠️ 绝不可改成"喂邻居台词"：受控实验 E2 实测，邻居文本里的错写法会被逐字搬进本段
    ///    （音频说的是"奶香"，prompt 写"乃香"就输出"乃香"；"清清甜甜"被写成"轻轻甜甜"）。
    ///    锚只钉**书写风格**、不含任何业务词，才拿到"钉简体"的收益而没有传染面。
    public static let retakeStyleAnchor =
        "下面是一段简体中文口语旁白，请使用简体中文书写，句子通顺，标点规范。"

    /// 曾经这里还住着宽窗（把 3 秒段扩到 12 秒再按时间戳裁回）的四个参数 + 接缝容差。
    /// **2026-09-29 整块删除**：两遍实测都是净收益为负（4 段只产出 1 段，且修复前那版会把邻居台词写进来），
    /// 而"给中文原生引擎铺路"这条前景也随 F 收档消失。要重看这段历史：另立计划 §8 与 §13。
}
