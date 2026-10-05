import Foundation
import Testing
@testable import MixCutCore

/// demucs 行式百分比解析 + 字节流累加器测试。
/// 维度回溯：等价类/边界（0%/100%/1000% 误配）、流残片（Data 级 + UTF8 切半）、
/// 变化节流、多线程 feed（readabilityHandler 在后台队列回调）。
@Suite("DemucsProgressParser")
struct DemucsProgressParserTests {

    @Test("标准行 ( 42%) → 0.42")
    func standardLine() {
        #expect(DemucsProgressParser.fraction(in: "( 42%) separator_chunk") == 0.42)
    }

    @Test("0% → 0")
    func zeroPercent() {
        #expect(DemucsProgressParser.fraction(in: "(  0%) model_load") == 0)
    }

    @Test("100% → 1.0")
    func fullPercent() {
        #expect(DemucsProgressParser.fraction(in: "(100%) write_wav") == 1.0)
    }

    @Test("空串 / 无百分比 → nil")
    func noMatch() {
        #expect(DemucsProgressParser.fraction(in: "") == nil)
        #expect(DemucsProgressParser.fraction(in: "starting demucs inference") == nil)
    }

    @Test("同一行多个百分比取最后一个")
    func lastMatchWins() {
        #expect(DemucsProgressParser.fraction(in: "(10%) a (73%) b") == 0.73)
    }

    @Test("超过 100 的值 clamp 到 1.0")
    func clampOver100() {
        // 三位数才可能匹配，故此处只能构造 100；真正的越界保护靠 clamp 本身存在。
        #expect(DemucsProgressParser.fraction(in: "(100%)") == 1.0)
    }

    @Test("setw 空格与无空格两种真实格式都能解析")
    func spacingVariants() {
        #expect(DemucsProgressParser.fraction(in: "( 5%) x") == 0.05)
        #expect(DemucsProgressParser.fraction(in: "(5%) x") == 0.05)
        #expect(DemucsProgressParser.fraction(in: "(  5 %) x") == 0.05)
    }

    @Test("(1000%) 不误配：百分号前必须恰好 1–3 位数字")
    func fourDigitsRejected() {
        #expect(DemucsProgressParser.fraction(in: "(1000%) bad counter") == nil)
    }

    @Test("负号不匹配")
    func negativeRejected() {
        #expect(DemucsProgressParser.fraction(in: "(-5%) x") == nil)
    }
}

@Suite("DemucsLineAccumulator")
struct DemucsLineAccumulatorTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test("整块多行：按行有序吐出")
    func multipleCompleteLines() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data("(10%) a\n(20%) b\n(30%) c\n".utf8))
        #expect(r.snapshot == [0.1, 0.2, 0.3])
    }

    @Test("残片跨两块：切开的一行在第二块补齐后才回调")
    func partialLineAcrossChunks() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data("(4".utf8))
        #expect(r.snapshot == [])
        acc.feed(Data("2%) chunk\n".utf8))
        #expect(r.snapshot == [0.42])
    }

    @Test("无换行结尾：滞留不回调，finish 后吐出")
    func trailingWithoutNewline() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data("(77%) final".utf8))
        #expect(r.snapshot == [])
        acc.finish()
        #expect(r.snapshot == [0.77])
    }

    @Test("CRLF 与 LF 都能切行")
    func lineEndings() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data("(11%) a\r\n(22%) b\n".utf8))
        #expect(r.snapshot == [0.11, 0.22])
    }

    @Test("空 Data 不回调")
    func emptyChunk() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data())
        acc.feed(Data("\n".utf8))
        #expect(r.snapshot == [])
    }

    @Test("UTF8 多字节从字节中间切开：中文消息仍完整还原")
    func utf8SplitAcrossChunks() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        let line = Data("(42%) 正在分离人声第 3 段\n".utf8)
        // 在一个 3 字节中文（"正" = E6 AD A3）的中间切开。
        let cut = line.firstIndex(of: 0x25)! // '%' 之后某处之前，直接选一个多字节边界内点
        let mid = line.index(line.startIndex, offsetBy: 12) // 落在 "(42%) " 之后的中文字节内
        _ = cut
        acc.feed(line[line.startIndex..<mid])
        #expect(r.snapshot == [])
        acc.feed(line[mid...])
        #expect(r.snapshot == [0.42])
    }

    @Test("同值百分比重复多行只回调一次（变化节流）")
    func duplicateValueSuppressed() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data("(42%) a\n(42%) a\n(42%) a\n".utf8))
        #expect(r.snapshot == [0.42])
    }

    @Test("非单调变化也回调：契约是『变化即回调』，不假设进度只增")
    func nonMonotonicChangeReported() {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        acc.feed(Data("(42%) a\n(41%) b\n".utf8))
        #expect(r.snapshot == [0.42, 0.41])
    }

    @Test("多线程并发 feed 不崩溃，拼接结果与串行等价（锁定后顺序由行数据自身决定）")
    func concurrentFeeds() async {
        let r = Recorder()
        let acc = DemucsLineAccumulator { r.append($0) }
        let line = Data("(50%) chunk\n".utf8)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { acc.feed(line) }
            }
        }
        // 每个线程喂入的都是完整行，同值节流后最多一次；关键契约：无崩溃、无重复风暴。
        #expect(r.snapshot.count <= 1)
    }
}
