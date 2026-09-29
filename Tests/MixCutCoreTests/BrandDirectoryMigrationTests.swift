import Foundation
import Testing
@testable import MixCutCore

/// 迁移决策层的用例一律用**中性合成名**（OldName/NewName），不写真实品牌值：
/// 这段逻辑必须与品牌无关，把真名钉进测试反而会让阶段 4 翻值时误红。
/// "当前值确实是 MixCut" 由 `BrandIdentityTests` 与假 home 演练负责。

private func planned(_ entries: [String], old: String = "OldName", new: String = "NewName",
                     legacyStore: String = "OldName.store", store: String = "NewName.store")
    -> BrandDirectoryMigration.Plan {
    BrandDirectoryMigration.plan(oldDirectoryName: old, newDirectoryName: new,
                                 legacyStoreFileName: legacyStore, storeFileName: store, entries: entries)
}

@Test("目录名和库名都没变 ⇒ 空计划（阶段 3 尚未翻值时的空转就该落在这里）")
func planIsEmptyWhenNothingChanged() {
    let r = planned(["Videos", "OldName.store", "OldName.store-wal", "backup-x"],
                    old: "OldName", new: "OldName", legacyStore: "OldName.store", store: "OldName.store")
    #expect(r.moves.isEmpty)
    #expect(r.keepBehind.isEmpty)
}

@Test("只换目录名、库名不动 ⇒ 每项同名搬，含库文件本体")
func planMovesSameNamedEntries() {
    let r = planned(["Videos", "Thumbnails", "OldName.store"], store: "OldName.store")
    #expect(r.moves == [
        DirectoryMove(fromName: "OldName.store", toName: "OldName.store"),
        DirectoryMove(fromName: "Thumbnails", toName: "Thumbnails"),
        DirectoryMove(fromName: "Videos", toName: "Videos"),
    ])
}

@Test("目录名和库名都换 ⇒ store 三件套改名，其余同名搬")
func planRenamesStoreTriple() {
    let r = planned(["OldName.store", "OldName.store-wal", "OldName.store-shm", "Videos"])
    #expect(r.moves.contains(DirectoryMove(fromName: "OldName.store", toName: "NewName.store")))
    #expect(r.moves.contains(DirectoryMove(fromName: "OldName.store-wal", toName: "NewName.store-wal")))
    #expect(r.moves.contains(DirectoryMove(fromName: "OldName.store-shm", toName: "NewName.store-shm")))
    #expect(r.moves.contains(DirectoryMove(fromName: "Videos", toName: "Videos")))
    #expect(r.moves.count == 4)
}

@Test("只换库名不换目录名 ⇒ 只有 store 相关条目需要改名")
func planRenamesStoreInsideSameDirectory() {
    let r = planned(["Videos", "BGM", "OldName.store", "OldName.store-wal"], old: "OldName", new: "OldName")
    #expect(r.moves == [
        DirectoryMove(fromName: "OldName.store", toName: "NewName.store"),
        DirectoryMove(fromName: "OldName.store-wal", toName: "NewName.store-wal"),
    ])
}

@Test("backup- 前缀留在旧目录，既不搬也不丢")
func planKeepsBackupsBehind() {
    let r = planned(["backup-20260928T105625Z", "Videos", "whisper-models"])
    #expect(r.keepBehind == ["backup-20260928T105625Z"])
    #expect(r.moves == [
        DirectoryMove(fromName: "Videos", toName: "Videos"),
        DirectoryMove(fromName: "whisper-models", toName: "whisper-models"),
    ])
}

@Test("不认识的 store 派生名不许瞎改名")
func planDoesNotInventRenames() {
    let r = planned(["OldName.store-journal", "OldName.stores"])
    #expect(r.moves == [
        DirectoryMove(fromName: "OldName.store-journal", toName: "OldName.store-journal"),
        DirectoryMove(fromName: "OldName.stores", toName: "OldName.stores"),
    ])
}

