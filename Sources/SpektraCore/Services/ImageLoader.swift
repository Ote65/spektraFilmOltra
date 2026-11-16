import Foundation
import CoreGraphics
import CoreImage
import ImageIO

struct LoadedImage {
    var image: ImageRGB
    var colorSpace: String
    var cctfDecoding: Bool
    var isRaw: Bool
    /// RAW 解码超时/失败后退回 ImageIO 预览。调用方可据此提示用户。
    var usedFallback: Bool = false
}

/// 输入图像识别与解码。对齐 Python `spektrafilm_gui/input_color.py`：
/// RAW → ProPhoto 线性；EXR/HDR → ACES 线性；编码图按 ICC 描述匹配，缺省 sRGB + CCTF 解码。
///
/// 除色彩解码外还承担以下行为，调用方需一并知晓：
/// - **JPEG 门槛**：`rejectedSuffixes`（jpg/jpeg）默认拒绝，只有设置打开「支持 JPEG」、
///   调用方传 `allowEncoded: true` 才放行；其余编码图（png/tif/heic 等）不受此门槛限制。
/// - **RAW 降级**：真机上 CIRAWFilter 打不开或首次 MobileAsset 查询超时时，预览可经
///   `allowPreviewFallback` 退回 ImageIO 内嵌预览并在 `LoadedImage.usedFallback` 标记；
///   导出必须传 `allowPreviewFallback: false`，否则会把低分辨率预览写成成品。
/// - **模拟器**：无相机 RAW 描述，RAW 一律走 ImageIO 缩略图管线（线性 sRGB，不能应用
///   白平衡/镜头校正），仅用于预览与验收。
/// - **方向**：EXIF 方向在 `renderToImage` 统一应用（显影/调色/导出/缩略图共用入口），
///   用户手动旋转在 `load` 施加。
enum ImageLoader {
    static let rawSuffixes: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef",
        "srw", "3fr", "iiq", "x3f", "erf", "mef", "mos", "mrw", "nrw",
        "rwl", "srf", "sr2",
    ]
    static let linearSuffixes: Set<String> = ["exr", "hdr"]
    static let encodedSuffixes: Set<String> = [
        "png", "tif", "tiff", "bmp", "webp", "jpg", "jpeg", "heic", "heif",
    ]
    /// 默认拒绝的编码图；iOS 设置里打开「支持 JPEG」后由调用方传入 allowEncoded 放行。
    static let rejectedSuffixes: Set<String> = ["jpg", "jpeg"]

    static let iccMappings: [(String, String)] = [
        ("display p3", "Display P3"),
        ("dci-p3", "DCI-P3"),
        ("adobe rgb", "Adobe RGB (1998)"),
        ("prophoto", "ProPhoto RGB"),
        ("romm", "ProPhoto RGB"),
        ("aces", "ACES2065-1"),
        ("rec.2020", "ITU-R BT.2020"),
        ("bt.2020", "ITU-R BT.2020"),
        ("rec.709", "sRGB"),
        ("bt.709", "sRGB"),
        ("srgb", "sRGB"),
        ("iec61966", "sRGB"),
    ]

    static func detectColorSpace(url: URL) -> (space: String, cctfDecoding: Bool) {
        let suffix = url.pathExtension.lowercased()
        if rawSuffixes.contains(suffix) { return ("ProPhoto RGB", false) }
        if linearSuffixes.contains(suffix) { return ("ACES2065-1", false) }
        if let description = profileName(url: url)?.lowercased() {
            for (token, space) in iccMappings where description.contains(token) {
                return (space, space != "ACES2065-1")
            }
        }
        return ("sRGB", true)
    }

    static func profileName(url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any] else { return nil }
        return properties[kCGImagePropertyProfileName as String] as? String
    }

    /// - Parameter maxSize: 长边上限。预览只解码到显示需要的尺寸，避免为 12MP 原图
    ///   常驻 290MB 的双精度缓冲；导出传 nil 才是全分辨率。
    /// - Parameter rawOptions: RAW 解码参数（白平衡/色温/色调/镜头校正）；非 RAW 忽略。
    /// - Parameter rotationTurns: 用户手动旋转，0–3 表示顺时针 90° 的倍数。
    /// - Parameter rawTimeout: RAW 解码（含首次 MobileAsset 查询）超时秒数。
    /// - Parameter allowPreviewFallback: RAW 超时/失败后是否允许退回 ImageIO 内嵌预览。
    ///   预览可以降级，导出必须为 false，否则会把低分辨率预览当成成品写出去。
    static func load(url: URL, maxSize: Int? = nil,
                     rawOptions: RawDecoder.Options = RawDecoder.Options(),
                     rotationTurns: Int = 0,
                     allowEncoded: Bool = false,
                     rawTimeout: TimeInterval = 12,
                     allowPreviewFallback: Bool = true) throws -> LoadedImage {
        var loaded = try decode(url: url, maxSize: maxSize, rawOptions: rawOptions,
                                allowEncoded: allowEncoded, rawTimeout: rawTimeout,
                                allowPreviewFallback: allowPreviewFallback)
        let turns = ((rotationTurns % 4) + 4) % 4
        if turns != 0 {
            loaded.image = loaded.image.rotatedClockwise(turns)
        }
        return loaded
    }

    /// 读取 EXIF 方向；缺失时按 `.up` 处理。
    static func exifOrientation(url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let raw = properties[kCGImagePropertyOrientation as String] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }

    /// 拍摄时的曝光补偿（EXIF ExposureBias）。相机内调过曝光的 DNG 靠它把拍摄意图带进显影：
    /// 补偿已写进感光数据，但显影管线的自动曝光会把它归一化掉，必须读回来重新施加。
    static func capturedExposureBias(url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let bias = exif["ExposureBias"] as? Double,
              bias.isFinite else { return 0 }
        return bias
    }

    private static func decode(url: URL, maxSize: Int?,
                               rawOptions: RawDecoder.Options,
                               allowEncoded: Bool,
                               rawTimeout: TimeInterval,
                               allowPreviewFallback: Bool) throws -> LoadedImage {
        let detected = detectColorSpace(url: url)
        let suffix = url.pathExtension.lowercased()
        if !allowEncoded, rejectedSuffixes.contains(suffix) {
            throw NSError(domain: "Spektrafilm.ImageLoader", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "显影台不支持 JPEG 输入：\(url.lastPathComponent)"])
        }
        if rawSuffixes.contains(suffix) {
            #if targetEnvironment(simulator)
            // 模拟器没有相机 RAW 描述，CIRAWFilter 会永久卡在 MobileAsset 查询上，
            // 直接走 ImageIO 的缩略图管线（已去马赛克，线性 sRGB），只用于预览与验收。
            // 该路径无法应用白平衡/镜头校正参数，真机才走 CIRAWFilter。
            let image = try RawDecoder.decodeThumbnail(url: url, maxSize: maxSize ?? 4096)
            return LoadedImage(image: image, colorSpace: "sRGB",
                               cctfDecoding: false, isRaw: true)
            #else
            do {
                var options = rawOptions
                options.outputColorSpace = detected.space
                options.maxSize = maxSize
                let image = try RawDecoder.decodeWithTimeout(
                    url: url, options: options, timeout: rawTimeout)
                return LoadedImage(image: image, colorSpace: detected.space,
                                   cctfDecoding: false, isRaw: true)
            } catch {
                // 导出等需要全质量的路径不能悄悄退回内嵌预览。
                if !allowPreviewFallback { throw error }
                // CIRAWFilter 打不开这张 RAW（不同机型的 ProRAW 容器差异、系统 RAW 支持缺失等），
                // 或首次 MobileAsset 查询超时。不让用户卡在「读取 RAW」：退回 ImageIO 预览，
                // 只降级不拒绝，并把原因写日志。
                let timedOut: Bool
                if case .some(.timeout) = error as? RawDecoder.DecodeError {
                    timedOut = true
                } else {
                    timedOut = false
                }
                if timedOut {
                    NSLog("MRaw timeout %@ — %@", url.lastPathComponent,
                          (error as NSError).localizedDescription)
                } else {
                    NSLog("MRaw fallback %@ — %@", url.lastPathComponent,
                          (error as NSError).localizedDescription)
                }
                let image = try RawDecoder.decodeThumbnail(url: url, maxSize: maxSize ?? 4096)
                return LoadedImage(image: image, colorSpace: "sRGB",
                                   cctfDecoding: false, isRaw: true,
                                   usedFallback: true)
            }
            #endif
        }
        if linearSuffixes.contains(suffix) {
            var image = try renderToImage(url: url, colorSpace: "sRGB",
                                          linear: true)
            image.mapInPlace { ColorMath.rgbToRGB($0, from: "sRGB", to: "ACES2065-1") }
            return LoadedImage(image: image, colorSpace: "ACES2065-1",
                               cctfDecoding: false, isRaw: false)
        }
        let image = try renderToImage(url: url, colorSpace: detected.space,
                                      linear: !detected.cctfDecoding)
        return LoadedImage(image: image, colorSpace: detected.space,
                           cctfDecoding: detected.cctfDecoding, isRaw: false)
    }

    /// 用 Core Image 渲染到 RGBAf；`linear` 为 true 时用扩展线性 sRGB 工作空间。
    static func renderToImage(url: URL, colorSpace: String, linear: Bool) throws -> ImageRGB {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageExport.ExportError.encodeFailed("image source \(url.lastPathComponent)")
        }
        // EXIF 方向必须在这里应用：显影、调色、导出、缩略图都经过这个入口。
        let ciImage = CIImage(cgImage: cgImage)
            .oriented(forExifOrientation: Int32(exifOrientation(url: url).rawValue))
        let extent = ciImage.extent
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else {
            throw ImageExport.ExportError.encodeFailed("empty image \(url.lastPathComponent)")
        }
        let outputSpace: CGColorSpace
        if linear {
            outputSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        } else if let icc = ImageExport.iccProfile(colorSpace: colorSpace, cctfEncoding: true),
                  let profile = CGColorSpace(iccData: icc as CFData) {
            outputSpace = profile
        } else {
            outputSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let context = CIContext(options: [.workingColorSpace: outputSpace])
        var buffer = [Float](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            context.render(
                ciImage, toBitmap: raw.baseAddress!,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: extent, format: .RGBAf, colorSpace: outputSpace
            )
        }
        // 直接收成 RGB Float 后释放 RGBA 缓冲，避免 34 MP 下再背一份 Double 整图。
        var image = ImageRGB(width: width, height: height, rgbaFloat: buffer)
        buffer = []
        return image
    }
}
