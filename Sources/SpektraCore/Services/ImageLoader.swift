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
    /// 已应用 Apple HDR 增益图：image 为真实场景线性 HDR（含 >1.0 高光），cctfDecoding 恒为 false。
    var appliedGainMap: Bool = false
    /// 是否可进入全质量场景线性路径。RAW 内嵌预览即使转成 Float 也仍只是 SDR 降级。
    var isSceneLinearHDR: Bool { !usedFallback && !cctfDecoding }
}

// MARK: - Apple HDR 增益图（Adaptive HDR 原片）

/// 按 Apple 官方文档《Applying Apple HDR effect to your photos》实现：
/// 增益图为 8-bit 单通道、Rec.709 传递函数编码、主图的 1/4 分辨率；
/// headroom 由主图 EXIF MakerNote 的键 33/48 官方公式换算；
/// 应用公式 `hdr = sdr_linear × (1 + (headroom − 1) × gainmap_linear)`（线性域乘性，
/// 三通道等比，不改变色相，色彩平衡保持）。
///
/// 谨慎性设计：任何一步探测/解析失败都返回 nil / 跳过应用，退回现状的 SDR 基底解码，
/// 绝不引入错误增强。EXIF 1…8 的方向与镜像均在应用阶段显式处理。
enum HDRGainMap {
    struct Info {
        let data: Data
        let width: Int
        let height: Int
        let stride: Int
        let headroom: Double
        let orientation: CGImagePropertyOrientation

        /// 线性域应用增益图。`image` 必须是 extendedLinear 空间的线性数据（已按 EXIF 方向摆正）。
        func apply(inPlace image: inout ImageRGB) {
            // renderToImage 已按 EXIF 摆正主图；增益图仍对应未转正原图。
            // 逆映射必须使用显示宽高，增益图网格缩放则使用原图宽高。
            let sourceWidth: Double, sourceHeight: Double
            switch orientation {
            case .right, .left, .rightMirrored, .leftMirrored:
                (sourceWidth, sourceHeight) = (Double(image.height), Double(image.width))
            default:
                (sourceWidth, sourceHeight) = (Double(image.width), Double(image.height))
            }
            let dataBytes = [UInt8](data)
            // Rec.709 解码查表：12 MP 逐像素 pow 要数百毫秒，256 项表等价且近乎零成本。
            var decodeLUT = [Float](repeating: 0, count: 256)
            for i in 1...255 {
                let encoded = Double(i) / 255.0
                decodeLUT[i] = Float(encoded <= 0.081
                    ? encoded / 4.5
                    : pow((encoded + 0.099) / 1.099, 1.0 / 0.45))
            }
            for y in 0..<image.height {
                for x in 0..<image.width {
                    guard let (r, c) = Self.sourceCoordinates(
                        orientation: orientation, x: x, y: y,
                        orientedWidth: image.width, orientedHeight: image.height)
                    else { return }
                    let g = Self.sampleBilinear(
                        data: dataBytes, lut: decodeLUT, width: width, height: height,
                        stride: stride, row: Double(r), column: Double(c),
                        sourceWidth: sourceWidth, sourceHeight: sourceHeight)
                    guard g > 0 else { continue }
                    let gain = Float(1.0 + (headroom - 1.0) * Double(g))
                    guard gain != 1 else { continue }
                    let p = (y * image.width + x) * 3
                    image.data[p] *= gain
                    image.data[p + 1] *= gain
                    image.data[p + 2] *= gain
                }
            }
        }

        /// display(x,y) → 未转正原图(r,c)，覆盖 EXIF 1…8（含镜像）。
        static func sourceCoordinates(orientation: CGImagePropertyOrientation,
                                      x: Int, y: Int, orientedWidth: Int,
                                      orientedHeight: Int) -> (r: Int, c: Int)? {
            switch orientation {
            case .up: return (y, x)
            case .upMirrored: return (y, orientedWidth - 1 - x)
            case .down: return (orientedHeight - 1 - y, orientedWidth - 1 - x)
            case .downMirrored: return (orientedHeight - 1 - y, x)
            case .leftMirrored: return (x, y)
            case .right: return (orientedWidth - 1 - x, y)
            case .rightMirrored:
                return (orientedWidth - 1 - x, orientedHeight - 1 - y)
            case .left: return (x, orientedHeight - 1 - y)
            @unknown default: return nil
            }
        }

