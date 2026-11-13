import Foundation
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
    /// 同一 URL 的并发加载合并：后到的调用等前一个解码完成，直接取缓存。
    private var inFlight: [String: DispatchGroup] = [:]

    init() {
        cache.countLimit = 240
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) -> MPlatformImage? {
        let key = url.path
        lock.lock()
        if let hit = cache.object(forKey: key as NSString) {
            lock.unlock()
            return hit
        }
        if let group = inFlight[key] {
            // 已有相同 URL 在解码：释放锁后等待，避免在锁内阻塞。
            lock.unlock()
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return cache.object(forKey: key as NSString)
        }
        let group = DispatchGroup()
        group.enter()
        inFlight[key] = group
        lock.unlock()

        let image = MImage.load(url: url)

        lock.lock()
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        inFlight.removeValue(forKey: key)
        lock.unlock()
        group.leave()
        return image
    }

    /// 按图像实际像素尺寸记账：缩略图实际约 320 px，固定按 512² 记账会
    /// 提前挤爆 64 MB 上限，滚动回来又要重新解码。
    private static func cost(of image: MPlatformImage) -> Int {
        #if os(macOS)
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        #else
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        #endif
        return max(1, width * height * 4)
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
