import Foundation
import Testing
@testable import MixCutCore

struct SegmentSourceTests {
    @Test("S1 四个 case 的 rawValue 往返一致")
    func rawValueRoundTrip() {
        for source in SegmentSource.allCases {
            #expect(SegmentSource(rawValue: source.rawValue) == source)
        }
    }

    @Test("S2 未知 raw 安全回退未分类（不 fatalError、不猜搬运）")
    func unknownRawFallsBackToUnclassified() {
        #expect(SegmentSource(persisted: "some_future_source") == .unclassified)
        #expect(SegmentSource(rawValue: "nonsense") == nil)
        #expect(SegmentSource(persisted: "nonsense") == .unclassified)
    }

    @Test("S3 displayName 四个非空且互异")
    func displayNamesComplete() {
        let names = SegmentSource.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == SegmentSource.allCases.count)
        #expect(Set(names) == ["自拍", "搬运", "AI生产", "未分类"])
    }

    @Test("S4 存量迁移契约：unclassified.rawValue == 空串")
    func unclassifiedRawIsEmptyString() {
        // Segment.sourceRaw 列默认 ""；空串必须解析成「未分类」这个合法 case，
        // 而不是被当成脏数据、更不能回退成 curated（否则全部存量分镜静默变搬运）。
        #expect(SegmentSource.unclassified.rawValue == "")
        #expect(SegmentSource(rawValue: "") == .unclassified)
        #expect(SegmentSource(persisted: "") == .unclassified)
    }

    @Test("S5 case 数锁定 = 4：新增来源时强制同步芯片/右键/批量/导出/配色五处")
    func caseCountLocked() {
        #expect(SegmentSource.allCases.count == 4,
                "新增来源后请同步：抽屉来源芯片、素材库筛选芯片、右键标记菜单、批量标记 Menu、导出统计与配色")
    }
}
