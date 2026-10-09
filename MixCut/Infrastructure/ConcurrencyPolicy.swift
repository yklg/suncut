import Foundation

/// 并发策略 — 基于 HardwareProfile 计算各场景的最佳并发数
///
/// **Mac 专属公式**，与 Windows 版（独立 NVIDIA NVENC）的逻辑不同：
/// - Apple Silicon 的 Media Engine 是独立硬件单元，数量决定编码并发上限
/// - 单 Media Engine 单路 1080p H.264 已可达 500+ fps，叠太多路会排队，反而占内存
/// - Whisper 在 Apple Silicon 上跑 Metal 后端，单次只能跑一个模型（GPU 抢占）
///
/// 设计原则：保守而不过度激进。MacBook 散热远不如台式机，太高并发会触发热降频，
/// 实际收益曲线在 3-4 路达到 90% 之后趋平。
@MainActor
enum ConcurrencyPolicy {
    /// 视频导出 / 分镜导出并发数（按 Media Engine 限制）
    static func maxExportConcurrency() -> Int {
        let profile = HardwareProfile.shared
        let raw: Int = {
            guard profile.videoToolboxAvailable else {
                // 软件 libx264：按 CPU 核数粗算
                return max(1, min(4, profile.physicalCores / 4))
            }
            guard profile.isAppleSilicon else {
                // Intel + Quick Sync：保守 2 路
                return 2
            }
            // Apple Silicon：基于 Media Engine 数
            switch profile.mediaEngineCount {
            case 4:  return 6   // Ultra：4 ME 但单 ME 已快，留缓冲
            case 2:  return 4   // Max
            case 1:  return 3   // base / Pro
            default: return 2
            }
        }()
        return Self.memoryGate(raw, memoryGB: profile.memoryGB)
    }

    /// 视频分析（场景检测 + 解码 + AI 文本调用）并发数
    /// 主要受 CPU 滤镜和 SwiftData 写入限制，不全是硬件
    ///
    /// 2026-10-09 真机基线（计划 §Q-1）：本机建议 2 路时，第三条素材的**第一段 ffmpeg 检测**
    /// 被排空等了 80s —— 素材一多，这一层就是用户看到的"导入慢"。所以这里开了一个用户覆盖口，
    /// 但本机识别另有 `LocalWhisperGate` 单模型闸兜底（§Q-2 实测并行是负收益），
    /// 提高这一层不会把两路 large-v3 放出来抢 GPU。
    static func maxAnalyzeConcurrency() -> Int {
        analyzeOverride ?? hardwareMaxAnalyzeConcurrency()
    }

    /// 用户覆盖键：导入「同时分析视频数」。0 或没写过 = 跟随硬件建议。
    static let analyzeOverrideKey = "concurrency.maxAnalyzeVideos"
    /// 上限 6：再高只会让解码/磁盘互相抢，且 20–50 条素材一批也用不到更多路。
    static let analyzeOverrideCap = 6
    /// 环境变量优先于偏好：与 `MIXCUT_MCP_PORT` 同一套办法 —— 验证/压测时临时调一个数，
    /// 不必往用户的默认域里写东西，也不留下"改完忘了改回来"的状态。
    static let analyzeEnvironmentKey = "MIXCUT_ANALYZE_CONCURRENCY"

    static var analyzeOverride: Int? {
        if let raw = ProcessInfo.processInfo.environment[analyzeEnvironmentKey],
           let n = Int(raw.trimmingCharacters(in: .whitespaces)), n >= 1 {
            return min(n, analyzeOverrideCap)
        }
        let stored = UserDefaults.standard.integer(forKey: analyzeOverrideKey)
        guard stored >= 1 else { return nil }
        return min(stored, analyzeOverrideCap)
    }

    /// 硬件建议值。覆盖不许把它抹掉 —— 设置页要能同时显示"你选的"和"机器建议的"。
    static func hardwareMaxAnalyzeConcurrency() -> Int {
        let profile = HardwareProfile.shared
        let raw: Int = {
            guard profile.isAppleSilicon else {
                return max(2, min(3, profile.physicalCores / 4))
            }
            // Apple Silicon
            switch profile.mediaEngineCount {
            case 4:  return 4   // Ultra
            case 2:  return 3   // Max
            case 1:  return 2   // base / Pro
            default: return 2
            }
        }()
        return Self.memoryGate(raw, memoryGB: profile.memoryGB)
    }

    /// D2: 8GB 内存机器并发跑多路 export + ASR + 解码会触发 swap 反而更慢
    /// 强制把基础并发降到 ≤2，给系统留出缓冲；> 8GB 的机器透传原值
    private static func memoryGate(_ n: Int, memoryGB: Int) -> Int {
        memoryGB <= 8 ? min(n, 2) : n
    }

    /// ASR 并发数（受 Metal GPU 抢占限制）
    /// **关键**：whisper.cpp 在 Apple Silicon 用 Metal 后端，单次只能跑一个模型
    /// 并行多个 Whisper 反而互相抢 GPU 上下文，更慢
    static func maxASRConcurrency() -> Int {
        let profile = HardwareProfile.shared
        guard profile.isAppleSilicon else {
            return 1   // Intel CPU 后端，单线程跑
        }
        switch profile.mediaEngineCount {
        case 4, 2:  return 2   // Max/Ultra GPU 资源充足，可以 2 路
        default:    return 1   // base/Pro Metal 抢占，单路
        }
    }

    // MARK: - 解释文案（给 Settings UI 用）

    static func explainExport() -> String {
        let profile = HardwareProfile.shared
        let n = maxExportConcurrency()
        if !profile.isAppleSilicon {
            return profile.videoToolboxAvailable
                ? "\(n) 路 (Intel Quick Sync)"
                : "\(n) 路 (CPU libx264)"
        }
        return "\(n) 路 (\(profile.mediaEngineDescription))"
    }

    static func explainAnalyze() -> String {
        let n = maxAnalyzeConcurrency()
        let profile = HardwareProfile.shared
        let base: String = {
            if profile.isAppleSilicon {
                return "\(n) 路 (\(profile.chipFamily.rawValue) \(profile.chipTier.displayName) · CPU 滤镜 + VT 解码)"
            }
            return "\(n) 路 (\(profile.chipBrandString))"
        }()
        let hardware = hardwareMaxAnalyzeConcurrency()
        // 手动覆盖时把机器建议值一并显示：只写"4 路"会让人以为硬件算出来的就是 4
        return n == hardware ? base : "\(base) · 手动覆盖（机器建议 \(hardware) 路）"
    }

    static func explainASR() -> String {
        let n = maxASRConcurrency()
        let profile = HardwareProfile.shared
        if profile.isAppleSilicon {
            return "\(n) 路 (Metal 抢占，避免互相干扰；全局识别闸已强制生效)"
        }
        return "\(n) 路 (CPU)"
    }
}
