import Foundation
import Testing
@testable import MixCutCore

/// `SegmentationCompleteness.audit` 的契约测试（计划 §10.3 组 2，TC-28…TC-34）
///
/// 钉住的规则（计划 §2、§4 步骤 1-b）：
/// - R1 `segments` 为空 ⇒ 只出 `.noSegments`，不再叠其它结论
/// - R2 实收 < 自报 ⇒ `.countShortfall`
/// - R3 自报为 nil **或 ≤0** ⇒ 一律"不可断言"，不得判"不少"（宽容解码把缺失解成 0）
/// - R4 单段时长 > `maxSegmentSeconds + tolerance` ⇒ `.segmentTooLong`；**等于上限合规**
/// - R5 相邻段交叠 > tolerance ⇒ `.overlappingSegments`
/// - R6 补出来的 `qualityScore` ⇒ 只算"字段不可信"；整条段被解码器丢弃 ⇒ 才算"可证丢失"（两条轴独立）
/// - R7 `coversTail` 仅当"是最后一段且贴着片尾"；**只有落在尾段的超长**才构成截断特征签名
///    （中间段超长可能是模型无视 18 秒规则，不该被当成截断误杀）
/// - R8 超长判定：> limit + tolerance；**等于上限合规**
///
/// 非空洞性对应：TC-30 是正向对照（干净结果必须返回空缺口列表）；TC-34 断言
/// `hasUntrustedFields == true` 而 `isProvablyIncomplete == false`，若两条轴被写成同一条，该测试即挂。
///
/// 样本诚实标注：线上真实样本只有"正文 0 字符"这一形状（已两次复现）。
/// TC-28 用的"6 段 / 尾段吞到 141.8 秒"是**按 `createSegments` 的产出形状构造**的 fixture，
/// 不是从某次真实响应里抄来的，故此处明写，免得日后把它当成线上证据。
@Suite("SegmentationCompleteness 分镜完整性审计")
struct SegmentationCompletenessTests {

    private func seg(_ start: Double, _ end: Double, scoreFromModel: Bool = true) -> SegmentTiming {
        SegmentTiming(start: start, end: end, scoreFromModel: scoreFromModel)
    }

    /// 把秒边界列表摊成"首尾相接"的分镜 —— `createSegments` 的真实产出形状就是这样
    private func contiguous(_ cuts: [Double], duration: Double, lastEndIsDuration: Bool = true) -> [SegmentTiming] {
        var out: [SegmentTiming] = []
        var start = 0.0
        for (i, end) in cuts.enumerated() {
            let isLast = i == cuts.count - 1
            out.append(seg(start, isLast && lastEndIsDuration ? duration : end))
            start = end
        }
        return out
    }

    // MARK: - TC-28

