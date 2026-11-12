import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 预览渲染调度：串行队列 + 代际取消 + 共享 LUT 缓存 + 预览降采样。
/// 只保留最后一次请求的结果，过期结果直接丢弃。
final class PreviewRenderer {
    struct Outcome {
        let image: ImageRGB
        let elapsed: TimeInterval
        let cancelled: Bool
    }

    private let queue = DispatchQueue(label: "spektra.preview.render", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var sharedLUT: SpectralLUTService?
    private var lutKey: String?

    func invalidate() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func lutService(for params: RuntimePhotoParams) -> SpectralLUTService {
        let key = "\(params.film.info.stock)|\(params.print.info.stock)|\(params.settings.lutResolution)"
        lock.lock()
        defer { lock.unlock() }
        if let sharedLUT, lutKey == key {
            return sharedLUT
        }
        let service = SpectralLUTService(resolution: params.settings.lutResolution)
        sharedLUT = service
        lutKey = key
        return service
    }

    func render(params: RuntimePhotoParams, image: ImageRGB, maxSize: Int? = nil,
                progress: ((String, Int, Int) -> Void)? = nil,
                completion: @escaping (Outcome) -> Void) {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        let capacity = maxSize ?? params.settings.previewMaxSize
        queue.async { [weak self] in
            guard let self else { return }
            if self.currentGeneration() != token { return }
            // 缩放放到渲染队列：1600→1008 的逐像素双线性在主线程会顶掉交互帧。
            let prepared = Self.prepared(image, maxSize: capacity)
            var working = params
            let lut = self.lutService(for: working)
            let pipeline = SimulationPipeline(params: working, lutService: lut, keepTaps: false)
            pipeline.shouldCancel = { self.currentGeneration() != token }
            let start = Date()
            let result = pipeline.process(prepared, progress: { label, index, total in
                if self.currentGeneration() == token {
                    progress?(label, index, total)
                }
            })
            let elapsed = Date().timeIntervalSince(start)
            if self.currentGeneration() != token { return }
            completion(Outcome(image: result.rgbOut, elapsed: elapsed, cancelled: false))
        }
    }

    /// 预览/导出准备：双线性降采样。最近邻在非整数倍缩小（如 1600→1008）时会产生锯齿。
    static func prepared(_ image: ImageRGB, maxSize: Int) -> ImageRGB {
        Resize.longEdge(image, maxSize: maxSize)
    }

    /// 8-bit sRGB 显示图（预览仅用于屏幕显示）。
    static func cgImage(from image: ImageRGB) -> CGImage? {
        ImageBridge.cgImage(from: image)
    }

    #if os(macOS)
    static func nsImage(from image: ImageRGB) -> NSImage? {
        guard let cgImage = ImageBridge.cgImage(from: image) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: image.width, height: image.height))
    }
    #else
    static func uiImage(from image: ImageRGB) -> UIImage? {
        guard let cgImage = ImageBridge.cgImage(from: image) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}
