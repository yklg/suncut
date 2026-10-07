import Foundation
import Testing

@testable import MixCutCore

// ============================================================================
// RawAudioCache（M3 原始 TTS 音频缓存）—— 键构成 / LRU 淘汰 / 对账
//
// 覆盖的核心主张（M3 验收口径「同文案不同时长两分镜各自时长正确且只计一次 TTS 费」）：
//   RA-1…RA-8  键：rate 分桶是命中率的关键（连续 rate 必须落同一档）
//   RA-9…RA-13 文案归一化：排版差异算同一份文案（用户换来源粘贴不该重复付费）
//   RA-14…RA-20LRU：被引用者永不淘汰（删了会让用户配音变哑）；预算非正=不限制
//   RA-21…RA-23对账：孤儿=盘上有、账上没有（写入侧与 GC 共用同一真源）
// ============================================================================

// MARK: - 键：rate 分桶

@Test("RA-1 同文案同音色同 rate → 同键")
func ra1_sameInputsSameKey() {
    func key(rate: Double) -> RawAudioCacheKey {
        RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v2", voiceID: "longyingxiao",
                         text: "这个厨房油污太难搞了", rate: rate, sampleRate: 24000, format: "mp3")
    }
    #expect(key(rate: 1.0) == key(rate: 1.0))
}

@Test("RA-2 小幅抖动（±0.01，retargetRate 的实际抖动幅度）落同一档")
func ra2_smallJitterSameBucket() {
    // retargetRate 只在 drift > acceptTolerance 时返回不同 rate，实际抖动通常 < 0.05。
    // 选桶心附近的 1.00：±0.01 都远离边界，必然同档。
    let b1 = RawAudioCacheKey.bucket(for: 1.00)
    let b2 = RawAudioCacheKey.bucket(for: 1.01)
    #expect(b1 == b2, "桶心附近小幅抖动必须同档，否则命中率崩")
}

@Test("RA-3 档边界附近分属两档（分桶的固有性质，刻意接受）")
func ra3_bucketBoundarySplits() {
    // 1.024/0.05 = 20.48 → 20；1.026/0.05 = 20.52 → 21，恰好跨边界。
    // 契约钉死「边界会分档」：宁可偶尔不命中（多合成一次）也不放大步长牺牲音质。
    let b1 = RawAudioCacheKey.bucket(for: 1.024)
    let b2 = RawAudioCacheKey.bucket(for: 1.026)
    #expect(b1 != b2)
    // 距边界半个步长以内的两个 rate 必同档（桶心区域是绝大多数真实 rate 所在处）。
    #expect(RawAudioCacheKey.bucket(for: 1.00) == RawAudioCacheKey.bucket(for: 1.02))
}

@Test("RA-4 rate clamp 到 [0.5, 2.0]（越界不会产生非法桶）")
func ra4_rateClamped() {
    #expect(RawAudioCacheKey.bucket(for: 0.01) == RawAudioCacheKey.bucket(for: 0.5))
    #expect(RawAudioCacheKey.bucket(for: 9.0) == RawAudioCacheKey.bucket(for: 2.0))
}

@Test("RA-5 bucket↔rate 往返一致（命中后能复述出可执行的 rate）")
func ra5_bucketRoundTrip() {
    for rate in [0.5, 0.9, 1.0, 1.35, 2.0] {
        let bucket = RawAudioCacheKey.bucket(for: rate)
        let back = RawAudioCacheKey.rate(forBucket: bucket)
        #expect(abs(back - rate) <= RawAudioCacheKey.rateBucketStep / 2 + 1e-9,
                "rate \(rate) 往返得到 \(back)")
    }
}

@Test("RA-6 差一个维度即不同键（engine/model/voice/sampleRate/format 全都是键的一部分）")
func ra6_anyDimensionChangesKey() {
    let base = RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v2", voiceID: "v1",
                                text: "台词", rate: 1.0, sampleRate: 24000, format: "mp3")
    #expect(base != RawAudioCacheKey(engine: .qwenVC, model: "cosyvoice-v2", voiceID: "v1",
                                     text: "台词", rate: 1.0, sampleRate: 24000, format: "mp3"))
    #expect(base != RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v3-plus", voiceID: "v1",
                                     text: "台词", rate: 1.0, sampleRate: 24000, format: "mp3"))
    #expect(base != RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v2", voiceID: "v2",
                                     text: "台词", rate: 1.0, sampleRate: 24000, format: "mp3"))
    #expect(base != RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v2", voiceID: "v1",
                                     text: "台词", rate: 1.0, sampleRate: 16000, format: "mp3"))
    #expect(base != RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v2", voiceID: "v1",
                                     text: "台词", rate: 1.0, sampleRate: 24000, format: "wav"))
}

