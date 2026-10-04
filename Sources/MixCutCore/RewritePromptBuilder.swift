import Foundation

/// K 轮改写的风格轮次编排（纯逻辑、可测）。
///
/// 第 k 轮风格下标 = `(base + k) % poolCount`：一次管线内 K ≤ pool 时风格互不重复；
/// 超出池长显式回绕。起点由调用方随机化（随机源只允许留在调用点一行），
/// 使同一分镜重复改写不再恒定从池首开始。
public enum RewriteStylePlan {
    public static func roundIndices(base: Int, rounds: Int, poolCount: Int) -> [Int] {
        guard rounds > 0, poolCount > 0 else { return [] }
        // 规范化任意（含负数）base 到合法下标
        let normalizedBase = ((base % poolCount) + poolCount) % poolCount
        return (0..<rounds).map { (normalizedBase + $0) % poolCount }
    }
}

/// 把改写输入拼成可发送给 AI 的 prompt。模板里 {{STYLE}} / {{SEGMENTS}} / {{PRIOR_VERSIONS}}
/// 为占位符。
public enum RewritePromptBuilder {

    /// 历史轮次注入的确定性截断阈值。
    /// 整片改写（N 分镜 × K 轮）时 prior 逐轮累积会把输入撑到原文的数倍；
    /// 只保留最近若干轮、并给总字符设硬上限，从最旧轮**整轮**丢弃（不切半轮）。
    public static let priorMaxRounds = 3
    public static let priorMaxChars = 6000

    public static func build(template: String,
                             inputs: [RewriteSegmentInput],
                             style: String,
                             priorVersions: [[RewritePriorVersion]] = []) -> String {
        let segmentLines = inputs.map { input -> String in
            let origCount = input.originalText.count
            let budget = CharBudget.forOriginalLength(origCount)
            let kw = input.keywords.isEmpty ? "无" : input.keywords.joined(separator: "、")
            let dur = String(format: "%.2f", input.durationSeconds)
            return "- segmentId=\(input.segmentId) | 原字数=\(origCount)字（目标≈\(origCount)字，允许 \(budget.minChars)~\(budget.maxChars)字，与原台词字数相当即可，配音会自动加速对齐到画面）| 时长=\(dur)s | 必须保留关键事实=\(kw) | 原台词：\(input.originalText)"
        }.joined(separator: "\n")

        let priorBlock = renderPriorBlock(rounds: cappedPriors(priorVersions), inputs: inputs)

        return template
            .replacingOccurrences(of: "{{STYLE}}", with: style)
            .replacingOccurrences(of: "{{SEGMENTS}}", with: segmentLines)
            .replacingOccurrences(of: "{{PRIOR_VERSIONS}}", with: priorBlock)
    }

    /// 历史轮次截断：① 只保留最近 maxRounds 轮；② 再按总字符预算从最旧轮整轮丢弃。
    /// 顺序固定（先轮数后字符），结果对同一输入确定，便于测试与排查。
    public static func cappedPriors(_ rounds: [[RewritePriorVersion]],
                                    maxRounds: Int = priorMaxRounds,
                                    maxChars: Int = priorMaxChars) -> [[RewritePriorVersion]] {
        guard maxRounds > 0, maxChars >= 0 else { return [] }
        var kept = Array(rounds.suffix(maxRounds))
        var total = kept.reduce(0) { $0 + roundChars($1) }
        // 超字符预算：从最旧轮整轮丢弃，绝不保留半轮（语义完整优先）
        while total > maxChars, !kept.isEmpty {
            total -= roundChars(kept[0])
            kept.removeFirst()
        }
        return kept
    }

    /// 组装第 `currentIndex` 轮实际注入的历史轮次（已截断）。
    ///
    /// 顺序契约（决定截断时谁先被丢）：其他存量轮（按 index 升序）→ **即将被本轮覆盖的
    /// 存量轮**（currentIndex）→ 本次管线已产出的新轮次（最新在末尾）。
    /// 这样 cappedPriors 从尾部保留时，优先保住「同一次点击刚产出的新版本」与
    /// 「即将被覆盖、用户会直接对比的旧版本」——两者是差异化最相关的历史。
    ///
    /// 不修这个顺序的反例：库中 5 版、当前 K=2，首轮若简单 suffix(3)，丢掉的恰好是
    /// 即将被覆盖的旧第 0、1 版，重写结果可以与它们合法雷同。
    public static func assemblePriors(seedIndices: [Int],
                                      seedRounds: [Int: [RewritePriorVersion]],
                                      currentIndex: Int,
                                      freshRounds: [[RewritePriorVersion]]) -> [[RewritePriorVersion]] {
        var ordered: [[RewritePriorVersion]] = []
        for idx in seedIndices where idx != currentIndex {
            if let round = seedRounds[idx], !round.isEmpty { ordered.append(round) }
        }
        if let current = seedRounds[currentIndex], !current.isEmpty {
            ordered.append(current)
        }
        ordered.append(contentsOf: freshRounds)
        return cappedPriors(ordered)
    }

    private static func roundChars(_ round: [RewritePriorVersion]) -> Int {
        round.reduce(0) { $0 + $1.rewrittenText.count }
    }

    /// 渲染互斥段：轮内严格按 inputs 的 segmentId 顺序对齐；未知 id / 空文本忽略（脏数据防御）。
    /// 首轮（无历史）给出固定占位文案；旧模板没有该占位符时 replacingOccurrences 自然无操作。
    private static func renderPriorBlock(rounds: [[RewritePriorVersion]],
                                         inputs: [RewriteSegmentInput]) -> String {
        guard !rounds.isEmpty else {
            return "（本版是第一版，无历史版本需要避开）"
        }
        var lines: [String] = [
            "下列是此前已经产出的改写版本。你的新台词必须与【原台词】及下列【每一个历史版本】都明显不同：",
            "- 禁止复用任一版本的开头写法（前 4 个字的措辞组合）；",
            "- 禁止沿用同一套句式骨架；",
            "- 只替换一两个近义字词视为不合格，必须重新组织表达。",
            "语义与关键事实仍须完全一致。"
        ]
        for (idx, round) in rounds.enumerated() {
            var byId: [String: String] = [:]
            for v in round where byId[v.segmentId] == nil {
                let t = v.rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { byId[v.segmentId] = t }
            }
            lines.append("历史版本 \(idx + 1)：")
            for input in inputs {
                if let text = byId[input.segmentId] {
                    lines.append("- segmentId=\(input.segmentId)：\(text)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
