import Foundation

/// FFmpeg 执行进度回调
struct FFmpegProgress: Sendable {
    let frame: Int
    let fps: Double
    let time: Double      // 当前处理到的秒数
    let speed: Double
    let percentage: Double // 0.0 - 1.0

    static let zero = FFmpegProgress(frame: 0, fps: 0, time: 0, speed: 0, percentage: 0)
}

/// FFmpeg 错误类型
enum FFmpegError: LocalizedError {
    case binaryNotFound
    case executionFailed(exitCode: Int32, stderr: String)
    case outputParsingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "视频处理组件未找到，请重新安装应用"
        case .executionFailed(let code, let stderr):
            // ⚠️ 不要把 ffmpeg 原始 stderr 糊给用户 —— 末尾 200 字符通常是编码器参数刷屏，
            // 不是失败原因。这里翻译成人话 + 可执行建议，原文只进日志。
            return Self.friendlyMessage(exitCode: code, stderr: stderr)
        case .outputParsingFailed(let detail):
            return "视频分析结果异常: \(detail)"
        case .cancelled:
            return "操作已取消"
        }
    }

    /// 把 ffmpeg 的 stderr 归类成用户能看懂、且知道下一步做什么的一句话。
    /// 匹配不到已知模式时给通用建议，**绝不回落到原始 stderr**（那是给日志看的）。
    private static func friendlyMessage(exitCode: Int32, stderr: String) -> String {
        let s = stderr.lowercased()

        if s.contains("no space left") || s.contains("enospc") {
            return "磁盘空间不足，无法写入视频。请清理磁盘后重试。"
        }
        if s.contains("permission denied") || s.contains("operation not permitted") {
            return "没有文件读写权限。请检查导出目录的访问权限，或换一个目录重试。"
        }
        if s.contains("no such file") || s.contains("does not exist") {
            // 短标签取自唯一真源，但**结论保留自己那份**（这里要的是重新导入，不是放回原处）——
            // 方案批 5 明令"只统一措辞骨架，不把两种不同结论强行说成一种"。
            return MissingMaterialCopy.needsReimport
        }
        if s.contains("invalid data found") || s.contains("moov atom not found") || s.contains("could not find codec") {
            return "视频文件已损坏或格式不受支持，无法处理。建议用其他工具转成 MP4(H.264) 后重新导入。"
        }
        if s.contains("device") && (s.contains("busy") || s.contains("unavailable")) {
            return "硬件编码器当前不可用。请稍后重试，或在设置中改用软件编码。"
        }
        if s.contains("killed") || exitCode == 137 {
            return "视频处理被系统中断（内存不足）。请关闭其他大型应用后重试。"
        }
        return "视频处理失败。请重试；若反复失败，日志见 \(MixLog.logFileURL.path)（错误码 \(exitCode)）。"
    }
}

/// 线程安全的字符串收集器（用于跨闭包收集 stderr 输出）
private final class ThreadSafeStringBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    func append(_ text: String) {
        lock.lock()
        _value += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

/// 非阻塞管道收集器：进程运行期间用 readabilityHandler 持续排空管道
/// （与 VocalSeparationService.runDemucs 的可靠路径同构）。
/// 终止回调只允许做非阻塞收尾——禁止同步读取到 EOF（那会阻塞 Foundation 终止回调线程），
/// 这一契约由 DubbingTaskOwnershipGuardTests G10 源码守卫钉死；旧写法也是现场抓到
/// 无主 PIPE 残骸的来源之一。
private final class PipeCollector: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.lock.lock()
            self?.buffer.append(chunk)
            self?.lock.unlock()
        }
    }

    /// 进程终止后调用：停止接收并取出全部已收集字节。
    func finish() -> Data {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}

