import Foundation
import SwiftData

/// 产品（第一层分类）。一个产品可以包含多个项目；项目建项时选择归属产品。
///
/// 本期生命周期（非目标见实施计划）：只在建项目弹窗里创建/选择；
/// 不做重命名 UI、删除、项目在产品间移动，因此这里**故意不挂 cascade 关系**——
/// 产品侧不持有项目数组，项目归属由 `Project.product`（optional to-one）表达，
/// 误删一个 Product 不会级联删掉用户项目（归属回退 nil → 读侧回退默认产品）。
@Model
final class Product: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// true = 系统内置「默认产品」（哨兵，见 ProductCatalogDefaults.defaultProductID）。
    /// 存量数据与未选择归属的项目都归它；全库至多一个。
    var isBuiltInDefault: Bool

    init(id: UUID = UUID(), name: String, isBuiltInDefault: Bool = false) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.isBuiltInDefault = isBuiltInDefault
    }
}
