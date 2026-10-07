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
// 边界（M1a）：仅 CosyVoice 预置音色；视频克隆（qwen-vc）/全局复刻（M2）不在此试听，
//   故不复制 DubbingViewModel 的引擎路由。M2 复刻型号不同时扩 playPreset(_:model:)。
// ============================================================================

@MainActor
@Observable
final class VoiceAuditionPlayer {
    static let shared = VoiceAuditionPlayer()

    /// 试听固定短句（设置页/选择器统一，便于跨音色横向比较）。
    private static let auditionText = "这款产品真的很好用，喜欢的话点击下方链接了解一下吧。"

    private let client: TTSClient
    private var player: AVAudioPlayer?

    /// 当前是否在合成/播放样音（驱动按钮忙碌态）。
    private(set) var isAuditioning = false
    /// M1b：当前正在试听的音色 id（行级忙碌态：选择器列表据此只让对应行显示进度/停止）。
    /// nil = 当前无试听。与 isAuditioning 同生同灭。
    private(set) var auditioningVoiceID: String?
    /// 最近一次失败原因（成功/新一轮开始时清空）。
    private(set) var lastError: String?

    private init(client: TTSClient = CosyVoiceTTSClient()) {
        self.client = client
    }

    /// 播放一个 CosyVoice 预置音色的样音（同一时刻只保留最新一次）。
    func playPreset(_ voiceID: String) {
        guard !voiceID.isEmpty else {
            lastError = "未选择音色"
            return
        }
        stop()
        isAuditioning = true
        auditioningVoiceID = voiceID
        lastError = nil
        Task { @MainActor in
            do {
                let result = try await client.synthesize(
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
            }
        }
    }

    /// 停止当前样音并释放播放器（不影响分镜/方案的成片配音播放）。
    func stop() {
        player?.stop()
        player = nil
        isAuditioning = false
        auditioningVoiceID = nil
    }
}
