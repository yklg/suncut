import Foundation

// ============================================================================
// 产品脚本成片配音：index 分配 + 空壳绑定四分支 + 删除归属 —— 纯值可单测。
//
// 数据契约背景：
// - 物化时每段创建一条 SegmentDub（voiceId="" 未绑定壳，variantIndex 局部分配）；
// - 分镜上可能同时存在普通改写 dub（逐视频克隆或预置音色），按 textVariantIndex 去重展示；
// - 生成配音时把空壳绑定到解析出的音色；绑定必须处理撞号/复用/载体缺失，且绝不覆盖
//   用户既有的改写资产。
// ============================================================================

public enum ScriptDubIndexAllocator {

    /// 新 dub 应使用的 index = 该分镜现存 index 最大值 + 1（无现存 → 0）。
    /// 同口径供物化（MaterializationService）与载体缺失重建使用，杜绝与既有改写版撞号。
    public static func nextIndex(occupied: [Int]) -> Int {
        (occupied.max() ?? -1) + 1
    }
}

/// 绑定前对现存 dub 的纯值快照。
public struct ExistingDub: Equatable, Sendable {
    public let dubID: UUID
    public let variantIndex: Int
    public let voiceID: String
    public let text: String
    public let hasAudio: Bool

    public init(dubID: UUID, variantIndex: Int, voiceID: String, text: String, hasAudio: Bool) {
        self.dubID = dubID; self.variantIndex = variantIndex
        self.voiceID = voiceID; self.text = text; self.hasAudio = hasAudio
    }
}

/// 绑定结果（调用方按结果在 SwiftData 上执行；本判据不碰模型）。
public enum ScriptDubBindingOutcome: Equatable, Sendable {
    /// 现存同文案 dub 可直接复用：方案选中改指 reusableDubID；
    /// shellDubID 非 nil 时该空壳应删除（nil=本就无壳，无需删）。
    /// 有音频时零合成；无音频时对该 dub 合成即可（voiceID 已就绪）。
    case reuseExisting(reusableDubID: UUID, shellDubID: UUID?, reusableVoiceID: String, reusableHasAudio: Bool)
    /// 撞号但文案不同：空壳迁到 newIndex 后原地绑定（既有 dub 不动）。
    case relocate(shellDubID: UUID, newIndex: Int, voiceID: String)
    /// 无冲突：空壳原地绑定音色。
    case bindInPlace(shellDubID: UUID, voiceID: String)
    /// 载体缺失（壳已被清理/选择被清空）：新建 dub（index=newIndex）并写回方案选中。
    case createNew(dubIndex: Int, voiceID: String)
}

public enum ScriptDubBinding {

    /// 解析一次绑定。
    /// - Parameters:
    ///   - shellDubID: 物化空壳 id；nil = 载体已缺失（方案槽当前无绑定）。
    ///   - shellIndex: 空壳 index；nil 时由现存列表推导新 index。
    ///   - shellText: 该槽脚本台词。
    ///   - existing: 该分镜现存全部 dub 的快照（含空壳与普通改写）。
    ///   - voiceID: 本次解析出的合成音色 id（非空）。
    public static func resolve(shellDubID: UUID?,
                               shellIndex: Int?,
                               shellText: String,
                               existing: [ExistingDub],
                               voiceID: String) -> ScriptDubBindingOutcome {
        precondition(!voiceID.isEmpty, "解析层未配置音色时不得进入绑定（应在调用前阻断）")

        // ① 复用：存在同文案、且音色就是本次音色的 dub（有/无音频均可），直接改指。
        //    必须音色相同——音色 A 的同文案配音不能冒充音色 B 的成果。
        if let match = existing.first(where: {
            $0.voiceID == voiceID && $0.text == shellText && $0.dubID != shellDubID
        }) {
            return .reuseExisting(reusableDubID: match.dubID,
                                  shellDubID: shellDubID,
                                  reusableVoiceID: match.voiceID,
                                  reusableHasAudio: match.hasAudio)
        }

        // 确定壳与目标 index
        if let shellID = shellDubID,
           let shell = existing.first(where: { $0.dubID == shellID }) {
            let occupiedByOthers = existing.filter { $0.dubID != shellID }.map(\.variantIndex)
            if occupiedByOthers.contains(shell.variantIndex) {
                // ② 撞号且文案不同（同文案已在上面被音色相同条件放过；此处指非同音色/非同文案占用）
                let newIndex = ScriptDubIndexAllocator.nextIndex(occupied: occupiedByOthers)
                return .relocate(shellDubID: shellID, newIndex: newIndex, voiceID: voiceID)
            }
            // ③ 无冲突：原地绑
            return .bindInPlace(shellDubID: shellID, voiceID: voiceID)
        }

        // ④ 载体缺失：新建。index 避开全部现存（shell 已不在其中，shellIndex 仅在壳未被列入
        //    existing 的防御场景兜底，正常路径与物化分配器同口径）。
        var occupied = existing.map(\.variantIndex)
        if let shellIndex, !existing.contains(where: { $0.dubID == shellDubID }) {
            occupied.append(shellIndex)
        }
        return .createNew(dubIndex: ScriptDubIndexAllocator.nextIndex(occupied: occupied),
                          voiceID: voiceID)
    }
}

/// 删除归属判据：删方案时哪些脚本 dub 可以随方案永久删除。
public enum ScriptDubReap {

    /// 脚本成片配音的文案来源集合（删除归属的唯一真源；App 层据此过滤模型行）。
    /// 注意不含 aiRewrite——那是通用 AI 新撰来源，可能属普通改写资产，不随脚本方案回收。
    public static let scriptProvenanceRaws: Set<String> = [
        TranscriptSource.productScript.rawValue,
        TranscriptSource.userScriptReverse.rawValue,
    ]

    /// 纯判据：一条脚本 dub 是否可被正在删除的方案回收。
    /// - Parameters:
    ///   - provenanceIsScript: dub 文案来源是否为脚本族（productScript/userScriptReverse）。
    ///   - dubID: 待判 dub。
    ///   - boundByDeletingSchemeIDs: 正在删除的方案槽位绑定的全部 dub id。
    ///   - referencedBySurvivingSchemeIDs: 其余存活方案槽位仍绑定的全部 dub id。
    public static func reapable(provenanceIsScript: Bool,
                                dubID: UUID,
                                boundByDeletingSchemeIDs: Set<UUID>,
                                referencedBySurvivingSchemeIDs: Set<UUID>) -> Bool {
        // 非脚本族（普通改写资产）永不由此路径回收。
        guard provenanceIsScript else { return false }
        // 必须确实是被待删方案绑定的（未绑定的脚本 dub 可能属于别的载体状态，保留）。
        guard boundByDeletingSchemeIDs.contains(dubID) else { return false }
        // 仍被存活方案引用 → 保留（两方案共享同一条复用 dub 时）。
        if referencedBySurvivingSchemeIDs.contains(dubID) { return false }
        return true
    }

    /// 批量版：返回可安全删除的 dub id（保持输入顺序）。
    public static func reapableCandidates(provenanceScriptDubIDs: [UUID],
                                          boundByDeletingSchemeIDs: Set<UUID>,
                                          referencedBySurvivingSchemeIDs: Set<UUID>) -> [UUID] {
        provenanceScriptDubIDs.filter {
            reapable(provenanceIsScript: true,
                     dubID: $0,
                     boundByDeletingSchemeIDs: boundByDeletingSchemeIDs,
                     referencedBySurvivingSchemeIDs: referencedBySurvivingSchemeIDs)
        }
    }
}
