import Foundation

/// 文件管理工具
enum FileHelper {

    /// 确保目录存在，失败时记录日志
    private static func ensureDirectory(at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            MixLog.error("无法创建目录 \(url.path): \(error.localizedDescription)")
        }
    }

    /// `Application Support` 本身（品牌数据目录的父级）。取不到时退回临时目录，与历史行为一致。
    static var appSupportBaseDirectory: URL {
        #if DEBUG
        // 改名迁移的演练入口：把数据根指到 .scratch 下的假根，让真搬迁/真改写能在克隆数据上跑，
        // 而不碰用户真目录。假 HOME 这条路实测走不通（Foundation 用户域不认 $HOME），所以只能显式给。
        // Release 编译不进这一支。
        if let root = ProcessInfo.processInfo.environment["MIXCUT_DEBUG_APP_SUPPORT_ROOT"],
           !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// 应用沙盒中的项目数据目录
    static var appSupportDirectory: URL {
        let url = appSupportDirectoryForReading
        ensureDirectory(at: url)
        return url
    }

    /// 换品牌前数据所在的目录。**只读**，不在这里建目录 —— 目录不存在就等于没东西可搬。
    static var legacyAppSupportDirectory: URL {
        appSupportBaseDirectory.appendingPathComponent(Brand.legacyDataDirectoryName, isDirectory: true)
    }

    // MARK: - SwiftData 数据库

    /// MixCut 专属数据库文件路径。
    ///
    /// ⚠️ 必须用专属库名，**绝不能**用 SwiftData 默认库：非沙盒 App 的默认库固定落在
    /// `~/Library/Application Support/default.store`，会与本机其它非沙盒 SwiftData App
    /// 共用同一文件，schema 不符时双方互相清库，导致项目数据丢失。
    static var mixCutStoreURL: URL {
        appSupportDirectory.appendingPathComponent(Brand.storeFileName)
    }

    /// 旧版共享数据库（SwiftData 默认库）路径
    static var legacyDefaultStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("default.store")
    }

    // MARK: - 全局视频存储（按 hash 去重）

    /// 全局视频存储目录（**写入侧**用这颗：它读一次就把目录建出来）
    static var globalVideoDirectory: URL {
        let url = globalVideoDirectoryForReading
        ensureDirectory(at: url)
        return url
    }

    /// 全局缩略图存储目录
    static var globalThumbnailDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - 分镜头/替换画面产物根目录（写入侧与孤儿 GC 共用同一真源）

    /// 目录名只允许写在这里一次：GC 若另抄一份，漂移就会把在用文件当孤儿删。
    static var shotVariantsDirectory: URL {
        appSupportDirectory.appendingPathComponent("ShotVariants", isDirectory: true)
    }

    static var shotThumbnailsDirectory: URL {
        appSupportDirectory.appendingPathComponent("ShotThumbnails", isDirectory: true)
    }

    static var replacedPicturesDirectory: URL {
        appSupportDirectory.appendingPathComponent("ReplacedPictures", isDirectory: true)
    }

    /// 复刻音色的**参考音频样本**目录（M2）。
    ///
    /// 为什么**不用** tempDirectory：裁切后的样本要活到「注册成功」那一刻之后
    /// （`VoiceProfile.sampleAudioPath` 存它、用户点「重新注册」时还要复用），
    /// 放 temp 会被系统在任意时刻清掉 ⇒ 复刻音色会突然变成「样本丢失、无法重注册」。
    /// 放在 appSupport 下与 `Dubs` / `Thumbnails` 同级，语义一致。
    static var cloneSamplesDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("CloneSamples", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - 配音音频存储（按视频 hash / 方案变体 / 分镜 ID 三级目录）

    /// 配音音频全局目录：AppSupport/MixCut/Dubs/{videoHash}/{segmentId}/{voiceId}-v{textVariantIndex}.m4a
    static func dubAudioURL(videoHash: String, segmentId: UUID, voiceId: String, textVariantIndex: Int) -> URL {
        let dir = appSupportDirectory
            .appendingPathComponent("Dubs", isDirectory: true)
            .appendingPathComponent(videoHash, isDirectory: true)
            .appendingPathComponent(segmentId.uuidString, isDirectory: true)
        ensureDirectory(at: dir)
        return dir.appendingPathComponent("\(voiceId)-v\(textVariantIndex).m4a")
    }

    // MARK: - 分镜头 AI 编辑变体存储

    /// 分镜头变体视频：AppSupport/MixCut/ShotVariants/{videoHash}/{shotId}/{variantId}.mp4
    static func shotVariantURL(videoHash: String, shotId: UUID, variantId: UUID) -> URL {
        let dir = shotVariantsDirectory
            .appendingPathComponent(videoHash, isDirectory: true)
            .appendingPathComponent(shotId.uuidString, isDirectory: true)
        ensureDirectory(at: dir)
        return dir.appendingPathComponent("\(variantId.uuidString).mp4")
    }

    /// 分镜头变体缩略图（与变体视频同目录，后缀 .jpg）
    static func shotVariantThumbnailURL(videoHash: String, shotId: UUID, variantId: UUID) -> URL {
        let dir = shotVariantsDirectory
            .appendingPathComponent(videoHash, isDirectory: true)
            .appendingPathComponent(shotId.uuidString, isDirectory: true)
        ensureDirectory(at: dir)
        return dir.appendingPathComponent("\(variantId.uuidString).jpg")
    }

    /// 分镜头首帧缩略图：AppSupport/MixCut/ShotThumbnails/{videoHash}/{shotId}.jpg
    static func shotThumbnailURL(videoHash: String, shotId: UUID) -> URL {
        let dir = shotThumbnailsDirectory
            .appendingPathComponent(videoHash, isDirectory: true)
        ensureDirectory(at: dir)
        return dir.appendingPathComponent("\(shotId.uuidString).jpg")
    }

    // MARK: - 就地画面替换产物存储

    /// 替换画面视频：AppSupport/MixCut/ReplacedPictures/{videoHash}/{segmentId}.mp4
    static func replacedPictureURL(videoHash: String, segmentId: UUID) -> URL {
        let dir = replacedPicturesDirectory
            .appendingPathComponent(videoHash, isDirectory: true)
        ensureDirectory(at: dir)
        return dir.appendingPathComponent("\(segmentId.uuidString).mp4")
    }

    /// 替换画面缩略图（与替换视频同目录，后缀 .jpg）
    static func replacedPictureThumbnailURL(videoHash: String, segmentId: UUID) -> URL {
        let dir = replacedPicturesDirectory
            .appendingPathComponent(videoHash, isDirectory: true)
        ensureDirectory(at: dir)
        return dir.appendingPathComponent("\(segmentId.uuidString).jpg")
    }

    // MARK: - 人声分离（demucs）模型与产物

    /// demucs GGML 模型存储目录（AppSupport，理由同 Whisper：不能放 Caches 被系统清理）。
    static var demucsModelsDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("demucs-models", isDirectory: true)
        ensureDirectory(at: url)
        excludeFromBackup(url)
        return url
    }

    /// 人声分离产物缓存目录：AppSupport/MixCut/Stems/{videoHash}/（vocals.wav / bgm.wav）。
    /// 整轨分离一次后按需切片，键 = videoHash（确定性，避免重复分离）。
    static func stemsDirectory(videoHash: String) -> URL {
        let dir = appSupportDirectory
            .appendingPathComponent("Stems", isDirectory: true)
            .appendingPathComponent(videoHash, isDirectory: true)
        ensureDirectory(at: dir)
        return dir
    }

    // MARK: - BGM 库（全局共享）

    /// BGM 库目录：AppSupport/MixCut/BGM/。
    /// 上传的音频文件直接落此目录，"库"即目录扫描，无数据库记录（避免 schema 变更）。
    static var bgmLibraryDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("BGM", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - Logo 库（全局共享）

    /// Logo 库目录：AppSupport/<Brand>/LogoLibrary/。
    /// 文件名是裁边后 PNG 的内容哈希；Project 只存引用，跨项目复用/去重。
    static var logoLibraryDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("LogoLibrary", isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    // MARK: - Whisper 语音模型存储

    /// Whisper 语音模型存储目录。
    ///
    /// ⚠️ 必须放在 Application Support，**绝不能**放 `~/Library/Caches`：
    /// macOS 把 Caches 当作「可重建缓存」，磁盘紧张 / 重启 / 系统维护时会主动清空，
    /// 而模型（GB 级，具体档位只由 `ASRPolicy.engineTier` 定）重下成本极高。曾因放 Caches 导致用户重启后模型丢失。
    static var whisperModelsDirectory: URL {
        let url = appSupportDirectory.appendingPathComponent("whisper-models", isDirectory: true)
        ensureDirectory(at: url)
        // 标记不参与备份：GB 级模型可随时重下，无需进 Time Machine / iCloud
        excludeFromBackup(url)
        return url
    }

    /// 旧版模型目录（`~/Library/Caches/com.mixcut.app/whisper-models`），仅用于一次性迁移读取
    static var legacyCacheWhisperModelsDirectory: URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return cacheDir.appendingPathComponent(Brand.legacyWhisperModelsComponent, isDirectory: true)
    }

    /// 一次性迁移：把旧 Caches 目录里的 whisper 模型移动到 Application Support。
    /// 幂等，可安全多次调用；同卷 move 是元数据操作，1.5GB 也瞬间完成。
    static func migrateWhisperModelsToAppSupport() {
        let fm = FileManager.default
        guard let legacyDir = legacyCacheWhisperModelsDirectory,
              fm.fileExists(atPath: legacyDir.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) else { return }

        let destDir = whisperModelsDirectory
        // 同时迁移 .bin（完整模型）和 .bin.partial（断点续传临时文件），
        // 否则旧目录会残留最多 1.5GB 的 partial 文件，且续传进度丢失
        for src in entries where src.pathExtension == "bin" || src.pathExtension == "partial" {
            let dest = destDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                // 新目录已有同名文件，旧的直接删除回收空间
                try? fm.removeItem(at: src)
                continue
            }
            do {
                try fm.moveItem(at: src, to: dest)
                MixLog.info("已迁移 Whisper 模型文件到 Application Support: \(src.lastPathComponent)")
            } catch {
                MixLog.error("迁移 Whisper 模型文件失败 \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // 迁移后清理空的旧目录
        if let remaining = try? fm.contentsOfDirectory(atPath: legacyDir.path), remaining.isEmpty {
            try? fm.removeItem(at: legacyDir)
        }
    }

    /// 将目录标记为不参与备份（iCloud / Time Machine）。
    /// 幂等：已标记则直接跳过，避免每次访问目录都重复写元数据。
    private static func excludeFromBackup(_ url: URL) {
        var target = url
        // 已经标记过就不再重复设置（省去重复 syscall）
        if let already = try? target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
           already {
            return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
        } catch {
            MixLog.error("标记目录不参与备份失败 \(url.path): \(error.localizedDescription)")
        }
    }

    /// 拷贝视频文件到全局目录（按 hash 子目录存储，同一视频只保留一份）
    static func copyVideoToGlobal(from sourceURL: URL, contentHash: String) throws -> URL {
        let hashDir = globalVideoDirectory.appendingPathComponent(contentHash, isDirectory: true)
        ensureDirectory(at: hashDir)
        let destURL = hashDir.appendingPathComponent(sourceURL.lastPathComponent)

        // 文件已存在则跳过（同 hash 同文件名，内容一定相同）
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    /// 删除全局视频文件（当无任何项目引用时调用）
    static func deleteGlobalVideoFiles(localPath: String, thumbnailPath: String?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: localPath) {
            // 删除文件
            try? fm.removeItem(atPath: localPath)
            // 尝试删除空的 hash 子目录
            let parentDir = (localPath as NSString).deletingLastPathComponent
            if let contents = try? fm.contentsOfDirectory(atPath: parentDir), contents.isEmpty {
                try? fm.removeItem(atPath: parentDir)
            }
        }
        if let thumbPath = thumbnailPath, fm.fileExists(atPath: thumbPath) {
            try? fm.removeItem(atPath: thumbPath)
        }
    }

    // MARK: - 品牌目录一次性迁移

    /// 完成标志存的是"迁到了哪个目录名"，不是布尔：换品牌时目录名一变，存的值就不再相等，
    /// 迁移会自动再触发一次。键名与"不许跨域继承"的规则同住 `LegacySettingsImport`。
    ///
    /// 这个值同时是孤儿 GC 的冻结门：迁移未完成时库里的路径仍指着旧目录，任何"未引用"判定都不可信。
    static var isBrandDirectoryMigrationComplete: Bool {
        UserDefaults.standard.string(forKey: LegacySettingsImport.migratedToKey) == Brand.dataDirectoryName
    }

    /// 把数据从历史目录名搬到当前目录名。同卷 `moveItem` 是 rename，GB 级也瞬间完成，绝不用 `cp -R`。
    ///
    /// 幂等：源已不存在就跳过；**新旧两处同名则整轮中止**（不敢猜哪一份在用）。
    /// 任何一步没成都不写完成标志，于是 GC 一直冻着 —— 宁可留着孤儿，也不能删错。
    @discardableResult
    static func migrateToBrandDirectoryIfNeeded() -> Bool {
        guard !isBrandDirectoryMigrationComplete else { return true }
        let fm = FileManager.default
        let legacy = legacyAppSupportDirectory
        let target = appSupportDirectory          // 顺带把新目录建出来
        let entries = (try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []
        let plan = BrandDirectoryMigration.plan(
            oldDirectoryName: Brand.legacyDataDirectoryName,
            newDirectoryName: Brand.dataDirectoryName,
            legacyStoreFileName: Brand.legacyStoreFileName,
            storeFileName: Brand.storeFileName,
            entries: entries
        )

        var moved = 0
        switch BrandDirectoryMigration.execute(plan, oldDirectory: legacy, newDirectory: target) {
        case .collision(let name):
            MixLog.error("[BrandMigration] \(name) 在新旧两处都有，不敢猜哪一份在用 —— 迁移中止，孤儿 GC 保持冻结")
            return false
        case .failed(let name, let reason):
            MixLog.error("[BrandMigration] 搬迁 \(name) 失败：\(reason) —— 迁移未完成，孤儿 GC 保持冻结")
            return false
        case .done(let count):
            moved = count
        }
        excludeFromBackup(target)

        // 旧目录只剩回退料（backup-*），改名 -legacy 摆在原地，免得被当成当前数据目录
        if Brand.legacyDataDirectoryName != Brand.dataDirectoryName,
           fm.fileExists(atPath: legacy.path) {
            let remnant = appSupportBaseDirectory
                .appendingPathComponent("\(Brand.legacyDataDirectoryName)-legacy", isDirectory: true)
            if fm.fileExists(atPath: remnant.path) {
                MixLog.info("[BrandMigration] \(remnant.lastPathComponent) 已存在，旧目录原样保留")
            } else {
                do { try fm.moveItem(at: legacy, to: remnant) }
                catch {
                    MixLog.error("[BrandMigration] 旧目录改名 -legacy 失败（可容忍，内容已搬空）：\(error.localizedDescription)")
                }
            }
        }

        UserDefaults.standard.set(Brand.dataDirectoryName, forKey: LegacySettingsImport.migratedToKey)
        MixLog.info("[BrandMigration] 目录迁移完成：搬迁 \(moved) 项，留在旧目录 \(plan.keepBehind.count) 项")
        return true
    }

    // MARK: - 孤儿文件 GC

    /// 回收孤儿文件：扫描全局视频/缩略图目录，删除"数据库已无任何记录引用"的文件。
    /// referencedPaths 由调用方从所有 Video/Segment 记录收集（localPath/thumbnailPath/segment.thumbnailPath）。
    static func collectOrphanFiles(referencedPaths: Set<String>) {
        let fm = FileManager.default
        var onDisk: [String] = []
        // 视频：Videos/{hash}/xxx.mp4（两级）
        if let hashDirs = try? fm.contentsOfDirectory(at: globalVideoDirectory, includingPropertiesForKeys: nil) {
            for hashDir in hashDirs {
                if let files = try? fm.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: nil) {
                    onDisk.append(contentsOf: files.map(\.path))
                }
            }
        }
        // 缩略图：Thumbnails/xxx
        if let thumbs = try? fm.contentsOfDirectory(at: globalThumbnailDirectory, includingPropertiesForKeys: nil) {
            onDisk.append(contentsOf: thumbs.map(\.path))
        }
        // 就地替换画面：ReplacedPictures/{hash}/xxx.mp4|.jpg（两级）
        let replacedDir = replacedPicturesDirectory
        if let hashDirs = try? fm.contentsOfDirectory(at: replacedDir, includingPropertiesForKeys: nil) {
            for hashDir in hashDirs {
                if let files = try? fm.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: nil) {
                    onDisk.append(contentsOf: files.map(\.path))
                }
            }
        }
        // 分镜头缩略图：ShotThumbnails/{hash}/xxx.jpg（两级）
        let shotThumbDir = shotThumbnailsDirectory
        if let hashDirs = try? fm.contentsOfDirectory(at: shotThumbDir, includingPropertiesForKeys: nil) {
            for hashDir in hashDirs {
                if let files = try? fm.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: nil) {
                    onDisk.append(contentsOf: files.map(\.path))
                }
            }
        }
        // 分镜头变体产物：ShotVariants/{hash}/{shotId}/xxx.mp4|.jpg（三级）
        let shotVarDir = shotVariantsDirectory
        if let hashDirs = try? fm.contentsOfDirectory(at: shotVarDir, includingPropertiesForKeys: nil) {
            for hashDir in hashDirs {
                if let shotDirs = try? fm.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: nil) {
                    for shotDir in shotDirs {
                        if let files = try? fm.contentsOfDirectory(at: shotDir, includingPropertiesForKeys: nil) {
                            onDisk.append(contentsOf: files.map(\.path))
                        }
                    }
                }
            }
        }

        let raw = OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referencedPaths)
        let orphans = OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referencedPaths)
        if orphans.isEmpty && !raw.isEmpty {
            // 本可以删掉整批文件，但引用集与磁盘零交集 —— 说明判断依据不可信（库退到内存模式、
            // 目录迁移尚未改写路径等）。宁可留着孤儿，也不能把在用素材删掉。
            MixLog.error("[OrphanGC] 跳过回收：磁盘 \(onDisk.count) 个文件与库内 \(referencedPaths.count) 条引用零交集（疑似迁移未完成或库不可用）")
        }
        for path in orphans {
            try? fm.removeItem(atPath: path)
        }
        // 清理空的 hash 子目录
        if let hashDirs = try? fm.contentsOfDirectory(at: globalVideoDirectory, includingPropertiesForKeys: nil) {
            for hashDir in hashDirs where (try? fm.contentsOfDirectory(atPath: hashDir.path))?.isEmpty == true {
                try? fm.removeItem(at: hashDir)
            }
        }
        if !orphans.isEmpty { MixLog.info("GC 回收孤儿文件 \(orphans.count) 个") }
    }

    /// 临时文件目录
    static var tempDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Brand.dataDirectoryName, isDirectory: true)
        ensureDirectory(at: url)
        return url
    }

    /// 删除整个项目目录（早期按项目存储时的兼容清理；新数据走全局目录但此函数保留以彻底清空老目录）
    static func deleteProjectDirectory(for projectID: UUID) {
        let projectDir = appSupportDirectory
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: projectDir)
        } catch {
            MixLog.error("删除项目目录失败 \(projectID): \(error.localizedDescription)")
        }
    }
}

