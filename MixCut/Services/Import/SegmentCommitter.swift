import Foundation
import SwiftData

/// 一次 AI 分区落库的结果，供调用方写留痕（谁改写了素材、改成了几段）。
struct PartitionCommit {
    /// 规划层实际生效的规则；空数组表示原样放行。
    let appliedRules: [SegmentationRule]
    /// 规划层动手之前 AI 返回的条数 —— 合并后这个数就反推不出来了。
    let aiSegmentCount: Int
    /// 最终落库的条数（含极短碎片的兜底合并）。
    let committedCount: Int
}

/// `Segment` 的唯一生产者。
///
/// 为什么要收成一个类型：同一个实体的「建对象 / 搬字 / 帧化 / 删除」此前散在 5 处
/// （`ImportViewModel` 三处 + `DebugSelfTest` 两处），于是任何一条分镜规则都必须逐点插一遍，
/// 首跑与「重跑分析」因此分叉 —— 重跑路径会绕过只插在首跑上的规则。
/// 本文件是全仓唯一允许直接构造 `Segment` 的地方，由
/// `scripts/check_ai_completeness_guards.sh` 的构造点判据钉住。
///
/// 边界：这里只做**建与改实体**，不碰控制流。失败态语义、取消检查、是否删旧段、
/// 用哪个 `AIAnalysisService` 实例，仍由调用方（导入链与重试链）各自决定 ——
/// 那两处流水线目前的行为差异是真实的，收口生产者不等于统一它们。
@MainActor
struct SegmentCommitter {

    private let boundaryOptimizer = BoundaryOptimizerService()

    /// 落库一条 AI 分区：边界吸附 → 规划层决定是否并组 → 建段帧化 → 极短碎片兜底合并。
    ///
    /// 返回 `PartitionCommit`，调用方据此写留痕（本来几段、成了几段、动了哪条规则）。
    /// 这里不碰 `Video` —— 一个函数同时改两张表，出问题就说不清是谁写的。
    func commitAIPartition(
        from analysisResult: AISegmentationResult,
        asr: TranscriptionResult,
        localAnalysis: VideoLocalAnalysis,
        video: Video,
        context: ModelContext,
        planConfig: SegmentationPlanConfig = SegmentationPlanConfig()
    ) -> PartitionCommit {
        let boundaries = analysisResult.segments.map(\.endTime)
        let (optimizedBoundaries, _) = boundaryOptimizer.optimize(
            boundaries: boundaries,
            asrSentences: asr.sentences,
            localAnalysis: localAnalysis
        )

        // 顺序不能反：先把每条 AI 分镜换算成「吸附后的区间」，再交给规划层决定要不要并。
        // 若先并再吸附，边界优化会把刚攒够的组又拆开。
        var timings: [SegmentTiming] = []
        for (i, aiSeg) in analysisResult.segments.enumerated() {
            var adjustedEnd = i < optimizedBoundaries.count ? optimizedBoundaries[i] : aiSeg.endTime
            let adjustedStart: Double
            if i == 0 {
                adjustedStart = 0.0
            } else if i - 1 < optimizedBoundaries.count {
                adjustedStart = optimizedBoundaries[i - 1]
            } else {
                adjustedStart = aiSeg.startTime
            }
            if i == analysisResult.segments.count - 1 && video.duration > 0 {
                adjustedEnd = video.duration
            }
            timings.append(SegmentTiming(start: adjustedStart, end: adjustedEnd,
                                         scoreFromModel: aiSeg.scoreFromModel))
        }

        let plan = SegmentationPlanner.plan(segments: timings, duration: video.duration, in: planConfig)
        let groups = SegmentationPlanner.intervals(of: plan, segments: timings, duration: video.duration)

        let asrWords = asr.words
        var createdSegments: [Segment] = []
        for (i, group) in groups.enumerated() {
            let members = group.indices.map { analysisResult.segments[$0] }
            let first = members[0]

            let extractedText = Self.extractTextFromASR(
                words: asrWords, startTime: group.start, endTime: group.end
            )
            let fallbackText = members.map(\.text).filter { !$0.isEmpty }.joined()
            let finalText = extractedText.isEmpty ? fallbackText : extractedText

            // 并组后的标签口径：类型与关键词取并集（保序去重），
            // 位置与理由取组内首条 —— 首条最接近这一段开头的语气，尾巴那条不该决定整体定位。
            // 质量分取**最小**：一段的可用性由最差的那半决定，取平均会让合并段冒充高分段。
            var mergedTypes: [SemanticType] = []
            for raw in members.flatMap(\.types) {
                let normalized = Self.normalizeSemanticType(raw)
                if !mergedTypes.contains(normalized) { mergedTypes.append(normalized) }
            }
            var mergedKeywords: [String] = []
            for keyword in members.flatMap(\.keywords) where !mergedKeywords.contains(keyword) {
                mergedKeywords.append(keyword)
            }

            let globalIndex = String(format: "seg_%03d", i + 1)
            let segment = Segment(
                segmentIndex: globalIndex,
                startTime: group.start,
                endTime: group.end,
                text: finalText,
                semanticTypes: mergedTypes,
                positionType: Self.normalizePositionType(first.position),
                qualityScore: members.map { $0.dataQuality.score }.min() ?? 8.0,
                // 台词是从整片听写的字级结果切下来的 ⇒ fullVideoSlice；
                // 切不到字、退回 AI 建议文本时**不猜来源**，记"未记录"而不是某个引擎。
                textSource: extractedText.isEmpty ? .unknownLegacy : .fullVideoSlice
            )
            segment.qualityReasoning = first.dataQuality.reasoning
            segment.keywords = mergedKeywords
            segment.video = video
            // 分镜继承视频导入时选定的默认来源（自拍/搬运/AI）；之后可在素材库逐条改
            segment.setSource(video.defaultSource)
            context.insert(segment)
            // 帧化：把秒边界 round 成帧号作为真相（永不差帧）
            if video.fps > 0 {
                segment.setFrameRange(
                    startFrame: FrameTime.frame(seconds: group.start, fps: video.fps),
                    endFrame: FrameTime.frame(seconds: group.end, fps: video.fps),
                    fps: video.fps
                )
            }
            createdSegments.append(segment)
        }

        Self.mergeShortSegments(&createdSegments,
                                minDuration: planConfig.minSegmentSeconds,
                                context: context)
        return PartitionCommit(appliedRules: plan.appliedRules,
                               aiSegmentCount: analysisResult.segments.count,
                               committedCount: createdSegments.count)
    }

