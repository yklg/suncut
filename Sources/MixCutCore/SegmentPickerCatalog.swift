import Foundation

// ============================================================================
// 选素材抽屉的「产品 → 分镜」目录投影（纯值类型 + 纯函数，零 SwiftData 依赖）。
//
// 接口锁定（实现必须逐字满足，SegmentPickerCatalogTests 依赖这些形状）：
//
//   public struct CatalogProduct:  Equatable, Sendable { id, name, isDefault }
//   public struct CatalogProject:  Equatable, Sendable { id, productID: UUID? }
//   public struct CatalogVideo:    Equatable, Sendable { id, ownerProjectID: UUID? }
//   public struct CatalogSegment:  Equatable, Sendable { id, videoID, sourceRaw }
//   public struct BorrowedInfo:    Equatable, Sendable { productID, productName }
//   public struct CatalogEntry:   Equatable, Sendable { segmentID, videoID, source, borrowed }
//   public struct CatalogResult:   Equatable, Sendable { entries: [CatalogEntry],
//                                                            counts: [SegmentSource: Int] }
//   public enum SegmentPickerCatalog {
//       static func entries(forProduct productID: UUID,
//                          products: [CatalogProduct],
//                          projects: [CatalogProject],
//                          videos: [CatalogVideo],
//                          segments: [CatalogSegment],
//                          associations: [ProjectVideoAssociation]) -> CatalogResult
//   }
//
// 规则：
//   R1 可见视频：可解析关联（projectID/videoID 非 nil）中，项目归属产品 == 目标产品的 videoID 集合，
//      按 videoID 去重（投影自防御重复关联，不假设上游已 dedup）；
//   R2 可见视频顺序：该产品下关联按 (addedAt, projectID.uuidString, videoID.uuidString) 升序、
//      每视频取首条后的顺序——不依赖输入数组下标；
//   R3 entries 顺序：R2 的视频顺序，视频内按 segments 输入顺序（分镜顺序由上游 VM 保证，投影不重排）；
//   R4 视频主属产品：ownerProjectID → 该项目 productID（nil 视为默认产品）；
//      ownerProject 找不到/无归属时，回退到该视频**最早可解析关联**项目的产品；再不行默认产品；
//   R5 borrowed：主属产品 != 目标产品 → BorrowedInfo(主属产品 id/name)，否则 nil；对称：
//      同一视频在主属产品 borrowed=nil，在其他产品非 nil；
//   R6 悬挂分镜（videoID 不在可见集合）不出现；无分镜视频贡献 0 entries；
//   R7 项目 productID=nil 归默认产品；products 表缺默认产品时用 ProductCatalogDefaults 常量名；
//   R8 counts：四类来源各计数（含未分类），四类之和 == entries.count；口径含全部可见分镜
//      （已在方案中的置灰项也计入，与抽屉 header 的「已在方案 N 个」是两个并列数字）。
//
// 非空洞性论证（实现写错时哪条测试红）：
//   - 可见集合误用「视频 owner 字段匹配」单一路径     → C1/C3（跨产品借用看不到/悬空回退失效）红
//   - borrowed 误按「该视频关联项目数 > 1」判定      → C2 对称红
//   - 不去重重复关联                                → C1 计数翻倍红
//   - 按输入数组下标排序                             → C6 乱序输入红
//   - counts 漏 unclassified 或扣减置灰            → C4 守恒红
//   - 悬挂分镜强解视频                              → C5 崩溃/红
// ============================================================================

public struct CatalogProduct: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let isDefault: Bool
    public init(id: UUID, name: String, isDefault: Bool) {
        self.id = id; self.name = name; self.isDefault = isDefault
    }
}

public struct CatalogProject: Equatable, Sendable {
    /// nil = backfill 之前的存量项目，解析时归默认产品（R7）
    public let id: UUID
    public let productID: UUID?
    public init(id: UUID, productID: UUID?) {
        self.id = id; self.productID = productID
    }
}

public struct CatalogVideo: Equatable, Sendable {
    /// ownerProjectID 为导入事实；nil/悬空时走 R4 回退
    public let id: UUID
    public let ownerProjectID: UUID?
    public init(id: UUID, ownerProjectID: UUID?) {
        self.id = id; self.ownerProjectID = ownerProjectID
    }
}

public struct CatalogSegment: Equatable, Sendable {
    public let id: UUID
    /// 所属视频；nil = 悬挂分镜（关系断裂），投影 R6 保证它不出现在任何产品的 entries
    public let videoID: UUID?
    /// Segment.sourceRaw 原值；""=未分类，未知值也回退未分类
    public let sourceRaw: String
    public init(id: UUID, videoID: UUID?, sourceRaw: String) {
        self.id = id; self.videoID = videoID; self.sourceRaw = sourceRaw
    }
}

public struct BorrowedInfo: Equatable, Sendable {
    public let productID: UUID
    public let productName: String
}

