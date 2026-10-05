import Foundation
import Testing

/// 一键改写「任务归属层级」修复的架构守卫。
///
/// 被守的 bug：忙碌/进度按视频键控，任务句柄却挂在分镜检查器 @State 上，
/// .id(segment.id) 一切换子树就 cancel 视频级付费管线 → 取消还被当成失败弹窗。
/// 修复后句柄归 DubbingJobRegistry（MixCutCore，有运行时测试），App 层这些结构性
/// 约束 swift test 跑不到视图/Service，只能像 InspectorSegmentIdentityGuard 一样
/// 用源码扫描钉死，每条配变异腿自证。
@Suite("DubbingTaskOwnership 守卫（真实代码）")
struct DubbingTaskOwnershipGuardTests {

    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/MixCutCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 包根

    private func read(_ rel: String) -> String {
        (try? String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    private func code(_ rel: String) -> String {
        String(TagRowHostScan.codeOnly(read(rel)))
    }

    private let inspector = "MixCut/Views/SegmentLibrary/SegmentVariantInspector.swift"
    private let bar = "MixCut/Views/SegmentLibrary/DubSettingsBar.swift"
    private let library = "MixCut/Views/SegmentLibrary/SegmentLibraryView.swift"
    private let vm = "MixCut/ViewModels/DubbingViewModel.swift"
    private let sep = "MixCut/Services/TTS/VocalSeparationService.swift"
    private let ff = "MixCut/Services/VideoProcessing/FFmpegRunner.swift"
    private let registry = "Sources/MixCutCore/DubbingJobRegistry.swift"

    private func count(_ pattern: String, in text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            Issue.record("守卫自身正则坏掉：\(pattern)"); return 0
        }
        return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private func window(in code: String, from anchor: String, chars: Int) -> String? {
        guard let range = code.range(of: anchor) else { return nil }
        let end = code.index(range.lowerBound, offsetBy: min(chars, code.distance(from: range.lowerBound, to: code.endIndex)),
                             limitedBy: code.endIndex) ?? code.endIndex
        return String(code[range.lowerBound..<end])
    }

    // MARK: G1 检查器不得再持有任务 / onDisappear 取消

    @Test("G1 检查器源码不得再出现 runningTasks/cancelRunningTasks/onDisappear 取消")
    func inspectorMustNotOwnTasks() {
        let src = code(inspector)
        #expect(src.count > 500, "检查器读不到 —— 判据失效")
        #expect(!src.contains("runningTasks"), "任务句柄逃回分镜 @State，切换素材会再次连带取消")
        #expect(!src.contains("cancelRunningTasks"))
        #expect(!src.contains(".onDisappear"), "onDisappear 取消链必须只在任务归属修正后整体移除")
    }

    @Test("G1 变异腿：插回 runningTasks 必须变红")
    func g1MutationTurnsRed() {
        let src = code(inspector) + "\n@State private var runningTasks: [Task<Void, Never>] = []"
        #expect(src.contains("runningTasks"))
    }

    // MARK: G2 入口必须走 VM 注册表

    @Test("G2a 检查器必须通过 startRewriteTask / startManualVariantTask 发起任务")
    func inspectorUsesStarts() {
        let src = code(inspector)
        #expect(src.contains("startRewriteTask("))
        #expect(src.contains("startManualVariantTask("))
    }

    @Test("G2b DubSettingsBar 不得再裸调 dubVM.rewrite（必须走 startRewriteTask）")
    func barHasNoBareRewrite() {
        let src = code(bar)
        #expect(src.contains("startRewriteTask("))
        #expect(!src.contains("dubVM.rewrite("), "裸 await dubVM.rewrite 的句柄无人登记，无法停止")
        #expect(!src.contains("Task {"), "标题行不得保留裸 Task 壳")
    }

    // MARK: G3/G4 广播订阅与禁载约束

    @Test("G3 VM 必须以 target-action 订阅 .mixCutDataDidUndo 且 deinit removeObserver(self)")
    func vmSubscribesToBroadcast() {
        let src = code(vm)
        // addObserver( 与 self 之间允许换行/空白（真实代码跨行）。
        #expect(firstMatch(src, pattern: "addObserver\\(\\s*self,") != nil,
                "删除广播订阅缺失：素材被删后任务会继续写死实体")
        #expect(src.contains("name: .mixCutDataDidUndo"))
        #expect(src.contains("#selector(handleGraphChange"))
        #expect(src.contains("removeObserver(self)"), "必须 deinit 移除观察者（target-action 形态）")
        // 不允许回退到 block-token：那会重新引入跨隔离属性 / init 逃逸闭包捕获两条编译约束。
        #expect(!src.contains("forName: .mixCutDataDidUndo"),
                "订阅形态应统一为 target-action，不得回退 block-token 观察者")
    }

