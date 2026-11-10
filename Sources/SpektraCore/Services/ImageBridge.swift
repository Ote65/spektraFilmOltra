import Foundation
import CoreGraphics
import ImageIO

/// ImageRGB → 8-bit sRGB CGImage，仅用于屏幕显示。
/// 桌面 `PreviewRenderer.nsImage` 与 iOS 侧的 `UIImage` 都走这里，保证两端像素一致。
enum ImageBridge {
    static func cgImage(from image: ImageRGB) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, image.data.count == width * height * 3 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                let raw = image.data[i * 3 + c]
                let value = raw.isFinite ? min(max(raw, 0), 1) : 0
                pixels[i * 4 + c] = UInt8((value * 255).rounded())
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    /// 按文件加载屏幕显示图（缩略图、原片对比）。
    static func cgImage(contentsOf url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
