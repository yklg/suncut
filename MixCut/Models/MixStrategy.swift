import Foundation
import SwiftData

/// 混剪策略（一个策略下包含多个排列组合变体）
@Model
final class MixStrategy: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var style: String
    var strategyDescription: String
    var targetAudience: String
    var narrativeStructure: String
    var targetDuration: Double
    var strategyReasoning: String?
    var differentiation: String?

    var project: Project?

    @Relationship(deleteRule: .cascade, inverse: \MixScheme.strategy)
    var schemes: [MixScheme] = []

    var createdAt: Date

    /// true = 系统级"自定义组合"容器策略，不会被 AI 生成流程触碰
    var isCustomGroup: Bool = false

    /// true = 用户自定义叙事结构（区别于 AI 策略 / 自定义组合）
    var isNarrativeTemplate: Bool = false

    /// true = 「产品脚本成片」容器：脚本向导物化的方案归属此组。
    /// 与 isCustomGroup（原声手挑）、isNarrativeTemplate（自定义结构）正交的第三类容器；
    /// 组内方案一律 dubOnly（全新配音），见 MixScheme.audioTrackPolicy。
    /// 容器懒建（首个脚本物化时 ensure），UI 空组由 SchemeViewModel 的内存占位承担。
    var isScriptGroup: Bool = false

    /// 叙事段位序列（JSON 存储，元素见 NarrativeSlot）
    var narrativeSlotsData: Data?

    /// 叙事段位序列（计算属性，参照 Segment.semanticTypes 的 JSON 编解码写法）
    var narrativeSlots: [NarrativeSlot] {
        get {
            guard let data = narrativeSlotsData else { return [] }
            return (try? JSONDecoder().decode([NarrativeSlot].self, from: data)) ?? []
        }
        set {
            narrativeSlotsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(
        name: String,
        style: String,
        description: String,
        targetAudience: String = "",
        narrativeStructure: String = "",
        targetDuration: Double = 60
    ) {
        self.id = UUID()
        self.name = name
        self.style = style
        self.strategyDescription = description
        self.targetAudience = targetAudience
        self.narrativeStructure = narrativeStructure
        self.targetDuration = targetDuration
        self.createdAt = Date()
    }

    /// 变体数量
    var schemeCount: Int { schemes.count }

    /// 按创建时间排序的变体
    var orderedSchemes: [MixScheme] {
        schemes.sorted { $0.variationIndex < $1.variationIndex }
    }
}

// MARK: - 「自定义组合」容器的唯一构造口

extension MixStrategy {

    /// 系统容器的名字与元信息 —— 全仓只许在这里写一遍。
    ///
    /// 为什么要收成一颗（计划 Step 4「修族不修点」）：`MixStrategy(name: "自定义组合", …)`
    /// ＋ `isCustomGroup = true` ＋ `project = …` ＋ `strategies.append` ＋ `context.insert`
    /// 这一整套动作，实测有 **4 份逐字拷贝**：
    ///   ① `ProjectViewModel.createProject()`（UI 新建项目）
    ///   ② `MCPToolHandlers` 的建项工具（那里的注释自己写着「与 UI 的 createProject 保持一致」
    ///      —— 靠人记着抄对，就是最脆的那种一致性）
    ///   ③ `MixCutApp.ensureCustomGroupStrategy`（给老项目补建的一次性数据修复）
    ///   ④ `SchemeViewModel.createCustomScheme`（"理论上一定有，双保险"那段）
    /// 文件夹混剪是第 5 个要建项目的通路，不能再抄第 5 份：每多一份，就多一处
    /// "将来给容器加一个必备字段时只改了被调到的那份"的静默分歧点。
    @discardableResult
    static func attachCustomGroup(to project: Project, in context: ModelContext) -> MixStrategy {
        let group = MixStrategy(name: "自定义组合",
                                style: "",
                                description: "手动挑选分镜组合的方案",
                                targetAudience: "",
                                narrativeStructure: "",
                                targetDuration: 0)
        group.isCustomGroup = true
        group.project = project
        project.strategies.append(group)
        context.insert(group)
        return group
    }

    /// 幂等版：已有容器就返回既有那一份，绝不补第二份（重复容器会让方案页出现两个同名分组）。
    @discardableResult
    static func customGroup(for project: Project, in context: ModelContext) -> MixStrategy {
        if let existing = project.strategies.first(where: { $0.isCustomGroup }) {
            return existing
        }
        return attachCustomGroup(to: project, in: context)
    }
}
