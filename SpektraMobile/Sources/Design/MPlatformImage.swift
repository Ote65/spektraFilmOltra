import Foundation
import SwiftUI
import CoreGraphics
import CoreImage

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

    /// 按 EXIF 方向转正后加载：与显影台/缩略图同源（`ImageLoader.renderToImage` 里的
    /// `oriented(forExifOrientation:)`），专供本次拍摄大图预览——那条路径原先走裸
    /// `load(url:)`，竖拍 DNG/JPEG 内嵌图会横过来 90°。
    static func loadOriented(url: URL) -> MPlatformImage? {
        guard let cgImage = ImageBridge.cgImage(contentsOf: url) else { return nil }
        let exif = ImageLoader.exifOrientation(url: url)
        guard exif != .up else { return make(cgImage: cgImage) }
        let oriented = CIImage(cgImage: cgImage)
            .oriented(forExifOrientation: Int32(exif.rawValue))
        let context = CIContext(options: nil)
        guard let rotated = context.createCGImage(oriented, from: oriented.extent) else {
            return make(cgImage: cgImage)
        }
        return make(cgImage: rotated)
    }

    /// 保存成品用的通用 JPEG 编码，避免各页面各写一套平台分支。
    static func jpegData(_ image: MPlatformImage, quality: Double = 0.94) -> Data? {
        #if os(macOS)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.representation(using: .jpeg,
                                     properties: [.compressionFactor: quality])
        #else
        return image.jpegData(compressionQuality: quality)
        #endif
    }

    static func thumbnail(url: URL) -> MPlatformImage? {
        MThumbnailCache.shared.image(for: url)
    }
}

/// 按实际像素尺寸记账开销，两个缓存共用：固定按 512² 估值会提前挤爆上限，
/// 滚动回来又要重新解码。
private func imageCost(_ image: MPlatformImage) -> Int {
    #if os(macOS)
    let width = Int(image.size.width.rounded())
    let height = Int(image.size.height.rounded())
    #else
    let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
    let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
    #endif
    return max(1, width * height * 4)
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
            // 加超时：损坏文件 / 磁盘异常导致解码永远不返回时，调用线程（可能含主线程）不会被永久挂住。
            lock.unlock()
            _ = group.wait(timeout: .now() + 6)
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
            cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
        }
        inFlight.removeValue(forKey: key)
        lock.unlock()
        group.leave()
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

    /// 设置页清理缓存：缩略图只是解码加速层，清空后会按需重新读盘。
    func removeAll() {
        lock.lock()
        cache.removeAllObjects()
        lock.unlock()
    }
}

/// 成品预览缓存：主页点开已调色卡片时，直接复用显影交接图做一次调色/几何/片边合成。
///
/// 结果既进内存 L1，也落盘到 `FinishedPreviews/` 作为 L2。落盘是必要的：
/// 老卡片没有直出 `renderedPath`，若只在点开瞬间异步渲染，首帧 `previewImage` 为空，
/// 相框只能按几何猜比例，成品图到达后再跳一次。启动时 `backfill` 把所有已调色照片
/// 各渲染一遍写入磁盘，之后点开就能同步命中真实成品图与它的真实比例。
final class MFinishedPreviewCache {
    static let shared = MFinishedPreviewCache()

    private let memory = NSCache<NSString, MPlatformImage>()
    private var inFlight: [String: Task<MPlatformImage?, Never>] = [:]

