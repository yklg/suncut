import Foundation
import Testing
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SunCut

@Suite("LogoOverlay · 资源库与面板状态", .serialized)
struct LogoOverlayAssetStoreTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logo-asset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(to url: URL, width: Int, height: Int, alpha: Bool,
                          fill: CGRect, color: CGColor) throws {
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: alphaInfo.rawValue) else {
            throw LogoOverlayAssetError.encodeFailed
        }
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        ctx.setFillColor(color)
        ctx.fill(fill)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LogoOverlayAssetError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw LogoOverlayAssetError.encodeFailed }
    }

    @Test("透明边被裁掉：10×10 透明底 + 6×6 红块 ⇒ 入库 6×6；同图两次只落一个哈希")
    func trimsAndDedupes() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trim.png")
        try writePNG(to: url, width: 10, height: 10, alpha: true,
                     fill: CGRect(x: 2, y: 2, width: 6, height: 6),
                     color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))

        let first = try LogoOverlayAssetStore.importPNG(from: url)
        let second = try LogoOverlayAssetStore.importPNG(from: url)
        #expect(first.pixelWidth == 6 && first.pixelHeight == 6)
        #expect(first.warning == nil)
        #expect(first.file == second.file, "同一张图两次导入必须落到同一个哈希文件")

        guard let libURL = LogoOverlayAssetStore.url(for: first.file) else {
            Issue.record("入库文件名不合法：\(first.file)"); return
        }
        let sameHashFiles = (try? FileManager.default.contentsOfDirectory(
            atPath: FileHelper.logoLibraryDirectory.path))?.filter { $0 == first.file } ?? []
        #expect(FileManager.default.fileExists(atPath: libURL.path))
        #expect(sameHashFiles.count == 1)
        let size = LogoOverlayAssetStore.pixelSize(file: first.file)
        #expect(size?.width == 6 && size?.height == 6)
    }

    @Test("无 alpha 的图入库给出人话警告，不静默")
    func opaqueImageWarns() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opaque.png")
        try writePNG(to: url, width: 4, height: 4, alpha: false,
                     fill: CGRect(x: 0, y: 0, width: 4, height: 4),
                     color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let result = try LogoOverlayAssetStore.importPNG(from: url)
        #expect(result.pixelWidth == 4 && result.pixelHeight == 4)
        #expect(result.warning != nil)
    }

    @Test("K 预设只改宽度/边距，保留已选文件；清除只摘层")
    @MainActor
    func kPresetPreservesFilesAndClearRemovesLayer() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logoURL = dir.appendingPathComponent("logo.png")
        try writePNG(to: logoURL, width: 10, height: 10, alpha: true,
                     fill: CGRect(x: 2, y: 2, width: 6, height: 6),
                     color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))

        let vm = LogoOverlayViewModel()
        let project = Project(name: "logo-vm-test")
        vm.load(project: project)
        try vm.importImage(logoURL, into: .topLeft)
        #expect(vm.layer(for: .topLeft) != nil)
        let file = vm.layer(for: .topLeft)?.file

        vm.applyKPreset()
        #expect(vm.layer(for: .topLeft)?.file == file, "套用 K 档不能清空已选文件")
        #expect(vm.layer(for: .topLeft)?.widthPct == LogoOverlayPresets.kTopWidth)
        #expect(vm.config.rightMarginPct == LogoOverlayPresets.kRightMarginPct)
        #expect(vm.config.bottomMarginPct == LogoOverlayPresets.kBottomMarginPct)

        vm.clear(.topLeft)
        #expect(vm.layer(for: .topLeft) == nil)
    }

    @Test("开启但零图层 ⇒ preflight 拦住；关闭 ⇒ 不拦")
    @MainActor
    func preflightBlocksEmptyEnabledConfig() {
        let vm = LogoOverlayViewModel()
        let project = Project(name: "logo-preflight-test")
        vm.load(project: project)
        #expect(vm.preflightProblem() == nil)

        vm.setEnabled(true)
        #expect(vm.preflightProblem() != nil)
        #expect(!vm.isReadyForExport)

        vm.setEnabled(false)
        #expect(vm.preflightProblem() == nil)
        #expect(vm.isReadyForExport)
    }
}
