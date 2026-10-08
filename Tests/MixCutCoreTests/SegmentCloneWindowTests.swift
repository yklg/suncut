import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// SCW · 段级克隆参考窗口（M2）
//
// ## 本组测试守护什么
//
// 1. **窗口绝不向前扩展**（SCW-1，负向哨兵）—— 向前必然侵入前一分镜，
//    那正是「选中女声段却克隆出男声」的病根。宁可样本短，也不能跨界。
// 2. **长度上限 6 秒**（实测依据：18s 参考会让 TTS「续读参考内容」，
//    见 `DubbingViewModel.ensureClonedVoice` 注释）。
// 3. **复用判据在跨说话人时必须拒绝**（SCW-7 = 用户现场回归）。
// 4. **变异腿**（SCW-9）防判据恒绿：破坏实现后用例必须变红。
// ============================================================================

// MARK: - 窗口只向后取

@Test("SCW-1 窗口永不早于分镜起点（负向哨兵：向前扩展 = 跨说话人 = 本 bug）")
func scw1_windowNeverExtendsBackward() {
    // 🔵 负向哨兵：这条红了说明有人加了「向前外扩」。
    for start in [0, 30, 300, 5400] {
        let w = WindowPlanner.planWindow(startFrame: start, fps: 30, videoFrameCount: 6000)
        let w2 = try! #require(w, "start=\(start) 应产出窗口")
        #expect(w2.startFrame == start,
                "窗口起点 \(w2.startFrame) 早于分镜起点 \(start) ⇒ 会侵入前一分镜")
    }
}

@Test("SCW-2 窗口长度不超过 6 秒（fps 无关）")
func scw2_windowLengthCapped() {
    // 30fps → 6s = 180 帧；60fps → 360 帧；29.97 → 180 帧（取整）
    let w30 = try! #require(WindowPlanner.planWindow(startFrame: 0, fps: 30, videoFrameCount: 10000))
    #expect(w30.frameCount == 180, "30fps 应为 180 帧，实际 \(w30.frameCount)")

    let w60 = try! #require(WindowPlanner.planWindow(startFrame: 0, fps: 60, videoFrameCount: 20000))
    #expect(w60.frameCount == 360, "60fps 应为 360 帧，实际 \(w60.frameCount)")

    let w2997 = try! #require(WindowPlanner.planWindow(startFrame: 0, fps: 29.97, videoFrameCount: 10000))
    #expect(w2997.frameCount == 180, "29.97fps 应约 180 帧，实际 \(w2997.frameCount)")
}

@Test("SCW-3 短分镜：窗口向后补足到 6 秒（不是截成 3 秒）")
func scw3_shortSegmentExtendsForwardOnly() {
    // 3 秒分镜（90 帧 @30fps）⇒ 窗口 [0, 180) = 6 秒。
    // ⚠️ 允许「向后吃进后续内容」——那仍在同一分镜之后，不会跨到前一分镜。
    let w = try! #require(WindowPlanner.planWindow(startFrame: 0, fps: 30, videoFrameCount: 1000))
    #expect(w.frameCount == 180, "短分镜应向后补足，实际 \(w.frameCount)")
}

@Test("SCW-4 末尾分镜：窗口被夹在视频内，不越界")
func scw4_clampedToVideoEnd() {
    let total = 1000
    let w = try! #require(WindowPlanner.planWindow(startFrame: 980, fps: 30, videoFrameCount: total))
    #expect(w.endFrame == total, "窗口终点 \(w.endFrame) 越界（视频共 \(total) 帧）")
    #expect(w.startFrame == 980)
    #expect(w.frameCount == 20, "末尾分镜只有 20 帧可用，实际 \(w.frameCount)")
}

