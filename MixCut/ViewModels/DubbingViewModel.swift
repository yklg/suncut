import Foundation
import SwiftData
import AVFoundation
import CryptoKit

@MainActor
@Observable
final class DubbingViewModel {
    /// 台词变体数量：默认值与可选范围（全局设置，存 UserDefaults["dubVariantCount"]）。
    static let defaultVariantCount = 2
    static let variantCountRange = 1...5

    /// 当前要产出的台词变体数量（读全局设置，越界自动夹紧到 1...5）。
    var variantCount: Int {
        let stored = UserDefaults.standard.integer(forKey: "dubVariantCount")
        let n = stored == 0 ? Self.defaultVariantCount : stored
        return min(max(n, Self.variantCountRange.lowerBound), Self.variantCountRange.upperBound)
    }

    /// 差异化改写风格池（支持最多 5 套变体；不足时由 RewriteStylePlan 显式回绕）。
    /// 每条都是「定位 + 可执行手法」，手法维度互不重叠——只给一句"口语化"式定位，
    /// 在字数/语义紧约束下拉不动措辞，多版必然雷同。
    private static let rewriteStyles = [
        "短句快节奏、设问开场的口语化风格：多用 8–15 字短句，以一句与痛点或好奇相关的设问开场，随后直接给答案；语气年轻有活力，可用感叹句式但禁用句末语气助词，适合面向年轻受众的信息流广告",
        "结论前置、强行动号召的干练风格：第一句就抛核心卖点或利益结论，再用一两句补证据，结尾给明确命令式号召（点击、下单、抢）；不铺垫、不绕弯，适合效果转化类信息流广告",
        "痛点场景化、先问题后方案的代入风格：先描述目标用户的具体使用场景与痛点困扰，再把产品作为解决方案自然带出，形成问题—转机—获益的讲述节奏；画面感强、像真人分享，适合种草类信息流广告",
        "数据与口碑背书的专业信任风格：用销量、复购率、检测结果、用户评价等具体数字与事实做支撑，措辞克制专业、少夸张，强调品质、资质与口碑，适合高客单价或决策谨慎品类的信息流广告",
        "限时限量、损失厌恶的紧迫促销风格：强调优惠的时间或库存边界与错过的损失（不得改写任何价格数字与现价/恢复价指向），节奏紧凑、句句推动决策，适合大促与清仓类信息流广告"
    ]
    let topVoices: [TTSVoice] = VoiceCatalog.top(10)

    /// 视频级配音作业注册表：进程级共享单例（Core，可 swift test）。
    /// 忙碌互斥是进程级语义——UI / MCP 工具 / 导出共用素材与付费音色，
    /// 任一实例 beginBusy 后其他实例对同一视频必须互斥。
    /// 任务归属是视频级，生命周期独立于分镜检查器子树——切换分镜/素材不再连带取消。
    let registry = DubbingJobRegistry.shared

    /// @Observable 投影修订号：registry 自身不是 Observable（Core 零 SwiftUI 依赖），
    /// 本实例改 registry 后通过 bumpJobs 同步；其他实例（如 MCP）改了 shared registry 时，
    /// 由浮层 TimelineView 每秒调 syncJobsRevision 把外部变化拉进本 VM 的观察域。
    private(set) var jobsRevision = DubbingJobRegistry.shared.revision
    private func bumpJobs() { jobsRevision = registry.revision }
    /// 轮询入口：仅当 shared registry 被其他实例改动时才写入（写入即触发 UI 刷新）。
    func syncJobsRevision() {
        if jobsRevision != registry.revision { jobsRevision = registry.revision }
    }

    /// 取消原因 → toast 策略。projectSwitch 静默；dataDeleted 提示素材已删；userStop 由管线各检查点提示。
    enum DubbingCancelReason: Equatable {
        case userStop
        case dataDeleted
        case projectSwitch
    }
    /// 按视频记录「本次取消的 toast 策略」，管线抵达取消检查点时消费一次。
    private var silentCancelVideoIDs: Set<UUID> = []
    private var dataDeletedCancelVideoIDs: Set<UUID> = []

    /// 广播观察者采用 target-action（不持 token）：
    /// deinit 可直接 removeObserver(self)，规避 block-token 的跨隔离属性与
    /// 「init 逃逸闭包捕获未完成初始化的 self」两条 Swift 约束。
    // （无 graphChangeObserver 存储属性）

    /// 按视频独立跟踪「正在配音（克隆/改写/合成）」状态与进度——派生自 registry，不同视频互不联动。
    var busyVideoIDs: Set<UUID> {
        _ = jobsRevision
        return registry.busyIDs
    }
    var busyDubIDs: Set<UUID> = []
    var playingDubID: UUID?

    /// 配音错误性质：alert 是否提供「去设置配置」由它派生。
    enum DubErrorKind: Equatable {
        /// 缺少千问/DashScope 凭证（可跳设置）
        case missingCredential
        /// 其余错误
        case generic
    }

    /// 配音错误状态（单一真源，替代旧的 errorMessage 字符串）。
    /// alert 关闭 = 整体置 nil，一处复位；错误信息与错误性质不再是两份影子状态。
    struct DubErrorState: Equatable {
        let message: String
        let kind: DubErrorKind
    }
    var errorState: DubErrorState?

    /// 每个变体最近一次合成失败的友好原因（dubID → 文案），供批量汇总与单格展示。
    var lastDubErrors: [UUID: String] = [:]

    /// 该视频是否正在配音处理中（用于其专属配音条显示忙碌）。
    func isBusy(videoID: UUID?) -> Bool {
        _ = jobsRevision
        guard let id = videoID else { return false }
        return registry.isBusy(id)
    }
    /// 该视频当前的进度文案。
    func progressText(videoID: UUID?) -> String {
        _ = jobsRevision
        guard let id = videoID else { return "" }
        return registry.progressText(id)
    }
    /// 该视频的进度槽位快照（浮层/三阶段指示器用）。
    func jobSlot(videoID: UUID?) -> DubbingJobRegistry.Slot? {
        _ = jobsRevision
        guard let id = videoID else { return nil }
        return registry.slot(id)
    }
    /// 当前所有忙碌视频（浮层列表真源，按 id 排序保证渲染顺序稳定）。
    func activeJobVideoIDs() -> [UUID] {
        _ = jobsRevision
        return registry.busyIDs.sorted()
    }
    /// 该视频是否存在可由 UI 停止的句柄（MCP 自动化管线无句柄 → 停止键置灰）。
    func canStopJob(videoID: UUID?) -> Bool {
        guard let id = videoID else { return false }
        return registry.canStop(id)
    }

    /// 统一 designated init：注册删除广播观察者 + 注入 TTS 客户端（默认值=生产链路）。
    /// - 观察者：唯一删除广播的第二消费者，处理函数内严禁 load/fetch/save/flush（G4 钉死）。
    ///   selector 经 nonisolated 跳板显式 hop MainActor。
    /// - 客户端注入：DebugSelfTest/测试可传假客户端；默认 CosyVoice/qwen-vc，旧行为零变化。
    /// - rewriteService 注入：只换 AI provider 来源，prompt 构建/结果映射（Core）与轮次编排全同路径。
    init(tts: TTSClient? = nil, vcClient: TTSClient? = nil,
         rewriteService: ScriptRewriteService? = nil) {
        self.tts = tts ?? CosyVoiceTTSClient()
        self.vcClient = vcClient ?? QwenTTSClient(model: VoiceCloneService.targetModel)
        self.rewriteService = rewriteService ?? ScriptRewriteService()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGraphChange(_:)),
            name: .mixCutDataDidUndo,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// selector 跳板：GraphBroadcast 虽恒在 MainActor 同步投递，这里仍显式 hop，
    /// 不把「投递线程永远是主线程」的假设埋进观察者机制。
    @objc private nonisolated func handleGraphChange(_ note: Notification) {
        let payload: Any? = note.object
        Task { @MainActor [weak self] in
            self?.handleDataDeletion(payload)
        }
    }

    /// 处理真删广播：仅在有 id 载荷时按纯判据取消；无载荷（MCP 全量重载等）不动作，
    /// 正确性由管线 isDroppedFromContext 自检兜底。此方法不得触发任何数据加载/保存。
    private func handleDataDeletion(_ payload: Any?) {
        guard let change = payload as? GraphChange else { return }
        let deletedVideos = change.idsDeleted(of: .video)
        let deletedSegments = change.idsDeleted(of: .segment)
        guard !(deletedVideos.isEmpty && deletedSegments.isEmpty) else { return }
        for (videoID, slot) in registry.allSlots() {
            guard DubbingJobCancellation.shouldCancel(
                videoID: videoID,
                targetSegmentIDs: slot.targetSegmentIDs,
                deletedVideoIDs: deletedVideos,
                deletedSegmentIDs: deletedSegments) else { continue }
            cancelJobs(for: videoID, reason: .dataDeleted)
        }
    }

    // MARK: - 作业生命周期（UI 发起的可取消任务统一从这里进）

    /// busy 互斥拦截反馈：被 guard 静默拦下时按钮像失灵（空状态 CTA 尤甚），
    /// 统一给一条中性提示，说明当前视频已有配音作业在跑（可能由 MCP 等其他入口发起）。
    private static func notifyBusy(videoName: String) {
        let label = videoName.isEmpty ? "该视频" : "「\(videoName)」"
        ToastCenter.shared.show("\(label)正在配音处理中，请等待当前任务完成",
                                icon: "hourglass", style: .info)
    }

