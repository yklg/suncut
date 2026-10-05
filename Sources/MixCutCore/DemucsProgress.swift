import Foundation

/// demucs.cpp CLI 的进度输出解析。
///
/// 上游 sevagh/demucs.cpp 的 cli-apps/demucs.cpp 经 ProgressCallback 向 stdout 逐行打印：
/// ```
/// (  0%) model_load
/// ( 42%) separator_chunk
/// (100%) write_wav
/// ```
/// 解析规则只认「左括号 + 1–3 位数字 + 百分号」，取一行中最后一个匹配；
/// 1000% 这类 4 位数不匹配（百分号前必须恰好是 1–3 位数字）。
public enum DemucsProgressParser {
    /// 全量扫描一行中的全部 `(NNN%)`，返回最后一个的 0...1；无合法匹配返回 nil。
    public static func fraction(in line: String) -> Double? {
        let pattern = #"\(\s*(\d{1,3})\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard let last = matches.last, last.numberOfRanges >= 2,
              let r = Range(last.range(at: 1), in: line),
              let value = Int(line[r]) else { return nil }
        return min(max(Double(value) / 100.0, 0.0), 1.0)
    }
}

/// 行式字节流累加器：吃 readabilityHandler 的任意 Data 分块，按行吐出百分比。
///
/// 必须按 **Data** 缓冲而不能先按 String 拼接：chunk 可能从 UTF-8 多字节序列中间切开，
/// String(data: .utf8) 会在切口插入替换字符并永久丢失该字节。
///
/// 线程安全：FileHandle.readabilityHandler 在后台队列回调，feed 可能并发；
/// 内部用 NSLock 串行化缓冲与「最后百分比」状态。回调在锁外执行，避免外部代码重入死锁。
public final class DemucsLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lastPercent: Int?
    private let onPercent: @Sendable (Double) -> Void

    public init(onPercent: @escaping @Sendable (Double) -> Void) {
        self.onPercent = onPercent
    }

    /// 喂入一个任意大小的字节块。
    public func feed(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var completedLines: [Data] = []
        lock.lock()
        buffer.append(chunk)
        // 按 \n 切行；最后一段（无尾换行）留在 buffer 等下一块。
        while let nlIndex = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<nlIndex)
            buffer.removeSubrange(buffer.startIndex...nlIndex)
            // 兼容 CRLF：去掉行尾 \r。
            if line.last == 0x0D { line.removeLast() }
            completedLines.append(line)
        }
        let drained = drainPercentChanges(from: completedLines)
        lock.unlock()
        for value in drained { onPercent(value) }
    }

    /// 进程结束时调用：尝试解析残留在 buffer 里的最后一行（无尾换行也认）。
    public func finish() {
        var trailing: Data?
        lock.lock()
        if !buffer.isEmpty {
            trailing = buffer
            buffer.removeAll()
        }
        let drained = trailing.flatMap { drainPercentChanges(from: [$0]) } ?? []
        lock.unlock()
        for value in drained { onPercent(value) }
    }

    /// 在持锁状态下从行数据解析「发生了变化」的整数百分比。
    /// 同一行重复同一值不重复回调（tqdm minInterval 同款节流：整流程最多 ~100 次）。
    private func drainPercentChanges(from lines: [Data]) -> [Double] {
        var out: [Double] = []
        for lineData in lines {
            guard let line = String(data: lineData, encoding: .utf8),
                  let fraction = DemucsProgressParser.fraction(in: line) else { continue }
            let percent = Int((fraction * 100).rounded())
            guard percent != lastPercent else { continue }
            lastPercent = percent
            out.append(fraction)
        }
        return out
    }
}