@Test("RA-7 文案不同 → 不同键")
func ra7_differentTextDifferentKey() {
    let a = RawAudioCacheKey(engine: .cosyVoice, model: "m", voiceID: "v",
                              text: "台词甲", rate: 1.0, sampleRate: 24000, format: "mp3")
    let b = RawAudioCacheKey(engine: .cosyVoice, model: "m", voiceID: "v",
                              text: "台词乙", rate: 1.0, sampleRate: 24000, format: "mp3")
    #expect(a != b)
}

@Test("RA-8 fileStem 稳定且只含摘要（长文案/长voiceID 不撑爆文件名）")
func ra8_fileStemStableAndBounded() {
    let longText = String(repeating: "很长的带货文案", count: 500)
    let key = RawAudioCacheKey(engine: .cosyVoice, model: "cosyvoice-v2",
                               voiceID: String(repeating: "x", count: 300),
                               text: longText, rate: 1.0, sampleRate: 24000, format: "mp3")
    let stem = key.fileStem
    #expect(stem == key.fileStem, "同名文件必须稳定，否则缓存永远写不到同一处")
    #expect(!stem.isEmpty)
    #expect(stem.count <= 32, "fileStem \(stem.count) 字符，超出预期（应为短摘要）")
    #expect(!stem.contains("/") && !stem.contains("|"), "文件名不允许出现路径分隔符")
}

// MARK: - 键：文案归一化

@Test("RA-9 首尾空白不改变哈希")
func ra9_trimInsensitive() {
    #expect(RawAudioCacheKey.normalizedTextHash("  你真能忍冰箱发霉？  ")
            == RawAudioCacheKey.normalizedTextHash("你真能忍冰箱发霉？"))
}

@Test("RA-10 内部换行/缩进折叠成单空格（换来源粘贴同一段文案不该重复付费）")
func ra10_internalWhitespaceFolds() {
    let a = "你真能忍\n冰箱发霉？"
    let b = "你真能忍   冰箱发霉？"
    let c = "你真能忍\t冰箱发霉？"
    #expect(RawAudioCacheKey.normalizedTextHash(a) == RawAudioCacheKey.normalizedTextHash(b))
    #expect(RawAudioCacheKey.normalizedTextHash(a) == RawAudioCacheKey.normalizedTextHash(c))
}

@Test("RA-11 全角空格视同半角（中文文案常见排版差异）")
func ra11_fullWidthSpaceFolds() {
    #expect(RawAudioCacheKey.normalizedTextHash("你真能忍\u{3000}冰箱发霉？")
            == RawAudioCacheKey.normalizedTextHash("你真能忍 冰箱发霉？"))
}

@Test("RA-12 空文案有稳定标记（不与任何真实文案撞键）")
func ra12_emptyTextStable() {
    #expect(RawAudioCacheKey.normalizedTextHash("") == "empty")
    #expect(RawAudioCacheKey.normalizedTextHash("   \n  ") == "empty")
    #expect(RawAudioCacheKey.normalizedTextHash("台词") != "empty")
}

@Test("RA-13 归一化保留首尾不产生多余空格（normalize 的边界）")
func ra13_normalizeEdges() {
    #expect(RawAudioCacheKey.normalize("  a  b  ") == "a b")
    #expect(RawAudioCacheKey.normalize("") == "")
    #expect(RawAudioCacheKey.normalize("\n\n") == "")
    #expect(RawAudioCacheKey.normalize("单字") == "单字")
}

// MARK: - LRU 淘汰

private func entry(_ stem: String, _ bytes: Int64, _ t: TimeInterval) -> RawAudioCacheEntry {
    RawAudioCacheEntry(fileStem: stem, byteSize: bytes,
                       lastAccess: Date(timeIntervalSince1970: t))
}

@Test("RA-14 未超预算 → 不淘汰任何条目")
func ra14_underBudgetNoVictims() {
    let entries = [entry("a", 100, 1), entry("b", 100, 2)]
    #expect(RawAudioCacheEvictor.victims(entries, budgetBytes: 500, protectedStems: []).isEmpty)
}

@Test("RA-15 超预算 → 按最久未访问顺序淘汰（LIFO 反向）")
func ra15_lruOrder() {
    // 总量 300，预算 150：应淘汰最旧的 a（100），剩 200 仍超 → 再淘汰 b。
    let entries = [entry("a", 100, 1), entry("b", 100, 2), entry("c", 100, 3)]
    let victims = RawAudioCacheEvictor.victims(entries, budgetBytes: 150, protectedStems: [])
    #expect(victims.map(\.fileStem) == ["a", "b"], "实际 \(victims.map(\.fileStem))")
}

