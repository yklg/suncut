import Foundation
import SwiftData
import Testing

@testable import SunCut

// ============================================================================
// TAP · 每点一颗标签的实测成本（计划 R6 欠的那个数字）
//
// ## 为什么要量
//
// 本轮把 Inspector 的「直写模型 + try? save()」收敛进 `ViewModel.toggleSemanticType`，
// 而那颗方法尾部会 `applyFilter()` → `recomputeAllDerived()`（全量重算 countByType、
// groupedSegments、segmentByID）。改前那条直写路径**不做**这件事。
// ⇒ 这是一次"净退化换正确性"，计划里要求按两档规模实测，不许拍脑袋写"可接受"。
//
// ## 这台仪器量的是哪一半，明确说
//
// 它量的是 **模型侧每 tap 的开销**（写模型 + 落库 + 全量派生重算），走的是生产那颗
// `toggleSemanticType`，不是复制一份算法来量 —— 复制品没有取证力。
//
// ⚠️ 它**量不到** SwiftUI 网格的重绘成本。那一半要靠真机（`scripts/measure_nav_blank.sh`
// 那类帧尺子，或 Mac2 黑盒环）才能取数，本文件不假装覆盖它。
//
// ## 台架纪律
//   · 计时判据在繁忙机器上会抖 ⇒ 断言只放一条**极宽**的病态上限，
//     真正的读数以 `print` 打到输出里，由人读数，不由机器判"快/慢"。
//   · 两档规模按"即将下结论的那个字段"分层：35 段（用户当前项目就是这个量级）与 480 段。
//     只在一档上测过一次就外推，是本轮已经犯过的抽样偏差。
// ============================================================================

private let tapFps = 25.0

/// 造 count 段可显示分镜（台词非空、单标签，好让每次 tap 都真的改动数据）。
///
/// ⚠️ 必须把 `ModelContainer` 一起返回并由调用方持有：容器一旦离开作用域就被释放，
/// 之后再读 `Segment` 的 SwiftData 生成访问器（这次是 `startTime`，被 applyFilter 的
/// 排序比较器读到）会踩进 SwiftData 内部断言 ⇒ SIGTRAP。
/// 同仓的 `bfkProject` / `bgcGraph` 都返回容器，不是巧合。
@MainActor
private func tapStore(count: Int) throws
    -> (Project, [Segment], ModelContext, ModelContainer) {
    let container = try ModelContainer(
        for: Schema(versionedSchema: AppSchemaV1.self),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    let ctx = container.mainContext
    let project = Project(name: "TAP-项目")
    ctx.insert(project)
    let video = Video(name: "TAP-源", localPath: "/tmp/tap-fake.mov")
    video.duration = Double(count) * 2
    video.fps = tapFps
    video.width = 1080
    video.height = 1920
    ctx.insert(video)
    _ = ProjectVideo.associate(project: project, video: video, in: ctx)

    var segs: [Segment] = []
    segs.reserveCapacity(count)
    for i in 0..<count {
        let seg = Segment(segmentIndex: String(format: "seg_%04d", i + 1),
                          startTime: Double(i) * 2, endTime: Double(i) * 2 + 2,
                          text: "台词 \(i)", semanticTypes: [.painPoint],
                          positionType: .middle)
        seg.startFrame = FrameTime.frame(seconds: Double(i) * 2, fps: tapFps)
        seg.endFrame = FrameTime.frame(seconds: Double(i) * 2 + 2, fps: tapFps)
        seg.video = video
        ctx.insert(seg)
        segs.append(seg)
    }
    try ctx.save()
    return (project, segs, ctx, container)
}

/// 在同一个库上反复「加一颗标签 / 再摘掉」，返回每次 tap 的平均毫秒。
@MainActor
private func tapMillis(segments: [Segment], context: ModelContext, rounds: Int) -> Double {
    let vm = SegmentLibraryViewModel()
    vm.setModelContext(context)
    vm.segments = segments
    vm.applyFilter()

    let target = segments[0]
    var total = 0.0
    for round in 0..<rounds {
        let type: SemanticType = round.isMultiple(of: 2) ? .hook : .results
        let start = ContinuousClock.now
        vm.toggleSemanticType(for: target, type: type)
        // 只取一次差值再拆秒/纳秒：分两次 `duration(to:)` 量的是两段不同的时间。
        let elapsed = start.duration(to: .now)
        let c = elapsed.components
        total += Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    return total / Double(rounds) * 1000
}

@Suite("TAP · 每点一颗标签的实测成本")
struct SegmentTapCostMeasurementTests {

    @Test("TAP-1 两档规模的每 tap 模型侧开销（读数打屏，不由机器判快慢）")
    @MainActor
    func measureTapCostAtTwoScales() throws {
        // 35 段：用户当前项目就是这个量级（截图里「35 / 35 个分镜」）。
        let small = try tapStore(count: 35)
        let smallMs = withExtendedLifetime(small) {
            tapMillis(segments: small.1, context: small.2, rounds: 40)
        }

        // 480 段：计划要求的那一档"≥300 段的副本"，取到能看出线性/超线性。
        let large = try tapStore(count: 480)
        let largeMs = withExtendedLifetime(large) {
            tapMillis(segments: large.1, context: large.2, rounds: 40)
        }

        print("TAP 读数（模型侧：写模型 + safeSave + recomputeAllDerived）")
        print("  35 段 ⇒ \(String(format: "%.3f", smallMs)) ms / tap")
        print("  480 段 ⇒ \(String(format: "%.3f", largeMs)) ms / tap")
        print("  段数 ×13.7，耗时比 \(String(format: "%.2f", largeMs / max(smallMs, 0.0001))) ×")

        // ⚠️ `print` 在**托管测试**里不落 xcodebuild 日志（实测：日志只有 23 行、无 stdout），
        // 所以读数必须写进文件才取得到。写在沙盒的 temporaryDirectory 里 ——
        // 同仓的 bfkScratch 也用它，沙盒允许。
        let readout = """
        TAP 读数（模型侧：写模型 + safeSave + recomputeAllDerived）
          35 段 ⇒ \(String(format: "%.3f", smallMs)) ms / tap
          480 段 ⇒ \(String(format: "%.3f", largeMs)) ms / tap
          段数 ×13.7，耗时比 \(String(format: "%.2f", largeMs / max(smallMs, 0.0001))) ×
        """
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("twr-tap-readout.txt")
        try? readout.write(to: out, atomically: true, encoding: .utf8)

        // 只拦病态：真退化到"点一下卡一下"的量级（>120ms/tap）才红。
        // 这条断言的存在是为了抓"重算被写成 O(n²) 或加了同步 IO"，不是为了评性能好坏。
        let detail = "480 段下每 tap " + String(format: "%.2f", largeMs)
            + " ms，已到人眼可感的量级 ⇒ 按计划 R6 把 recomputeAllDerived 拆成 "
            + "recomputeCounts + recomputeGroups，tap 只调前者"
        #expect(largeMs < 120, "\(detail)")
    }
}
