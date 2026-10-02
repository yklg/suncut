import Foundation
import Testing
@testable import MixCutCore

/// SegmentPickerCatalog 投影测试（C1-C7）。
/// 夹具段：产品 id(50+)、项目 id(100+)、视频 id(200+)、分镜 id(300+)、关联行 id(1+)。
struct SegmentPickerCatalogTests {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
    }
    private let t0 = 812_267_661.0

    private func product(_ n: Int, _ name: String = "", isDefault: Bool = false) -> CatalogProduct {
        CatalogProduct(id: id(50 + n), name: name.isEmpty ? "产品\(n)" : name, isDefault: isDefault)
    }
    private let defaultProduct = CatalogProduct(id: ProductCatalogDefaults.defaultProductID,
                                               name: ProductCatalogDefaults.defaultProductName,
                                               isDefault: true)
    private func project(_ n: Int, product p: Int?) -> CatalogProject {
        CatalogProject(id: id(100 + n), productID: p == nil ? nil : id(50 + p!))
    }
    private func video(_ n: Int, ownerProject o: Int?) -> CatalogVideo {
        CatalogVideo(id: id(200 + n), ownerProjectID: o == nil ? nil : id(100 + o!))
    }
    private func seg(_ n: Int, video v: Int?, raw: String) -> CatalogSegment {
        CatalogSegment(id: id(300 + n), videoID: v == nil ? nil : id(200 + v!), sourceRaw: raw)
    }
    private func link(_ pv: Int, project p: Int, video v: Int, at offset: Double) -> ProjectVideoAssociation {
        ProjectVideoAssociation(pvID: id(pv), projectID: id(100 + p), videoID: id(200 + v),
                                addedAt: Date(timeIntervalSinceReferenceDate: t0 + offset))
    }

    private func run(_ targetProduct: Int,
                     products: [CatalogProduct],
                     projects: [CatalogProject],
                     videos: [CatalogVideo],
                     segments: [CatalogSegment],
                     links: [ProjectVideoAssociation]) -> CatalogResult {
        SegmentPickerCatalog.entries(forProduct: id(50 + targetProduct),
                                     products: products, projects: projects,
                                     videos: videos, segments: segments,
                                     associations: links)
    }

    // MARK: C1

    @Test("C1 可见集合 = 该产品项目关联视频并集；重复链接自防御去重")
    func visibleUnionDedup() {
        let r = run(0,
                    products: [product(0)],
                    projects: [project(0, product: 0), project(1, product: 1)],
                    videos: [video(0, ownerProject: 0), video(1, ownerProject: 1)],
                    segments: [seg(0, video: 0, raw: "curated"), seg(1, video: 1, raw: "curated")],
                    links: [
                        link(1, project: 0, video: 0, at: 10),
                        link(2, project: 0, video: 0, at: 5),   // 同 project+video 重复
                        link(3, project: 1, video: 1, at: 8),
                    ])
        // 产品 0 只应看到视频 200 一次
        #expect(r.entries.map(\.videoID) == [id(200)])
    }

    // MARK: C2

    @Test("C2 借用对称性：主属产品不标借用；其他产品标 BorrowedInfo(产品 id/name)")
    func borrowedSymmetry() {
        let products = [product(0, "祛痘"), product(1, "牙贴")]
        let projects = [project(0, product: 0), project(1, product: 1)]
        let videos = [video(0, ownerProject: 0)]
        let segments = [seg(0, video: 0, raw: "curated")]
        // 视频 200 属产品 0 的项目 100，同时被产品 1 的项目 101 借用
        let links = [link(1, project: 0, video: 0, at: 5),
                     link(2, project: 1, video: 0, at: 9)]

        let atHome = run(0, products: products, projects: projects, videos: videos,
                         segments: segments, links: links)
        let borrowedView = run(1, products: products, projects: projects, videos: videos,
                               segments: segments, links: links)

        #expect(atHome.entries.first?.borrowed == nil)
        #expect(borrowedView.entries.first?.borrowed?.productID == id(50))
        #expect(borrowedView.entries.first?.borrowed?.productName == "祛痘")
    }

    // MARK: C3

    @Test("C3 ownerProject 悬空 → 回退最早关联项目产品；主属在他处时借用标他处")
    func danglingOwnerFallback() {
        let products = [product(0), product(1)]
        let projects = [project(0, product: 0), project(1, product: 1)]
        // 视频 ownerProject=109（不存在的项目）；最早关联是产品 0 的 100，同时被产品 1 的 101 关联
        let videos = [video(0, ownerProject: 9)]
        let segments = [seg(0, video: 0, raw: "self_shot")]
        let links = [link(1, project: 0, video: 0, at: 5),
                     link(2, project: 1, video: 0, at: 9)]

        let atEarliest = run(0, products: products, projects: projects, videos: videos,
                             segments: segments, links: links)
        let atOther = run(1, products: products, projects: projects, videos: videos,
                          segments: segments, links: links)

        #expect(atEarliest.entries.first?.borrowed == nil, "回退到最早关联产品 0，在产品 0 不算借用")
        #expect(atOther.entries.first?.borrowed?.productID == id(50), "在产品 1 看，主属回退为产品 0")
    }

    // MARK: C4

    @Test("C4 计数守恒：四类之和 == entries 总数（含未分类，口径不扣置灰）")
    func countsSumToEntries() {
        let segments: [CatalogSegment] = [
            seg(0, video: 0, raw: "self_shot"), seg(1, video: 0, raw: "self_shot"),
            seg(2, video: 0, raw: "curated"), seg(3, video: 0, raw: "curated"),
            seg(4, video: 0, raw: "curated"),
            seg(5, video: 0, raw: "ai_generated"),
            seg(6, video: 0, raw: ""),
        ]
        let r = run(0,
                    products: [product(0)],
                    projects: [project(0, product: 0)],
                    videos: [video(0, ownerProject: 0)],
                    segments: segments,
                    links: [link(1, project: 0, video: 0, at: 1)])
        #expect(r.entries.count == 7)
        #expect(r.counts[.selfShot] == 2)
        #expect(r.counts[.curated] == 3)
        #expect(r.counts[.aiGenerated] == 1)
        #expect(r.counts[.unclassified] == 1)
        #expect(SegmentSource.allCases.allSatisfy { r.counts[$0] != nil })
        #expect(r.counts.values.reduce(0, +) == r.entries.count)
    }

    // MARK: C5

    @Test("C5 异常输入不崩：悬挂分镜丢弃、空视频 0 entries、默认产品名内建回退")
    func robustness() {
        let projects = [project(0, product: 0)]
        let videos = [video(0, ownerProject: 0), video(1, ownerProject: 0)]
        // 300 是 videoID=nil 的悬挂分镜；301 属于可见的 201
        let segments = [CatalogSegment(id: id(300), videoID: nil, sourceRaw: "curated"),
                        seg(1, video: 1, raw: "curated")]
        let r = run(0,
                    products: [product(0)],          // 不含默认产品
                    projects: projects,
                    videos: videos,
                    segments: segments,
                    links: [link(1, project: 0, video: 0, at: 1),
                            link(2, project: 0, video: 1, at: 2)])
        #expect(r.entries.map(\.segmentID) == [id(301)], "悬挂分镜丢弃；空视频 200 无 entry；顺序先 201")
        #expect(r.counts.values.reduce(0, +) == 0 + r.entries.count && r.entries.count == 1)
    }

    @Test("C5b 项目无 productID（backfill 前）归默认产品；默认产品不在 products 表也能解析")
    func nilProductProjectGoesDefault() {
        let r = SegmentPickerCatalog.entries(
            forProduct: ProductCatalogDefaults.defaultProductID,
            products: [],                                  // 默认产品行都还没建
            projects: [CatalogProject(id: id(100), productID: nil)],
            videos: [video(0, ownerProject: 0)],
            segments: [seg(0, video: 0, raw: "")],
            associations: [ProjectVideoAssociation(pvID: id(1), projectID: id(100), videoID: id(200),
                                                   addedAt: Date(timeIntervalSinceReferenceDate: t0))])
        #expect(r.entries.count == 1)
        #expect(r.entries.first?.borrowed == nil)
    }

    // MARK: C6

    @Test("C6 顺序守恒：按(addedAt,projectID,videoID)升序，乱序输入与视频内分镜顺序稳定")
    func orderingDeterministic() {
        let projects = [project(0, product: 0), project(1, product: 0)]
        let videos = [video(0, ownerProject: 0), video(1, ownerProject: 0), video(2, ownerProject: 1)]
        // 200@t20(p101) / 201@t10(p100) / 202@t10(p100) → 期望视频序 201,202,200
        let links = [link(1, project: 1, video: 0, at: 20),
                     link(2, project: 0, video: 2, at: 10),
                     link(3, project: 0, video: 1, at: 10)]
        let segments = [
            seg(2, video: 0, raw: "curated"),
            seg(0, video: 1, raw: "curated"), seg(1, video: 1, raw: "curated"),
            seg(3, video: 2, raw: "curated"),
        ]
        let r = run(0, products: [product(0)], projects: projects, videos: videos,
                    segments: segments, links: links)
        // entries 按分镜计（201 有两个分镜）；首现视频序必须是 201,202,200
        var firstSeen = Set<UUID>()
        let firstVideoOrder = r.entries.map(\.videoID).filter { firstSeen.insert($0).inserted }
        #expect(firstVideoOrder == [id(201), id(202), id(200)])
        // 视频内分镜按输入顺序（201 的两个分镜 id 输入序 300,301）
        #expect(r.entries.prefix(2).map(\.segmentID) == [id(300), id(301)])
    }

    // MARK: C7

    @Test("C7 多产品计数互不串：产品 1 的私有视频不出现在产品 0")
    func productIsolation() {
        let r0 = run(0,
                     products: [product(0), product(1)],
                     projects: [project(0, product: 0), project(1, product: 1)],
                     videos: [video(0, ownerProject: 0), video(1, ownerProject: 1)],
                     segments: [seg(0, video: 0, raw: "curated"),
                                seg(1, video: 1, raw: "ai_generated")],
                     links: [link(1, project: 0, video: 0, at: 1),
                             link(2, project: 1, video: 1, at: 2)])
        #expect(r0.entries.map(\.videoID) == [id(200)])
        #expect(r0.counts[.curated] == 1)
        #expect(r0.counts[.aiGenerated] == 0)
    }
}
