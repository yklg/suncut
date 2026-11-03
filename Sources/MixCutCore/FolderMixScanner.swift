import Foundation

// ============================================================================
// 文件夹混剪 · 「一级子目录名 → 类别 → 候选文件名」投影（纯值类型 + 纯函数）。
//
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md（D1/D2/D12/D13 + Step 1）
// 零 IO：本文件不许出现 FileManager / URL 目录遍历 —— 扫盘是 App 层 MaterialFolderScanner 的事，
// 它把「文件夹名 + 该目录一级文件名」拍成值传进来，判定与归一全在这里（守卫 G-c 的同款口径）。
//
// 接口锁定（FolderMixScannerTests 依赖这些形状）：
//
//   public enum VideoFileFormat {
//       static let videoExtensions: [String]                    // 全仓唯一扩展名真源
//       static func isVideoExtension(_ ext: String) -> Bool     // 给 url.pathExtension 用
//       static func isVideoFileName(_ name: String) -> Bool     // 给纯文件名用
//       static func pathExtension(of name: String) -> String
//   }
//   public struct FolderMixRawFile      { name, byteSize }
//   public struct FolderMixRawDirectory { rawName, files, fileNames(视图) }
//   public struct FolderMixVideoFile    { folder, name, byteSize }
//   public struct FolderMixCategory     { name, rawFolderNames, videoFiles, rejectedFileNames,
//                                         isEmpty, mergedFolderNames,
//                                         videoFileNames/videoFolders/videoByteSizes/videoPaths(视图) }
//   public struct FolderMixScanResult   { categories, emptyCategories, mergedCategories,
//                                         totalVideoFiles, totalRejectedFiles }
//   public enum FolderMixScanner {
//       static func normalizeCategoryName(_ raw: String) -> String
//       static func scan(_ directories: [FolderMixRawDirectory]) -> FolderMixScanResult
//   }
//
// 规则：
//   S1 层级：输入已被 IO 层限定为一级子目录，投影**不再下钻**，也不判断是不是目录（IO 层判）。
//   S2 过滤：非白名单扩展名不静默丢 —— 逐名进 `rejectedFileNames`（第九节「某类别 0 可用素材」
//      要能点名，只报个数等于把症状藏起来）。
//   S3 归一：类别名 = `normalizeCategoryName(raw)` = `trimmingCharacters(.whitespacesAndNewlines)`，
//      与 `ProjectViewModel.createProject()` 建项目时的 trim **同口径**（不引入第三种规范化：
//      不做大小写折叠、不做全半角折叠 —— 近名情况由 S4 出声，不自动并）。
//   S4 合并：trim 后同名的多个文件夹合成一个类别；`rawFolderNames` 按输入顺序全部留档，
//      供界面写「2 个文件夹归为 1 个类别：A、A␣」（D12 同名合并 + 第九节「归一同名必须出声」）。
//   S5 顺序：`categories` 顺序 = 各类别**首次出现**的输入顺序；类别内候选 = 文件夹输入顺序拼接。
//      不字典序、不按数量排 —— 顺序一旦由这里决定，用户排的序就失去意义（D1 的排列是输入）。
//   S6 空类别保留：`videoFileNames.isEmpty` 的类别照常出现在 `categories` 里（D13 标灰不阻断），
//      同时汇总进 `emptyCategories` 供界面直接取。
//   S8 provenance 与字节数随候选走（笔 4 懒入库的前提）：每条候选带着它出自哪个原始文件夹
//     （`videoFiles[i].folder`，判据 S4f）与它的盘上字节数 `videoFiles[i].byteSize` —— 后者由 IO 层的
//      `.fileSizeKey` 供给，读不出就是 nil，**不许当 0**：超软上限那句「还要占多少盘」的预估与
//      入库预检共用 `DiskSpaceBudget` 这一颗真源，喂 0 等于把预算判成免费（决定 6 的同一条口径）。
//
// 非空洞性论证（投影写错时哪条测试红）：
//   - 没做 trim                      → S3/S4 的「A」+「A␣」对照红（合成两个类别、merged 为空）
//   - 顺手做了大小写折叠             → S4b 的「Hook」+「hook」红（本卷不该自动并，该提示近名）
//   - 删掉空类别                     → S6 红（categories.count 少一）
//   - 按名字典序排                   → S5 红
//   - 非视频文件 continue 掉不留档    → S2 红（rejectedFileNames 空 + 计数对不上）
//   - 白名单漏 mkv/m4v               → S2c 红（这两条被当非视频丢进 rejected）
//   - 合并时只留首个文件夹名         → S4 的 rawFolderNames.count == 2 红
//   - 合并时不记候选的出处文件夹     → S4f 红（videoFolders 与候选不齐 ⇒ 调用方拼不出真实 URL）
// ============================================================================

