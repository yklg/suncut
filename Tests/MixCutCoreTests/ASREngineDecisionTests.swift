import Foundation
import Testing
@testable import MixCutCore

/// `ASRPolicy` + `ASREngineDecision` 的契约测试（计划 v9 §10.4 组 2，TC-73…TC-77）
///
/// 本文件已从预览落地：在 `Tests/MixCutCoreTests/` 内、已编译、`swift test` 跑绿（2026-09-28）。
/// 它钉的是尚未实现的 API 形状；实现须与此签名一致，对不上时回计划对齐，不放宽测试。
///
/// 假定签名：
/// ```
/// public enum ASRPurpose: String, CaseIterable, Sendable {
///     case wholeVideoTimeline    // 整片听写，产出字级时间戳（分镜边界的依据）
///     case singleClipListening   // 自建分镜上传：整听一个短片，只取文本
///     case segmentTextRetake     // 逐段重听，覆盖 Segment.text
/// }
/// public enum ASRPreference: String, CaseIterable, Sendable { case auto, cloud, local }
/// public enum ASREngine: String, Equatable, Sendable { case cloud, local }
/// public enum EngineDecision: Equatable, Sendable {
///     case use(ASREngine, reason: String)
///     case refused(reason: String)
/// }
/// public struct LocalASRState: Equatable, Sendable { public let usable: Bool; public let tier: String? }
/// public enum ASRPolicy { public static let engineTier: String; public static let defaultPreference: ASRPreference }
/// public enum ASREngineDecision {
///     public static func decide(purpose: ASRPurpose,
///                               preference: ASRPreference?,   // nil = 用户没设过，回落 ASRPolicy.defaultPreference
///                               hasCloudKey: Bool,
///                               local: LocalASRState) -> EngineDecision
/// }
/// ```
///
/// 钉住的规则（红线 R6 + 一般规则 R-c/R-g）：
/// - **能力优先于偏好**：`wholeVideoTimeline` 恒本地（云端没有时间戳，选它=分镜边界坏）
/// - `singleClipListening` 恒本地 —— **这一格是我替你选的"保守"，理由是上传片段不该外流云端，不是能力不允许**；
///   要放开成"可云端"就改这条测试，别只改实现（计划 §3.4 说的"不许实现时随手填"就是这个意思）
/// - **拒绝必须给理由，且三种拒绝的理由彼此不同**（能力/凭据/本地未就绪），不许静默换路线
/// - 决策**只由入参决定**（同输入三次调用同结论）；"包内不读存储"那半边由守卫 TC-86 守
///
/// 非空洞性对应：TC-77 断言"偏好云端但没配 Key"必须是 `.refused` 而**不是**悄悄 `.use(.local)` ——
/// 若实现写成静默降级，这条会红（这正是今天那个"静默回落到整片抽取"的形状）。

@Suite("ASREngineDecision：9 格决策表与必拒理由")
struct ASREngineDecisionTests {

    private let readyLocal = LocalASRState(usable: true, tier: ASRPolicy.engineTier)
    private let noLocal = LocalASRState(usable: false, tier: nil)

    // MARK: TC-73 九格全展开（本机现状：Key 未配 → hasCloudKey=false 单独在 TC-77 走）

    @Test("TC-73 3 purpose × 3 preference 每格都有定义，且不留空、理由非空")
    func fullGridHasNoUndefinedCell() {
        let expectations: [ASRPurpose: [ASRPreference: ASREngine?]] = [
            .wholeVideoTimeline: [.auto: .local, .cloud: nil, .local: .local],
            .singleClipListening: [.auto: .local, .cloud: nil, .local: .local],
            .segmentTextRetake: [.auto: .cloud, .cloud: .cloud, .local: .local],
        ]
        var cells = 0
        for purpose in ASRPurpose.allCases {
            for preference in ASRPreference.allCases {
                cells += 1
                let decision = ASREngineDecision.decide(purpose: purpose,
                                                        preference: preference,
                                                        hasCloudKey: true,
                                                        local: readyLocal)
                let expected = expectations[purpose]?[preference]
                #expect(expected != nil, "测试自身的期望表漏了格：\(purpose)/\(preference)")
                switch (decision, expected ?? .local) {
                case let (.use(engine, reason), .some(want)):
                    #expect(engine == want, "\(purpose)×\(preference) 走了 \(engine)，期望 \(want)")
                    #expect(!reason.isEmpty, "\(purpose)×\(preference) 的理由是空串")
                case let (.refused(reason), nil):
                    #expect(!reason.isEmpty, "\(purpose)×\(preference) 拒绝却没给理由")
                case (.refused, .some):
                    Issue.record("\(purpose)×\(preference) 本应可用（\(String(describing: expected))）却被拒")
                case (.use, nil):
                    Issue.record("\(purpose)×\(preference) 本应拒绝却返回了使用")
                }
            }
        }
        #expect(cells == 9, "格子数不对（\(cells)），说明枚举或期望表有一边没铺满")
    }

    // MARK: TC-74 三个必拒理由彼此不同