    @Test("TC-28 自报 9 实收 6 且尾段吞到片尾：同时报条数缺口与超长（S3 + R7）")
    func shortfallWithTailSwallow() {
        // 141.8 秒全片，只回了 6 段；第 6 段一路吞到片尾
        let cuts = [12.0, 26.0, 40.0, 55.0, 68.0, 141.8]
        let input = SegmentationAuditInput(declaredSegmentCount: 9,
                                           videoDuration: 141.8,
                                           segments: contiguous(cuts, duration: 141.8))
        let gaps = SegmentationCompleteness.audit(input)

        #expect(gaps.contains(.countShortfall(declared: 9, received: 6)))
        #expect(gaps.contains(.segmentTooLong(index: 5, seconds: 141.8 - 68.0,
                                              limit: 18.0, coversTail: true)))
        #expect(SegmentationCompleteness.isProvablyIncomplete(gaps))
        #expect(SegmentationCompleteness.violatesSegmentationRules(gaps))
        #expect(SegmentationCompleteness.summary(of: gaps).contains("吞到片尾"))
    }

    // MARK: - TC-29

    @Test("TC-29 自报缺失或为 0 ⇒ 判'不可断言'，绝不判'不少'（R3）")
    func undeclaredIsNotAssertion() {
        let clean = contiguous([10.0, 20.0, 30.0], duration: 30.0)
        let nilDeclared = SegmentationAuditInput(declaredSegmentCount: nil, videoDuration: 30, segments: clean)
        let zeroDeclared = SegmentationAuditInput(declaredSegmentCount: 0, videoDuration: 30, segments: clean)

        #expect(SegmentationCompleteness.audit(nilDeclared).isEmpty)
        #expect(SegmentationCompleteness.audit(zeroDeclared).isEmpty)
        #expect(!SegmentationCompleteness.isProvablyIncomplete(SegmentationCompleteness.audit(zeroDeclared)))
    }

    // MARK: - TC-30

    @Test("TC-30 自报==实收且各段合规 ⇒ 无缺口（正向对照 + 承认本判据必要非充分）")
    func cleanResultHasNoGaps() {
        let input = SegmentationAuditInput(declaredSegmentCount: 4,
                                           videoDuration: 38.5,
                                           segments: contiguous([9.0, 18.0, 27.0, 38.5], duration: 38.5))
        let gaps = SegmentationCompleteness.audit(input)
        #expect(gaps.isEmpty)
        // 诚实边界：模型"少报了自报值"时本判据抓不到，只有 R4 那条规则与 transport 证据抓得到
        #expect(!SegmentationCompleteness.isProvablyIncomplete(gaps))
    }

    // MARK: - TC-31

    @Test("TC-31 单段时长三点法：17.99 与 18.0 合规，18.1 违规（R4 + 外部经验边界三点）")
    func segmentLengthBoundary() {
        for (seconds, shouldFlag) in [(17.99, false), (18.0, false), (18.1, true)] as [(Double, Bool)] {
            let cuts = [seconds]
            let input = SegmentationAuditInput(declaredSegmentCount: nil,
                                               videoDuration: seconds,
                                               segments: contiguous(cuts, duration: seconds))
            let gaps = SegmentationCompleteness.audit(input)
            let flagged = gaps.contains { if case .segmentTooLong = $0 { return true }; return false }
            #expect(flagged == shouldFlag, "\(seconds)s → 期望违规=\(shouldFlag)")
        }
    }

    // MARK: - TC-32

    @Test("TC-32 相邻段重叠 0.5 秒 ⇒ 违规；首尾相接（重叠 0）不违规（R5）")
    func overlappingSegments() {
        let touching = SegmentationAuditInput(declaredSegmentCount: nil, videoDuration: 30,
                                              segments: [seg(0, 15), seg(15, 30)])
        #expect(SegmentationCompleteness.audit(touching).isEmpty)

        let overlap = SegmentationAuditInput(declaredSegmentCount: nil, videoDuration: 30,
                                             segments: [seg(0, 15.5), seg(15.0, 30.0)])
        let gaps = SegmentationCompleteness.audit(overlap)
        #expect(gaps.contains(.overlappingSegments(firstIndex: 0, secondIndex: 1, overlapSeconds: 0.5)))
        #expect(SegmentationCompleteness.violatesSegmentationRules(gaps))
    }

    // MARK: - TC-33

    @Test("TC-33 段数为 0 ⇒ 单独成案，不得返回'无违规'（R1 + P3）")
    func zeroSegments() {
        let input = SegmentationAuditInput(declaredSegmentCount: 9, videoDuration: 141.8, segments: [])
        let gaps = SegmentationCompleteness.audit(input)
        #expect(gaps == [.noSegments])
        #expect(SegmentationCompleteness.isProvablyIncomplete(gaps))
        #expect(SegmentationCompleteness.summary(of: gaps).contains("一条分镜都没收到"))
    }

    // MARK: - TC-34

    @Test("TC-34 补出来的质量分：只算'字段不可信'，不算'可证丢失'（R6，两条轴独立）")
    func synthesizedScoresAreSeparateAxis() {
        let input = SegmentationAuditInput(declaredSegmentCount: 3,
                                           videoDuration: 30,
                                           segments: [seg(0, 10, scoreFromModel: false),
                                                      seg(10, 20),
                                                      seg(20, 30)])
        let gaps = SegmentationCompleteness.audit(input)

        #expect(gaps.contains(.synthesizedQualityScores(indices: [0])))
        #expect(SegmentationCompleteness.hasUntrustedFields(gaps))
        #expect(!SegmentationCompleteness.isProvablyIncomplete(gaps))   // 独立轴
        #expect(!SegmentationCompleteness.violatesSegmentationRules(gaps))
    }

    @Test("TC-34b 有整条段解码时被丢弃 ⇒ 算可证丢失")
    func skippedItemsAreProvableLoss() {
        let input = SegmentationAuditInput(declaredSegmentCount: nil,
                                           videoDuration: 30,
                                           segments: [seg(0, 15), seg(15, 30)],
                                           skippedUnparsableCount: 2)
        let gaps = SegmentationCompleteness.audit(input)
        #expect(gaps.contains(.skippedUnparsableSegments(count: 2)))
        #expect(SegmentationCompleteness.isProvablyIncomplete(gaps))
        #expect(SegmentationCompleteness.hasUntrustedFields(gaps))
    }

    @Test("TC-34c 超长落在中间段 vs 落在尾段：只有后者算截断特征签名")
    func truncationSignatureOnlyForTail() {
        let midLong = SegmentationAuditInput(declaredSegmentCount: nil, videoDuration: 60,
                                            segments: [seg(0, 25), seg(25, 45), seg(45, 60)])
        let midGaps = SegmentationCompleteness.audit(midLong)
        #expect(SegmentationCompleteness.violatesSegmentationRules(midGaps))
        #expect(!SegmentationCompleteness.showsTruncationSignature(midGaps))

        let tailLong = SegmentationAuditInput(declaredSegmentCount: nil, videoDuration: 60,
                                             segments: [seg(0, 20), seg(20, 60)])
        #expect(SegmentationCompleteness.showsTruncationSignature(
            SegmentationCompleteness.audit(tailLong)))
    }

    // MARK: - 规则常量归属

    @Test("单段上限是入参不是硬编码：调用方可覆盖，默认值仍对齐 prompt 的 18 秒")
    func limitIsInjectable() {
        #expect(SegmentationCompleteness.promptSegmentLimit == 18)
        let input = SegmentationAuditInput(declaredSegmentCount: nil,
                                           videoDuration: 40,
                                           maxSegmentSeconds: 30,
                                           segments: contiguous([25.0, 40.0], duration: 40.0))
        // 15s 段在默认 18s 下合规；25s 段在 30s 上限下也合规
        #expect(SegmentationCompleteness.audit(input).isEmpty)
    }
}
