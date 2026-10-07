import Foundation
import SwiftData

/// 脚本（一次「产品脚本成片」向导的产物根）。
///
/// 生命周期（方案 A，见实施计划 §2.1）：
/// - 向导开始（结构定稿、点「开始生成」）⇒ 立即插入，状态 `.draft`；
/// - 全部槽位匹配锁定 ⇒ 迁移 `.matched`，逐槽检索/写作在 matched 态进行；
/// - 用户确认 materialize ⇒ `.materialized`（终态，整树冻结），并一对一关联落成的 MixScheme。
@Model
final class ScriptDocument: Identifiable {
    @Attribute(.unique) var id: UUID
    var project: Project?
    var product: Product?
    var title: String
    /// ScriptDirection.forward / .reverse
    var directionRaw: String
    /// StructureMode.template / .aiAuto
    var structureModeRaw: String
    var targetDuration: Double
    /// ScriptLifecycle.State：draft / matched / materialized
    var statusRaw: String
    /// materialize 后一对一关联 MixScheme；**只允许赋值一次**。
    var realizedScheme: MixScheme?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ScriptScene.script)
    var scenes: [ScriptScene] = []

    var status: ScriptLifecycle.State {
        get { ScriptLifecycle.State(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var direction: ScriptDirection {
        get { ScriptDirection(rawValue: directionRaw) ?? .forward }
        set { directionRaw = newValue.rawValue }
    }

    /// 状态迁移唯一入口：仅合法迁移生效；终态拒绝任何写入；返回是否成功。
    /// `realizedScheme` 的绑定与 `.materialized` 迁移必须同一次发生（见 MaterializationService）。
    @discardableResult
    func transition(to next: ScriptLifecycle.State, realizedScheme: MixScheme? = nil) -> Bool {
        guard ScriptLifecycle.canMove(from: status, to: next) else { return false }
        if next == .materialized {
            guard self.realizedScheme == nil, let scheme = realizedScheme else { return false }
            self.realizedScheme = scheme
        }
        status = next
        updatedAt = Date()
        return true
    }

    init(id: UUID = UUID(),
         project: Project?,
         product: Product?,
         title: String,
         direction: ScriptDirection = .forward,
         structureMode: StructureMode,
         targetDuration: Double,
         status: ScriptLifecycle.State = .draft) {
        self.id = id
        self.project = project
        self.product = product
        self.title = title
        self.directionRaw = direction.rawValue
        self.structureModeRaw = structureMode.rawValue
        self.targetDuration = targetDuration
        self.statusRaw = status.rawValue
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
    }
}
