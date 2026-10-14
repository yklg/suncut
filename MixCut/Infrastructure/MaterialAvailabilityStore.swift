import SwiftUI

/// 素材可用性的**唯一持有者**：库里这条记录的 `localPath`，现在到底还指不指向一个读得动的文件。
///
/// 为什么只能有这一个持有者（而不是导入页、分镜库各存一份）：两页各扫一次，就会对
/// 「丢没丢」给出不同答案（时间窗不同、扫描时机不同），而「全链路统一提示」正是拍下的范围。
/// 共享的是**结果集**（值类型 `Set<UUID>`），写侧只有 `refresh` 一处，读侧只读不回写。
/// 与 `ThumbnailCache.shared` / `PendingDeletionCenter.shared` 同族的"单一共享真源"写法。
///
/// ⚠️ 这一层**只报告，不删任何东西**：`missingVideoIDs` 的下游只有「投影过滤」与「标注」。
/// 真删记录仍走视频删除咽喉（`ImportViewModel.scheduleVideoDeletion`），由用户显式发起 ——
/// 把「文件没了」自动变成「记录删掉」是这个功能最危险的误读，禁止。
///
/// 与孤儿 GC 那条轴的分工：那条问「磁盘有、库里无 ⇒ 可以回收文件」，这条问
/// 「库里有、磁盘无 ⇒ 只能不再显示」。两条轴共用 `OrphanFileFinder.normalize` 那一颗归一，
/// 判定结果互不重叠（`TC-MA-10` 钉着）。
@MainActor
@Observable
final class MaterialAvailabilityStore {

    static let shared = MaterialAvailabilityStore()
    private init() {}

    /// 当前判为「源文件已不存在」的视频 id。
    ///
    /// ⚠️ 只许**整体赋值**，不许 `formUnion(` —— 并集会让一次误判永久留在集里：
    /// 用户把文件放回原处，那张卡却仍然写着「已丢失」，自愈能力当场失效。
    var missingVideoIDs: Set<UUID> = []

    /// 判据本身不可信时的原因。
    /// 「我查不了」必须显示成「查不了」——不许伪装成「没丢」，也不许伪装成「丢了」。
    var warning: String?

    /// 未参与判定的条数（路径为空，或不在当前素材真源目录下 —— 品牌迁移未完成时的形状）。
    var excludedRecords: Int = 0

    /// 在真源目录下但读不动的条数（权限 / 卷未就绪）—— 既不判在也不判缺。
    var unreadableRecords: Int = 0

    /// 同项目、同指纹两次扫描的最小间隔。手动「重新检查」传 `force: true` 绕过。
    private static let throttleWindow: TimeInterval = 2

    /// 上一次扫描的坐标（项目 + 变化指纹 + 时刻）。
    @ObservationIgnored private var lastScan: (projectID: UUID, at: Date, fingerprint: String)?

    /// 最近一次**发起**扫描的项目 id。扫描跑在协作线程池上，回来时用户可能已经切了项目，
    /// 不核对这一颗就会把**上一个项目**的缺失集整体盖进来（跨项目串「丢失」）。
    @ObservationIgnored private var latestRequestProjectID: UUID?

