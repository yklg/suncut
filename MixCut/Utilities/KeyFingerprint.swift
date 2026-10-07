import Foundation
import CryptoKit

/// API Key 指纹（**单一真源**）。
///
/// ## 用途
///
/// DashScope 的克隆音色（逐视频克隆 + 账号级复刻）都注册在**某个账户**下，
/// 换 Key 后旧 voiceId 在新账户不存在，合成时服务端报 InvalidParameter。
/// 指纹让「这个音色是用哪把 Key 注册的」可判，且**不泄漏 Key 本身**
/// （只取 SHA256 前 2 字节 = 4 个十六进制字符，足以区分不同Key，
/// 又短到能当 UserDefaults 键的一部分、能放进设置页副标题）。
///
/// ## 为什么不放Core
///
/// 需要 `CryptoKit` 的 SHA256。Core 是纯 SwiftPM 库、可在无 Foundation-crypto 的
/// 环境构建；而 `KeychainHelper` 也在 App 层，放Core 会引入 App 依赖。
/// 代价是「Core 侧判据（VoiceProfileValidity）只吃指纹字符串」—— 这正是它该有的形状：
/// 判据纯值、不关心指纹怎么算。
///
/// ## 两份实现是漂移温床
///
/// `DubbingViewModel.currentKeyFingerprint` 与 `VoiceCloneViewModel` 曾各写一份。
/// 一旦某一边改了算法（例如从 2 字节加到 4 字节），存量音色会被**全部**误判为失效、
/// 集体置灰。故抽到此处，两边都调它。
enum KeyFingerprint {
    /// 取 Key 的指纹。空 Key ⇒ 空串（调用方按「未配置」处理，不是「指纹不匹配」）。
    static func of(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(2).map { String(format: "%02x", $0) }.joined()
    }
}