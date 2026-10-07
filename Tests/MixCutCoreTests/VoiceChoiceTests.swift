import Foundation
import Testing
@testable import MixCutCore

/// VoiceChoice 持久化编解码（VC-1…5）+ 双工作流解析真值表（VR-1…12）+ 合成门。
///
/// 钉死的契约：
/// - 坏串/未知版本/类型漂移一律解 nil（= 未配置），绝不 crash、绝不猜音色；
/// - 素材库链路：视频克隆在且未显式跟随全局时优先；脚本链路：永不回退视频克隆；
/// - 级联：项目覆盖 > 全局默认，坏串不阻断继续向下回落。
struct VoiceChoiceTests {

    // MARK: VC：编解码

    @Test("VC-1 三类 choice 往返相等")
    func roundTripAllCases() {
        let profileID = UUID()
        let cases: [VoiceChoice] = [
            .preset(voiceID: "longyingxiao"),
            .globalClone(profileID: profileID, voiceID: "clone-abc", model: "cosyvoice-v2"),
            .videoClone(voiceID: "vc-123"),
        ]
        for c in cases {
            let str = VoiceChoiceCoder.encode(c)
            #expect(VoiceChoiceCoder.decode(str) == c)
        }
    }

    @Test("VC-2 编码串必须携带版本字段 v=1")
    func encodedCarriesVersion() {
        let str = VoiceChoiceCoder.encode(.preset(voiceID: "longxiaochun_v2"))
        #expect(str.contains("\"v\":1"))
    }

    @Test("VC-3 缺失/非法/未来版本号 → nil")
    func rejectsBadVersion() {
        #expect(VoiceChoiceCoder.decode("{\"v\":2,\"kind\":\"preset\",\"voice_id\":\"x\"}") == nil)
        #expect(VoiceChoiceCoder.decode("{\"kind\":\"preset\",\"voice_id\":\"x\"}") == nil)
        #expect(VoiceChoiceCoder.decode("{\"v\":\"1\",\"kind\":\"preset\",\"voice_id\":\"x\"}") == nil)
    }

    @Test("VC-4 截断/非法 JSON/类型漂移 → nil，不崩")
    func rejectsMalformed() {
        #expect(VoiceChoiceCoder.decode(nil) == nil)
        #expect(VoiceChoiceCoder.decode("") == nil)
        #expect(VoiceChoiceCoder.decode("not json") == nil)
        #expect(VoiceChoiceCoder.decode("{") == nil)
        #expect(VoiceChoiceCoder.decode("[]") == nil)
        #expect(VoiceChoiceCoder.decode("123") == nil)
        #expect(VoiceChoiceCoder.decode("{\"v\":1}") == nil)
        #expect(VoiceChoiceCoder.decode("{\"v\":1,\"kind\":\"unknown\",\"voice_id\":\"x\"}") == nil)
    }

