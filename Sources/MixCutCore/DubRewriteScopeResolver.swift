import Foundation

/// 配音改写作用域种类。
public enum DubRewriteScopeKind: String, Sendable, Equatable {
    /// 本视频全部非锁定分镜
    case all
    /// 当前选中的 1 个分镜
    case single
    /// 多选模式下、属于本视频的勾选分镜
    case selected
    /// 多选模式但本视频无勾选（调用方应禁用按钮，管线不会被触发）
    case disabled
}

/// 作用域解析结果。
public struct DubRewriteScopeResolution: Equatable, Sendable {
    public let kind: DubRewriteScopeKind
    /// 目标分镜 ID；nil 表示「本视频全部」（由视图层映射为该视频全部分镜）。
    public let targetIDs: Set<UUID>?

    public init(kind: DubRewriteScopeKind, targetIDs: Set<UUID>?) {
        self.kind = kind
        self.targetIDs = targetIDs
    }
}

/// 作用域解析：把「多选 / 单选 / 空选」的界面状态，解析为某个视频级控件的目标集合。
///
/// 控件是**视频级**的（每个视频分组标题行各一份），而选中状态是全局的——
/// 因此必须以该视频自己的分镜 ID 集合为【定义域】做交集，杜绝跨视频越界处理。
public enum DubRewriteScopeResolver {

    /// - Parameters:
    ///   - domainIDs: 该视频拥有的全部分镜 ID（定义域）。
    ///   - isSelectionMode: 是否处于多选模式。
    ///   - selectedSegmentIDs: 多选模式下勾选的分镜 ID（全局集合）。
    ///   - singleSegmentID: 非多选时当前选中查看的分镜 ID。
    public static func resolve(
        domainIDs: Set<UUID>,
        isSelectionMode: Bool,
        selectedSegmentIDs: Set<UUID>,
        singleSegmentID: UUID?
    ) -> DubRewriteScopeResolution {
        if isSelectionMode {
            // 多选优先：只处理属于本视频的勾选
            let inDomain = selectedSegmentIDs.intersection(domainIDs)
            guard !inDomain.isEmpty else {
                return DubRewriteScopeResolution(kind: .disabled, targetIDs: [])
            }
            return DubRewriteScopeResolution(kind: .selected, targetIDs: inDomain)
        }
        if let id = singleSegmentID, domainIDs.contains(id) {
            return DubRewriteScopeResolution(kind: .single, targetIDs: [id])
        }
        // 空选或查看的分镜不属于本视频 → 本视频全部
        return DubRewriteScopeResolution(kind: .all, targetIDs: nil)
    }
}

/// 目标排序：targetIDs 是无序 Set，直接映射会让进度/TTS 执行顺序随重绘抖动。
///
/// 泛型纯函数、不依赖 App 层模型，SPM 可独立测试；视图层与 DebugSelfTest 共用同一口径。
public enum DubTargetOrdering {

    /// 按 (主数值升序, 次数值升序) 稳定重排。
    /// 分镜场景调用方传 (startTime, startFrame)：startTime 相同按起始帧决胜。
    public static func ordered<T: Hashable>(
        _ items: [T],
        key: (T) -> (primary: Double, secondary: Int)
    ) -> [T] {
        items.sorted {
            let a = key($0)
            let b = key($1)
            // 先按主数值升序，相同再按次数值（帧号）稳定决胜。
            if a.primary != b.primary { return a.primary < b.primary }
            return a.secondary < b.secondary
        }
    }
}

/// 作用域呈现：管线中所有「随作用域变化的文案」由该值承载，调用方不出现 scope 文案分支。
public struct DubScopePresentation: Equatable, Sendable {
    /// 定义域内没有可改写分镜时的错误语
    public let emptyEligibleError: String
    /// 全部成功的 Toast：
    /// - wantsCount=false：直接使用；
    /// - wantsCount=true ：调用方把变体总数前置，形如「\(count) \(successToast)」。
    public let successToast: String
    /// 成功 Toast 是否需要前置变体总数（布尔开关取代 %d 占位字符串约定）。
    public let wantsCount: Bool
    /// 确认弹窗/汇总中的动作对象名称（如「本视频」「当前分镜」「选中分镜」）。
    public let actionNoun: String

    public init(emptyEligibleError: String,
                successToast: String,
                wantsCount: Bool,
                actionNoun: String) {
        self.emptyEligibleError = emptyEligibleError
        self.successToast = successToast
        self.wantsCount = wantsCount
        self.actionNoun = actionNoun
    }
}

/// 作用域 → 呈现文案映射。
public enum DubScopePresentationMapper {

    public static func presentation(for kind: DubRewriteScopeKind) -> DubScopePresentation {
        switch kind {
        case .all:
            return DubScopePresentation(
                emptyEligibleError: "没有可重配的分镜",
                successToast: "个配音变体已完成 TTS 合成，点开任意分镜可在右侧试听",
                wantsCount: true,
                actionNoun: "本视频")
        case .single:
            return DubScopePresentation(
                emptyEligibleError: "该分镜不可改写（保留原声或没有原台词）",
                successToast: "本分镜已重新改写并生成配音",
                wantsCount: false,
                actionNoun: "当前分镜")
        case .selected:
            return DubScopePresentation(
                emptyEligibleError: "选中的分镜都不可改写（可能全部保留原声）",
                successToast: "个选中分镜的配音变体已完成合成",
                wantsCount: true,
                actionNoun: "选中分镜")
        case .disabled:
            return DubScopePresentation(
                emptyEligibleError: "请先勾选要改写的分镜",
                successToast: "",
                wantsCount: false,
                actionNoun: "选中分镜")
        }
    }
}
