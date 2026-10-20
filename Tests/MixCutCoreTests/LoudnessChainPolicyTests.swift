import Testing
@testable import MixCutCore

// ============================================================================
// LC · `LoudnessChainPolicy` —— 「这段音频能不能喂 loudnorm」的唯一判据
//
// ## 为什么这组测试存在
//
// 2026-10-20 沿产品链路实测：包内 ffmpeg 8.1 的 `loudnorm` 在**纯数字静音 + 时长不足
// 测量窗**时吐 NaN，aac 编码器拒收 ⇒ 整条导出 `rc=234`，屏上只有「视频处理失败（错误码
// 234）」。而这条规则此前在仓库里一个字都没有 —— 它藏在 ffmpeg 的行为里，
// 只能靠"某个方案莫名其妙导不出来"的形式反复出现。
//
// 真产品可达形态（已复现，见 `MixCutAppTests/ExportDurationGateTests.swift` 末两条）：
// **1s 静音分镜 + 4s 有声分镜 = 总时长 5s**，过千川 4s 时长闸、画布也合规，
// 却因为那一条短分镜整条渲染死掉 —— 中毒单位是分镜，不是成片。
//
// ## 判别式设计（防「假绿」）
//
// - 断言打在**实测分界数字**（2.9 红 / 3.0 绿）上，不是打在常量本身上：
//   把 `measurementWindowSeconds` 从 3.0 改成别的值，边界用例必须红。
// - 每条"该绕开"的判据都配一条"不该绕开"的对照腿：
//   ≥窗口的静音**必须仍然走 loudnorm** —— 否则这次改动会把今天能导的长片一起改道，
//   那才是真正的回归面（改动面必须严格等于"今天必然失败的那些"）。
// - `needsSilenceProbe` 与 `mustBypassLoudnorm` 共享同一个窗口常量：
//   单独测每一个都可能绿得毫无意义，所以有一条把两者绑起来的不变量。
// ============================================================================

@Suite("LC · loudnorm 可用边界")
struct LoudnessChainPolicyTests {

    @Test("实测分界：纯静音在 2.9s 必须绕开、在 3.0s 必须照走（同一条链只差时长）",
          arguments: [
            // (秒, 期望是否绕开 loudnorm)
            (2.9, true), (2.5, true), (1.0, true), (3.0, false), (3.1, false), (6.0, false),
          ])
    func boundaryOnMeasuredNumbers(_ input: (Double, Bool)) {
        let bypass = LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: input.0,
                                                            isPureDigitalSilence: true)
        #expect(bypass == input.1,
                "\(input.0)s 的纯静音：期望绕开=\(input.1)，实得绕开=\(bypass)")
    }

    @Test("有电平的音频一律不绕开 —— 再短也照走 loudnorm（实测 1.0s 440Hz 正常）")
    func audibleAudioIsNeverRerouted() {
        for seconds in [0.0, 0.3, 1.0, 2.5, 2.9, 3.0, 10.0] {
            #expect(!LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: seconds,
                                                            isPureDigitalSilence: false),
                    "\(seconds)s 的有声分镜被改道了 ⇒ 这次改动动了今天能导的片子")
        }
    }

    @Test("近静音不等于静音：−81dB 级实测能导，所以判据不许用「够安静」")
    func nearSilenceIsNotSilence() {
        // 这条锁的是**调用方**的取值口径（astats 只有 -inf 才判真），
        // 判据函数本身只认布尔，所以这里断言的是"传进来 false 就不许绕开"。
        #expect(!LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: 2.5,
                                                       isPureDigitalSilence: false))
        #expect(LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: 2.5,
                                                      isPureDigitalSilence: true))
    }

    @Test("不变量：达到测量窗 ⇒ 无论静音与否都不绕开（把两个函数绑在同一条窗口规则上）")
    func windowIsTheOnlyGate() {
        for seconds in [LoudnessChainPolicy.measurementWindowSeconds,
                        LoudnessChainPolicy.measurementWindowSeconds + 0.001,
                        300.0] {
            #expect(!LoudnessChainPolicy.needsSilenceProbe(durationSeconds: seconds),
                    "\(seconds)s 不该花这次探测")
            #expect(!LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: seconds,
                                                           isPureDigitalSilence: true),
                    "\(seconds)s 却绕开了 loudnorm ⇒ 窗口规则被抄成了两份或改动了作用面")
        }
    }

    @Test("零长/负长音频：按短段处理（0 长度本来就没什么可归一）")
    func degenerateDurations() {
        #expect(LoudnessChainPolicy.needsSilenceProbe(durationSeconds: 0))
        #expect(LoudnessChainPolicy.needsSilenceProbe(durationSeconds: -1))
        #expect(LoudnessChainPolicy.mustBypassLoudnorm(durationSeconds: 0,
                                                      isPureDigitalSilence: true))
    }

    @Test("窗口就是实测那个 3s（R128 短时窗）：改常量必须连带改这里的证据")
    func windowValueIsTheMeasuredOne() {
        #expect(LoudnessChainPolicy.measurementWindowSeconds == 3.0,
                "实测分界在 2.9 与 3.0 之间；要动这个数，先重跑产品链路那条分界")
    }
}
