import Foundation
import Testing
@testable import MixCutCore

// ============================================================================
// 计划 fluid-spring-char §批一（旧契约）→ §批十（本契约）—— 模块/项目切换闪屏的根因判据
//
// 本文件锁定的接口（实现必须逐字满足，否则这些用例不算通过）：
//
//   public struct ProjectDataReadiness: Sendable, Equatable {
//       public private(set) var loadedProjectID: UUID?
//       public init()
//       public var needsSkeleton: Bool
//       public func holdsData(for projectID: UUID) -> Bool
//       public mutating func markLoaded(for projectID: UUID)
//   }
//
// 规则：
//   R1 骨架屏的唯一判据是「屏上连一个项目的数据都还没有」，即 `loadedProjectID == nil`；
//   R2 `needsSkeleton` **不带任何参数** —— 长出项目维度或模块维度都会让闪屏复发（编译期守住）；
//   R3 只记一个项目（单槽）。回切旧项目时 `holdsData` 为假，画面照常留屏但要禁点，不许做成多项目缓存；
//   R4 `markLoaded` 对同一个 id 幂等；
//   R5 不提供 `invalidate()`：进入模块仍会重跑 loadXXX，就绪态只决定「亮不亮骨架 + 该不该禁点」，
//      不决定数据新鲜度，所以没有任何调用者需要它 —— 无人调的 API 不写（CLAUDE.md 的反假覆盖纪律）；
//   R6（批十新增）换项目**不改变** `needsSkeleton`（旧画面留屏），只改变 `holdsData(for: 新项目)`。
//      这两条读法必须分离：合并成一条就是闪屏本体。
//
// 为什么 R6 值得单独锁：实测 `mainContent → SkeletonView → mainContent` 这次结构翻转要在同一次提交里
// 拆掉整棵旧内容树，窗口连续 3–10 帧（50–133ms）拿不到新帧，侧栏整块没有内容 —— 用户报的「闪屏/跳动」。
// 量法与三个数见 scripts/measure_nav_blank.sh 与计划批九第 0 步④⑤。
//
// 非空洞性论证（实现若写错，哪一条会红）：
//   - `needsSkeleton` 写死 `true`                      → TC-U02 / TC-U03 / TC-U06 / TC-U07 红
//   - `needsSkeleton` 写死 `false`                     → TC-U01 / TC-U06 红（冷启动不再亮骨架）
//   - 退回旧契约 `loadedProjectID != projectID`        → 本文件与两个视图的调用点**全部编译不过**（R2 由编译期守住），
//                                                        同时守卫脚本 G04/G05 红
//   - `holdsData` 写死 `true`                          → TC-U05 / TC-U08 / TC-U09 红（禁点窗口被关掉 → 跨项目误操作复发）
//   - `holdsData` 写死 `false`                         → TC-U02 / TC-U08 / TC-U09 红（页面永远点不动）
//   - `holdsData` 写成 `loadedProjectID == nil`（与骨架判据混同）→ TC-U08 红（两读法必须反向）
//   - 改成 `[UUID]` 多项目缓存                         → TC-U03 红（回切旧项目不再需要重新 load）
//   - `markLoaded` 顺手清掉别的 id 以外的状态           → TC-U04 红（幂等被破坏）
// ============================================================================

// MARK: - 夹具工厂（沿用仓内约定，见 ProjectVideoDedupTests 的 id()）

/// 定宽十六进制 ⇒ 可读且互不相等；项目之间绝不会因随手 UUID() 而意外相同
private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", n, n))!
}

private let projA = id(101)
private let projB = id(202)
private let projC = id(303)

/// 迁移表的动作：`check` 只读判据（不改状态），`load` 走 `markLoaded`
private enum Op {
    case check
    case load(UUID)
}