    /// 覆盖整片的单段（自建分镜上传路径；后续「整片保留」规则也接这里）。
    ///
    /// 原 `ImportViewModel.importSelfSegments` 的建段段原样搬入。注意它**不设** `textSource`
    /// （用 `Segment.init` 的 `.unknownLegacy`），台词由调用方随后 `setText(_:source: .uploadedClip)` 写入 ——
    /// 自建分镜是"整听用户自己上传的那个文件"，标成 `fullVideoSlice` 会让来源说谎。
    func commitWholeVideo(
        for video: Video,
        source: SegmentSource,
        context: ModelContext
    ) -> Segment {
        let fps = video.fps > 0 ? video.fps : 30
        let endFrame = max(1, Int((video.duration * fps).rounded()))
        let seg = Segment(segmentIndex: "seg_001", startTime: 0, endTime: video.duration,
                          text: "", semanticTypes: [], positionType: .opening)
        seg.video = video
        seg.setFrameRange(startFrame: 0, endFrame: endFrame, fps: fps)
        seg.thumbnailPath = video.thumbnailPath
        seg.setSource(source)
        context.insert(seg)
        return seg
    }

    /// 拆分产物：从供体段继承标签、关键词与来源的新段。
    ///
    /// 原 `ImportViewModel.splitSegment` 的 B 段构造原样搬入。供体段自身的收缩（A 段）
    /// 仍由调用方做 —— 那属于"改已有实体"，不是新建。
    func commitSplitRemainder(
        of donor: Segment,
        segmentIndex: String,
        startFrame: Int,
        endFrame: Int,
        fps: Double,
        context: ModelContext
    ) -> Segment {
        let b = Segment(segmentIndex: segmentIndex,
                        startTime: 0, endTime: 0, text: "",
                        semanticTypes: donor.semanticTypes, positionType: donor.positionType,
                        qualityScore: donor.qualityScore)
        b.video = donor.video
        b.setFrameRange(startFrame: startFrame, endFrame: endFrame, fps: fps)
        b.keywords = donor.keywords
        // 拆出的新段继承原段来源（同一素材切两半，来源不变）
        b.setSource(donor.source)
        context.insert(b)
        return b
    }