    @Test("G4 删除处理函数窗口内禁止 load/fetch/save/flush/delete（防同栈递归）")
    func observerClosureMustNotReload() {
        let src = code(vm)
        guard let win = window(in: src, from: "func handleDataDeletion", chars: 460) else {
            Issue.record("找不到 handleDataDeletion 锚点 —— 判据失效"); return
        }
        for banned in ["loadSegments", "fetchProjects", "safeSave", "flushNow", "context.delete"] {
            #expect(!win.contains(banned), "删除处理函数里出现 \(banned)：同步 post 栈内重入，前案 P0 复发")
        }
    }

    @Test("G4 变异腿：处理函数窗口插入 loadSegments 必须被检出")
    func g4MutationDetected() {
        let fake = "func handleDataDeletion() { loadSegments(); cancelJobs() }"
        #expect(fake.contains("loadSegments"))
    }

    // MARK: G5 换项目必须取消全部作业

    @Test("G5 SegmentLibraryView 的 .task(id: project.id) 窗口内必须有 cancelAllJobs")
    func projectSwitchCancelsJobs() {
        let src = code(library)
        guard let win = window(in: src, from: ".task(id: project.id)", chars: 700) else {
            Issue.record("找不到 .task(id: project.id) 锚点"); return
        }
        #expect(win.contains("cancelAllJobs"), "换项目必须静默停掉旧项目的视频级作业")
        #expect(win.contains(".projectSwitch"))
    }

    @Test("G5 变异腿：删掉 cancelAllJobs 调用必须被检出")
    func g5MutationDetected() {
        let fake = ".task(id: project.id) { importVM.setModelContext(modelContext) }"
        #expect(!fake.contains("cancelAllJobs"))
    }

    // MARK: G6 demucs 必须真停进程