// MARK: - 只读坐标（新增代码一律追加在文件末尾：本文件有外部按行号的引用，中间插行会把它们全部弄旧）

extension FileHelper {

    /// 素材根目录的目录名，只写这一次；写入侧与只读侧都从这里取。
    static let videosDirectoryName = "Videos"

    /// 数据目录的**坐标**：只算路径，绝不创建。
    ///
    /// 与 `legacyAppSupportDirectory` 同一条守法 —— 目录不存在就等于没东西可看。
    /// 需要"顺手建目录"的调用方请用 `appSupportDirectory`。
    static var appSupportDirectoryForReading: URL {
        appSupportBaseDirectory.appendingPathComponent(Brand.dataDirectoryName, isDirectory: true)
    }

    /// 素材根目录的**坐标**：只算路径，绝不创建。
    ///
    /// ⚠️ 磁盘对账这条轴必须用这颗，**不能用 `globalVideoDirectory`**：后者读一次路径就把目录
    /// 建了出来，于是"素材根目录本身不在（外置卷未挂载 / 数据目录被移走）"这道兜底
    /// 在生产里永不可达 —— 那道门（`MissingMaterialFinder.safeMissingIDs` 的第一关）会退化成
    /// 一句永远为真的话。只读侧要的是"它现在在不在"，不是"把它变出来"。
    static var globalVideoDirectoryForReading: URL {
        appSupportDirectoryForReading.appendingPathComponent(videosDirectoryName, isDirectory: true)
    }

