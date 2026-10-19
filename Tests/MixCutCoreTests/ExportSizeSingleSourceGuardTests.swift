import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// ES · 导出画布尺寸「唯一真源」守卫
//
// ## 为什么要有这道门（它防的就是一次真实事故）
//
// 2026-10-19，"档位→输出宽高"这一条规则在仓库里抄了 7 份，批量导出的 41 条成片因此
// 整批是 480×854 而被千川拒收，且**没有任何一处代码知道自己算出了 480**。
// 把规则收敛进 `MixCutCore.DeliveryCanvas` 只是修好这一次；本守卫防的是它再抄开。
//
// ## 判据为什么只扫「复合形态」，不扫裸数字
//
// 实测 `1080` 在 `MixCut/**` 有 15 处命中，`720` 另有几处，全部与视频画布无关：
//   · `Views/SegmentLibrary/ArrangeOrderSheet.swift` 的 `.frame(minWidth: 720, …)`
//   · `Services/ASR/ASRService.swift` 的 `timeoutIntervalForResource = 7200`（`720` 是它的子串）
//   · `Views/Shared/ThumbnailCache.swift` 文档注释里的「1080×1920」
//   · `Services/ShotEdit/Wan25VideoEditClient.swift` 的 `"720P"`（API 请求体字段）
// 写「裸数字不许出现」会误伤这四处既有正确代码 —— 本仓 `SheetSizeContractTests.swift`
// 的文件头就是为这类误伤立过规矩的。所以只扫**尺寸专用形状**：滤镜串 `"W:H"` 与
// `width: W, height: H`。ES-04 把这四处钉成"必绿"样本。
//
// ## 已知漏口（写在这里，不假装看不见）
//
// ① 只认字面量。把尺寸拆成两个变量再拼（`let w = 1080; let h = 1920`）扫不到 ——
//    那要靠 `DeliverySpecTests` 的行为对表兜，不靠本文件。
// ② 只扫 `MixCut/` 与 `Sources/MixCutCore/`。`.scratch/` 下有整仓副本，
//    那是变异台架与构建缓存的地盘，扫它会把旧常量当成现网违规。
// ============================================================================

// MARK: - 被测判据（纯函数，与文件 IO 解耦）

enum ExportSizeScan {
    /// ① 系：允许存在，但只许住在 Core。
    static let coreOnlyTokens = [
        "width: 1080, height: 1920",
        "width: 720, height: 1280",
        "\"1080:1920\"",
        "\"720:1280\"",
    ]
    /// ② 系：已被 F7 整档删除，App 与 Core 都不许再有。
    /// 只取"只可能是画布"的形状 —— 证据表里 `PlatformVerdictRecord(width: 480, height: 854, …)`
    /// 是**登记拒收事实**，不是产出尺寸，不能一起禁掉。
    static let bannedEverywhere = [
        "\"480:854\"",
        "\"854:480\"",
        "case p480",
        "\"480p\"",
        "DeliveryCanvas(width: 480, height: 854)",
    ]

    struct Hit: Equatable {
        let file: String
        let line: Int
        let token: String
    }

    /// 在**已剥注释与字符串**的字符流上数某个 token 的出现次数。
    static func count(in code: [Character], _ token: String) -> Int {
        let p = Array(token)
        guard !p.isEmpty, code.count >= p.count else { return 0 }
        var count = 0, i = 0
        while i <= code.count - p.count {
            if Array(code[i..<(i + p.count)]) == p { count += 1; i += p.count }
            else { i += 1 }
        }
        return count
    }

    /// 找出 ② 系违规的位置（带行号，便于报错指得准）。
    /// 注意：`codeOnly` 是等长置换、换行保留 ⇒ 行号与原文件一致。
    static func bannedHits(file: String, src: String) -> [Hit] {
        let code = TagRowHostScan.codeOnly(src)
        var hits: [Hit] = []
        for token in bannedEverywhere where count(in: code, token) > 0 {
            let p = Array(token)
            var line = 1
            for i in 0..<code.count {
                if code[i] == "\n" { line += 1 }
                if i + p.count <= code.count, Array(code[i..<(i + p.count)]) == p {
                    hits.append(Hit(file: file, line: line, token: token))
                    break
                }
            }
        }
        return hits
    }
}

// MARK: - 仓库根与遍历

