import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct LogoOverlayImportResult: Sendable {
    let file: String
    let pixelWidth: Int
    let pixelHeight: Int
    let warning: String?
}

enum LogoOverlayAssetError: LocalizedError {
    case unreadable(String)
    case fullyTransparent
    case encodeFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "「\(name)」不是可解码的 PNG，或文件已损坏"
        case .fullyTransparent:
            return "这张图完全没有可见像素（全透明），无法作为角标"
        case .encodeFailed:
            return "裁边后的 PNG 编码失败"
        case .writeFailed(let reason):
            return "写入 logo 库失败：\(reason)"
        }
    }
}

/// 全局 logo 库：裁透明边 → PNG 编码 → 内容哈希命名 → 原子写。
/// 文件名是裁后字节的哈希 ⇒ 同一张图重复导入只落一份，跨项目复用同一条引用。
enum LogoOverlayAssetStore {

    static func url(for file: String) -> URL? {
        guard LogoOverlayConfig.isSafeFileName(file) else { return nil }
        return FileHelper.logoLibraryDirectory.appendingPathComponent(file)
    }

    static func pixelSize(file: String) -> (width: Int, height: Int)? {
        guard let url = url(for: file),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    static func nsImage(file: String) -> NSImage? {
        guard let url = url(for: file) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func importPNG(from url: URL) throws -> LogoOverlayImportResult {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else {
            throw LogoOverlayAssetError.unreadable(url.lastPathComponent)
        }

        let hasAlpha = Self.hasAlpha(image)
        let warning: String? = hasAlpha ? nil : "「\(url.lastPathComponent)」没有透明通道，叠加后会盖住一块方框；建议换透明底 PNG"

        let trimmed: CGImage
        if hasAlpha {
            guard let bbox = alphaBoundingBox(image) else {
                throw LogoOverlayAssetError.fullyTransparent
            }
            guard let crop = image.cropping(to: CGRect(x: bbox.x, y: bbox.y,
                                                       width: bbox.width, height: bbox.height)) else {
                throw LogoOverlayAssetError.encodeFailed
            }
            trimmed = crop
        } else {
            trimmed = image
        }

        guard let png = encodePNG(trimmed) else {
            throw LogoOverlayAssetError.encodeFailed
        }
        let digest = SHA256.hash(data: png)
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let file = "logo-\(hex).png"
        let dest = FileHelper.logoLibraryDirectory.appendingPathComponent(file)
        do {
            // 哈希同名即同内容；原子覆盖比"先问存在再写"少一处裸问文件站点。
            try png.write(to: dest, options: .atomic)
        } catch {
            throw LogoOverlayAssetError.writeFailed(error.localizedDescription)
        }
        return LogoOverlayImportResult(file: file,
                                       pixelWidth: trimmed.width,
                                       pixelHeight: trimmed.height,
                                       warning: warning)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            return true
        default:
            return false
        }
    }

    /// CGContext 的位图缓冲第 0 行是画面顶行（2026-10-23 实测），
    /// 与 `CGImage.cropping(to:)` 的 y=0 同一朝向，不需要翻转。
    private static func alphaBoundingBox(_ image: CGImage) -> PixelRect? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return AlphaBounds.boundingBox(width: w, height: h, rgba: bytes)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
