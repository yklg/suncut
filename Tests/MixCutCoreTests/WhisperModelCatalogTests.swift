import Foundation
import Testing
@testable import MixCutCore

/// `WhisperModelCatalog` 的契约测试（计划 v9 §10.4 组 1，TC-61…TC-72）
///
/// 本文件已从预览落地：在 `Tests/MixCutCoreTests/` 内、已编译、`swift test` 跑绿（2026-09-28）。
/// 下面"假定签名"仍是契约锚点：实现与测试对不上时，回计划对齐，**不放宽测试**。
///
/// 假定签名（实现须与此一致）：
/// ```
/// public enum ModelRoot: Int, CaseIterable, Comparable, Sendable { case userDirectory, appBundle, legacyCache, systemDirectory }
/// public struct ModelFile: Equatable, Sendable {
///     public init(root: ModelRoot, fileName: String, byteCount: Int64, headerIsGGML: Bool, path: String)
/// }
/// public enum ModelIssue: Equatable, Sendable {
///     case truncated(expected: Int64, actual: Int64), badHeader, tierUnknown
/// }
/// public struct ModelReport: Equatable, Sendable {
///     let selected: ModelFile?, selectedTier: String?, usable: Bool, issues: [ModelIssue], detected: [ModelFile]
/// }
/// public enum WhisperModelCatalog {
///     static var tiers: [String]
///     static func expectedBytes(forTier: String) -> Int64?
///     static func downloadURLs(forTier: String) -> [String]
///     static func tier(ofFileName: String) -> String?
///     static func report(files: [ModelFile]) -> ModelReport
/// }
/// ```
///
/// 钉住的规则（计划 §3.2、红线 R2/R3/R7，一般规则 R-a/R-b）：
/// - R-a **就绪单调性**：L2/L3/L4 任何一层变红都**不得**让 `usable` 变 false —— 只有"一个文件都没有"才不可用
/// - R-b **同源唯一且确定**：同输入两次 `report` 结果逐字段相等；选出的必是输入之一
/// - R-c 根优先级 = 磁盘 > 包内 > 旧缓存 > 系统目录（v5 裁定项，同档两颗时磁盘赢）
/// - R-d 半截文件只出 `truncated` 提示；未识别文件名只出 `tierUnknown`，且 `selectedTier == nil` 但 `usable == true`
///
/// 非空洞性对应：TC-65 是正向对照（唯一一颗干净模型必须 `issues` 为空）；TC-72 是穷举不变量
/// （**故意不做随机 property 版**：本域输入空间可枚举，且 `SplitMix64` 现已收编为
/// `Sources/MixCutCore/FolderMixPicker.swift` 的 public 定义（2026-10-20，从 `ProjectVideoDedupTests`
/// 那份 private 副本迁来）—— 要用就直连，另抄一份等于制造第二份真源）。

@Suite("WhisperModelCatalog：档位识别、四层就绪与根优先级")
struct WhisperModelCatalogTests {

    private let largeV3Bytes: Int64 = 3_095_033_483

    private func file(_ name: String,
                      _ root: ModelRoot,
                      bytes: Int64,
                      header: Bool = true,
                      path: String? = nil) -> ModelFile {
        ModelFile(root: root,
                  fileName: name,
                  byteCount: bytes,
                  headerIsGGML: header,
                  path: path ?? "/somewhere/\(name)")
    }

    private var cleanLargeV3OnDisk: ModelFile {
        file("ggml-large-v3.bin", .userDirectory, bytes: largeV3Bytes)
    }

    // MARK: 表本身

