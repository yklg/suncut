import Foundation
import Testing
@testable import MixCutCore

/// `EngineModelState` 的**契约测试**（计划 v4 §4.1 五态定义 + §15 测试计划）。
///
/// ⚠️ 当前状态：契约先行。以下"假定签名"在 Core 层**尚未实现**（2026-11-11 全仓 0 命中），
/// 因此本文件加入后 `swift test` 会**编译失败**（`cannot find type 'EngineModelState'` /
/// `incorrect argument label 'engine:'`）。这是 TDD 的 red 阶段，**不是** §15 判据里
/// "可运行且断言失败"的那种红 —— 新增类型的第一步只能先编译红，落地 Core 骨架后才转断言红/绿。
/// 沙盒内也无法跑 `swift test`（SwiftPM 嵌套沙盒被拒），需到 Xcode / 沙盒外验证。
///
/// 假定签名（实现须与此一致；对不上时回计划对齐，**不放宽测试**）：
/// ```
/// public enum EngineModelState: Equatable, Sendable {
///     case missing
///     case truncated(expected: Int64, actual: Int64)
///     case badHeader
///     case readyUnverified
///     case ready
/// }
/// extension ModelReport {
///     public let engineState: EngineModelState?   // 默认 nil，仅传 engine 时非 nil
///     public init(..., engineState: EngineModelState? = nil)
/// }
/// extension WhisperModelCatalog {
///     public static func report(files: [ModelFile], engine: WhisperTier?) -> ModelReport
/// }
/// ```
///
/// 钉住的规则（计划 §4.1 / §4.2 / §4.3）：
/// - **判定优先级互斥，取首个命中**：`missing → truncated → badHeader → readyUnverified → ready`
///   （体积不符是"下了一半"的强信号，优先于坏头；坏头又优先于"未校验"）
/// - **R2 边界**：`engineState` 只是"下载/修复入口"判据，**不是可用性判据**。
///   `usable` 一个字不改 —— 非引擎档存在但引擎档缺失时，`usable == true` 且 `engineState == .missing`。
/// - **向后兼容**：`engine` 传 nil 时，`ModelReport` 既有字段逐字不变、`engineState == nil`。
///   §12 记的生产 1 处 + 测试 18 处调用走默认参数，不应被本改动波及。

@Suite("EngineModelState：引擎档模型五态、判定优先级与 R2 边界")
struct EngineModelStateTests {

    // MARK: 夹具