    @Test("VC-5 关键字段缺失或空串 → nil")
    func rejectsMissingFields() {
        #expect(VoiceChoiceCoder.decode("{\"v\":1,\"kind\":\"preset\"}") == nil)
        #expect(VoiceChoiceCoder.decode("{\"v\":1,\"kind\":\"preset\",\"voice_id\":\"\"}") == nil)
        #expect(VoiceChoiceCoder.decode("{\"v\":1,\"kind\":\"preset\",\"voice_id\":\"   \"}") == nil)
        #expect(VoiceChoiceCoder.decode(
            "{\"v\":1,\"kind\":\"globalClone\",\"profile_id\":\"bad-uuid\",\"voice_id\":\"v\",\"model\":\"m\"}") == nil)
        #expect(VoiceChoiceCoder.decode(
            "{\"v\":1,\"kind\":\"globalClone\",\"profile_id\":\"\(UUID().uuidString)\",\"voice_id\":\"v\"}") == nil)
        #expect(VoiceChoiceCoder.decode(
            "{\"v\":1,\"kind\":\"globalClone\",\"profile_id\":\"\(UUID().uuidString)\",\"voice_id\":\"v\",\"model\":\"\"}") == nil)
    }

    // MARK: VR：素材库链路（legacy）

    @Test("VR-LR1 视频有克隆、无任何配置 → 视频克隆优先")
    func legacyCloneWinsWhenNothingConfigured() {
        let r = VoiceResolver.resolveForLegacyDub(.init(videoCloneVoiceID: "vc1"))
        #expect(r == .resolved(.videoClone(voiceID: "vc1")))
    }

    @Test("VR-LR2 克隆+全局并存且未手动跟随 → 仍克隆优先（存量零变化）")
    func legacyCloneBeatsGlobalByDefault() {
        let r = VoiceResolver.resolveForLegacyDub(.init(
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "p1")),
            videoCloneVoiceID: "vc1"))
        #expect(r == .resolved(.videoClone(voiceID: "vc1")))
    }

    @Test("VR-LR3 手动跟随全局 → 克隆被压制，走全局")
    func legacySuppressCloneUsesGlobal() {
        let r = VoiceResolver.resolveForLegacyDub(.init(
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "p1")),
            videoCloneVoiceID: "vc1",
            suppressVideoClone: true))
        #expect(r == .resolved(.preset(voiceID: "p1")))
    }

    @Test("VR-LR4 项目覆盖 > 全局默认（压制克隆时）")
    func legacyProjectBeatsGlobal() {
        let r = VoiceResolver.resolveForLegacyDub(.init(
            projectOverrideRaw: VoiceChoiceCoder.encode(.preset(voiceID: "proj")),
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "glob")),
            videoCloneVoiceID: "vc1",
            suppressVideoClone: true))
        #expect(r == .resolved(.preset(voiceID: "proj")))
    }

    @Test("VR-LR5 无克隆、仅全局 → 全局")
    func legacyGlobalOnly() {
        let r = VoiceResolver.resolveForLegacyDub(.init(
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "glob"))))
        #expect(r == .resolved(.preset(voiceID: "glob")))
    }

    @Test("VR-LR6 全无配置 → unconfigured")
    func legacyUnconfigured() {
        #expect(VoiceResolver.resolveForLegacyDub(.init()) == .unconfigured)
    }

    @Test("VR-LR7 项目串损坏 → 回落全局，不阻断")
    func legacyCorruptProjectFallsBackToGlobal() {
        let r = VoiceResolver.resolveForLegacyDub(.init(
            projectOverrideRaw: "{坏",
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "glob"))))
        #expect(r == .resolved(.preset(voiceID: "glob")))
    }

    @Test("VR-LR8 克隆 id 空串/空白等同未克隆")
    func legacyEmptyCloneIDIgnored() {
        let r1 = VoiceResolver.resolveForLegacyDub(.init(
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "g")),
            videoCloneVoiceID: ""))
        #expect(r1 == .resolved(.preset(voiceID: "g")))
        let r2 = VoiceResolver.resolveForLegacyDub(.init(videoCloneVoiceID: "   "))
        #expect(r2 == .unconfigured)
    }

    // MARK: VR：脚本链路（script）

    @Test("VR-S1 项目覆盖 > 全局")
    func scriptProjectBeatsGlobal() {
        let r = VoiceResolver.resolveForScript(
            projectOverrideRaw: VoiceChoiceCoder.encode(.preset(voiceID: "proj")),
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "glob")))
        #expect(r == .resolved(.preset(voiceID: "proj")))
    }

    @Test("VR-S2 仅全局 → 全局")
    func scriptGlobalOnly() {
        let r = VoiceResolver.resolveForScript(
            projectOverrideRaw: nil,
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "glob")))
        #expect(r == .resolved(.preset(voiceID: "glob")))
    }

    @Test("VR-S3 全无配置、即使视频有克隆 → 仍 unconfigured（严禁回退克隆）")
    func scriptNeverFallsBackToVideoClone() {
        let r = VoiceResolver.resolveForScript(projectOverrideRaw: nil, globalDefaultRaw: nil)
        #expect(r == .unconfigured)
        // 即便外部把克隆 id 一并传错也无此入参——编译期保证；这里钉死解析签名只有两参。
    }

    @Test("VR-S4 项目串损坏 → 回落全局")
    func scriptCorruptProjectFallsBack() {
        let r = VoiceResolver.resolveForScript(
            projectOverrideRaw: "null",
            globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "g")))
        #expect(r == .resolved(.preset(voiceID: "g")))
    }

    // MARK: 冲突子集：胜出唯一

    @Test("VR-C1 两级同时存在且项目坏/好切换，结果始终唯一非双重")
    func conflictResolvesToExactlyOneWinner() {
        let good = VoiceChoiceCoder.encode(.preset(voiceID: "proj"))
        // 同一输入多次解析必须幂等一致（不允许一次项目、一次全局的抖动）
        let results = (0..<5).map { _ in
            VoiceResolver.resolveForLegacyDub(.init(
                projectOverrideRaw: good,
                globalDefaultRaw: VoiceChoiceCoder.encode(.preset(voiceID: "glob")),
                videoCloneVoiceID: "vc",
                suppressVideoClone: true))
        }
        #expect(results.allSatisfy { $0 == results.first })
        #expect(results.first == .resolved(.preset(voiceID: "proj")))
    }

    // MARK: 引擎/型号路由

    @Test("音色身份路由：预置/全局复刻→CosyVoice；视频克隆→qwenVC")
    func engineRoutingByIdentity() {
        #expect(VoiceChoice.preset(voiceID: "x").engine == .cosyVoice)
        #expect(VoiceChoice.globalClone(profileID: UUID(), voiceID: "y", model: "cosyvoice-v2").engine == .cosyVoice)
        #expect(VoiceChoice.videoClone(voiceID: "z").engine == .qwenVC)

        #expect(VoiceChoice.preset(voiceID: "x").cosyVoiceModel == CosyVoiceCatalog.model)
        #expect(VoiceChoice.globalClone(profileID: UUID(), voiceID: "y", model: "cosyvoice-v3-plus").cosyVoiceModel
                == "cosyvoice-v3-plus")
        #expect(VoiceChoice.videoClone(voiceID: "z").cosyVoiceModel == nil)
    }

    @Test("合成门：预置查目录、复刻查 profile 有效性、视频克隆只校形态")
    func synthesisGateBranches() {
        #expect(VoiceSynthesisGate.isUsable(.preset(voiceID: "in"),
                                           isCatalogVoice: { $0 == "in" },
                                           isValidCloneProfile: { _ in false }) == true)
        #expect(VoiceSynthesisGate.isUsable(.preset(voiceID: "out"),
                                           isCatalogVoice: { $0 == "in" },
                                           isValidCloneProfile: { _ in false }) == false)
        let pid = UUID()
        #expect(VoiceSynthesisGate.isUsable(.globalClone(profileID: pid, voiceID: "v", model: "m"),
                                           isCatalogVoice: { _ in true },
                                           isValidCloneProfile: { $0 == pid }) == true)
        #expect(VoiceSynthesisGate.isUsable(.globalClone(profileID: UUID(), voiceID: "v", model: "m"),
                                           isCatalogVoice: { _ in true },
                                           isValidCloneProfile: { $0 == pid }) == false)
        #expect(VoiceSynthesisGate.isUsable(.videoClone(voiceID: "vc"),
                                           isCatalogVoice: { _ in false },
                                           isValidCloneProfile: { _ in false }) == true)
    }
}
