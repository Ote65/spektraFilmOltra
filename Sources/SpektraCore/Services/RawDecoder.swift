import Foundation
import CoreImage
import ImageIO

/// RAW 解码（macOS 原生路径）。
///
/// Python 参考实现使用 LibRaw（rawpy）输出线性 ACES RGB；macOS 没有 LibRaw，
/// 这里使用 ImageIO / Core Image 的 RAW 管线（CIRAWFilter）做去马赛克与相机矩阵，
/// 再转换到请求的输出色彩空间。去马赛克与白平衡细节无法与 LibRaw 逐像素一致，
/// 因此这部分不参与数值对拍，只保证接口与色彩空间链路正确。
enum RawDecoder {
    struct Options {
        var whiteBalance: String = "as_shot"
        var temperature: Double?
        var tint: Double?
        var outputColorSpace: String = "ACES2065-1"
        var outputCCTFEncoding: Bool = false
        var lensCorrection: Bool = true
        /// 长边上限；nil 表示全分辨率。
        var maxSize: Int? = nil
        /// 按行分带渲染：大图不再一次要一整张 RGBAf，峰值只跟带高有关。
        /// 48 MP 下整图 RGBAf 约 780 MB，分 256 行后只要约 30 MB。
        var bandRows: Int? = nil
        /// 草稿模式：跳过高质量去马赛克，模拟器上避免等待 MobileAsset 相机描述。
        var draftMode: Bool = false
    }

    enum DecodeError: Error, CustomStringConvertible {
        case unsupported(String)
        case renderFailed(String)
        case timeout(String)

        var description: String {
            switch self {
            case .unsupported(let message): return "RAW decode unsupported: \(message)"
            case .renderFailed(let message): return "RAW render failed: \(message)"
            case .timeout(let message): return "RAW decode timeout: \(message)"
            }
        }
    }

    /// CIRAWFilter 首次初始化会查询系统 RAW 支持（MobileAsset）。系统或 App
    /// 刚更新、网络不可用时，这个查询可能长时间不返回；解码必须放在独立并发
    /// 队列并加超时，不能占住显影台的串行 loadQueue。
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<ImageRGB, Error>?

        func set(_ value: Result<ImageRGB, Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }

        func get() -> Result<ImageRGB, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private static let decodeQueue = DispatchQueue(
        label: "spektrafilm.raw.decode", qos: .userInitiated, attributes: .concurrent)
    /// 最多允许两个解码卡在 MobileAsset 查询上；再多就直接走预览兜底。
    private static let decodeSlots = DispatchSemaphore(value: 2)

    static func decodeWithTimeout(url: URL, options: Options = Options(),
                                  timeout: TimeInterval = 12) throws -> ImageRGB {
        try decodeWithTimeout(url: url, options: options, timeout: timeout) { url, options in
            try decode(url: url, options: options)
        }
    }

    static func decodeWithTimeout(url: URL, options: Options, timeout: TimeInterval,
                                  decoder: @escaping (URL, Options) throws -> ImageRGB) throws -> ImageRGB {
        guard decodeSlots.wait(timeout: .now()) == .success else {
            throw DecodeError.timeout("decoder busy")
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        decodeQueue.async {
            defer { decodeSlots.signal() }
            do {
                box.set(.success(try decoder(url, options)))
            } catch {
                box.set(.failure(error))
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw DecodeError.timeout("exceeded \(timeout)s")
        }
        guard let result = box.get() else {
            throw DecodeError.renderFailed("no decode result")
        }
        return try result.get()
    }

    static func decode(url: URL, options: Options = Options()) throws -> ImageRGB {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw DecodeError.unsupported(url.lastPathComponent)
        }
        filter.isDraftModeEnabled = options.draftMode
        filter.isLensCorrectionEnabled = options.lensCorrection
        // 手机横屏拍摄时 DNG 只有 EXIF orientation 记录方向；不设这一步输出会躺倒。
        filter.orientation = ImageLoader.exifOrientation(url: url)
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        if let maxSize = options.maxSize {
            let native = filter.nativeSize
            let longEdge = max(native.width, native.height)
            if longEdge > 0, CGFloat(maxSize) < longEdge {
                filter.scaleFactor = Float(CGFloat(maxSize) / longEdge)
            }
        }

        switch options.whiteBalance {
        case "as_shot":
            break
        case "daylight":
            // 参考实现的 daylight 预设：中性日光白平衡，等价于 5500 K / 中性色调。
            filter.neutralTemperature = 5500
            filter.neutralTint = 0
        case "tungsten":
            filter.neutralTemperature = 2850
        case "custom":
            if let temperature = options.temperature {
                filter.neutralTemperature = Float(temperature)
            }
            if let tint = options.tint {
                // CIRAWFilter 的 tint 轴为 [-150, 150]；Python 的 tint 是绿色乘子（1.0 为中性）。
                filter.neutralTint = Float((tint - 1.0) * 100.0)
            }
        default:
            break
        }

        guard let output = filter.outputImage else {
            throw DecodeError.renderFailed("no output image")
        }
        let extent = output.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else {
            throw DecodeError.renderFailed("empty extent")
        }

        let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.workingColorSpace: linearSRGB])
        var image: ImageRGB
        if let bandRows = options.bandRows, bandRows > 0, height > bandRows {
            image = renderBanded(output, width: width, height: height, bandRows: bandRows,
                                 context: context, colorSpace: linearSRGB)
        } else {
            var buffer = [Float](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { raw in
                context.render(
                    output, toBitmap: raw.baseAddress!, rowBytes: width * 4 * MemoryLayout<Float>.size,
                    bounds: extent, format: .RGBAf, colorSpace: linearSRGB
                )
            }

            // 直接从 RGBAf 收成 RGB Float，随后立刻释放 RGBA 缓冲；
            // 34 MP 下比旧实现（RGBAf + Double RGB + Float RGB 三份并存）少约 1.3 GB。
            image = ImageRGB(width: width, height: height, rgbaFloat: buffer)
            buffer = []
        }
        if options.outputColorSpace != "sRGB" {
            let target = options.outputColorSpace
            image.mapInPlace { pixel in
                ColorMath.rgbToRGB(pixel, from: "sRGB", to: target)
            }
        }
        if options.outputCCTFEncoding {
            let kind = ColorMath.cctfKind(for: options.outputColorSpace)
            image.mapInPlace { pixel in
                Vec3(
                    ColorMath.cctfEncode(pixel.x, kind: kind),
                    ColorMath.cctfEncode(pixel.y, kind: kind),
                    ColorMath.cctfEncode(pixel.z, kind: kind)
                )
            }
        }
        image.sanitizeNonFinite()
        return image
    }

