import Foundation
import Testing
@testable import MixCutCore

/// `SegmentHeaderLayout` 降级序列契约测试。
///
/// 钉住的规则：
/// - 每档首元素恒为 icon（任何宽度下头部标识不消失）；
/// - 每档是前一档的严格前缀（降级只减尾部、不换序、不增元素）；
/// - 末档 = [.icon]（任意宽度兜底）。
struct SegmentHeaderLayoutTests {

    @Test("每档首元素恒为 .icon")
    func everyTierStartsWithIcon() {
        for tier in SegmentHeaderLayout.tiers {
            #expect(tier.first == .icon)
        }
    }

    @Test("每档是上一档的严格前缀（只减尾部、不换序）")
    func eachTierIsStrictPrefixOfPrevious() {
        let tiers = SegmentHeaderLayout.tiers
        #expect(tiers.count >= 2)
        for index in tiers.indices.dropFirst() {
            let previous = tiers[index - 1]
            let current = tiers[index]
            #expect(current.count == previous.count - 1)
            #expect(Array(previous.prefix(current.count)) == current)
        }
    }

    @Test("末档 = [.icon]（任意宽度兜底）")
    func lastTierIsIconOnly() {
        #expect(SegmentHeaderLayout.tiers.last == [.icon])
    }
}