@Test("清单排序后给出，执行顺序不依赖磁盘返回顺序")
func planIsSortedIndependentlyOfInputOrder() {
    let a = planned(["Videos", "Thumbnails", "Dubs"])
    let b = planned(["Dubs", "Thumbnails", "Videos"])
    #expect(a.moves == b.moves)
    #expect(a.moves.first?.fromName == "Dubs")
}

@Test("空目录 ⇒ 空计划")
func planOnEmptyEntries() {
    let r = planned([])
    #expect(r.moves.isEmpty)
    #expect(r.keepBehind.isEmpty)
}

@Test("命中前缀才改写；不命中的值一律返回 nil 表示不动")
func rewriteOnlyOnPrefixMatch() {
    let oldP = "/u/Library/Application Support/OldName"
    let newP = "/u/Library/Application Support/NewName"

    #expect(StoredPathPrefixRewriter.rewrite("\(oldP)/Videos/a.mp4", from: oldP, to: newP)
            == "\(newP)/Videos/a.mp4")
    // 已经在新目录下的值：不该再动，重复调用因此幂等
    #expect(StoredPathPrefixRewriter.rewrite("\(newP)/Videos/a.mp4", from: oldP, to: newP) == nil)
    // 只是路径中段含有旧目录名，不是我们的数据根
    #expect(StoredPathPrefixRewriter.rewrite("/other/OldName/Videos/a.mp4", from: oldP, to: newP) == nil)
    // 前缀后没有斜杠分隔 ⇒ 不算命中（防 /…/OldNameBackup 被改成 /…/NewNameBackup）
    #expect(StoredPathPrefixRewriter.rewrite("\(oldP)Backup/x", from: oldP, to: newP) == nil)
    // 存的是目录本身而非其下的文件
    #expect(StoredPathPrefixRewriter.rewrite(oldP, from: oldP, to: newP) == nil)
    // 新旧前缀相同 ⇒ 不动，不做无意义写入
    #expect(StoredPathPrefixRewriter.rewrite("\(oldP)/Videos/a.mp4", from: oldP, to: oldP) == nil)
}

@Test("改写只换前缀，后半段逐字保留（含空格与中文）")
func rewritePreservesRemainder() {
    let oldP = "/u/Library/Application Support/OldName"
    let newP = "/u/Library/Application Support/NewName"
    let value = "\(oldP)/Thumbnails/项目 1/中 段#3.jpg"
    #expect(StoredPathPrefixRewriter.rewrite(value, from: oldP, to: newP)
            == "\(newP)/Thumbnails/项目 1/中 段#3.jpg")
}

// MARK: - 执行器：真跑在临时目录上

private typealias Fixture = (root: URL, old: URL, new: URL)

/// 每个用例一套独立临时目录，避免用例之间互相看见。
private func makeFixture() -> Fixture {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("BrandMigration-\(UUID().uuidString)", isDirectory: true)
    let old = root.appendingPathComponent("OldName", isDirectory: true)
    let new = root.appendingPathComponent("NewName", isDirectory: true)
    try? fm.createDirectory(at: old, withIntermediateDirectories: true)
    try? fm.createDirectory(at: new, withIntermediateDirectories: true)
    return (root, old, new)
}

private func seed(_ fixture: Fixture, _ name: String, _ contents: String = "payload") {
    let url = fixture.old.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.data(using: .utf8)?.write(to: url)
}

private func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? "<缺失>"
}

@Test("执行把文件和整棵子树搬过去，内容逐字不变")
func executeMovesFilesAndSubtrees() {
    let f = makeFixture()
    seed(f, "Videos/abc/movie.mp4", "视频内容")
    seed(f, "Thumbnails/t1.jpg", "缩略图")

    let plan = planned(["Videos", "Thumbnails"])
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .done(moved: 2))

    #expect(read(f.new.appendingPathComponent("Videos/abc/movie.mp4")) == "视频内容")
    #expect(read(f.new.appendingPathComponent("Thumbnails/t1.jpg")) == "缩略图")
    #expect(!FileManager.default.fileExists(atPath: f.old.appendingPathComponent("Videos").path))
}

