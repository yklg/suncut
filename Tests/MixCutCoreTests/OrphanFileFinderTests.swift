import Testing
@testable import MixCutCore

@Test func orphan_returnsFilesNotReferenced() {
    let onDisk = ["/v/a.mp4", "/v/b.mp4", "/t/x.jpg"]
    let referenced: Set<String> = ["/v/a.mp4", "/t/x.jpg"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4"])
}

@Test func orphan_emptyWhenAllReferenced() {
    let onDisk = ["/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: ["/v/a.mp4"]).isEmpty)
}

@Test func orphan_normalizesTrailingSlashAndCase() {
    // 末尾斜杠 + 大小写差异应视为同一路径（macOS 默认大小写不敏感）
    let onDisk = ["/V/A.mp4/"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: referenced).isEmpty)
}

@Test func orphan_allUnreferencedReturnedInInputOrder() {
    let onDisk = ["/v/b.mp4", "/v/a.mp4"]
    #expect(OrphanFileFinder.orphanFiles(onDisk: onDisk, referenced: []) == ["/v/b.mp4", "/v/a.mp4"])
}

// MARK: - safeOrphanFiles：破坏性回收的保守入口
// 上面那条是 orphanFiles（纯查询）的既有契约，保持不变；
// 下面几条守的是「GC 何时不该动手」。

@Test func safeOrphan_refusesWhenReferencedEmpty() {
    // 库打不开 / 退到内存模式时，引用集会是空的 —— 此时全删不可逆
    let onDisk = ["/v/a.mp4", "/t/x.jpg"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: []).isEmpty)
}

@Test func safeOrphan_refusesWhenZeroOverlap() {
    // 目录迁移改名的现场：DB 里 34 个路径仍指旧前缀，磁盘已在新目录 → 零交集
    let onDisk = ["/new/Videos/a.mp4", "/new/Thumbnails/x.jpg"]
    let referenced: Set<String> = ["/old/Videos/a.mp4", "/old/Thumbnails/x.jpg"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced).isEmpty)
}

@Test func safeOrphan_stillReclaimsWhenReferenceSetIsTrustworthy() {
    // 反向防线：有交集时照常给出孤儿，不能退化成「永远返回空」的假守卫
    let onDisk = ["/v/a.mp4", "/v/b.mp4", "/v/c.mp4"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4", "/v/c.mp4"])
}

@Test func safeOrphan_overlapCheckHonoursNormalization() {
    // 交集判定必须与 orphanFiles 用同一套归一（大小写 + 末尾斜杠），否则会误判成零交集
    let onDisk = ["/V/A.mp4/", "/v/b.mp4"]
    let referenced: Set<String> = ["/v/a.mp4"]
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: onDisk, referenced: referenced) == ["/v/b.mp4"])
}

@Test func safeOrphan_emptyOnDiskYieldsEmpty() {
    #expect(OrphanFileFinder.safeOrphanFiles(onDisk: [], referenced: ["/v/a.mp4"]).isEmpty)
}