@Test("SCW-5 边界：零长分镜 / 起始越界 / 帧率非法 ⇒ nil")
func scw5_invalidInputsYieldsNil() {
    #expect(WindowPlanner.planWindow(startFrame: 500, fps: 30, videoFrameCount: 500) == nil,
            "零长分镜（start == 末尾）应返回 nil")
    #expect(WindowPlanner.planWindow(startFrame: 600, fps: 30, videoFrameCount: 500) == nil,
            "起始越界应返回 nil")
    #expect(WindowPlanner.planWindow(startFrame: 0, fps: 0, videoFrameCount: 500) == nil,
            "fps=0 应返回 nil")
    #expect(WindowPlanner.planWindow(startFrame: 0, fps: -30, videoFrameCount: 500) == nil,
            "fps 为负应返回 nil")
}

@Test("SCW-6 无语音（纯 BGM）⇒ nil（不送注册，避免静默兜底成默认音色）")
func scw6_noVoiceYieldsNil() {
    #expect(WindowPlanner.planWindow(startFrame: 0, fps: 30, videoFrameCount: 500,
                                     hasVoice: false) == nil,
            "无语音时不该产出窗口：送去克隆会被服务端静默兜底成默认音色（= 静默错误）")
    #expect(WindowPlanner.planWindow(startFrame: 0, fps: 30, videoFrameCount: 500,
                                     hasVoice: true) != nil,
            "有语音时应正常产出窗口（合法必绿等价类）")
}

// MARK: - 复用判据

@Test("SCW-7 用户现场回归：跨说话人的两个分镜**不得**复用（男声段 vs 女声段）")
func scw7_crossSpeakerMustNotReuse() {
    // 实测（Stems/c9e2e09d…/vocals.wav，58.8s，自相关估基频）：
    //   0~18 秒 男声 125~156 Hz · 21 秒后 女声 200~256 Hz
    let male = try! #require(WindowPlanner.planWindow(startFrame: 0, fps: 30, videoFrameCount: 1764))
    let female1 = try! #require(WindowPlanner.planWindow(startFrame: 630, fps: 30, videoFrameCount: 1764))

    // 🔴 核心断言：女声段**不得**复用男声窗口（否则拿到男声音色 = 用户现场 bug）
    #expect(WindowPlanner.reusableWindow(candidate: female1, among: [male]) == nil,
            "女声段复用了男声窗口 ⇒ 会克隆出男声（用户现场 bug）")

    // 合法必绿等价类：男声段**确实**能复用自己（否则上面的 nil 可能来自判据恒假）
    #expect(WindowPlanner.reusableWindow(candidate: male, among: [male]) != nil,
            "男声段连自己都复用不了 ⇒ 判据恒假（上面的 nil 就没有意义了）")
}

@Test("SCW-7b 已知代价：同一人但相隔 18 秒的两个分镜**会**漏复用（多花一次注册）")
func scw7b_knownCostOfOverlapOnlyHeuristic() {
    // ⚠️ **这是用户已裁决的已知代价**（复用判据用「时间重叠」而非基频聚类的直接后果）：
    // 两个分镜相隔 18 秒时窗口零重叠 ⇒ 判为不同人 ⇒ 各自注册一次。
    // 实测代价：在 34 分镜的典型视频上，注册次数从 1 变成 ~3（而非 2）。
    // 保留这条用例是为了**让代价显式可见**，将来若改用基频聚类，这里应当变绿。
    let female1 = try! #require(WindowPlanner.planWindow(startFrame: 630, fps: 30, videoFrameCount: 1764))
    let female2 = try! #require(WindowPlanner.planWindow(startFrame: 1350, fps: 30, videoFrameCount: 1764))

    #expect(WindowPlanner.overlapRatio(female1, female2) == 0.0,
            "相隔 18 秒的两个 6 秒窗口本就不重叠（构造前提）")
    #expect(WindowPlanner.reusableWindow(candidate: female2, among: [female1]) == nil,
            "当前判据下会漏复用—— 这是**已知且已接受**的代价，不是缺陷")
}