    /// 按行分带渲染进整图。
    ///
    /// Core Image 的坐标原点在左下角，而 `ImageRGB` 的第 0 行是画面顶部：
    /// 顶部第 `top` 行对应 CI 的 `height - top - rows`。整图缓冲只分配一次，
    /// 每条带的 RGBAf 缓冲渲染完立刻释放，峰值 = 整图 RGB + 一条带。
    private static func renderBanded(
        _ output: CIImage, width: Int, height: Int, bandRows: Int,
        context: CIContext, colorSpace: CGColorSpace
    ) -> ImageRGB {
        var image = ImageRGB(width: width, height: height)
        let rows = max(16, bandRows)
        var top = 0
        while top < height {
            let bandHeight = min(rows, height - top)
            let rect = CGRect(x: 0, y: height - top - bandHeight,
                              width: width, height: bandHeight)
            let band = output.cropped(to: rect)
            var buffer = [Float](repeating: 0, count: width * bandHeight * 4)
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                context.render(
                    band, toBitmap: base,
                    rowBytes: width * 4 * MemoryLayout<Float>.size,
                    bounds: rect, format: .RGBAf, colorSpace: colorSpace
                )
            }
            image.data.withUnsafeMutableBufferPointer { destination in
                guard let dst = destination.baseAddress else { return }
                buffer.withUnsafeBufferPointer { source in
                    guard let src = source.baseAddress else { return }
                    var srcIndex = 0
                    var dstIndex = top * width * 3
                    for _ in 0..<(width * bandHeight) {
                        dst[dstIndex] = src[srcIndex]
                        dst[dstIndex + 1] = src[srcIndex + 1]
                        dst[dstIndex + 2] = src[srcIndex + 2]
                        srcIndex += 4
                        dstIndex += 3
                    }
                }
            }
            buffer = []
            top += bandHeight
        }
        return image
    }

    /// 模拟器专用回退：`CIRAWFilter` 在 iOS 模拟器上会卡住（MobileAsset 拿不到相机描述）。
    /// 用 ImageIO 的缩略图管线拿到已去马赛克的图，代价是白平衡采用系统默认，但预览可用。
    static func decodeThumbnail(url: URL, maxSize: Int) throws -> ImageRGB {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DecodeError.unsupported(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let fullEdge = max(
            properties?[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
            properties?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        )
        let target = max(1, min(maxSize, max(fullEdge, 1)))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            throw DecodeError.renderFailed("thumbnail failed")
        }
        let image = try renderLinear(thumbnail)
        // ImageIO 在没有对应 RAW 解码器时会退回内嵌预览且不报错；
        // 这里留下尺寸差异日志，方便定位「选最大尺寸仍只有预览尺寸」的机型。
        let actual = max(image.width, image.height)
        if actual < target {
            NSLog("MRaw preview fallback %@ requested %ld got %ld",
                  url.lastPathComponent, target, actual)
        }
        return image
    }

    /// CGImage → 线性 sRGB `ImageRGB`。
    private static func renderLinear(_ image: CGImage) throws -> ImageRGB {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw DecodeError.renderFailed("empty image") }
        let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let ciContext = CIContext(options: [.workingColorSpace: linearSRGB])
        let ciImage = CIImage(cgImage: image)
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ciContext.render(
                ciImage, toBitmap: base,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf, colorSpace: linearSRGB
            )
        }
        var image = ImageRGB(width: width, height: height, rgbaFloat: buffer)
        buffer = []
        image.sanitizeNonFinite()
        return image
    }

    /// 基础 EXIF（相机 / 镜头 / 焦距 / 光圈），供导出与界面显示使用。
    static func metadata(url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        var result: [String: Any] = [:]
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake as String] { result["make"] = make }
            if let model = tiff[kCGImagePropertyTIFFModel as String] { result["model"] = model }
        }
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let lens = exif[kCGImagePropertyExifLensModel as String] { result["lensModel"] = lens }
            if let focal = exif[kCGImagePropertyExifFocalLength as String] { result["focalLength"] = focal }
            if let aperture = exif[kCGImagePropertyExifFNumber as String] { result["fNumber"] = aperture }
            if let exposure = exif[kCGImagePropertyExifExposureTime as String] { result["exposureTime"] = exposure }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] { result["iso"] = iso }
        }
        return result
    }
}