    /// 统一改写入口的任务句柄发起：句柄归视频级注册表，切换分镜/素材不取消。
    /// - Parameter projectOverrideRaw: 当前项目音色覆盖串（调用方从 Project 传入；nil=跟随全局）。
    func startRewriteTask(video: Video,
                          targets: [Segment],
                          presentation: DubScopePresentation,
                          context: ModelContext,
                          projectOverrideRaw: String? = nil) {
        let vid = video.id
        guard !registry.isBusy(vid), !targets.isEmpty else {
            if registry.isBusy(vid) { Self.notifyBusy(videoName: video.name) }
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.registry.removeTask(vid, taskID: taskID)
                self?.bumpJobs()
            }
            await self?.rewrite(video: video,
                                targets: targets,
                                presentation: presentation,
                                context: context,
                                projectOverrideRaw: projectOverrideRaw)
        }
        registry.register(vid, taskID: taskID,
                          targets: Set(targets.map(\.id)),
                          name: video.name, task: task)
        bumpJobs()
    }

    /// 手动新增空白变体的任务发起（收口原 inspector 里的无句柄裸 Task）。
    func startManualVariantTask(for segment: Segment,
                                context: ModelContext,
                                onReady: @escaping @MainActor (Int) -> Void) {
        guard let video = segment.video else { return }
        let vid = video.id
        guard !registry.isBusy(vid) else {
            Self.notifyBusy(videoName: video.name)
            return
        }
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.registry.removeTask(vid, taskID: taskID)
                self?.bumpJobs()
            }
            guard let newIndex = await self?.addManualVariant(for: segment, context: context) else { return }
            if Task.isCancelled { return }
            onReady(newIndex)
        }
        registry.register(vid, taskID: taskID,
                          targets: [segment.id],
                          name: video.name, task: task)
        bumpJobs()
    }

    /// 单格配音（试听/重试）任务发起：句柄同样入视频级注册表，
    /// 素材删除/换项目/整视频停止时可被一并取消；不占视频忙碌引用计数（不顶掉主 CTA）。
    func startDubAudioTask(for dub: SegmentDub, context: ModelContext) {
        guard let segment = dub.segment, let video = segment.video else { return }
        let vid = video.id
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.registry.removeTask(vid, taskID: taskID)
                self?.bumpJobs()
            }
            _ = await self?.generateAudio(for: dub, context: context)
        }
        registry.register(vid, taskID: taskID,
                          targets: [segment.id],
                          name: video.name, task: task)
        bumpJobs()
    }

    /// 显式停止某视频的作业（用户确认后调用）；管线抵达取消检查点时给中性提示。
    func cancelJobs(for videoID: UUID, reason: DubbingCancelReason) {
        switch reason {
        case .userStop:
            break
        case .dataDeleted:
            dataDeletedCancelVideoIDs.insert(videoID)
        case .projectSwitch:
            silentCancelVideoIDs.insert(videoID)
        }
        registry.cancel(videoID)
        bumpJobs()
    }

    /// 停止全部作业（切换项目时静默调用）。
    func cancelAllJobs(reason: DubbingCancelReason) {
        let changed = registry.cancelAll()
        for id in changed {
            switch reason {
            case .userStop: break
            case .dataDeleted: dataDeletedCancelVideoIDs.insert(id)
            case .projectSwitch: silentCancelVideoIDs.insert(id)
            }
        }
        bumpJobs()
    }

    /// 管线抵达取消检查点时统一的中性提示；消费一次取消策略。返回是否已处理取消。
    @discardableResult
    private func announceCancellation(videoID: UUID?, completedRounds: Int? = nil) -> Bool {
        guard let id = videoID, Task.isCancelled else { return false }
        registry.setProgress(id, .idle)
        if silentCancelVideoIDs.remove(id) != nil || dataDeletedCancelVideoIDs.contains(id) {
            if dataDeletedCancelVideoIDs.remove(id) != nil {
                ToastCenter.shared.show("素材已删除，改写任务已停止",
                                        icon: "trash", style: .info, duration: 3)
            }
            // projectSwitch：静默。
            return true
        }
        if let completedRounds, completedRounds > 0 {
            ToastCenter.shared.show("已停止改写，前 \(completedRounds) 套已保留",
                                    icon: "stop.circle.fill", style: .info)
        } else {
            ToastCenter.shared.show("已停止", icon: "stop.circle.fill", style: .info)
        }
        return true
    }

    private func beginBusy(_ id: UUID?) {
        guard let id else { return }
        registry.begin(id)
        bumpJobs()
    }

    private func endBusy(_ id: UUID?) {
        guard let id else { return }
        registry.end(id)
        bumpJobs()
    }

    /// 结构化阶段进度（阶段内 fraction；nil = 不定条）。
    private func setStage(_ id: UUID?, _ phase: DubbingPhase, _ text: String, fraction: Double? = nil) {
        guard let id else { return }
        registry.setProgress(id, DubbingJobProgress(phase: phase, phaseText: text, fraction: fraction))
        bumpJobs()
    }
    /// 兼容纯文案更新（沿用当前阶段）。
    private func setProgress(_ id: UUID?, _ text: String) {
        guard let id else { return }
        let current = registry.slot(id)?.progress.phase ?? .prepareClone
        let fraction = registry.slot(id)?.progress.fraction
        registry.setProgress(id, DubbingJobProgress(phase: current, phaseText: text, fraction: text.isEmpty ? nil : fraction))
        bumpJobs()
    }

    /// 改写服务。init 可注入（默认 = 生产链路，运行时动态取当前 provider，Settings 改了立即生效）；
    /// DebugSelfTest 就绪腿注入假 provider，在零真实 API 成本下走通`rewrite()` 全链路。
    private let rewriteService: ScriptRewriteService
    /// CosyVoice 合成客户端（预置音色与全局复刻；model 可经 init 注入，默认 cosyvoice-v2）。
    private let tts: TTSClient
    /// qwen3-tts-vc 逐视频克隆合成客户端（存量链路，行为不变）。
    private let vcClient: TTSClient
    private let vocalSep = VocalSeparationService()
    private let cloneService = VoiceCloneService()
    private let finalizer = DubAudioFinalizer()
    private let asrService = ASRService()   // 逐句字幕对齐用（对成品配音做 whisper ASR 测每句时间）
    private var auditionPlayer: AVAudioPlayer?

    /// 按音色身份选合成客户端（引擎路由，与业务模式无关）。
    ///
    /// ⚠️ qwen-vc 分支要**按型号现建客户端**，不能直接返回共享的 `vcClient`：
    /// `QwenTTSClient` 的 model 在 init 时固定（`private let model`），
    /// 而账号级复刻音色（M2）各自绑定自己的型号（`choice.model`）。
    /// 返回共享实例 ⇒ 拿 A 音色注册的 voiceId 会被用B 型号去合成，服务端报
    /// InvalidParameter（且该错只在真机合成时才暴露，类型层面看不出来）。
    ///
    /// 存量视频克隆音色仍走共享 `vcClient`（型号恒为 targetModel），
    /// 既保持零行为变化，也避免每次合成都新建 actor。
    private func synthesisClient(for choice: VoiceChoice) -> TTSClient {
        switch choice.engine {
        case .cosyVoice:
            return tts
        case .qwenVC:
            if case .globalClone(_, _, let model) = choice, !model.isEmpty,
               model != VoiceCloneService.targetModel {
                return QwenTTSClient(model: model)
            }
            return vcClient
        }
    }
    private var playbackResetTask: Task<Void, Never>?

    /// 该 voiceId 是否是这个**分镜**（或该视频）的克隆原声。
    ///
    /// ⚠️ **M2：必须收 segment**。旧签名收 `video`，只比 `video.clonedVoiceId` ——
    /// 而该字段在 M2 后**生产代码已无写点**（恒 nil）⇒ 段级克隆音色恒判为「非克隆」
    /// ⇒ 落进 `generateAudio` 的 `.preset` 分支 ⇒ `VoiceCatalog.voice(id:)` 查不到
    /// ⇒ 报「该变体的音色未配置或已失效」。
    ///
    /// 判据本身在 Core（`CloneBranchDecider.isCloneVoice`），此处只做取参数。
    private func isCloned(_ voiceId: String, _ segment: Segment) -> Bool {
        CloneBranchDecider.isCloneVoice(
            voiceId,
            segmentCloneVoiceID: segment.clonedVoiceId,
            legacyVideoCloneVoiceID: segment.video?.clonedVoiceId)
    }

    // MARK: - 原声克隆（一键改写时自动确保已克隆）

    /// 确保**该分镜**已克隆出原声音色。返回该分镜的 voiceId（nil = 不可克隆）。
    ///
    /// ## M2：从「按视频」改为「按分镜」（本函数是本次缺陷的修复点）
    ///
    /// 旧实现签名收 `Video` 且参考音恒取人声轨 `0~6s`
    /// ⇒ 同一视频里**跨说话人**的分镜拿到同一个音色。实测某 58.8 秒视频
    /// `0~18s` 男声（125~156 Hz）、`21s+` 女声（200~256 Hz），选女声段却克隆出男声。
    ///
    /// 现在：
    /// - 收 `Segment`，用**它自己的时间范围**规划参考窗口（`WindowPlanner`，只向后取）；
    /// - 同视频内窗口重叠的其它分镜**复用**已注册音色（省计费）；
    /// - Key 指纹落**段级字段**（旧实现是 `UserDefaults` 键 `clonedVoiceKeyFP_{videoHash}`，
    ///   按分镜后键数会 ×分镜数）；
    /// - 仍写 `video.clonedVoiceIds` 兼容链上的 `selectedVoiceIds`（读侧回落用，见 `SegmentDub`）。
    ///
    /// - Returns: 该分镜的 voiceId；`nil` 表示不可克隆（分镜已删除 / 无语音 / 找不到视频）。
    @discardableResult
    func ensureClonedVoice(for segment: Segment, context: ModelContext, forceReclone: Bool = false) async -> String? {
        guard let video = segment.video else { return nil }
        let hash = video.contentHash ?? video.id.uuidString
        let currentFP = Self.currentKeyFingerprint()
        let vid = video.id   // 进度按视频独立跟踪（分离是视频级的）
        let fps = video.fps > 0 ? video.fps : 30
        // 视频总帧数：取「最后一个分镜的 endFrame」与「duration × fps」的较大者。
        // ⚠️ Video 上没有 totalFrameCount 字段（只有 fps/segments/duration），
        // 而窗口末端只需不越界 ⇒ 宁可放宽（放宽只是让末尾窗口多几秒，不影响正确性）。
        let derivedTotal = Int((video.duration * fps).rounded())
        let segmentsEnd = video.segments.map(\.endFrame).max() ?? 0
        let totalFrames = max(segment.endFrame, segmentsEnd, derivedTotal, segment.startFrame + 1)

        // 段级窗口（nil = 零长/越界 ⇒ 不克隆）
        guard let window = WindowPlanner.planWindow(startFrame: segment.startFrame,
                                                    fps: fps,
                                                    videoFrameCount: totalFrames) else {
            MixLog.info("[Clone] 分镜 \(segment.id) 窗口不可用，跳过克隆")
            return nil
        }

        // ---- 复用：段级已克隆且窗口一致 → 直接返回 ----
        if !forceReclone,
           let sv = segment.clonedVoiceId, !sv.isEmpty,
           segment.cloneWindowStartFrame == window.startFrame,
           segment.cloneWindowEndFrame == window.endFrame {
            // DashScope 克隆音色绑定注册它的账户(API Key)。换 Key 后旧 voiceId 在新账户不存在。
            if currentFP == nil || segment.cloneKeyFingerprint.isEmpty
                || segment.cloneKeyFingerprint == currentFP {
                if video.selectedVoiceIds != [sv] { video.selectedVoiceIds = [sv]; try? context.save() }
                return sv
            }
            MixLog.info("[Clone] 检测到 API Key 变更，段级旧克隆音色(\(sv))在新账户不可用，重新克隆")
        }

        // ---- 复用：同视频内窗口重叠的**其它分镜**已注册过 → 共享它的音色 ----
        // ⚠️ 只认**段级** `clonedVoiceId`（窗口信息也只有段级有）；
        // 存量视频级 `video.clonedVoiceId` 不参与复用判定——它没有窗口信息，
        // 猜窗口会把它误配到别的说话人上（那正是本缺陷）。
        let siblings: [(window: CloneReferenceWindow, voiceId: String)] = video.segments.compactMap { sib in
            guard sib.id != segment.id,
                  let sid = sib.clonedVoiceId, !sid.isEmpty,
                  sib.cloneWindowStartFrame >= 0, sib.cloneWindowEndFrame > sib.cloneWindowStartFrame
            else { return nil }
            return (CloneReferenceWindow(startFrame: sib.cloneWindowStartFrame,
                                         endFrame: sib.cloneWindowEndFrame), sid)
        }
        if !forceReclone, !siblings.isEmpty {
            let hit = WindowPlanner.reusableWindow(
                candidate: window,
                among: siblings.map(\.window))
            if let hw = hit, let vid2 = siblings.first(where: { $0.window == hw })?.voiceId {
                MixLog.info("[Clone] 分镜 \(segment.id) 复用兄弟分镜音色（窗口 \(hw.startFrame)-\(hw.endFrame)）")
                segment.clonedVoiceId = vid2
                segment.cloneWindowStartFrame = hw.startFrame
                segment.cloneWindowEndFrame = hw.endFrame
                if let fp = currentFP { segment.cloneKeyFingerprint = fp }
                try? context.save()
                return vid2
            }
        }

        segment.clonedVoiceId = nil      // 走下方重克隆流程（能复用的已在上面 return）
        let path = video.localPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            errorState = .init(message: "找不到原视频文件，无法克隆原声", kind: .generic)
            return nil
        }
        MixLog.info("[Clone] 开始克隆原声: video=\(path) 窗口=\(window.startFrame)-\(window.endFrame)")
        do {
            setStage(vid, .prepareClone, "分离人声…")
            let stems = try await vocalSep.separate(videoPath: path, videoHash: hash) { [weak self] p in
                Task { @MainActor in self?.setStage(vid, .prepareClone, p.message, fraction: p.fraction) }
            }
            // 等待分离期间视频可能已被删除（句柄已脱离视图生命周期）：写回前必须过门。
            guard !video.isDroppedFromContext else {
                MixLog.info("[Clone] 视频已删除，中止克隆写回: \(vid)")
                return nil
            }
            if Task.isCancelled { return nil }
            MixLog.info("[Clone] 分离完成: vocals=\(stems.vocalsPath)")
            setStage(vid, .prepareClone, "提取克隆参考…")
            // 参考音取**该分镜的时间范围**（不再恒取视频开头 6s）：
            // 参考音必须【短而干净】(≈6s)—— 18s 长参考含多句原话，qwen 克隆 TTS 会间歇性
            // "续读参考里的内容"导致配音混进下一段(实测 18s→clean 1/3，6s→clean 5/5)。
            let startSeconds = WindowPlanner.seconds(frame: window.startFrame, fps: fps)
            let ref = try await vocalSep.referenceClip(fromVocals: stems.vocalsPath,
                                                         startSeconds: startSeconds)
            guard !video.isDroppedFromContext else { return nil }
            setStage(vid, .prepareClone, "注册克隆音色…")
            // ⚠️ 传入的是纯 ASCII（品牌短名 + hash 前8 位）⇒ 清洗后不变 ⇒ 行为零变化。
            // 名字带上分镜序号，便于在阿里云控制台区分「这是哪个分镜的声音」。
            let enrolled = try await cloneService.enroll(
                referenceAudioPath: ref,
                preferredName: "\(Brand.shortName)\(hash.prefix(6))s\(segment.startFrame)")
            let voiceId = enrolled.voiceId
            guard !video.isDroppedFromContext else { return nil }
            MixLog.info("[Clone] 克隆成功: voiceId=\(voiceId) providerName=\(enrolled.providerName) 窗口=\(window.startFrame)-\(window.endFrame)")
            segment.clonedVoiceId = voiceId
            segment.cloneWindowStartFrame = window.startFrame
            segment.cloneWindowEndFrame = window.endFrame
            if let fp = currentFP { segment.cloneKeyFingerprint = fp }
            // 兼容链：老读侧（SegmentVariantInspector 等）仍看 video.selectedVoiceIds。
            // ⚠️ 新读侧应优先读segment.clonedVoiceId（见 SegmentDub.effectiveDubVariants）。
            video.selectedVoiceIds = [voiceId]
            try? context.save()
            setProgress(vid, "")
            return voiceId
        } catch {
            setProgress(vid, "")
            // 用户停止 / 数据删除导致的取消不是失败：不弹失败 alert（toast 策略由管线检查点统一处理）。
            if Task.isCancelled || error is CancellationError {
                MixLog.info("[Clone] 克隆因取消中断: \(error.localizedDescription)")
                return nil
            }
            MixLog.error("[Clone] 克隆失败: \(error.localizedDescription)")
            // 缺凭证性质在错误产生点定型：未配置千问 Key → 可跳设置；其余按通用错误。
            let kind: DubErrorKind
            if case VoiceCloneService.CloneError.missingAPIKey = error {
                kind = .missingCredential
            } else {
                kind = .generic
            }
            errorState = .init(message: "原声克隆失败：\(Self.friendlyError(error))", kind: kind)
            return nil
        }
    }

    // MARK: - 统一改写入口（自动克隆原声 → 改写 K 套台词 → 合成配音）
    //
    // 作用域（本视频全部 / 当前分镜 / 选中分镜）由入参 targets 与 presentation 表达，
    // 管线体内不出现 scope 分支。调用方负责：disabled 不触发、targets 已稳定排序。

    func rewrite(video: Video,
                 targets: [Segment],
                 presentation: DubScopePresentation,
                 context: ModelContext,
                 projectOverrideRaw: String? = nil) async {
        let vid = video.id
        guard !isBusy(videoID: vid) else { return }   // 防重复点击；与其它视频互不影响
        // 入口 guard（P2-R6）：空目标（disabled 被程序化误用）静默不执行，
        // 不产出空 Toast、不触发任何计费链路。
        guard !targets.isEmpty else { return }
        beginBusy(vid)
        defer { endBusy(vid) }

        // 音色解析（唯一入口；UI 与 MCP 同此）：**段级克隆优先**（M2），
        // 未克隆或已显式跟随全局 → 项目覆盖/全局预置音色，跳过克隆、不付分离注册费。
        //
        // ⚠️ **M2：必须把段级信息传进去**，否则分镜级克隆在解析链里不存在：
        // `LegacyInput` 原先只有视频级 `videoCloneVoiceID`，而它在 M2 后生产代码已无写点
        // ⇒ 恒 nil ⇒ 已配全局音色时解析成 `.preset` ⇒ 下面的分支判定不是 qwenVC
        // ⇒ **跳过 `ensureClonedVoice`，已付费注册的段级克隆音色被无视，合成出全局音色的声音**。
        let hasAnySegmentClone = targets.contains { ($0.clonedVoiceId ?? "").isEmpty == false }
        let suppressClone = video.voiceFollowsGlobal
        let resolution = VoicePreferences.resolveForLegacy(
            video: video, projectOverrideRaw: projectOverrideRaw,
            suppressVideoClone: suppressClone,
            segment: targets.first(where: { $0.clonedVoiceId?.isEmpty == false }),
            hasAnySegmentClone: hasAnySegmentClone)
        // ⚠️ 分支判据**不能**只看 `initialChoice.engine == .qwenVC`：那依赖解析结果，
        // 而解析在「视频级 id 为 nil、段级有克隆」时会落到预置音色 ⇒ 分支判错
        // ⇒ **已付费注册的段级克隆被跳过，合成出全局音色的声音**（实测 R3）。
        //
        // 判据抽在 Core（`CloneBranchDecider`），**两个条件缺一不可**：
        //   ① 用户没显式压制克隆 —— 否则无视其选择、强制克隆 ⇒ 花钱
        //   ② 确实有可用克隆声（段级或存量视频级）—— 否则白跑 demucs 分离
        let shouldCloneBranch = CloneBranchDecider.shouldClone(
            suppressVideoClone: suppressClone)
        // ⚠️ `unconfigured` **不能**直接报错退出（M2）：「段级已克隆但没配全局音色」的
        // 场景解析也会落到这里，而克隆音色此时**完全可用** ⇒ 直接 return 等于
        // 把唯一可用的路径堵死。克隆分支的音色由 ensureClonedVoice 给出，不需要预置音色。
        let initialChoice: VoiceChoice
        switch resolution {
        case .unconfigured:
            guard shouldCloneBranch else {
                errorState = .init(
                    message: "尚未配置配音音色：请到「设置 → 配音」选择一个全局音色后再改写；需要保留原博主音色时，可先在该视频上克隆原声。",
                    kind: .generic)
                return
            }
            // 占位：克隆分支内从不读 `initialChoice.voiceID`（各分镜音色来自 ensure 的返回值）。
            // 占位：**绝不能传空串** —— 空 voiceId 是「貌似合法的坏值」，
            // 一旦有人后来读 `initialChoice.voiceID` 就会拿到"音色 id 为空"这种静默错误。
            // 克隆分支内确实不读它（各分镜音色来自 ensure 的返回值），
            // 用视频级 id 作占位；存量视频本来就有值，新库留空也不会被读到。
            initialChoice = .videoClone(voiceID: video.clonedVoiceId ?? "unresolved-segment-clone")
        case .resolved(let resolved):
            initialChoice = resolved
        }

        // 本次改写每个分镜各自使用的音色。
        // ⚠️ M2：从 `[String]`（全视频共用一个）改为 `[UUID: String]`（**按分镜**）。
        // 旧实现按视频克隆一次、参考音恒取人声轨开头 6 秒 ⇒ 同一视频里跨说话人的分镜
        // 拿到同一个音色（实测某 58.8s 视频 0~18s 男声、21s+ 女声 ⇒ 选女声段却克隆出男声）。
        var voicesBySegment: [UUID: String]
        if shouldCloneBranch {
            // 逐分镜克隆分支：每个分镜用自己的时间范围取参考音；
            // 窗口重叠的相邻分镜会复用（省一次注册计费），见 ensureClonedVoice。
            guard !targets.isEmpty else { return }
            var map: [UUID: String] = [:]
            for (i, seg) in targets.enumerated() {
                if Task.isCancelled { announceCancellation(videoID: vid); return }
                if seg.isDroppedFromContext { continue }
                // 进度按「第 i/N 个音色」播报：注册要花钱，N 次等待需要可见进度。
                setStage(vid, .prepareClone, "准备音色 \(i + 1)/\(targets.count)…", fraction: nil)
                guard let sv = await ensureClonedVoice(for: seg, context: context) else {
                    if Task.isCancelled { announceCancellation(videoID: vid); return }
                    // 该分镜不可克隆（零长/越界）：跳过它，不阻断其余分镜。
                    MixLog.info("[Rewrite] 分镜 \(seg.id) 克隆不可用，跳过")
                    continue
                }
                map[seg.id] = sv
            }
            if Task.isCancelled { announceCancellation(videoID: vid); return }
            guard !video.isDroppedFromContext else { return }
            if map.isEmpty {
                errorState = .init(message: "克隆原声未就绪", kind: .generic); return
            }
            voicesBySegment = map
        } else {
            // 预置/全局复刻分支：零克隆，全部分镜共用解析出的音色。
            if Task.isCancelled { announceCancellation(videoID: vid); return }
            guard !video.isDroppedFromContext else { return }
            voicesBySegment = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, initialChoice.voiceID) })
        }
        // 死实体过门：等待克隆期间分镜可能已被删除。
        let reconfigurable = targets.filter {
            !$0.isDroppedFromContext && !$0.isVoiceLocked && !$0.text.isEmpty
        }
        guard !reconfigurable.isEmpty else {
            if !Task.isCancelled {
                errorState = .init(message: presentation.emptyEligibleError, kind: .generic)
            }
            return
        }

        let inputs = reconfigurable.map {
            RewriteSegmentInput(segmentId: $0.id.uuidString,
                                originalText: $0.text,
                                durationSeconds: $0.duration,
                                keywords: $0.keywords)
        }
        let segById = Dictionary(uniqueKeysWithValues: reconfigurable.map { ($0.id.uuidString, $0) })

        let n = variantCount
        // 首轮互斥：把库里**存量**改写版作为历史注入——覆盖重写时第一轮不再盲写，
        // 否则「重新改写本分镜」结果仍和旧版雷同。收集为空（首次改写）自然降级为无 prior，
        // 任何异常都不得阻断本可正常进行的付费改写链路。
        let (seedIndices, seedRounds) = existingPriorRounds(for: reconfigurable)
        // 本次管线已产出的新轮次（逐轮累积，作为后续轮次互斥输入）
        var freshRounds: [[RewritePriorVersion]] = []

        // 风格起点每次随机（随机源仅此一行），轮次编排走可测纯函数；
        // 同一分镜重复改写不再恒定从池首开始。
        let poolCount = Self.rewriteStyles.count
        let styleBase = Int.random(in: 0..<poolCount)
        let styleIndices = RewriteStylePlan.roundIndices(base: styleBase, rounds: n, poolCount: poolCount)
        MixLog.info("[Rewrite] 开始 video=\(vid) targets=\(reconfigurable.count) rounds=\(n) styleBase=\(styleBase) styleIndices=\(styleIndices) seedPriorRounds=\(seedIndices.count)")

        var completedRounds = 0
        for k in 0..<n {
            // ⚠️ 取消检查：这条链路每轮都在花钱（AI 改写 + 后续 TTS）。
            // 停止/数据删除/换项目的取消在此收口为中性提示，绝不进失败 alert。
            if Task.isCancelled {
                announceCancellation(videoID: vid, completedRounds: completedRounds)
                return
            }
            setStage(vid, .rewrite, "改写第 \(k + 1)/\(n) 套…", fraction: Double(k) / Double(n))
            // 轮次组装保「将被本轮覆盖的旧 k 版」与「同次新产出」在截断窗口尾部，
            // 避免变体数调小后首轮恰好丢了要覆盖的旧版。
            let priorsForRound = RewritePromptBuilder.assemblePriors(
                seedIndices: seedIndices, seedRounds: seedRounds,
                currentIndex: k, freshRounds: freshRounds)
            MixLog.info("[Rewrite] 第 \(k + 1)/\(n) 轮 styleIndex=\(styleIndices[k]) priorRounds=\(priorsForRound.count)")
            do {
                let results = try await rewriteService.rewrite(
                    inputs: inputs,
                    style: Self.rewriteStyles[styleIndices[k]],
                    priorVersions: priorsForRound)
                for r in results {
                    // 死实体过门：分镜在等 AI 响应期间被删则跳过回写。
                    guard let seg = segById[r.segmentId], !seg.isDroppedFromContext else { continue }
                    // ⚠️ 该分镜若在克隆阶段不可用（无语音/窗口越界）则没有音色，跳过它。
                    if let voiceId = voicesBySegment[seg.id] {
                        upsertDub(segment: seg, voiceId: voiceId, textVariantIndex: k,
                                  text: r.rewrittenText, context: context)
                    }
                }
                context.saveOrWarn("改写台词")
                completedRounds += 1
                setStage(vid, .rewrite, "改写第 \(k + 1)/\(n) 套…", fraction: Double(k + 1) / Double(n))
                // 本轮非回退结果累积为下一轮的互斥输入（回退原文不是新说法，注入无意义）
                let roundVersions = results
                    .filter { !$0.isFallback }
                    .map { RewritePriorVersion(segmentId: $0.segmentId, rewrittenText: $0.rewrittenText) }
                if !roundVersions.isEmpty { freshRounds.append(roundVersions) }
            } catch {
                // 取消不是失败：已完成轮次中性保留。
                if Task.isCancelled || error is CancellationError {
                    announceCancellation(videoID: vid, completedRounds: completedRounds)
                    return
                }
                // ⚠️ 以前这里直接 return：已落库的前几套台词留在库里，但后面的批量合成被整体跳过，
                // 于是产生一批"有台词、没音频"的变体，用户看不出问题、也没有"只补合成"的入口。
                // 改为 break：保留已成功的几套，并继续往下走合成，把它们补齐。
                errorState = .init(
                    message: "第 \(k + 1) 套改写失败：\(Self.friendlyError(error))",
                    kind: .generic)
                if completedRounds == 0 {
                    setProgress(vid, "")
                    return   // 一套都没成功才真的中止
                }
                ToastCenter.shared.show("第 \(k + 1) 套改写失败，已保留前 \(completedRounds) 套并继续合成配音",
                                        icon: "exclamationmark.triangle.fill", style: .warning, duration: 4)
                break
            }
        }
        if Task.isCancelled {
            announceCancellation(videoID: vid, completedRounds: completedRounds)
            return
        }
        setProgress(vid, "")

        // 改写完成后自动批量合成 TTS（用户无需逐格手动点）；换 Key 致音色失效时自动重克隆重试
        let result = await generateAllAudioWithRecloneFallback(
            for: reconfigurable, videoID: vid, video: video, context: context)

        // 合成阶段被停止：不发成功 toast、不弹失败 alert，只给中性提示。
        if Task.isCancelled {
            ToastCenter.shared.show("已停止，已合成的配音已保留（\(result.ok) 段）",
                                    icon: "stop.circle.fill", style: .info)
            return
        }
        guard !video.isDroppedFromContext else { return }

        // ⚠️ M2：`voices` 已改为 `voicesBySegment`（逐分镜）。产出数按**有音色的分镜**算，
        // 否则不可克隆的分镜（无语音/窗口越界）会被算进分母，Toast 报的数字虚高。
        let producedCount = reconfigurable.filter { voicesBySegment[$0.id] != nil }.count * n
        if result.fail > 0 {
            // 弹 alert 给出真实失败原因（可截图/复制），不再只显示笼统计数
            errorState = .init(
                message: Self.dubFailureMessage(
                    summary: "已生成 \(producedCount) 个变体，配音合成 \(result.ok) 成功 / \(result.fail) 失败。",
                    errors: result.errors),
                kind: .generic)
        } else {
            // wantsCount 决定是否前置变体总数（布尔开关，无占位符漏传风险）
            let text = presentation.wantsCount
                ? "\(producedCount) \(presentation.successToast)"
                : presentation.successToast
            ToastCenter.shared.show(text,
                                    icon: "checkmark.circle.fill",
                                    style: .success,
                                    duration: 3.5)
        }
    }

    /// 收集 targets 中**存量**改写版，按 variantIndex 分轮，供 assemblePriors 排序组装。
    ///
    /// 降级语义（R3）：纯内存读取，空结果即「首轮无历史」，绝不因收集失败阻断付费改写主链路。
    /// - 手动编辑可能使同一分镜同一 variantIndex 在多 voiceId 上文本分叉：按分镜去重、
    ///   过滤空白，每个分镜每轮最多保留 2 条分叉文本。
    /// - 返回：升序 index 列表 + index → 该轮版本（保留 index 语义供「覆盖旧 k 版优先」排序）。
    private func existingPriorRounds(for targets: [Segment])
        -> (indices: [Int], rounds: [Int: [RewritePriorVersion]]) {
        var collected: [Int: [RewritePriorVersion]] = [:]
        for seg in targets {
            let sid = seg.id.uuidString
            var perIndex: [Int: [String]] = [:]
            for dub in seg.segmentDubs {
                let text = dub.rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var texts = perIndex[dub.textVariantIndex] ?? []
                guard !texts.contains(text) else { continue }
                texts.append(text)
                perIndex[dub.textVariantIndex] = texts
            }
            for (idx, texts) in perIndex {
                for text in texts.prefix(2) {
                    collected[idx, default: []].append(
                        RewritePriorVersion(segmentId: sid, rewrittenText: text))
                }
            }
        }
        return (collected.keys.sorted(), collected)
    }

    // MARK: - 手动新增一版（用户自己写台词 → 自动克隆配音）

    /// 在该分镜下手动新增一个空白改写版，返回新版下标（供 UI 立即进入编辑）。
    /// 自动确保已克隆原声；新建空文本变体，用户写完台词后 updateVariantText 会自动合成配音。
    @discardableResult
    func addManualVariant(for segment: Segment, context: ModelContext) async -> Int? {
        guard let video = segment.video else { return nil }
        guard !segment.isVoiceLocked else {
            errorState = .init(message: "该分镜保留原声，不参与配音", kind: .generic); return nil
        }
        let vid = video.id
        guard !isBusy(videoID: vid) else { return nil }
        beginBusy(vid)
        defer { endBusy(vid) }

        // M2：收segment（该分镜自己的时间范围）⇒ 手动新增的变体与自动改写用**同一个**音色。
        guard let voiceId = await ensureClonedVoice(for: segment, context: context) else {
            return nil
        }

        let nextIndex = (segment.segmentDubs.map { $0.textVariantIndex }.max() ?? -1) + 1
        // M2：音色来自 ensure 的返回值（该分镜自己的窗口），不再读 video.selectedVoiceIds。
        upsertDub(segment: segment, voiceId: voiceId, textVariantIndex: nextIndex,
                  text: "", context: context)
        try? context.save()
        return nextIndex
    }

    // MARK: - 删除某改写版（其所有音色配音 + 磁盘音频）

    /// 删除该分镜下某个改写版（含一键生成的版本）：移除所有音色的 SegmentDub 与磁盘音频文件。
    /// selectedSegmentDubId 只是 UUID 字段，消费端用 first(where:) 解析，删后自动回退原音，不会崩。
    func deleteVariant(_ segment: Segment, textVariantIndex t: Int, context: ModelContext) {
        let dubs = segment.segmentDubs.filter { $0.textVariantIndex == t }
        guard !dubs.isEmpty else { return }
        if let playing = playingDubID, dubs.contains(where: { $0.id == playing }) {
            stopDubPlayback()
        }
        let doomedIDs = Set(dubs.map(\.id))
        for d in dubs {
            if let path = d.audioFilePath { try? FileManager.default.removeItem(atPath: path) }
        }
        // 顺序是真约束：先从**还活着**的关系数组里按 id 摘掉，再整批删。
        // 反过来（先 delete 再按 id 摘）等于对已删对象读 `.id` —— 就是这次崩溃那一类。
        segment.segmentDubs.removeAll { doomedIDs.contains($0.id) }
        context.delete(dubs)
        try? context.save()
    }

    // MARK: - 编辑某改写版台词（改完重生成该版 TTS）

    /// 把某 textVariant 下所有音色的台词改成 newText，清旧音频并重生成 TTS。
    func updateVariantText(segment: Segment, textVariantIndex t: Int,
                           newText: String, context: ModelContext) async {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorState = .init(message: "台词不能为空", kind: .generic); return
        }

        let dubs = segment.segmentDubs.filter { $0.textVariantIndex == t }
        guard !dubs.isEmpty else { return }
        var changed = false
        for d in dubs where d.rewrittenText != trimmed {
            d.rewrittenText = trimmed
            d.audioFilePath = nil
            d.status = .pending
            changed = true
        }
        guard changed else { return }
        try? context.save()

        guard let video = segment.video else { return }
        let vid = video.id
        beginBusy(vid)
        defer { endBusy(vid) }
        setStage(vid, .synthesize, "重新合成本版配音…")
        let result = await generateAllAudioWithRecloneFallback(
            for: [segment], videoID: vid, video: video, context: context)
        setProgress(vid, "")
        // 取消不弹失败 alert。
        if Task.isCancelled {
            ToastCenter.shared.show("已停止，已合成的配音已保留", icon: "stop.circle.fill", style: .info)
            return
        }
        if result.fail > 0 {
            errorState = .init(
                message: Self.dubFailureMessage(
                    summary: "台词已更新，配音 \(result.ok) 成功 / \(result.fail) 失败。",
                    errors: result.errors),
                kind: .generic)
        } else {
            ToastCenter.shared.show("台词已更新并重新生成配音", icon: "checkmark.circle.fill", style: .success)
        }
    }

    /// 汇总批量配音失败信息：概览 + 真实失败原因（最多列前 2 条，避免过长）+ 重试指引。
    static func dubFailureMessage(summary: String, errors: [String]) -> String {
        guard !errors.isEmpty else { return summary + "\n失败项可在分镜右侧点 ↻ 重试。" }
        let shown = errors.prefix(2).enumerated()
            .map { errors.count > 1 ? "\($0.offset + 1). \($0.element)" : $0.element }
            .joined(separator: "\n")
        let more = errors.count > 2 ? "\n…等共 \(errors.count) 类原因" : ""
        return "\(summary)\n\n失败原因：\n\(shown)\(more)\n\n失败项可在分镜右侧点 ↻ 重试。"
    }

    /// 当前千问 API Key 的指纹（SHA256 前 8 位 hex）。只存指纹不存明文，用于检测换 Key。
    static func currentKeyFingerprint() -> String? {
        let fp = KeyFingerprint.of(KeychainHelper.getAPIKey(for: .qwen))
        return fp.isEmpty ? nil : fp
    }

    /// 把底层（DashScope / 网络）错误翻译成用户能看懂的提示，并保留原始返回片段便于排查。
    /// 与 AI 改写共用 APIErrorClassifier 的识别规则，避免重复维护两套。
    static func friendlyError(_ error: Error) -> String {
        FriendlyError.reason(for: error)
    }

    /// qwen 克隆 TTS 偶发"续读参考内容"(合成音频比台词长、混进下一段，且常带重复)。
    /// 干净版必然最短：重试最多 3 次取最短结果；某次时长 ≤ 字数×阈值(视为干净)即提前返回。
    private static func synthesizeCloneRobust(client: TTSClient, text: String, voiceId: String) async throws -> TTSResult {
        let maxTries = 3
        let cleanLimit = Double(max(1, text.count)) * 0.28   // 秒/字上限，超过疑似跑飞
        var best: TTSResult?
        for _ in 0..<maxTries {
            let r = try await client.synthesize(text: text, voiceId: voiceId, languageType: "Chinese", rate: 1.0)
            if best == nil || r.rawDuration < best!.rawDuration { best = r }
            if r.rawDuration <= cleanLimit { break }   // 看着干净，直接用
        }
        return best!
    }

    /// 缓存未命中时的真实合成路径，并在**返回前**把原始音频存入缓存。
    ///
    /// 抽成独立函数而非内联在 `generateAudio` 里，有两个原因：
    /// ① **可读性**：命中/未命中两条路径对称，`generateAudio` 里只留「选哪条」；
    /// ② **可验证性**：存缓存必须在 finalize 之前（finalize 会删掉传入文件），
    /// 收在一个函数里才不会在后续改动中被挪到 finalize 之后。
    ///
    /// - Parameter skipCacheProbe: true 表示**本分镜此前已合成过同文案**（`forceRegenerate`
    ///   或改写后重生成）。此时「读缓存拿到脏音频」的风险大于「再花一次钱重合成」——
    ///   见 `synthesizeCloneRobust` 的跑飞说明：首包可能续读参考内容，且**同样的输入
    ///   未必复现同样的脏结果**，缓存会把一次偶发的跑飞**固化**下来反复播放。
    ///   故此路径直接跳过缓存读写，只做一次干净重合成。
    private static func synthesizeFresh(client: TTSClient,
                                        voiceID: String,
                                        text: String,
                                        targetDuration: Double,
                                        bias: Double,
                                        cloned: Bool,
                                        skipCacheProbe: Bool,
                                        cacheSpec: (engine: RawAudioCacheKey.Engine,
                                                    model: String,
                                                    sampleRate: Int,
                                                    format: String)?) async throws -> TTSResult {
        let firstRate = 1.0
        let cacheable = skipCacheProbe ? nil : cacheSpec
        let result: TTSResult
        if cloned {
            // qwen克隆 TTS 间歇性"续读参考内容/跑飞"(音频比台词长，混进下一段)：
            // 干净版必然最短 → 重试取最短，看着干净(时长≤字数×阈值)即提前采用。
            result = try await synthesizeCloneRobust(client: client, text: text, voiceId: voiceID)
        } else {
            var r = try await client.synthesize(text: text, voiceId: voiceID,
                                                languageType: "Chinese", rate: firstRate)
            if let retarget = SpeechRatePlanner.retargetRate(
                targetDuration: targetDuration, measuredDuration: r.rawDuration,
                measuredAtRate: firstRate, bias: bias) {
                r = try await client.synthesize(text: text, voiceId: voiceID,
                                                languageType: "Chinese", rate: retarget)
            }
            result = r
        }
        // 存入缓存（键用 rate=1.0 —— 与下次查询用的键严格一致；命中率靠分桶保证）。
        // ⚠️ 读侧在「该分镜此前已合成过同文案」时会绕过缓存（skipCacheProbe），
        // 写侧**同样**要绕过 —— 否则刚绕过脏缓存、转头又把这次的新结果盖进去，
        // 下次那条路径又会命中。两边必须同一把尺子。
        if let cacheable {
            let key = RawAudioCacheStore.key(engine: cacheable.engine, model: cacheable.model,
                                             voiceID: voiceID, text: text, rate: firstRate,
                                             sampleRate: cacheable.sampleRate, format: cacheable.format)
            await RawAudioCacheStore.shared.store(key: key,
                                                  audioURL: URL(fileURLWithPath: result.wavPath),
                                                  rawDuration: result.rawDuration)
        }
        return result
    }

    // MARK: - M3 原始音频缓存（M3：只缓存原始 TTS，绝不复用成品 m4a）

    /// 该音色身份是否可缓存，以及缓存键所需的固定维度（model/采样率/格式）。
    /// 返回 nil = 该组合不进缓存（调用方按原路径合成）。
    ///
    /// ## 两个引擎都进缓存，但克隆分支多一道「脏音频」防线
    ///
    /// qwen-vc 分支带「重试取最短」健壮逻辑（`synthesizeCloneRobust`），
    /// 这是为治「间歇性续读参考内容/跑飞」而存在的。跑飞的特征是**音频比台词长**
    /// 且混进下一段内容。对缓存的含义：
    ///
    /// - **存的时候**：重试会挑出「最干净的那一份」（时长最短），缓存它是对的 ——
    ///   缓存的是「已通过时长阈值筛选」的结果，不是跑飞的那份。
    /// - **读的时候**：同样输入**未必复现同样的脏结果**（这是间歇性故障），
    ///   但缓存一旦存进跑飞版就会**固化**，之后每次命中都放跑飞版 ⇒ 必须能绕过。
    ///
    /// 所以 `generateAudio` 传`skipCacheProbe` 给`已合成过同文案` 的场景
    /// （`forceRegenerate` / 改写后重生成），那条路径跳过缓存读写、只做干净重合成。
    /// 首次合成仍走缓存（那正是缓存最该省钱的场景）。
    private static func rawCacheSpec(for choice: VoiceChoice,
                                     voiceID: String) -> (engine: RawAudioCacheKey.Engine,
                                                          model: String,
                                                          sampleRate: Int,
                                                          format: String)? {
        switch choice.engine {
        case .cosyVoice:
            return (.cosyVoice,
                    choice.cosyVoiceModel ?? CosyVoiceCatalog.model,
                    CosyVoiceTTSClient.sampleRateForCache,
                    CosyVoiceTTSClient.formatForCache)
        case .qwenVC:
            // ⚠️ model 维度必须取**该音色实际注册/合成时用的型号**，不能一律用
            // `VoiceCloneService.targetModel`：账号级复刻音色（M2）允许绑定不同型号
            // （如 `qwen3-tts-vc-realtime-*`）。若一律写死 targetModel，
            // 同一音色按 targetModel 建键、却用另一个型号合成 ⇒ 键与内容不对应，
            // 最坏情况是**命中了另一型号的缓存音频**（音色/音质都不是用户要的那个）。
            //
            // 取值优先级：choice 带型号（globalClone 的 model）→ 存量视频克隆回落到
            // targetModel（存量 voiceId 就是用它注册的，写死才对得上）。
            let model = Self.qwenSynthesisModel(for: choice)
            return (.qwenVC, model,
                    QwenTTSClient.sampleRateForCache,
                    QwenTTSClient.formatForCache)
        }
    }

    /// qwen-vc 引擎下的实际合成型号（缓存键的 model 维度）。
    ///
    /// 单独抽出而非内联：注册、合成、缓存键三处必须**同一个型号**（服务端要求
    /// 注册型号与合成型号一致，否则合成失败）。三处各自硬编码是这类 bug 的温床。
    private static func qwenSynthesisModel(for choice: VoiceChoice) -> String {
        switch choice {
        case .globalClone(_, _, let model) where !model.isEmpty:
            return model
        default:
            // 预置/存量视频克隆：voiceId 由 VoiceCloneService.targetModel 注册而来。
            return VoiceCloneService.targetModel
        }
    }

    /// 缓存命中/临时副本用的唯一临时路径出口（finalize 会删传入文件，故必须是副本）。
    private static func ttsTempURL(prefix: String) -> URL {
        FileHelper.tempDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).tmp")
    }

    /// 同 (分镜, 音色, 改写版) 已存在则更新文本（文本变更则清空旧音频），否则新建。
    private func upsertDub(segment: Segment, voiceId: String, textVariantIndex: Int,
                           text: String, context: ModelContext) {
        if let existing = segment.segmentDubs.first(where: {
            $0.voiceId == voiceId && $0.textVariantIndex == textVariantIndex
        }) {
            if existing.rewrittenText != text {
                existing.rewrittenText = text
                existing.audioFilePath = nil
                existing.status = .pending
            }
        } else {
            let dub = SegmentDub(segment: segment, voiceId: voiceId,
                                 textVariantIndex: textVariantIndex, rewrittenText: text)
            context.insert(dub)
            segment.segmentDubs.append(dub)
        }
    }

    // MARK: - M1b 音色偏好写入收口

    /// 视频级「原声克隆 ↔ 跟随全局/项目」开关唯一写入点（G-V7 守此函数名）。
    /// 只改变此后新生成的解析口径（VoiceResolver.suppressVideoClone），不重生成、不删除既有音频。
    /// VM 不持有 ModelContext，与配音生成方法同形态由调用方显式传入。
    func setVideoFollowsGlobal(_ follows: Bool, video: Video, context: ModelContext) {
        guard video.voiceFollowsGlobal != follows else { return }
        video.voiceFollowsGlobal = follows
        context.safeSave()
    }

    // MARK: - 按需生成单格音频

    /// - Parameter silent: 批量生成时传 true，失败不逐条弹窗（由调用方汇总）。
    /// - Returns: 是否生成成功。
    @discardableResult
    func generateAudio(for dub: SegmentDub, context: ModelContext, silent: Bool = false) async -> Bool {
        await generateAudio(for: dub, context: context, silent: silent, resolvedChoice: nil)
    }

    /// - Parameter resolvedChoice: 调用方已经 VoiceResolver 解析出的音色身份（脚本成片/无克隆链路传入）。
    ///   nil = 兼容旧调用，按 dub.voiceId 现场推导（视频克隆 ∪ CosyVoice 目录）。
    @discardableResult
    func generateAudio(for dub: SegmentDub, context: ModelContext, silent: Bool = false,
                       resolvedChoice: VoiceChoice?) async -> Bool {
        guard let segment = dub.segment, let video = segment.video else { return false }
        guard !dub.rewrittenText.isEmpty else {
            if !silent {
                errorState = .init(message: "该变体没有台词", kind: .generic)
            }
            return false
        }
        // 音色身份：显式解析优先；否则按存量形态推导（视频克隆 ∪ 预置目录）。
        // 空 voiceId 的脚本空壳必须由调用方经解析绑定后传入，这里不猜测、不兜底。
        let choice: VoiceChoice
        if let resolvedChoice {
            choice = resolvedChoice
        } else if isCloned(dub.voiceId, segment) {
            choice = .videoClone(voiceID: dub.voiceId)
        } else if VoiceCatalog.voice(id: dub.voiceId) != nil {
            choice = .preset(voiceID: dub.voiceId)
        } else {
            if !silent {
                errorState = .init(
                    message: "该变体的音色未配置或已失效，请在「设置 → 配音」选择全局音色后重试",
                    kind: .generic)
            }
            return false
        }
        // M2：全局复刻 profile 的有效性接真实判据 —— 库里存在、且未因换 Key 而失效。
        // ⚠️ 这里必须**活查 SwiftData**（而不是让调用方把 profile 传进来）：
        // `VoiceSynthesisGate` 是 Core 纯函数，只吃 (profileID) -> Bool；
        // 若把 profile 实体塞进解析入参，纯值判据就退化成了有实体依赖的判据，
        // 未来「已删除 profile 的残留 choice」这类测试就无从构造。
        // 只在 `.globalClone` 分支才查库，存量路径零额外 IO。
        let currentFP = Self.currentKeyFingerprint()
        let usable = VoiceSynthesisGate.isUsable(
            choice,
            isCatalogVoice: { VoiceCatalog.voice(id: $0) != nil },
            isValidCloneProfile: { profileID in
                guard let p = try? context.fetch(FetchDescriptor<VoiceProfile>())
                    .first(where: { $0.id == profileID }) else { return false }
                return !p.isInvalidated(currentKeyFingerprint: currentFP)
            })
        guard usable else {
            if !silent {
                errorState = .init(
                    message: Self.invalidVoiceMessage(for: choice, context: context),
                    kind: .generic)
            }
            return false
        }
        let cloned = choice.engine == .qwenVC
        busyDubIDs.insert(dub.id)
        defer { busyDubIDs.remove(dub.id) }
        do {
            let target = segment.duration
            let bias = video.dubSpeechRate
            // qwen-vc 引擎（逐视频克隆）无数值语速，靠 atempo 对齐 + 健壮重试；
            // CosyVoice 引擎（预置/全局复刻）走 rate 对齐。客户端按音色身份路由。
            let client = synthesisClient(for: choice)
            let synthVoiceID = choice.voiceID

            // M3 原始音频缓存：命中即省一次 TTS 计费。
            // ⚠️ 缓存的是**原始 TTS 音频**，不是成品 m4a —— 成品与 targetDuration/fps
            // 强绑定（atempo+补帧），同一文案出现在不同时长的分镜里无法复用成品；
            // 命中后各分镜仍各自 finalize（自己的 atempo），故时长各自正确。
            // ⚠️ 命中时必须把缓存**复制**到临时文件再交给 finalize —— finalize
            // 会删掉传入的文件，直接给缓存真身会把缓存删空。
            let cacheSpec = Self.rawCacheSpec(for: choice, voiceID: synthVoiceID)

            // 这条 dub 此前是否已按**同一段文案**合成过？若是，说明本次是「重新生成」
            // （forceRegenerate 或改写后重生成）—— 那次合成可能跑飞过。
            // qwen 克隆的跑飞是间歇性的（同样输入未必复现），但缓存会**固化**跑飞版，
            // 所以这类场景必须绕过缓存重合成，而不是拿回那份可能脏的音频。
            let regeneratedSameText = !dub.generatedForTextHash.isEmpty
                && dub.generatedForTextHash == DubStaleness.textHash(of: dub.rewrittenText)

            // 两条路径（命中 / 新合成）各自返回「可交给 finalize 的 TTSResult」。
            // ⚠️ 刻意用 if/else **表达式**而不是「先 var result 再分支赋值」——
            // 后者 Swift 无法证明所有路径都已初始化（silgen 腿实测报
            // "variable 'result' used before being initialized"，而 typecheck 放行）。
            let hitURL = Self.ttsTempURL(prefix: "cachhit")
            let cachedDuration: Double? = if let cacheSpec, !regeneratedSameText {
                await RawAudioCacheStore.shared.hit(
                    key: RawAudioCacheStore.key(engine: cacheSpec.engine, model: cacheSpec.model,
                                               voiceID: synthVoiceID, text: dub.rewrittenText,
                                               rate: 1.0, sampleRate: cacheSpec.sampleRate,
                                               format: cacheSpec.format),
                    copyingTo: hitURL)
            } else {
                nil
            }
            let result: TTSResult
            if let cachedDuration {
                MixLog.info("[TTSCache] 命中 raw=\(String(format: "%.2f", cachedDuration))s voice=\(synthVoiceID)")
                result = TTSResult(wavPath: hitURL.path, rawDuration: cachedDuration)
            } else {
                if regeneratedSameText {
                    MixLog.info("[TTSCache] 该分镜此前已合成过同文案（可能跑飞过）→ 本次绕过缓存重合成")
                }
                result = try await Self.synthesizeFresh(
                    client: client, voiceID: synthVoiceID, text: dub.rewrittenText,
                    targetDuration: target, bias: bias, cloned: cloned,
                    skipCacheProbe: regeneratedSameText, cacheSpec: cacheSpec)
            }
            let finalized = try await finalizer.finalize(
                tts: result, targetDuration: target, fps: video.fps > 0 ? video.fps : 30,
                videoHash: video.contentHash ?? video.id.uuidString,
                segmentId: segment.id, voiceId: dub.voiceId, textVariantIndex: dub.textVariantIndex)
            dub.audioFilePath = finalized.m4aPath
            dub.atempoFactor = finalized.plan.atempoFactor
            dub.freezePadFrames = finalized.plan.freezePadFrames
            dub.trailingSilence = finalized.plan.trailingSilence
            // 对齐后实际音频时长（atempo 变速后），用于在变体池展示
            dub.audioDuration = result.rawDuration / max(0.0001, finalized.plan.atempoFactor)
            dub.generatedForStartFrame = segment.startFrame
            dub.generatedForEndFrame = segment.endFrame
            dub.generatedForTextHash = DubStaleness.textHash(of: dub.rewrittenText)
            // 同一次落笔也要把**原台词**的哈希记下来：只追踪改写版时，
            // "原台词被重听换掉、改写版没动"这条配音就会永远显示新鲜（无声的错位）。
            dub.generatedForSourceTextHash = DubStaleness.textHash(of: segment.text)
            dub.status = .generated
            // TTS 已计费、音频已落盘：保存失败会变成"孤儿文件 + 必须重新付费合成"，必须告知
            context.saveOrWarn("配音")
            // 配音落库后自动逐句对齐（whisper 对成品配音测每句时间；失败静默走比例兜底，不阻断配音成功）
            await alignCaptions(for: dub, context: context)
            lastDubErrors[dub.id] = nil   // 成功后清掉旧失败原因
            return true
        } catch {
            dub.status = .failed
            try? context.save()
            let friendly = Self.friendlyError(error)
            lastDubErrors[dub.id] = friendly   // 即使 silent 也记录，供批量汇总透出
            MixLog.error("[Dub] 配音生成失败 dub=\(dub.id): \(error.localizedDescription)")
            if !silent {
                // 未配置千问 Key 的 TTS 失败 → 可跳设置；与克隆失败的归类口径一致。
                let kind: DubErrorKind
                if case TTSError.missingAPIKey = error {
                    kind = .missingCredential
                } else {
                    kind = .generic
                }
                errorState = .init(message: "配音生成失败：\(friendly)", kind: kind)
            }
            return false
        }
    }

    /// 音色不可用时的提示。**区分两种失效** —— 用户要采取的动作完全不同：
    /// 「已被删除」去库里删掉引用即可；「换 Key 失效」得用回原 Key 或重新注册。
    private static func invalidVoiceMessage(for choice: VoiceChoice, context: ModelContext) -> String {
        switch choice {
        case .globalClone(let profileID, _, _):
            let fp = Self.currentKeyFingerprint()
            let p = try? context.fetch(FetchDescriptor<VoiceProfile>())
                .first(where: { $0.id == profileID })
            if let p, p.isInvalidated(currentKeyFingerprint: fp) {
                return VoiceProfileValidity.invalidatedMessage()
            }
            return "这个复刻音色已被删除。请到「设置 → 配音 → 我的复刻音色库」重新选择或注册。"
        default:
            return "该变体的音色未配置或已失效，请在「设置 → 配音」选择全局音色后重试"
        }
    }

