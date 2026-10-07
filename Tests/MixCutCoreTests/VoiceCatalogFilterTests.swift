import Foundation
import Testing
@testable import MixCutCore

/// VoiceCatalogFilter 纯逻辑（VF-1 ~ VF-7）+ CosyVoice 目录标签完整性。
struct VoiceCatalogFilterTests {

    private let catalog = CosyVoiceCatalog.all

    @Test func VF1_blankFilter_returnsAllInOriginalOrder() {
        let result = VoiceCatalogFilter.filter(catalog, selectedTags: [], query: "")
        #expect(result.map(\.id) == catalog.map(\.id))
        // 目录实际条数以代码为准（百炼宣传 80，当前接入 76；新增条目时本测试随 VF6 全量标签校验自动覆盖）。
        #expect(result.count == catalog.count)
        #expect(catalog.count >= 70)
    }

    @Test func VF2_whitespaceQuery_isSameAsEmpty() {
        let result = VoiceCatalogFilter.filter(catalog, selectedTags: [], query: "   \n ")
        #expect(result.count == catalog.count)
    }

    @Test func VF3_queryMatchesSubstringCaseInsensitiveAcrossFields() {
        // displayName 子串
        #expect(VoiceCatalogFilter.filter(catalog, selectedTags: [], query: "龙樱晓").map(\.id) == ["longyingxiao"])
        // 英文 id 大小写不敏感
        #expect(VoiceCatalogFilter.filter(catalog, selectedTags: [], query: "BELLA").map(\.id) == ["loongbella_v2"])
        // summary 子串（「美猴王」只命中角色条目）
        #expect(VoiceCatalogFilter.filter(catalog, selectedTags: [], query: "美猴王").map(\.id) == ["longhouge"])
        // 无命中
        #expect(VoiceCatalogFilter.filter(catalog, selectedTags: [], query: "不存在的音色xyz").isEmpty)
    }

    @Test func VF4_tagsUseIntersection_genderAndCommerceStack() {
        let femaleCommerce = VoiceCatalogFilter.filter(catalog, selectedTags: [.female, .commerce], query: "")
        // 前 10 带货位中的女声恰为 6 条
        #expect(femaleCommerce.count == 6)
        #expect(Set(femaleCommerce.map(\.id)) == [
            "longyingxiao", "longanxuan", "longanping", "longxiaochun_v2",
            "longanrou", "longhua_v2",
        ])
        // 互斥性别同选 → 必空（交集语义，防 chips 组合出错）
        #expect(VoiceCatalogFilter.filter(catalog, selectedTags: [.female, .male], query: "").isEmpty)
    }

    @Test func VF5_commerceChip_isExactlyTheFirstTen() {
        let commerce = VoiceCatalogFilter.filter(catalog, selectedTags: [.commerce], query: "")
        #expect(Set(commerce.map(\.id)) == Set(catalog.prefix(10).map(\.id)))
        #expect(commerce.count == 10)
    }

    @Test func VF6_everyCatalogVoiceHasExactlyOneGenderTag() {
        // 漏标 → chip 筛不到；多选 → 性别 chips 交集/计数全错。全量逐条强制。
        let offenders = catalog.filter { !VoiceCatalogFilter.hasExactlyOneGenderTag($0) }
        #expect(offenders.isEmpty, "缺少或多重性别标签的音色：\(offenders.map(\.id))")
    }

    @Test func VF7_genderBucketsCoverAllAndExpectedSizes() {
        let children = catalog.filter { $0.tags.contains(.child) }
        let characters = catalog.filter { $0.tags.contains(.character) }
        let male = catalog.filter { $0.tags.contains(.male) }
        let female = catalog.filter { $0.tags.contains(.female) }
        #expect(children.map(\.id).sorted() == [
            "longhuhu", "longjielidou_v2", "longke_v2",
            "longling_v2", "longniuniu", "longshanshan",
        ])
        #expect(Set(characters.map(\.id)) == [
            "longjiqi", "longhouge", "libai_v2", "kabuleshen_v2",
        ])
        // 四类恰好铺满全目录（性别互斥，commerce 不占名额）
        #expect(male.count + female.count + children.count + characters.count == catalog.count)
        #expect(male.count > 0 && female.count > 0)
    }
}
