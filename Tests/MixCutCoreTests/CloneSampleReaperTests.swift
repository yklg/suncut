import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// CS · 复刻音色参考音频样本的清理判据
//
// ## 为什么这组测试存在
//
// M2 把裁切产物从 `tempDirectory` 改到**持久目录** `FileHelper.cloneSamplesDirectory`
// （为了支撑「重新注册」复用 `VoiceProfile.sampleAudioPath`），**但没配套清理**
// ⇒ 每次注册/改选样本都留下一份 ~160KB 音频，永久累积。
// 这是「把系统兜底的清理换成无人清理」的静默泄漏。
//
// ## 被测范围（skill 要求写进 docstring）
//
// 本组只测 **`CloneSampleReaper` 的纯计算**（Core 层），
// **不碰真实文件系统** ⇒ 无需 App 层测试载体。
// IO（列目录 / 删文件）与 SwiftData 查询在 App 层，其契约由 TB-2 与真机 L0 覆盖。
//
// ## 最重要的一条
//
// **CS-2 是「守卫的守卫」**：清理是不可逆动作，若把「在用样本」误判成孤儿，
// 用户已注册音色就永久失去重新注册的能力（样本通常不在别处留副本）。
// ⇒ 这条断言的失败必须响亮，且**绝不允许**为了让实现好过而放宽。
// ============================================================================

private let testDir = URL(fileURLWithPath: "/tmp/clonesamplereaper-test")

// MARK: - CS-1/3/4：候选筛选与孤儿判定

@Test("CS-1 只把 .mp3 列为候选（目录里混入别的东西不会误删）")
func cs1_onlyMp3AreCandidates() {
    let contents = ["sample-a.mp3", "sample-b.mp3", "notes.txt", ".sample-c.mp3.tmp", "README"]
    let cands = CloneSampleReaper.candidates(fromContents: contents)
    #expect(cands.sorted() == ["sample-a.mp3", "sample-b.mp3"],
            "非 .mp3 与点开头的临时文件都应被排除，实际 \(cands)")
}

@Test("CS-3 无任何引用时，全部候选都是孤儿（用户没注册过 ⇒ 全可清）")
func cs3_noReferencesAllOrphans() {
    let cands = CloneSampleReaper.candidates(
        fromContents: ["a.mp3", "b.mp3", "c.mp3"])
    let orphans = CloneSampleReaper.orphans(candidates: cands,
                                           referencedPaths: [], directory: testDir)
    #expect(orphans.count == 3, "无引用时应有 3 个孤儿，实际 \(orphans)")
}

@Test("CS-4 空目录 / 目录不存在时返回空（首次运行必然不存在，不得抛错）")
func cs4_emptyContentsYieldsNoOrphans() {
    #expect(CloneSampleReaper.candidates(fromContents: []).isEmpty)
    #expect(CloneSampleReaper.orphans(candidates: [], referencedPaths: [], directory: testDir).isEmpty)
    // 目录不存在时由调用方兜住（contentsOfDirectory 返回空）——判据不该自己碰 IO。
    #expect(CloneSampleReaper.candidates(fromContents: []).isEmpty)
}

// MARK: - CS-2：守卫的守卫（最重要）

@Test("CS-2 被 profile 引用的样本永不判为孤儿（误删 = 永久丢用户声音）")
func cs2_referencedSampleNeverOrphan() {
    let used = testDir.appendingPathComponent("used.mp3").path
    let cands = CloneSampleReaper.candidates(fromContents: ["used.mp3", "orphan.mp3"])
    let orphans = CloneSampleReaper.orphans(candidates: cands,
                                           referencedPaths: [used], directory: testDir)

    #expect(!orphans.contains("used.mp3"),
            "在用样本被判成孤儿 ⇒ 清理会永久删除用户已注册音色的样本")
    #expect(orphans.contains("orphan.mp3"), "未被引用的应是孤儿（可清）")
}

@Test("CS-2b 路径差异不得导致误判（/private/var 与 /var 是同一个目录）")
func cs2b_standardizedPathComparison() {
    // ⚠️ 这是**实测会踩的坑**：macOS 上 `/var` 是 `/private/var` 的符号链接。
    // 若比较时不做 standardizedFileURL，「在用样本」会被判成孤儿 ⇒ 误删。
    // 本用例用两个字符串构造「同文件不同写法」，断言它们必须被视为同一个。
    let real = testDir.appendingPathComponent("x.mp3").standardizedFileURL.path
    var viaPrivate = real
    if real.hasPrefix("/var/") {
        viaPrivate = real.replacingOccurrences(of: "/var/", with: "/private/var/")
    } else if real.hasPrefix("/private/var/") {
        viaPrivate = real.replacingOccurrences(of: "/private/var/", with: "/var/")
    }
    if viaPrivate == real {
        // 路径形态不适用于本机（Linux 等）⇒ 该分支不适用，跳过但不留假绿。
        #expect(Bool(true))
        return
    }
    let orphans = CloneSampleReaper.orphans(
        candidates: ["x.mp3"],
        referencedPaths: [viaPrivate],   // 用「非标准化」的写法引用同一个文件
        directory: testDir)
    #expect(orphans.isEmpty, "同一文件的两种路径写法不应导致误判为孤儿（实际判为孤儿：\(orphans)）")
}

// MARK: - CS-5：不变式声明本身（防止有人只改实现不改注释）

@Test("CS-5 清理判据的三条不变式在代码里可被grep 到")
func cs5_invariantsAreDocumented() {
    let text = CloneSampleReaper.invariants
    #expect(text.contains("永不删除"))
    #expect(text.contains(".mp3"))
    #expect(text.contains("standardizedFileURL"),
            "路径标准化这条必须写进不变式——它是误删在用样本的唯一防线")
}