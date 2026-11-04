import Testing
@testable import MixCutCore

@Test("FMX-19 类别硬上限为 24，超限文案只在 25 类起出现")
func categoryHardLimitIsTwentyFour() {
    #expect(FolderMixLimits.maxCategories == 24)
    #expect(FolderMixLimits.categoryLimitMessage(count: 24) == nil)
    #expect(FolderMixLimits.categoryLimitMessage(count: 25)?.contains("24") == true)
    #expect(FolderMixLimits.categoryLimitMessage(count: 25)?.contains("25") == true)
}
