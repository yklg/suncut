import Foundation

/// 存量视频的「导入项目」归属回填规则（启动 backfill 使用）。
///
/// 背景：Video.ownerProject 是本期新增的导入事实字段，存量视频该字段为 nil。
/// 可观测的最佳近似是 ProjectVideo 关联——按约定视频首次导入即在该项目挂载，
/// 取**最早一条可解析关联的项目**作为它的 ownerProject。
///
/// 规则（与 ProjectVideoDedup R2/R3 同族，测试 ProductOwnershipBackfillTests 逐条钉着）：
/// - B1 同一 videoID 有多条关联 → addedAt 最早者胜；
/// - B2 addedAt 平局 → projectID.uuidString 字典序最小者胜（不能依赖输入数组下标）；
/// - B3 projectID/videoID 为 nil 的悬挂行不参与；一个视频只有悬挂行时不出现在结果里
///      （调用方读侧 ProductCatalog 会再回退到默认产品，backfill 不瞎填）；
/// - B4 输入预期是 `ProjectVideoDedup.deduplicate(_:).retained`；本函数对重复行也自防御
///      （同 project+video 多行不会影响取最早的结果）；
/// - B5 纯函数幂等：输出是输入的确定性映射，重复调用结果不变。
public enum ProductOwnershipBackfill {

    /// - Parameter associations: 全部 ProjectVideo 关联行（推荐先过 dedup.retained）
    /// - Returns: [videoID: ownerProjectID]，只含至少有一条可解析关联的视频
    public static func ownerProjectIDByVideoID(_ associations: [ProjectVideoAssociation]) -> [UUID: UUID] {
        // 只保留可解析行
        let resolvable = associations.filter { $0.projectID != nil && $0.videoID != nil }

        // 按 (videoID) 分组选最早；选择键 = (addedAt, projectID.uuidString)，与下标无关。
        var best: [UUID: (at: Date, projectID: UUID)] = [:]
        for row in resolvable {
            guard let videoID = row.videoID, let projectID = row.projectID else { continue }
            if let current = best[videoID] {
                let candidateKey = "\(row.addedAt.timeIntervalSinceReferenceDate)|\(projectID.uuidString)"
                let currentKey = "\(current.at.timeIntervalSinceReferenceDate)|\(current.projectID.uuidString)"
                if candidateKey < currentKey {
                    best[videoID] = (row.addedAt, projectID)
                }
            } else {
                best[videoID] = (row.addedAt, projectID)
            }
        }
        return best.mapValues { $0.projectID }
    }
}
