import Foundation

/// Inspector 里「镜像模型字段的文本草稿」状态机。
///
/// 台词原文框、边界时间码框都有同一个需求：编辑框展示模型值的一份草稿，
/// 但模型值也可能在**实体未切换**时被外部流程原地更新（边界微调重切台词、
/// 重新识别 ASR），此时：
/// - 用户没动过草稿 → 必须跟随新值（否则界面停在旧文本，就是「台词原文不刷新」那类 bug）；
/// - 用户已经手改且未保存 → 必须**拒绝**外部覆盖（不能因为一次失焦后的重切把用户草稿静默吞掉）。
///
/// 判定基准是「草稿是否偏离上次载入值」这个哨兵，而不是焦点状态：
/// 用户改完草稿点了别处（焦点已离开），脏草稿仍然成立，外部更新照样被挡下，
/// 由「保存 / 还原」显式收口。
///
/// 值类型、可 Sendable：与 ``HoverTipState`` / ``PlaybackActivationGate`` 同一范式——
/// MixCutCore 不依赖 SwiftUI / Observation，交互契约由可完整推演的状态迁移承担，
/// 视图层只持一个 `@State` 镜像并在 `onChange(of: 模型值)` 时调 ``adoptExternal(_:)``。
public struct InspectorDraftMirror: Equatable, Sendable {
    /// 上次从模型载入（或保存成功后回写）的值，脏判定的基准。
    private var loadedSource: String
    /// 编辑框当前展示的草稿。
    public private(set) var draft: String

    public init(source: String = "") {
        self.loadedSource = source
        self.draft = source
    }

    /// 草稿是否相对已载入值发生过未保存修改。
    public var isDirty: Bool { draft != loadedSource }

    /// 模型值在外部被原地更新时调用（同一实体，非切换）。
    ///
    /// - Returns: true = 草稿干净，已采纳新值；false = 草稿有未保存修改，已拒绝覆盖。
    ///   同值重复推送走干净分支，幂等且不会把干净草稿误标为脏。
    @discardableResult
    public mutating func adoptExternal(_ newSource: String) -> Bool {
        guard !isDirty else { return false }
        loadedSource = newSource
        draft = newSource
        return true
    }

    /// 丢弃草稿、以给定值重新建立镜像（首载 / 用户点「还原」）。
    public mutating func reset(to source: String) {
        loadedSource = source
        draft = source
    }

    /// 用户显式保存成功后调用：以落库值更新基准，镜像重新变干净。
    public mutating func didCommit(_ committedSource: String) {
        loadedSource = committedSource
        draft = committedSource
    }

    /// 视图把编辑框绑定到草稿后，通过此方法回写用户输入（不改变基准）。
    public mutating func edit(_ text: String) {
        draft = text
    }
}