@Test("RA-16 保护项本身永不被淘汰（函数级契约：保护集内的条目即便最旧也保留）")
func ra16_protectedNeverVictim() {
    // 本设计下 App 层恒传空保护集（缓存与成品 m4a 解耦，见 RA-21）；
    // 但纯函数必须仍支持保护语义：一旦将来缓存与引用产生耦合，这条是防线。
    let entries = [entry("protected", 1000, 1), entry("old", 100, 2)]
    let victims = RawAudioCacheEvictor.victims(entries, budgetBytes: 1, protectedStems: ["protected"])
    #expect(victims.map(\.fileStem) == ["old"],
            "只该淘汰未保护的 old；实际 \(victims.map(\.fileStem))")
}

@Test("RA-17 预算为 0 或负 → 视为不限制（防误配把缓存清空）")
func ra17_zeroBudgetMeansUnlimited() {
    let entries = [entry("a", 100, 1)]
    #expect(RawAudioCacheEvictor.victims(entries, budgetBytes: 0, protectedStems: []).isEmpty)
    #expect(RawAudioCacheEvictor.victims(entries, budgetBytes: -1, protectedStems: []).isEmpty)
}

@Test("RA-18 同时间戳用文件名定序（淘汰顺序必须确定性）")
func ra18_tieBreakDeterministic() {
    let a = [entry("z", 100, 5), entry("a", 100, 5), entry("m", 100, 5)]
    let victims = RawAudioCacheEvictor.victims(a, budgetBytes: 150, protectedStems: [])
    #expect(victims.map(\.fileStem) == ["a", "m"], "实际 \(victims.map(\.fileStem))")
}

@Test("RA-19 重复调用同一输入 → 同一结果（纯函数，不是真删档）")
func ra19_pureFunction() {
    let entries = [entry("a", 100, 1), entry("b", 100, 2), entry("c", 100, 3)]
    let r1 = RawAudioCacheEvictor.victims(entries, budgetBytes: 150, protectedStems: [])
    let r2 = RawAudioCacheEvictor.victims(Array(entries.reversed()), budgetBytes: 150, protectedStems: [])
    #expect(Set(r1.map(\.fileStem)) == Set(r2.map(\.fileStem)))
}

@Test("RA-20 淘汰后字节数对账一致（设置页显示用，不重复扫盘）")
func ra20_bytesAfterEviction() {
    let entries = [entry("a", 100, 1), entry("b", 100, 2), entry("c", 100, 3)]
    let victims = RawAudioCacheEvictor.victims(entries, budgetBytes: 150, protectedStems: [])
    let after = RawAudioCacheEvictor.bytesAfterEviction(entries, victims: victims)
    #expect(after == 300 - victims.reduce(Int64(0)) { $0 + $1.byteSize })
}

// MARK: - 保护集合恒等（缓存与成品音频解耦的语义钉死）

@Test("RA-21 保护集合在当前设计下恒为空—— 缓存与成品 m4a 解耦，删缓存不影响已生成配音")
func ra21_protectionIsAlwaysEmpty() {
    // 架构决定：缓存存原始 TTS 音频（独立命名空间），finalize 产出的是另一个
    // 自包含的 m4a。故「被 SegmentDub.audioFilePath 引用」这一保护条件**不适用**，
    // 调用方恒传空集。把它钉成单测：一旦有人想引入真保护，此测试会提醒口径已变。
    let entries = [entry("a", 100, 1), entry("b", 100, 2)]
    let withEmpty = RawAudioCacheEvictor.victims(entries, budgetBytes: 1, protectedStems: [])
    #expect(withEmpty.count == 2, "空保护集 = 可全淘汰（符合「缓存可自由清理」语义）")
}

@Test("RA-22 LRU 保护集合仍可用（函数保持通用，App 层按需传保护项）")
func ra22_protectionStillSupported() {
    let entries = [entry("keep", 100, 1), entry("drop", 100, 2)]
    let victims = RawAudioCacheEvictor.victims(entries, budgetBytes: 1, protectedStems: ["keep"])
    #expect(victims.map(\.fileStem) == ["drop"], "保护项永不淘汰（函数级契约仍然成立）")
}

@Test("RA-23 淘汰后字节数对账一致（设置页显示用，不重复扫盘）")
func ra23_bytesAfterEviction() {
    let entries = [entry("a", 100, 1), entry("b", 100, 2), entry("c", 100, 3)]
    let victims = RawAudioCacheEvictor.victims(entries, budgetBytes: 150, protectedStems: [])
    let after = RawAudioCacheEvictor.bytesAfterEviction(entries, victims: victims)
    #expect(after == 300 - victims.reduce(Int64(0)) { $0 + $1.byteSize })
}