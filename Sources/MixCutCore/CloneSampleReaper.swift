import Foundation

/// 复刻音色**参考音频样本**的清理判据（M2）。
///
/// ## 为什么需要它（一个由修复引入的缺陷）
///
/// 裁切产物原先落在 `tempDirectory`（由系统定期清理，安全）。M2 为了让
/// `VoiceProfile.sampleAudioPath` 能复用样本（「重新注册」要用），把它改到了
/// **持久目录** `FileHelper.cloneSamplesDirectory` —— 但**没配套清理**。
/// ⇒ 用户每注册一次、或每改选一次样本，就留下一份 ~160KB 音频，**永久累积**。
/// 这是「把系统兜底的清理换成无人清理」的静默泄漏。
///
/// ## 判据（纯函数，可单测）
///
/// 「目录下的文件，要么被某个 `VoiceProfile.sampleAudioPath` 引用，要么是孤儿」。
///
/// - **被引用的样本永不可删**：删了用户已注册音色就失去重新注册的能力，
///   且样本通常不在别处留有副本 ⇒ 不可逆。
/// - **孤儿**（用户改选样本后上一份的残留）可删。
///
/// ## 为什么判据在 Core 而不在 App
///
/// 判据本身是「两个字符串集合求差」的纯计算，不该依赖 SwiftData。
/// 调用方（App 层）负责「去查库拿到 `sampleAudioPath` 集合」——
/// 与本仓「撞名判据在 App、名字判据在 Core」是同一条分层纪律。
public enum CloneSampleReaper {
    /// 样本文件的扩展名（与 `CloneRegistrationService` 裁切时的输出一致）。
    /// 只清理该扩展名的文件 ⇒ 目录里若混入别的东西不会误删。
    public static let sampleExtension = "mp3"

    /// 列出样本目录里的候选文件路径（**纯函数**：不做 IO，由调用方传入目录内容）。
    ///
    /// - Parameter contents: 目录内文件名列表（`FileManager.contentsOfDirectory` 的结果）。
    /// - Returns: 候选样本文件路径（文件名，非完整路径）。
    ///   非 `.mp3`、以 `.` 开头的临时文件（如写入中途的 `tmp`）一律排除。
    public static func candidates(fromContents contents: [String]) -> [String] {
        contents.filter { name in
            name.hasSuffix("." + sampleExtension) && !name.hasPrefix(".")
        }
    }

    /// 找出**孤儿**样本（未被任何 profile 引用 ⇒ 可安全删除）。
    ///
    /// - Parameters:
    ///   - candidates: 目录内候选文件名（来自 `candidates(fromContents:)`）。
    ///   - referencedPaths: 被 `VoiceProfile.sampleAudioPath` 引用的**完整路径**集合。
    /// - Returns: 孤儿文件名（可删）。被判为孤儿的文件**没有被任何 profile 使用**。
    ///
    /// ⚠️ 比较用**标准化后的完整路径**（`standardizedFileURL`）：
    /// profile 里存的是绝对路径，而目录枚举出的是文件名；两者拼出的字符串
    /// 若不经标准化，可能因 `/private/var` vs `/var`、尾斜杠等差异**判错**
    /// ⇒ 把「在用样本」误判成孤儿删掉（不可逆）。
    public static func orphans(candidates: [String],
                                referencedPaths: Set<String>,
                                directory: URL) -> [String] {
        let normalizedRefs = referencedPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        return candidates.filter { name in
            let full = directory.appendingPathComponent(name).standardizedFileURL.path
            return !normalizedRefs.contains(full)
        }
    }

    /// 一条常读性质的说明（供守卫脚本 grep 引用，防止有人只删不更新注释）。
    public static let invariants = """
        1. 被 VoiceProfile.sampleAudioPath 引用的样本永不删除（不可逆，样本通常无副本）。
        2. 只清理 .mp3，且跳过以 . 开头的临时文件（写入中途产物）。
        3. 路径比较必须 standardizedFileURL（否则 /private/var 与 /var 差异会误删在用样本）。
        """
}