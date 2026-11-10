import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ExportMetadata {
    var software: String = "spektrafilm"
    var dateTime: Date = Date()
    var make: String?
    var model: String?
    var orientation: Int = 1
    /// 源文件属性（`CGImageSourceCopyPropertiesAtIndex`），用于复制 EXIF/IPTC。
    var sourceProperties: [String: Any]?
}

/// 图像导出：TIFF（8/16/32-bit，Deflate + ICC + 基础 EXIF）、EXR（half/float 线性）、PNG/JPEG（8-bit）。
/// 对应 Python `utils/io.py::save_image_oiio` 与 `write_image_metadata`。
enum ImageExport {
    enum ExportError: Error, CustomStringConvertible {
        case unsupportedFormat(String)
        case encodeFailed(String)
        var description: String {
            switch self {
            case .unsupportedFormat(let value): return "Unsupported export format: \(value)"
            case .encodeFailed(let value): return "Export encode failed: \(value)"
            }
        }
    }

    static func save(_ image: ImageRGB, to url: URL, bitDepth: Int = 16,
                     colorSpace: String, cctfEncoding: Bool = true,
                     jpegQuality: Double = 0.95,
                     metadata: ExportMetadata = ExportMetadata()) throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tif", "tiff":
            let icc = iccProfile(colorSpace: colorSpace, cctfEncoding: cctfEncoding)
            try TiffWriter.write(image: image, to: url, bitDepth: bitDepth, icc: icc,
                                 colorSpaceTag: colorSpaceTag(colorSpace, cctfEncoding),
                                 metadata: metadata)
        case "exr":
            try EXRWriter.write(image: image, to: url, bitDepth: bitDepth)
        case "png":
            try writeViaImageIO(image: image, to: url, ext: ext,
                                colorSpace: colorSpace, metadata: metadata)
        case "jpg", "jpeg":
            // 导出侧支持 JPEG；导入侧仍按硬约束只收 RAW。
            try writeViaImageIO(image: image, to: url, ext: "jpg",
                                colorSpace: colorSpace, jpegQuality: jpegQuality,
                                metadata: metadata)
        default:
            throw ExportError.unsupportedFormat(ext)
        }
    }

    // MARK: - ICC / EXIF helpers

    static let iccFiles: [String: String] = [
        "sRGB|true": "ellelstone/sRGB-elle-V2-srgbtrc.icc",
        "sRGB|false": "ellelstone/sRGB-elle-V2-g10.icc",
        "Adobe RGB (1998)|true": "ellelstone/ClayRGB-elle-V2-g22.icc",
        "Adobe RGB (1998)|false": "ellelstone/ClayRGB-elle-V2-g10.icc",
        "ProPhoto RGB|true": "ellelstone/LargeRGB-elle-V2-g18.icc",
        "ProPhoto RGB|false": "ellelstone/LargeRGB-elle-V2-g10.icc",
        "ITU-R BT.2020|true": "ellelstone/Rec2020-elle-V2-rec709.icc",
        "ITU-R BT.2020|false": "ellelstone/Rec2020-elle-V2-g10.icc",
        "ACES2065-1|true": "ellelstone/ACES-elle-V2-g10.icc",
        "ACES2065-1|false": "ellelstone/ACES-elle-V2-g10.icc",
        "Display P3|true": "saucecontrol/DisplayP3-v2-micro.icc",
        "DCI-P3|true": "saucecontrol/DCI-P3-v4.icc",
    ]

    static func iccProfile(colorSpace: String, cctfEncoding: Bool) -> Data? {
        guard let relative = iccFiles["\(colorSpace)|\(cctfEncoding)"] else { return nil }
        let url = ResourceLocator.url("icc/" + relative)
        return try? Data(contentsOf: url)
    }

    static func colorSpaceTag(_ colorSpace: String, _ cctfEncoding: Bool) -> UInt16 {
        if colorSpace == "sRGB" && cctfEncoding { return 1 }
        return 65535
    }

    static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - PNG / JPEG

    static func writeViaImageIO(image: ImageRGB, to url: URL, ext: String,
                                colorSpace: String,
                                jpegQuality: Double = 0.95,
                                metadata: ExportMetadata) throws {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 {
                let value = image.data[i * 3 + c]
                let clipped = min(max(value, 0), 1) * 255
                pixels[i * 4 + c] = UInt8(clipped.rounded())
            }
            pixels[i * 4 + 3] = 255
        }
        let space: CGColorSpace
        if let icc = iccProfile(colorSpace: colorSpace, cctfEncoding: true),
           let profile = CGColorSpace(iccData: icc as CFData) {
            space = profile
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let cgImage: CGImage? = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let cgImage else {
            throw ExportError.encodeFailed("CGImage")
        }
        let type: UTType = (ext == "png") ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil
        ) else {
            throw ExportError.encodeFailed("destination")
        }
        var properties = exifProperties(metadata)
        if ext == "jpg" || ext == "jpeg" {
            properties[kCGImageDestinationLossyCompressionQuality as String]
                = min(max(jpegQuality, 0), 1)
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodeFailed("finalize")
        }
    }

    static func exifProperties(_ metadata: ExportMetadata) -> [String: Any] {
        var exif = (metadata.sourceProperties?[kCGImagePropertyExifDictionary as String]
            as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal as String] = dateTimeString(metadata.dateTime)
        exif["Software"] = metadata.software
        var tiff = (metadata.sourceProperties?[kCGImagePropertyTIFFDictionary as String]
            as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = metadata.software
        tiff[kCGImagePropertyTIFFDateTime as String] = dateTimeString(metadata.dateTime)
        tiff[kCGImagePropertyTIFFOrientation as String] = metadata.orientation
        if let make = metadata.make { tiff[kCGImagePropertyTIFFMake as String] = make }
        if let model = metadata.model { tiff[kCGImagePropertyTIFFModel as String] = model }
        var result: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
        ]
        if let iptc = metadata.sourceProperties?[kCGImagePropertyIPTCDictionary as String] {
            result[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        return result
    }

    /// 读取源图属性，供导出时复制 EXIF/IPTC。
    static func sourceProperties(url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }
}

// MARK: - TIFF writer

enum TiffWriter {
    static func write(image: ImageRGB, to url: URL, bitDepth: Int, icc: Data?,
                      colorSpaceTag: UInt16, metadata: ExportMetadata) throws {
        let width = image.width
        let height = image.height
        let sampleFormat: UInt16

        let raw: Data
        switch bitDepth {
        case 8:
            var values = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height * 3) {
                let raw = image.data[i]
                let clipped = (raw.isFinite ? min(max(raw, 0), 1) : 0) * 255
                values[i] = UInt8(clipped.rounded())
            }
            raw = values.withUnsafeBytes { Data($0) }
            sampleFormat = 1
        case 16:
            var values = [UInt16](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height * 3) {
                let raw = image.data[i]
                let clipped = (raw.isFinite ? min(max(raw, 0), 1) : 0) * 65535
                values[i] = UInt16(clipped.rounded())
            }
            raw = values.withUnsafeBytes { Data($0) }
            sampleFormat = 1
        case 32:
            var values = [Float](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height * 3) { values[i] = Float(image.data[i]) }
            raw = values.withUnsafeBytes { Data($0) }
            sampleFormat = 3
        default:
            throw ImageExport.ExportError.unsupportedFormat("TIFF bit depth \(bitDepth)")
        }

        let compressed = Deflate.compress(raw)
        let compression: UInt16 = compressed != nil ? 8 : 1
        let stripBytes = compressed ?? raw
        let software = Data((metadata.software + "\0").utf8)
        let dateTime = Data((ImageExport.dateTimeString(metadata.dateTime) + "\0").utf8)
        let make = metadata.make.map { Data(($0 + "\0").utf8) }
        let model = metadata.model.map { Data(($0 + "\0").utf8) }

        // IFD0 entries.
        var entries: [Entry] = []
        entries.append(Entry(256, 4, 1, UInt32(width)))
        entries.append(Entry(257, 4, 1, UInt32(height)))
        entries.append(Entry(258, 3, 3, 0)) // bits per sample
        entries.append(Entry(259, 3, 1, UInt32(compression)))
        entries.append(Entry(262, 3, 1, 2))
        entries.append(Entry(273, 4, 1, 0)) // strip offset
        entries.append(Entry(274, 3, 1, UInt32(metadata.orientation)))
        entries.append(Entry(277, 3, 1, 3))
        entries.append(Entry(278, 4, 1, UInt32(height)))
        entries.append(Entry(279, 4, 1, UInt32(stripBytes.count)))
        entries.append(Entry(284, 3, 1, 1))
        entries.append(Entry(305, 2, UInt32(software.count), 0))
        entries.append(Entry(306, 2, UInt32(dateTime.count), 0))
        entries.append(Entry(339, 3, 3, 0)) // sample format
        if let make { entries.append(Entry(271, 2, UInt32(make.count), 0)) }
        if let model { entries.append(Entry(272, 2, UInt32(model.count), 0)) }
        entries.append(Entry(34665, 4, 1, 0)) // EXIF IFD
        if icc != nil { entries.append(Entry(34675, 7, UInt32(icc!.count), 0)) }
        entries.sort { $0.tag < $1.tag }

        let headerSize = 8
        let stripOffset = headerSize
        let ifdOffset = even(stripOffset + stripBytes.count)
        let ifdSize = 2 + entries.count * 12 + 4
        var cursor = ifdOffset + ifdSize

        let bitsPerSampleOffset = cursor
        cursor += 6
        let sampleFormatOffset = cursor
        cursor += 6
        cursor = even(cursor)
        let softwareOffset = cursor
        cursor += software.count
        cursor = even(cursor)
        let dateTimeOffset = cursor
        cursor += dateTime.count
        var makeOffset = 0
        var modelOffset = 0
        if let make {
            cursor = even(cursor)
            makeOffset = cursor
            cursor += make.count
        }
        if let model {
            cursor = even(cursor)
            modelOffset = cursor
            cursor += model.count
        }
        var iccOffset = 0
        if let icc {
            cursor = even(cursor)
            iccOffset = cursor
            cursor += icc.count
        }
        cursor = even(cursor)
        let exifOffset = cursor
        let exifSize = 2 + 4 * 12 + 4
        cursor += exifSize
        let interopOffset = cursor
        let interopSize = 2 + 1 * 12 + 4
        cursor += interopSize
        let interopStringOffset = cursor
        cursor += 4
        let fileSize = cursor

        var data = Data(capacity: fileSize)
        data.append(0x49)
        data.append(0x49) // "II"
        data.appendUInt16(42)
        data.appendUInt32(UInt32(ifdOffset))
        data.append(stripBytes)
        if data.count < ifdOffset { data.appendZeros(ifdOffset - data.count) }

        data.appendUInt16(UInt16(entries.count))
        for entry in entries {
            data.appendUInt16(entry.tag)
            data.appendUInt16(entry.type)
            data.appendUInt32(entry.count)
            switch entry.tag {
            case 258:
                data.appendUInt32(UInt32(bitsPerSampleOffset))
            case 273:
                data.appendUInt32(UInt32(stripOffset))
            case 305:
                data.appendUInt32(UInt32(softwareOffset))
            case 306:
                data.appendUInt32(UInt32(dateTimeOffset))
            case 339:
                data.appendUInt32(UInt32(sampleFormatOffset))
            case 271:
                data.appendUInt32(UInt32(makeOffset))
            case 272:
                data.appendUInt32(UInt32(modelOffset))
            case 34665:
                data.appendUInt32(UInt32(exifOffset))
            case 34675:
                data.appendUInt32(UInt32(iccOffset))
            default:
                if entry.type == 3 && entry.count <= 2 {
                    data.appendUInt16(UInt16(entry.value))
                    data.appendUInt16(0)
                } else {
                    data.appendUInt32(entry.value)
                }
            }
        }
        data.appendUInt32(0)

        // External IFD0 values.
        if data.count < bitsPerSampleOffset { data.appendZeros(bitsPerSampleOffset - data.count) }
        for _ in 0..<3 { data.appendUInt16(UInt16(bitDepth)) }
        if data.count < sampleFormatOffset { data.appendZeros(sampleFormatOffset - data.count) }
        for _ in 0..<3 { data.appendUInt16(sampleFormat) }
        if data.count < softwareOffset { data.appendZeros(softwareOffset - data.count) }
        data.append(software)
        if data.count < dateTimeOffset { data.appendZeros(dateTimeOffset - data.count) }
        data.append(dateTime)
        if let make {
            if data.count < makeOffset { data.appendZeros(makeOffset - data.count) }
            data.append(make)
        }
        if let model {
            if data.count < modelOffset { data.appendZeros(modelOffset - data.count) }
            data.append(model)
        }
        if let icc {
            if data.count < iccOffset { data.appendZeros(iccOffset - data.count) }
            data.append(icc)
        }
        if data.count < exifOffset { data.appendZeros(exifOffset - data.count) }

        // EXIF IFD.
        data.appendUInt16(4)
        data.appendUInt16(40961); data.appendUInt16(3); data.appendUInt32(1); data.appendUInt32(UInt32(colorSpaceTag))
        data.appendUInt16(40962); data.appendUInt16(4); data.appendUInt32(1); data.appendUInt32(UInt32(width))
        data.appendUInt16(40963); data.appendUInt16(4); data.appendUInt32(1); data.appendUInt32(UInt32(height))
        data.appendUInt16(40965); data.appendUInt16(4); data.appendUInt32(1); data.appendUInt32(UInt32(interopOffset))
        data.appendUInt32(0)

        // Interop IFD.
        data.appendUInt16(1)
        data.appendUInt16(1); data.appendUInt16(2); data.appendUInt32(4); data.appendUInt32(UInt32(interopStringOffset))
        data.appendUInt32(0)
        data.append(0x52)
        data.append(0x39)
        data.append(0x38)
        data.append(0x00)

        try data.write(to: url)
    }

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let value: UInt32
        init(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            self.tag = tag
            self.type = type
            self.count = count
            self.value = value
        }
    }

    static func even(_ value: Int) -> Int { value % 2 == 0 ? value : value + 1 }
}