    @Test("TC-74 拒绝理由分三种：能力 / 凭据 / 本地未就绪，不许同一句话糊过去")
    func refusalReasonsAreDistinguishable() {
        let capability = ASREngineDecision.decide(purpose: .wholeVideoTimeline,
                                                 preference: .cloud,
                                                 hasCloudKey: true,
                                                 local: readyLocal)
        let notReady = ASREngineDecision.decide(purpose: .segmentTextRetake,
                                               preference: .local,
                                               hasCloudKey: true,
                                               local: noLocal)
        let noKey = ASREngineDecision.decide(purpose: .segmentTextRetake,
                                            preference: .cloud,
                                            hasCloudKey: false,
                                            local: readyLocal)

        guard case let .refused(reasonA) = capability,
              case let .refused(reasonB) = notReady,
              case let .refused(reasonC) = noKey else {
            Issue.record("三格本应全部拒绝：\(capability) / \(notReady) / \(noKey)")
            return
        }
        #expect(reasonA != reasonB && reasonB != reasonC && reasonA != reasonC,
                "三种不同的拒绝原因被写成了同一句话：\(reasonA)")
        #expect(reasonA.contains("时间戳") || reasonA.contains("整片"),
                "能力型拒绝要说清是时间戳/整片这条能力线，实际：\(reasonA)")
        #expect(reasonB.contains("模型"), "本地未就绪要说清缺模型，实际：\(reasonB)")
        #expect(reasonC.contains("Key"), "缺凭据要说清是没配 Key，实际：\(reasonC)")
    }

    // MARK: TC-75 纯函数确定性

    @Test("TC-75 全 36 组合（3 purpose × 3 偏好 × 有无 Key × 本地就绪与否）重复调用三次 ⇒ 结论一致")
    func decisionIsDeterministic() {
        let keyStates = [true, false]
        let locals = [readyLocal, noLocal]
        var evaluated = 0
        for purpose in ASRPurpose.allCases {
            for preference in ASRPreference.allCases {
                for hasKey in keyStates {
                    for local in locals {
                        evaluated += 1
                        let first = ASREngineDecision.decide(purpose: purpose, preference: preference,
                                                             hasCloudKey: hasKey, local: local)
                        let second = ASREngineDecision.decide(purpose: purpose, preference: preference,
                                                              hasCloudKey: hasKey, local: local)
                        let third = ASREngineDecision.decide(purpose: purpose, preference: preference,
                                                             hasCloudKey: hasKey, local: local)
                        #expect(first == second && second == third,
                                "同输入得到不同结论（\(purpose)/\(preference)/\(hasKey)）：说明读了外部状态")
                    }
                }
            }
        }
        #expect(evaluated == 36, "组合没铺满，实际 \(evaluated)")
    }

    // MARK: TC-76 未设置偏好时回落默认（回落逻辑在纯函数侧，存储侧由 ASRSettings 负责）

    @Test("TC-76 preference 为 nil（用户从没设过）⇒ 等价于 ASRPolicy.defaultPreference")
    func nilPreferenceFallsBackToPolicyDefault() {
        #expect(ASRPolicy.defaultPreference == .local, "本轮裁定默认是本地，改了要回计划对齐")
        for purpose in ASRPurpose.allCases {
            let asNil = ASREngineDecision.decide(purpose: purpose, preference: nil,
                                                 hasCloudKey: false, local: readyLocal)
            let asDefault = ASREngineDecision.decide(purpose: purpose,
                                                     preference: ASRPolicy.defaultPreference,
                                                     hasCloudKey: false, local: readyLocal)
            #expect(asNil == asDefault, "\(purpose)：nil 与默认偏好结论不同，等于多出一处隐含默认值")
        }
        #expect(ASRPolicy.engineTier == "large-v3", "恒用档位这条裁定被改动：\(ASRPolicy.engineTier)")
    }

    // MARK: TC-77 缺凭据不许静默改路线

    @Test("TC-77 强制云端但没配 Key ⇒ 必须明确拒绝，不得悄悄走本地")
    func cloudWithoutKeyIsRefusedNotSilentLocal() {
        let refused = ASREngineDecision.decide(purpose: .segmentTextRetake, preference: .cloud,
                                               hasCloudKey: false, local: readyLocal)
        switch refused {
        case let .use(engine, _):
            Issue.record("偏好被无声改写成 \(engine) —— 这正是今天'静默回落到整片抽取'的形状")
        case let .refused(reason):
            #expect(!reason.isEmpty, "拒绝必须给一句能显示的话")
            #expect(reason.contains("Key"), "理由要说清是没配 Key，实际：\(reason)")
        }

        // auto 是**显式定义**的回落，与"强制云端被拒"是两条不同路线，不许混为一谈
        let autoFallback = ASREngineDecision.decide(purpose: .segmentTextRetake, preference: .auto,
                                                    hasCloudKey: false, local: readyLocal)
        switch autoFallback {
        case let .use(engine, reason):
            #expect(engine == .local, "auto 且无 Key 时应走本地，实际 \(engine)")
            #expect(!reason.isEmpty, "回落也要给一句能显示给用户的话")
        case .refused:
            Issue.record("本地可用模型存在时 auto 不该拒绝：\(autoFallback)")
        }
    }
}