private let esRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func esRead(_ rel: String) -> String {
    (try? String(contentsOf: esRepoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

private func esSwiftFiles(under dir: String) -> [String] {
    let base = esRepoRoot.appendingPathComponent(dir)
    guard let en = FileManager.default.enumerator(at: base,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else { return [] }
    let prefix = base.path
    return en.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .map { dir + String($0.path.dropFirst(prefix.count)) }
        .sorted()
}

/// 把一批源文件剥成代码流后，数某个 token 的总命中数。
private func esCount(_ tokens: [String], inFiles files: [String]) -> Int {
    var total = 0
    for rel in files {
        let code = TagRowHostScan.codeOnly(esRead(rel))
        for t in tokens { total += ExportSizeScan.count(in: code, t) }
    }
    return total
}

// MARK: - ES-01 ② 系：480 档不得复活

@Suite("ES · 480p 档不得复活")
struct ExportSizeTierRetiredTests {

    @Test("档位枚举恰为三档，且没有任何一档与 480 有关")
    func tierEnumHasNo480() {
        #expect(DeliveryTier.allCases.count == 3,
                "档位数量变了（实得 \(DeliveryTier.allCases.count)）：\(DeliveryTier.allCases.map(\.rawValue))")
        #expect(Set(DeliveryTier.allCases.map(\.rawValue)) == Set(["原始分辨率", "1080p", "720p"]),
                "档位名单与批准口径不符：\(DeliveryTier.allCases.map(\.rawValue))")
        for t in DeliveryTier.allCases {
            #expect(!t.rawValue.contains("480"), "\(t.rawValue) 是复活的 480 档")
        }
    }

    @Test("没有任何档位算出过 480×854 或 480 宽的非原始画布")
    func noTierProducesRetiredCanvas() {
        for tier in [DeliveryTier.p1080, .p720] {
            let c = DeliveryCanvas.size(tier: tier, sourceMaxWidth: 480, sourceMaxHeight: 854)
            #expect(!(c.width == 480 && c.height == 854),
                    "\(tier.rawValue) 档仍能产出被删掉的 480×854")
        }
    }

    @Test("② 系字面量在 App 与 Core 两侧都必须为 0")
    func retiredLiteralsAreGoneEverywhere() {
        let app = esSwiftFiles(under: "MixCut")
        let core = esSwiftFiles(under: "Sources/MixCutCore")
        let hits = app.flatMap { ExportSizeScan.bannedHits(file: $0, src: esRead($0)) }
            + core.flatMap { ExportSizeScan.bannedHits(file: $0, src: esRead($0)) }
        #expect(hits.isEmpty,
                "被删档位的东西回来了：\(hits.map { "\($0.file):\($0.line) \($0.token)" }.joined(separator: "；"))")
    }
}

// MARK: - ES-02 ① 系：尺寸常量只许住 Core

@Suite("ES · 尺寸常量唯一住所")
struct ExportSizeSingleSourceTests {

    private let appFiles = esSwiftFiles(under: "MixCut")
    private let coreFiles = esSwiftFiles(under: "Sources/MixCutCore")

    @Test("App 侧不许出现任何画布尺寸字面量")
    func appHasNoCanvasLiterals() {
        let n = esCount(ExportSizeScan.coreOnlyTokens, inFiles: appFiles)
        #expect(n == 0, "App 侧又抄了一份尺寸常量（命中 \(n) 处）—— 改档位就得改 N 个文件，正是本次事故的形状")
    }

    @Test("Core 侧必须仍有这些常量（真源不能被顺手删空，否则上一条会恒绿）")
    func coreStillOwnsThem() {
        for token in ["width: 1080, height: 1920", "width: 720, height: 1280"] {
            let n = esCount([token], inFiles: coreFiles)
            #expect(n >= 1, "Core 里找不到 \(token) —— 真源被删空了，App 侧的 0 就成了假绿")
        }
    }
}

// MARK: - ES-03 扫描根健全性

@Suite("ES · 判据本身有没有跑起来")
struct ExportSizeScanRootTests {

    @Test("两侧遍历都必须真的扫到东西，否则上面所有 0 都是空的")
    func scanRootIsSane() {
        let app = esSwiftFiles(under: "MixCut")
        let core = esSwiftFiles(under: "Sources/MixCutCore")
        #expect(app.count >= 50, "只扫到 \(app.count) 个 App 源文件 —— 扫描根可能错了，判据没跑起来，不算通过")
        #expect(core.count >= 20, "只扫到 \(core.count) 个 Core 源文件 —— 扫描根可能错了，不算通过")
        #expect(app.contains("MixCut/Services/Export/DubExportService.swift"),
                "没扫到事故现场那颗文件，守卫作用不到它")
        #expect(core.contains("Sources/MixCutCore/DeliverySpec.swift"),
                "没扫到真源文件本身")
    }
}

// MARK: - ES-04 合法必绿（防误伤）

@Suite("ES · 既有正确代码不得被误伤")
struct ExportSizeNoFalsePositiveTests {

    /// 这四处在 2026-10-19 实测各自含一个"看着像尺寸"的裸数字，但都不是画布。
    /// 判据若改成扫裸数字，这四条会立刻红 —— 那正是本仓 `SheetSizeContractTests` 警告过的误伤。
    @Test("四处近邻字面量必须全部判绿", arguments: [
        "MixCut/Views/SegmentLibrary/ArrangeOrderSheet.swift",     // .frame(minWidth: 720, …)
        "MixCut/Services/ASR/ASRService.swift",                    // timeoutIntervalForResource = 7200
        "MixCut/Views/Shared/ThumbnailCache.swift",                // 文档注释里的「1080×1920」
        "MixCut/Services/ShotEdit/Wan25VideoEditClient.swift",     // 请求体 "720P"
    ])
    func neighboursStayGreen(_ rel: String) {
        let src = esRead(rel)
        #expect(src.count > 200, "读不到 \(rel) —— 这条必绿样本已经失效，先修路径再来谈误伤")
        let code = TagRowHostScan.codeOnly(src)
        for token in ExportSizeScan.coreOnlyTokens + ExportSizeScan.bannedEverywhere {
            #expect(ExportSizeScan.count(in: code, token) == 0,
                    "\(rel) 被判成含 \(token) —— 守卫过宽，会误伤既有正确代码")
        }
        #expect(ExportSizeScan.bannedHits(file: rel, src: src).isEmpty)
    }
}