/// 视频扩展名唯一真源。
///
/// 为什么需要它（修族不修点）：全仓原本有**两份**各自写死的白名单，且口径不一致 ——
/// 原先 `ImportView.swift:476`（`VideoFileFormat`，拖拽/选择过滤）与
/// `MixCutApp.swift:1144`（`VideoFileFormat`，旧库恢复扫描）各抄一份 `["mp4", "mov", "avi", "m4v", "mkv"]`，
/// 顺序还不一样。两处当年恰好等价，但没有任何东西阻止
/// 其中一处再加一种容器格式 ⇒ 同一个文件在导入页可选、在恢复扫描里看不见。
/// 本期新增第三个消费者（文件夹混剪），所以真源收进 Core，那两处同笔改为调用这里；
/// 守卫 `scripts/check_folder_mix_guards.sh` 的 G-i 数「扩展名字面量只许出现在本文件」。
public enum VideoFileFormat {

    /// 全仓唯一的一份视频扩展名白名单（小写、无点）。
    public static let videoExtensions: [String] = ["mp4", "mov", "avi", "m4v", "mkv"]

    private static let lookup: Set<String> = Set(videoExtensions)

    /// 文件名的扩展名（小写、无点）；无扩展名时返回 ""。
    /// 只认名字最后一个 `.` 之后的部分 —— 与 `NSString.pathExtension` 同口径，
    /// 因为被替换的两处旧写法就是用它（`url.pathExtension`）。
    public static func pathExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    /// 扩展名是否算视频。入参可以是 `"MP4"` 也可以带别的形态，只做小写归一。
    /// App 层那两处旧写法本来就是拿 `url.pathExtension` 直接比这里的清单，
    /// 所以这里收的是同一个口径 —— 迁移只换真源，不换判据。
    public static func isVideoExtension(_ ext: String) -> Bool {
        lookup.contains(ext.lowercased())
    }

    /// 是否算视频候选。**只看名字**：内容合法性由入库阶段的 ffprobe 读数决定，
    /// 不在这里猜（D8：混剪通路不跑分析）。
    public static func isVideoFileName(_ name: String) -> Bool {
        isVideoExtension(pathExtension(of: name))
    }
}

/// 一级目录里的一条文件读数（名字 + 盘上字节数）。
public struct FolderMixRawFile: Equatable, Sendable {
    public let name: String
    /// 字节数。nil = IO 层读不出（`.fileSizeKey` 偶发缺值 / 文件在扫描之间被移走）。
    /// **不许当 0**：0 会被 `DiskSpaceBudget` 当成免费额度，那正是决定 6 要在数据层堵住的那格。
    public let byteSize: Int64?

    public init(name: String, byteSize: Int64? = nil) {
        self.name = name
        self.byteSize = byteSize
    }
}

/// 一个一级子目录的输入投影。
public struct FolderMixRawDirectory: Equatable, Sendable {
    /// 磁盘上的文件夹名（**未** trim，出声归一合并时要用原文）
    public let rawName: String
    /// 该目录一级文件的清单（未过滤，非视频也在里面），按 IO 层给的位置序
    public let files: [FolderMixRawFile]

    public init(rawName: String, files: [FolderMixRawFile]) {
        self.rawName = rawName
        self.files = files
    }

    /// 只给名字的便利入口（测试与"字节数不参与本轮"的调用方）—— 走同一个存储形状，
    /// 不留第二种输入形态，否则"带 size 的那条路"永远没人测。
    public init(rawName: String, fileNames: [String]) {
        self.init(rawName: rawName, files: fileNames.map { FolderMixRawFile(name: $0) })
    }

    /// 名字清单（投影出来的只读视图，不是第二份存储）。
    public var fileNames: [String] { files.map(\.name) }
}

/// 一条候选视频：**文件夹 + 文件名 + 字节数**绑成一个值，而不是三列平行数组。
public struct FolderMixVideoFile: Equatable, Sendable {
    /// 出自哪个**原始**文件夹名（归一合并后重建真实 URL 的唯一依据）
    public let folder: String
    public let name: String
    /// 盘上字节数，nil = 读不出（口径同 `FolderMixRawFile.byteSize`）
    public let byteSize: Int64?

    public init(folder: String, name: String, byteSize: Int64? = nil) {
        self.folder = folder
        self.name = name
        self.byteSize = byteSize
    }
}

/// 一个类别（= trim 后同名文件夹的并集）。
public struct FolderMixCategory: Equatable, Sendable {
    /// trim 后的类别名，同时是建 Project 时用的名字（S3）
    public let name: String
    /// 归一到本类别的全部原始文件夹名，按输入顺序（S4）
    public let rawFolderNames: [String]
    /// 候选视频，按输入顺序（S5）；同名不同内容**不去重** —— 名字不是身份，身份是 `identityKey`。
    /// 存成「文件夹 + 名字 + 字节数」一条值，而不是三列平行数组：平行列靠 `precondition` 兜，
    /// 值列靠类型兜 —— 后者不可能漂，前者只要有人加第四列就重新暴露（笔 4 就是来加第四列的）。
    public let videoFiles: [FolderMixVideoFile]
    /// 被 S2 判掉的非视频文件名，逐名留档
    public let rejectedFileNames: [String]

