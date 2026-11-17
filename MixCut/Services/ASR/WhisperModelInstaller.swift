import Foundation
import Observation

/// Whisper 引擎档模型的**唯一 UI 状态源**（计划 v4 §4/§5）。
///
/// 为什么需要它：此前三个视图（设置页 / 侧栏 / 欢迎页）各自持一份 `hasWhisperModel` 或
/// `modelReport` 缓存，刷新时机各不相同 —— 下载完成后 A 视图显示"已就绪"、B 视图还显示
/// "待下载"，甚至出现"档位 A + 状态 B"的错配。改为 installer 持有**唯一一份** `report`，
/// 三个视图只读它；下载链路完成后 installer 自己 `refresh()`，不再发通知让各视图各自重扫
/// （两套机制做同一件事，漏一次就是"橙叹号不消失"——计划 v2 已推翻双通知方案）。
///
/// 边界：
/// - **不重写下载**：`start()` 只调 `ASRService.downloadModelIfNeeded`（下载/续传/校验真源在那里）。
/// - **不判定可用性**：`engineState` 派生自 Core 的 `ModelReport`，只作"下载/修复入口"判据；
///   `usable`（红线 R2）一个字不改，installer 不拿 engineState 去否决识别。
/// - **单飞**：`isBusy` 在 @MainActor 上串行，第二个 `start()` 直接返回（进程内单飞）；
///   跨实例并发由 ASRService 的 `.lock` 文件（O_EXCL）兜住。
@MainActor
@Observable
final class WhisperModelInstaller {

    /// 全局单例 —— 三个视图与引导页共享同一份状态。
    static let shared = WhisperModelInstaller()

    /// 唯一的模型报告（档位 / 来自哪个根 / 提示 / 引擎态）。视图只读这里，不再各自 stat。
    private(set) var report: ModelReport = WhisperModelCatalog.report(files: [])

    /// 下载阶段（给 UI 显示"连接中 / 下载中 / 完成 / 失败"）。
    enum Phase: Equatable, Sendable {
        case idle
        case downloading
        case verifying
        case failed(String)
    }
    private(set) var phase: Phase = .idle
    private(set) var progress: DownloadProgress?
    /// 是否已做过至少一次真实扫描。未扫描前 needsDownload 不可信（初始空报告会让老用户误弹模型页）。
    private(set) var hasScanned = false

    /// 引擎态，纯派生 —— 与 report 同源，绝不独立赋值（否则又是个双状态源）。
    var engineState: EngineModelState? { report.engineState }

    /// 是否需要给用户下载/修复入口。唯一口径：`engineState != .ready`（计划 §4.2）。
    /// 传了引擎档才有 engineState；理论上不会 nil（除非 Core 没配引擎档），此时保守给下载入口。
    var needsDownload: Bool {
        guard let state = engineState else { return true }
        return state != .ready
    }

    private var isBusy = false
    private var downloadTask: Task<Void, Never>?

    private init() {}

    /// 重新扫描模型。放后台队列（stat + 读 4 字节头便宜，但不占主线程）；完成后回主线程写唯一状态。
    func refresh() {
        Task.detached(priority: .utility) {
            let fresh = ASRService.modelReport(engine: ASRService.engineTier)
            await MainActor.run {
                self.report = fresh
                self.hasScanned = true
                // 未下载时保持 idle；已就绪且之前是 failed ⇒ 清掉旧错误（状态自愈）
                if case .failed = self.phase, fresh.engineState == .ready {
                    self.phase = .idle
                }
            }
        }
    }

    /// 启动下载（含完整性校验，全在 ASRService）。进程内单飞：忙碌时直接返回。
    func start() {
        guard !isBusy else { return }
        isBusy = true
        phase = .downloading
        progress = nil
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isBusy = false
                self.downloadTask = nil
            }
            do {
                let asr = ASRService()
                // 不下传 modelName：引擎档由 ASRPolicy 定（红线 R3），界面不留第二个档位选择
                _ = try await asr.downloadModelIfNeeded { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
                self.phase = .verifying
                // 成功后自己刷新唯一状态源（不发通知 —— 见类型注释）
                self.refresh()
                self.phase = .idle
            } catch is CancellationError {
                self.phase = .failed("已取消，可继续（已下载部分会续传）")
                self.refresh()
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.refresh()
            }
        }
    }

    /// 取消下载。ASRService 会在下一个检查点响应 Task 取消并保留 partial 供续传。
    func cancel() {
        downloadTask?.cancel()
    }
}