    private init() {
        memory.countLimit = 8
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    /// FNV-1a：跨进程稳定，`Data.hashValue` 每次启动都会变，磁盘文件名必须用这个。
    private static func stableHash(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        return hash
    }

    static func key(for photo: LibraryPhoto) -> String {
        let fingerprint = MobileDevelopSession.handoffFingerprint(for: photo)
        func digest(_ data: Data?) -> String {
            guard let data else { return "-" }
            return String(format: "%016llx", stableHash([UInt8](data)))
        }
        return "\(photo.id)|\(fingerprint)|\(digest(photo.gradeData))"
            + "|\(digest(photo.cropData))|\(digest(photo.borderData))"
            + "|\(photo.renderedPath ?? "-")"
    }

    private static func directory(_ store: LibraryStore) -> URL {
        store.root.appendingPathComponent("FinishedPreviews", isDirectory: true)
    }

    private static func fileURL(key: String, store: LibraryStore) -> URL {
        let name = String(format: "%016llx", stableHash(Array(key.utf8))) + ".jpg"
        return directory(store).appendingPathComponent(name)
    }

    /// 磁盘命中：只解码已有成品图，不跑渲染管线，可以同步做。
    private static func loadDisk(key: String, store: LibraryStore) -> MPlatformImage? {
        guard let cg = ImageBridge.cgImage(contentsOf: fileURL(key: key, store: store)) else {
            return nil
        }
        return MImage.make(cgImage: cg)
    }

    private static func writeDisk(_ image: MPlatformImage, key: String, store: LibraryStore) {
        var dir = directory(store)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 派生缓存，不占 iCloud 备份空间。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        guard let data = MImage.jpegData(image, quality: 0.92) else { return }
        try? data.write(to: fileURL(key: key, store: store), options: .atomic)
    }

    /// 内存 L1 未命中时同步读磁盘 L2；回填完成后这里就是真实成品图，比例不会跳。
    func cached(for photo: LibraryPhoto, store: LibraryStore) -> MPlatformImage? {
        let key = Self.key(for: photo)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let disk = Self.loadDisk(key: key, store: store) else { return nil }
        memory.setObject(disk, forKey: key as NSString, cost: imageCost(disk))
        return disk
    }

    @MainActor
    func image(for photo: LibraryPhoto, store: LibraryStore) async -> MPlatformImage? {
        let key = Self.key(for: photo)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task: Task<MPlatformImage?, Never> = Task.detached(priority: .userInitiated) {
            // 先查磁盘 L2：L1 被挤出后不必重跑整条渲染管线（回填与按需求值可能命中同一 key）。
            if let disk = Self.loadDisk(key: key, store: store) { return disk }
            guard let image = Self.render(photo: photo, store: store) else { return nil }
            Self.writeDisk(image, key: key, store: store)
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        guard let image = await task.value else { return nil }
        memory.setObject(image, forKey: key as NSString, cost: imageCost(image))
        return image
    }

    /// 回填：把库内每张已调色照片的成品预览各渲染一次写进磁盘缓存。
    ///
    /// 逐张串行、低优先级执行，已命中磁盘的直接跳过；只有依赖交接图/原图都无法渲染的
    /// 卡片会留空，下次点开再走既有的按需求值兜底。参数变化后键随之变化，旧文件自然失效。
    nonisolated static func backfill(photos: [LibraryPhoto], store: LibraryStore) async {
        // 与 MobileEngine 的 isGraded 口径一致：显影台只调 quickIntents 的照片也算已调色，
        // 它们靠显影交接图出片，同样没有直出副本，正是最需要回填的一类。
        let graded = photos.filter {
            !$0.edit.quickIntents.isEmpty || $0.gradeData != nil
        }
        guard !graded.isEmpty else { return }
        let started = Date()
        try? FileManager.default.createDirectory(
            at: directory(store), withIntermediateDirectories: true)
        var validNames = Set<String>()
        for photo in graded {
            if Task.isCancelled { return }
            let key = key(for: photo)
            let url = fileURL(key: key, store: store)
            validNames.insert(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            // 每张独立 autoreleasepool：CoreImage/ImageIO 的临时对象按张释放，
            // 库大时不累积成内存峰值。
            guard let image = autoreleasepool(invoking: { render(photo: photo, store: store) })
            else { continue }
            writeDisk(image, key: key, store: store)
            // NSCache 本身线程安全；顺手预热 L1，让刚启动点开也直接命中内存。
            shared.memory.setObject(image, forKey: key as NSString, cost: imageCost(image))
            // 每张后让出线程：启动期间不长时间霸占 .utility 线程，相机首帧/主页不被拖慢。
            await Task.yield()
        }
        // 只清理回填开始前就存在的失效派生缓存：回填期间 image(for:) 可能写入新 key，
        // 用起始时间划线，避免把刚生成的图删掉。不碰本目录以外的任何文件。
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory(store), includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        for file in files where !validNames.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantFuture
            guard modified < started else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 交接图是线性 ProPhoto；必须走和调色台一致的转换，不能当成 sRGB 直接编码。
    private static func render(photo: LibraryPhoto, store: LibraryStore) -> MPlatformImage? {
        // 优先用当前参数对应的显影交接图；只有没有交接图的直出成片才读持久化副本，
        // 否则重新显影/调色后会一直展示旧的直出成片。
        let fingerprint = MobileDevelopSession.handoffFingerprint(for: photo)
        let linear = MDevelopHandoffCache.load(
            root: store.root, photoID: photo.id, fingerprint: fingerprint)
        if linear == nil, let rendered = store.renderedURL(for: photo),
           let cg = ImageBridge.cgImage(contentsOf: rendered) {
            return MImage.make(cgImage: cg)
        }
        guard let linear else { return nil }
        // 与调色台同序：先在 ProPhoto→线性 sRGB 域套几何，再调色，最后编码显示图。
        // 若先调色再裁 8-bit 图，暗角/颗粒的中心会跟着未裁画幅走，和成片不一致。
        var prepared = GradeEngine.prepareSource(linear)
        if let data = photo.cropData,
           let geometry = try? JSONDecoder().decode(MPhotoGeometry.self, from: data) {
            prepared = geometry.apply(to: prepared)
        }
        let source = GradeEngine.downsampleLinear(prepared, maxLongEdge: 1200)
        let recipe = photo.gradeData.flatMap {
            try? JSONDecoder().decode(GradeRecipe.self, from: $0)
        } ?? GradeRecipe()
        let graded = try? GradeEngine.render(source, recipe: recipe, analyze: false)
        let display = graded?.image ?? PreviewLUTService.displayImage(fromLinear: source)
        guard var cg = PreviewRenderer.cgImage(from: display) else { return nil }

        if let data = photo.borderData,
           let config = try? JSONDecoder().decode(MFilmBorderConfig.self, from: data) {
            let stamp = MFilmBorderRenderer.captureStamp(url: store.originalURL(for: photo))
            cg = MFilmBorderRenderer.preview(
                photo: cg, config: config, filmID: photo.edit.filmStock,
                photoID: photo.id, dateLabel: stamp.date, timeLabel: stamp.time) ?? cg
        }
        return MImage.make(cgImage: cg)
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
    /// 按目标宽高比居中裁切：只取中间区域，不改像素内容。
    /// 用于显影预览图提前呈现成片的画幅（横拍 16:9 / 竖拍 9:16）。
    func centerCropped(toAspect target: Double) -> CGImage? {
        let current = Double(width) / Double(height)
        guard target > 0, width > 1, height > 1 else { return self }
        let cropW: Int
        let cropH: Int
        if current > target {
            cropH = height
            cropW = max(1, min(width, Int((Double(height) * target).rounded())))
        } else {
            cropW = width
            cropH = max(1, min(height, Int((Double(width) / target).rounded())))
        }
        let rect = CGRect(
            x: (width - cropW) / 2, y: (height - cropH) / 2,
            width: cropW, height: cropH)
        return cropping(to: rect)
    }

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

    /// 水平镜像：纯几何变换，不插值。前置「镜像前置相机」开时，
    /// 快门缩略图翻成取景预览所见，成片渲染做同一翻转。
    var mirroredHorizontally: CGImage? {
        guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.scaleBy(x: -1, y: 1)
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
