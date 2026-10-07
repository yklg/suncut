import Foundation

/// 脚本匹配在素材真删后的回退判据（纯逻辑，可单测；M4 补齐计划 W3 契约）。
///
/// 背景：`ScriptScene.matchedSegment` 是非 cascade 关系，分镜被真删后关系边被 nullify，
/// 但 `matchStatusRaw` 仍停在 "matched"——状态与边不一致。向导 VM 订阅 `GraphBroadcast`
/// 真删广播后，必须用**纯 UUID 快照**（不持模型关系、不 fault backing）判定哪些场景
/// 受影响，再回退 `unmatched` 让用户重选。
public enum ScriptMatchRepair {

    /// 计算已锁定分镜被真删时，必须回退到 unmatched 的场景 id 集合。
    /// - Parameters:
    ///   - sceneToSegment: 场景当前锁定的分镜映射（sceneID → segmentID，纯 UUID 快照）
    ///   - deletedSegmentIDs: 本次真删广播携带的分镜业务 id
    /// - Returns: 命中删除的场景 id（保持稳定顺序由调用方处理；集合本身无序）
    public static func affectedSceneIDs(
        sceneToSegment: [UUID: UUID],
        deletedSegmentIDs: Set<UUID>
    ) -> Set<UUID> {
        guard !sceneToSegment.isEmpty, !deletedSegmentIDs.isEmpty else { return [] }
        var result = Set<UUID>()
        for (sceneID, segmentID) in sceneToSegment {
            if deletedSegmentIDs.contains(segmentID) {
                result.insert(sceneID)
            }
        }
        return result
    }
}