/// 逐句对齐的结局。调用方据此决定要不要给用户提示。
    enum CaptionAlignOutcome {
        /// ASR 成功，按真实词时间戳对齐
        case aligned
        /// ASR 失败，按字数比例估算（精度较差）
        case approximated(reason: String)
        /// 什么都没做，附原因
        case skipped(reason: String)
    }

    /// 对已生成配音的 dub 做逐句对齐，写回 captionLines。
    /// ASR 跑成品 m4a（已 atempo，时间=分镜内 0 起）；ASRService 是 actor，await 期间不卡主线程。
    ///
    /// - Parameter allowApproximation: ASR 失败时是否允许用「按字数比例估算」的结果覆盖现有字幕。
    ///   - 刚生成配音后的**自动**对齐传 `true`：此时 captionLines 本来就是空的，估算总比没有强。
    ///   - 用户手动点「重新自动对齐」时必须传 `false`：他可能已经逐句手调过时间，
    ///     ASR 一失败就拿估算值覆盖，等于**静默毁掉他的手工成果**且界面上毫无异样。
    @discardableResult
    func alignCaptions(for dub: SegmentDub, context: ModelContext,
                       allowApproximation: Bool = true) async -> CaptionAlignOutcome {
        guard let audio = dub.audioFilePath, FileManager.default.fileExists(atPath: audio) else {
            return .skipped(reason: "这一版还没有生成配音音频，或音频文件已丢失。请先生成配音再对齐。")
        }
        guard let seg = dub.segment else {
            return .skipped(reason: "这条配音已不属于任何分镜，无法对齐。")
        }
        let segDur = seg.duration
        guard segDur > 0 else {
            return .skipped(reason: "分镜时长为 0，无法计算字幕时间。")
        }
        guard !dub.rewrittenText.isEmpty else {
            return .skipped(reason: "这一版没有台词文本，没有可对齐的内容。")
        }

        var words: [AlignWord] = []
        var audioDur = dub.audioDuration
        var asrFailure: String?
        do {
            let r = try await asrService.transcribe(videoPath: audio)
            words = r.words.map { AlignWord(text: $0.word, start: $0.start, end: $0.end) }
            if r.duration > 0 { audioDur = r.duration }
        } catch {
            asrFailure = FriendlyError.reason(for: error)
            MixLog.info("[Caption] 逐句对齐 ASR 失败: \(error.localizedDescription)")
        }

        if let asrFailure, !allowApproximation {
            // 拿不到真实词时间戳，又不允许用估算覆盖 → 保持现状，把原因如实告诉用户
            return .skipped(reason: "语音识别没能跑通，无法精确对齐，已保留你当前的字幕时间未做改动。\n原因：\(asrFailure)")
        }

        let lines = SentenceTimingAligner.align(text: dub.rewrittenText, words: words,
                                                audioDuration: audioDur, segmentDuration: segDur)
        dub.captionLines = lines
        context.saveOrWarn("字幕时间")
        if let asrFailure {
            return .approximated(reason: asrFailure)
        }
        return .aligned
    }

    /// 批量合成一组分镜下所有「还没音频」的变体（一键改写后自动调用）。
    private func generateAllAudio(for segments: [Segment], videoID: UUID?,
                                  context: ModelContext) async -> (ok: Int, fail: Int, errors: [String]) {
        // 死实体过门：分镜或配音记录已删则不合成（句柄脱离视图后删除可能发生在等待期间）。
        let pending = segments
            .filter { !$0.isDroppedFromContext }
            .flatMap { $0.segmentDubs }
            .filter { !$0.isDroppedFromContext && $0.audioFilePath == nil && !$0.rewrittenText.isEmpty }
        guard !pending.isEmpty else { return (0, 0, []) }
        let total = pending.count
        var ok = 0, fail = 0
        var errors: [String] = []   // 去重收集真实失败原因，供上层透出
        for dub in pending {
            // ⚠️ 合成是整条链路里最长最贵的一段（每段都要调 TTS）。
            // 用户点了停止 / 素材被删 / 换项目，必须立刻停手，不能继续烧配额。
            if Task.isCancelled || dub.isDroppedFromContext {
                MixLog.info("[Dub] 取消或实体已删，已合成 \(ok) 段，剩余 \(total - ok - fail) 段未合成")
                break
            }
            let done = ok + fail
            setStage(videoID, .synthesize, "合成配音 \(done + 1)/\(total)…",
                     fraction: Double(done) / Double(total))
            if await generateAudio(for: dub, context: context, silent: true) {
                ok += 1
            } else {
                fail += 1
                if let m = lastDubErrors[dub.id], !errors.contains(m) { errors.append(m) }
            }
        }
        setStage(videoID, .synthesize, ok + fail == total ? "合成配音 \(total)/\(total)…" : "合成配音 \(ok + fail)/\(total)…",
                 fraction: Double(ok + fail) / Double(total))
        return (ok, fail, errors)
    }

    /// 判断批量失败是否为「克隆音色失效」（多因更换 API Key，旧克隆音色在新账户不存在）。
    static func isStaleCloneError(_ errors: [String]) -> Bool {
        errors.contains { e in
            let l = e.lowercased()
            return l.contains("tts speak request failed")
                || (l.contains("invalidparameter") && l.contains("voice"))
                || l.contains("克隆音色在当前 api key")
        }
    }

    /// 批量合成；若失败是「克隆音色失效」，自动用当前 Key 强制重克隆、把待生成变体迁到新音色后重试一次。
    /// 覆盖指纹无法识别的存量旧音色：乐观复用→真失败→自愈重克隆，用户无感；没换 Key 则永不触发。
    private func generateAllAudioWithRecloneFallback(
        for segments: [Segment], videoID vid: UUID?, video: Video, context: ModelContext
    ) async -> (ok: Int, fail: Int, errors: [String]) {
        let first = await generateAllAudio(for: segments, videoID: vid, context: context)
        guard first.fail > 0, Self.isStaleCloneError(first.errors) else { return first }
        setStage(vid, .prepareClone, "检测到克隆音色失效，正在用当前 Key 重新克隆…")
        // ⚠️ M2 逐段重克隆：段级音色各自绑定自己的注册窗口，重克隆也要按段走，
        // 否则「拿A 段的窗口重新注册」会把 B 段的声音也换掉。
        var remapped: [UUID: String] = [:]      // segmentID → newVoiceId
        for seg in segments where !seg.isDroppedFromContext {
            let oldVoice = seg.clonedVoiceId ?? video.clonedVoiceId
            guard let oldVoice, !oldVoice.isEmpty else { continue }
            guard let newVoice = await ensureClonedVoice(for: seg, context: context,
                                                         forceReclone: true),
                  newVoice != oldVoice else { continue }
            remapped[seg.id] = newVoice
        }
        guard let anyNew = remapped.values.first else {
            return first   // 重克隆全部失败 → 保留原始错误供展示
        }
        // 把这些分镜下「待生成且仍指向旧克隆音色」的变体迁到**各自的新音色**
        // （已生成的本地文件不动）。
        // ⚠️ M2 逐段迁移：每段的新音色可能不同（窗口不同 ⇒ 可能注册出不同 voiceId），
        // 一律写同一个 newVoice 会把 A 段的声音套到 B 段上（= 跨说话人错配）。
        for (segID, newVoice) in remapped {
            guard let seg = segments.first(where: { $0.id == segID }), !seg.isDroppedFromContext
            else { continue }
            let oldVoice = seg.clonedVoiceId
            for dub in seg.segmentDubs where !dub.isDroppedFromContext && dub.audioFilePath == nil {
                if let oldVoice, dub.voiceId != oldVoice && dub.voiceId != newVoice { continue }
                dub.voiceId = newVoice
                dub.status = .pending
            }
        }
        try? context.save()
        setStage(vid, .synthesize, "重克隆完成，重新合成配音…", fraction: nil)
        let retry = await generateAllAudio(for: segments, videoID: vid, context: context)
        setProgress(vid, "")
        return retry
    }

    // MARK: - 试听已生成的变体音频（对齐后的成片音频）

    /// 播放某个变体已生成的音频文件（再次点击同一变体则停止）。
    func playDub(_ dub: SegmentDub) {
        if playingDubID == dub.id { stopDubPlayback(); return }
        guard let path = dub.audioFilePath, FileManager.default.fileExists(atPath: path) else {
            errorState = .init(message: "音频文件不存在，请重新生成该变体", kind: .generic)
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            auditionPlayer = player
            player.play()
            playingDubID = dub.id
            // 播完自动复位高亮（AVAudioPlayer 的 delegate 需要 NSObject，这里用时长定时复位更简单）
            playbackResetTask?.cancel()
            let duration = max(0.1, player.duration)
            playbackResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self?.playingDubID == dub.id { self?.playingDubID = nil }
            }
        } catch {
            errorState = .init(
                message: "播放失败：\(error.localizedDescription)", kind: .generic)
        }
    }

    func stopDubPlayback() {
        playbackResetTask?.cancel()
        playbackResetTask = nil
        auditionPlayer?.stop()
        auditionPlayer = nil
        playingDubID = nil
    }

    // MARK: - 导出前补齐选定变体音频

    /// 对方案里被选中但还没音频的变体按需补齐合成（导出前调用）。
    func ensureSelectedAudio(for scheme: MixScheme, context: ModelContext) async {
        for ss in scheme.orderedSegments {
            guard let id = ss.selectedSegmentDubId,
                  let dub = ss.segment?.segmentDubs.first(where: { $0.id == id }),
                  dub.audioFilePath == nil else { continue }
            await generateAudio(for: dub, context: context)
        }
    }

    // MARK: - 产品脚本成片：配音生成（dubOnly，全新配音，不克隆、不改文案）

    /// 脚本方案配音就绪度（VM 单一投影；UI 与导出 blockers 同源）。
    struct ScriptReadiness: Equatable {
        var ready: Int
        var total: Int
        var allReady: Bool { total > 0 && ready == total }
    }

    /// 单槽配音 UI 态（VM 投影；视图层零跨边读）。
    /// M1b：staleVoice = 已有音频但音色已被改选（先于 ready 判定；旧音频可播放，点生成才按新音色合成）。
    enum ScriptSlotState: Equatable {
        case missing, pending, busy, ready, staleVoice
    }

    /// 槽位当前生效音色（M1b 单一函数，展示投影与生成路径共用）：
    /// 段覆盖 VoiceChoiceCoder 串优先（坏串回落），否则项目覆盖 → 全局默认；未配置返回 nil。
    /// 纯字符串/UserDefaults 读取，无 SwiftData 关系访问，无 IO。
    func resolvedScriptChoice(for schemeSeg: SchemeSegment, project: Project?) -> VoiceChoice? {
        VoiceChoiceCoder.decode(schemeSeg.preferredVoiceChoiceRaw)
            ?? projectLevelScriptChoice(project: project)
    }

    /// 项目级脚本音色（resolveForScript 的 .resolved 取值）。
    private func projectLevelScriptChoice(project: Project?) -> VoiceChoice? {
        guard case .resolved(let choice) = VoicePreferences.resolveForScript(project: project) else {
            return nil
        }
        return choice
    }

    /// 段级音色覆盖唯一写入收口（raw=nil 表示跟随项目/全局默认）。只影响此后新生成。
    func setScriptSlotVoiceOverride(raw: String?, schemeSeg: SchemeSegment, context: ModelContext) {
        schemeSeg.preferredVoiceChoiceRaw = raw
        context.safeSave()
    }

    /// 方案槽有效变体的纯值投影（App 层值类型；Core 侧对应 DubVariantValue）。
    /// 视图只消费它，不直读 segment.segmentDubs（G08）。
    struct SlotVariantView: Identifiable, Equatable {
        let dubID: UUID
        let variantIndex: Int
        let voiceID: String
        var id: UUID { dubID }
    }

    /// 方案槽 R3 有效变体：按卡片所属工作流解析「当前音色」后交 Core 去重。
    /// dubOnly 脚本槽当前音色=段覆盖→项目/全局且永不回退克隆；普通方案槽=该视频 legacy 解析。
    func effectiveSlotVariants(for schemeSeg: SchemeSegment, project: Project?) -> [SlotVariantView] {
        guard let segment = schemeSeg.segment, let video = segment.video else { return [] }
        let isDubOnly = !(schemeSeg.scheme?.audioTrackPolicy.allowsOriginalFallback ?? true)
        let preferredVoiceID: String?
        let cloneVoiceID: String?
        if isDubOnly {
            preferredVoiceID = resolvedScriptChoice(for: schemeSeg, project: project)?.voiceID
            cloneVoiceID = nil
        } else if case .resolved(let choice) = VoicePreferences.resolveForLegacy(
            video: video,
            projectOverrideRaw: project?.preferredVoiceChoiceRaw,
            // ⚠️ 这里是 **SchemeSegment（方案段）**，不是 Segment（分镜）：
            // SchemeSegment 没有段级克隆字段 ⇒ M2 的按分镜克隆只作用于**素材库链路**。
            // ⇒ 此处仍读视频级（方案链路的段级化属另一批，见计划「未闭合项」）。
            suppressVideoClone: video.voiceFollowsGlobal) {
            preferredVoiceID = choice.voiceID
            cloneVoiceID = video.clonedVoiceId
        } else {
            preferredVoiceID = nil
            cloneVoiceID = video.clonedVoiceId
        }
        return segment.effectiveDubVariants(
            preferredVoiceID: preferredVoiceID,
            videoCloneVoiceID: cloneVoiceID
        ).map {
            SlotVariantView(dubID: $0.id, variantIndex: $0.textVariantIndex, voiceID: $0.voiceId)
        }
    }

    /// 素材库检查器 R3 有效变体（legacy 链路；返回模型对象供既有台词/播放路径使用）。
    /// 关系读取全部封在 VM：preferred 取该视频解析结果（含跟随开关与项目覆盖），克隆取视频字段。
    func effectiveLegacyVariants(for segment: Segment, project: Project?) -> [SegmentDub] {
        guard let video = segment.video else { return [] }
        var preferredVoiceID: String?
        if case .resolved(let choice) = VoicePreferences.resolveForLegacy(
            video: video,
            projectOverrideRaw: project?.preferredVoiceChoiceRaw,
            suppressVideoClone: video.voiceFollowsGlobal,
            segment: segment) {
            preferredVoiceID = choice.voiceID
        }
        return segment.effectiveDubVariants(
            preferredVoiceID: preferredVoiceID,
            videoCloneVoiceID: segment.clonedVoiceId ?? video.clonedVoiceId)
    }

    /// 方案涉及的视频 id 集合（VM 内读关系；供忙碌/取消，视图不直接碰关系链）。
    private func scriptSchemeVideoIDs(_ scheme: MixScheme) -> Set<UUID> {
        Set(scheme.orderedSegments.compactMap { $0.segment?.video?.id })
    }

    /// 方案是否有配音作业在跑。
    func isScriptSchemeBusy(_ scheme: MixScheme) -> Bool {
        _ = jobsRevision
        return scriptSchemeVideoIDs(scheme).contains { isBusy(videoID: $0) }
    }

    /// 停止方案涉及的全部视频作业。
    func cancelScriptSchemeJobs(_ scheme: MixScheme) {
        for vid in scriptSchemeVideoIDs(scheme) {
            cancelJobs(for: vid, reason: .userStop)
        }
    }

    /// 单槽配音态（VM 读 segment/segmentDubs/video，视图只 switch 枚举）。
    /// M1b：project 必传——已生成音频还要与槽位生效音色比对（staleVoice）。
    func scriptSlotState(_ schemeSeg: SchemeSegment, project: Project?) -> ScriptSlotState {
        guard let segment = schemeSeg.segment else { return .missing }
        // 本槽 dub 正在合成为最高优先（不用随机 UUID 占位，缺 id 即不忙）。
        if let id = schemeSeg.selectedSegmentDubId, busyDubIDs.contains(id) { return .busy }
        if let id = schemeSeg.selectedSegmentDubId,
           let dub = segment.segmentDubs.first(where: { $0.id == id }) {
            if let path = dub.audioFilePath, FileManager.default.fileExists(atPath: path) {
                // 已有音频但音色已改选 → stale（先于 ready）；未配置音色时不判 stale（无法合成新音色，仍只展示已生成）。
                let resolvedID = resolvedScriptChoice(for: schemeSeg, project: project)?.voiceID
                if DubVariantSelector.isStale(boundVoiceID: dub.voiceId, resolvedVoiceID: resolvedID) {
                    return .staleVoice
                }
                return .ready
            }
            return .pending
        }
        return .missing
    }

    /// 一组分镜下「已有音频」的配音变体数（素材库视频行计数，排除空壳）。
    func readyDubCount(in segments: [Segment]) -> Int {
        segments.reduce(0) { $0 + $1.segmentDubs.filter { $0.audioFilePath != nil }.count }
    }

    /// 该分镜所属视频当前是否有配音作业；返回进度文案（空串=忙碌但无阶段文案，nil=不忙）。
    func videoDubProgress(for segment: Segment) -> String? {
        _ = jobsRevision
        guard let vid = segment.video?.id, isBusy(videoID: vid) else { return nil }
        return progressText(videoID: vid)
    }

    /// 未绑定的脚本成片配音空壳（provenance 脚本族 + 空音色 + 无音频）。
    func unboundScriptShells(in segment: Segment) -> [SegmentDub] {
        segment.segmentDubs.filter {
            ScriptDubReap.scriptProvenanceRaws.contains($0.textProvenanceRaw)
                && $0.voiceId.isEmpty
                && ($0.audioFilePath == nil)
        }
    }

    /// 该分镜是否「仅有脚本空壳、无任何真实变体」（检查器据此显示引导而非死路）。
    func hasOnlyUnboundScriptShells(_ segment: Segment) -> Bool {
        let shells = unboundScriptShells(in: segment)
        guard !shells.isEmpty else { return false }
        return segment.segmentDubs.allSatisfy { shells.contains($0) }
    }

    /// 实际存在的改写版下标（排除未绑定脚本空壳；检查器变体池唯一投影）。
    func presentVariantIndices(_ segment: Segment) -> [Int] {
        let shellIDs = Set(unboundScriptShells(in: segment).map(\.id))
        return Array(Set(segment.segmentDubs
            .filter { !shellIDs.contains($0.id) }
            .map(\.textVariantIndex))).sorted()
    }

    func scriptDubbingReadiness(for scheme: MixScheme) -> ScriptReadiness {
        var ready = 0, total = 0
        for ss in scheme.orderedSegments {
            total += 1
            if let id = ss.selectedSegmentDubId,
               let dub = ss.segment?.segmentDubs.first(where: { $0.id == id }),
               let path = dub.audioFilePath, FileManager.default.fileExists(atPath: path) {
                ready += 1
            }
        }
        return .init(ready: ready, total: total)
    }

    /// 整方案生成：视频内串行、跨视频最多 2 路（Core BoundedTaskGate）。
    /// 不调用 AI 改写、不克隆；每槽经 VoiceResolver（项目→全局）解析音色。
    /// - Returns: (成功数, 失败数, 逐段去重原因)
    @discardableResult
    func generateScriptDubs(for scheme: MixScheme, project: Project?,
                            context: ModelContext) async -> (ok: Int, fail: Int, errors: [String]) {
        let ordered = scheme.orderedSegments
        guard !ordered.isEmpty else { return (0, 0, []) }

        // M1b：音色按槽解析（段覆盖 → 项目/全局），不再整批只认一个 choice——
        // 允许方案内逐段不同音色；全槽都未配置时逐槽记同一失败原因，观感等同整批阻断。

        // 按视频分组（保持方案顺序）。
        var groups: [(videoID: UUID, slots: [SchemeSegment])] = []
        for ss in ordered {
            guard let seg = ss.segment, let vid = seg.video?.id else { continue }
            if let idx = groups.firstIndex(where: { $0.videoID == vid }) {
                groups[idx].slots.append(ss)
            } else {
                groups.append((vid, [ss]))
            }
        }

        let gate = BoundedTaskGate(maxConcurrent: 2)
        var ok = 0, fail = 0
        var errors: [String] = []
        // 跨组结果归并用串行队列（actor 内安全）。
        await withTaskGroup(of: (Int, Int, [String]).self) { group in
            for (vid, slots) in groups {
                group.addTask { [weak self] in
                    do {
                        return try await gate.run { () -> (Int, Int, [String]) in
                            guard let self else { return (0, slots.count, ["配音服务不可用"]) }
                            return await self.generateScriptSlots(
                                slots, scheme: scheme, project: project,
                                videoID: vid, context: context)
                        }
                    } catch {
                        return (0, slots.count, ["已取消"])
                    }
                }
            }
            for await (o, f, es) in group {
                ok += o; fail += f
                for e in es where !errors.contains(e) { errors.append(e) }
            }
        }
        MixLog.info("[ScriptDub] 方案配音生成完成 ok=\(ok) fail=\(fail)")
        return (ok, fail, errors)
    }

    /// 单卡生成（一个槽位）。返回是否成功；失败原因写 lastDubErrors/errorState。
    @discardableResult
    func generateScriptDub(for schemeSeg: SchemeSegment, scheme: MixScheme,
                           project: Project?, context: ModelContext,
                           forceRegenerate: Bool = false) async -> Bool {
        guard let seg = schemeSeg.segment, let vid = seg.video?.id else { return false }
        let (ok, _, errors) = await generateScriptSlots(
            [schemeSeg], scheme: scheme, project: project, videoID: vid,
            context: context, forceRegenerate: forceRegenerate)
        if ok == 0, let e = errors.first {
            errorState = .init(message: e, kind: .generic)
        }
        return ok == 1
    }

    /// 同一视频内逐槽串行合成（调用方负责并发闸）。M1b：每槽按段覆盖→项目/全局解析音色。
    private func generateScriptSlots(_ slots: [SchemeSegment], scheme: MixScheme,
                                     project: Project?, videoID: UUID,
                                     context: ModelContext,
                                     forceRegenerate: Bool = false) async -> (Int, Int, [String]) {
        var ok = 0, fail = 0
        var errors: [String] = []
        let total = slots.count
        for (i, ss) in slots.enumerated() {
            if Task.isCancelled {
                errors.append("已停止")
                break
            }
            // 段覆盖 → 项目/全局（与展示投影同一函数）；本槽未配置音色则跳过合成、结构化报错。
            guard let choice = resolvedScriptChoice(for: ss, project: project) else {
                fail += 1
                let reason = "第 \(ss.position) 段：尚未配置配音音色，请到「设置 → 配音」选择或在本段菜单指定音色"
                if !errors.contains(reason) { errors.append(reason) }
                continue
            }
            setStage(videoID, .synthesize, "合成脚本配音 \(i + 1)/\(total)…",
                     fraction: Double(i) / Double(max(1, total)))
            let result = await bindAndSynthesize(ss, scheme: scheme, choice: choice,
                                                 context: context, forceRegenerate: forceRegenerate)
            switch result {
            case .success:
                ok += 1
            case .failure(let reason):
                fail += 1
                if !errors.contains(reason) { errors.append(reason) }
            }
        }
        setProgress(videoID, "")
        try? context.save()
        return (ok, fail, errors)
    }

    private enum SlotResult { case success, failure(String) }

    /// 单槽：Core ScriptDubBinding 四分支落 SwiftData → generateAudio（不改文案、不克隆）。
    private func bindAndSynthesize(_ ss: SchemeSegment, scheme: MixScheme,
                                   choice: VoiceChoice, context: ModelContext,
                                   forceRegenerate: Bool = false) async -> SlotResult {
        guard let segment = ss.segment, segment.video != nil else {
            return .failure("第 \(ss.position) 段：分镜数据缺失")
        }
        let existing = segment.segmentDubs.map {
            ExistingDub(dubID: $0.id, variantIndex: $0.textVariantIndex,
                        voiceID: $0.voiceId, text: $0.rewrittenText,
                        hasAudio: $0.audioFilePath != nil)
        }
        let shellID = ss.selectedSegmentDubId
        let shell = existing.first { $0.dubID == shellID }
        // 文案真源：壳的脚本台词；壳缺失则从冻结 ScriptScene 反查（防御分支，清理豁免后罕见）。
        let scriptText: String = {
            if let shell, !shell.text.isEmpty { return shell.text }
            return scriptSceneText(for: segment, scheme: scheme, context: context)
        }()
        guard !scriptText.isEmpty else { return .failure("第 \(ss.position) 段：脚本台词为空") }

        let outcome = ScriptDubBinding.resolve(
            shellDubID: shellID, shellIndex: shell?.variantIndex,
            shellText: scriptText, existing: existing, voiceID: choice.voiceID)

        let targetDub: SegmentDub
        switch outcome {
        case .reuseExisting(let reusableID, let shellToDelete, _, _):
            guard let reusable = segment.segmentDubs.first(where: { $0.id == reusableID }) else {
                return .failure("第 \(ss.position) 段：可复用配音已不存在")
            }
            if let sid = shellToDelete, sid != reusableID,
               let shellModel = segment.segmentDubs.first(where: { $0.id == sid }) {
                context.delete(shellModel)
            }
            ss.selectedSegmentDubId = reusableID
            targetDub = reusable
        case .relocate(let sid, let newIndex, let voiceID):
            guard let shellModel = segment.segmentDubs.first(where: { $0.id == sid }) else {
                return .failure("第 \(ss.position) 段：配音载体缺失")
            }
            shellModel.textVariantIndex = newIndex
            shellModel.voiceId = voiceID
            targetDub = shellModel
        case .bindInPlace(let sid, let voiceID):
            guard let shellModel = segment.segmentDubs.first(where: { $0.id == sid }) else {
                return .failure("第 \(ss.position) 段：配音载体缺失")
            }
            shellModel.voiceId = voiceID
            targetDub = shellModel
        case .createNew(let index, let voiceID):
            let dub = SegmentDub(segment: segment, voiceId: voiceID,
                                 voiceProvider: "cosyvoice",
                                 textVariantIndex: index, rewrittenText: scriptText)
            // 继承脚本来源（供删除归属 Reap 判定）；反查不到方向时按正向 AI 新撰记录。
            dub.setProvenance(scriptDirection(for: segment, scheme: scheme, context: context))
            context.insert(dub)
            segment.segmentDubs.append(dub)
            ss.selectedSegmentDubId = dub.id
            targetDub = dub
        }
        try? context.save()

        // 已有音频直接视为成功，不重复合成、不重复计费；forceRegenerate（单卡重生成）除外。
        if !forceRegenerate,
           let path = targetDub.audioFilePath, FileManager.default.fileExists(atPath: path) {
            return .success
        }
        let startedOK = await generateAudio(for: targetDub, context: context,
                                            silent: true, resolvedChoice: choice)
        return startedOK ? .success : .failure(
            lastDubErrors[targetDub.id] ?? "第 \(ss.position) 段：配音合成失败")
    }

    /// 经活 fetch + 标识符解边反查槽位脚本台词（VM 内允许，视图层禁止）。
    private func scriptSceneText(for segment: Segment, scheme: MixScheme,
                                 context: ModelContext) -> String {
        let scenes = (try? context.fetch(FetchDescriptor<ScriptScene>())) ?? []
        let docs = (try? context.fetch(FetchDescriptor<ScriptDocument>())) ?? []
        return scenes.first { scene in
            scene.matchedSegment?.id == segment.id
                && docs.contains { $0.id == scene.script?.id && $0.realizedScheme?.id == scheme.id }
        }?.text ?? ""
    }

    private func scriptDirection(for segment: Segment, scheme: MixScheme,
                                 context: ModelContext) -> TranscriptSource {
        let docs = (try? context.fetch(FetchDescriptor<ScriptDocument>())) ?? []
        let scenes = (try? context.fetch(FetchDescriptor<ScriptScene>())) ?? []
        let isReverse = scenes.contains { scene in
            scene.matchedSegment?.id == segment.id
                && docs.contains { $0.id == scene.script?.id && $0.realizedScheme?.id == scheme.id
                    && $0.direction == .reverse }
        }
        return isReverse ? .userScriptReverse : .productScript
    }
}
