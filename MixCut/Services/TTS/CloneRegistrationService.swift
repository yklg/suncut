import Foundation

/// 复刻音色注册服务（M2，qwen 路线）：把本地参考音频注册成账号级音色。
///
/// ## 分工（与 `VoiceCloneService` 的关系）
///
/// - `VoiceCloneService`：**底层 HTTP 客户端**，只管「一份 base64 音频 → 一个 voiceId」。
///   它是逐视频克隆链路的既有实现，行为与调用方无关。
/// - 本服务（`CloneRegistrationService`）：**注册流程编排** —— 样本准备（裁切/转码）、
///   质量校验、授权前置、落库。复用上面的客户端，不重复实现 HTTP。
///
/// ## 为什么样本准备必须在本地做
///
/// 官方要求样本 10–20s、≤10MB。三个来源都不天然满足：
/// - **上传整段音频**：用户给的是一首歌/一段视频，几十秒到几分钟，且体积常超 10MB；
/// - **视频提取**：`VocalSeparationService` 产出的是**整轨人声**（可能几分钟），
///   直接送注册必被拒；
/// - **已有克隆音色**：`Video.clonedVoiceId` 注册时用的是当时的参考音频，
///   但那条音频不保证留在本机（可能是用户当时临时选的）。
///
/// 所以统一在注册前裁成一段 10–20s 的**合规样本**再送注册。
actor CloneRegistrationService {
    enum PrepError: Error, LocalizedError {
        case sourceUnreadable
        case durationProbeFailed(String)
        case trimmingFailed
        case sampleRejected(String)      // 携带用户可读原因

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable:
                return "读不到参考音频文件，它可能已被移动或删除"
            case .durationProbeFailed(let d):
                return "探测音频时长失败：\(d)"
            case .trimmingFailed:
                return "裁切参考音频失败"
            case .sampleRejected(let reason):
                return reason
            }
        }
    }

    /// 裁切后的合规样本（注册实际送出去的音频）。
    struct PreparedSample: Sendable {
        /// 送注册的音频路径（临时文件，调用方负责最终清理或在注册成功后保留）。
        let path: String
        let durationSeconds: Double
        let byteSize: Int
        /// 样本是否被裁切过（false = 原文件就合规，直接用）。
        let wasTrimmed: Bool
    }

    private let runner = FFmpegRunner()
    private let cloneService: VoiceCloneService
    private let apiKeyProvider: @Sendable () -> String?

    init(cloneService: VoiceCloneService = VoiceCloneService(),
         apiKeyProvider: @escaping @Sendable () -> String? = { KeychainHelper.dashScopeKey }) {
        self.cloneService = cloneService
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - 样本准备

    /// 把任意本地音频准备成合规样本（10–20s / ≤10MB）。
    /// - Parameter sourceDuration: 已探测到的源时长；传 nil 则由本方法探测。
    @discardableResult
    func prepareSample(from sourcePath: String,
                       sourceDuration: Double? = nil) async throws -> PreparedSample {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { throw PrepError.sourceUnreadable }

        let duration: Double
        if let sourceDuration {
            duration = sourceDuration
        } else {
            duration = try await probeDuration(of: sourcePath)
        }
        // 同上：属性的异步读取要拆出来（属性读取虽非 async，写在 ?? 里与上面的
        // await 混用会让整个表达式落进 autoclosure）。
        let attrs = try? fm.attributesOfItem(atPath: sourcePath)
        let size = (attrs?[.size] as? Int) ?? 0

        // 原文件已合规 → 直接用（不重编码，避免不必要的音质损失）
        if CloneSampleValidator.validate(durationSeconds: duration, byteSize: size) == .ok {
            return PreparedSample(path: sourcePath, durationSeconds: duration,
                                 byteSize: size, wasTrimmed: false)
        }

        // 需裁切：取中段（避开开头/结尾的静音与寒暄，中段人声最连续）
        let target = Self.trimDuration(for: duration)
        let start = max(0, min((duration - target) / 2.0, duration - target))
        let out = FileHelper.tempDirectory
            .appendingPathComponent("clone-sample-\(UUID().uuidString).mp3")
        try? fm.removeItem(at: out)
        defer { try? fm.removeItem(at: out) }   // 失败路径不留半成品

        let args = [
            "-ss", String(format: "%.3f", start),
            "-t", String(format: "%.3f", target),
            "-i", sourcePath,
            "-vn",
            "-acodec", "libmp3lame", "-b:a", "64k",   // 64kbps 足够复刻，且 20s 仅约 160KB
            "-y", out.path,
        ]
        do {
            _ = try await runner.run(arguments: args, timeoutSeconds: 120)
        } catch {
            throw PrepError.trimmingFailed
        }
        guard fm.fileExists(atPath: out.path) else { throw PrepError.trimmingFailed }

        // ⚠️ 不能写成 `try? await probeDuration(...) ?? target`：?? 的右操作数是
        // autoclosure，不支持并发调用（编译器直接报"async call in an autoclosure"）。
        let newDuration = (try? await probeDuration(of: out.path)) ?? target
        let newSize = ((try? fm.attributesOfItem(atPath: out.path))?[.size] as? Int) as? Int ?? 0

        let verdict = CloneSampleValidator.validate(durationSeconds: newDuration, byteSize: newSize)
        guard case .ok = verdict else {
            // 裁完仍不合规（如源太短）→ 如实报原因，不硬着头皮注册（那必然被服务端拒）。
            throw PrepError.sampleRejected(
                CloneSampleValidator.message(for: verdict) ?? "参考音频不符合要求")
        }
        return PreparedSample(path: out.path, durationSeconds: newDuration,
                             byteSize: newSize, wasTrimmed: true)
    }

    /// 裁切目标时长：取区间中点（16s），对10–20s 两端都留有余量。
    static func trimDuration(for sourceDuration: Double) -> Double {
        let lo = CloneSampleValidator.minDurationSeconds
        let hi = CloneSampleValidator.maxDurationSeconds
        let mid = (lo + hi) / 2
        // 源比下限还短 ⇒ 无从裁切，返回原长（交由校验报「太短」）
        if sourceDuration < lo { return max(0.1, sourceDuration) }
        return min(mid, sourceDuration)
    }

    // MARK: - 探测与注册

    func probeDuration(of path: String) async throws -> Double {
        do {
            let out = try await runner.runProbe(arguments: [
                "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", path,
            ])
            guard let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PrepError.durationProbeFailed("ffprobe 返回了非数字内容")
            }
            return d
        } catch let e as PrepError {
            throw e
        } catch {
            throw PrepError.durationProbeFailed(error.localizedDescription)
        }
    }

    /// 注册一个复刻音色。
    /// - Parameters:
    ///   - displayName: 用户填的名字（中文可；供应商侧 ASCII 名内部清洗）。
    ///   - consentAccepted: 授权确认。**false 直接拒绝** —— 未确认授权不得注册
    ///     （合规前置，不是可选项）。
    /// - Returns: 落库用的 `VoiceProfile`（未落库，由调用方 insert）。
    @discardableResult
    func register(displayName: String,
                  samplePath: String,
                  sampleDuration: Double,
                  consentAccepted: Bool,
                  kind: CloneProfileKind,
                  keyFingerprint: String) async throws -> VoiceProfile {
        // 授权是硬前置。放在最前面而不是最后 —— 授权检查不该消耗任何昂贵操作。
        guard consentAccepted else {
            throw PrepError.sampleRejected("请先确认你拥有该声音的合法授权")
        }
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw PrepError.sampleRejected("尚未配置千问 API Key，请到「设置」填写后重试")
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PrepError.sampleRejected("给这个音色起个名字吧")
        }

        let voiceId = try await cloneService.enroll(
            referenceAudioPath: samplePath, preferredName: trimmedName)

        return VoiceProfile(
            name: trimmedName,
            voiceId: voiceId,
            providerName: CloneVoiceNaming.sanitizeForProvider(
                trimmedName, maxLength: CloneVoiceNaming.ProviderLimit.qwenPreferredName),
            rawModel: VoiceCloneService.targetModel,
            kind: kind,
            keyFingerprint: keyFingerprint,
            sampleAudioPath: samplePath,
            sampleDurationSeconds: sampleDuration)
    }
}