// MARK: - ES-05 面板回显必须走 Core 同一函数

@Suite("ES · 面板回显不许自己拼")
struct ExportViewReadoutGuardTests {

    private let viewPath = "MixCut/Views/Export/ExportView.swift"

    @Test("ExportView 必须引用 DeliveryCanvas.readout")
    func viewMustDelegateReadoutToCore() {
        let src = esRead(viewPath)
        #expect(src.count > 3000, "读不到导出面板 —— 判据没跑起来，不算通过")
        let code = TagRowHostScan.codeOnly(src)
        #expect(ExportSizeScan.count(in: code, "DeliveryCanvas.readout") >= 1,
                "面板没有回显实际输出尺寸 ⇒ 又会回到「选了 480p 屏上一个字都没变」那个状态")
        // ⚠️ 这里**不**加"面板里不许出现「将输出」字样"那种反向禁字判据：
        // 手拼的回显活在字符串字面量里，而 codeOnly 会剥掉字符串 ⇒ 那条永远不会触发，
        // 是恒绿的假牙（本轮实测想过一次，靠变异腿才发现）。真正有牙的是上面这条正向在场。
    }

    @Test("变异腿：把回显换成面板手拼字符串 ⇒ 正向在场判据必须变红")
    func handAssembledReadoutTurnsItRed() {
        let src = esRead(viewPath)
        // 锚点取单行：多行锚点会因缩进对不上而静默不落地（本轮实测踩过一次）。
        let mutated = src.replacingOccurrences(
            of: "DeliveryCanvas.readout(target: exportConfig.deliveryTarget, tier: exportConfig.resolution)",
            with: "\"1080×1920\"")
        #expect(mutated != src, "变异没落地，对照作废")
        let code = TagRowHostScan.codeOnly(mutated)
        #expect(ExportSizeScan.count(in: code, "DeliveryCanvas.readout") == 0,
                "去掉 Core 调用后仍被判绿 ⇒ 上面那条正向在场判据是空的")
    }
}

// MARK: - ES-06 变异腿（证明判据有牙）

@Suite("ES · 变异腿")
struct ExportSizeMutationTests {

    @Test("变异1：把旧的第二份抄本注回 App ⇒ App 侧计数守卫必须变红")
    func reinjectSecondCopy() {
        let rel = "MixCut/Services/Export/DubExportService.swift"
        let src = esRead(rel)
        let mutated = src.replacingOccurrences(
            of: "    // MARK: - 分辨率",
            with: """
            private func legacyCanvas() -> DeliveryCanvas { DeliveryCanvas(width: 1080, height: 1920) }

                // MARK: - 分辨率
            """)
        #expect(mutated != src, "变异没落地，对照作废")
        let code = TagRowHostScan.codeOnly(mutated)
        #expect(ExportSizeScan.count(in: code, "width: 1080, height: 1920") >= 1,
                "注回的第二份抄本没被抓到 ⇒ ES-02 那条『App 侧为 0』是恒绿的假判据")
    }

    @Test("变异2：把 480p 档加回枚举 ⇒ ② 系守卫必须变红")
    func reinjectRetiredTier() {
        let rel = "Sources/MixCutCore/DeliverySpec.swift"
        let src = esRead(rel)
        let mutated = src.replacingOccurrences(
            of: "    case p720 = \"720p\"",
            with: "    case p720 = \"720p\"\n    case p480 = \"480p\"")
        #expect(mutated != src, "变异没落地，对照作废")
        let hits = ExportSizeScan.bannedHits(file: "fixture", src: mutated)
        #expect(!hits.isEmpty, "复活的 480p 档未被抓到 ⇒ ES-01 是恒绿的假判据")
    }

    @Test("变异3：把靶串藏进注释与字符串 ⇒ 必须仍判绿（自证 codeOnly 生效）")
    func tokensInsideCommentsAreStripped() {
        let decoy = """
        // 旧实现写死 "480:854"，整数上永远凑不出 9:16
        /* 曾抄过 width: 1080, height: 1920 一份 */
        let note = "case p480 已删除"
        """
        #expect(ExportSizeScan.bannedHits(file: "fixture", src: decoy).isEmpty,
                "注释/字符串里的靶串被判红 ⇒ codeOnly 没生效，真源扫描会假红一片")
        // 同一条管道的阳性对照：换个写法（挪进代码位）就必须抓到
        let real = "let canvas = DeliveryCanvas(width: 480, height: 854)"
        #expect(!ExportSizeScan.bannedHits(file: "fixture", src: real).isEmpty,
                "同形状的代码位写法没被抓到 ⇒ 这条阴性读数是假绿")
    }
}