    @Test("G6 runDemucs 必须包 withTaskCancellationHandler 且 stdin 显式接 /dev/null")
    func demucsCancellationHandlerPresent() {
        let src = code(sep)
        #expect(src.contains("withTaskCancellationHandler"),
                "没有取消处理器时 Task 取消后 demucs 子进程仍在跑，CPU/配额照烧")
        #expect(src.contains("DemucsLineAccumulator"), "stdout 百分比必须经累加器解析")
        #expect(src.contains("standardInput = FileHandle.nullDevice"),
                "demucs stdin 未接管：终端启动继承 tty / Finder 启动继承 EOF，行为随启动方式漂移")
    }

    // MARK: G7 取消中性化落点计数

    @Test("G7 VM 中 Task.isCancelled 中性分支 ≥5 处（克隆后/轮顶/catch/合成尾/编辑保存）")
    func cancellationNeutralizedEverywhere() {
        let src = code(vm)
        let n = count(#"Task\.isCancelled"#, in: src)
        #expect(n >= 5, "取消中性化落点不足（实得 \(n)）：必有一条链路把取消当失败弹窗")
    }

    // MARK: G8 死实体过门计数

    @Test("G8 VM 中 isDroppedFromContext 过门 ≥4 处（克隆写回/回写循环/pending 收集/逐段合成）")
    func droppedEntityGuardsPresent() {
        let src = code(vm)
        let n = count(#"isDroppedFromContext"#, in: src)
        #expect(n >= 4, "句柄脱离视图后删除窗口缺少死实体过门（实得 \(n)），会产生墓碑写")
    }

    // MARK: G9 注册表必须在 Core（可测性架构约束）

    @Test("G9 DubbingJobRegistry 必须位于 MixCutCore 且标注 @MainActor")
    func registryLivesInCore() {
        let url = repoRoot.appendingPathComponent(registry)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "注册表逃回 App target 后并发契约无法 swift test")
        let src = code(registry)
        // @MainActor 与类声明允许跨行（修饰符独立成行）。
        #expect(src.contains("@MainActor"))
        #expect(src.contains("public final class DubbingJobRegistry"))
        #expect(!src.contains("import SwiftUI"), "Core 注册表不得引入 SwiftUI/Observation 依赖")
    }

    // MARK: G10 子进程生命周期卫生（ffmpeg 路径与 demucs 可靠路径同构）

    @Test("G10 FFmpegRunner 必须统一 null stdin + -nostdin + 非阻塞管道收尾 + 生命周期埋点")
    func ffProcessHygiene() {
        // 结构断言走 codeOnly（剥注释/字符串，防注释假红）；
        // 字符串内容断言（-nostdin 参数、埋点格式）走原始文本并带引号锚定，注释里不会同形。
        let src = code(ff)
        let raw = read(ff)
        // 4 处 Process 统一走 makeProcess（内含 stdin=/dev/null），不得再各自 new Process 漏接管。
        #expect(src.contains("static func makeProcess"), "子进程配置必须收口到单一 helper")
        #expect(src.contains("process.standardInput = FileHandle.nullDevice"),
                "stdin 未接管：ffmpeg 行为随启动方式（tty/EOF）漂移")
        #expect(raw.contains(#""-nostdin""#), "ffmpeg 自动化调用必须显式 -nostdin（官方要求）")
        // 禁止在 terminationHandler 线程做阻塞读（曾产生无主 PIPE 残骸）。
        #expect(!src.contains("readDataToEndOfFile"),
                "禁止在终止回调里同步读到 EOF：必须运行期 readabilityHandler 排空")
        // 生命周期埋点：挂死时分得清「没启动 / 不退出 / 异常退出」。
        #expect(raw.contains("[FF] launched pid="), "缺进程启动埋点")
        #expect(raw.contains("[FF] exit rc="), "缺进程退出埋点")
    }

    @Test("G10 变异腿：终止回调插回 readDataToEndOfFile 必须被检出")
    func g10MutationDetected() {
        let fake = "terminationHandler = { _ in let d = pipe.fileHandleForReading.readDataToEndOfFile() }"
        #expect(fake.contains("readDataToEndOfFile"))
    }

    // MARK: G11 注册表必须进程级共享（UI/MCP/导出跨实例互斥）

    @Test("G11 DubbingJobRegistry 必须提供进程级 shared，VM 必须引用 shared 而非各建实例")
    func registrySharedAcrossInstances() {
        let regSrc = code(registry)
        #expect(regSrc.contains("public static let shared"),
                "视频是进程级共享资源（素材/付费音色），忙碌互斥也必须进程级；缺 shared 时 UI 与 MCP 会并发克隆")
        // 保留 public init()：单测必须能用独立实例隔离。
        #expect(regSrc.contains("public init()"), "shared 不得挤掉 public init()（测试隔离需要）")
        let vmSrc = code(vm)
        #expect(vmSrc.contains("DubbingJobRegistry.shared"),
                "VM 自建 DubbingJobRegistry() 会让 UI/MCP/导出的忙碌状态互不可见")
    }

    @Test("G11 变异腿：VM 回退自建实例必须被检出")
    func g11MutationDetected() {
        let fake = "let registry = DubbingJobRegistry()"
        #expect(fake.contains("DubbingJobRegistry()"))
        #expect(!fake.contains(".shared"))
    }
}