    /// 对账一次，把结果整体换进本持有者。
    ///
    /// 挂点是两页**已存在**的 `.task(id: project.id)`（不新开任务、不做 LaunchStep：
    /// 启动期算出的集合没有承接者，而加一颗 step 要同步的门单已排到十六条）。
    /// - Parameter force: 手动「重新检查」传 true，绕过节流与指纹。
    func refresh(for project: Project, force: Bool = false) async {
        let projectID = project.id
        latestRequestProjectID = projectID

        // 跨 Actor 只许传值类型：在这里就把 (id, path) 摘出来，一条 `Video` 对象都不许离开主 Actor
        // —— SwiftData 模型非 Sendable，递出去就是墓碑读那一族。
        // 顺手算出变化指纹（关联条数 + 最大 createdAt）：只按「同项目 2 秒」节流的话，
        // 用户从 Finder 删完文件立刻回页面会"看起来没反应"，条数变了就必须重扫。
        var records: [MaterialRecordPath] = []
        records.reserveCapacity(project.associatedVideos.count)
        var latestCreatedAt: TimeInterval = 0
        for video in project.associatedVideos {
            records.append(MaterialRecordPath(id: video.id, path: video.localPath))
            latestCreatedAt = max(latestCreatedAt, video.createdAt.timeIntervalSince1970)
        }
        let fingerprint = "\(records.count)@\(Int(latestCreatedAt))"

        if !force, let last = lastScan,
           last.projectID == projectID, last.fingerprint == fingerprint,
           Date().timeIntervalSince(last.at) < Self.throttleWindow {
            return
        }

        // 只读坐标在 `missingDivideReading` 里取（界面上问与启动日志问必须是同一颗）。
        let result = await Self.scan(records: records)

        // 扫到一半切了项目 ⇒ 这份结果属于上一个项目，一个字段都不许落进来。
        guard latestRequestProjectID == projectID else { return }

        missingVideoIDs = result.missingIDs
        warning = result.degraded ? result.degradationReason : nil
        excludedRecords = result.excludedRecords
        unreadableRecords = result.unreadableRecords
        lastScan = (projectID, Date(), fingerprint)
    }

    /// 真正的磁盘对账。声明为 `nonisolated static … async` 而**不是** `Task.detached`：
    ///
    /// ⚠️ `Task.detached` 不继承父任务的取消（那是它的定义性语义），而 `.task(id:)` 在换项目/
    /// 离屏时取消的是父 task ⇒ 写在 detached 里的取消检查永不触发，"最坏只多跑几条"的保护是假的。
    /// 走 await 链，取消才会真的沿调用链传播。
    ///
    /// ⚠️ **不并发化**：每条一次 `stat()`，161 条串行在协作线程池上是毫秒级。
    /// 改成并发不会更快（瓶颈是磁盘随机 IO 而不是次数），只会让"这一轮看了哪些文件"变得不可预期。
    nonisolated static func scan(records: [MaterialRecordPath]) async -> MissingScanResult {
        if Task.isCancelled {
            // 取消必须留痕。方案 E2E 的「竞态」那一格要证的是"扫描真的被取消了"，
            // 而界面看不出一个没落进来的结果 —— 没有读数点时那一格只能判死，这两行就是读数点。
            MixLog.info("[可用性对账] 已取消（发起时已取消，一条路径都没问）")
            return MissingScanResult()
        }
        let result = missingDivideReading(records: records)
        if Task.isCancelled {
            MixLog.info("[可用性对账] 已取消（本轮应问 \(records.count) 条，问完才取消 ⇒ 结果不落进来）")
            return MissingScanResult()
        }
        MixLog.info("[可用性对账] 本轮问了 \(records.count) 条：缺失 \(result.missingIDs.count)、"
                    + "未参与判定 \(result.excludedRecords)、读不动 \(result.unreadableRecords)、"
                    + "判据降级=\(result.degraded)")
        // 判定循环住在 Core 纯函数里（它因此能被 `swift test` 打到）。取消检查放在它前后各一次，
        // 而不是把 `try await` 塞进循环 —— 塞进去就得在 App 侧另写一遍判定，那正是"两个答案"的来源。
        return result
    }

    /// 「库里有记录、磁盘上没有文件」的一次读数。**界面与启动日志共用这一颗**：
    /// 「扫不扫」与「用不用」若各写一份前缀或探针，同一批素材就能得到两个结论。
    nonisolated static func missingDivideReading(records: [MaterialRecordPath]) -> MissingScanResult {
        // 只读坐标（`...ForReading`）：走写入侧那颗 `globalVideoDirectory` 会把目录顺手建出来，
        // "素材根目录不在"这道兜底因此在生产里永不可达。
        let root = FileHelper.globalVideoDirectoryForReading.path
        return MissingMaterialFinder.safeMissingIDs(
            records: records,
            probe: FileHelper.materialProbe,     // 探针唯一出口（批 5），这里不再自带一把尺子
            trustedPrefixes: [root],
            videoRootPresent: FileManager.default.isReadableFile(atPath: root)
        )
    }
}