public struct CatalogEntry: Equatable, Sendable {
    public let segmentID: UUID
    public let videoID: UUID
    public let source: SegmentSource
    public let borrowed: BorrowedInfo?
}

public struct CatalogResult: Equatable, Sendable {
    public let entries: [CatalogEntry]
    /// 四类计数（key 恒为 SegmentSource 四个 case）
    public let counts: [SegmentSource: Int]
}

public enum SegmentPickerCatalog {

    public static func entries(forProduct targetProductID: UUID,
                               products: [CatalogProduct],
                               projects: [CatalogProject],
                               videos: [CatalogVideo],
                               segments: [CatalogSegment],
                               associations: [ProjectVideoAssociation]) -> CatalogResult {

        // 索引
        let projectByID: [UUID: CatalogProject] = Dictionary(projects.map { ($0.id, $0) },
                                                              uniquingKeysWith: { first, _ in first })
        let videoByID: [UUID: CatalogVideo] = Dictionary(videos.map { ($0.id, $0) },
                                                         uniquingKeysWith: { first, _ in first })
        let productByID: [UUID: CatalogProduct] = Dictionary(products.map { ($0.id, $0) },
                                                             uniquingKeysWith: { first, _ in first })

        func productName(_ pid: UUID) -> String {
            productByID[pid]?.name
                ?? (pid == ProductCatalogDefaults.defaultProductID ? ProductCatalogDefaults.defaultProductName : "未知产品")
        }

        // R7：项目 → 产品（nil 归默认产品）
        func productID(ofProjectID pid: UUID) -> UUID {
            projectByID[pid]?.productID ?? ProductCatalogDefaults.defaultProductID
        }

        // 可解析关联（自防御：不假设上游 dedup 过）
        let resolvable = associations.filter { $0.projectID != nil && $0.videoID != nil }

        // 每个视频的最早可解析关联（R4 回退 + R2 排序共用），键=(addedAt, projectID, videoID)
        var earliestLink: [UUID: ProjectVideoAssociation] = [:]
        for row in resolvable {
            guard let vid = row.videoID else { continue }
            if let cur = earliestLink[vid] {
                if linkKey(row) < linkKey(cur) { earliestLink[vid] = row }
            } else {
                earliestLink[vid] = row
            }
        }

        // R1/R2：目标产品的可见视频，按 (addedAt, projectID, videoID) 排序后去重取序
        let inProduct = resolvable
            .filter { productID(ofProjectID: $0.projectID!) == targetProductID }
            .sorted { linkKey($0) < linkKey($1) }
        var orderedVideoIDs: [UUID] = []
        var seenVideoIDs = Set<UUID>()
        for row in inProduct {
            guard let vid = row.videoID else { continue }
            if seenVideoIDs.insert(vid).inserted { orderedVideoIDs.append(vid) }
        }

        // R4：视频主属产品
        func ownerProductID(forVideoID vid: UUID) -> UUID {
            if let ownerPID = videoByID[vid]?.ownerProjectID,
               projectByID[ownerPID] != nil {
                return productID(ofProjectID: ownerPID)
            }
            // ownerProject 悬空/缺失：回退到最早关联项目的产品；再不行默认产品
            if let earliest = earliestLink[vid], let pid = earliest.projectID {
                return productID(ofProjectID: pid)
            }
            return ProductCatalogDefaults.defaultProductID
        }

        // 分镜按视频分组（保留输入顺序，R3）；videoID 为 nil 的悬挂分镜无组可归（R6 丢弃）
        var segmentsByVideo: [UUID: [CatalogSegment]] = [:]
        for seg in segments {
            guard let vid = seg.videoID else { continue }
            segmentsByVideo[vid, default: []].append(seg)
        }

        // 组装 entries（R5/R6）
        var entries: [CatalogEntry] = []
        var counts: [SegmentSource: Int] = [
            .selfShot: 0, .curated: 0, .aiGenerated: 0, .unclassified: 0
        ]
        for vid in orderedVideoIDs {
            let ownerPID = ownerProductID(forVideoID: vid)
            let borrowed: BorrowedInfo? = (ownerPID == targetProductID)
                ? nil
                : BorrowedInfo(productID: ownerPID, productName: productName(ownerPID))
            for seg in segmentsByVideo[vid] ?? [] {
                let source = SegmentSource(persisted: seg.sourceRaw)
                entries.append(CatalogEntry(segmentID: seg.id, videoID: vid,
                                            source: source, borrowed: borrowed))
                counts[source, default: 0] += 1
            }
        }

        return CatalogResult(entries: entries, counts: counts)
    }

    /// 全序键：addedAt → projectID 字典序 → videoID 字典序（nil 调用方已过滤）。
    private static func linkKey(_ row: ProjectVideoAssociation) -> String {
        "\(row.addedAt.timeIntervalSinceReferenceDate)|"
        + "\(row.projectID?.uuidString ?? "")|\(row.videoID?.uuidString ?? "")"
    }
}
