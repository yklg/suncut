import Foundation
import SwiftData
import AVFoundation
import CryptoKit

// ============================================================================
// ClipIngestService · 「把素材文件落进某个 Project」这件事的真身
//
// ## 为什么存在（计划 D-0 / 台账 D32，Context 第 5 条根因）
//
// 这活以前长在 `ImportViewModel` 里，而那颗对象同时是**导入页的 UI 状态宿主**
// （`phase` / `progress` / `progressDescription` / `errorMessage` / `isProcessing`）。
// `ContentView.swift:97` 把它提到根、`:132` 给混剪页、`:269` 给导入页 —— 同一个实例，
// 于是混剪跑起来时导入页的进度条在显示「混剪入库第 3/60 个…」。
// 加个"归属位"只是把串味藏起来；本文件把它从结构上断开：**入库这件事不带 UI 状态**。
//
// ## 生效条件与拦不住什么（照本仓"注入点要写清代价"的规矩）
//
// ✅ 生效：本文件**不出现** `phase` / `progress` / `progressDescription` / `errorMessage`
//    / `ToastCenter` 任何一颗（门 T-24 逐串扫）。要显示什么，只能经 `Hooks` 回调出去，
//    由调用方决定怎么写自己的界面。
// ❌ 拦不住：调用方在自己的 hook 里写出奇怪的东西；以及 `Hooks` 之外的新参数被塞进
//    UI 闭包。所以 hook 的签名只给"事实"（第几个、总共几个、失败原因、中止原因），
//    不给"该怎么显示"。
// ⚠️ 本文件**一次 `context.delete(` 都没有**：停止与失败都不删任何东西
//    （与既有 `finishAsCancelled` 的"停止 ≠ 删除"同口径）。取消收尾留在 VM，
//    经 `Hooks.cancelled` 回调 —— 删除点若搬进这里，G12 真删名册会当场多出一颗。
//
// ## `@MainActor` 是允许的
//
// 先例 `SegmentCommitter.swift:25-26` 自带 `@MainActor`、且不碰任何 UI 读数 —— SwiftData 的
// `ModelContext` 本来就在主 actor 上，脱离它反而把每个插入点变成一次 hop。
// 要禁的是"为写 UI 而 `@MainActor`"，不是它本身。
// ============================================================================

/// 入库过程的**事实**回调。名字里不出现"进度/错误"这类界面词，就是为了不让这里长出 UI 语义。
@MainActor
struct ClipIngestHooks {
    /// 单个文件开始处理（序号从 0 起、总数）。调用方要不要显示、怎么显示，是它的事。
    var fileStarting: (_ index: Int, _ total: Int) -> Void = { _, _ in }
    /// 进入"正在拷贝落盘"这一步。母体导入链用它写 `phase = .copying`；混剪链可以完全不理。
    var copying: () -> Void = {}
    /// 某个文件失败（文件名 + 已友好化的原因）。
    var failure: (_ file: String, _ reason: String) -> Void = { _, _ in }
    /// 整批因磁盘不足中止（已格式化好的两个容量串）。
    var diskShortfall: (_ needed: String, _ available: String) -> Void = { _, _ in }
    /// 用户点了停止：调用方去做自己的收尾（本服务不删任何东西）。
    var cancelled: () -> Void = {}
    /// 整批走完（收尾读数由调用方决定）。
    var finished: () -> Void = {}
    /// 每 5 个文件一次的节流落盘后通知。
    var batchSaved: () -> Void = {}
}

@MainActor
enum ClipIngestService {

