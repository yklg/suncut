import Foundation
import Testing

/// 设置页两张 Key 卡片操作行统一性守卫。
///
/// 历史问题：两个操作行手写复制后漂移——按钮顺序相反（保存左 vs 清除左）、
/// 保存按钮白底 vs 蓝底、一卡缺测试连接。统一为 KeyManagementActionBar 后，
/// 用两条源码判据防回潮（中文按钮标题是字符串字面量，codeOnly 会剥掉，不能做锚点）：
/// 1. 全文件不许再出现 `.borderedProminent`（蓝底主按钮回潮）；
/// 2. `KeyManagementActionBar(` 必须被引用 ≥2 次（两张卡必须共用，退回手写即红）。
enum SettingsKeyActionBarScan {
    static let prominentToken = ".borderedProminent"
    static let componentToken = "KeyManagementActionBar("
    static let fileMarker = "struct SettingsView"

    struct Result: Equatable {
        let anchored: Bool
        let prominentCount: Int
        let componentUseCount: Int
    }

    static func inspect(_ src: String) -> Result {
        let a = TagRowHostScan.codeOnly(src)
        guard indexOfSeq(a, fileMarker) != nil else {
            return Result(anchored: false, prominentCount: 0, componentUseCount: 0)
        }
        return Result(anchored: true,
                     prominentCount: countOccurrences(a, prominentToken),
                     componentUseCount: countOccurrences(a, componentToken))
    }

    private static func countOccurrences(_ a: [Character], _ token: String) -> Int {
        let p = Array(token)
        guard !p.isEmpty, a.count >= p.count else { return 0 }
        var count = 0
        var i = 0
        while i <= a.count - p.count {
            if Array(a[i..<(i + p.count)]) == p {
                count += 1
                i += p.count
            } else {
                i += 1
            }
        }
        return count
    }

    private static func indexOfSeq(_ haystack: [Character], _ needle: String) -> Int? {
        let p = Array(needle)
        guard !p.isEmpty, haystack.count >= p.count else { return nil }
        for s in 0...(haystack.count - p.count) where haystack[s] == p[0] {
            if Array(haystack[s..<(s + p.count)]) == p { return s }
        }
        return nil
    }
}

private let settingsRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/MixCutCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // 包根

private func settingsRead(_ rel: String) -> String {
    (try? String(contentsOf: settingsRepoRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

@Suite("设置 Key 操作行统一性守卫")
struct SettingsKeyActionBarGuardTests {

    private let realPath = "MixCut/Views/Settings/SettingsView.swift"

    @Test("扫描根健全：真实设置页可读且含 struct SettingsView")
    func scanRootIsSane() {
        let src = settingsRead(realPath)
        #expect(src.count > 1000, "真实文件读不到 —— 判据没跑起来，不算通过")
        #expect(SettingsKeyActionBarScan.inspect(src).anchored,
                "没找到 struct SettingsView —— 宿主结构变了，需更新守卫")
    }

    @Test("两卡共用组件：KeyManagementActionBar 引用至少 2 处，且全文件无 borderedProminent")
    func cardsShareUnifiedBar() {
        let r = SettingsKeyActionBarScan.inspect(settingsRead(realPath))
        #expect(r.anchored)
        #expect(r.componentUseCount >= 2,
                "文本卡与千问卡都必须使用 KeyManagementActionBar（实得 \(r.componentUseCount) 处）；退回手写即分叉")
        #expect(r.prominentCount == 0,
                "Key 操作行不得再出现蓝底 borderedProminent（实得 \(r.prominentCount) 处）；样式统一走组件")
    }

    @Test("变异腿1：注入一行 borderedProminent，蓝底守卫必须变红")
    func prominentMutationTurnsItRed() {
        let src = settingsRead(realPath)
        let mutated = src.replacingOccurrences(
            of: ".buttonStyle(.bordered)\n                    .controlSize(.small)\n                    .disabled(!canSave)",
            with: ".buttonStyle(.borderedProminent)\n                    .controlSize(.small)\n                    .disabled(!canSave)")
        #expect(mutated != src, "变异没落地，对照作废")
        let r = SettingsKeyActionBarScan.inspect(mutated)
        #expect(r.prominentCount >= 1)
    }

    @Test("变异腿2：一张卡退回手写操作行，组件引用数守卫必须变红")
    func handwrittenForkMutationTurnsItRed() {
        let src = settingsRead(realPath)
        // 把千问卡的组件调用改为一个手写 HStack（模拟下一次复制分叉）
        let mutated = src.replacingOccurrences(
            of: "KeyManagementActionBar(\n                    saveTitle: \"保存千问 Key\"",
            with: "HStack { Text(\"已保存\"); Spacer(); Button(\"清除\") {}; Button(\"保存千问 Key\") {} }")
        #expect(mutated != src, "变异没落地，对照作废")
        let r = SettingsKeyActionBarScan.inspect(mutated)
        #expect(r.componentUseCount < 2, "退回手写后引用数必须跌破 2，实得 \(r.componentUseCount)")
    }
}
