import Foundation

// ============================================================================
// 配音语速口径与超字闸（A 块）
// 计划真源：~/.qoder-cn/plans/mossy-sea-elk.md §二 A 块、§三·③
// ============================================================================

/// 一段配音**怎么被塞进画面**的口径。住在 Core，导出层只认这颗策略 ——
/// 与 `AudioTrackPolicy` 同族，守的是 `check_script_pipeline_guards.sh` 的 G-S1：
/// 导出层不得出现业务模式词（`productScript` / `userScriptReverse`），
/// 业务模式改名字不该牵动导出。
///
/// 为什么必须有这颗显式枚举，而不是"看 `atempoFactor` 是不是 1.0"：
/// 新口径下 `atempoFactor` 恒为 1.0，存量里也有正好 1.0 的 —— 拿一颗数值同时当
/// "变速系数"和"哪套口径"用，就是本仓已记的「一颗字段两用」形状。
/// 缺省档只许是 `.unknownLegacy`（防"默认值冒充数据"，同 `TextProvenance` TC-92b 口径）。
public enum DubAlignmentPolicy: String, CaseIterable, Codable, Sendable {
    /// 存量未记录：无从判起。**按落库的 `atempoFactor` / `trailingSilence` 原样复现**，
    /// 绝不重新推导 —— 已交付件必须能重渲成同一个样子。
    case unknownLegacy
    /// 旧口径（明确记录）：配音被逐段变速塞进画面，偏长无封顶。
    case legacyStretch
    /// 新口径：一条方案一个语速、全程不变速；`atempoFactor` 恒 1.0，
    /// 配音偏长一律被超字闸拒掉（画面侧由 B 块的窗口承接，本期未做）。
    case fixedRate
}

/// 语速值的合法区间与唯一 clamp 处。
///
/// 为什么要有这颗：`Video.dubSpeechRate` 的注释写着「范围 0.7~1.3」，但全仓**零写入面**
/// （无控件、无 setter、MCP 不碰），那句范围从来没被 clamp 过 —— 注释与实现早就分叉了。
/// 现在把区间收在一处、并在**写入侧**clamp，面板滑杆与合成侧都从这里取值。
public enum DubRateLimits {

    /// CosyVoice 原生 `rate` 的合法下界（沿用 `SpeechRatePlanner` 的既有权威，不另起一处）。
    public static var rateMin: Double { SpeechRatePlanner.rateMin }
    /// 合法上界，同上。
    public static var rateMax: Double { SpeechRatePlanner.rateMax }

    /// 写入侧唯一 clamp。任何要落库/要发给引擎的语速都必须过这里。
    public static func clamp(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1.0 }
        return min(max(rate, rateMin), rateMax)
    }
}

/// 音色的「字/秒」实测值。
///
/// 为什么需要：`SpeechDuration.charactersPerSecond = 4.3` 是一颗写死的经验值，估完
/// **永不校准、永不回写**（唯一消费者把值单向塞进 `ScriptScene.targetDuration` 就结束）。
/// 语速固定之后，估算误差不再被 atempo 吸收，而是直接决定"这稿字会不会被闸掉"
/// ⇒ 必须让实测值回流进来。默认档仍取 4.3，保证未校准时行为可预期。
public struct DubVoiceCalibration: Equatable, Sendable {

    /// 未校准档的兜底字/秒 —— 与 `SpeechDuration.charactersPerSecond` 同源，不抄第二份。
    public static let fallbackCharsPerSecond: Double = SpeechDuration.charactersPerSecond

    public var charsPerSecond: Double

    public init(charsPerSecond: Double = DubVoiceCalibration.fallbackCharsPerSecond) {
        self.charsPerSecond = charsPerSecond
    }

    /// 按本档字/秒估算口播时长。字数口径复用 `SpeechDuration` 的同一份实现
    /// （去空白与换行、标点保留），不另数一遍。
    public func estimatedSeconds(for text: String) -> Double {
        SpeechDuration.estimatedSeconds(for: text, charsPerSecond: charsPerSecond)
    }