    /// 全仓**唯一**的文件校验和实现（门 T-27 钉住"定义处恰好 1 处"）。
    ///
    /// 口径：SHA-256 over `String(fileSize)` + 头 4 MB + 尾 4 MB —— **不是整片**。
    /// 所以"内容相同"这句话在界面上只能写成"大小相同且头尾各 4 MB 相同"。
    /// 原先它长在 `ImportViewModel` 里（`:1419`），service 与混剪 reader 去调它就是
    /// Service → ViewModel 的反向依赖（计划 D34 / 评审 P0-3），故整颗搬到这里。
    ///
    /// `nonisolated`：这颗只读文件 + 算哈希，不碰 `ModelContext`、不碰任何 UI 状态，
    /// 所以没理由占主 actor。混剪的「精确识别（慢）」要对上千个文件逐条算，
    /// 若继承 `@MainActor`，每一趟 8 MB 读盘都排在主线程上 ⇒ 界面直接卡成幻灯片。
    nonisolated static func computeFileHash(path: String) -> String? {
        do {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attrs[.size] as? Int64) ?? 0

            var hasher = SHA256()
            hasher.update(data: Data(String(fileSize).utf8))

            let chunkSize = 4 * 1024 * 1024
            let headData = handle.readData(ofLength: chunkSize)
            hasher.update(data: headData)

            if fileSize > Int64(chunkSize * 2) {
                handle.seek(toFileOffset: UInt64(fileSize) - UInt64(chunkSize))
                let tailData = handle.readData(ofLength: chunkSize)
                hasher.update(data: tailData)
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            MixLog.error(" 计算文件哈希失败: \(error)")
            return nil
        }
    }