    /// 引擎实际要跑的那颗档（来自 ASRPolicy，不在此处硬编码文件名）。
    private func engine() throws -> WhisperTier {
        try #require(WhisperModelCatalog.tier(named: ASRPolicy.engineTier),
                     "档位表里没有引擎档 \(ASRPolicy.engineTier)，下面的用例全部失去意义")
    }

    /// 引擎档的表值体积（从表取，不硬编码，避免测试与表分家）。
    private func expectedBytes() throws -> Int64 {
        try #require(WhisperModelCatalog.expectedBytes(forTier: ASRPolicy.engineTier),
                     "引擎档没有精确字节数，截断态用例无法判定")
    }

    private func engineFile(bytes: Int64,
                            header: Bool = true,
                            root: ModelRoot = .userDirectory) -> ModelFile {
        ModelFile(root: root,
                  fileName: ASRPolicy.engineFileName,
                  byteCount: bytes,
                  headerIsGGML: header,
                  path: "/models/\(ASRPolicy.engineFileName)")
    }

    private func file(_ name: String, bytes: Int64,
                      root: ModelRoot = .userDirectory,
                      header: Bool = true) -> ModelFile {
        ModelFile(root: root,
                  fileName: name,
                  byteCount: bytes,
                  headerIsGGML: header,
                  path: "/models/\(name)")
    }

    // MARK: 五态判定

    @Test("TC-110 候选中没有引擎档 ⇒ .missing（即使别的档存在、usable 仍为真）")
    func engineAbsentIsMissing() throws {
        let tier = try engine()
        // 放一颗 base，但引擎档 q5_0 不在任何根里
        let report = WhisperModelCatalog.report(files: [file("ggml-base.bin", bytes: 147_951_465)],
                                                engine: tier)
        #expect(report.engineState == .missing,
                "引擎档缺失就必须给下载入口；实际 \(String(describing: report.engineState))")
        // R2：engineState 不许否决 usable
        #expect(report.usable, "R2：有任意候选即可用，engineState 不是可用性判据")
    }

    @Test("TC-111 引擎档存在但字节数不符 ⇒ .truncated(expected:actual:)")
    func engineTruncated() throws {
        let tier = try engine()
        let expected = try expectedBytes()
        let actual = expected - 1024
        let report = WhisperModelCatalog.report(files: [engineFile(bytes: actual)], engine: tier)
        #expect(report.engineState == .truncated(expected: expected, actual: actual),
                "实际 \(String(describing: report.engineState))")
        #expect(report.usable, "R2：半截文件仍算 L1 存在")
    }

    @Test("TC-112 引擎档字节对但文件头非 ggml ⇒ .badHeader")
    func engineBadHeader() throws {
        let tier = try engine()
        let report = WhisperModelCatalog.report(files: [engineFile(bytes: try expectedBytes(), header: false)],
                                                engine: tier)
        #expect(report.engineState == .badHeader,
                "实际 \(String(describing: report.engineState))")
    }

    @Test("TC-113 引擎档无精确字节数（expectedBytes == nil）⇒ .readyUnverified，不是 .ready")
    func engineWithoutExactBytesIsUnverified() throws {
        // 用 medium 这种表里 expectedBytes 为 nil 的档冒充 engine 入参，验证 L3 跳过分支
        let unverified = try #require(WhisperModelCatalog.tier(named: "medium"))
        #expect(unverified.expectedBytes == nil, "夹具自检：medium 应当没有精确字节数")
        let report = WhisperModelCatalog.report(
            files: [file(unverified.fileName, bytes: 1_430_000_000)], engine: unverified)
        #expect(report.engineState == .readyUnverified,
                "表里没有精确值时只能算未校验，不许冒充已校验；实际 \(String(describing: report.engineState))")
    }

    @Test("TC-114 引擎档字节对、头正常 ⇒ .ready（正向对照，防恒真判定）")
    func engineReady() throws {
        let tier = try engine()
        let report = WhisperModelCatalog.report(files: [engineFile(bytes: try expectedBytes())], engine: tier)
        #expect(report.engineState == .ready,
                "干净的引擎档必须判就绪，否则每次启动都会误报下载；实际 \(String(describing: report.engineState))")
        #expect(report.issues.isEmpty, "干净输入不该有告警，实际 \(report.issues)")
    }

    // MARK: 优先级与兼容

    @Test("TC-115 截断 + 坏头同时成立 ⇒ 取 .truncated（体积强信号优先于坏头）")
    func truncatedWinsOverBadHeader() throws {
        let tier = try engine()
        let expected = try expectedBytes()
        // 字节错 + 头坏：两个条件都成立，优先级判定必须落在 truncated
        let dirty = engineFile(bytes: expected - 1, header: false)
        let report = WhisperModelCatalog.report(files: [dirty], engine: tier)
        #expect(report.engineState == .truncated(expected: expected, actual: expected - 1),
                "优先级应是 truncated 压过 badHeader；实际 \(String(describing: report.engineState))")

        // 顺序无关：把同样的输入换个根再跑一次，结果须一致
        let another = WhisperModelCatalog.report(files: [engineFile(bytes: expected - 1, header: false,
                                                                  root: .appBundle)], engine: tier)
        #expect(another.engineState == report.engineState)
    }

    @Test("TC-116 engine 传 nil ⇒ engineState 为 nil，既有字段逐字不变（钉住 18 处旧调用）")
    func nilEngineKeepsLegacyBehavior() throws {
        let clean = engineFile(bytes: try expectedBytes())
        let dirty = file("ggml-base.bin", bytes: 1, header: false)
        let withEngine = WhisperModelCatalog.report(files: [dirty, clean], engine: try engine())
        let legacy = WhisperModelCatalog.report(files: [dirty, clean])

        #expect(legacy.engineState == nil, "没传 engine 就不该凭空产生引擎态")
        // 除 engineState 外，其余字段必须与带 engine 的调用逐字相同
        #expect(legacy.selected == withEngine.selected)
        #expect(legacy.selectedTier == withEngine.selectedTier)
        #expect(legacy.usable == withEngine.usable)
        #expect(legacy.issues == withEngine.issues)
        #expect(legacy.detected == withEngine.detected)
    }

    @Test("""
    TC-117 穷举五态：只要有引擎档候选，engineState 不许为 nil；
    且 engineState != .ready 时 usable 允许为真（R2 不变量）
    """)
    func fiveStatesCoverAllCandidateShapes() throws {
        let tier = try engine()
        let expected = try expectedBytes()
        let shapes: [(name: String, file: ModelFile, want: EngineModelState)] = [
            ("缺根", file("ggml-base.bin", bytes: expected), .missing),
            ("截断", engineFile(bytes: expected - 1), .truncated(expected: expected, actual: expected - 1)),
            ("坏头", engineFile(bytes: expected, header: false), .badHeader),
            ("就绪", engineFile(bytes: expected), .ready),
        ]
        for shape in shapes {
            let report = WhisperModelCatalog.report(files: [shape.file], engine: tier)
            #expect(report.engineState != nil, "\(shape.name)：传了 engine 就必须给出引擎态")
            #expect(report.engineState == shape.want,
                    "\(shape.name)：期望 \(String(describing: shape.want))，实际 \(String(describing: report.engineState))")
            #expect(report.usable, "R2：\(shape.name) 不得否决 usable")
        }
        #expect(shapes.count == 4, "夹具自检：本用例覆盖 4 种候选形态（第 5 态 readyUnverified 见 TC-113）")
    }
}
