import Foundation
import Testing

@testable import SunCut

// ============================================================================
// DI · 模型下载完整性链路（计划 v4 §15 的第二张测试表）
//
// 覆盖 `ASRService.downloadModelIfNeeded` 的**早退/拒绝/单飞**分支 —— 这些分支
// 不需要真下载 1.08GB，用三个注入点（modelDirectory / availableBytes / session）
// 即可在临时目录里隔离验证，不碰用户真实模型目录、不联网、不花钱。
//
// 为什么只测这些分支：体积/sha256/416/total 的"下载后校验"逻辑需要喂 1.08GB 的
// 真实字节流才能走到 move 点，在单测里造这么大的夹具不现实；那部分由 Core 层的
// EngineModelStateTests（五态判定）+ 真机 App 手工验收（首启下载全链路）覆盖。
// 本文件钉住的是"下载之前"的守门分支 —— 它们是纯决策、零网络，正是最容易回归的地方。
//
// ⚠️ 本文件属 MixCutAppTests（@testable import SunCut），由 Xcode 的 SunCutAppTests
// target 运行；SwiftPM 的 `swift test` 只跑 MixCutCore，不含这里。
// ============================================================================

@Suite("DI · 模型下载守门分支（预检三态 / 磁盘 / 单飞）")
struct DownloadIntegrityTests {

    private func tempModelDir(_ name: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("di-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// DI-1 磁盘空间不足 ⇒ 直接拒绝，且不留任何 partial/lock 文件。
    @Test("DI-1 磁盘空间不足直接拒绝，不联网不落盘")
    func insufficientDiskRejectedBeforeDownload() async throws {
        let dir = tempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asr = ASRService()
        do {
            _ = try await asr.downloadModelIfNeeded(
                session: URLSession(configuration: .ephemeral),
                availableBytes: 0,              // 模拟磁盘已满
                modelDirectory: dir
            )
            Issue.record("磁盘空间不足应抛错，不该返回路径")
        } catch let e as ASRService.ASRError {
            guard case .insufficientDiskSpace = e else {
                Issue.record("错误类型应为 insufficientDiskSpace，实际 \(e)")
                return
            }
        }
        // 守门失败发生在下载前 ⇒ 目录里不该留下任何下载中间物
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty, "磁盘预检失败不该落盘，实际残留 \(leftovers)")
    }

    /// DI-2 表无精确字节的档（base）已存在 ⇒ 早退返回该路径，不触发下载。
    /// 这钉住"表无精确值时跳过 L3/L4 比较"的既有语义（红线 R2 的一部分）。
    @Test("DI-2 无精确字节的档已存在即早退（跳过体积校验）")
    func tierWithoutExactBytesEarlyReturns() async throws {
        let dir = tempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tier = try #require(WhisperModelCatalog.tier(named: "base"))
        #expect(tier.expectedBytes == nil, "夹具自检：base 应无精确字节")

        // 写一个"体积随便"的文件：表无精确值 ⇒ sizeMatches=true 且无 sha ⇒ 早退
        let fakePath = dir.appendingPathComponent(tier.fileName).path
        try Data("fake".utf8).write(to: URL(fileURLWithPath: fakePath))

        let asr = ASRService()
        let returned = try await asr.downloadModelIfNeeded(
            modelName: tier.fileName,
            session: URLSession(configuration: .ephemeral),
            availableBytes: nil,
            modelDirectory: dir
        )
        #expect(returned == fakePath, "已存在的无校验档应早退返回原路径")
        #expect(FileManager.default.fileExists(atPath: fakePath), "早退不该删除已有文件")
    }

    /// DI-3 单飞锁：预置 .lock 文件 ⇒ 报"另一实例正在下载"，且不碰已有 dest。
    @Test("DI-3 .lock 被占用时拒绝，不覆盖已有模型")
    func existingLockRejects() async throws {
        let dir = tempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelName = ASRPolicy.engineFileName
        let dest = dir.appendingPathComponent(modelName)
        let lock = dir.appendingPathComponent(modelName + ".lock")
        try Data("existing".utf8).write(to: dest)
        try Data("lock".utf8).write(to: lock)   // 模拟另一实例持锁

        let asr = ASRService()
        do {
            _ = try await asr.downloadModelIfNeeded(
                modelName: modelName,
                session: URLSession(configuration: .ephemeral),
                availableBytes: nil,
                modelDirectory: dir
            )
            Issue.record(".lock 被占用应抛 downloadInProgressByAnotherInstance")
        } catch let e as ASRService.ASRError {
            guard case .downloadInProgressByAnotherInstance = e else {
                Issue.record("错误类型应为 downloadInProgressByAnotherInstance，实际 \(e)")
                return
            }
        }
        // 拒绝后已有模型与锁都原样保留（defer 释放锁是"本实例持锁"那条路径，此处没拿到锁）
        #expect((try? Data(contentsOf: dest)) == Data("existing".utf8), "不该覆盖已有模型")
        #expect(FileManager.default.fileExists(atPath: lock.path), "不该删掉别实例的锁")
    }

    /// DI-4 引擎档存在但体积不符 ⇒ 先删除可疑文件再下载（这里用磁盘预检截断，验证"删了"）。
    /// 用 availableBytes=0 让删除后立刻在磁盘预检处失败，隔离出"预检删坏文件"这一步。
    @Test("DI-4 体积不符的引擎档被预检删除，不留可疑文件")
    func truncatedEngineFileRemovedOnPrecheck() async throws {
        let dir = tempModelDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tier = try #require(ASRService.engineTier)
        let expected = try #require(tier.expectedBytes)
        let dest = dir.appendingPathComponent(tier.fileName)
        // 造一个"体积明显不符"的坏文件（只写少量字节，不造 1GB）
        try Data("truncated".utf8).write(to: dest)

        let asr = ASRService()
        do {
            _ = try await asr.downloadModelIfNeeded(
                modelName: tier.fileName,
                session: URLSession(configuration: .ephemeral),
                availableBytes: 0,              // 删完立刻在磁盘预检处停住
                modelDirectory: dir
            )
            Issue.record("本用例预期在磁盘预检处抛错")
        } catch let e as ASRService.ASRError {
            guard case .insufficientDiskSpace = e else {
                Issue.record("应走到磁盘预检错误，实际 \(e)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path), "体积不符的坏文件应已被预检删除")
    }

    /// DI-5 表值 Helper 与表同源（钉住 expectedBytes/expectedSHA256 的取法）。
    @Test("DI-5 expectedBytes / expectedSHA256 从档位表同源取")
    func tableHelpersAreSameSourced() throws {
        let tier = try #require(ASRService.engineTier)
        #expect(ASRService.expectedBytes(forModelNamed: tier.fileName) == tier.expectedBytes)
        #expect(ASRService.expectedSHA256(forModelNamed: tier.fileName) == tier.expectedSHA256)
        // 引擎档两项都必须有值（sha256 已从 HF LFS oid 取到，不是 nil 未覆盖）
        #expect(tier.expectedBytes != nil)
        #expect(tier.expectedSHA256?.count == 64, "sha256 应为 64 位十六进制")
    }
}
