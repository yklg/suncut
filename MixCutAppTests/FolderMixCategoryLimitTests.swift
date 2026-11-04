import Foundation
import SwiftData
import Testing
@testable import SunCut

// ============================================================================
// FMX-19 · 类别数硬上限 24（与 D15 900×600 版面绑定）
//
// 为什么是 App 腿：上限的判据在 `FolderMixLimits`（Core），但「扫描结果有没有
// 真的被拦在视图外」发生在 `FolderMixViewModel.beginScan`。只测常量会漏掉
// 「扫描到了 25 类、界面仍把 25 行塞进 600pt」这条失败面。
//
// 台架：空类别 + 一个非视频文件；不跑时长/校验和探针，也不写用户目录。
// `beginScan` 会 persist 会话，测试前后把 `folderMix.session.v1` 原样还原。
// ============================================================================

private func capRoot(_ count: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fmx19-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for i in 0..<count {
        let category = root.appendingPathComponent(String(format: "类别%02d", i), isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        // 非视频文件：类别保留，但候选为空，因此不会启动 ffprobe 探针。
        try Data([0x5A]).write(to: category.appendingPathComponent("说明.txt"))
    }
    return root
}

private func capContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: AppSchemaV1.self)
    return try ModelContainer(for: schema, configurations: [
        ModelConfiguration(isStoredInMemoryOnly: true)
    ])
}

@MainActor
private func withRestoredSession<T>(_ body: () throws -> T) rethrows -> T {
    let defaults = UserDefaults.standard
    let key = FolderMixViewModel.sessionDefaultsKey
    let old = defaults.data(forKey: key)
    defer {
        if let old {
            defaults.set(old, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
    return try body()
}

@Test("FMX-19a 24 个类别可以进入视图")
@MainActor
func twentyFourCategoriesAreAccepted() throws {
    let root = try capRoot(24)
    defer { try? FileManager.default.removeItem(at: root) }
    try withRestoredSession {
        let container = try capContainer()
        let vm = FolderMixViewModel()
        vm.beginScan(root: root, context: container.mainContext)
        #expect(vm.categoryLimitError == nil)
        #expect(vm.orderedCategories.count == 24)
        #expect(vm.scan != nil)
    }
}

@Test("FMX-19b 25 个类别被硬拦，视图不拿 25 行")
@MainActor
func twentyFiveCategoriesAreRejected() throws {
    let root = try capRoot(25)
    defer { try? FileManager.default.removeItem(at: root) }
    try withRestoredSession {
        let container = try capContainer()
        let vm = FolderMixViewModel()
        vm.beginScan(root: root, context: container.mainContext)
        #expect(vm.categoryLimitError != nil)
        #expect(vm.orderedCategories.isEmpty)
        #expect(vm.scan == nil)
        #expect(vm.candidatesByCategory.isEmpty)
    }
}