/// 失败信息里把动作写成人话，避免红的时候只看到一个 enum dump
private func describe(_ op: Op) -> String {
    switch op {
    case .check:        return "只读判据"
    case .load(let id): return "markLoaded(\(id.uuidString.prefix(8))…)"
    }
}

@Suite("项目数据就绪态（骨架判据 + 禁点判据）")
struct ProjectDataReadinessTests {

    // MARK: TC-U01 / TC-U02 —— R1 + R2：闪屏的反用例就在这两条里

    @Test("TC-U01 冷启动、一个项目都没加载过：必须亮骨架（R1）")
    func firstEntryNeedsSkeleton() {
        var readiness = ProjectDataReadiness()
        #expect(readiness.loadedProjectID == nil)      // 夹具自证：确实是初始空槽，不是被谁写过
        #expect(readiness.needsSkeleton == true)
        #expect(readiness.holdsData(for: projA) == false)
    }

    @Test("TC-U02 加载过之后：同项目重复进入与换模块都不亮骨架，且画面可点（R1+R2）")
    func sameProjectReentryNeedsNoSkeleton() {
        var readiness = ProjectDataReadiness()
        readiness.markLoaded(for: projA)
        #expect(readiness.loadedProjectID == projA)    // 夹具自证：markLoaded 真的落了值
        // 连点三次「离开再回来」，三次都不亮骨架、都可点 —— 这就是修前会闪、修后不该闪的那一帧
        for _ in 0..<3 {
            #expect(readiness.needsSkeleton == false)
            #expect(readiness.holdsData(for: projA) == true)
        }
    }

    // MARK: TC-U03 / TC-U05 —— R3 单槽 + R6 换项目

    @Test("TC-U03 回切旧项目：不亮骨架，但 holdsData 为假 → 该禁点直到重新 load（R3+R6，挡住多项目缓存）")
    func switchingBackHoldsNoData() {
        var readiness = ProjectDataReadiness()
        readiness.markLoaded(for: projA)
        readiness.markLoaded(for: projB)               // 用户切到项目 B 并加载完

        #expect(readiness.needsSkeleton == false)          // 回切 A 时不再上屏骨架
        #expect(readiness.holdsData(for: projA) == false)  // 但 A 的数据已经不在了 → 禁点
        #expect(readiness.holdsData(for: projB) == true)
        #expect(readiness.loadedProjectID == projB)        // 且只记 B —— 单槽，不是两个都记
    }

    @Test("TC-U05 未加载过的 id 一律判为「屏上不是它的数据」（R6；防「拿任意非空值当就绪」的假实现）")
    func otherProjectsAreNeverHeld() {
        var readiness = ProjectDataReadiness()
        readiness.markLoaded(for: projA)
        #expect(readiness.holdsData(for: projB) == false)
        #expect(readiness.holdsData(for: projC) == false)
        #expect(readiness.holdsData(for: UUID()) == false)   // 随手新 id 也一样，不依赖夹具
    }

    // MARK: TC-U04 —— R4 幂等

    @Test("TC-U04 markLoaded 同 id 连调 5 次与调 1 次结果相同（R4）")
    func markLoadedIsIdempotent() {
        var once = ProjectDataReadiness()
        once.markLoaded(for: projA)

        var many = ProjectDataReadiness()
        for _ in 0..<5 { many.markLoaded(for: projA) }

        #expect(many == once)                              // Equatable 直接比，不比可读属性数量
        #expect(many.needsSkeleton == false)
        #expect(many.holdsData(for: projA) == true)
        #expect(many.holdsData(for: projB) == false)
    }

    // MARK: TC-U06 —— 迁移全表（期望值逐格写死，不由被测逻辑推导）

