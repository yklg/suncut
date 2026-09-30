import Foundation

/// 「手上有没有这个项目的数据」的唯一判据 —— 骨架屏亮不亮、旧画面该不该禁点，都由它派生。
///
/// 为什么要有这个类型：视图实例每次切模块都被销毁重建（`ContentView.detailView` 是 `@ViewBuilder switch`，
/// 分支返回不同类型），原先写在各视图里的 `@State private var isLoading = true` 因此每次进入都复位成 `true`，
/// 于是「换模块」也上了本该只为「换项目」服务的骨架屏 —— 用户看到的闪屏。就绪态必须与它所描述的数据同
/// 生命周期，所以住进 ViewModel，而不是住进随时会被扔掉的视图。
///
/// ⚠️ 只有单槽（记一个项目），不是多项目缓存：回切旧项目要重新 load 一次。
/// 做成「每个项目各记一份」会让回切不刷新，属回归。
public struct ProjectDataReadiness: Sendable, Equatable {

    /// `nil` = 还没有为任何项目加载过数据，屏上没有任何可留的画面。
    public private(set) var loadedProjectID: UUID?

    public init() {}

    /// 骨架屏的唯一判据：**只有屏上连一个项目的数据都还没有时**才亮。
    ///
    /// 刻意不带任何参数。判据一旦长出项目（或模块）维度，换项目就又上一次骨架 —— 而实测证明那次上屏
    /// 就是闪屏本体：`mainContent → SkeletonView → mainContent` 这次结构翻转要在同一次提交里拆掉整棵
    /// 旧内容树，主线程被占住，窗口拿不到新帧，侧栏区连续 3–10 帧（50–133ms）完全没有内容。
    /// 消融实测（尺子 `scripts/measure_nav_blank.sh`）：内容区整块换空仍剩 33–50ms（换入换出本身的底价），
    /// 不亮骨架则 359 帧一帧不丢。
    ///
    /// 换项目期间屏上留的是上一个项目的画面，靠 `holdsData(for:)` 禁点，不靠遮罩。
    public var needsSkeleton: Bool { loadedProjectID == nil }

    /// 屏上正画着的内容**属不属于**这个项目。
    ///
    /// `false` = 数据还没换过来，屏上是上一个项目的画面。这时渲染分支不变（这正是不闪的原因），
    /// 但必须禁点：画面上那些按钮的回调捕获的是**新的** `project`，例如素材库的「上传自建分镜」走
    /// `importSelfSegments(into: project)` —— 不禁点就会把旧项目面板上的操作落到新项目上。
    public func holdsData(for projectID: UUID) -> Bool { loadedProjectID == projectID }

    /// 记下某个项目的数据已就绪。对同一个 id 重复调用不改变结果。
    public mutating func markLoaded(for projectID: UUID) {
        loadedProjectID = projectID
    }
}
