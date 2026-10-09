import Testing
@testable import MixCutCore

/// 分区审计的契约测试。核心主张是**两条轴不许互相冒充**：
/// 提案侧的"超长即丢段签名"与分区侧的"超长只是违反应用上限"必须各自独立成立。
@Suite("分区审计 SegmentPartitionAudit")
struct SegmentPartitionAuditTests {

    private func iv(_ pairs: [(Double, Double)]) -> [SegmentPartitionAudit.Interval] {
        pairs.map { SegmentPartitionAudit.Interval(start: $0.0, end: $0.1) }
    }

    @Test("TC-Q1 铺满全片、段长合规的分区无缺口")
    func healthyPartitionIsSilent() {
        let gaps = SegmentPartitionAudit.audit(intervals: iv([(0, 5), (5, 12), (12, 18)]), videoDuration: 18)
        #expect(gaps.isEmpty, "实际：\(SegmentPartitionAudit.summary(of: gaps))")
    }

    @Test("TC-Q2 超上限只报 tooLong，不产生任何截断语义")
    func tooLongIsReportedAsRuleViolationOnly() {
        let gaps = SegmentPartitionAudit.audit(intervals: iv([(0, 20)]), videoDuration: 20)
        #expect(gaps == [.tooLong(index: 0, seconds: 20, limit: SegmentationCompleteness.promptSegmentLimit)])
    }

    @Test("TC-Q3 与提案审计对同一形状给出不同结论（两条轴真的分开了）")
    func twoAxesDisagreeByDesign() {
        let intervals = iv([(0, 6), (6, 30)])
        let partition = SegmentPartitionAudit.audit(intervals: intervals, videoDuration: 30)
        // 同一形状送进提案审计：第二段 24s 超 18s 且它是尾段、一路吞到片长
        // ⇒ 在提案侧被读成"模型丢段的特征签名"（那是它唯一的用途）
        let proposal = SegmentationCompleteness.audit(SegmentationAuditInput(
            declaredSegmentCount: nil, videoDuration: 30,
            segments: intervals.map { SegmentTiming(start: $0.start, end: $0.end) },
            skippedUnparsableCount: 0))
        #expect(SegmentationCompleteness.showsTruncationSignature(proposal))
        // 分区侧只报规则违规一条，绝不产出"漏交付"这种结论
        #expect(partition.count == 1)
        #expect(partition.contains { if case .tooLong(let i, let sec, _) = $0 { return i == 1 && abs(sec - 24) < 0.005 }; return false })
    }

    @Test("TC-Q4 重叠、空洞、头尾不覆盖是各自独立的轴（互斥断言）")
    func shapeAxesAreIndependent() {
        let overlap = SegmentPartitionAudit.audit(intervals: iv([(0, 6), (5.5, 12)]), videoDuration: 12)
        #expect(overlap.contains { if case .overlapping = $0 { return true }; return false })
        #expect(!overlap.contains { if case .holeBetween = $0 { return true }; return false })

        let hole = SegmentPartitionAudit.audit(intervals: iv([(0, 5), (6, 12)]), videoDuration: 12)
        #expect(hole.contains { if case .holeBetween(_, _, let s) = $0 { return abs(s - 1) < 0.005 }; return false })
        #expect(!hole.contains { if case .overlapping = $0 { return true }; return false })

        let head = SegmentPartitionAudit.audit(intervals: iv([(0.5, 12)]), videoDuration: 12)
        #expect(head.contains { if case .notCoveringHead = $0 { return true }; return false })
        #expect(!head.contains { if case .notCoveringTail = $0 { return true }; return false })
    }

    @Test("TC-Q5 尾段差半帧以内算合规（帧号才是真相源）")
    func tailAllowsSubFrameSlack() {
        // 真实库实测：片长 58.8145s，帧化后尾段终点 58.8s ⇒ 差 0.0145s（不足半帧）。
        // 四段、每段都 ≤18s，免得太长那条把这一条的结论盖掉。
        let ok = iv([(0, 15), (15, 30), (30, 45), (45, 58.8)])
        let gaps = SegmentPartitionAudit.audit(intervals: ok, videoDuration: 58.8145)
        #expect(gaps.isEmpty, "实际：\(SegmentPartitionAudit.summary(of: gaps))")
        let far = iv([(0, 15), (15, 30), (30, 45), (45, 58.7)])
        let farGaps = SegmentPartitionAudit.audit(intervals: far, videoDuration: 58.8145)
        #expect(farGaps.count == 1)
        #expect(farGaps.contains { if case .notCoveringTail = $0 { return true }; return false })
    }

    @Test("TC-Q6 18.0 合规、18.006 违规（沿用既有容差口径）")
    func toleranceMatchesProposalAudit() {
        #expect(SegmentPartitionAudit.audit(intervals: iv([(0, 18)]), videoDuration: 18).isEmpty)
        let over = SegmentPartitionAudit.audit(intervals: iv([(0, 18.006)]), videoDuration: 18.006)
        #expect(over.contains { if case .tooLong = $0 { return true }; return false })
    }

    @Test("TC-Q7 空分区单独成案，不混进形状缺口")
    func emptyPartitionIsItsOwnCase() {
        let gaps = SegmentPartitionAudit.audit(intervals: [], videoDuration: 10)
        #expect(gaps == [.empty])
        #expect(SegmentPartitionAudit.summary(of: gaps).contains("一条分镜都没有"))
    }

    @Test("TC-Q8 上限可注入：换 limit 结论就变（不许把 18 抄成第二个常量）")
    func limitIsInjected() {
        let tight = SegmentPartitionAudit.audit(intervals: iv([(0, 10)]), videoDuration: 10, maxSeconds: 9.5)
        #expect(tight.contains { if case .tooLong = $0 { return true }; return false })
        let loose = SegmentPartitionAudit.audit(intervals: iv([(0, 10)]), videoDuration: 10, maxSeconds: 10.5)
        #expect(loose.isEmpty)
    }
}