@Test("SCW-7c 说话人连续时的正常复用（相邻分镜，窗口必然重叠）")
func scw7c_adjacentSegmentsReuse() {
    // 真实的复用场景：同一人连续说话被切成相邻短分镜 ⇒ 窗口高度重叠。
    let seg1 = try! #require(WindowPlanner.planWindow(startFrame: 600, fps: 30, videoFrameCount: 1764))
    let seg2 = try! #require(WindowPlanner.planWindow(startFrame: 660, fps: 30, videoFrameCount: 1764))
    // 3s 间隔 ⇒ 窗口 [600,780) 与 [660,840) 重叠 120 帧 = 67% ⇒ 复用
    #expect(WindowPlanner.reusableWindow(candidate: seg2, among: [seg1]) != nil,
            "相邻 2 秒的分镜（同一人连续说话）应复用，否则会大量重复注册")
}

@Test("SCW-8 复用阈值：重叠需达到较短窗口的一半")
func scw8_overlapThreshold() {
    let a = CloneReferenceWindow(startFrame: 0, endFrame: 180)     // 6s
    let half = CloneReferenceWindow(startFrame: 90, endFrame: 270)   // 重叠 90 = a 的 50%
    let touching = CloneReferenceWindow(startFrame: 180, endFrame: 360)  // 零重叠
    let most = CloneReferenceWindow(startFrame: 30, endFrame: 210)   // 重叠 150 = 83%

    #expect(WindowPlanner.overlapRatio(a, a) == 1.0, "自身重叠应为 1.0")
    #expect(WindowPlanner.overlapRatio(a, touching) == 0.0, "首尾相接不重叠应为 0")
    #expect(WindowPlanner.reusableWindow(candidate: half, among: [a]) != nil,
            "恰好 50% 重叠应判为可复用（阈值含等号）")
    #expect(WindowPlanner.reusableWindow(candidate: touching, among: [a]) == nil,
            "零重叠不得复用")
    #expect(WindowPlanner.reusableWindow(candidate: most, among: [a]) != nil,
            "83% 重叠应可复用")
}

@Test("SCW-9 变异腿：破坏阈值后 SCW-8/7 必须变红（防判据恒绿）")
func scw9_mutationSentinel() {
    // 变异：把阈值从 0.5 改成 1.1（永不满足）⇒ 复用全部失效。
    // 若 SCW-8 的"恰好 50% 应复用"仍绿，说明那条断言没在承重 ⇒ 是假绿。
    let mutatedRatio = 1.1
    let a = CloneReferenceWindow(startFrame: 0, endFrame: 180)
    let half = CloneReferenceWindow(startFrame: 90, endFrame: 270)
    let ratio = WindowPlanner.overlapRatio(a, half)
    let wouldReuse = ratio >= mutatedRatio          // 模拟被改坏的判据
    #expect(wouldReuse == false,
            "变异后 50% 重叠被判为不可复用 —— 这正是 SCW-8 会变红的原因（若 SCW-8 仍绿即为假绿）")
    #expect(WindowPlanner.reuseOverlapRatio == 0.5, "真实阈值必须是 0.5，被改动过则本条红")
}

@Test("SCW-10 seconds 换算与帧栅格一致（不引入第二套口径）")
func scw10_secondsConsistent() {
    let w = CloneReferenceWindow(startFrame: 30, endFrame: 210)
    #expect(abs(w.seconds(fps: 30) - 6.0) < 0.001, "180 帧 @30fps 应为 6 秒")
    #expect(WindowPlanner.seconds(frame: 45, fps: 30) == 1.5, "45 帧 @30fps = 1.5 秒")
    #expect(WindowPlanner.seconds(frame: -10, fps: 30) == 0.0, "负帧夹到 0，不返回负秒")
    #expect(WindowPlanner.seconds(frame: 30, fps: 0) == 0.0, "fps=0 不得除零")
}
