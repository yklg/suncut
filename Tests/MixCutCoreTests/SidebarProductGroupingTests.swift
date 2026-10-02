import Foundation
import Testing
@testable import MixCutCore

/// 侧栏产品分组投影测试（G1-G7）。夹具：产品 id(50+)、项目 id(100+)，时间为相对 t0 偏移。
struct SidebarProductGroupingTests {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
    }
    private let t0 = 812_267_661.0

    private func product(_ n: Int, name: String? = nil, default isDefault: Bool = false,
                         created offset: Double = 0) -> SidebarProductRef {
        SidebarProductRef(id: id(50 + n), name: name ?? "产品\(n)",
                          isDefault: isDefault,
                          createdAt: Date(timeIntervalSinceReferenceDate: t0 + offset))
    }
    private func project(_ n: Int, product p: Int?, updated offset: Double,
                         archived: Bool = false) -> SidebarProjectRef {
        SidebarProjectRef(id: id(100 + n),
                          productID: p == nil ? nil : id(50 + p!),
                          updatedAt: Date(timeIntervalSinceReferenceDate: t0 + offset),
                          isArchived: archived)
    }

    private func ids(_ groups: [SidebarProductGroup], at i: Int) -> [UUID] { groups[i].projectIDs }

    @Test("G1 只出现含活跃项目的产品；空产品不产出组")
    func onlyNonEmptyProducts() {
        let groups = SidebarProductGrouping.groups(
            products: [product(0, default: true), product(1), product(2)],
            projects: [project(0, product: 0, updated: 10), project(1, product: 1, updated: 5)])
        #expect(groups.map(\.productID) == [id(50), id(51)])
    }

    @Test("G2 默认产品固定第一组，即使其他组项目更新更近")
    func defaultProductFirst() {
        let groups = SidebarProductGrouping.groups(
            products: [product(0, default: true), product(1, created: 0)],
            projects: [project(0, product: 0, updated: 1),
                       project(1, product: 1, updated: 999)])
        #expect(groups.first?.productID == id(50))
    }

    @Test("G3 非默认产品按组内最近项目 updatedAt 降序")
    func nonDefaultOrderedByLatestProject() {
        let groups = SidebarProductGrouping.groups(
            products: [product(0, default: true), product(1), product(2)],
            projects: [project(0, product: 0, updated: 0),
                       project(1, product: 1, updated: 10),
                       project(2, product: 2, updated: 50),
                       project(3, product: 1, updated: 5)])  // 产品1最近=10 < 产品2的50
        let nonDefault = groups.filter { $0.productID != id(50) }
        #expect(nonDefault.map(\.productID) == [id(52), id(51)])
    }

    @Test("G4 组内项目按 updatedAt 降序")
    func projectsDescendingWithinGroup() {
        let groups = SidebarProductGrouping.groups(
            products: [product(0, default: true)],
            projects: [project(0, product: 0, updated: 10),
                       project(1, product: 0, updated: 30),
                       project(2, product: 0, updated: 20)])
        #expect(ids(groups, at: 0) == [id(101), id(102), id(100)])
    }

    @Test("G5 archived 项目全部过滤（哪怕该产品只剩归档项也不出组）")
    func archivedFiltered() {
        let groups = SidebarProductGrouping.groups(
            products: [product(0, default: true), product(1)],
            projects: [project(0, product: 0, updated: 10, archived: false),
                       project(1, product: 1, updated: 99, archived: true)])
        #expect(groups.map(\.productID) == [id(50)])
    }

    @Test("G6 平局确定性：乱序输入结果一致（产品间/组内平局均按 id 降序）")
    func deterministicTieBreaks() {
        // 三个产品各一个项目且同刻；同产品内两个项目同刻
        let projects: [SidebarProjectRef] = [
            project(3, product: 2, updated: 10),
            project(0, product: 0, updated: 10),
            project(2, product: 1, updated: 10),
            project(1, product: 0, updated: 10),
        ].shuffled()  // 故意打乱
        let inputProducts = [product(0, default: true, created: 0), product(1, created: 0), product(2, created: 0)]
        let a = SidebarProductGrouping.groups(products: inputProducts, projects: projects)
        let b = SidebarProductGrouping.groups(products: inputProducts.reversed(), projects: projects.reversed())
        #expect(a == b)
        // 默认产品组第一；组内两个项目 id 降序
        #expect(a.first?.productID == id(50))
        #expect(a.first?.projectIDs == [id(101), id(100)])
        // 非默认产品平局按 productID 降序：52 在 51 前
        #expect(a.dropFirst().map(\.productID) == [id(52), id(51)])
    }

    @Test("G7 productID=nil 与悬空产品 id 都归默认产品；无默认实体时不出组")
    func nilOrDanglingProductGoesDefault() {
        let withDefault = SidebarProductGrouping.groups(
            products: [product(0, default: true), product(1)],
            projects: [
                SidebarProjectRef(id: id(100), productID: nil,
                                  updatedAt: Date(timeIntervalSinceReferenceDate: t0), isArchived: false),
                SidebarProjectRef(id: id(101), productID: id(999),  // 不存在的产品
                                  updatedAt: Date(timeIntervalSinceReferenceDate: t0 + 1), isArchived: false),
            ])
        #expect(withDefault.count == 1)
        #expect(Set(withDefault[0].projectIDs) == [id(100), id(101)])

        let noDefault = SidebarProductGrouping.groups(
            products: [product(1)],
            projects: [SidebarProjectRef(id: id(100), productID: nil,
                                         updatedAt: Date(timeIntervalSinceReferenceDate: t0),
                                         isArchived: false)])
        #expect(noDefault.isEmpty)
    }

    @Test("空输入返回空组")
    func emptyInput() {
        #expect(SidebarProductGrouping.groups(products: [], projects: []).isEmpty)
    }
}
