import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// PW · 画面窗口派生（B 块第一层：纯函数，零行为变更）
//
// 这一批只测**派生**。导出侧把画面裁剪从「分镜帧区间」换成「窗口帧区间」是下一层，
// 那时才需要 `ExportDurationGateTests` 那条真渲染腿（T6）。
//
// 计划 T5（跨段累积漂移）在本文件的 PW-8 —— 它原本挂着"红钉（新判据未写）"，
// 有了这个纯派生函数才写得出来，故本轮一并结掉。
// ============================================================================

@Suite("PW · 画面窗口派生")
struct PictureWindowTests {

    // MARK: 三态

    @Test("PW-1 配音短于分镜 ⇒ 窗口就是分镜本身，且**不缩短画面**")
    func dubShorterThanShotKeepsPicture() throws {
        // 分镜 [100,200) = 100 帧 @25fps = 4s；dub 2s = 50 帧
        let w = try #require(PictureWindowPolicy.derive(startFrame: 100, endFrame: 200,
                                                         sourceEndFrame: 1000,
                                                         dubSeconds: 2.0, fps: 25))
        #expect(w.frames == 100, "配音短就把画面缩短 ⇒ 分镜长度不再是地板，同一段素材在画面裁剪与交付时长闸两处会给出不同长度")
        #expect(w.endFrame == 200)
        #expect(w.requiredFrames == 100)
        #expect(w.shortfallFrames == 0)
        #expect(w.mode == .unchanged)
    }

    @Test("PW-2 配音恰等于分镜 ⇒ unchanged（边界取 <=，不许抖成 extended）")
    func dubExactlyEqualsShot() throws {
        let w = try #require(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100,
                                                         sourceEndFrame: 500,
                                                         dubSeconds: 4.0, fps: 25))
        #expect(w.mode == .unchanged, "4.0s@25fps 恰是 100 帧，等于分镜 ⇒ 不该算扩窗")
        #expect(w.endFrame == 100)
    }

    @Test("PW-3 配音比画面长 ⇒ 往源片后面续帧接住，无差额")
    func dubLongerExtendsForward() throws {
        // dub 5.0s = 125 帧 > 分镜 100 帧；源片还有 500 帧 ⇒ 全接得住
        let w = try #require(PictureWindowPolicy.derive(startFrame: 100, endFrame: 200,
                                                         sourceEndFrame: 500,
                                                         dubSeconds: 5.0, fps: 25))
        #expect(w.requiredFrames == 125)
        #expect(w.startFrame == 100, "计划 B 块 12：起点恒等于分镜起点")
        #expect(w.endFrame == 225, "窗口尾 = 100 + 125")
        #expect(w.frames == 125)
        #expect(w.shortfallFrames == 0)
        #expect(w.mode == .extended)
    }

    @Test("PW-4 续到源片末尾仍不足 ⇒ 判差额，且差额数就是差的那几帧")
    func clampAtSourceEndReportsShortfall() throws {
        // dub 5.0s = 125 帧，但源片只到 240 帧 ⇒ 窗口 [100,240) = 140…不对：可用只有 140 帧 > 125
        // 换个数：源片末尾 210 帧 ⇒ 可用 110 帧，差 15 帧
        let w = try #require(PictureWindowPolicy.derive(startFrame: 100, endFrame: 200,
                                                         sourceEndFrame: 210,
                                                         dubSeconds: 5.0, fps: 25))
        #expect(w.endFrame == 210, "没夹到源片末尾 ⇒ 会裁出源里不存在的帧（导出直接失败或黑帧）")
        #expect(w.frames == 110)
        #expect(w.shortfallFrames == 15, "差额 = 125 − 110")
        #expect(w.mode == .shortByBroll)
    }

    @Test("PW-5 源片元数据比分镜尾帧还短（脏数据）⇒ 分镜是地板，不许被缩短")
    func staleSourceDurationCannotShrinkShot() throws {
        // 真实来源：`video.duration`（容器时长）与分镜帧号来自两次测量，浮点误差能让前者"短于"分镜尾
        let w = try #require(PictureWindowPolicy.derive(startFrame: 100, endFrame: 200,
                                                         sourceEndFrame: 150,
                                                         dubSeconds: 2.0, fps: 25))
        #expect(w.frames == 100, "按脏的源长夹 ⇒ 一条完全正常的分镜被缩成 50 帧，而屏上只少了 2 秒，没人会注意到")
        #expect(w.endFrame == 200)
        #expect(w.mode == .unchanged)
        #expect(w.shortfallFrames == 0, "分镜本身装得下这条 dub ⇒ 不该报差额")
    }

    // MARK: 秒→帧口径

    @Test("PW-6 秒→帧走 FrameTime 的 half-away-from-zero，平局点有实算值钉着")
    func frameRoundingFollowsFrameTime() throws {
        // 1.38s × 25 = 34.5 是平局点：T4-1 那轮踩过"浮点把实数平局压歪"，
        // 平局方向由实算值钉，不许 floor/ceil 漂（本仓 `.rounded()` 是 half-away-from-zero）
        let atTie = try #require(PictureWindowPolicy.derive(startFrame: 0, endFrame: 10,
                                                            sourceEndFrame: 1000,
                                                            dubSeconds: 1.38, fps: 25))
        #expect(atTie.requiredFrames == 35, "平局点取 35（half-away-from-zero）；变 34 说明换算不再是 FrameTime 那一处")

        let belowTie = try #require(PictureWindowPolicy.derive(startFrame: 0, endFrame: 10,
                                                               sourceEndFrame: 1000,
                                                               dubSeconds: 1.37, fps: 25))
        #expect(belowTie.requiredFrames == 34)
        let aboveTie = try #require(PictureWindowPolicy.derive(startFrame: 0, endFrame: 10,
                                                              sourceEndFrame: 1000,
                                                              dubSeconds: 1.39, fps: 25))
        #expect(aboveTie.requiredFrames == 35)
    }

    @Test("PW-7 输入不成立 ⇒ nil，不许退化成零长窗口或原分镜")
    func badInputsYieldNilNotAGuess() throws {
        // 每颗非法输入单独验：退化成"照原分镜办"会让超字闸以为接不住/接得住（取决于哪条路），
        // 退化成 0 帧窗口则会裁出 0 帧画面 —— 两种都是把"算不出来"伪装成结论。
        #expect(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100, sourceEndFrame: 500,
                                           dubSeconds: 3.0, fps: 0) == nil)
        #expect(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100, sourceEndFrame: 500,
                                           dubSeconds: 3.0, fps: -25) == nil)
        #expect(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100, sourceEndFrame: 500,
                                           dubSeconds: 3.0, fps: .nan) == nil)
        #expect(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100, sourceEndFrame: 500,
                                           dubSeconds: .nan, fps: 25) == nil)
        #expect(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100, sourceEndFrame: 500,
                                           dubSeconds: -1, fps: 25) == nil)
        #expect(PictureWindowPolicy.derive(startFrame: 200, endFrame: 200, sourceEndFrame: 500,
                                           dubSeconds: 3.0, fps: 25) == nil, "帧区间倒挂/零长")
        #expect(PictureWindowPolicy.derive(startFrame: 300, endFrame: 200, sourceEndFrame: 500,
                                           dubSeconds: 3.0, fps: 25) == nil)
        #expect(PictureWindowPolicy.derive(startFrame: -1, endFrame: 200, sourceEndFrame: 500,
                                           dubSeconds: 3.0, fps: 25) == nil)
        // dub = 0 是"这条配音没声音"，不是"输入不成立" ⇒ 走正常派生（结果等于分镜）
        let zero = try #require(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100,
                                                           sourceEndFrame: 500,
                                                           dubSeconds: 0, fps: 25))
        #expect(zero.frames == 100)
    }

    // MARK: T5 跨段累积漂移

    @Test("PW-8 跨段累积漂移：逐段派生帧数之和 vs 总时长单次派生，差 ≤1 帧")
    func crossSegmentDriftStaysWithinOneFrame() throws {
        // 计划 T5 的动机：帧率口径不一致会造成线性 progressive drift。
        // 挑非整帧率 + 一个会累积的时长，让"每段各自 floor/ceil"与"总时长一次算"必然分叉。
        let fps = 29.97
        let each = 1.234
        let n = 9
        var perSegment = 0
        for i in 0..<n {
            let start = i * 30
            let w = try #require(PictureWindowPolicy.derive(startFrame: start, endFrame: start + 20,
                                                             sourceEndFrame: 100_000,
                                                             dubSeconds: each, fps: fps))
            perSegment += w.frames
        }
        let singleShotTotal = FrameTime.frame(seconds: each * Double(n), fps: fps)
        let drift = abs(perSegment - singleShotTotal)
        // 显式记录实测差值（T5 要求"记下差值"，只报"≤1"等于没测）
        print("PW-8 实测：逐段合计 \(perSegment) 帧 vs 总时长单次派生 \(singleShotTotal) 帧 ⇒ 差 \(drift) 帧"
              + "（fps=\(fps), 每段 \(each)s × \(n)）")
        #expect(drift <= 1, "跨段累积漂移超过 1 帧 ⇒ 窗口派生与总时长口径分叉，成片会漂")
    }

    @Test("PW-9 窗口帧数与秒数在帧栅格上往返无损（交付时长闸吃的是同一个数）")
    func framesAndSecondsAgreeOnGrid() throws {
        let fps = 25.0
        for dub in [2.0, 4.0, 5.0, 7.32] {
            let w = try #require(PictureWindowPolicy.derive(startFrame: 0, endFrame: 100,
                                                             sourceEndFrame: 100_000,
                                                             dubSeconds: dub, fps: fps))
            #expect(w.seconds(fps: fps) == FrameTime.seconds(frame: w.frames, fps: fps),
                    "窗口秒数不是帧数的精确派生 ⇒ 会出现'屏上时长'与'实际裁剪长度'两个数")
            // 时长闸按 (endFrame − startFrame)/fps 累加，与本函数的 frames 必须是同一个量
            #expect(w.frames == w.endFrame - w.startFrame)
        }
    }

    // MARK: 可交付判定与回退

    @Test("PW-10 差额容忍：容差折算成帧，且容差是入参不是写死的数")
    func deliverabilityUsesToleranceAsAnInput() throws {
        let fps = 25.0
        let tol = DubLengthGate.measuredToleranceSeconds          // 0.05s → 1 帧
        #expect(FrameTime.frame(seconds: tol, fps: fps) == 1,
                "实测容差折算不再是 1 帧 ⇒ 下面两格的边界要重算，别把判据改成恰好过的样子")
        // 需要 125 帧、可续到 201 ⇒ 只有 101 帧 ⇒ 差 24 帧，远超容差
        let t = try #require(PictureWindowPolicy.derive(startFrame: 100, endFrame: 200,
                                                        sourceEndFrame: 201, dubSeconds: 5.0, fps: fps))
        #expect(t.shortfallFrames == 24)
        #expect(!PictureWindowPolicy.isDeliverable(t, fps: fps, toleranceSeconds: tol))

        // 差 1 帧（恰等容差）⇒ 仍可导：今天这类素材本来就能出片，改成"有差额即拒"是回归不是收紧
        let oneFrame = PictureWindow(startFrame: 0, endFrame: 100, frames: 100,
                                     requiredFrames: 101, shortfallFrames: 1, mode: .shortByBroll)
        #expect(PictureWindowPolicy.isDeliverable(oneFrame, fps: fps, toleranceSeconds: tol),
                "1 帧差额被判不可导 ⇒ 会把今天能出的片子当场变红")
        let twoFrames = PictureWindow(startFrame: 0, endFrame: 100, frames: 100,
                                      requiredFrames: 102, shortfallFrames: 2, mode: .shortByBroll)
        #expect(!PictureWindowPolicy.isDeliverable(twoFrames, fps: fps, toleranceSeconds: tol))
        #expect(!PictureWindowPolicy.isDeliverable(oneFrame, fps: fps, toleranceSeconds: 0),
                "容差传 0 还判可导 ⇒ 这个入参没被用上，两处口径其实是写死的")
        // 无差额一律可导，且非法参数不许判成"可导"
        let ok = PictureWindow(startFrame: 0, endFrame: 100, frames: 100,
                               requiredFrames: 100, shortfallFrames: 0, mode: .unchanged)
        #expect(PictureWindowPolicy.isDeliverable(ok, fps: 0, toleranceSeconds: -1))
        #expect(!PictureWindowPolicy.isDeliverable(twoFrames, fps: .nan, toleranceSeconds: tol))
    }

    @Test("PW-13 容量口径：替换画面不能往原视频后面续，原视频才看源片末尾")
    func capacityDependsOnThePictureSource() {
        // 替换画面（合成片整段）只有自己那几帧。拿原视频长度当容量 ⇒ 裁出源里不存在的帧，
        // 症状是导出黑帧或 ffmpeg init 失败，而不是"某处报错"。
        let replaced = PictureWindowPolicy.capacityFrames(pictureStartFrame: 0, pictureEndFrame: 100,
                                                         pictureIsReplaced: true,
                                                         sourceDurationSeconds: 999, fps: 25, siblingStartFrame: nil)
        #expect(replaced == 100, "替换画面的容量跟着了原视频长度 ⇒ 会续出不存在的帧")
        let original = PictureWindowPolicy.capacityFrames(pictureStartFrame: 100, pictureEndFrame: 200,
                                                         pictureIsReplaced: false,
                                                         sourceDurationSeconds: 20, fps: 25, siblingStartFrame: nil)
        #expect(original == 400, "容量应是『画面起点→源片末尾』：20s@25fps=500 帧，起点在 100 ⇒ 400 帧")
        // 脏数据（源长换算出的末尾在画面尾帧之前）⇒ 地板把容量兜回画面自身长度
        let stale = PictureWindowPolicy.capacityFrames(pictureStartFrame: 100, pictureEndFrame: 200,
                                                       pictureIsReplaced: false,
                                                       sourceDurationSeconds: 6, fps: 25, siblingStartFrame: nil)
        #expect(stale == 100, "源长换算 150 帧 < 画面尾 200 帧时容量掉到 50 ⇒ 分镜被缩短，地板没生效")
        // 直接钉 capacityEndFrame 自己的契约（不靠下游地板兜）：V3 那把刀让它返回 0，
        // 下游的 max(…, pictureEndFrame) 会把它盖住 ⇒ 只从下游测就等于"这道工序坏了也没人知道"。
        #expect(PictureWindowPolicy.capacityEndFrame(pictureIsReplaced: false, pictureEndFrame: 200,
                                                     sourceDurationSeconds: 0, fps: 25, siblingStartFrame: nil) == 200)
        #expect(PictureWindowPolicy.capacityEndFrame(pictureIsReplaced: false, pictureEndFrame: 200,
                                                     sourceDurationSeconds: 20, fps: 0, siblingStartFrame: nil) == 200)
        #expect(PictureWindowPolicy.capacityEndFrame(pictureIsReplaced: true, pictureEndFrame: 137,
                                                     sourceDurationSeconds: 999, fps: 25, siblingStartFrame: nil) == 137)
        // 非正/非有限的源长与帧率：一律退成"画面自身"，不猜一个大数
        for bad in [(0.0, 25.0), (20.0, 0.0), (20.0, Double.nan), (Double.nan, 25.0)] {
            let v = PictureWindowPolicy.capacityFrames(pictureStartFrame: 0, pictureEndFrame: 100,
                                                       pictureIsReplaced: false,
                                                       sourceDurationSeconds: bad.0, fps: bad.1, siblingStartFrame: nil)
            #expect(v == 100, "\(bad) 应退成画面自身 100 帧，实得 \(v)")
        }
    }

    @Test("PW-14 生成侧与导出侧共用同一颗容量：容量秒数 == 窗口可用帧的秒数")    func generationAndExportShareOneCapacity() throws {
        // 超字闸吃"容量秒数"，导出吃"窗口帧数"。两者若不同源，就会出现
        // "闸按 12.4s 放行、窗口只有 12.0s"这种 TTS 已付费却导出装不下的形状。
        for fps in [24.0, 25.0, 29.97, 30.0] {
            for (start, end, src) in [(0, 100, 20.0), (37, 137, 5.2), (100, 200, 8.01)] {
                let cap = PictureWindowPolicy.capacityFrames(pictureStartFrame: start, pictureEndFrame: end,
                                                             pictureIsReplaced: false,
                                                             sourceDurationSeconds: src, fps: fps, siblingStartFrame: nil)
                let capacitySeconds = FrameTime.seconds(frame: cap, fps: fps)
                // 用一条刚好等于容量的配音去派生：窗口必须刚好用满容量、且判可交付
                let w = try #require(PictureWindowPolicy.derive(
                    startFrame: start, endFrame: end,
                    sourceEndFrame: start + cap, dubSeconds: capacitySeconds, fps: fps))
                #expect(w.frames == cap, "fps=\(fps) 画面[\(start),\(end)) 源长\(src)s：容量与窗口帧数不一致")
                #expect(PictureWindowPolicy.isDeliverable(w, fps: fps,
                        toleranceSeconds: DubLengthGate.measuredToleranceSeconds))
            }
        }
    }

    @Test("PW-11 派生失败的回退只有一件事可做：不扩窗，且不许顺手缩短画面")
    func fallbackNeverShrinksThePicture() {
        let f = PictureWindowPolicy.fallback(startFrame: 100, endFrame: 200)
        #expect(f.startFrame == 100 && f.endFrame == 200 && f.frames == 100)
        #expect(f.shortfallFrames == 0 && f.mode == .unchanged)
        // 倒挂输入也不许给出负帧数（下游 trim=start_frame=…:end_frame=… 会直接 init 失败）
        let bad = PictureWindowPolicy.fallback(startFrame: 200, endFrame: 100)
        #expect(bad.frames == 0 && bad.endFrame == 200)
    }

    @Test("PW-12 跨接缝不变式：生成侧放行的配音，导出侧必须判'装得下'")
    func gatePassingAudioIsAlwaysDeliverable() {
        // 这是 B 块唯一那条跨两道门的 e2e：超字闸（DubLengthGate，容差按**秒**）
        // 与窗口判定（PictureWindowPolicy，容差折成**帧**）分属两个模块。
        // 一旦两家的"差多少算能忍"不一致，就会出现：TTS 已经付费、音频已落库，
        // 导出时才发现装不下 —— 比一开始就拒更糟（费用已花、用户还得重来一遍）。
        // 遍历多个帧率与偏移，专门找那种"0.05s 在不同 fps 下折成不同帧数"的边角。
        let tol = DubLengthGate.measuredToleranceSeconds
        var firstBad = ""
        var cases = 0
        for fps in [24.0, 25.0, 29.97, 30.0, 60.0] {
            for startFrame in [0, 37] {
                let segmentFrames = 100
                let endFrame = startFrame + segmentFrames
                let pictureSeconds = FrameTime.seconds(frame: segmentFrames, fps: fps)
                // 源片末尾给三种：接得住 / 刚好在容差边上 / 明确接不住
                for extra in [4.0, 0.0, -2.0] {
                    let capacityEnd = PictureWindowPolicy.capacityEndFrame(
                        pictureIsReplaced: false, pictureEndFrame: endFrame,
                        sourceDurationSeconds: max(0.01, (Double(endFrame) / fps) + extra), fps: fps, siblingStartFrame: nil)
                    let capacityFrames = max(0, capacityEnd - startFrame)
                    let capacitySeconds = max(pictureSeconds,
                                              FrameTime.seconds(frame: capacityFrames, fps: fps))
                    for k in stride(from: 0.0, through: 1.2, by: 0.05) {
                        let audio = capacitySeconds + k - 0.5
                        guard audio > 0, firstBad.isEmpty else { continue }
                        cases += 1
                        let gate = DubLengthGate.postCheck(audioSeconds: audio, capacitySeconds: capacitySeconds)
                        guard gate == .pass else { continue }
                        let w = PictureWindowPolicy.derive(startFrame: startFrame, endFrame: endFrame,
                                                           sourceEndFrame: capacityEnd,
                                                           dubSeconds: audio, fps: fps)
                        guard let w else { firstBad = "fps=\(fps) derive 返回 nil（输入本应成立）"; continue }
                        if !PictureWindowPolicy.isDeliverable(w, fps: fps, toleranceSeconds: tol) {
                            firstBad = String(format: "fps=%.2f start=%d extra=%.1f audio=%.3f capSec=%.3f 差额=%d 帧",
                                              fps, startFrame, extra, audio, capacitySeconds, w.shortfallFrames)
                        }
                    }
                }
            }
        }
        print("PW-12 共比对 \(cases) 组（fps × 起点 × 源片余量 × 音频时长偏移）")
        #expect(firstBad.isEmpty,
                "闸放行却装不下 ⇒ 两家容差分叉，TTS 已付费的配音会在导出时废掉。首处：\(firstBad)")
    }

    @Test("PW-15 生成侧两处闸调用必须吃**容量**，不许被无声改回分镜时长")
    func generationGateMustReadCapacity() throws {
        // 为什么必须钉源码：B-2 放宽的是**参数**，不是阈值。调用点把 capacitySeconds 换回
        // target/pictureSeconds，B2-1 那种"函数级"判据一条都不会红 —— 它测的是闸本身，
        // 测不到 VM 传了什么。这类"纪律只能靠调用形状成立"的事，本仓一律用源码扫描钉
        // （先例：PromptTemplateGuardTests、FrameTimeSingleSourceGuardTests）。
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MixCutCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
            .appendingPathComponent("MixCut/ViewModels/DubbingViewModel.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let bad = gateCallsMissingCapacity(in: src)
        #expect(bad.isEmpty, "生成侧超字闸不再吃可续容量：\(bad)")
        // 反向对照：把两处实参换回分镜时长，这条判据必须能点名 —— 否则上面那格是恒绿的
        let mutated = src.replacingOccurrences(of: "capacitySeconds: capacitySeconds",
                                              with: "capacitySeconds: target")
        #expect(!gateCallsMissingCapacity(in: mutated).isEmpty,
                "把容量换成画面时长都不算违规 ⇒ 这条判据没牙")
        // 取样面自证：确实扫到了两处调用，而不是"一句都没匹配上"的假通过
        #expect(src.contains("DubLengthGate.preCheck(") && src.contains("DubLengthGate.postCheck("),
                "生成侧两个调用点少了一个 ⇒ 这条判据的取样面已经变了，要重读")
        // 第二道：容量必须**由 Core 那颗函数算出来**。V5 那把刀（`let capacitySeconds = pictureSeconds`）
        // 只改赋值不改调用形状，上面那条扫不出来 —— 这条才抓得住"基准被悄悄换回分镜时长"。
        #expect(src.contains("PictureWindowPolicy.capacitySeconds("),
                "生成侧不再用 Core 的容量口径 ⇒ 超字闸的基准可以随便漂移，B2-1 测的是闸不是这里")
        let reassigned = src.replacingOccurrences(of: "PictureWindowPolicy.capacitySeconds(",
                                                 with: "pictureSeconds // MUTANT: ")
        #expect(reassigned.contains("pictureSeconds // MUTANT"), "反向对照的替换没生效 ⇒ 下面那条断言是空跑的")
        #expect(!reassigned.contains("PictureWindowPolicy.capacitySeconds("),
                "被改坏的样本里仍能找到 Core 口径 ⇒ 这条判据的写法本身有问题")
    }

    @Test("PW-16 起点覆盖只能往前挪：往后挪会被夹回，且不静默改数")
    func startOverrideClampsToEarlierOnly() {
        // 没填覆盖 ⇒ 用画面自己的起点，未被夹
        #expect(PictureWindowPolicy.resolveWindowStart(override: nil, segmentStartFrame: 100)
                == (100, nil))
        // 往前挪（更小）⇒ 原样采纳
        #expect(Policy_start(40, 100) == (40, nil), "往前挪被夹了？")
        // 往后挪 ⇒ 夹回画面起点，并把**被夹前的原值**回传（界面要能说出来）
        #expect(Policy_start(160, 100) == (100, 160),
                "往后挪被直接采纳 ⇒ 本槽画面会盖进下一槽，同一段源画面在成片里连续出现两次")
        // 负数 ⇒ 夹到 0，且原值照样回传（差值表达会在这里退化成 0，等于没报告）
        #expect(Policy_start(-20, 100) == (0, -20), "负数被夹后没报告原值 ⇒ 界面上说不清'你填的不作数'")
        // 相等 ⇒ 不算被夹（别把"就填了原地"报成用户填错）
        #expect(Policy_start(100, 100) == (100, nil))
    }

    /// 短别名，只为让上面那几格一行读完一件事（元组比较写全名会把断言淹没在类型里）。
    private func Policy_start(_ override: Int, _ seg: Int)
        -> (startFrame: Int, clampedFrom: Int?) {
        PictureWindowPolicy.resolveWindowStart(override: override, segmentStartFrame: seg)
    }

    @Test("PW-17 挪起点之后，画面自身的长度仍是地板")
    func shiftingStartKeepsPictureLengthAsFloor() throws {
        // 起点从 100 挪到 40（前移 60 帧），配音 2s（50 帧）比画面短 ⇒ 窗口必须仍有 100 帧
        let w = try #require(PictureWindowPolicy.derive(
            startFrame: 40, endFrame: 140, sourceEndFrame: 500, dubSeconds: 2.0, fps: 25))
        #expect(w.frames == 100, "挪起点把画面缩短了 ⇒ 帧区间地板丢了")
        #expect(w.startFrame == 40 && w.endFrame == 140)
        // 配音更长时窗口按配音走
        let long = try #require(PictureWindowPolicy.derive(
            startFrame: 40, endFrame: 140, sourceEndFrame: 500, dubSeconds: 8.0, fps: 25))
        #expect(long.frames == 200 && long.endFrame == 240)
        // 前移把可续余量吃掉 ⇒ 差额要如实报出来（不是把画面缩回去）
        let tight = try #require(PictureWindowPolicy.derive(
            startFrame: 460, endFrame: 560, sourceEndFrame: 500, dubSeconds: 8.0, fps: 25))
        #expect(tight.mode == .shortByBroll && tight.shortfallFrames > 0,
                "起点前移导致容量不足却没报差额 ⇒ 后面会裁出不存在的帧")
    }

    @Test("PW-18 同素材下一格分镜的起点才是可续天花板（源片末尾不是）")
    func siblingShotCapsTheExtension() {
        // 画面 [100,200)、源片 20s@25=500 帧，但下一格分镜从 260 起 ⇒ 只能续到 260
        let capped = PictureWindowPolicy.capacityEndFrame(
            pictureIsReplaced: false, pictureEndFrame: 200,
            sourceDurationSeconds: 20, fps: 25, siblingStartFrame: 260)
        #expect(capped == 260, "可续上界没让位给下一格分镜 ⇒ 实得 \(capped)")
        // 紧贴（sibling <= 本段尾帧）⇒ 一格都不给续
        #expect(PictureWindowPolicy.capacityEndFrame(
            pictureIsReplaced: false, pictureEndFrame: 200,
            sourceDurationSeconds: 20, fps: 25, siblingStartFrame: 200) == 200,
            "紧贴下一格却还能续 ⇒ 同一段画面会在成片里连播两遍")
        // 兄弟起点落在本段内部（脏数据）⇒ 也不能拿它当上界把画面缩短
        #expect(PictureWindowPolicy.capacityEndFrame(
            pictureIsReplaced: false, pictureEndFrame: 200,
            sourceDurationSeconds: 20, fps: 25, siblingStartFrame: 150) == 200)
        // 源片更近时以源片为准
        let srcFirst = PictureWindowPolicy.capacityEndFrame(
            pictureIsReplaced: false, pictureEndFrame: 200,
            sourceDurationSeconds: 9, fps: 25, siblingStartFrame: 400)
        #expect(srcFirst == 225, "源片末尾比下一格更早时天花板取错了：实得 \(srcFirst)")
        // nil = 本段之后没有别的分镜 ⇒ 可续到源片末尾
        #expect(PictureWindowPolicy.capacityEndFrame(
            pictureIsReplaced: false, pictureEndFrame: 200,
            sourceDurationSeconds: 20, fps: 25, siblingStartFrame: nil) == 500)
        // 替换画面：既无后续帧也无兄弟可言
        #expect(PictureWindowPolicy.capacityEndFrame(
            pictureIsReplaced: true, pictureEndFrame: 137,
            sourceDurationSeconds: 999, fps: 25, siblingStartFrame: 900) == 137)
    }

    @Test("PW-19 窗口绝不越进下一格分镜的画面")
    func windowStopsBeforeSibling() throws {
        // 段1 [0,100)、下一格从 100 起、dub 8s ⇒ 无可续余量 ⇒ 如实报差额
        let glued = try #require(PictureWindowPolicy.derive(
            startFrame: 0, endFrame: 100, sourceEndFrame: 100, dubSeconds: 8.0, fps: 25))
        #expect(glued.endFrame == 100, "越进了下一格的画面 ⇒ 成片里同一段源画面连播两遍")
        #expect(glued.shortfallFrames == 100 && glued.mode == .shortByBroll)
        // 只有 40 帧余量时续满就停，剩下的照实报
        let partial = try #require(PictureWindowPolicy.derive(
            startFrame: 0, endFrame: 100, sourceEndFrame: 140, dubSeconds: 8.0, fps: 25))
        #expect(partial.endFrame == 140 && partial.shortfallFrames == 60)
    }

    @Test("PW-20 差额文案唯一口径：帧进秒出，两位小数")
    func shortfallTextIsCanonical() {
        // 卡片预警与导出失败清单都吃这一颗；两边各写一套 format 就是两个数。
        #expect(PictureWindowPolicy.shortfallText(shortfallFrames: 50, fps: 25) == "配音差 2.00s")
        #expect(PictureWindowPolicy.shortfallText(shortfallFrames: 1, fps: 25) == "配音差 0.04s")
    }
}

