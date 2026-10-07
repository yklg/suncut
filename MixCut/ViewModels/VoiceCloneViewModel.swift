import Foundation
import SwiftData
import SwiftUI

/// 复刻音色库的写入收口（M2）。
///
/// ## 为什么单独一个 VM
///
/// 本仓纪律：视图**不直写** SwiftData 字段（见G-V7「写入收口」）。
/// 复刻库有四个写入点（注册落库 / 重命名 / 删除本地记录 / 远端注销），
/// 散在视图里各写各的必然出现「删了库记录但远端没注销」这类半截状态。
///
/// ## 删除的两阶段（重要）
///
/// 远端注销是**网络操作、可能失败**，本地删记录是**本地操作、必成功**。
/// 口径固定为「先删本地、再试远端」：
/// - 远端成功 → 配额释放，用户得到想要的结果；
/// - 远端失败 → **本地已删、远端仍占配额**，此时如实提示即可。
///   反过来（先删远端再删本地）若远端失败，本地记录还在而远端已注销，
///   用户会拿到一个「看起来存在但合成必失败」的僵尸音色 —— 更糟。
@MainActor
@Observable
final class VoiceCloneViewModel {

    /// 一次性提示（成功/失败/部分失败），由视图消费后清空。
    var message: CloneLibraryMessage?

    struct CloneLibraryMessage: Identifiable, Equatable {
        enum Kind: Equatable { case success, warning, failure }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    // MARK: - 注册

    /// 注册一个新复刻音色并落库。
    /// - Parameters:
    ///   - displayName: 用户填的名字。
    ///   - samplePath: 已准备好的合规样本路径（10–20s/≤10MB）。
    ///   - consentAccepted: 授权确认。**必须 true**（服务层也会再挡一次，双保险）。
    func register(displayName: String,
                  samplePath: String,
                  sampleDuration: Double,
                  consentAccepted: Bool,
                  kind: CloneProfileKind,
                  context: ModelContext) async {
        let fp = Self.currentKeyFingerprint()
        do {
            let profile = try await CloneRegistrationService().register(
                displayName: displayName,
                samplePath: samplePath,
                sampleDuration: sampleDuration,
                consentAccepted: consentAccepted,
                kind: kind,
                keyFingerprint: fp)
            context.insert(profile)
            // 授权确认时间：注册成功那一刻落（而不是向导勾选那一刻）——
            // 「授权已确认」与「音色已注册」应当是同一时刻的事实。
            profile.recordConsent()
            context.safeSave()
            message = .init(kind: .success, text: "音色「\(profile.name)」已注册，可直接在全局音色里选用。")
        } catch {
            message = .init(kind: .failure, text: FriendlyError.reason(for: error))
        }
    }

    // MARK: - 重命名

    func rename(_ profile: VoiceProfile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = .init(kind: .warning, text: "音色名不能为空。")
            return
        }
        profile.name = trimmed
        safeSaveOrReport("重命名音色")
    }

    // MARK: - 删除

    /// 删除一个复刻音色。
    /// - Parameter scope: 仅删本地 / 同时注销远端释放配额。
    func delete(_ profile: VoiceProfile, scope: CloneProfileDeletion.Scope, context: ModelContext) async {
        let name = profile.name
        let voiceId = profile.voiceId
        context.delete(profile)
        context.safeSave()

        guard scope == .alsoRevokeRemote else {
            message = .init(kind: .success,
                            text: "已删除「\(name)」。已生成的配音全部保留；远端音色仍占配额。")
            return
        }
        // 本地已删（上面），远端单独试。失败**不回滚本地**（见类型注释的两阶段理由）。
        do {
            try await VoiceCloneRemoteService().revoke(voiceId: voiceId)
            message = .init(kind: .success,
                            text: "已删除「\(name)」并注销远端音色，配额已释放。已生成的配音全部保留。")
        } catch {
            message = .init(kind: .warning,
                            text: "已删除「\(name)」，但远端注销失败（\(FriendlyError.reason(for: error))）。"
                               + "音色不再可用，远端仍占配额，可在阿里云控制台手动删除。")
        }
    }

    // MARK: - 读侧

    /// 当前 Key 的指纹（nil = 未配置 Key）。供 UI 判断音色是否置灰。
    static func currentKeyFingerprint() -> String {
        guard let key = KeychainHelper.getAPIKey(for: .qwen), !key.isEmpty else { return "" }
        return KeyFingerprint.of(key)
    }

    private func safeSaveOrReport(_ what: String) {
        do { try modelContext?.save() }
        catch {
            message = .init(kind: .failure, text: "\(what)失败：\(error.localizedDescription)")
        }
    }

    /// 由视图注入的上下文（VM 不在 init 里拿，避免与`@Query` 的生命周期打架）。
    var modelContext: ModelContext?
}