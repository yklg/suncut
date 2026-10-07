import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// M2 复刻音色库：样本校验 / Key 指纹失效 / 删除口径 / 命名清洗
//
// 本轮最关键的改动是 VP 系列：`globalClone.engine` 从「一律 cosyVoice」
// 改为「由 model 决定」。那个硬编码是「M2 必定走 CosyVoice 复刻」假设下的写法，
// 实际选了 Qwen 路线后会把 qwen 音色送进 CosyVoice 客户端 —— 类型层看不出、
// 只在真机合成时才报InvalidParameter。这组用例把该判据钉死。
// ============================================================================

// MARK: - VP: 复刻音色的引擎由型号决定（M2 架构改动）

@Test("VP-1 预置音色走 CosyVoice")
func vp1_presetIsCosyVoice() {
    #expect(VoiceChoice.preset(voiceID: "longyingxiao").engine == .cosyVoice)
}

@Test("VP-2 存量视频克隆走 qwen-vc")
func vp2_videoCloneIsQwenVC() {
    #expect(VoiceChoice.videoClone(voiceID: "cosyvoice-vc-xxx").engine == .qwenVC)
}

@Test("VP-3 账号级复刻音色：qwen 型号 ⇒ qwen-vc（M2 选定路线）")
func vp3_globalCloneQwenModelIsQwenVC() {
    let choice = VoiceChoice.globalClone(profileID: UUID(),
                                        voiceID: "myvoice",
                                        model: "qwen3-tts-vc-2026-01-22")
    #expect(choice.engine == .qwenVC, "qwen 型号必须走 qwen-vc，否则会用 CosyVoice 客户端请求 qwen 音色")
    #expect(choice.cosyVoiceModel == nil, "qwen 系不应有 CosyVoice 型号")
}

@Test("VP-4 账号级复刻音色：cosyvoice 型号 ⇒ CosyVoice（未来切回路线也不用改代码）")
func vp4_globalCloneCosyModelIsCosyVoice() {
    let choice = VoiceChoice.globalClone(profileID: UUID(),
                                        voiceID: "cosyvoice-v3-plus-abc-xxx",
                                        model: "cosyvoice-v3-plus")
    #expect(choice.engine == .cosyVoice)
    #expect(choice.cosyVoiceModel == "cosyvoice-v3-plus")
}

@Test("VP-5 型号家族判定覆盖 qwen-audio-* 与大小写")
func vp5_qwenFamilyDetection() {
    #expect(VoiceChoice.isQwenFamily("qwen3-tts-vc-realtime-2026-01-15"))
    #expect(VoiceChoice.isQwenFamily("QWEN3-TTS-VC"))
    #expect(VoiceChoice.isQwenFamily("qwen-audio-3.0-tts-flash"))
    #expect(!VoiceChoice.isQwenFamily("cosyvoice-v3-plus"))
    #expect(!VoiceChoice.isQwenFamily("cosyvoice-v2"))
    #expect(!VoiceChoice.isQwenFamily(""))
}

@Test("VP-6 引擎随型号变 ⇒ 同一音色身份可承载两条复刻路线（解码往返不丢型号）")
func vp6_engineFollowsModelThroughCodec() {
    for model in ["qwen3-tts-vc-2026-01-22", "cosyvoice-v3-plus"] {
        let choice = VoiceChoice.globalClone(profileID: UUID(), voiceID: "v", model: model)
        let raw = VoiceChoiceCoder.encode(choice)
        let decoded = VoiceChoiceCoder.decode(raw)
        #expect(decoded == choice)
        #expect(decoded?.engine == choice.engine, "型号 \(model) 经编解码往返后引擎必须不变")
    }
}

// MARK: -CV: 样本校验

