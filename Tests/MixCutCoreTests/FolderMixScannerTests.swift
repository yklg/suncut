import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MixCutCore

// ============================================================================
// FolderMixScanner / VideoFileFormat 判据（S1–S8）。
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md Step 1 + 笔 4（S8）
//
// 每条规则的夹具都配一个"实现写错时会红"的形状：
//   - 忘记 trim             → S3/S4
//   - 顺手大小写折叠        → S4c
//   - 删空类别              → S6
//   - 字典序重排            → S5
//   - 非视频静默 continue   → S2
//   - 白名单漏 mkv/m4v      → S2c
//   - 合并时只留首个文件夹名 → S4b
//   - 按文件名去重          → S4d（同名不同内容是两条候选，身份在 Step 4 的 hash 键）
//   - 字节数读不出折成 0     → S8 红（必须是 nil，0 会被磁盘预算当免费额度）
//   - 合并时字节数串位       → S8c 红（预算按错的素材算）
// ============================================================================

struct FolderMixScannerTests {

    private func dir(_ raw: String, _ files: String...) -> FolderMixRawDirectory {
        FolderMixRawDirectory(rawName: raw, fileNames: files)
    }

    // ── S2 / S2c：过滤必须逐名留档，白名单必须齐 ──

    @Test("S2 非视频文件不静默丢：逐名进 rejectedFileNames，且总数对账")
    func rejectedFilesAreNamedNotSwallowed() {
        let r = FolderMixScanner.scan([dir("钩子", "a.mp4", "notes.txt", "cover.jpg", "b.mov")])
        #expect(r.categories.count == 1)
        #expect(r.categories[0].videoFileNames == ["a.mp4", "b.mov"])
        #expect(r.categories[0].rejectedFileNames == ["notes.txt", "cover.jpg"])
        // 守恒：进来的每一个名字都必须在某一侧被记账（丢了就是"凭空消失"）
        #expect(r.totalVideoFiles + r.totalRejectedFiles == 4)
    }