    /// 自检 / IT 现场用的最小裸段：只写自有列 + 同视频边，不帧化、不设来源。
    ///
    /// 与生产路径的区别是刻意的（见 `DebugSelfTest` 原注释"只写自有列 + 同视频边"），
    /// 但构造点仍必须收在这里，否则「App 层裸构造 Segment 为 0」这条判据要开豁免名单。
    func commitBare(
        segmentIndex: String,
        startTime: Double,
        endTime: Double,
        text: String,
        semanticTypes: [SemanticType],
        positionType: PositionType,
        video: Video,
        context: ModelContext
    ) -> Segment {
        let seg = Segment(segmentIndex: segmentIndex, startTime: startTime, endTime: endTime,
                          text: text, semanticTypes: semanticTypes, positionType: positionType)
        seg.video = video
        context.insert(seg)
        return seg
    }

    // MARK: - 搬入的私有实现（原属 ImportViewModel，均只被上面这几个入口使用）

    /// 合并过短的分镜到相邻分镜
    private static func mergeShortSegments(
        _ segments: inout [Segment],
        minDuration: Double,
        context: ModelContext
    ) {
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            guard seg.duration < minDuration, segments.count > 1 else {
                i += 1
                continue
            }

            if i > 0 {
                let prev = segments[i - 1]
                if let fps = prev.video?.fps, fps > 0 {
                    prev.setFrameRange(startFrame: prev.startFrame, endFrame: seg.endFrame, fps: fps)
                } else {
                    prev.endTime = seg.endTime
                }
                // 搬字：合并后的台词来源记 boundaryShift，**不继承被删那段的来源**
                // （接口上没有"邻段来源"这个入参，结构上就继承不了；红线 R8）
                prev.setText(prev.text + seg.text, source: .boundaryShift)
                var kw = prev.keywords
                for k in seg.keywords where !kw.contains(k) { kw.append(k) }
                prev.keywords = kw
                context.delete(seg)
                segments.remove(at: i)
            } else if segments.count > 1 {
                let next = segments[1]
                if let fps = next.video?.fps, fps > 0 {
                    next.setFrameRange(startFrame: seg.startFrame, endFrame: next.endFrame, fps: fps)
                } else {
                    next.startTime = seg.startTime
                }
                next.setText(seg.text + next.text, source: .boundaryShift)
                context.delete(seg)
                segments.remove(at: 0)
            } else {
                i += 1
            }
        }
    }

    /// 根据时间范围从 ASR words 中精确提取台词
    private static func extractTextFromASR(
        words: [ASRWord],
        startTime: Double,
        endTime: Double
    ) -> String {
        let matched = words.filter { w in
            let center = (w.start + w.end) / 2
            return center >= startTime && center < endTime
        }
        let text = matched.map(\.word).joined()
        var cleaned = text
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned
    }

    /// 归一化 AI 返回的语义类型字符串
    private static func normalizeSemanticType(_ raw: String) -> SemanticType {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let exact = SemanticType(rawValue: cleaned) {
            return exact
        }

        let mapping: [(keywords: [String], type: SemanticType)] = [
            (["噱头", "hook", "开场", "引入", "吸引"], .hook),
            (["痛点", "pain", "问题", "烦恼"], .painPoint),
            (["产品方案", "solution", "产品介绍", "成分", "功能"], .solution),
            (["效果展示", "effect", "result", "对比", "变化"], .results),
            (["信任背书", "social proof", "用户评价", "品牌", "背书", "见证"], .socialProof),
            (["价格对比", "price", "性价比", "价格"], .priceAnchor),
            (["活动福利", "promotion", "优惠", "福利", "折扣", "赠品"], .promotion),
            (["行动号召", "call to action", "cta", "购买", "下单", "直播间"], .callToAction),
            (["产品定位", "positioning", "适用", "人群"], .productPositioning),
            (["产品使用教育", "usage", "使用方法", "教育", "使用场景"], .usageEducation),
            (["过渡", "transition", "衔接", "转场"], .transition),
        ]

        let lower = cleaned.lowercased()
        for (keywords, type) in mapping {
            if keywords.contains(where: { lower.contains($0.lowercased()) }) {
                return type
            }
        }

        MixLog.error(" 未识别的语义类型: \"\(raw)\"，降级为 .transition")
        return .transition
    }

    /// 归一化位置类型
    private static func normalizePositionType(_ raw: String) -> PositionType {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = PositionType(rawValue: cleaned) { return exact }
        let lower = cleaned.lowercased()
        if lower.contains("开头") || lower.contains("opening") { return .opening }
        if lower.contains("结尾") || lower.contains("ending") { return .ending }
        return .middle
    }
}