        /// 主图像素中心映射到增益图网格，边界复制 + 双线性插值，消除最近邻方块。
        static func sampleBilinear(data: [UInt8], lut: [Float], width: Int, height: Int,
                                   stride: Int, row: Double, column: Double,
                                   sourceWidth: Double, sourceHeight: Double) -> Float {
            guard width > 0, height > 0, stride >= width, lut.count == 256,
                  sourceWidth > 0, sourceHeight > 0 else { return 0 }
            let gy = min(max((row + 0.5) * Double(height) / sourceHeight - 0.5, 0),
                         Double(height - 1))
            let gx = min(max((column + 0.5) * Double(width) / sourceWidth - 0.5, 0),
                         Double(width - 1))
            let y0 = Int(floor(gy)), x0 = Int(floor(gx))
            let y1 = min(y0 + 1, height - 1), x1 = min(x0 + 1, width - 1)
            let fy = Float(gy - Double(y0)), fx = Float(gx - Double(x0))
            func value(_ y: Int, _ x: Int) -> Float {
                lut[Int(data[y * stride + x])]
            }
            let top = value(y0, x0) * (1 - fx) + value(y0, x1) * fx
            let bottom = value(y1, x0) * (1 - fx) + value(y1, x1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// 探测并读取增益图。无增益图或解析失败返回 nil（调用方按现状 SDR 处理）。
    static func detect(url: URL) -> Info? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [String: Any],
              let data = aux[kCGImageAuxiliaryDataInfoData as String] as? Data,
              let desc = aux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
              let width = desc[kCGImagePropertyWidth as String] as? Int,
              let height = desc[kCGImagePropertyHeight as String] as? Int,
              let stride = desc[kCGImagePropertyBytesPerRow as String] as? Int,
              width > 0, height > 0, stride >= width,
              data.count >= stride * (height - 1) + width else { return nil }
        // headroom 藏在主图 EXIF 的 Apple MakerNote（键 33/48，SRational）。
        guard let fileData = try? Data(contentsOf: url),
              let headroom = Self.appleHeadroom(fileData: fileData) else { return nil }
        let orientation = ImageLoader.exifOrientation(url: url)
        return Info(data: data, width: width, height: height, stride: stride,
                    headroom: headroom, orientation: orientation)
    }

    /// 官方公式：
    /// ```
    /// if maker33 < 1.0 {
    ///     stops = maker48 <= 0.01 ? -20.0 * maker48 + 1.8 : -0.101 * maker48 + 1.601
    /// } else {
    ///     stops = maker48 <= 0.01 ? -70.0 * maker48 + 3.0 : -0.303 * maker48 + 2.303
    /// }
    /// headroom = 2 ^ max(stops, 0)
    /// ```
    /// 上限夹到 4 档（16×，官方分支的取值域 ≤ 3.0 档）：异常/损坏的 SRational
    /// 可能给出巨大 stops，不夹会把整图高光乘成死白——与「绝不引入错误增强」的
    /// 设计原则一致。
    static func headroomFromMakerNote(maker33: Double, maker48: Double) -> Double {
        let stops: Double
        if maker33 < 1.0 {
            stops = maker48 <= 0.01 ? -20.0 * maker48 + 1.8 : -0.101 * maker48 + 1.601
        } else {
            stops = maker48 <= 0.01 ? -70.0 * maker48 + 3.0 : -0.303 * maker48 + 2.303
        }
        return pow(2.0, min(max(stops, 0.0), 4.0))
    }

    /// 在文件二进制中定位 Apple MakerNote 并解析 headroom。
    /// HEIC 的 EXIF 以独立 item 内嵌，ImageIO 不透出 MakerNote 原始数据，
    /// 这里按「TIFF 头 → IFD0 → EXIF IFD → MakerNote("Apple iOS" 头) → 键 33/48」
    /// 的校验链搜索，误报概率极低；任何异常都吞掉返回 nil。
    static func appleHeadroom(fileData: Data) -> Double? {
        let bytes = [UInt8](fileData)
        func u16(_ o: Int, _ be: Bool) -> Int {
            be ? Int(bytes[o]) << 8 | Int(bytes[o + 1]) : Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int, _ be: Bool) -> Int {
            be ? u16(o, be) << 16 | u16(o + 2, be) : u16(o, be) | u16(o + 2, be) << 16
        }
        func i32(_ o: Int, _ be: Bool) -> Int { Int(Int32(truncatingIfNeeded: u32(o, be))) }

        var searchStart = 0
        while true {
            // TIFF 头：II*\0 (LE) 或 MM\0* (BE)
            let iiIdx = firstIndex(of: [0x49, 0x49, 0x2A, 0x00], in: bytes, from: searchStart)
            let mmIdx = firstIndex(of: [0x4D, 0x4D, 0x00, 0x2A], in: bytes, from: searchStart)
            guard iiIdx >= 0 || mmIdx >= 0 else { return nil }
            // 取先出现的那个
            var tiff = 0; var bigEndian = false
            if iiIdx >= 0 && (mmIdx < 0 || iiIdx <= mmIdx) { tiff = iiIdx; bigEndian = false }
            else { tiff = mmIdx; bigEndian = true }
            searchStart = tiff + 1
            guard tiff + 8 < bytes.count else { continue }

            guard let (m33, m48) = parseAppleMakerNote(
                bytes: bytes, tiff: tiff, bigEndian: bigEndian,
                u16: { u16($0, bigEndian) }, u32: { u32($0, bigEndian) },
                i32: { i32($0, bigEndian) }) else { continue }
            return headroomFromMakerNote(maker33: m33, maker48: m48)
        }
    }

    private static func parseAppleMakerNote(
        bytes: [UInt8], tiff: Int, bigEndian: Bool,
        u16: (Int) -> Int, u32: (Int) -> Int, i32: (Int) -> Int
    ) -> (Double, Double)? {
        func entryCount(_ ifd: Int) -> Int {
            guard ifd + 2 <= bytes.count else { return 0 }
            let c = u16(ifd)
            return (c >= 8 && c <= 256) ? c : 0
        }
        let ifd0 = tiff + u32(tiff + 4)
        guard entryCount(ifd0) > 0 else { return nil }
        // IFD0 → EXIF IFD 指针 (0x8769)
        var exifIfd = 0
        for i in 0..<entryCount(ifd0) {
            let e = ifd0 + 2 + i * 12
            guard e + 12 <= bytes.count else { return nil }
            if u16(e) == 0x8769 && u16(e + 2) == 4 {
                exifIfd = tiff + u32(e + 8)
                break
            }
        }
        guard exifIfd > 0, entryCount(exifIfd) > 0 else { return nil }
        // EXIF IFD → MakerNote 指针 (0x927C)
        var makerNote = 0
        for i in 0..<entryCount(exifIfd) {
            let e = exifIfd + 2 + i * 12
            guard e + 12 <= bytes.count else { return nil }
            if u16(e) == 0x927C {
                makerNote = tiff + u32(e + 8)
                break
            }
        }
        guard makerNote > 0, makerNote + 16 < bytes.count else { return nil }
        // Apple MakerNote 头："Apple iOS\0"(10) + 2 字节 endianness + 2 字节 pad + "MM"(2) + 条目数(2)
        let header = [UInt8](bytes[makerNote..<min(makerNote + 10, bytes.count)])
        guard header == [0x41, 0x70, 0x70, 0x6C, 0x65, 0x20, 0x69, 0x4F, 0x53, 0x00] else { return nil }
        // SRATIONAL(8字节) 数据按 offset 定位，基准是 MakerNote 头（已实测验证：
        // 多张样片键 33 均读出相同校准值 0.7844，跨条目基准则读出碎片垃圾）。
        let entriesStart = makerNote + 16
        guard bytes[makerNote + 12] == 0x4D, bytes[makerNote + 13] == 0x4D else { return nil }
        let count = u16(makerNote + 14)
        guard count > 0, count <= 256 else { return nil }
        var maker33: Double?; var maker48: Double?
        for i in 0..<count {
            let e = entriesStart + i * 12
            guard e + 12 <= bytes.count else { break }
            let key = u16(e); let type = u16(e + 2)
            guard key == 33 || key == 48, type == 10 else { continue }  // SRATIONAL
            let offset = u32(e + 8)
            let dataPos = makerNote + offset
            guard dataPos + 8 <= bytes.count else { continue }
            let n = i32(dataPos); let d = i32(dataPos + 4)
            guard d != 0 else { continue }
            let v = Double(n) / Double(d)
            if key == 33 { maker33 = v } else { maker48 = v }
        }
        guard let m33 = maker33, let m48 = maker48 else { return nil }
        return (m33, m48)
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int {
        guard !pattern.isEmpty, bytes.count > pattern.count else { return -1 }
        var i = max(from, 0)
        while i + pattern.count <= bytes.count {
            if bytes[i] == pattern[0] {
                var match = true
                for j in 1..<pattern.count where bytes[i + j] != pattern[j] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return -1
    }
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
                     allowPreviewFallback: Bool = true,
                     bandRows: Int? = nil) throws -> LoadedImage {
        var loaded = try decode(url: url, maxSize: maxSize, rawOptions: rawOptions,
                                allowEncoded: allowEncoded, rawTimeout: rawTimeout,
                                allowPreviewFallback: allowPreviewFallback,
                                bandRows: bandRows)
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
                               allowPreviewFallback: Bool,
                               bandRows: Int? = nil) throws -> LoadedImage {
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
                               cctfDecoding: false, isRaw: true, usedFallback: true)
            #else
            do {
                var options = rawOptions
                options.outputColorSpace = detected.space
                options.maxSize = maxSize
                options.bandRows = bandRows
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
        // Apple Adaptive HDR 原片（HEIC/JPG 带 HDR 增益图）：解码 SDR 基底到线性域，
        // 应用增益图还原真实场景宽动态（高光 >1.0），按线性数据交给显影管线。
        // 物理上这正是负片的工作方式：胶片记录 HDR 场景，靠密度曲线与显影映射到相纸。
        // 仅对管线有扩展线性空间定义的 sRGB / Display P3 启用，其它色彩空间退回现状。
        if detected.cctfDecoding,
           let gainMap = HDRGainMap.detect(url: url),
           let linearSpace = extendedLinearSpace(named: detected.space) {
            var image = try renderToImage(url: url, colorSpace: detected.space,
                                          linear: true, linearSpace: linearSpace)
            gainMap.apply(inPlace: &image)
            return LoadedImage(image: image, colorSpace: detected.space,
                               cctfDecoding: false, isRaw: false,
                               appliedGainMap: true)
        }
        let image = try renderToImage(url: url, colorSpace: detected.space,
                                      linear: !detected.cctfDecoding)
        return LoadedImage(image: image, colorSpace: detected.space,
                           cctfDecoding: detected.cctfDecoding, isRaw: false)
    }

    /// sRGB / Display P3 对应的扩展线性色彩空间；其它空间返回 nil（不启用增益图路径）。
    private static func extendedLinearSpace(named space: String) -> CGColorSpace? {
        switch space {
        case "sRGB":
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case "Display P3":
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        default:
            return nil
        }
    }

    /// 导入入库用的解码语义：与 `load` 的实际口径一致。
    /// 带 HDR 增益图的原片在 `load` 时会按「线性 + 应用增益图」解码（cctfDecoding = false），
    /// 库记录必须存同一语义，避免其它路径按 SDR gamma 口径误解码造成二次解码。
    static func decodingSemantics(url: URL) -> (space: String, cctfDecoding: Bool) {
        let detected = detectColorSpace(url: url)
        guard detected.cctfDecoding,
              HDRGainMap.detect(url: url) != nil,
              extendedLinearSpace(named: detected.space) != nil else {
            return detected
        }
        return (detected.space, false)
    }

    /// 用 Core Image 渲染到 RGBAf；`linear` 为 true 时用扩展线性空间
    /// （`linearSpace` 缺省为扩展线性 sRGB，增益图路径传入与源图匹配的扩展线性空间）。
    static func renderToImage(url: URL, colorSpace: String, linear: Bool,
                              linearSpace: CGColorSpace? = nil) throws -> ImageRGB {
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
            outputSpace = linearSpace
                ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
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