    /// 问「这条路径现在能不能用」的**唯一出口**（三态）。
    ///
    /// 为什么只能有这一颗：这条问题此前散在 8 个文件里各问一遍（`reidentify`/`reextract`/克隆原声/
    /// 导出/两个播放器/…），于是"到底算不算在"有 N 个答案 —— 同一份 0 字节文件，播放那边算"在"、
    /// 导出那边算"没了"。批 4 的磁盘对账与批 5 的各条链现在都问这一颗。
    ///
    /// 三档不许压成两档：`fileExists` 对**0 字节**与**无读权限**文件都判「在」，而这两种文件播放与
    /// ffmpeg 都会失败；把「读不动」并进「不存在」则会误藏一张还能救的卡（方向性代价见
    /// `MissingMaterialFinder` 文件头：藏一张好卡比多显示一张死卡更错）。
    static func materialProbe(_ path: String) -> MaterialProbeReading {
        let fm = FileManager.default
        guard !path.isEmpty else { return .absent }
        guard fm.fileExists(atPath: path) else { return .absent }
        guard fm.isReadableFile(atPath: path) else { return .unreadable }
        let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int
        return size == 0 ? .unreadable : .present
    }

    /// 素材可用性判定的布尔便捷口（= `materialProbe` 的"能用"那一档）。
    ///
    /// ⚠️ 调用方**不许**再自己写 `FileManager.default.fileExists(atPath: 素材路径)`；
    /// 判据 G-M03 盯着素材轴文件里的裸问法，长出一处就红。
    static func isMaterialFilePresent(path: String) -> Bool {
        materialProbe(path) == .present
    }
}
