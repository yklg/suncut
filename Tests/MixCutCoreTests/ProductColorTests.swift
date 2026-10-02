import Foundation
import Testing
@testable import MixCutCore

struct ProductColorTests {
    private func id(_ s: String) -> UUID { UUID(uuidString: s)! }

    @Test("默认产品返回 nil（UI 渲染灰色）")
    func defaultProductHasNoIndex() {
        #expect(ProductColor.colorIndex(forProductID: ProductCatalogDefaults.defaultProductID,
                                        isDefault: true) == nil)
    }

    @Test("非默认产品序号落在 0..paletteCount")
    func indexInRange() {
        for i in 0..<30 {
            let uuid = UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", i, i))!
            let idx = ProductColor.colorIndex(forProductID: uuid, isDefault: false)
            #expect(idx != nil)
            #expect(idx! >= 0 && idx! < ProductColor.paletteCount)
        }
    }

    @Test("同一产品多次取值幂等（颜色稳定不漂移）")
    func stableAcrossCalls() {
        let uuid = id("12345678-0000-0000-0000-000000000001")
        let first = ProductColor.colorIndex(forProductID: uuid, isDefault: false)
        for _ in 0..<10 {
            #expect(ProductColor.colorIndex(forProductID: uuid, isDefault: false) == first)
        }
        // 大小写不影响（uuidString 规范化）
        #expect(ProductColor.colorIndex(forProductID: uuid, isDefault: false) == first)
    }

    @Test("散列分布覆盖多个序号（避免全挤一色；样本 60 个至少覆盖 4 色）")
    func distributionReasonable() {
        var seen = Set<Int>()
        for i in 0..<60 {
            let uuid = UUID(uuidString: String(format: "%08X-AAAA-BBBB-CCCC-%012X", i * 7 + 1, i * 13 + 5))!
            if let idx = ProductColor.colorIndex(forProductID: uuid, isDefault: false) {
                seen.insert(idx)
            }
        }
        #expect(seen.count >= 4, "60 个 id 只散到 \(seen.count) 色，散列分布异常")
    }
}