    /// 查找全局已有的同 hash 视频。
    static func findExistingVideo(hash: String, context: ModelContext) -> Video? {
        let descriptor = FetchDescriptor<Video>(
            predicate: #Predicate<Video> { video in
                video.contentHash == hash
            }
        )
        guard let videos = try? context.fetch(descriptor) else { return nil }
        return videos.first
    }

    /// 使用 AVFoundation 提取视频元数据。**全仓 `Video.duration` 的唯一写点。**
    static func extractMetadata(for video: Video, at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        video.duration = CMTimeGetSeconds(duration)

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformedSize = size.applying(transform)
            video.width = Int(abs(transformedSize.width))
            video.height = Int(abs(transformedSize.height))

            let rate = try await track.load(.nominalFrameRate)
            video.fps = Double(rate)
        }
    }

    /// 生成视频缩略图（全局目录）。`ffmpeg` 由调用方注入，不在这里另起一台。
    static func generateVideoThumbnail(for video: Video, using ffmpeg: FFmpegRunner) async throws {
        let thumbDir = FileHelper.globalThumbnailDirectory
        let thumbPath = thumbDir.appendingPathComponent("\(video.id.uuidString).jpg").path

        try await ffmpeg.generateThumbnail(from: video.localPath, to: thumbPath)
        video.thumbnailPath = thumbPath
    }

    /// 单个文件：落进全局库并挂到项目上，命中去重时只做幂等关联。
    ///
    /// 六步的形状对每个调用方都成立（母体导入的阶段 1 / 文件夹混剪 / 将来第四个），
    /// 所以共用同一个动作，而不是"照抄一遍步骤"。
    /// - `source` **必填**（计划 D20/R12）：以前这行写的是 `pendingBatchSource.rawValue`
    ///   —— 一个默认 `.curated`（搬运）的实例可变状态，调用方不显式赋值就静默把整批素材
    ///   标成"他人视频"，编译器不拦、既有测试也不覆盖。守卫 T-16 钉住这条不许回来。
    /// - 算不出校验和 ⇒ **拒绝该文件**（计划 R17）：以前这里退化成 `UUID()` 当目录名继续入库，
    ///   而那条分支**同时跳过**了上面的 hash 去重 ⇒ 同一文件反复进来就反复成行、每行各带分镜，
    ///   把混剪 D3「本次会话内不回放」直接击穿；几十条一批时命中概率还被放大。
    ///   宁可少一条并让调用方逐名上报，不可静默降级。
    static func importOrLink(url: URL, to project: Project,
                             source: SegmentSource, context: ModelContext,
                             hooks: ClipIngestHooks,
                             ffmpeg: FFmpegRunner) async throws -> (Video, Bool) {
        hooks.copying()

        // 先计算文件 hash（算不出来 = 读不出这个文件，按拒绝档上报）
        guard let hash = computeFileHash(path: url.path) else {
            throw ImportIngestError.uncomputableHash(url.lastPathComponent)
        }

        // 查找全局是否已有同 hash 的视频
        if let existingVideo = findExistingVideo(hash: hash, context: context) {
            // 已有此视频：幂等挂到本项目（同一素材第二次进来不产生第二行关联）
            ProjectVideo.associate(project: project, video: existingVideo, in: context)
            context.safeSave()
            MixLog.info(" 全局已有视频「\(existingVideo.name)」(hash=\(hash.prefix(8))...)，直接关联到项目")

            let needsAnalysis = existingVideo.status != .completed || existingVideo.segments.isEmpty
            return (existingVideo, needsAnalysis)
        }

        // 全局没有，创建新的
        let destURL = try FileHelper.copyVideoToGlobal(from: url, contentHash: hash)

        let video = Video(name: url.lastPathComponent, localPath: destURL.path)
        video.status = .imported
        video.contentHash = hash
        // 导入事实：首次导入所在项目 + 本批选定来源。命中去重复用的已有视频在上面的分支直接返回，
        // 不会走到这里，因此这两个事实字段不存在被覆写的路径。
        video.ownerProject = project
        video.defaultSourceRaw = source.rawValue
        context.insert(video)

        // 创建 ProjectVideo 关联（幂等入口）
        ProjectVideo.associate(project: project, video: video, in: context)
        context.safeSave()

        // 提取元数据（失败不阻塞）
        do {
            try await extractMetadata(for: video, at: destURL)
        } catch {
            video.errorMessage = "元数据提取失败: \(FriendlyError.reason(for: error))"
        }

        // 生成视频缩略图（失败不阻塞）
        do {
            try await generateVideoThumbnail(for: video, using: ffmpeg)
        } catch {
            MixLog.error("缩略图生成失败: video=\(video.name), error=\(error)")
        }

        context.safeSave()
        return (video, true)
    }

    /// 一批文件落进一个项目，**不跑分析**（D8：不跑 ASR、不跑 AI 打标、不碰网络）。
    ///
    /// 逐文件复用 `importOrLink`，不复制那六步。
    ///
    /// ⚠ 幂等纪律：`commitWholeVideo` 每次调用都**新建**一条 Segment，它自己不判重
    /// （实读 `SegmentCommitter.swift:166-181`，函数体里没有任何"已有整片段"的检查）。
    /// 所以守门必须在调用方：**已有任何分镜的视频不再建段**。否则重扫同一目录会给同一素材
    /// 叠出第二条整片段 ⇒ 混剪抽片出现"同一素材的两个副本"。
    /// （这一条就是计划「未知清单」第 1 行的闭合：它对 >30s、无台词都没有隐含假设，
    ///  唯独对"被重复调用"没有防护 ⇒ 丁案成立，但要带这道门。）
    ///
    /// - Parameter source: **必填**（D20）。这批素材是自拍还是搬运，只有用户知道；
    ///   没有默认值可退，因为默认值曾经把整批素材静默标成"搬运"。
    static func importClips(urls: [URL], to project: Project,
                            source: SegmentSource, context: ModelContext,
                            committer: SegmentCommitter, ffmpeg: FFmpegRunner,
                            hooks: ClipIngestHooks) async -> ImportReport {
        var report = ImportReport()

        // 磁盘预检走 Core 的同一个式子（`DiskSpaceBudget`），不在这里再抄一遍 `× 2`。
        // 成片项这里传空数组：混剪只到方案（D17），落盘 mp4 发生在导出页，
        // 那一头需要的是「素材 ×2 ＋ Σ 每条成片」——本函数只负责入库那一半。
        let totalFileSize = urls.compactMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        }.reduce(0, +)
        let requiredSpace = DiskSpaceBudget.requiredBytes(
            materialBytes: totalFileSize, outputDurations: [],
            bitrateMbps: DiskSpaceBudget.defaultOutputBitrateMbps)
        if let availableSpace = try? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           !DiskSpaceBudget.isSufficient(freeBytes: availableSpace, requiredBytes: requiredSpace) {
            let needed = ByteCountFormatter.string(fromByteCount: requiredSpace, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
            let message = "磁盘空间不足：需要约 \(needed)，当前可用 \(available)"
            MixLog.error("[FolderMix] 磁盘预检未过：project=\(project.name) 需要 \(needed)，可用 \(available)")
            hooks.diskShortfall(needed, available)
            report.abortMessage = message
            return report
        }

        project.status = .importing
        context.safeSave()

        var builtWholeClip = 0
        var linkedOnly = 0
        var internalWholeClipBuilt = 0
        for (index, url) in urls.enumerated() {
            // 用户点了停止：已入库的保留（复用阶段 1 的取消语义，停止 ≠ 删除）
            if Task.isCancelled {
                MixLog.info("[FolderMix] 用户停止入库，已完成 \(index)/\(urls.count) 个文件")
                hooks.cancelled()
                report.abortMessage = "用户停止混剪导入"
                return report
            }
            hooks.fileStarting(index, urls.count)

            do {
                // needsAnalysis 这个返回值在这里**刻意被丢掉**：阶段 2（镜头检测 + ASR + AI）
                // 是 D8 明令不跑的，母体链将来导入同一文件时照常会跑（status 仍是 .imported，
                // :418 的判定不被污染 —— 这正是 ④ 方案选择"不加枚举"的正面理由）。
                let (video, _) = try await importOrLink(url: url, to: project, source: source,
                                                        context: context, hooks: hooks, ffmpeg: ffmpeg)
                if video.segments.isEmpty {
                    _ = committer.commitWholeVideo(for: video, source: source, context: context)
                    builtWholeClip += 1
                    report.importedVideoIDs.append(video.id)
                    report.importedNames.append(video.name)
                    report.ingested.append(FolderMixIngestedRow(sourcePath: url.path,
                                                                videoID: video.id))
                } else {
                    // 已有分镜（重扫同一目录，或这素材此前走过别的链路）⇒ 默认只关联，不再叠一条整片段
                    linkedOnly += 1
                    report.linkedExistingNames.append(video.name)
                    // 甲-隐（决议 K2 + K3，计划 2026-10-22 第三轮 笔 K2）：这一行有分镜、
                    // 却没有一条**覆盖全片**的段时，为混剪补建一条整片段。三条守门缺一不可：
                    //   ① 形状守门走 `WholeClipShape` 那颗真源 ⇒ 幂等：重扫同一目录第二次时，
                    //      第一次补的那条就在 ⇒ 永远不再叠第二片（判据 JOIN-25）；
                    //   ② 在盘守门走 `FileHelper.materialProbe` 那颗唯一探针 ⇒ 绝不给指向空文件的行
                    //      补段，否则"坏"会从导出期被提前伪装成"可用"（判据 JOIN-26）；
                    //   ③ 建出来就带 `mixInternalWholeClip` 标记 ⇒ 分镜素材库与 AI 候选池都不列它
                    //      （可见性只走决议 K9 那颗唯一出口，判据门 T-33）。
                    // 为什么这一支天然只属于混剪、不需要"哪条链"的入参：`importClips` 全仓
                    // **只有一个生产调用方**（`FolderMixViewModel` 的混剪入库）；母体导入页走的是
                    // `ImportViewModel.importVideos`，而 1b 下沉留下的那层适配层零生产调用方。
                    // 补建后的段数恒 ≥ 2 ⇒ `WholeClipShape` 的 W1（`count == 1`）恒 false ⇒
                    // 母体首跑的 clearsExistingSegments 判定与启动期 restoreSelfBuiltFlags 都不会误命中（JOIN-27）。
                    let hasWholeClip = video.segments.contains { segment in
                        WholeClipShape.isWholeClip(
                            segments: [WholeClipSegmentShape(startTime: segment.startTime,
                                                            endTime: segment.endTime)],
                            videoDuration: video.duration)
                    }
                    if !hasWholeClip, FileHelper.materialProbe(video.localPath) == .present {
                        let built = committer.commitWholeVideo(for: video, source: source,
                                                               context: context)
                        built.mixInternalWholeClip = true
                        internalWholeClipBuilt += 1
                    }
                    // 这一支**原本把 id 丢掉只留名字** —— 真机 50 条全被摘掉就是这么来的：
                    // 混剪后来只能拿名字/库内路径去猜这一行，而猜必然落空。对应关系在这里
                    // 还是已知量，过了这一步就再也拿不回来了。
                    report.ingested.append(FolderMixIngestedRow(sourcePath: url.path,
                                                                videoID: video.id))
                }
            } catch {
                let file = url.lastPathComponent
                let reason = FriendlyError.reason(for: error)
                hooks.failure(file, reason)
                report.failed.append(.init(name: file, reason: reason, path: url.path,
                                           code: FolderMixFailureCode.classify(error)))
            }

            // 每 5 个文件回写一次进度（计划 Step 3 的节流口径；safeSave 自己会吞错）
            if index % 5 == 4 {
                context.safeSave()
                hooks.batchSaved()
            }
        }

        context.safeSave()
        project.status = .ready
        project.updatedAt = Date()
        context.safeSave()
        report.internalWholeClipBuilt = internalWholeClipBuilt
        hooks.finished()
        // G-h 那句关键路径日志：三档各一个数，界面上「本轮自动补建 k 条」用的就是这颗。
        MixLog.info("[FolderMix] 入库完成：项目「\(project.name)」新建整片段 \(builtWholeClip)、"
                    + "仅关联 \(linkedOnly)、补建内部整片段 \(internalWholeClipBuilt)、"
                    + "失败 \(report.failed.count)")
        return report
    }
}