@Test("CV-1 合规样本通过（12s / 2MB）")
func cv1_validSamplePasses() {
    #expect(CloneSampleValidator.validate(
        durationSeconds: CloneSampleValidator.acceptableDurationSeconds,
        byteSize: CloneSampleValidator.acceptableByteSize) == .ok)
    #expect(CloneSampleValidator.message(for: .ok) == nil, "通过时不应有任何提示文案")
}

@Test("CV-2 太短被拒（9.9s）")
func cv2_tooShortRejected() {
    let v = CloneSampleValidator.validate(durationSeconds: 9.9, byteSize: 1024)
    #expect(v == .tooShort(seconds: 9.9))
    #expect(CloneSampleValidator.message(for: v)?.contains("太短") == true)
}

@Test("CV-3 过长被拒（20.1s）")
func cv3_tooLongRejected() {
    let v = CloneSampleValidator.validate(durationSeconds: 20.1, byteSize: 1024)
    #expect(v == .tooLong(seconds: 20.1))
}

@Test("CV-4 时长边界：恰好 10s 与 20s 都通过（闭区间）")
func cv4_durationBoundariesInclusive() {
    #expect(CloneSampleValidator.validate(durationSeconds: 10.0, byteSize: 1024) == .ok)
    #expect(CloneSampleValidator.validate(durationSeconds: 20.0, byteSize: 1024) == .ok)
}

@Test("CV-5 超过体积上限被拒（10MB + 1 字节）")
func cv5_tooLargeRejected() {
    let v = CloneSampleValidator.validate(durationSeconds: 12,
                                         byteSize: CloneSampleValidator.maxBytes + 1)
    guard case .tooLarge(let mb) = v else {
        Issue.record("应为 tooLarge，实际 \(v)")
        return
    }
    // 不写 == 10.0：`(maxBytes+1)/(1024*1024)` 是 10.00000095，浮点精确相等必然失败。
    #expect(abs(mb - 10.0) < 0.001)
}

@Test("CV-6 体积边界：恰好 10MB 通过")
func cv6_sizeBoundaryInclusive() {
    #expect(CloneSampleValidator.validate(durationSeconds: 12,
                                        byteSize: CloneSampleValidator.maxBytes) == .ok)
}

@Test("CV-7 空文件先被拒（不落到时长判定，避免 0 秒报「太短」）")
func cv7_emptyFileFirst() {
    #expect(CloneSampleValidator.validate(durationSeconds: 0, byteSize: 0) == .emptyFile)
    #expect(CloneSampleValidator.validate(durationSeconds: 12, byteSize: 0) == .emptyFile)
}

@Test("CV-8 时长优先于体积（两个都不合格时先报时长——用户先修更根本的那个）")
func cv8_durationWinsOverSize() {
    let v = CloneSampleValidator.validate(durationSeconds: 5,
                                         byteSize: CloneSampleValidator.maxBytes + 1)
    #expect(v == .tooShort(seconds: 5))
}

@Test("CV-9 每种 verdict 都有可读文案（UI 不必自己拼）")
func cv9_allVerdictsHaveMessage() {
    let verdicts: [CloneSampleValidator.Verdict] = [
        .ok, .emptyFile, .tooShort(seconds: 3), .tooLong(seconds: 60), .tooLarge(megabytes: 20),
    ]
    for v in verdicts where v != .ok {
        #expect(CloneSampleValidator.message(for: v)?.isEmpty == false,
                "verdict \(v) 缺文案")
    }
}

// MARK: - KV: Key 指纹失效

@Test("KV-1 指纹不匹配 ⇒ 置灰")
func kv1_mismatchInvalidates() {
    #expect(VoiceProfileValidity.isInvalidated(profileKeyFingerprint: "abcd",
                                             currentFingerprint: "wxyz"))
}

@Test("KV-2 指纹匹配 ⇒ 有效")
func kv2_matchIsValid() {
    #expect(!VoiceProfileValidity.isInvalidated(profileKeyFingerprint: "abcd",
                                             currentFingerprint: "abcd"))
}