    @Test("TC-61 档位表：档名唯一、URL 齐全且 https、精确体积只给校验过的档（未校验档不许编数）")
    func catalogTableIntegrity() {
        let tiers = WhisperModelCatalog.tiers
        #expect(!tiers.isEmpty, "表不能是空的，否则下面所有用例都会空过")
        #expect(Set(tiers).count == tiers.count, "档名重复：\(tiers)")
        #expect(tiers.contains(ASRPolicy.engineTier), "表里必须有引擎实际使用的那颗：\(tiers)")

        for tier in tiers {
            #expect(WhisperModelCatalog.fileName(forTier: tier) != nil, "\(tier) 没有文件名")
            let urls = WhisperModelCatalog.downloadURLs(forTier: tier)
            #expect(!urls.isEmpty, "\(tier) 没有下载源")
            for url in urls {
                #expect(url.hasPrefix("https://"), "\(tier) 的 URL 不是 https：\(url)")
            }
        }

        // 校验过的档：精确值就是镜像 API 给的真值
        #expect(WhisperModelCatalog.expectedBytes(forTier: "large-v3") == 3_095_033_483)
        #expect(WhisperModelCatalog.expectedBytes(forTier: "large-v3-turbo") == 1_624_555_275)
        #expect(WhisperModelCatalog.expectedBytes(forTier: "large-v3-q5_0") == 1_081_140_203)

        // 未取到精确值的档必须留 nil —— 拿"约 141.1MB"这种四舍五入值冒充预期值，
        // 会让正常文件被判成下断了（计划 §3.1 的"预期值要有来源"）
        for tier in ["medium", "small", "base"] {
            #expect(WhisperModelCatalog.expectedBytes(forTier: tier) == nil,
                    "\(tier) 的精确字节数还没取到，表里不许放近似值充数")
        }
    }

    @Test("TC-62 未识别文件名判'检测到但未使用'，不得判'没有模型'")
    func unknownFileNameStaysUsable() throws {
        let odd = file("ggml-tiny.bin", .userDirectory, bytes: 80_000_000)
        #expect(WhisperModelCatalog.tier(ofFileName: "ggml-tiny.bin") == nil)

        let report = WhisperModelCatalog.report(files: [odd])
        #expect(report.usable, "R-a：能读到文件就该算可用，未识别档位不许剥夺可用性")
        #expect(report.selected?.fileName == "ggml-tiny.bin")
        #expect(report.selectedTier == nil)
        #expect(report.issues.contains(.tierUnknown))
    }

    @Test("TC-63 半截文件（字节数小于期望）只出提示，L1 仍可用")
    func truncatedFileWarnsButStaysUsable() throws {
        let expected = try #require(WhisperModelCatalog.expectedBytes(forTier: "large-v3"))
        let half = file("ggml-large-v3.bin", .userDirectory, bytes: expected - 1024)
        let report = WhisperModelCatalog.report(files: [half])
        #expect(report.usable, "R-a：体积不符属 L3 提示，不许升级为'没模型'")
        #expect(report.issues.contains(.truncated(expected: expected, actual: expected - 1024)))
    }

    @Test("TC-64 文件头不是 ggml ⇒ 报损坏，但仍算 L1 存在")
    func badHeaderReportsCorruptNotMissing() {
        let junk = file("ggml-large-v3.bin", .userDirectory, bytes: largeV3Bytes, header: false)
        let report = WhisperModelCatalog.report(files: [junk])
        #expect(report.usable)
        #expect(report.issues.contains(.badHeader))
    }

    @Test("TC-65 正向对照：唯一一颗干净的 large-v3 ⇒ usable 且零告警（防恒真判定）")
    func cleanSingleModelReportsNothing() throws {
        let report = WhisperModelCatalog.report(files: [cleanLargeV3OnDisk])
        #expect(report.usable)
        #expect(report.issues.isEmpty, "干净输入不该有告警，实际：\(report.issues)")
        #expect(report.selectedTier == "large-v3")
        #expect(report.selected?.fileName == "ggml-large-v3.bin")
    }

    // MARK: 根优先级（v5 裁定的直接判据）

    @Test("TC-66 同档两颗（磁盘 + 包内同名）⇒ 选磁盘那颗")
    func diskBeatsBundleForSameTier() throws {
        let onDisk = file("ggml-large-v3.bin", .userDirectory, bytes: largeV3Bytes,
                          path: "/Library/Application Support/\(Brand.dataDirectoryName)/whisper-models/ggml-large-v3.bin")
        let inBundle = file("ggml-large-v3.bin", .appBundle, bytes: largeV3Bytes,
                            path: "/Applications/\(Brand.displayName).app/Contents/Resources/bin/ggml-large-v3.bin")
        let report = WhisperModelCatalog.report(files: [inBundle, onDisk])
        #expect(report.selected?.root == .userDirectory,
                "磁盘优先是本轮裁定项；实际选中 \(String(describing: report.selected?.root))")

        let reversed = WhisperModelCatalog.report(files: [onDisk, inBundle])
        #expect(reversed.selected?.root == .userDirectory, "结果不许依赖输入顺序")
    }

    @Test("TC-67 只有包内有 turbo ⇒ 选它并如实报来源与档位")
    func bundleOnlyIsHonored() throws {
        let inBundle = file("ggml-large-v3-turbo.bin", .appBundle,
                            bytes: try #require(WhisperModelCatalog.expectedBytes(forTier: "large-v3-turbo")))
        let report = WhisperModelCatalog.report(files: [inBundle])
        #expect(report.usable)
        #expect(report.selected?.root == .appBundle)
        #expect(report.selectedTier == "large-v3-turbo")
        #expect(report.issues.isEmpty)
    }

    @Test("TC-68 候选为空 ⇒ 不可用、无选中、不崩（IN-01）")
    func emptyInputIsNotUsable() {
        let report = WhisperModelCatalog.report(files: [])
        #expect(report.selected == nil)
        #expect(report.selectedTier == nil)
        #expect(report.usable == false)
        #expect(report.issues.isEmpty)
    }

    @Test("TC-69 同输入两次 report ⇒ 逐字段相同（R-b 确定性）")
    func reportIsDeterministic() {
        let inputs = [file("ggml-base.bin", .userDirectory, bytes: 147_951_465),
                      file("ggml-large-v3.bin", .appBundle, bytes: largeV3Bytes),
                      file("ggml-weird.bin", .systemDirectory, bytes: 1)]
        let first = WhisperModelCatalog.report(files: inputs)
        let second = WhisperModelCatalog.report(files: inputs)
        #expect(first == second)
    }

    @Test("TC-70 四档根优先级：磁盘 > 包内 > 旧缓存 > 系统目录")
    func rootOrderIsTotalAndDocumented() {
        #expect(ModelRoot.userDirectory < ModelRoot.appBundle)
        #expect(ModelRoot.appBundle < ModelRoot.legacyCache)
        #expect(ModelRoot.legacyCache < ModelRoot.systemDirectory)

        let tier = "ggml-large-v3.bin"
        let bytes = largeV3Bytes
        let pairs: [(ModelRoot, ModelRoot)] = [
            (.userDirectory, .appBundle),
            (.userDirectory, .legacyCache),
            (.userDirectory, .systemDirectory),
            (.appBundle, .legacyCache),
            (.legacyCache, .systemDirectory),
        ]
        for (high, low) in pairs {
            let winner = WhisperModelCatalog.report(files: [file(tier, low, bytes: bytes),
                                                            file(tier, high, bytes: bytes)])
            #expect(winner.selected?.root == high, "\(high) 应压过 \(low)")
        }
    }

    @Test("TC-71 体积判据从表取值：等于期望不报，差 1 字节才报（预期值要有来源）")
    func truncationComparesAgainstTable() {
        guard let expected = WhisperModelCatalog.expectedBytes(forTier: "large-v3") else {
            Issue.record("表里没有 large-v3 的期望值，本用例失去意义")
            return
        }
        let exact = WhisperModelCatalog.report(files: [file("ggml-large-v3.bin", .userDirectory, bytes: expected)])
        #expect(!exact.issues.contains { if case .truncated = $0 { return true } else { return false } },
                "体积正好等于表值却报了截断，说明判据不是从表来的")

        let offByOne = WhisperModelCatalog.report(files: [file("ggml-large-v3.bin", .userDirectory, bytes: expected - 1)])
        #expect(offByOne.issues.contains(.truncated(expected: expected, actual: expected - 1)))
    }

    @Test("TC-72 穷举不变量：只要候选非空，usable 必为真且选中的必是输入之一")
    func exhaustiveUsabilityInvariant() {
        let tierNames = ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-medium.bin",
                         "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin", "custom-my-model.bin"]
        let roots = ModelRoot.allCases
        let states: [(bytes: Int64, header: Bool)] = [(largeV3Bytes, true), (1, false), (999, false)]

        // 夹具自检：枚举空间必须真被铺开，否则这条会空过
        var checked = 0
        for name in tierNames {
            for root in roots {
                for state in states {
                    checked += 1
                    let candidate = file(name, root, bytes: state.bytes, header: state.header)
                    let report = WhisperModelCatalog.report(files: [candidate])
                    #expect(report.usable, "单颗文件 \(name)@\(root) 被判不可用，违反 R-a")
                    #expect(report.selected?.fileName == name)

                    // 混合输入：干净大档存在时，脏候选不许把可用抢掉
                    let mixed = WhisperModelCatalog.report(files: [candidate, cleanLargeV3OnDisk])
                    #expect(mixed.usable)
                    #expect(mixed.selected != nil)
                }
            }
        }
        #expect(checked == tierNames.count * roots.count * states.count, "穷举没跑满：\(checked)")
    }

    // MARK: TC-109 「另检测到 X（未使用）」的界面依据：detected 必须与 selected 同源同序

    @Test("TC-109 detected 是排好序的全部候选：第 0 个即 selected，未选中的那颗仍在名单里")
    func detectedListsAllCandidatesInSelectionOrder() {
        let turboInBundle = file("ggml-large-v3-turbo.bin", .appBundle, bytes: 1_624_555_275)
        let baseInBundle = file("ggml-base.bin", .appBundle, bytes: 147_951_465)
        // 故意把磁盘那颗放最后：若实现按输入顺序报，这条就会红（顺序判据不是装饰）
        let report = WhisperModelCatalog.report(files: [turboInBundle, baseInBundle, cleanLargeV3OnDisk])

        #expect(report.detected.count == 3, "候选漏报，界面就会少报'另检测到'")
        #expect(report.detected.first == report.selected, "detected[0] 与 selected 分家 = 同源（R3）破了")
        #expect(report.detected.map(\.fileName)
                == ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-base.bin"],
                "未按'大档在前、同档按根'排序；实际：\(report.detected.map(\.fileName))")
        #expect(report.detected.filter { $0 != report.selected }.count == 2)

        // 空候选：detected 为空且不崩（TC-68 的延伸 —— 界面据 detected 判'一个都没检测到'）
        #expect(WhisperModelCatalog.report(files: []).detected.isEmpty)
    }
}
