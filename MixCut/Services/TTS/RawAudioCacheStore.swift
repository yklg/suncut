import Foundation

/// 原始 TTS 音频缓存的 App 层实现（actor，隔离磁盘 IO 与并发命中）。
///
/// 契约（与 Core `RawAudioCache` 的纯值判据严格分工）：
/// - **Core** 决定「键是什么 / 该淘汰谁 / 谁是孤儿」（纯函数，可单测）；
/// - **本 actor** 只做磁盘动作：存、取出、扫目录、删。
/// 命中判定一律交给 Core，本文件**不允许**出现任何哈希/淘汰规则的第二份实现
/// —— 那是本仓最忌讳的「两处各算」，一旦漂移就会出现「界面显示已缓存却永远命中不了」。
///
/// ## 为什么要「复制」而不是「直接用缓存文件」
///
/// `DubAudioFinalizer` 在**结尾会删掉传入的 wav**（它是 TTS wav 的终点）。
/// 若把缓存文件的真实路径直接交给 finalize，缓存当场被删 ⇒ 缓存永续为空。
/// 故命中时必须先复制一份到临时目录再交finalize。
actor RawAudioCacheStore {
    static let shared = RawAudioCacheStore()

    /// 缓存目录：AppSupport/Suncut/TTSCache/（与 Dubs/ 同级，语义不同故不同目录）。
    private let directory: URL
    /// 预算上限（默认 500MB，计划书口径）。0/负 = 不限制。
    private let budgetBytes: Int64
    /// 侧车元数据后缀（记录 rawDuration —— 它是 finalize 的输入，只靠文件探测每次
    /// 都得多跑一次 ffprobe；Dubs 那侧已经为省IO做过同类取舍）。
    private static let sidecarSuffix = ".json"

    init(directory: URL? = nil, budgetBytes: Int64 = 500 * 1024 * 1024) {
        self.directory = directory ?? FileHelper.appSupportDirectory
            .appendingPathComponent("TTSCache", isDirectory: true)
        self.budgetBytes = budgetBytes
        // 目录**不在 init 里建**：用户没合成过配音就不该凭空多一个空目录，
        // 且 FileHelper.ensureDirectory 是私有的、不能复用。各写盘点自行确保目录存在。
    }

    /// 写/读前确保目录存在（`createDirectory(withIntermediateDirectories:)` 幂等）。
    private func ensureCacheDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 键与路径

    /// 由合成身份构造键。**唯一**入口：调用方不许自己拼 stem。
    static func key(engine: RawAudioCacheKey.Engine,
                    model: String,
                    voiceID: String,
                    text: String,
                    rate: Double,
                    sampleRate: Int,
                    format: String) -> RawAudioCacheKey {
        RawAudioCacheKey(engine: engine, model: model, voiceID: voiceID,
                          text: text, rate: rate, sampleRate: sampleRate, format: format)
    }

    private func audioURL(_ key: RawAudioCacheKey) -> URL {
        directory.appendingPathComponent("\(key.fileStem).audio")
    }
    private func sidecarURL(_ key: RawAudioCacheKey) -> URL {
        directory.appendingPathComponent("\(key.fileStem)\(Self.sidecarSuffix)")
    }

    // MARK: - 存

    /// TTS 成功后存入。**必须在 finalize 之前调用**（finalize 会删源文件）。
    /// - Returns: 是否真的存入（失败不阻断合成：缓存是优化，不是功能）。
    @discardableResult
    func store(key: RawAudioCacheKey, audioURL source: URL, rawDuration: Double) -> Bool {
        ensureCacheDirectory()
        let dest = audioURL(key)
        let tmp = directory.appendingPathComponent(".\(key.fileStem).\(UUID().uuidString).tmp")
        do {
            // 原子替换：先写临时文件再 move，绝不先删 dest（dest 可能正被并发读者用）。
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: tmp)
            try FileManager.default.moveItem(at: tmp, to: dest)
            let sidecar: [String: Any] = ["rawDuration": rawDuration]
            let data = try JSONSerialization.data(withJSONObject: sidecar)
            try data.write(to: sidecarURL(key), options: .atomic)
            touch(key)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            MixLog.info("[TTSCache] 存入失败（不阻断合成）：\(error.localizedDescription)")
            return false
        }
    }

    /// 命中时把缓存音频**复制**到 `destination`（调用方给临时路径），返回 rawDuration。
    /// - Returns: nil = 未命中。命中时 destination 上一定有文件。
    func hit(key: RawAudioCacheKey, copyingTo destination: URL) -> Double? {
        let src = audioURL(key)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: src, to: destination)
            touch(key)
            let duration = (try? Data(contentsOf: sidecarURL(key)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["rawDuration"] as? Double }
            return duration ?? 0
        } catch {
            MixLog.info("[TTSCache] 命中但复制失败（回退真实合成）：\(error.localizedDescription)")
            return nil
        }
    }

    /// 更新访问时刻（LRU 用）。文件不存在时忽略。
    private func touch(_ key: RawAudioCacheKey) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: audioURL(key).path)
    }

    // MARK: - 扫盘 / 用量

    struct Usage: Sendable, Equatable {
        public let fileCount: Int
        public let bytes: Int64
        public let budgetBytes: Int64
        public var isOverBudget: Bool { budgetBytes > 0 && bytes > budgetBytes }
    }

    /// 扫目录清点（设置页显示用量）。**不**在此处做淘汰决策（那是 Core 的事）。
    func usage() -> Usage {
        let entries = scanEntries()
        return Usage(fileCount: entries.count,
                     bytes: entries.reduce(Int64(0)) { $0 + $1.byteSize },
                     budgetBytes: budgetBytes)
    }

    /// 目录条目（读侧一份；LRU 与对账共用，保证口径一致）。
    func entries() -> [RawAudioCacheEntry] { scanEntries() }

    private func scanEntries() -> [RawAudioCacheEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [RawAudioCacheEntry] = []
        for name in names where name.hasSuffix(".audio") {
            let url = directory.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date(timeIntervalSince1970: 0)
            out.append(RawAudioCacheEntry(fileStem: String(name.dropLast(".audio".count)),
                                          byteSize: Int64(size), lastAccess: mtime))
        }
        return out
    }

    // MARK: - 淘汰与清理

    /// LRU 淘汰到预算内。
    ///
    /// ## 为什么这里**不需要**「被SegmentDub.audioFilePath 引用者保护」
    ///
    /// M3 原计划写的是「跳过被任一 SegmentDub.audioFilePath 引用的文件」——
    /// 那条保护的前提是「缓存文件本身就是成品音频（m4a）」，删了会让配音变哑。
    /// 但本设计缓存的是**原始 TTS 音频**，与 `audioFilePath` 指向的成品 m4a 是
    /// 两个不同命名空间的文件：`hit()` 永远**复制**一份临时副本交给 finalize，
    /// finalize 转码成独立 m4a 后删掉那份临时副本。
    /// ⇒ 删缓存文件**永远不会**影响任何已生成配音的自包含性。
    ///
    /// 真正的约束是另一条：**不得删除正在被读取的文件**。actor 串行化已保证
    /// `hit` 的读与本方法的删不会交错到同一路径上（hit 全程await 在actor 内）。
    ///
    /// - Returns: 实际删除的条目数。
    @discardableResult
    func evictToBudget() -> Int {
        let entries = scanEntries()
        let victims = RawAudioCacheEvictor.victims(entries, budgetBytes: budgetBytes,
                                                   protectedStems: [])
        var removed = 0
        for v in victims where remove(v.fileStem) { removed += 1 }
        if removed > 0 { MixLog.info("[TTSCache] LRU 淘汰 \(removed) 项") }
        return removed
    }

    /// 孤儿回收：盘上有、账上没有（既不在索引也不在引用集合里）。
    /// 与既有 `OrphanFileFinder` 同形态—— 写入侧与 GC 共用同一真源，避免漂移误删。
    ///
    /// 判据说明：缓存目录**没有索引**（键全编码在文件名里，命中靠算键不查表），
    /// 所以「孤儿」= 侧车缺失的条目（`foo.audio` 在但 `foo.json` 不在）——
    /// 那才是真正的不一致（下次命中会拿不到 rawDuration，白跑一次 ffprobe）。
    /// 仅剩 `.audio` 而侧车被误删的条目，其音频本身仍可用，故**只报不删**，
    /// 由 store 重新写入时自然修复。真正的垃圾（既无 .audio 也无 .json）本就不在 entries 里。
    func inconsistentEntries() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [String] = []
        for name in names where name.hasSuffix(".audio") {
            let stem = String(name.dropLast(".audio".count))
            let sidecar = directory.appendingPathComponent("\(stem)\(Self.sidecarSuffix)")
            if !fm.fileExists(atPath: sidecar.path) { out.append(stem) }
        }
        return out.sorted()
    }

    /// 设置页「清空缓存」。缓存与成品音频解耦（见 evictToBudget 的说明），
    /// 故可全清—— 已生成配音是自包含的 m4a，不受影响。
    @discardableResult
    func clearAll() -> Int {
        let entries = scanEntries()
        var removed = 0
        for e in entries where remove(e.fileStem) { removed += 1 }
        if removed > 0 { MixLog.info("[TTSCache] 手动清空 \(removed) 项") }
        return removed
    }

    /// 删一项（音频 + 侧车）。成功返回 true。
    @discardableResult
    func remove(_ stem: String) -> Bool {
        var ok = false
        for name in ["\(stem).audio", "\(stem)\(Self.sidecarSuffix)"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url); ok = true }
                catch { MixLog.error("[TTSCache] 删除失败 \(name): \(error.localizedDescription)") }
            }
        }
        return ok
    }
}