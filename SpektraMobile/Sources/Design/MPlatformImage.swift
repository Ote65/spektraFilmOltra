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
        let key = url.path as NSString
        lock.lock()
        let hit = cache.object(forKey: key)
        lock.unlock()
        if let hit { return hit }
        guard let image = MImage.load(url: url) else { return nil }
        lock.lock()
        cache.setObject(image, forKey: key, cost: 512 * 512 * 4)
        lock.unlock()
        return image
    }

    func remove(path: String) {
        lock.lock()
        cache.removeObject(forKey: path as NSString)
        lock.unlock()
    }
}
