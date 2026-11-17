import Foundation

/// whisper.cpp 语音模型的**档位目录**（计划 §3.2）。
///
/// 三件事，且只做这三件：识别磁盘上有几颗什么档、按根优先级挑出引擎实际会用哪颗、逐层报告哪颗可用/损坏/未识别。
///
/// **不做**的事：不读磁盘、不读 UserDefaults、不否决可用性。
/// 四层就绪里只有 L1（有没有文件）决定"能不能跑"；L2/L3/L4 一律只出提示 ——
/// 把 L3（体积校验）当运行期否决，会让用户自下的量化档或官方重新发布导致的字节漂移直接变成"没模型"。
public enum ModelRoot: Int, CaseIterable, Comparable, Sendable {
    /// 用户自己的模型目录（`~/Library/Application Support/MixCut/whisper-models/`）
    case userDirectory
    /// App 包内置（`Contents/Resources/bin/`，由 `build_universal_binaries.sh` 放入）
    case appBundle
    /// 旧版缓存目录（历史兼容，一次性迁移读取）
    case legacyCache
    /// 系统目录（`~/.cache/...`、`/opt/homebrew/share/whisper/models` 等）
    case systemDirectory

    public static func < (lhs: ModelRoot, rhs: ModelRoot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 一颗候选模型文件。**由调用方（App 侧）stat 好后传进来** —— 本模块不碰文件系统。
public struct ModelFile: Equatable, Sendable {
    public let root: ModelRoot
    public let fileName: String
    public let byteCount: Int64
    /// L2：文件头是不是 ggml（magic 可读）
    public let headerIsGGML: Bool
    public let path: String

    public init(root: ModelRoot, fileName: String, byteCount: Int64, headerIsGGML: Bool, path: String) {
        self.root = root
        self.fileName = fileName
        self.byteCount = byteCount
        self.headerIsGGML = headerIsGGML
        self.path = path
    }
}

public enum ModelIssue: Equatable, Sendable {
    /// L3：体积与表值不符（可能下断了）。表里没有精确值时**不出这条**。
    case truncated(expected: Int64, actual: Int64)
    /// L2：文件头不是 ggml ⇒ 损坏或不是 whisper 模型
    case badHeader
    /// L4：文件名命中不了档位表 ⇒ 档位未知，但仍在用
    case tierUnknown
}

/// **引擎档**模型状态（计划 v4 §4.1）—— 与 `ModelIssue` 的区别是：这里只判引擎实际
/// 要跑的那一颗（`ASRPolicy.engineFileName`），五态互斥、取首个命中。
///
/// 优先级（互斥，取首个命中）：`missing → truncated → badHeader → readyUnverified → ready`。
/// 体积不符是"下了一半"的强信号，优先于坏头；坏头又优先于"未校验"。
///
/// ⚠️ **红线 R2**：`engineState` 只作"下载/修复入口"判据，**不是可用性判据**。
/// 它不许否决 `ModelReport.usable` —— 用户目录里放了一颗 f16 大档而引擎档缺失时，
/// `usable == true`（有任意候选）但 `engineState == .missing`，这是刻意保留的区分。
public enum EngineModelState: Equatable, Sendable {
    /// 引擎档不在任何根里
    case missing
    /// 引擎档存在但体积与表值不符（下了一半）
    case truncated(expected: Int64, actual: Int64)
    /// 引擎档字节数对但文件头非 ggml/lmgg
    case badHeader
    /// 引擎档存在，但表里没有精确字节 ⇒ L3 跳过，只能算"未校验"
    case readyUnverified
    /// 引擎档字节对、头正常
    case ready
}

public struct ModelReport: Equatable, Sendable {
    /// 引擎实际会用的那颗；候选为空时 nil
    public let selected: ModelFile?
    /// 选中那颗的档位名；未识别档为 nil
    public let selectedTier: String?
    /// L1：有任意可读候选即 true —— 永不因 L2/L3/L4 变 false
    public let usable: Bool
    /// 逐颗文件的提示（去重，按挑档顺序）
    public let issues: [ModelIssue]
    /// 全部候选，**已按挑档顺序排好**（第 0 个就是 `selected`）。
    /// 界面靠它报「另检测到 base（未使用）」；与 `selected` 出自同一次扫描 ⇒ 报告与实际用颗不会分家。
    public let detected: [ModelFile]
    /// 引擎档状态。**默认 nil** —— 仅当调用方传了 `engine` 时才有值。
    /// 这样 §12 记的生产 1 处 + 测试 18 处旧调用逐字不变（红线：usable 语义不动）。
    public let engineState: EngineModelState?

    public init(selected: ModelFile?, selectedTier: String?, usable: Bool,
                issues: [ModelIssue], detected: [ModelFile] = [],
                engineState: EngineModelState? = nil) {
        self.selected = selected
        self.selectedTier = selectedTier
        self.usable = usable
        self.issues = issues
        self.detected = detected
        self.engineState = engineState
    }
}

/// 一个档位。`expectedBytes == nil` 表示**官方只给过四舍五入的体积**，
/// 此时跳过 L3 比较 —— 拿近似值当预期值去比，是本项目定过要避免的"预期值要有来源"。
public struct WhisperTier: Equatable, Sendable {
    public let name: String
    public let fileName: String
    public let expectedBytes: Int64?
    /// 官方 LFS oid（即文件 sha256），用于下载后内容校验 —— 字节数防不了同长度替换。
    /// 仅取到确切 oid 的档填值；取不到留 nil 并在计划的"未覆盖"处登记，**不编造**。
    public let expectedSHA256: String?
    public let downloadURLs: [String]

    /// 自定义 init 带默认值，避免给既有 6 处构造点全部加 sha256 参数（未取到 oid 的档保持 nil）。
    public init(name: String, fileName: String, expectedBytes: Int64?,
                expectedSHA256: String? = nil, downloadURLs: [String]) {
        self.name = name
        self.fileName = fileName
        self.expectedBytes = expectedBytes
        self.expectedSHA256 = expectedSHA256
        self.downloadURLs = downloadURLs
    }
}

public enum WhisperModelCatalog {

    /// 优先级顺序即挑档顺序（大档在前）。
    ///
    /// **下载源只有 hf-mirror.com**（用户决策：只留国内源、不发境外请求）。
    /// 手动兜底路径：用户可把自己的模型放进 `~/Library/Application Support/MixCut/whisper-models/`，
    /// 该文件会被 scan 命中并优先于包内（根顺序 userDirectory 第一），无需走下载。
    public static let table: [WhisperTier] = [
        WhisperTier(name: "large-v3", fileName: "ggml-large-v3.bin", expectedBytes: 3_095_033_483,
                    downloadURLs: ["https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"]),
        WhisperTier(name: "large-v3-turbo", fileName: "ggml-large-v3-turbo.bin", expectedBytes: 1_624_555_275,
                    downloadURLs: ["https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"]),
        // 引擎档。expectedSHA256 取自 hf-mirror 模型树 API 的 lfs.oid（2026-11-16 实测），
        // 与 expectedBytes 1,081,140,203 出自同一条记录，两值同源。
        WhisperTier(name: "large-v3-q5_0", fileName: "ggml-large-v3-q5_0.bin", expectedBytes: 1_081_140_203,
                    expectedSHA256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
                    downloadURLs: ["https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"]),
        // 以下三档官方发布页只给到"约 1.43GB / 465MB / 141.1MB"这种四舍五入值，
        // 未取到精确字节 ⇒ expectedBytes 留 nil，L3 不比较（不是"随便填个数"）。
        WhisperTier(name: "medium", fileName: "ggml-medium.bin", expectedBytes: nil,
                    downloadURLs: ["https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"]),
        WhisperTier(name: "small", fileName: "ggml-small.bin", expectedBytes: nil,
                    downloadURLs: ["https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"]),
        WhisperTier(name: "base", fileName: "ggml-base.bin", expectedBytes: nil,
                    downloadURLs: ["https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"]),
    ]

    public static var tiers: [String] { table.map { $0.name } }

    public static func tier(named name: String) -> WhisperTier? {
        table.first { $0.name == name }
    }

    /// 表值。未校验档位返回 nil（调用方须跳过 L3，不许拿它当"体积不对"）。
    public static func expectedBytes(forTier name: String) -> Int64? {
        tier(named: name)?.expectedBytes
    }

    public static func downloadURLs(forTier name: String) -> [String] {
        tier(named: name)?.downloadURLs ?? []
    }

    /// L4：文件名 → 档位名。`ggml-weird.bin` 这种返回 nil（"检测到但未使用"，不是"没有模型"）。
    public static func tier(ofFileName fileName: String) -> String? {
        table.first { $0.fileName == fileName }?.name
    }

    public static func fileName(forTier name: String) -> String? {
        tier(named: name)?.fileName
    }

    /// 挑档 + 逐层报告。
    ///
    /// 顺序 = **根优先，再按档位**（v5 裁定项：磁盘用户目录 > 包内 > 旧缓存 > 系统目录）。
    /// 注意这与今天 `ASRService.findWhisperCppModel` 的"先跑完包内整轮再换磁盘"相反 —— 那是本轮要改掉的行为，
    /// 因为包内置 turbo 会永远压住用户自下的大档。
    public static func report(files: [ModelFile], engine: WhisperTier? = nil) -> ModelReport {
        // 引擎态只由引擎档的候选决定 —— 与 usable/L1 完全独立（红线 R2）。
        // 传 nil 时 engineState == nil，下面所有既有字段逐字不变。
        let resolvedEngineState = engine.map { engineState(of: $0, in: files) }

        guard !files.isEmpty else {
            return ModelReport(selected: nil, selectedTier: nil, usable: false, issues: [],
                               detected: [], engineState: resolvedEngineState)
        }

        func tierRank(_ file: ModelFile) -> Int {
            guard let name = tier(ofFileName: file.fileName),
                  let index = table.firstIndex(where: { $0.name == name }) else { return Int.max }
            return index
        }

        // 同档同根时保持输入顺序稳定（App 侧按根顺序喂入即可）
        let ranked = files.enumerated().sorted { a, b in
            let ra = tierRank(a.element), rb = tierRank(b.element)
            if ra != rb { return ra < rb }
            if a.element.root != b.element.root { return a.element.root < b.element.root }
            return a.offset < b.offset
        }
        let ordered = ranked.map { $0.element }
        let selected = ordered[0]

        var seen: [ModelIssue] = []
        for file in ordered {
            var fileIssues: [ModelIssue] = []
            if !file.headerIsGGML { fileIssues.append(.badHeader) }
            if let name = tier(ofFileName: file.fileName) {
                if let expected = expectedBytes(forTier: name), file.byteCount != expected {
                    fileIssues.append(.truncated(expected: expected, actual: file.byteCount))
                }
            } else {
                fileIssues.append(.tierUnknown)
            }
            for issue in fileIssues where !seen.contains(issue) {
                seen.append(issue)
            }
        }

        return ModelReport(selected: selected,
                           selectedTier: tier(ofFileName: selected.fileName),
                           usable: true,
                           issues: seen,
                           detected: ordered,
                           engineState: resolvedEngineState)
    }

    /// 引擎档五态判定（计划 v4 §4.1）。优先级互斥，取首个命中：
    /// `missing → truncated → badHeader → readyUnverified → ready`。
    ///
    /// 只认文件名 == `engine.fileName` 的候选；同一引擎档在多个根出现时，
    /// 按挑档顺序取最靠前那颗（与 `selected` 同源——用户目录优先）。
    /// 体积不符优先于坏头（下了一半是更强的"要重下"信号）。
    private static func engineState(of engine: WhisperTier, in files: [ModelFile]) -> EngineModelState {
        guard let target = files.filter({ $0.fileName == engine.fileName })
                                .min(by: { $0.root < $1.root }) else {
            return .missing
        }
        // ① truncated：表里有精确字节且不符（优先于坏头）
        if let expected = engine.expectedBytes, target.byteCount != expected {
            return .truncated(expected: expected, actual: target.byteCount)
        }
        // ② badHeader：字节数对（或表无精确值）但文件头非 ggml
        if !target.headerIsGGML { return .badHeader }
        // ③ readyUnverified：表里没有精确字节 ⇒ L3 跳过，只能算未校验
        if engine.expectedBytes == nil { return .readyUnverified }
        // ④ ready
        return .ready
    }
}