@Test("执行真的把库三件套改名，而不只是搬走")
func executeRenamesStoreTriple() {
    let f = makeFixture()
    seed(f, "OldName.store", "库本体")
    seed(f, "OldName.store-wal", "预写日志")

    let plan = planned(["OldName.store", "OldName.store-wal"])
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .done(moved: 2))

    #expect(read(f.new.appendingPathComponent("NewName.store")) == "库本体")
    #expect(read(f.new.appendingPathComponent("NewName.store-wal")) == "预写日志")
}

@Test("重复执行是空的：源已被搬走 ⇒ done(moved: 0)，不会把新家再搬一遍")
func executeIsIdempotent() {
    let f = makeFixture()
    seed(f, "Videos/a.mp4", "第一次")
    let plan = planned(["Videos"])
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .done(moved: 1))
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .done(moved: 0))
    #expect(read(f.new.appendingPathComponent("Videos/a.mp4")) == "第一次")
}

@Test("新旧两处同名 ⇒ 停在 collision，两边内容都不许被动")
func executeStopsOnCollision() throws {
    let f = makeFixture()
    seed(f, "Videos/a.mp4", "旧家那份")
    // 新家已经有同名目录（上一轮搬了一半、或新库已在用）
    let keeper = f.new.appendingPathComponent("Videos/keep.txt")
    try FileManager.default.createDirectory(at: keeper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "新家那份".write(to: keeper, atomically: true, encoding: .utf8)
    // 先自证夹具真的成立，否则这条用例会静默测成"没有冲突"
    #expect(FileManager.default.fileExists(atPath: keeper.path))

    let plan = planned(["Videos"])
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .collision(name: "Videos"))
    #expect(read(f.old.appendingPathComponent("Videos/a.mp4")) == "旧家那份")
    #expect(read(keeper) == "新家那份")
}

@Test("backup- 前缀留在旧目录，执行完还在原地")
func executeLeavesBackupsBehind() {
    let f = makeFixture()
    seed(f, "backup-20260928T105625Z/OldName.store", "回退料")
    seed(f, "Videos/a.mp4", "在用素材")

    let plan = planned(["backup-20260928T105625Z", "Videos"])
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .done(moved: 1))
    #expect(read(f.old.appendingPathComponent("backup-20260928T105625Z/OldName.store")) == "回退料")
    #expect(!FileManager.default.fileExists(
        atPath: f.new.appendingPathComponent("backup-20260928T105625Z").path))
}

@Test("清单里有、磁盘上已经没有的条目 ⇒ 跳过而不是报错")
func executeSkipsMissingSources() {
    let f = makeFixture()
    seed(f, "Videos/a.mp4")
    let plan = planned(["Videos", "Thumbnails"])       // Thumbnails 从未落地
    #expect(BrandDirectoryMigration.execute(plan, oldDirectory: f.old, newDirectory: f.new) == .done(moved: 1))
}

// MARK: - 跨域设置导入的放行面

@Test("两个迁移标志与孤儿键不许跨域继承，其余用户键全放行")
func importFilterDropsMarkersAndOrphanKey() {
    let stored: Set<String> = [
        "hasCompletedOnboarding", "lastOrphanGCAt", "api_key_deepseek", "lastSelectedProjectID",
        LegacySettingsImport.migratedToKey, LegacySettingsImport.importedFromKey, "dismissedUpdateVersion",
    ]
    #expect(LegacySettingsImport.keysToImport(stored) == [
        "hasCompletedOnboarding", "lastOrphanGCAt", "api_key_deepseek", "lastSelectedProjectID",
    ])
}

@Test("空集合过滤后仍为空（旧域没存过任何东西时不报错）")
func importFilterOnEmptySetYieldsEmpty() {
    #expect(LegacySettingsImport.keysToImport([]).isEmpty)
}
