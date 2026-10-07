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