// MARK: - EXR writer

enum EXRWriter {
    static func write(image: ImageRGB, to url: URL, bitDepth: Int) throws {
        let half = bitDepth <= 16
        if bitDepth != 16 && bitDepth != 32 {
            throw ImageExport.ExportError.unsupportedFormat("EXR bit depth \(bitDepth)")
        }
        let width = image.width
        let height = image.height

        var header = Data()
        header.appendUInt32(20000630)
        header.appendUInt32(2)
        var attributes = Data()
        attributes.appendAttribute(name: "channels", type: "chlist", payload: channelList(half: half))
        attributes.appendAttribute(name: "compression", type: "compression", payload: Data([0]))
        attributes.appendAttribute(name: "dataWindow", type: "box2i", payload: box2i(width: width, height: height))
        attributes.appendAttribute(name: "displayWindow", type: "box2i", payload: box2i(width: width, height: height))
        attributes.appendAttribute(name: "lineOrder", type: "lineOrder", payload: Data([0]))
        attributes.appendAttribute(name: "pixelAspectRatio", type: "float", payload: floatData(1.0))
        attributes.appendAttribute(name: "screenWindowCenter", type: "v2f", payload: floatData(0) + floatData(0))
        attributes.appendAttribute(name: "screenWindowWidth", type: "float", payload: floatData(1.0))
        attributes.append(0) // end of header
        header.append(attributes)

        let offsetTableSize = height * 8
        var offsetTable = Data()
        var blocks: [Data] = []
        var position = header.count + offsetTableSize
        let channelBytes = half ? 2 : 4
        let rowBytes = width * 3 * channelBytes
        for y in 0..<height {
            var block = Data()
            block.appendUInt32(UInt32(y))
            block.appendUInt32(UInt32(rowBytes))
            // EXR 扫描线按通道分块存储：B 行、G 行、R 行（与 chlist 顺序一致）。
            for c in [2, 1, 0] {
                for x in 0..<width {
                    let pixel = (y * width + x) * 3
                    let value = Double(image.data[pixel + c])
                    if half {
                        block.appendUInt16(EXRWriter.halfBits(from: Float(value)))
                    } else {
                        block.append(floatData(value))
                    }
                }
            }
            offsetTable.appendUInt64(UInt64(position))
            blocks.append(block)
            position += block.count
        }

        var output = header
        output.append(offsetTable)
        for block in blocks { output.append(block) }
        try output.write(to: url)
    }