@Test("KV-3 当前无 Key ⇒ 不置灰（那是「未配置」引导问题，不是音色失效）")
func kv3_noCurrentKeyNotInvalidated() {
    #expect(!VoiceProfileValidity.isInvalidated(profileKeyFingerprint: "abcd",
                                             currentFingerprint: nil))
    #expect(!VoiceProfileValidity.isInvalidated(profileKeyFingerprint: "abcd",
                                             currentFingerprint: ""))
}

@Test("KV-4 存量音色无指纹 ⇒ 乐观复用（存量零行为变化，与逐视频克隆同口径）")
func kv4_nilFingerprintReused() {
    #expect(!VoiceProfileValidity.isInvalidated(profileKeyFingerprint: nil,
                                             currentFingerprint: "wxyz"))
    #expect(!VoiceProfileValidity.isInvalidated(profileKeyFingerprint: "",
                                             currentFingerprint: "wxyz"))
}

@Test("KV-5 置灰文案同时给出两条出路（用原 Key / 删了重注册）")
func kv5_messageOffersBothWaysOut() {
    let msg = VoiceProfileValidity.invalidatedMessage()
    #expect(msg.contains("另一个 API Key"))
    #expect(msg.contains("重新注册"), "文案必须告诉用户怎么恢复，不能只说「不可用」")
}

// MARK: - CD: 删除口径

@Test("CD-1 两种删除口径都必须保留已生成音频（删音色绝不能毁掉用户成片）")
func cd1_deletionNeverDestroysAudio() {
    for scope in CloneProfileDeletion.Scope.allCases {
        #expect(CloneProfileDeletion.keepsExistingAudio(scope),
                "口径 \(scope.rawValue) 竟许诺毁掉已生成音频")
    }
}

@Test("CD-2 两种口径都有 label 与 detail（UI 不必自己写文案）")
func cd2_bothScopesHaveCopy() {
    let labels = CloneProfileDeletion.Scope.allCases.map(\.label)
    #expect(labels.count == 2)
    #expect(Set(labels).count == 2, "两个口径的文案必须不同")
    for scope in CloneProfileDeletion.Scope.allCases {
        #expect(!scope.detail.isEmpty, "口径 \(scope.rawValue) 缺 detail")
        #expect(scope.detail.contains("保留"), "detail 须明确说明已生成音频会保留")
    }
}

@Test("CD-3 注销远端的口径必须提到配额（用户据此判断要不要多花一次注册）")
func cd3_revokeScopeMentionsQuota() {
    #expect(CloneProfileDeletion.Scope.alsoRevokeRemote.detail.contains("配额"))
}

// MARK: - NV: 命名清洗

@Test("NV-1 中文名清洗成空 ⇒ 回落品牌默认名（服务端不允许空名）")
func nv1_chineseFallsBackToBrand() {
    let cleaned = CloneVoiceNaming.sanitizeForProvider("我的声音", maxLength: 16)
    #expect(cleaned == Brand.voiceAliasFallback)
}

@Test("NV-2 混合名只保留 ASCII 字母数字并截断到上限")
func nv2_mixedNameSanitized() {
    let cleaned = CloneVoiceNaming.sanitizeForProvider("My Voice 2024", maxLength: 10)
    #expect(cleaned == "myvoice202")
    #expect(cleaned.count <= 10)
}

@Test("NV-3 上限为 0 时至少留 1 个字符（不产生空名）")
func nv3_zeroMaxStillYieldsName() {
    let cleaned = CloneVoiceNaming.sanitizeForProvider("abc", maxLength: 0)
    #expect(!cleaned.isEmpty)
}

@Test("NV-4 两个协议的字符上限常量齐备且符合文档（Qwen 16 / CosyVoice 10）")
func nv4_providerLimitsMatchDoc() {
    #expect(CloneVoiceNaming.ProviderLimit.qwenPreferredName == 16)
    #expect(CloneVoiceNaming.ProviderLimit.cosyVoicePrefix == 10)
}