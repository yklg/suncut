import Foundation

/// 一键改写管线的宏观阶段。
///
/// 管线边界（见 DubbingViewModel.rewrite）：
/// - prepareClone：人声分离 + 克隆参考提取 + 音色注册（首次/换 Key 时最慢，demucs 在此阶段）
/// - rewrite：逐轮调用 AI 产出 K 套台词
/// - synthesize：逐段调用克隆 TTS 合成配音
public enum DubbingPhase: String, Sendable, CaseIterable, Equatable {
    case prepareClone
    case rewrite
    case synthesize

    /// 三阶段指示器上的中文名（展示契约：空字符串会让 UI 露底，由测试钉住非空）。
    public var displayName: String {
        switch self {
        case .prepareClone: return "准备原声"
        case .rewrite: return "改写台词"
        case .synthesize: return "合成配音"
        }
    }

    /// 三阶段固定顺序（UI 画阶段指示链路用，不依赖 CaseIterable 的隐含顺序语义）。
    public static let pipelineOrder: [DubbingPhase] = [.prepareClone, .rewrite, .synthesize]
}

/// 一次「视频级配音作业」的进度快照（Sendable 值类型）。
///
/// `fraction` 是**阶段内**进度 0...1；nil 表示当前子步没有可信百分比
/// （抽音频 / 注册克隆 / 模型兜底下载 / 等待 AI HTTP 响应），UI 退回不定条，
/// 绝不伪造跨阶段总百分比。
public struct DubbingJobProgress: Sendable, Equatable {
    public var phase: DubbingPhase
    public var phaseText: String
    public var fraction: Double?
    public var detail: String?

    public init(phase: DubbingPhase,
                phaseText: String,
                fraction: Double? = nil,
                detail: String? = nil) {
        self.phase = phase
        self.phaseText = phaseText
        self.fraction = fraction
        self.detail = detail
    }

    /// 空闲态：无作业时的读数（fraction=nil，文案空）。
    public static let idle = DubbingJobProgress(phase: .prepareClone, phaseText: "")
}

/// 「数据被真删后，哪些视频级作业必须停」的纯判据。
///
/// 删除广播（GraphChange）在三条删除链路上的载荷形态不同（已逐链路核实）：
/// - 删项目级联：带 `.video`（也带该视频的 `.segment`）→ video 命中即停；
/// - 素材页删视频：只带该视频全量分镜的 `.segment`（不带 video）→ 作业目标分镜全灭即停；
/// - 仅删单个分镜：只带部分 `.segment` → **不**停整视频作业，管线靠 isDroppedFromContext 跳过死分镜。
/// 无载荷广播（MCP 立即删等）不在此判据射程内，同样由管线死实体自检兜底。
public enum DubbingJobCancellation {
    /// - Parameters:
    ///   - videoID: 作业所属视频
    ///   - targetSegmentIDs: 本次作业的目标分镜集合（整片改写为全部分镜；单分镜改写为 1 个）
    ///   - deletedVideoIDs: 本次广播里被删的视频 id
    ///   - deletedSegmentIDs: 本次广播里被删的分镜 id
    /// - Returns: 该作业是否必须取消
    public static func shouldCancel(videoID: UUID,
                                    targetSegmentIDs: Set<UUID>,
                                    deletedVideoIDs: Set<UUID>,
                                    deletedSegmentIDs: Set<UUID>) -> Bool {
        // 删项目链：视频实体没了，优先级最高（此时目标集可能为空）。
        if deletedVideoIDs.contains(videoID) { return true }
        // 没有可对照的目标（如纯克隆作业）且视频未命中：不动。
        guard !targetSegmentIDs.isEmpty else { return false }
        // 部分删除不取消：剩余目标还要正常产出，死分镜由管线逐条过门跳过。
        return targetSegmentIDs.allSatisfy { deletedSegmentIDs.contains($0) }
    }
}