    static func channelList(half: Bool) -> Data {
        var data = Data()
        for name in ["B", "G", "R"] {
            data.append(contentsOf: Data(name.utf8))
            data.append(0)
            data.appendUInt32(half ? 1 : 2)
            data.append(0)
            data.append(contentsOf: [0, 0, 0])
            data.appendUInt32(1)
            data.appendUInt32(1)
        }
        data.append(0)
        return data
    }

    static func box2i(width: Int, height: Int) -> Data {
        var data = Data()
        data.appendUInt32(0)
        data.appendUInt32(0)
        data.appendUInt32(UInt32(width - 1))
        data.appendUInt32(UInt32(height - 1))
        return data
    }

    static func floatData(_ value: Double) -> Data {
        var bits = UInt32(Float(value).bitPattern)
        return Data(bytes: &bits, count: 4)
    }

    static func halfBits(from value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF)
        let mantissa = bits & 0x7FFFFF
        if exponent == 255 {
            return sign | 0x7C00 | (mantissa != 0 ? 0x0200 : 0)
        }
        var exp = exponent - 127 + 15
        if exp >= 31 {
            return sign | 0x7C00
        }
        if exp <= 0 {
            if exp < -10 { return sign }
            let shifted = (mantissa | 0x800000) >> UInt32(1 - exp)
            let rounded = (shifted + 0x1000) >> 13
            return sign | UInt16(rounded)
        }
        var result = sign | UInt16(exp << 10) | UInt16(mantissa >> 13)
        if mantissa & 0x1FFF >= 0x1000 {
            result += 1
            if (result & 0x7C00) == 0x7C00 { result = sign | 0x7C00 }
        }
        return result
    }
}