    @Test("S2c 白名单五种容器全覆盖，大写扩展名与无扩展名各判其对")
    func extensionWhitelistIsComplete() {
        #expect(VideoFileFormat.videoExtensions == ["mp4", "mov", "avi", "m4v", "mkv"])
        for ext in VideoFileFormat.videoExtensions {
            #expect(VideoFileFormat.isVideoFileName("片.\(ext)"), "\(ext) 必须算视频")
            #expect(VideoFileFormat.isVideoFileName("片.\(ext.uppercased())"),
                    "\(ext) 的大写形态必须算视频")
        }
        // 白名单之外的一律不算（这几条是"白名单写宽了"的对照）
        for name in ["clip.webm", "clip.flv", "clip.wmv", "README", "cover.jpg", ".DS_Store"] {
            #expect(!VideoFileFormat.isVideoFileName(name), "\(name) 不该被当视频")
        }
    }

    @Test("S2d 白名单自身形状：小写、无点、无重复、无空串")
    func whitelistShapeIsWellFormed() {
        let exts = VideoFileFormat.videoExtensions
        #expect(Set(exts).count == exts.count, "重复项会让两处消费方看到不同长度")
        #expect(exts.allSatisfy { !$0.isEmpty && !$0.contains(".") && $0 == $0.lowercased() })
    }

    // ── S3 / S4：归一与合并 ──

    @Test("S3 类别名归一 = 与 createProject 同一条 trim（首尾空白与换行都去）")
    func normalizationIsTrimOnly() {
        #expect(FolderMixScanner.normalizeCategoryName("  钩子 ") == "钩子")
        #expect(FolderMixScanner.normalizeCategoryName("钩子\n") == "钩子")
        #expect(FolderMixScanner.normalizeCategoryName("钩 子") == "钩 子", "中间空格不是空白可去项")
        // 只做 trim：大小写、全半角都不折叠（折叠 = 引入第三种规范化，与 createProject 分家）
        #expect(FolderMixScanner.normalizeCategoryName("Hook") == "Hook")
    }

    @Test("S4 归一后同名的两个文件夹合成一个类别，视频按文件夹输入顺序拼接")
    func trimCollisionMergesIntoOneCategory() {
        let r = FolderMixScanner.scan([dir("A", "1.mp4"), dir("A ", "2.mp4")])
        #expect(r.categories.count == 1)
        #expect(r.categories[0].name == "A")
        #expect(r.categories[0].videoFileNames == ["1.mp4", "2.mp4"])
    }

    @Test("S4b 合并必须把全部原始文件夹名留档 —— 界面要能点名")
    func mergedFolderNamesAreAllKept() {
        let r = FolderMixScanner.scan([dir("A", "1.mp4"), dir("A ", "2.mp4"), dir("B", "3.mp4")])
        #expect(r.categories[0].rawFolderNames == ["A", "A "])
        #expect(r.categories[0].mergedFolderNames == ["A", "A "])
        // 单文件夹类别不产生"合并说明"（否则每个类别都挂一句无意义的话）
        #expect(r.categories[1].mergedFolderNames.isEmpty)
        #expect(r.mergedCategories.count == 1)
    }

    @Test("S4c 近名（仅大小写之差）不自动合并：两个类别 + 原始名各自保留")
    func caseNearCollisionsAreNotMerged() {
        let r = FolderMixScanner.scan([dir("Hook", "a.mp4"), dir("hook", "b.mp4")])
        #expect(r.categories.map(\.name) == ["Hook", "hook"])
        #expect(r.mergedCategories.isEmpty)
    }

    @Test("S4d 同名不同内容不在这里去重：身份是 Step 4 的 hash 键，不是文件名")
    func sameNameAcrossMergedFoldersStaysTwoCandidates() {
        let r = FolderMixScanner.scan([dir("A", "x.mp4"), dir("A ", "x.mp4")])
        #expect(r.categories[0].videoFileNames == ["x.mp4", "x.mp4"])
    }

    @Test("S4e 归一后名字为空（纯空格文件夹）也照常成为一个类别，不丢")
    func blankFolderNameNormalizesToEmptyAndIsKept() {
        let r = FolderMixScanner.scan([dir("   ", "a.mp4")])
        #expect(r.categories.count == 1)
        #expect(r.categories[0].name.isEmpty)
        #expect(r.categories[0].rawFolderNames == ["   "], "原名必须留档，否则界面说不出是哪个文件夹")
    }

    @Test("S4f 每条候选都带着它来自哪个原始文件夹 —— 合并后重建 URL 只能靠这一列")
    func provenanceSurvivesMerge() {
        let r = FolderMixScanner.scan([dir("A", "1.mp4", "x.txt"), dir("A ", "2.mp4")])
        let cat = r.categories[0]
        #expect(cat.videoFolders == ["A", "A "], "文件名与文件夹必须同序同长，否则 zip 会错位")
        #expect(cat.videoPaths.map(\.fileName) == cat.videoFileNames)
        #expect(cat.videoPaths.map(\.folder) == cat.videoFolders)
        // 非视频不占 provenance（它不进候选）
        #expect(cat.videoFileNames.count == cat.videoFolders.count)
        // 合并前后同一目录里的相对顺序不变
        #expect(cat.videoPaths.map { "\($0.folder)/\($0.fileName)" } == ["A/1.mp4", "A /2.mp4"])
    }

    // ── S5：顺序 ──

    @Test("S5 类别顺序 = 首次出现的输入顺序，候选顺序 = 输入顺序（两处都不许排序）")
    func orderIsInputOrderNotSorted() {
        let r = FolderMixScanner.scan([
            dir("信任背书", "b.mp4", "a.mp4"),
            dir("钩子", "z.mp4"),
        ])
        #expect(r.categories.map(\.name) == ["信任背书", "钩子"])
        #expect(r.categories[0].videoFileNames == ["b.mp4", "a.mp4"], "候选不许字典序重排")
    }

    // ── S6：空类别 ──

    @Test("S6 空类别保留（D13 标灰不阻断），并汇总进 emptyCategories")
    func emptyCategorySurvives() {
        let r = FolderMixScanner.scan([dir("只有图片", "a.jpg"), dir("钩子", "b.mp4"), dir("全空")])
        #expect(r.categories.map(\.name) == ["只有图片", "钩子", "全空"], "空类别不许从 categories 里消失")
        #expect(r.emptyCategories.map(\.name) == ["只有图片", "全空"])
        #expect(r.categories[0].videoFileNames.isEmpty)
        #expect(r.categories[0].rejectedFileNames == ["a.jpg"], "0 候选的类也要说清为什么是 0")
    }

    @Test("S6b 全空输入：零类别零计数，不崩")
    func emptyInputIsNotAnError() {
        let r = FolderMixScanner.scan([])
        #expect(r.categories.isEmpty)
        #expect(r.totalVideoFiles == 0)
        #expect(r.totalRejectedFiles == 0)
        #expect(r.emptyCategories.isEmpty)
    }

    @Test("S6c 某类候选全被去重后为空 —— 空类的判定与报告只有一条口径")
    func allRejectedLeavesCategoryEmptyNotAbsent() {
        let r = FolderMixScanner.scan([dir("素材", "a.txt", "b.bin")])
        #expect(r.categories.count == 1)
        #expect(r.emptyCategories.count == 1)
        #expect(r.totalVideoFiles == 0)
        #expect(r.totalRejectedFiles == 2)
    }

    // ── 组合形态：合并 + 空类 + 顺序同时出现 ──

    @Test("S1–S6 同轮生效：三文件夹两类别（其中一次归一合并、一次全空）")
    func combinedShape() {
        let r = FolderMixScanner.scan([
            dir("爆点2", "p1.mp4", "p2.mkv", "p3.webm"),
            dir("爆点2 ", "p4.MOV"),
            dir("空类"),
        ])
        #expect(r.categories.map(\.name) == ["爆点2", "空类"])
        let boom = r.categories[0]
        #expect(boom.videoFileNames == ["p1.mp4", "p2.mkv", "p4.MOV"])
        #expect(boom.rejectedFileNames == ["p3.webm"])
        #expect(boom.mergedFolderNames == ["爆点2", "爆点2 "])
        #expect(r.totalVideoFiles == 3)
        #expect(r.totalRejectedFiles == 1)
    }

    @Test("S5b 输入顺序不被 Set 化：类别名重复出现只产生一条记录")
    func noPhantomCategories() {
        let r = FolderMixScanner.scan([dir("A", "1.mp4"), dir("A"), dir("A ", "2.mp4")])
        #expect(r.categories.count == 1)
        #expect(r.categories[0].rawFolderNames == ["A", "A", "A "])
        #expect(r.categories[0].videoFileNames == ["1.mp4", "2.mp4"])
    }

    // ── 口径对账：App 层 `ImportViewModel.supportedTypes` 现在由这份白名单派生 ──

    @Test("S7 每个扩展名都解析得出 UTType（supportedTypes 派生式的前提，`if let` 不许静默丢项）")
    func everyExtensionResolvesToAContentType() {
        // 这条不测 App 层那行代码本身（swift test 只编 Core），测的是它成立所依赖的那个前提：
        // 若哪天 `UTType(filenameExtension: "mkv")` 在这台系统上解析不出来，
        // 派生式会把它从放行器里**静默丢掉** ⇒ 又回到"白名单收、放行器不收"的老缺陷。
        for ext in VideoFileFormat.videoExtensions {
            let type = UTType(filenameExtension: ext)
            #expect(type != nil, "\(ext) 解析不出 UTType ⇒ 派生式会静默少一项，必须换写法")
        }
        // 父型必须还在：放行器靠它兜住动态类型之外的容器
        #expect(UTType.movie.identifier == "public.movie")
    }

    @Test("S7b m4v / mkv 这两颗历史上被放行器漏掉的扩展名，解析结果要能对上账")
    func previouslyMissingExtensionsResolve() {
        // 旧写法只列 [.movie, .mpeg4Movie, .quickTimeMovie, .avi] ⇒ m4v/mkv 全靠父型碰运气
        #expect(UTType(filenameExtension: "m4v") != nil)
        #expect(UTType(filenameExtension: "mkv") != nil)
        #expect(UTType(filenameExtension: "m4v")?.conforms(to: .movie) == true,
                "不 conform 到 .movie 就意味着派生式里那颗具体类型是承重的，不许删")
    }

    // ── S8（笔 4 懒入库）：字节数随候选走，读不出是 nil 不是 0 ──

    @Test("S8 候选是一条「文件夹 + 名字 + 字节数」的值，不是三列平行数组")
    func byteSizeTravelsWithTheCandidate() {
        let files = [FolderMixRawFile(name: "a.mp4", byteSize: 1_000),
                     FolderMixRawFile(name: "notes.txt", byteSize: 7),
                     FolderMixRawFile(name: "b.mov", byteSize: nil)]
        let r = FolderMixScanner.scan([FolderMixRawDirectory(rawName: "钩子", files: files)])
        let cat = r.categories[0]
        #expect(cat.videoFileNames == ["a.mp4", "b.mov"])
        #expect(cat.videoByteSizes == [1_000, nil], "读不出的那条必须是 nil —— 折成 0 就被磁盘预算当免费额度")
        // provenance 与字节数同源于一条值 ⇒ "两列不齐"这种错法在形状上已经不可表示
        // （旧形状靠 `precondition` 在读取时兜，现在挪到构造时，见 S8c）
        #expect(cat.videoFiles.map { "\($0.folder)/\($0.name)" } == ["钩子/a.mp4", "钩子/b.mov"])
        #expect(cat.rejectedFileNames == ["notes.txt"])
        #expect(r.totalVideoFiles == 2)
    }

    @Test("S8b 只给名字的旧入口仍可用：字节数一律未知，不是 0")
    func nameOnlyInputLeavesSizeUnknown() {
        let cat = FolderMixScanner.scan([dir("A", "a.mp4")]).categories[0]
        #expect(cat.videoByteSizes == [nil])
        #expect(cat.videoFiles[0].byteSize == nil)
    }

    @Test("S8c 归一合并的类别里，每条候选各带自己的出处与大小，顺序不混")
    func mergedCategoryKeepsPerFileProvenanceAndSize() {
        let r = FolderMixScanner.scan([
            FolderMixRawDirectory(rawName: "A", files: [FolderMixRawFile(name: "1.mp4", byteSize: 11)]),
            FolderMixRawDirectory(rawName: "A ", files: [FolderMixRawFile(name: "2.mp4", byteSize: 22)]),
        ])
        let cat = r.categories[0]
        #expect(cat.rawFolderNames == ["A", "A "])
        #expect(cat.videoFolders == ["A", "A "])
        #expect(cat.videoByteSizes == [11, 22], "合并时把大小串位 = 预算按错的素材算")
        #expect(cat.videoFiles.map(\.name) == ["1.mp4", "2.mp4"])
    }
}