// MARK: - 失败分类（计划 D 段第 2 条的前提）

extension FolderMixFailureCode {
    /// 从**错误本身**分类，不看 `reason` 的措辞。
    ///
    /// 为什么禁字符串匹配：`reason` 走的是 `FriendlyError`/`localizedDescription`，是**给人看的句子**，
    /// 会随文案改动、随系统语言改动。而"连续同因 ⇒ 环境级故障 ⇒ 停整批"这条判断
    /// 一旦建立在措辞上，改一句文案就能让磁盘满不再短路（变成对着满盘重试上千次），
    /// 或者反过来把两类无关失败并成"同一场故障"提前掐掉正常批。
    ///
    /// 拦不住什么：`NSError` 的 domain/code 是系统给的，本函数只认得它明说的三类
    /// （空间不足 / 权限 / 读不出）；系统只回一句"操作失败"时落 `.other` —— 而 `.other`
    /// 被 `isSystemic == false` 挡在短路之外，所以宁可少短路，不可误短路。
    static func classify(_ error: Error) -> FolderMixFailureCode {
        if error is ImportIngestError { return .unreadable }     // 校验和算不出 = 读不出内容
        if let posix = error as? POSIXError {
            switch posix.code {
            case .ENOSPC: return .diskShortfall
            case .EACCES, .EPERM: return .noPermission
            case .EIO, .ENOENT, .EBADF: return .unreadable
            default: return .other
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError:
                return NSFileWriteVolumeReadOnlyError == ns.code ? .noPermission : .diskShortfall
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .noPermission
            case NSFileReadNoSuchFileError, NSFileReadCorruptFileError,
                 NSFileReadInapplicableStringEncodingError, NSFileWriteInapplicableStringEncodingError:
                return .unreadable
            default: break
            }
        }
        // AVFoundation 的错误码在本机 SDK 上没有可直接引用的 Swift 名字（实测
        // `AVError.mediaFileMissingError` 与 `AVError.Code.mediaFileMissing` 都不存在），
        // 而按 `ns.code` 的整数硬编码 = 把系统枚举值抄成魔法数 —— 那比不分类更糟。
        // 所以 AV 侧一律落 `.other`（下面那句），代价是"外接盘被拔"时 AV 报错不提前短路整批，
        // 会由紧随其后的 Cocoa/POSIX 错误停住 —— `.other` 被 isSystemic 挡在短路之外，宁可少短路。
        return .other
    }
}