// MARK: - Deflate

enum Deflate {
    typealias Compress2Fn = @convention(c) (
        UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt>?,
        UnsafePointer<UInt8>?, UInt, Int32
    ) -> Int32

    /// 直接调用系统 zlib（避免 `Compression` 模块与当前工具链的 SDK 版本冲突），
    /// 输出标准 zlib 流，对应 TIFF Compression=8（Adobe Deflate）。
    static let compress2: Compress2Fn? = {
        guard let handle = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "compress2") else { return nil }
        return unsafeBitCast(symbol, to: Compress2Fn.self)
    }()

    static func compress(_ data: Data) -> Data? {
        guard let function = compress2, !data.isEmpty else { return nil }
        let bound = data.count + data.count / 2 + 64
        var output = Data(count: bound)
        var outputLength = UInt(bound)
        let status: Int32 = output.withUnsafeMutableBytes { destination -> Int32 in
            guard let dst = destination.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return data.withUnsafeBytes { source -> Int32 in
                guard let src = source.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return function(dst, &outputLength, src, UInt(data.count), 6)
            }
        }
        guard status == 0 else { return nil }
        return output.prefix(Int(outputLength))
    }
}

// MARK: - Binary helpers

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendZeros(_ count: Int) {
        append(Data(repeating: 0, count: count))
    }

    mutating func appendAttribute(name: String, type: String, payload: Data) {
        append(contentsOf: Data(name.utf8))
        append(0)
        append(contentsOf: Data(type.utf8))
        append(0)
        appendUInt32(UInt32(payload.count))
        append(payload)
    }
}