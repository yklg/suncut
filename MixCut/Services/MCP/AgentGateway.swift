import Foundation
import SwiftData

/// Agent 接入的装配与生命周期管理：持有 server、工具处理器、headless 导入 VM
@MainActor
final class AgentGateway {
    static let shared = AgentGateway()

    static let enabledKey = "agentServerEnabled"
    static let portKey = "agentServerPort"
    static let defaultPort: UInt16 = 8787

    private var server: MCPServer?
    private var handlers: MCPToolHandlers?
    private let importVM = ImportViewModel()
    private let jobs = AgentJobRegistry()
    /// 闸门自检钉住的那颗占位作业；nil = 本进程从没钉过（释放后也不重钉，见 holdGateJobForSelfTest）
    private var heldGateJobID: UUID?

    private init() {}

    /// 自动化实例专用端口覆盖。显式设了它，语义是「调用方要连的正是这个进程」——
    /// 所以这种实例绑不上端口时必须**响**（见 `restartFromSettings` 的退出分支），
    /// 不能像普通实例那样只弹一个 Toast：静默误路由会把请求打到持有该端口的另一个进程，也就是用户的活 App。
    static let portEnvironmentKey = "MIXCUT_MCP_PORT"

    static var isPortPinnedByEnvironment: Bool { portFromEnvironment != nil }

    /// 自动化实例专用：把全局作业闸门钉成「此刻已有一颗作业在跑」，N 秒后自动释放。
    /// 为什么要这颗占位作业：`ensureNoActiveJob()` 是 MCP 层唯一那道"第二路不许并发"的防线，
    /// import / retry / generate_schemes / export_scheme 四个入口共用它。判它"真拦得住"，
    /// 历史上只有一条腿 —— 先派一单**真活**（云端计费）再去抢第二个坑，
    /// 而且红不红取决于那次作业恰好跑了多久，本质是赌竞态。
    /// 占位作业把窗口变成确定的：判据先在**免费**入口 `export_scheme` 上取到拒因，
    /// 等它到期释放后拿同一份参数再取一次 —— 一拒一不拒成对出现，才能证明"拒"来自闸门、
    /// 不是来自我的参数（只取到一次拒，换谁都可能是在替一个假前提背书）。
    /// 生效条件收死在「被 env 钉了端口」这一类实例上：用户自己开的 App 永远进不来，也不写库。
    static let holdJobEnvironmentKey = "MIXCUT_SELFTEST_HOLD_JOB"

    private static var holdJobSeconds: Int? {
        guard isPortPinnedByEnvironment,
              let raw = ProcessInfo.processInfo.environment[holdJobEnvironmentKey],
              let seconds = Int(raw), seconds > 0 else { return nil }
        return seconds
    }

    private static var portFromEnvironment: UInt16? {
        guard let raw = ProcessInfo.processInfo.environment[portEnvironmentKey],
              let value = UInt16(raw), value > 0 else { return nil }
        return value
    }

    static var configuredPort: UInt16 {
        if let pinned = portFromEnvironment { return pinned }
        let stored = UserDefaults.standard.integer(forKey: portKey)
        guard stored > 0, stored <= 65535 else { return defaultPort }
        return UInt16(stored)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var registerCommand: String {
        "claude mcp add --transport http \(Brand.mcpServerName) http://127.0.0.1:\(configuredPort)/mcp"
    }

    func configure(container: ModelContainer) {
        importVM.setModelContext(container.mainContext)
        handlers = MCPToolHandlers(context: container.mainContext, importVM: importVM, jobs: jobs)
        restartFromSettings()
    }

    /// 按当前 UserDefaults 设置重启 server（开关/端口变更后调用）
    func restartFromSettings() {
        guard let handlers else { return }
        holdGateJobForSelfTest()
        let port = Self.configuredPort
        let enabled = Self.isEnabled
        let oldServer = server
        server = nil
        Task {
            await oldServer?.stop()
            guard enabled else { return }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            let newServer = MCPServer(port: port) { body in
                await Self.dispatch(body: body, handlers: handlers, serverVersion: version)
            }
            do {
                try await newServer.start()
                await MainActor.run { self.server = newServer }
            } catch {
                await MainActor.run {
                    // 由 env 钉了端口的实例：绑不上＝调用会落到持有端口的另一个进程（很可能是用户自己的
                    // 活 App + 活库）。这种静默误路由比"启动失败"危险得多，所以直接非零退出，让脚本当场看见。
                    if Self.isPortPinnedByEnvironment {
                        let line = "[MCP] \(Self.portEnvironmentKey)=\(port) 绑定失败："
                            + "\(error.localizedDescription)"
                            + "；本实例没拿到端口，继续跑会让调用打到持有该端口的另一个进程，故退出。\n"
                        FileHandle.standardError.write(Data(line.utf8))
                        exit(75)
                    }
                    ToastCenter.shared.show(
                        "Agent 服务启动失败：端口 \(port) 可能被占用，可在设置中修改",
                        icon: "antenna.radiowaves.left.and.right.slash", style: .error)
                }
            }
        }
    }

    /// 钉住闸门占位作业（只在 env 钉了端口且给了正秒数的自动化实例上发生）。
    /// 幂等且**只钉一次**：设置开关会反复走到这里，到期释放后不再重钉 ——
    /// 判据要的是"一次钉、一次放"那个完整往返；钉成循环会让"释放后同一份参数不再被拒"
    /// 那一格永远取不到读数，而那一格才是"拒因确实来自闸门"的唯一证明。
    /// 走 jobs.fail 而不是 finish：这颗作业从没产出任何东西，报 completed 是假话。
    private func holdGateJobForSelfTest() {
        guard heldGateJobID == nil, let seconds = Self.holdJobSeconds else { return }
        let job = jobs.begin(kind: .selftestGateHold, projectID: nil)
        heldGateJobID = job.id
        let registry = jobs
        MixLog.info("闸门自检：钉住占位作业 job_id=\(job.id.uuidString)"
            + "（\(Self.holdJobEnvironmentKey)=\(seconds)s，端口 \(Self.configuredPort) 的自动化实例，不落库）")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            registry.fail(job.id, message: "自检占位作业到期释放")
        }
    }

    /// JSON-RPC 分发：解析 → 路由 → 编码。返回 nil 表示 notification 无需应答。
    private static func dispatch(
        body: Data, handlers: MCPToolHandlers, serverVersion: String
    ) async -> Data? {
        switch MCPProtocol.parse(body) {
        case .initialize(let id):
            return MCPProtocol.initializeResponse(
                id: id, serverName: Brand.mcpServerName, serverVersion: serverVersion,
                instructions: AgentToolCatalog.serverInstructions)
        case .initializedNotification:
            return nil
        case .ping(let id):
            return MCPProtocol.pingResponse(id: id)
        case .toolsList(let id):
            return MCPProtocol.toolsListResponse(id: id, tools: AgentToolCatalog.all)
        case .toolsCall(let id, let name, let argumentsData):
            let outcome = await handlers.call(name: name, argumentsData: argumentsData)
            return MCPProtocol.toolCallResponse(id: id, resultJSON: outcome.json, isError: outcome.isError)
        case .invalid(let id, let code, let message):
            return MCPProtocol.errorResponse(id: id, code: code, message: message)
        }
    }
}