/// 找出"调用超字闸却没把可续容量传进去"的位置（返回违规说明，空数组即全部合规）。
///
/// ⚠️ 判的是**实参值**，不是参数标签：`capacitySeconds: target` 这种写法标签仍在、值却是分镜时长，
/// 只查标签的判据对它是瞎的（第一版就是这么写的，被自己那条反向对照当场抓出来）。
/// 所以钉的是 `capacitySeconds: capacitySeconds` 这整个形状 —— 同时挡住"标签改回去"
/// 和"值改回去"两种退化。代价：局部变量若改名，这里要同轮改，报错信息会直接说出这一点。
/// 调用是跨行的（`preCheck(text:` 换行后才是实参），所以向后看两行。
private func gateCallsMissingCapacity(in src: String) -> [String] {
    let lines = src.components(separatedBy: "\n")
    var bad: [String] = []
    for (i, line) in lines.enumerated() {
        guard line.contains("DubLengthGate.preCheck(") || line.contains("DubLengthGate.postCheck(") else { continue }
        let window = lines[i...min(i + 2, lines.count - 1)].joined(separator: " ")
        if !window.contains("capacitySeconds: capacitySeconds") {
            bad.append("第 \(i + 1) 行没把可续容量喂进闸（要找『capacitySeconds: capacitySeconds』这个形状）")
        }
    }
    return bad
}