    /// 用一次真合成结果回校：`实测秒数` 与 `有效字数` 的比值。
    /// 拿不到有效输入（零字、零时长、非有限值）时返回 nil —— **不许编一个 0 出来当校准**。
    public static func calibrate(text: String, measuredAudioSeconds: Double) -> Double? {
        let chars = SpeechDuration.spokenCharacterCount(text)
        guard chars > 0, measuredAudioSeconds.isFinite, measuredAudioSeconds > 0 else { return nil }
        return Double(chars) / measuredAudioSeconds
    }
}

/// 两态超字闸。
///
/// ## 为什么是"两态"而不是一道
///
/// 语速固定之后，"配音比画面长"这件事必须被拒（画面侧还没窗口承接）。
/// 但**只有合成之后才知道真时长**，所以：
///   · **合成前**按估算拦 —— 这道是**作业闸门**，必须排在 `jobs.begin()` 之前。
///     既有门禁前置 U07 判的就是这个顺序：「派单一旦发起就是云端计费 + 转写 + 导出，
///     拒回它已经来不及」。
///   · **合成后**按实测拦 —— 这道**不是**作业闸门，它天然在花钱之后。允许后置的理由：
///     实测值只在合成完成后存在，前移它只能靠"先做一次试合成"，而试合成与本轮
///     「停用逐段二次合成、每槽只一次调用」的目标直接相反。它的花钱是已知且已定价的。
/// 两态职责不重叠：估算拦管"别浪费钱"，实测拦管"别交付坏片"。
///
/// ## 为什么不复用 `SpeechDuration.atempoFactor`
///
/// 那颗判据的放行区间是 `factor ∈ (0.5...2.0)`，即**允许文案时长达槽位 2 倍**
/// （测试原文钉着：factor≈23 才返回 nil）。拿它当闸比旧的"无封顶压缩"更宽松，
/// 语速一致一点不解决；反向还会误伤偏短（factor 0.465 也拒），而偏短在固定语速下
/// 是无害的（残差交 `trailingSilence`）。⇒ 已删除，由本类型取代。
public enum DubLengthGate {

    /// 实测超出**可续画面**时允许的容差（秒）。
    ///
    /// 取绝对值而不是"一帧"：本闸管的是"话有没有说完"这种量级，半帧噪声不影响它；
    /// 把 fps 引进判据只会多一个能填错的口子。
    public static let measuredToleranceSeconds: Double = 0.05

    /// 拒绝原因。结构化，供面板逐槽显示"超了多少"，也供 MCP 返回体与导出失败清单复用。
    ///
    /// ⚠️ 载荷字段叫 `capacitySeconds` 而不叫 `pictureSeconds`，是 B 块 B-2 那一改的结果：
    /// 基准从"分镜自己的画面时长"换成"画面**能续到的长度**"（分镜起点 → 源片末尾）。
    /// 名字不改就等于让参数说假话 —— 屏上显示的秒数会被读成"分镜就这么长"，
    /// 而那时用户会去改短一句本来根本不用改的台词。
    public enum Rejection: Equatable, Sendable {
        /// 合成前：估算时长已超过可续画面
        case estimateOver(estimatedSeconds: Double, capacitySeconds: Double)
        /// 合成后：实测音频时长超过可续画面
        case measuredOver(audioSeconds: Double, capacitySeconds: Double)
        /// 无法判：容量缺失/非正。按**拒绝**处理 —— 放行一条不知道会不会超的配音，
        /// 等于把"绝不超画面"的承诺换成运气。
        case undecidable
    }

    public enum Verdict: Equatable, Sendable {
        case pass
        case reject(Rejection)
    }

    /// 合成前判据。`calibration` 缺省走 4.3 字/秒的未校准档。
    ///
    /// 空文本不算超字（交上游的"没词就别合成"处理），本闸只管长度。
    public static func preCheck(text: String,
                                capacitySeconds: Double,
                                calibration: DubVoiceCalibration = DubVoiceCalibration()) -> Verdict {
        guard capacitySeconds.isFinite, capacitySeconds > 0 else { return .reject(.undecidable) }
        guard SpeechDuration.spokenCharacterCount(text) > 0 else { return .pass }
        let estimated = calibration.estimatedSeconds(for: text)
        guard estimated > capacitySeconds else { return .pass }
        return .reject(.estimateOver(estimatedSeconds: estimated, capacitySeconds: capacitySeconds))
    }

