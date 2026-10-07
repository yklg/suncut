import Foundation
import Testing
@testable import MixCutCore

/// `KnowledgeDocumentFilter.enabledIDs` 过滤口径单测：
/// 替代原两层链 #Predicate（CoreData SQL 生成器无法翻译、抛 ObjC 异常致 abort）。
struct KnowledgeRetrievalFilterTests {

    @Test("仅「本产品且启用」文档通过；禁用/跨产品/悬空 product 边全部排除")
    func filtersByProductAndEnabled() {
        let target = UUID()
        let otherProduct = UUID()

        let good = UUID()
        let disabled = UUID()
        let crossProduct = UUID()
        let dangling = UUID()

        let inputs = [
            KnowledgeDocumentFilter.Input(
                id: good, isEnabled: true, productID: target),
            KnowledgeDocumentFilter.Input(
                id: disabled, isEnabled: false, productID: target),
            KnowledgeDocumentFilter.Input(
                id: crossProduct, isEnabled: true, productID: otherProduct),
            KnowledgeDocumentFilter.Input(
                id: dangling, isEnabled: true, productID: nil),
        ]

        let result = KnowledgeDocumentFilter.enabledIDs(
            inputs, targetProductID: target)

        #expect(result == [good],
                "只应保留本产品启用文档，实得 \(result)")
    }

    @Test("空输入返回空集，不崩")
    func emptyInput() {
        #expect(KnowledgeDocumentFilter.enabledIDs(
            [], targetProductID: UUID()).isEmpty)
    }

    @Test("同产品多份启用文档全部保留且结果去重")
    func multipleEnabled() {
        let target = UUID()
        let a = UUID()
        let b = UUID()
        let inputs = [
            KnowledgeDocumentFilter.Input(id: a, isEnabled: true, productID: target),
            KnowledgeDocumentFilter.Input(id: a, isEnabled: true, productID: target),
            KnowledgeDocumentFilter.Input(id: b, isEnabled: true, productID: target),
        ]
        #expect(KnowledgeDocumentFilter.enabledIDs(inputs, targetProductID: target) == [a, b])
    }
}
