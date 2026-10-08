import Foundation
import AVFoundation

// ============================================================================
// 音色试听播放：进程级共享单例。
//
// 为什么独立成服务而不是挂在 DubbingViewModel：
//   试听是「合成一句固定样音并播放」的短交互，调用点跨场景（设置页 / 未来 M1b 音色选择器），
//   且播放器必须活到播完（AVAudioPlayer.play() 仅启动异步播放，需强引用持有几秒）。
//   若像早期实现那样在设置页 `let vm = DubbingViewModel()` 造临时对象，闭包结束即释放 vm，
//   播放器随 vm 回收，表现为「点试听没反应」。单例天然存活到样音放完，也保证一次只播一个。
//
// ## 边界（M2 修正）
//
// M1a 的注释写「仅 CosyVoice 预置音色；克隆音色不在此试听，故不复制引擎路由」——
// **这个前提已经不成立了**：M2 加了账号级复刻音色后，试听按钮照样暴露给了它，
// 于是预置音色能试听、复刻音色必然失败（客户端固定 CosyVoice）。
// 实测症状：点试听报「克隆音色在当前 API Key 下不可用」，而日志显示同一 Key 下
// 预置音色合成成功（`longanrou-v0.m4a`）⇒ 那个归因本身就是错的。
//
// 现在：`play(_ choice:)` 按 `choice.engine` 路由，与 `DubbingViewModel.synthesisClient(for:)`
// **同一套判据**（不重写第二份路由）。`playPreset(_ voiceID:)` 保留但降级为
// 「显式报错」而不是静默用错客户端。
// ============================================================================

@MainActor
@Observable
final class VoiceAuditionPlayer {
    static let shared = VoiceAuditionPlayer()

    /// 试听固定短句（设置页/选择器统一，便于跨音色横向比较）。
    private static let auditionText = "这款产品真的很好用，喜欢的话点击下方链接了解一下吧。"

    private var player: AVAudioPlayer?

    /// 当前是否在合成/播放样音（驱动按钮忙碌态）。
    private(set) var isAuditioning = false
    /// M1b：当前正在试听的音色 id（行级忙碌态：选择器列表据此只让对应行显示进度/停止）。
    /// nil = 当前无试听。与 isAuditioning 同生同灭。
    private(set) var auditioningVoiceID: String?
    /// 最近一次失败原因（成功/新一轮开始时清空）。
    private(set) var lastError: String?

    /// 预置音色（CosyVoice）的客户端。复刻/克隆音色走`play(_:)` 里按型号现建的客户端。
    private let presetClient: TTSClient

    /// 依赖注入点：测试与未来定制用。默认即CosyVoice 预置客户端。
    init(presetClient: TTSClient = CosyVoiceTTSClient()) {
        self.presetClient = presetClient
    }

    /// 按音色身份选客户端（与 `DubbingViewModel.synthesisClient(for:)` 同一判据）。
    ///
    /// ⚠️ **不复用共享实例**：qwen 系音色各自绑定自己的注册型号
    /// （`VoiceCloneService.targetModel` 或复刻音色自己的 model），
    /// 而客户端的 model 在 init 时固定 ⇒ 用错型号服务端会报 InvalidParameter。
    private func client(for choice: VoiceChoice) -> TTSClient {
        switch choice.engine {
        case .cosyVoice:
            return presetClient
        case .qwenVC:
            if case .globalClone(_, _, let model) = choice, !model.isEmpty,
               model != VoiceCloneService.targetModel {
                return QwenTTSClient(model: model)
            }
            return QwenTTSClient(model: VoiceCloneService.targetModel)
        }
    }

    /// 播放一个 CosyVoice 预置音色的样音（同一时刻只保留最新一次）。
    /// 试听一个**已知身份**的音色（正确入口）。
    ///
    /// - Parameter choice: 携带引擎与型号的身份。缺了它播放器无从判断该用哪个客户端，
    ///   这正是 M2 试听失败的根因。
    func play(_ choice: VoiceChoice) {
        let voiceID = choice.voiceID
        guard !voiceID.isEmpty else {
            lastError = "未选择音色"
            return
        }
        stop()
        isAuditioning = true
        auditioningVoiceID = voiceID
        lastError = nil
        let cli = client(for: choice)
        Task { @MainActor in
            do {
                let result = try await cli.synthesize(
                    text: Self.auditionText, voiceId: voiceID,
                    languageType: "Chinese", rate: 1.0)
                let newPlayer = try AVAudioPlayer(
                    contentsOf: URL(fileURLWithPath: result.wavPath))
                // 旧样音停掉、换成新的；单例持有到播完。
                player?.stop()
                player = newPlayer
                newPlayer.prepareToPlay()
                let started = newPlayer.play()
                isAuditioning = false
                auditioningVoiceID = nil
                if !started {
                    lastError = "样音已合成但无法开始播放，请检查系统音频输出"
                }
            } catch {
                isAuditioning = false
                auditioningVoiceID = nil
                lastError = "试听失败：\(DubbingViewModel.friendlyError(error))"
                // ⚠️ 留证（此前**完全没有**）：试听失败只在界面显示一次，
                // 日志与 ai-fail 目录都没有 ⇒ 失败后**无从查起**。
                // 实测踩坑：正因为这里不留痕，「克隆音色在当前 Key 下不可用」
                // 这个误报一直查不到真实错误是什么。
                MixLog.error("[Audition] 试听失败 voice=\(voiceID) engine=\(choice.engine) "
                             + "error=\(error.localizedDescription)")
            }
        }
    }

    /// 只拿到裸 voiceId 时的**降级**入口。
    ///
    /// ⚠️ **不再静默用 CosyVoice 客户端**——那会让克隆/复刻音色必然失败，
    /// 且失败文案还会被误诊成「克隆音色 Key 失效」（预置音色不存在这个概念）。
    /// 保留它只为让漏改的调用点**响亮失败**，而不是继续产出错误归因。
    func playPreset(_ voiceID: String) {
        guard !voiceID.isEmpty else {
            lastError = "未选择音色"
            return
        }
        lastError = "该音色缺少引擎/型号信息，无法试听。请改用 play(_ choice:) 传入音色身份。"
        MixLog.error("[Audition] playPreset(\(voiceID)) 缺音色身份，已拒绝试听")
    }

    /// 停止当前样音并释放播放器（不影响分镜/方案的成片配音播放）。
    func stop() {
        player?.stop()
        player = nil
        isAuditioning = false
        auditioningVoiceID = nil
    }
}