/// FFmpeg 命令执行封装
actor FFmpegRunner {

    /// 显式指定的二进制路径（仅测试/特殊场景用）；nil 表示每次调用时动态解析。
    private let explicitBinaryPath: String?

    /// 当前运行中的进程（用于取消）
    private var runningProcess: Process?

    /// 当前系统是否为 Intel Mac（x86_64）
    private static let isIntelMac: Bool = {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }()

    init() {
        self.explicitBinaryPath = nil
    }

    init(binaryPath: String) {
        self.explicitBinaryPath = binaryPath
    }

    /// 动态解析 FFmpeg 路径（**每次调用时解析，而非 init 定死**）。
    ///
    /// 为什么不在 init 里定死：本项目开发期工作流会在 app 运行时于后台反复 clean/重建
    /// app bundle（Release 编译 + 打包 DMG）。若 init 时选中 bundle 内 ffmpeg 并缓存，
    /// 在几分钟级别的长任务（如 demucs 人声分离）执行中途，bundle 内的 ffmpeg 可能已被
    /// 后台构建删除/替换，后续 `ff.run` 就会对已失效路径 `fileExists` 失败并误报
    /// 「视频处理组件未找到」——即使系统里明明装着可用的 ffmpeg。
    /// 改为调用时解析后：bundled 失效会自动回退系统安装；长生命周期实例也不再持有陈旧路径。
    ///
    /// 优先级：显式指定 > bundle 内（存在才用）> 系统安装 > "".
    private func resolveBinary() -> String {
        if let explicitBinaryPath { return explicitBinaryPath }

        // 优先使用 bundle 内的 FFmpeg（开箱即用，用户无需安装任何依赖）
        // findBundledBinary 内部已校验 fileExists，返回即代表当下存在
        if let bundledPath = Self.findBundledBinary("ffmpeg") {
            return bundledPath
        }

        // 系统安装作为回退（开发期 fallback，也兜底 bundle 中途失效）
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let systemPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return systemPath
        }

        // 不在此处打日志：resolveBinary 是热路径（concat 一次会调多次），真缺失时由调用方
        // 的 guard 抛 binaryNotFound 统一透出，避免刷屏。
        return ""
    }

    /// 动态解析 ffprobe 路径（与 resolveBinary 对称，**独立回退系统安装**）。
    /// ffprobe 通常与 ffmpeg 同批打包/删除，但为真正兑现「bundle 中途失效自动回退」的承诺，
    /// 这里独立解析，而非从 ffmpeg 路径字符串推导（否则 ffmpeg 尚存、ffprobe 被删时会误报）。
    private func resolveProbeBinary() -> String {
        if let explicitBinaryPath {
            // 测试/显式覆盖：沿用「与 ffmpeg 同目录」的推导，保持旧行为
            return explicitBinaryPath.replacingOccurrences(of: "/ffmpeg", with: "/ffprobe")
        }
        if let bundledPath = Self.findBundledBinary("ffprobe") {
            return bundledPath
        }
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        if let systemPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return systemPath
        }
        return ""
    }

    /// 从 Bundle 中查找二进制（兼容 folder reference 和 resource group）
    private static func findBundledBinary(_ name: String) -> String? {
        // 方式 1: resourceURL 直接拼接（folder reference 最可靠）
        if let binURL = Bundle.main.resourceURL?.appendingPathComponent("bin").appendingPathComponent(name),
           FileManager.default.fileExists(atPath: binURL.path) {
            return binURL.path
        }
        // 方式 2: path(forResource:) API（resource group 模式）
        if let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "bin") {
            return path
        }
        if let path = Bundle.main.path(forResource: name, ofType: nil) {
            return path
        }
        return nil
    }

    // MARK: - 核心执行

    /// 统一构造子进程：最小环境 + stdin 显式接 /dev/null。
    /// stdin 必须与 stdout/stderr 对称接管——ffmpeg 默认把 stdin 当交互控制台，
    /// 继承到 tty 时行为依赖启动方式（Finder=EOF、终端=tty），自动化场景必须消除该差异。
    nonisolated private static func makeProcess(executable: String, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.qualityOfService = .userInitiated
        let binDir = (executable as NSString).deletingLastPathComponent
        process.environment = ["PATH": "\(binDir):/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// ffmpeg 自动化调用统一注入 `-nostdin`（官方要求，与 stdin=/dev/null 双保险）。
    /// 幂等：已含则不重复插。只用于 ffmpeg；ffprobe 不识别该参数，禁止对其调用。
    nonisolated private static func withNoStdin(_ arguments: [String]) -> [String] {
        arguments.contains("-nostdin") ? arguments : ["-nostdin"] + arguments
    }

    /// 进程生命周期埋点：挂死时这两行是区分「没启动 / 启动了不退出 / 退出码异常」的唯一证据。
    nonisolated private static func logProcessSummary(arguments: [String]) -> String {
        // filter_complex 等参数极长，只摘要前 8 段，避免日志刷屏。
        arguments.prefix(8).joined(separator: " ")
    }

    /// 执行 FFmpeg 命令并返回 stdout
    /// - Parameter timeoutSeconds: 墙钟超时（秒）。**0 表示不设**，靠 Task 取消来中断。
    ///   ⚠️ 以前这里写死 180 秒并作用于**所有** ffmpeg 调用 —— 导出一条 3 分钟以上的成片
    ///   必然被杀，而且报出来的是 exit code 非 0，用户根本看不出是超时。
    ///   短任务（缩略图/切片/探测）可以传具体秒数；整片编码类调用一律用默认的 0。
    func run(
        arguments: [String],
        totalDuration: Double? = nil,
        timeoutSeconds: Int = 0,
        onProgress: (@Sendable (FFmpegProgress) -> Void)? = nil
    ) async throws -> Data {
        let binaryPath = resolveBinary()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw FFmpegError.binaryNotFound
        }

        let arguments = Self.withNoStdin(arguments)
        let process = Self.makeProcess(executable: binaryPath, arguments: arguments)

        // 两条管道都在进程运行期间持续排空（与 demucs 路径同构）：
        // stdout 收输出字节，stderr 收错误文本 + 进度。
        let stdoutCollector = PipeCollector()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutCollector.pipe
        process.standardError = stderrPipe

        // stderr 进度解析（使用线程安全缓冲区）
        let stderrBuffer = ThreadSafeStringBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(text)

            // 解析进度
            if let progress = FFmpegRunner.parseProgressStatic(from: text, totalDuration: totalDuration) {
                onProgress?(progress)
            }
        }

        self.runningProcess = process
        let startedAt = Date()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    // 非阻塞收尾：只停 handler、取已排空的数据，绝不在此线程做阻塞 IO。
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let stdoutData = stdoutCollector.finish()
                    let elapsed = Date().timeIntervalSince(startedAt)

                    if proc.terminationStatus == 0 {
                        MixLog.info("[FF] exit rc=0 elapsed=\(String(format: "%.2f", elapsed))s")
                        continuation.resume(returning: stdoutData)
                    } else {
                        MixLog.error("[FF] exit rc=\(proc.terminationStatus) elapsed=\(String(format: "%.2f", elapsed))s")
                        continuation.resume(throwing: FFmpegError.executionFailed(
                            exitCode: proc.terminationStatus,
                            stderr: stderrBuffer.value
                        ))
                    }
                }

                do {
                    try process.run()
                    MixLog.info("[FF] launched pid=\(process.processIdentifier) \(Self.logProcessSummary(arguments: arguments))")
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // 超时保护：仅在调用方显式指定时生效（0 = 不设，交给 Task 取消）
                if timeoutSeconds > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                        if process.isRunning {
                            MixLog.error("FFmpeg 进程超时（\(timeoutSeconds)s），强制终止")
                            FFmpegRunner.forceTerminate(process)
                        }
                    }
                }
            }
        }, onCancel: {
            if process.isRunning {
                MixLog.info("FFmpeg 进程因 Task 取消被终止")
                FFmpegRunner.forceTerminate(process)
            }
        })
    }

    /// 执行 ffprobe 并返回 stdout（用于轻量探测：I-frame 列表等）
    /// 与 ffmpeg 不同的是只 demux 不解码，对长视频也很快
    /// - Parameters:
    ///   - arguments: ffprobe 参数（不含可执行路径）
    ///   - timeoutSeconds: 超时秒数，默认 60s
    func runProbe(arguments: [String], timeoutSeconds: Int = 60) async throws -> String {
        let ffprobePath = resolveProbeBinary()
        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            throw FFmpegError.binaryNotFound
        }

        let process = Self.makeProcess(executable: ffprobePath, arguments: arguments)

        // ffprobe 只 demux 不解码，输出走 stdout；运行期间持续排空（非阻塞收尾）。
        let stdoutCollector = PipeCollector()
        process.standardOutput = stdoutCollector.pipe
        process.standardError = FileHandle.nullDevice

        let startedAt = Date()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    let output = stdoutCollector.finish()
                    let text = String(data: output, encoding: .utf8) ?? ""
                    let elapsed = Date().timeIntervalSince(startedAt)
                    // ⚠️ 以前无视退出码一律返回 output：ffprobe 崩溃/被杀就返回空串，
                    // 下游 `Double("") ?? 0` 得到时长 0 → 配音变速系数、帧数、起始时间全部按 0 计算，
                    // 整条流程"成功"跑完但结果是错的。现在探测失败就明确抛错。
                    guard proc.terminationStatus == 0 else {
                        MixLog.error("[FFprobe] exit rc=\(proc.terminationStatus) elapsed=\(String(format: "%.2f", elapsed))s")
                        continuation.resume(throwing: FFmpegError.outputParsingFailed(
                            "视频信息探测失败（exit \(proc.terminationStatus)）"))
                        return
                    }
                    continuation.resume(returning: text)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // 超时保护：可配置，先 SIGTERM，3 秒后强制 SIGKILL
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                    if process.isRunning {
                        MixLog.error("ffprobe 进程超时（\(timeoutSeconds)秒），强制终止")
                        FFmpegRunner.forceTerminate(process)
                    }
                }
            }
        }, onCancel: {
            if process.isRunning {
                MixLog.info("ffprobe 进程因 Task 取消被终止")
                FFmpegRunner.forceTerminate(process)
            }
        })
    }

    /// 先发 SIGTERM，3 秒后若进程仍存活则发 SIGKILL 强制终止
    /// 解决 FFmpeg/Whisper 等某些状态下对 SIGTERM 无响应的问题
    nonisolated static func forceTerminate(_ process: Process) {
        process.terminate()  // SIGTERM
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning {
                MixLog.error("进程拒绝 SIGTERM，发送 SIGKILL: pid=\(pid)")
                kill(pid, SIGKILL)
            }
        }
    }

    /// 执行 FFmpeg 命令并返回 stderr（用于获取元数据、场景检测等）
    func runForStderr(arguments: [String]) async throws -> String {
        let binaryPath = resolveBinary()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw FFmpegError.binaryNotFound
        }

        let arguments = Self.withNoStdin(arguments)
        let process = Self.makeProcess(executable: binaryPath, arguments: arguments)

        // stderr 是该路径的输出通道，运行期间持续排空（非阻塞收尾）。
        let stderrCollector = PipeCollector()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrCollector.pipe

        let startedAt = Date()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { _ in
                    let output = stderrCollector.finish()
                    let text = String(data: output, encoding: .utf8) ?? ""
                    MixLog.info("[FF] stderr-path exit elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
                    continuation.resume(returning: text)
                }

                do {
                    try process.run()
                    MixLog.info("[FF] launched pid=\(process.processIdentifier) \(Self.logProcessSummary(arguments: arguments))")
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // 超时保护：3 分钟
                DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                    if process.isRunning {
                        MixLog.error("FFmpeg (stderr) 进程超时（3分钟），强制终止")
                        FFmpegRunner.forceTerminate(process)
                    }
                }
            }
        }, onCancel: {
            if process.isRunning {
                MixLog.info("FFmpeg (stderr) 进程因 Task 取消被终止")
                FFmpegRunner.forceTerminate(process)
            }
        })
    }

    /// 取消当前执行
    func cancel() {
        if let p = runningProcess {
            FFmpegRunner.forceTerminate(p)
        }
        runningProcess = nil
    }

    // MARK: - 便捷方法

    /// 提取音频为 16kHz mono WAV（用于 ASR）
    func extractAudio(from videoPath: String, to outputPath: String,
                      onProgress: (@Sendable (FFmpegProgress) -> Void)? = nil) async throws {
        let args = [
            "-i", videoPath,
            "-vn",                  // 不处理视频
            "-acodec", "pcm_s16le", // 16-bit PCM
            "-ar", "16000",         // 16kHz
            "-ac", "1",             // mono
            "-y",                   // 覆盖输出
            outputPath
        ]
        _ = try await run(arguments: args, onProgress: onProgress)
    }

    /// 裁切视频片段（用 trim filter 精确切 + setpts 重置时间戳，**保证第一帧立即有画面**）
    ///
    /// 关键技术：
    ///   - 不用 -ss 跳关键帧（input seeking 不精确），从 0 开始解码所有帧
    ///   - `trim` filter 精确取 [start, end] 区间的视频帧
    ///   - `setpts=PTS-STARTPTS` / `asetpts=PTS-STARTPTS` 把第一帧时间戳重置为 0
    ///   - VideoToolbox 硬件编码确保输出第一帧就是关键帧
    ///
    /// 这是 FFmpeg 文档推荐的「精确切片且无开头黑屏」标准方法。
    /// 切出一段。传入 fps > 0 时用帧号精确切（trim start_frame/end_frame，永不差帧）；
    /// fps == 0 时退回按秒切（兼容）。
    func cutSegment(from videoPath: String, start: Double, end: Double,
                    fps: Double = 0,
                    to outputPath: String) async throws {
        let videoFilter: String
        let audioFilter: String
        if fps > 0 {
            let startFrame = Int((start * fps).rounded())
            let endFrame = Int((end * fps).rounded())
            // 音频无帧概念，用帧换算回的精确秒
            let aStart = Double(startFrame) / fps
            let aEnd = Double(endFrame) / fps
            videoFilter = "trim=start_frame=\(startFrame):end_frame=\(endFrame),setpts=PTS-STARTPTS"
            audioFilter = "atrim=start=\(String(format: "%.5f", aStart)):end=\(String(format: "%.5f", aEnd)),asetpts=PTS-STARTPTS"
        } else {
            videoFilter = "trim=start=\(String(format: "%.3f", start)):end=\(String(format: "%.3f", end)),setpts=PTS-STARTPTS"
            audioFilter = "atrim=start=\(String(format: "%.3f", start)):end=\(String(format: "%.3f", end)),asetpts=PTS-STARTPTS"
        }

        let args = [
            "-i", videoPath,
            "-vf", videoFilter,
            "-af", audioFilter,
            // VideoToolbox 硬件加速编码（Apple Silicon Media Engine / Intel Quick Sync）
            "-c:v", "h264_videotoolbox",
            "-b:v", "8000k",
            "-maxrate", "16000k",
            "-tag:v", "avc1",
            "-allow_sw", "1",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-y", outputPath
        ]
        _ = try await run(arguments: args, timeoutSeconds: 600)
    }

    /// 切出 [start,end) 秒的音频为 16k 单声道裸 PCM(s16le)，供阿里实时 ASR 流式发送。
    func extractSegmentPCM(from videoPath: String, start: Double, end: Double,
                           sampleRate: Int = 16000, to outPath: String) async throws {
        let args = ["-y",
                    "-ss", String(format: "%.3f", max(0, start)),
                    "-to", String(format: "%.3f", end),
                    "-i", videoPath,
                    "-vn", "-ac", "1", "-ar", String(sampleRate),
                    "-f", "s16le", "-acodec", "pcm_s16le", outPath]
        _ = try await run(arguments: args, timeoutSeconds: 600)
    }

    /// 切出 [start,end) 秒的音频为 **16k 单声道 WAV**，供本机 whisper.cpp 使用。
    ///
    /// 与 `extractSegmentPCM` 的唯一区别是容器：whisper.cpp 要能自己读时长/采样率的文件，
    /// 裸 s16le 它读不了。格式由**引擎**决定（红线 R5），所以两枚方法都存在、由门面选。
    func extractSegmentAudio(from videoPath: String, start: Double, end: Double,
                             sampleRate: Int = 16000, to outPath: String) async throws {
        let args = ["-y",
                    "-ss", String(format: "%.3f", max(0, start)),
                    "-to", String(format: "%.3f", end),
                    "-i", videoPath,
                    "-vn", "-ac", "1", "-ar", String(sampleRate),
                    "-acodec", "pcm_s16le", outPath]
        _ = try await run(arguments: args, timeoutSeconds: 600)
    }

    /// 整片音频转 16k 单声道裸 PCM(s16le)，供阿里整片 ASR 流式发送。
    func extractAudioPCM(from videoPath: String, sampleRate: Int = 16000, to outPath: String) async throws {
        let args = ["-y", "-i", videoPath, "-vn", "-ac", "1", "-ar", String(sampleRate),
                    "-f", "s16le", "-acodec", "pcm_s16le", outPath]
        _ = try await run(arguments: args, timeoutSeconds: 600)
    }

    /// 探测视频文件是否包含音频轨道（异步，不阻塞 actor 线程）
    /// 回读成片的**显示**宽高。返回 `nil` = 读不到（无 ffprobe / 没有视频流 / 文件损坏）。
    ///
    /// 为什么必须存在这一步：2026-10-19 整批 41 条成片被千川以「素材尺寸不符合规范」拒收，
    /// 而导出链路此前只回读 `start_time` 与 `duration`，**从不回读宽高** —— 计划画布与落盘画布
    /// 分叉时没有任何一处会发现。调用方（`ExportService` / `DubExportService`）拿它做后置断言。
    ///
    /// ⚠️ 取的是 `width`/`height`（显示尺寸），**不是** `coded_width`/`coded_height`：
    /// H.264 按宏块对齐，编码面常比显示面大一圈（外部实测样本 854×480 的编码面是 864×480）。
    /// 平台读哪一路尚未证伪，因此调用方只保证"等于计划值"，不假装知道平台看什么。
    ///
    /// 无视频流时 `-select_streams v:0` 会输出空串 ⇒ 这里返回 `nil` 而不是 `(0, 0)`，
    /// 让调用方红掉。**空读数绝不能被读成"通过"**。
    func probeCanvasSize(path: String) async -> DeliveryCanvas? {
        let out = try? await runProbe(arguments: [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0", path])
        guard let line = out?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first,
              !line.isEmpty else { return nil }
        let parts = line.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return DeliveryCanvas(width: parts[0], height: parts[1])
    }

    private func probeHasAudio(path: String) async -> Bool {
        let ffprobePath = resolveProbeBinary()
        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            return true  // 无 ffprobe 时默认有音频
        }

        let process = Self.makeProcess(executable: ffprobePath, arguments: [
            "-v", "quiet",
            "-select_streams", "a",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            path
        ])
        let collector = PipeCollector()
        process.standardOutput = collector.pipe
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    let output = collector.finish()
                    let text = String(data: output, encoding: .utf8) ?? ""
                    continuation.resume(returning: text.contains("audio"))
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: true) // 出错时默认有音频
                    return
                }

                // 超时保护：30 秒（ffprobe 通常瞬时返回）
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if process.isRunning {
                        MixLog.error("ffprobe (hasAudio) 进程超时（30秒），强制终止")
                        FFmpegRunner.forceTerminate(process)
                    }
                }
            }
        }, onCancel: {
            if process.isRunning {
                FFmpegRunner.forceTerminate(process)
            }
        })
    }

    /// 这一段切片是不是**纯数字静音**（每个采样都为 0）。
    ///
    /// 为什么需要它：`loudnorm` 吃到不足测量窗的纯静音会吐 NaN，aac 编码器拒收 ⇒
    /// 整条导出 `rc=234`（实测与判据见 `MixCutCore.LoudnessChainPolicy`）。
    /// 调用方只在"短到需要判"时才调它，所以这里不必再设门槛。
    ///
    /// 判据取 `RMS level dB: -inf` 而不是「低于某个 dB」：实测 −81 dB 级近静音走原链
    /// 完全正常，只有 -inf（全零）会触发 NaN ⇒ 用阈值就会把今天能导的片子一起改道。
    ///
    /// 探测失败 / 读不到那行 ⇒ 返回 `false`（保持现有行为）。
    /// ⚠️ 这里「没读到」绝不能读成「是静音」：那会把一条有声分镜悄悄换成静音交付。
    func probePureDigitalSilence(path: String, start: Double, end: Double) async -> Bool {
        let args = ["-v", "info",
                    "-ss", String(format: "%.3f", max(0, start)),
                    "-to", String(format: "%.3f", end),
                    "-i", path,
                    "-af", "astats=measure_perchannel=none",
                    "-f", "null", "-"]
        guard let text = try? await runForStderr(arguments: args) else {
            MixLog.error("[FF] 静音探测未跑成（astats），按「非静音」处理以维持现有行为")
            return false
        }
        return text.contains("RMS level dB: -inf")
    }

    /// 拼接多个视频片段为一个 MP4（统一编码，确保多源视频可混剪）
    /// 使用 filter_complex concat 方式，自动处理不同分辨率/编码/帧率
    func concat(segments: [(path: String, start: Double, end: Double)],
                outputPath: String,
                resolution: String,
                crf: Int = 18,
                codec: String = "libx264",
                isHardware: Bool = false,
                videoBitrateKbps: Int = 8_000,
                onProgress: (@Sendable (FFmpegProgress) -> Void)? = nil) async throws {
        guard !segments.isEmpty else { return }

        // 并行决定每个输入的音频走哪条支路：源音轨（过 loudnorm）还是补静音。
        //
        // 这里原先只问「有没有音轨」，而正确的问法是「有没有**可听的**音频」——
        // 一条有音轨但整段是纯数字静音的分镜，喂进 loudnorm 会让它吐 NaN、
        // aac 编码器拒收，整条导出以 rc=234 失败（判据与实测见 `MixCutCore.LoudnessChainPolicy`）。
        // 中毒单位是单条分镜，不是成片总时长，所以千川时长闸拦不住它。
        let useSourceAudio: [Bool] = await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, seg) in segments.enumerated() {
                group.addTask { [self] in
                    guard await self.probeHasAudio(path: seg.path) else { return (i, false) }
                    let segSeconds = max(0, seg.end - seg.start)
                    // 只有不足测量窗的短段才值得花这次探测：长段今天就不会中毒。
                    guard LoudnessChainPolicy.needsSilenceProbe(durationSeconds: segSeconds) else {
                        return (i, true)
                    }
                    let pureSilence = await self.probePureDigitalSilence(path: seg.path,
                                                                        start: seg.start,
                                                                        end: seg.end)
                    guard LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: segSeconds,
                                                                 isPureDigitalSilence: pureSilence) else {
                        return (i, true)
                    }
                    MixLog.info("[FF] 分镜\(i) 是不足 " +
                               "\(LoudnessChainPolicy.measurementWindowSeconds)s 的纯数字静音，" +
                               "改走静音支路（否则 loudnorm 吐 NaN ⇒ 整条导出 rc=234）")
                    return (i, false)
                }
            }
            var results = Array(repeating: true, count: segments.count)
            for await (i, ok) in group {
                results[i] = ok
            }
            return results
        }

        // 构建 FFmpeg 命令：多输入 + filter_complex 统一编码拼接
        var args: [String] = []

        // 添加所有视频输入（精确裁切用 -ss/-to）
        for seg in segments {
            args += ["-ss", String(format: "%.3f", seg.start),
                     "-to", String(format: "%.3f", seg.end),
                     "-i", seg.path]
        }

        // 添加沉默音频生成器作为额外输入（索引 = segments.count）
        // 用于替代无音轨片段的音频
        let silenceInputIndex = segments.count
        args += ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo"]

        // 构建 filter_complex：统一缩放到目标分辨率 + concat
        // 目标尺寸由调用方从 `MixCutCore.DeliveryCanvas` 取，这里**不再兜底** ——
        // 一个 `?? "1080:1920"` 会让"调用方忘了算尺寸"静默变成"按 1080 导出"，
        // 而这次事故的形态恰恰是：整批产物是某个尺寸，却没有任何一处知道自己算出了什么。
        let targetScale = resolution
        var filterParts: [String] = []

        for i in 0..<segments.count {
            // 统一缩放 + 填充黑边 + 统一帧率 + 时间戳重置
            filterParts.append(
                "[\(i):v]scale=\(targetScale):force_original_aspect_ratio=decrease," +
                "pad=\(targetScale):(ow-iw)/2:(oh-ih)/2:black," +
                "setsar=1,fps=30[v\(i)]"
            )
            // 音频处理：可听的音轨走原始音频 + loudnorm；无音轨**或纯数字静音**走沉默源裁切
            let segDuration = segments[i].end - segments[i].start
            let durStr = String(format: "%.6f", segDuration)
            if useSourceAudio[i] {
                filterParts.append(
                    "[\(i):a]aresample=44100,loudnorm=I=-16:TP=-1.5:LRA=11,apad=whole_dur=\(durStr)[a\(i)]"
                )
            } else {
                // 走静音支路：无音轨，或整段是纯数字静音（后者不能喂 loudnorm，见上面的说明）
                filterParts.append(
                    "[\(silenceInputIndex):a]atrim=0:\(durStr),asetpts=PTS-STARTPTS[a\(i)]"
                )
            }
        }

        // concat 所有流（FFmpeg concat filter 要求输入按 segment 交替：[v0][a0][v1][a1]...）
        let concatInputs = (0..<segments.count).map { "[v\($0)][a\($0)]" }.joined()
        filterParts.append(
            "\(concatInputs)concat=n=\(segments.count):v=1:a=1[outv][outa]"
        )

        let filterComplex = filterParts.joined(separator: ";")
        args += ["-filter_complex", filterComplex]
        args += ["-map", "[outv]", "-map", "[outa]"]

        // 编码设置：根据软件/硬件分支
        if isHardware {
            // VideoToolbox 硬件编码（Apple Silicon Media Engine / Intel Quick Sync）：
            // 不支持 CRF，用目标比特率控质量；不支持 -preset；速度通常 5-10× 软件编码
            args += ["-c:v", codec]
            args += ["-b:v", "\(videoBitrateKbps)k"]
            // 给一个最大比特率上限，避免突发码率过高
            args += ["-maxrate", "\(videoBitrateKbps * 2)k"]
            args += ["-tag:v", codec.contains("hevc") ? "hvc1" : "avc1"]   // QuickTime/Safari 兼容
            // 让 VideoToolbox 走高质量预设（仍比 libx264 快很多）
            args += ["-allow_sw", "0"]
        } else {
            // 软件编码（libx264 / libx265）
            let preset: String
            switch crf {
            case 0...10:  preset = "slower"   // 无损/极高质量
            case 11...20: preset = "slow"     // 高质量
            case 21...25: preset = "medium"   // 中等质量
            default:      preset = "fast"     // 快速导出
            }
            args += ["-c:v", codec, "-crf", "\(crf)", "-preset", preset]
        }
        // 强制输出 yuv420p，保证 Safari/QuickTime/iOS 都能解码（防止 yuv420p10/yuv422 兼容性问题）
        args += ["-pix_fmt", "yuv420p"]
        args += ["-c:a", "aac", "-b:a", "192k"]
        args += ["-movflags", "+faststart"]  // 支持网络流式播放（信息流广告必须）
        args += ["-y", outputPath]

        let totalDuration = segments.reduce(0.0) { $0 + ($1.end - $1.start) }
        _ = try await run(arguments: args, totalDuration: totalDuration, onProgress: onProgress)
    }

    /// 生成视频缩略图
    func generateThumbnail(from videoPath: String, at time: Double = 1.0,
                           to outputPath: String) async throws {
        let args = [
            "-ss", String(format: "%.3f", time),
            "-i", videoPath,
            "-frames:v", "1",
            "-update", "1",
            "-q:v", "2",
            "-y",
            outputPath
        ]
        _ = try await run(arguments: args, timeoutSeconds: 120)
    }

    // MARK: - 进度解析

    /// 从 FFmpeg stderr 输出中解析进度信息
    private static func parseProgressStatic(from text: String, totalDuration: Double?) -> FFmpegProgress? {
        // FFmpeg 输出格式: frame=  123 fps= 60 ... time=00:01:30.00 speed=1.2x
        guard let timeMatch = text.range(of: #"time=(\d{2}):(\d{2}):(\d{2}\.\d+)"#,
                                         options: .regularExpression) else {
            return nil
        }

        let timeStr = String(text[timeMatch])
        let components = timeStr.replacingOccurrences(of: "time=", with: "").split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }

        let currentTime = hours * 3600 + minutes * 60 + seconds

        // 解析 frame
        let frame: Int
        if let frameMatch = text.range(of: #"frame=\s*(\d+)"#, options: .regularExpression) {
            let frameStr = String(text[frameMatch]).replacingOccurrences(of: "frame=", with: "").trimmingCharacters(in: .whitespaces)
            frame = Int(frameStr) ?? 0
        } else {
            frame = 0
        }

        // 解析 fps
        let fps: Double
        if let fpsMatch = text.range(of: #"fps=\s*([\d.]+)"#, options: .regularExpression) {
            let fpsStr = String(text[fpsMatch]).replacingOccurrences(of: "fps=", with: "").trimmingCharacters(in: .whitespaces)
            fps = Double(fpsStr) ?? 0
        } else {
            fps = 0
        }

        // 解析 speed
        let speed: Double
        if let speedMatch = text.range(of: #"speed=\s*([\d.]+)x"#, options: .regularExpression) {
            let speedStr = String(text[speedMatch]).replacingOccurrences(of: "speed=", with: "").replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)
            speed = Double(speedStr) ?? 0
        } else {
            speed = 0
        }

        let percentage: Double
        if let total = totalDuration, total > 0 {
            percentage = min(currentTime / total, 1.0)
        } else {
            percentage = 0
        }

        return FFmpegProgress(
            frame: frame,
            fps: fps,
            time: currentTime,
            speed: speed,
            percentage: percentage
        )
    }
}