    /// 合成后判据（真值）。
    public static func postCheck(audioSeconds: Double, capacitySeconds: Double) -> Verdict {
        guard capacitySeconds.isFinite, capacitySeconds > 0 else { return .reject(.undecidable) }
        guard audioSeconds.isFinite, audioSeconds > 0 else { return .reject(.undecidable) }
        guard audioSeconds > capacitySeconds + measuredToleranceSeconds else { return .pass }
        return .reject(.measuredOver(audioSeconds: audioSeconds, capacitySeconds: capacitySeconds))
    }
}

/// 语速的解析顺序（唯一真源）。
///
/// 为什么需要这颗函数而不是就地写 `?? 1.0`：分镜配音链里 dub **早于方案存在**
/// （`generateAllAudio` 注释「一键改写后自动调用」，入参只有 segments + videoID；
///  方案是事后靠 `SchemeSegment.selectedSegmentDubId` 绑的），所以"方案级语速"
/// 在这条链上**读不到**。语速必须在生成时就定下来并戳进 dub，方案侧只能事后校验。
///
/// 顺序照本仓 `resolvedChoice` 的既有先例：**显式传入 ＞ 视频级偏好 ＞ 1.0**，
/// 且每一档都过 `DubRateLimits.clamp`（不 clamp 就是让注释里的范围当摆设 ——
/// `Video.dubSpeechRate` 的 0.7~1.3 从来没被 clamp 过，就是这么烂掉的）。
public enum DubRateResolution {

    /// 未指定任何偏好时的中性语速（= 引擎自然语速）。
    public static let neutralRate: Double = 1.0

    public static func resolve(explicit: Double?, videoPreference: Double?) -> Double {
        if let explicit { return DubRateLimits.clamp(explicit) }
        if let videoPreference { return DubRateLimits.clamp(videoPreference) }
        return neutralRate
    }
}

/// 一条方案里"语速是否真的全程一致"的可校验判据。
///
/// 这是把用户的诉求（"全程语速一致"）从"生成时尽量做到"升级成"**落库后可审计**"：
/// 方案装配完成后，逐槽问一次就知道有没有混进别的语速，不用靠听。
public enum DubRateUniformity {

    public struct Verdict: Equatable, Sendable {
        /// 不一致的语速值集合（升序）。空 = 一致。
        public let distinctRates: [Double]
        /// 被检查的 dub 数（不含原声/锁定槽 —— 它们没有配音语速可言）。
        public let checkedCount: Int
        public var isUniform: Bool { distinctRates.count <= 1 }
    }

    /// `rates` 里每个元素是一条**参与本次组合的配音**所用的语速。
    /// 空数组 ⇒ 一致（没有配音就没有不一致可言，但 `checkedCount` 会是 0，
    /// 调用方要区分"都一致"与"根本没配音可查"）。
    public static func check(rates: [Double]) -> Verdict {
        Verdict(distinctRates: Set(rates).sorted(), checkedCount: rates.count)
    }
}

/// 超字拒绝的错误类型。导出/合成链用它把失败**结构化**上报 ——
/// 守 `check_script_pipeline_guards.sh` G-S3 的纪律：严禁 `guard let … else { continue }`
/// 那种静默跳过，缺配音必须进失败清单。
public struct DubLengthRejected: Error, CustomStringConvertible, Equatable, Sendable {
    public let reason: DubLengthGate.Rejection
    public init(_ reason: DubLengthGate.Rejection) { self.reason = reason }

    public var description: String {
        switch reason {
        case .estimateOver(let est, let cap):
            // 说的是"可续画面"而不是"画面"：数字是「分镜起点 → 源片末尾」的长度。
            // 只写"画面"会让用户去改一句本来不用改的台词 —— 他不知道画面还能往后接。
            return String(format: "文案约 %.1fs，超过可续画面 %.1fs（画面已能往后接到源片末尾），请先改短台词", est, cap)
        case .measuredOver(let audio, let cap):
            return String(format: "配音实测 %.1fs，超过可续画面 %.1fs（画面已接到源片末尾），请先改短台词", audio, cap)
        case .undecidable:
            return "画面可续长度未知，无法判配音是否超长"
        }
    }
}
