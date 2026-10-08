import SwiftUI
import SwiftData

/// 我的复刻音色库（M2）：列出账号级复刻音色 + 删除（仅本地 / 同时注销远端）。
///
/// 复用约束（同 `VoicePickerSheet` 的中立纪律）：
/// - 视图**不持有也不调用** `DubbingViewModel`（那是配音管线的 VM，与音色库无关）；
/// - 删除走 `VoiceCloneViewModel` 的收口方法，视图不直写 SwiftData 字段。
struct CloneLibrarySection: View {
    let profiles: [VoiceProfile]
    let currentKeyFingerprint: String?
    let onRegister: () -> Void
    let onDelete: (VoiceProfile, CloneProfileDeletion.Scope) -> Void
    let onRename: (VoiceProfile, String) -> Void

    @State private var pendingDeletion: (VoiceProfile, CloneProfileDeletion.Scope)?
    @State private var renameTarget: VoiceProfile?
    @State private var renameText = ""
    @State private var auditionPlayer = VoiceAuditionPlayer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            if profiles.isEmpty {
                Text("还没有复刻音色。注册一个你自己的声音，之后任何项目都能直接用它配音，不用再逐视频克隆。")
                    .font(DesignTokens.Typography.microRegular)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(profiles) { p in
                    row(p)
                }
            }
            Button {
                onRegister()
            } label: {
                Label("注册新音色", systemImage: "plus.circle")
            }
            .controlSize(.small)
        }
    }

    private func row(_ p: VoiceProfile) -> some View {
        let invalidated = p.isInvalidated(currentKeyFingerprint: currentKeyFingerprint)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(DesignTokens.Typography.label)
                    Text(p.displaySubtitle)
                        .font(DesignTokens.Typography.microRegular)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    // M2：传音色身份（profile 自带 voiceChoice，含它绑定的型号）。
                    auditionPlayer.play(p.voiceChoice)
                } label: {
                    Image(systemName: auditionPlayer.isAuditioning ? "stop.circle" : "play.circle")
                }
                .controlSize(.small)
                .disabled(auditionPlayer.isAuditioning || invalidated)
                .help("试听")
                Menu {
                    Button("重命名…") {
                        renameTarget = p
                        renameText = p.name
                    }
                    Divider()
                    // 两种口径都明说「已生成配音仍保留」——删音色不该毁掉用户成片。
                    ForEach(CloneProfileDeletion.Scope.allCases, id: \.self) { scope in
                        Button(scope.label) { pendingDeletion = (p, scope) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if invalidated {
                // ⭐ Key 指纹不匹配：置灰 + 引导，不自动重注册（处置权交回用户）。
                Label(VoiceProfileValidity.invalidatedMessage(), systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .alert("重命名音色", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("音色名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let t = renameTarget { onRename(t, renameText) }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            pendingDeletion.map { "删除「\($0.0.name)」" } ?? "删除音色",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion) { pair in
                // 两个选项各带自己的详细说明（是否释放配额、音频是否保留）。
                ForEach(CloneProfileDeletion.Scope.allCases, id: \.self) { scope in
                    Button(scope.label) { onDelete(pair.0, scope); pendingDeletion = nil }
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { pair in
                // 恒 true（Core 铁律：删音色绝不能毁掉用户成片），仍显式写出来——
                // 让「删除是否保留音频」在这处UI 上是可见的，而不是靠注释保证。
                Text("\(pair.1.detail)\n\n"
                     + (CloneProfileDeletion.keepsExistingAudio(pair.1)
                        ? "已生成的配音会全部保留。" : ""))
            }
    }
}