    /// 候选文件名清单（只读视图）。为什么还留着：界面与测试都按名字断言，
    /// 而"出自哪个文件夹"这一维对它们无意义 —— 但存储里绝不存两份。
    public var videoFileNames: [String] { videoFiles.map(\.name) }
    /// 每条候选**来自哪个原始文件夹**（与 `videoFileNames` 同序同长，由同一条值保证）。
    /// 为什么必须留这一列：归一合并之后，"这个文件名出自哪个磁盘文件夹"是把名字重建成
    /// 真实 URL 的唯一办法，而合并规则只有 Core 这一份 —— 让调用方回目录里自己找，
    /// 等于把 S3/S4 的归一规则抄出第二份（那正是守卫 G-i 要防的形态）。
    public var videoFolders: [String] { videoFiles.map(\.folder) }
    /// 候选字节数，与 `videoFileNames` 同序；nil = IO 层读不出（不许当 0）。
    public var videoByteSizes: [Int64?] { videoFiles.map(\.byteSize) }

    public var isEmpty: Bool { videoFiles.isEmpty }

    /// 归一合并了两个以上文件夹时返回全部原名（界面据此出声），否则空数组。
    /// 单文件夹时不返回自己 —— 否则界面上每个类别都要挂一句无意义的"合并说明"。
    public var mergedFolderNames: [String] { rawFolderNames.count > 1 ? rawFolderNames : [] }

    public init(name: String, rawFolderNames: [String], videoFiles: [FolderMixVideoFile],
                rejectedFileNames: [String]) {
        self.name = name
        self.rawFolderNames = rawFolderNames
        self.videoFiles = videoFiles
        self.rejectedFileNames = rejectedFileNames
    }

    /// 不带字节数的旧入口（测试与只关心名字的调用方）。
    /// 两列不齐就**在构造处**响 —— 原来这个检查挂在 `videoPaths` 上，读取时才崩；
    /// 挪到构造处之后，坏形状根本活不到被读的那一刻。
    public init(name: String, rawFolderNames: [String], videoFileNames: [String],
                videoFolders: [String], rejectedFileNames: [String]) {
        precondition(videoFolders.count == videoFileNames.count,
                     "videoFolders 与 videoFileNames 长度不齐（\(videoFolders.count)/\(videoFileNames.count)）"
                     + "⇒ 投影被改坏，宁可崩也不要让候选指向错的文件")
        self.init(name: name, rawFolderNames: rawFolderNames,
                  videoFiles: zip(videoFolders, videoFileNames).map {
                      FolderMixVideoFile(folder: $0, name: $1)
                  },
                  rejectedFileNames: rejectedFileNames)
    }

    /// 候选的 (原始文件夹名, 文件名) 对 —— 调用方拼真实 URL 用的入口（要字节数就用 `videoFiles`）。
    public var videoPaths: [(folder: String, fileName: String)] {
        videoFiles.map { (folder: $0.folder, fileName: $0.name) }
    }
}

/// 扫描投影结果。
public struct FolderMixScanResult: Equatable, Sendable {
    public let categories: [FolderMixCategory]

    public var emptyCategories: [FolderMixCategory] { categories.filter { $0.isEmpty } }
    public var mergedCategories: [FolderMixCategory] {
        categories.filter { !$0.mergedFolderNames.isEmpty }
    }
    public var totalVideoFiles: Int { categories.reduce(0) { $0 + $1.videoFileNames.count } }
    public var totalRejectedFiles: Int { categories.reduce(0) { $0 + $1.rejectedFileNames.count } }

    public init(categories: [FolderMixCategory]) { self.categories = categories }
}

public enum FolderMixScanner {

    /// S3：类别名归一 —— 与 `createProject` 同一条 trim。
    /// 只此一种规范化；大小写折叠明确**不做**（本卷 HFS+ 不区分大小写，
    /// 而外接盘/解包可能出现 `Hook` 与 `hook`，那时按 D12 的近名提示处理，不自动并）。
    public static func normalizeCategoryName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一级子目录清单 → 类别投影（S1–S6）。
    public static func scan(_ directories: [FolderMixRawDirectory]) -> FolderMixScanResult {
        var order: [String] = []
        var buckets: [String: (rawFolderNames: [String], video: [FolderMixVideoFile],
                               rejected: [String])] = [:]

        for dir in directories {
            let key = normalizeCategoryName(dir.rawName)
            if buckets[key] == nil {
                order.append(key)              // S5：首次出现的输入顺序
                buckets[key] = ([], [], [])
            }
            var bucket = buckets[key]!
            bucket.rawFolderNames.append(dir.rawName)   // S4：全部原名留档
            for file in dir.files {
                if VideoFileFormat.isVideoFileName(file.name) {
                    // S5：不排序；provenance（哪个原始文件夹）与字节数跟着名字一起进同一条值
                    bucket.video.append(FolderMixVideoFile(folder: dir.rawName, name: file.name,
                                                           byteSize: file.byteSize))
                } else {
                    bucket.rejected.append(file.name)   // S2：不静默丢
                }
            }
            buckets[key] = bucket
        }

        return FolderMixScanResult(categories: order.map { key in
            let b = buckets[key]!
            return FolderMixCategory(name: key, rawFolderNames: b.rawFolderNames,
                                     videoFiles: b.video, rejectedFileNames: b.rejected)
        })
    }
}
