import SwiftUI
import CoreGraphics

#if os(macOS)
import AppKit
typealias MPlatformImage = NSImage
#else
import UIKit
typealias MPlatformImage = UIImage
#endif

/// 屏幕显示图的跨平台入口：所有像素都从核心 `ImageBridge` 来。
enum MImage {
    static func make(cgImage: CGImage) -> MPlatformImage {
        #if os(macOS)
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    static func make(_ image: ImageRGB) -> MPlatformImage? {
        guard let cgImage = ImageBridge.cgImage(from: image) else { return nil }
        return make(cgImage: cgImage)
    }

    static func swiftUI(_ image: MPlatformImage) -> Image {
        #if os(macOS)
        return Image(nsImage: image)
        #else
        return Image(uiImage: image)
        #endif
    }

    static func load(url: URL) -> MPlatformImage? {
        guard let cgImage = ImageBridge.cgImage(contentsOf: url) else { return nil }
        return make(cgImage: cgImage)
    }

    static func thumbnail(url: URL) -> MPlatformImage? {
        MThumbnailCache.shared.image(for: url)
    }
}

/// 缩略图缓存：同一张缩略图在滚动列表里反复出现，避免每次重建。
final class MThumbnailCache {
    static let shared = MThumbnailCache()

    private let cache = NSCache<NSString, MPlatformImage>()
    private let lock = NSLock()

    init() {
        cache.countLimit = 240
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) -> MPlatformImage? {
        if let hit = cachedImage(for: url) { return hit }
        guard let image = MImage.load(url: url) else { return nil }
        lock.lock()
        cache.setObject(image, forKey: url.path as NSString, cost: 512 * 512 * 4)
        lock.unlock()
        return image
    }

    /// 只查缓存，不触发读盘：供视图在异步加载前判断是否已有可用图。
    func cachedImage(for url: URL) -> MPlatformImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: url.path as NSString)
    }

    func remove(path: String) {
        lock.lock()
        cache.removeObject(forKey: path as NSString)
        lock.unlock()
    }
}

/// 库内缩略图：缓存命中直接显示，未命中的磁盘解码放到后台，避免在视图求值里同步读盘。
struct MPhotoThumbnail: View {
    let url: URL

    @State private var image: MPlatformImage?

    var body: some View {
        ZStack {
            Rectangle().fill(MColor.surface2)
            if let image {
                MImage.swiftUI(image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = MThumbnailCache.shared.cachedImage(for: url) {
            image = cached
            return
        }
        image = nil
        let loaded = await Task.detached(priority: .utility) {
            MThumbnailCache.shared.image(for: url)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

extension CGImage {
    /// 顺时针旋转 90°：纯几何重排，不插值。
    var quarterTurnedClockwise: CGImage? {
        let targetWidth = height
        let targetHeight = width
        guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: targetWidth, height: targetHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.translateBy(x: CGFloat(targetWidth) / 2, y: CGFloat(targetHeight) / 2)
        context.rotate(by: .pi / 2)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension MPlatformImage {
    /// 屏幕显示图的 90° 顺时针旋转。
    var quarterTurnedClockwise: MPlatformImage? {
        #if os(iOS)
        guard let rotated = cgImage?.quarterTurnedClockwise else { return nil }
        return UIImage(cgImage: rotated, scale: scale, orientation: .up)
        #else
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rotated = cg.quarterTurnedClockwise else { return nil }
        return NSImage(cgImage: rotated,
                       size: NSSize(width: rotated.width, height: rotated.height))
        #endif
    }
}
