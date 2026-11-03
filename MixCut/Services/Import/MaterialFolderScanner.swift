import Foundation

// MARK: - 素材根目录扫描（文件夹混剪的唯一 IO 面）
//
// 计划真源：docs/superpowers/plans/2026-10-20-folder-mix-by-category.md（D1/D2、Step 4、第九节）
//
// 分工：这个 enum **只做盘上事实**（一层目录、一层文件、每个文件的字节数、哪些是替身、哪些读不了），
// 一切"算不算类别 / 算不算视频 / 要不要合并"的判定都在 Core 的 `FolderMixScanner` 里
// （守卫 G-c：判定不许出现在 IO 面，否则纯函数测不到）。
//
// 三条纪律，每条都对应第九节里一档已定型的失败形态：
//   ① **只扫一级**（D2）：子目录里再套的文件夹不进，只登记名字给用户看一眼。
//   ② **symlink / 替身目录整类拒绝并点名**：`contentsOfDirectory` 会把指向目录的替身
//      当子项返回，一个指向外部大库的替身就能让"只扫一级"变成无底洞，成环时更不能静默递归。
//   ③ **顺序必须稳定**：FileManager 的枚举顺序不保证，而混剪的抽取是"同 seed 同解"（R1）——
//      输入顺序一漂，用户点两次「换一换」就会看到与 seed 无关的抖动。这里按
//      `localizedStandardCompare`（Finder 的排序口径）排完再交给 Core。

/// 一个被拒的子目录（整类不参与混剪，但要能点名说明原因）。
struct MaterialFolderRejection: Equatable {
    let name: String
    let reason: String
}

/// 扫描结果（盘上事实的四份清单，判定留给 Core）。
struct MaterialFolderScan: Equatable {
    /// 正常参与的一级子目录，**直接就是 Core 的输入投影**（`FolderMixScanner.scan` 的入参），
    /// 中间不再造第二种形状 —— 多一层形状就多一处会漂移的翻译。
    var directories: [FolderMixRawDirectory] = []
    /// 被整类拒绝的子目录（替身 / 读不出来），逐名带原因
    var rejected: [MaterialFolderRejection] = []
    /// 一级子目录里再套的文件夹名（D2 不进，界面上给一句"未递归"的说明用）
    var nestedDirectoryNames: [String] = []
    /// 根目录本身就读不出来时的原因（nil = 根可读）
    var rootError: String?
}

enum MaterialFolderScanner {

    /// 扫一个素材根目录。`root` 由用户经面板/拖拽取得，故需要 security-scoped 访问；
    /// 这里自带 start/stop 配对，调用方不必（也不该）自己再套一层 —— 漏 stop 会泄漏句柄。
    ///
    /// 纯同步函数：不 await、不起任务。目录树再大也就两层枚举，放到主线程上是
    /// `importVideos` 那类交互入口的既有做法；真嫌慢再整体挪到 actor，别在这里半异步。
    static func scan(root: URL) -> MaterialFolderScan {
        var out = MaterialFolderScan()
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                      .fileSizeKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            out.rootError = "读不出目录内容（权限、外接盘被拔或路径已失效）：\(root.path)"
            MixLog.error("[FolderMix] 根目录读取失败：\(root.path)")
            return out
        }

        for child in children.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: Set(keys))

            // ② 替身目录：整类拒绝并点名。必须早于 isDirectory 判断 ——
            //   `resourceValues(.isDirectoryKey)` 对"指向目录的替身"报的是 **true**（跟随符号链接），
            //   先判目录就会把替身当成正常类别收进来，那正是"无底洞"的入口。
            if values?.isSymbolicLink == true {
                out.rejected.append(MaterialFolderRejection(
                    name: name, reason: "是替身/符号链接，未跟随（防止把外部大库或环当成一级子目录）"))
                continue
            }
            guard values?.isDirectory == true else { continue }   // 根目录下的散文件不属于任何类别

            var files: [FolderMixRawFile] = []
            var nested: [String] = []
            do {
                let items = try FileManager.default.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                for item in items.sorted(by: {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }) {
                    let itemValues = try? item.resourceValues(forKeys: Set(keys))
                    // ① 只扫一级：子目录登记名字，不进去
                    if itemValues?.isDirectory == true && itemValues?.isSymbolicLink != true {
                        nested.append(item.lastPathComponent)
                        continue
                    }
                    // 文件（含替身文件）按名字交给 Core 判扩展名；目录替身不算素材
                    if itemValues?.isSymbolicLink == true {
                        nested.append("\(item.lastPathComponent)（替身文件，已跳过）")
                        continue
                    }
                    // S8：字节数在这里一次取到（同一次 `resourceValues` 调用，不多开一趟盘）。
                    //     读不出留 nil —— Core 与预算都按"未知"处理，不替它编一个 0。
                    files.append(FolderMixRawFile(name: item.lastPathComponent,
                                                  byteSize: itemValues?.fileSize.map(Int64.init)))
                }
            } catch {
                out.rejected.append(MaterialFolderRejection(
                    name: name,
                    reason: "读不出该文件夹内容：\(FriendlyError.reason(for: error))"))
                continue
            }
            out.directories.append(FolderMixRawDirectory(rawName: name, files: files))
            out.nestedDirectoryNames.append(contentsOf: nested)
        }

        MixLog.info("[FolderMix] 扫描 \(root.lastPathComponent)：类别 \(out.directories.count)、"
                    + "拒绝 \(out.rejected.count)、未递归的子文件夹 \(out.nestedDirectoryNames.count)")
        return out
    }
}
