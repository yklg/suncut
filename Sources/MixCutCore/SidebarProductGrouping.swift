import Foundation

// ============================================================================
// 侧栏「产品 → 项目」分组投影（纯值类型 + 纯函数，零 SwiftData 依赖）。
//
// 本文件锁定的接口（实现必须逐字满足，SidebarProductGroupingTests 依赖这些形状）：
//   public struct SidebarProductRef: Sendable { id, name, isDefault, createdAt }
//   public struct SidebarProjectRef: Sendable { id, productID: UUID?, updatedAt, isArchived }
//   public struct SidebarProductGroup: Sendable { productID, projectIDs }
//   public enum SidebarProductGrouping {
//       static func groups(products: [SidebarProductRef],
//                         projects: [SidebarProjectRef]) -> [SidebarProductGroup]
//   }
//
// 规则：
//   G1 只输出含 ≥1 个**活跃**（非 archived）项目的产品；
//   G2 默认产品（isDefault，或项目 productID=nil 归属的产品哨兵）固定第一组；
//   G3 非默认产品按「组内最近项目 updatedAt」降序；
//   G4 组内项目按 updatedAt 降序；
//   G5 archived 项目不进任何组；
//   G6 平局确定性：产品间 max(updatedAt) 相等 → product.createdAt 降序 → productID.uuidString 降序；
//      组内 updatedAt 相等 → projectID.uuidString 降序。**不依赖输入数组下标**；
//   G7 项目 productID=nil 或指向不存在产品 → 归入默认产品；没有默认产品实体时不产出该组。
//
// 非空洞性论证：
//   - 用「含项目的产品下标顺序」排 → G3/G6 红；
//   - archived 不过滤 → G1/G5 红；
//   - productID=nil 项目丢失 → G7 红；
//   - 组内按数组顺序 → G4/G6 红。
// ============================================================================

public struct SidebarProductRef: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let isDefault: Bool
    public let createdAt: Date
    public init(id: UUID, name: String, isDefault: Bool, createdAt: Date) {
        self.id = id; self.name = name; self.isDefault = isDefault; self.createdAt = createdAt
    }
}

public struct SidebarProjectRef: Equatable, Sendable {
    public let id: UUID
    /// nil = backfill 前的存量项目，按 G7 归默认产品
    public let productID: UUID?
    public let updatedAt: Date
    public let isArchived: Bool
    public init(id: UUID, productID: UUID?, updatedAt: Date, isArchived: Bool) {
        self.id = id; self.productID = productID; self.updatedAt = updatedAt; self.isArchived = isArchived
    }
}

public struct SidebarProductGroup: Equatable, Sendable {
    public let productID: UUID
    public let projectIDs: [UUID]
}

public enum SidebarProductGrouping {

    public static func groups(products: [SidebarProductRef],
                              projects: [SidebarProjectRef]) -> [SidebarProductGroup] {
        // 产品索引；同名（可能重名）不影响分组，id 唯一
        let productByID = Dictionary(products.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let defaultProduct = products.first { $0.isDefault }

        // 活跃项目按归属产品分桶（G5 先滤 archived；G7 nil/悬空 → 默认产品）
        var projectIDsByProduct: [UUID: [SidebarProjectRef]] = [:]
        for project in projects where !project.isArchived {
            let ownerID: UUID?
            if let pid = project.productID, productByID[pid] != nil {
                ownerID = pid
            } else {
                ownerID = defaultProduct?.id
            }
            guard let pid = ownerID else { continue }   // G7：连默认产品实体都没有 → 不出组
            projectIDsByProduct[pid, default: []].append(project)
        }

        // 组装有项目的产品组
        var groups: [(product: SidebarProductRef, projects: [SidebarProjectRef])] = []
        for (pid, refs) in projectIDsByProduct {
            guard let product = productByID[pid] else { continue }
            groups.append((product, refs))
        }

        // G2 默认置顶；G3/G6 非默认按组内最近项目降序，平局 createdAt 降序 → productID 降序
        groups.sort { lhs, rhs in
            if lhs.product.isDefault != rhs.product.isDefault { return lhs.product.isDefault }
            if lhs.product.isDefault { return false }   // 两个默认不应出现（isDefault 至多一个）
            let lLatest = lhs.projects.map(\.updatedAt).max() ?? .distantPast
            let rLatest = rhs.projects.map(\.updatedAt).max() ?? .distantPast
            if lLatest != rLatest { return lLatest > rLatest }
            if lhs.product.createdAt != rhs.product.createdAt {
                return lhs.product.createdAt > rhs.product.createdAt
            }
            return lhs.product.id.uuidString > rhs.product.id.uuidString
        }

        return groups.map { entry in
            // G4/G6 组内 updatedAt 降序，平局 projectID 降序
            let ordered = entry.projects.sorted { a, b in
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id.uuidString > b.id.uuidString
            }
            return SidebarProductGroup(productID: entry.product.id,
                                       projectIDs: ordered.map(\.id))
        }
    }
}