    @Test("TC-U06 操作序列的逐步状态与两条判据全表（R1…R6 合起来的行为面）")
    func transitionTable() {
        // 每格 = (动作, 动作后应记的 loadedProjectID, needsSkeleton, holdsData(A), holdsData(B))
        // 期望值来源：本文件顶部的 R1…R6，不是运行结果。
        let steps: [(op: Op, loaded: UUID?, skeleton: Bool, holdsA: Bool, holdsB: Bool)] = [
            (.check,       nil,   true,  false, false),  // 冷启动：屏上没东西可留 → 亮骨架
            (.load(projA), projA, false, true,  false),  // 进入 A 并加载完
            (.check,       projA, false, true,  false),  // 离开又回 A / 换模块：判据不变（闪屏就在这格）
            (.load(projA), projA, false, true,  false),  // 重复 markLoaded：幂等
            (.check,       projA, false, true,  false),  // **用户已点 B、数据还是 A**：不亮骨架，但 B 不可点
            (.load(projB), projB, false, false, true),   // B 加载完：A 变「屏上不是它」
            (.check,       projB, false, false, true),   // 在 B 里换模块
            (.load(projA), projA, false, true,  false),  // 回切 A 并加载完：B 反过来不可点
            (.check,       projA, false, true,  false),
        ]

        var readiness = ProjectDataReadiness()
        for (index, step) in steps.enumerated() {
            if case .load(let project) = step.op {
                readiness.markLoaded(for: project)
            }
            let at = "第 \(index + 1) 步（\(describe(step.op))）"
            #expect(readiness.loadedProjectID == step.loaded, "\(at) loadedProjectID 与期望表不符")
            #expect(readiness.needsSkeleton == step.skeleton, "\(at) 骨架判据与期望表不符")
            #expect(readiness.holdsData(for: projA) == step.holdsA, "\(at) 对 A 的禁点判据与期望表不符")
            #expect(readiness.holdsData(for: projB) == step.holdsB, "\(at) 对 B 的禁点判据与期望表不符")
        }
    }

    // MARK: TC-U07 —— R3 不变量

    @Test("TC-U07 任意时刻恰好一个项目免骨架、恰好一个项目可点（R1+R3 的不变量表述）")
    func exactlyOneProjectIsHeld() {
        var readiness = ProjectDataReadiness()
        let projects = [projA, projB, projC, projA, projB]
        for project in projects {
            readiness.markLoaded(for: project)
            #expect(readiness.needsSkeleton == false, "加载过一次之后就不该再亮骨架")
            let held = [projA, projB, projC].filter { readiness.holdsData(for: $0) }
            #expect(held.count == 1, "写过 \(project) 之后可点的项目应恰好 1 个，实际 \(held)")
            #expect(held.first == project, "可点的那个必须就是刚写入的 \(project)")
        }
    }

    // MARK: TC-U08 / TC-U09 —— 反向对照：两条读法各自都不能是常量，且彼此不等价

    @Test("TC-U08 holdsData 双向都要出现：同 id 为真、异 id 为假（钉死恒真/恒假实现）")
    func holdCriterionIsNotConstant() {
        var readiness = ProjectDataReadiness()
        readiness.markLoaded(for: projA)

        let sameProject = readiness.holdsData(for: projA)
        let otherProject = readiness.holdsData(for: projB)

        #expect(sameProject != otherProject,
                "两个不同项目的禁点判据读起来一模一样 —— 说明 holdsData 是恒真或恒假的假实现")
        #expect(sameProject == true)
        #expect(otherProject == false)
    }

    @Test("TC-U09 两条判据不是同一个东西：加载完 A 之后，骨架判据已假、A 的禁点判据为真（R6）")
    func twoReadingsAreNotTheSamePredicate() {
        var readiness = ProjectDataReadiness()
        #expect(readiness.needsSkeleton == true)             // 冷启动：亮骨架
        #expect(readiness.holdsData(for: projA) == false)    // 且 A 还没数据
        readiness.markLoaded(for: projA)
        // 此刻两条读法必须给出**相反**的值 —— 写成同一个表达式就会红
        #expect(readiness.needsSkeleton == false)
        #expect(readiness.holdsData(for: projA) == true)
    }
}
