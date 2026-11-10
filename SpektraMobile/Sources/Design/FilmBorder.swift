import Foundation
import CoreGraphics
import CoreText
import SwiftUI

// MARK: - 片边选项设计
//
// 片边不是滤镜：它按真实底片的机械尺寸换算。
// 135 画幅 36×24mm、胶片宽 35mm、KS 齿孔 2.79×1.98mm、孔距 4.75mm；
// 120 无齿孔，片宽约 61mm、画面宽 56mm；
// 4×5 页片靠片夹导轨留边，并在片边打缺口码。
// 所有尺寸都以「照片长边 = 该规格画幅长边」换算成 px/mm，再按比例落笔。

enum MFilmBorderGauge: String, CaseIterable, Identifiable {
    case full135
    case half135
    case roll645
    case roll66
    case roll67
    case roll69
    case sheet45
    case cart110
    case cine16
    case cine35

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full135: return "135 全画幅"
        case .half135: return "135 半格"
        case .roll645: return "120 645"
        case .roll66: return "120 6×6"
        case .roll67: return "120 6×7"
        case .roll69: return "120 6×9"
        case .sheet45: return "4×5 页片"
        case .cart110: return "110 暗盒"
        case .cine16: return "16mm 电影"
        case .cine35: return "35mm 电影"
        }
    }

    /// 画幅长边 / 短边（mm）。照片长边按长边规格等比换算。
    var frameLongMM: Double {
        switch self {
        case .full135: return 36
        case .half135: return 24
        case .roll645: return 56
        case .roll66: return 56
        case .roll67: return 70
        case .roll69: return 84
        case .sheet45: return 127
        case .cart110: return 17
        case .cine16: return 10.26
        case .cine35: return 22
        }
    }

    /// 齿孔边到画幅边的留边（mm），已按规格取半宽。
    var marginPerfMM: Double {
        switch self {
        case .full135: return 5.5
        case .half135: return 8.5
        case .roll645, .roll66, .roll67, .roll69: return 2.5
        case .sheet45: return 3.5
        case .cart110: return 1.5
        case .cine16: return 4.25
        case .cine35: return 9.5
        }
    }

    /// 画幅两端的留边（mm），即上下片之间的间隔摊到单侧。
    var marginEndMM: Double {
        switch self {
        case .full135, .half135: return 2.0
        case .roll645, .roll66, .roll67, .roll69: return 2.5
        case .sheet45: return 4.0
        case .cart110: return 2.0
        case .cine16: return 1.0
        case .cine35: return 2.0
        }
    }

    var defaultPerf: MFilmBorderPerf {
        switch self {
        case .full135: return .ks
        case .half135: return .ks
        case .roll645, .roll66, .roll67, .roll69: return .none
        case .sheet45: return .none
        case .cart110: return .single110
        case .cine16: return .single16
        case .cine35: return .bh
        }
    }

    var defaultBase: MFilmBorderBase {
        switch self {
        case .sheet45: return .bw
        case .cine16, .cine35: return .reversal
        default: return .colorNegative
        }
    }

    var isSheet: Bool { self == .sheet45 }
}

enum MFilmBorderPerf: String, CaseIterable, Identifiable {
    case auto
    case none
    case ks
    case bh
    case cs
    case single126
    case single110
    case single16

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "随规格"
        case .none: return "无齿孔"
        case .ks: return "KS-1870"
        case .bh: return "BH-1866"
        case .cs: return "CS 电影孔"
        case .single126: return "126 单孔"
        case .single110: return "110 单孔"
        case .single16: return "16mm 单孔"
        }
    }

    /// 孔长（沿片长方向，mm）
    var lengthMM: Double {
        switch self {
        case .ks, .bh, .cs: return 2.79
        case .single126: return 4.8
        case .single110: return 3.0
        case .single16: return 1.83
        case .auto, .none: return 0
        }
    }

    /// 孔高（跨片宽方向，mm）
    var heightMM: Double {
        switch self {
        case .ks: return 1.98
        case .bh: return 1.85
        case .cs: return 1.85
        case .single126: return 4.8
        case .single110: return 2.0
        case .single16: return 1.37
        case .auto, .none: return 0
        }
    }

    /// 孔距（mm）
    var pitchMM: Double {
        switch self {
        case .ks, .bh, .cs: return 4.75
        case .single126: return 28
        case .single110: return 17
        case .single16: return 7.62
        case .auto, .none: return 0
        }
    }

    var isSingle: Bool {
        switch self {
        case .single126, .single110, .single16: return true
        default: return false
        }
    }

    /// 单孔规格只在一侧片边打孔；KS/BH 两侧都有。
    var isOneEdge: Bool {
        switch self {
        case .single110, .single16: return true
        default: return false
        }
    }
}

enum MFilmBorderCorner: String, CaseIterable, Identifiable {
    case square
    case rounded
    case chamfer
    case ear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return "方角"
        case .rounded: return "圆角"
        case .chamfer: return "切角"
        case .ear: return "耳角"
        }
    }
}

enum MFilmBorderBase: String, CaseIterable, Identifiable {
    case colorNegative
    case bw
    case reversal
    case clear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colorNegative: return "彩负片基"
        case .bw: return "黑白片基"
        case .reversal: return "反转片基"
        case .clear: return "透明片基"
        }
    }
}

enum MFilmBorderTextTone: String, CaseIterable, Identifiable {
    case auto
    case orange
    case green
    case white
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "随胶片"
        case .orange: return "柯达橙"
        case .green: return "富士绿"
        case .white: return "暖白"
        case .black: return "深黑"
        }
    }
}

// MARK: - 片边参数

struct MFilmBorderConfig: Codable, Hashable {
    var enabled: Bool = false
    var preset: String = "kodak135"
    var gauge: String = MFilmBorderGauge.full135.rawValue
    var borderScale: Double = 1.0
    var corner: String = MFilmBorderCorner.rounded.rawValue
    var cornerScale: Double = 1.0
    var perf: String = MFilmBorderPerf.auto.rawValue
    var perfScale: Double = 1.0
    var perfPitch: Double = 1.0
    var perfBrightness: Double = 0.0
    var baseTone: String = MFilmBorderBase.colorNegative.rawValue
    var baseBrightness: Double = 0.0
    var edgeText: Bool = true
    var customText: String = ""
    var textTone: String = MFilmBorderTextTone.auto.rawValue
    var textScale: Double = 1.0
    var frameNumbers: Bool = true
    var dxCode: Bool = true
    var notch: Bool = true
    var scratches: Double = 0.18
    var dust: Double = 0.14
    var fog: Double = 0.10

    static let off = MFilmBorderConfig()

    var gaugeValue: MFilmBorderGauge {
        MFilmBorderGauge(rawValue: gauge) ?? .full135
    }

    var perfValue: MFilmBorderPerf {
        let value = MFilmBorderPerf(rawValue: perf) ?? .auto
        return value == .auto ? gaugeValue.defaultPerf : value
    }

    /// 编码/外部输入一律先夹到安全区间，避免极端参数把片边撑成整屏黑边。
    func normalized() -> MFilmBorderConfig {
        var value = self
        if MFilmBorderGauge(rawValue: value.gauge) == nil {
            value.gauge = MFilmBorderGauge.full135.rawValue
        }
        if MFilmBorderCorner(rawValue: value.corner) == nil {
            value.corner = MFilmBorderCorner.rounded.rawValue
        }
        if MFilmBorderPerf(rawValue: value.perf) == nil {
            value.perf = MFilmBorderPerf.auto.rawValue
        }
        if MFilmBorderBase(rawValue: value.baseTone) == nil {
            value.baseTone = MFilmBorderBase.colorNegative.rawValue
        }
        if MFilmBorderTextTone(rawValue: value.textTone) == nil {
            value.textTone = MFilmBorderTextTone.auto.rawValue
        }
        value.borderScale = min(max(value.borderScale, 0.4), 2.0)
        value.cornerScale = min(max(value.cornerScale, 0.0), 3.0)
        value.perfScale = min(max(value.perfScale, 0.5), 1.8)
        value.perfPitch = min(max(value.perfPitch, 0.5), 2.0)
        value.perfBrightness = min(max(value.perfBrightness, -1.0), 1.0)
        value.baseBrightness = min(max(value.baseBrightness, -1.0), 1.0)
        value.textScale = min(max(value.textScale, 0.5), 2.5)
        value.scratches = min(max(value.scratches, 0.0), 1.0)
        value.dust = min(max(value.dust, 0.0), 1.0)
        value.fog = min(max(value.fog, 0.0), 1.0)
        value.customText = String(value.customText.prefix(28))
        return value
    }

    func matches(_ other: MFilmBorderConfig) -> Bool {
        var lhs = normalized()
        var rhs = other.normalized()
        lhs.preset = ""
        rhs.preset = ""
        return lhs == rhs
    }
}

// MARK: - 片边预设

struct MFilmBorderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let config: MFilmBorderConfig

    static let none = MFilmBorderPreset(
        id: "none", name: "无片边", note: "关闭",
        config: {
            var value = MFilmBorderConfig()
            value.enabled = false
            value.preset = "none"
            return value
        }()
    )

    static let all: [MFilmBorderPreset] = [
        none,
        MFilmBorderPreset(
            id: "kodak135", name: "135 柯达", note: "KS 齿孔 · DX",
            config: presetConfig("kodak135", gauge: .full135, base: .colorNegative,
                                 corner: .rounded, tone: .auto, dx: true)
        ),
        MFilmBorderPreset(
            id: "fuji135", name: "135 富士", note: "KS 齿孔 · 绿边字",
            config: presetConfig("fuji135", gauge: .full135, base: .colorNegative,
                                 corner: .rounded, tone: .green, dx: true)
        ),
        MFilmBorderPreset(
            id: "bw135", name: "135 黑白", note: "灰片基 · 白边字",
            config: presetConfig("bw135", gauge: .full135, base: .bw,
                                 corner: .square, tone: .white, dx: true)
        ),
        MFilmBorderPreset(
            id: "cine135", name: "35mm 电影", note: "BH 齿孔 · 宽片边",
            config: presetConfig("cine135", gauge: .cine35, base: .reversal,
                                 corner: .square, tone: .white, dx: false)
        ),
        MFilmBorderPreset(
            id: "roll120", name: "120 中画幅", note: "无边孔 · 编号",
            config: presetConfig("roll120", gauge: .roll66, base: .colorNegative,
                                 corner: .square, tone: .auto, dx: false)
        ),
        MFilmBorderPreset(
            id: "sheet45", name: "4×5 页片", note: "片缺口 · 导轨边",
            config: presetConfig("sheet45", gauge: .sheet45, base: .bw,
                                 corner: .square, tone: .white, dx: false)
        ),
    ]

    private static func presetConfig(
        _ id: String,
        gauge: MFilmBorderGauge,
        base: MFilmBorderBase,
        corner: MFilmBorderCorner,
        tone: MFilmBorderTextTone,
        dx: Bool
    ) -> MFilmBorderConfig {
        var value = MFilmBorderConfig()
        value.enabled = true
        value.preset = id
        value.gauge = gauge.rawValue
        value.baseTone = base.rawValue
        value.corner = corner.rawValue
        value.textTone = tone.rawValue
        value.dxCode = dx
        value.notch = gauge.isSheet
        // 4×5 页片没有连续边字，只有缺口码；打开会压住缺口。
        value.edgeText = !gauge.isSheet
        value.perf = MFilmBorderPerf.auto.rawValue
        return value
    }

    static func preset(id: String) -> MFilmBorderPreset? {
        all.first { $0.id == id }
    }

    static func name(for config: MFilmBorderConfig) -> String {
        guard config.enabled else { return "无片边" }
        if let match = all.first(where: { $0.id != "none" && $0.config.matches(config) }) {
            return match.name
        }
        return "自定义"
    }
}

// MARK: - 几何

struct MFilmBorderLayout {
    let photo: CGSize
    let canvas: CGSize
    let aperture: CGRect
    let marginX: CGFloat
    let marginY: CGFloat
    let pxPerMM: CGFloat
    /// 齿孔沿照片长边排列；横向照片的齿孔在上下边，竖向照片在左右边。
    let alongX: Bool
    let gauge: MFilmBorderGauge
}

// MARK: - 渲染器

enum MFilmBorderRenderer {
    // MARK: 预览

    static func preview(photo: CGImage, config: MFilmBorderConfig,
                        filmID: String, photoID: String) -> CGImage? {
        let value = config.normalized()
        guard value.enabled else { return photo }
        let layout = layout(for: CGSize(width: photo.width, height: photo.height), config: value)
        let width = max(1, Int(layout.canvas.width.rounded()))
        let height = max(1, Int(layout.canvas.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        draw(in: context, layout: layout, config: value,
             photo: photo, punch: false, filmID: filmID, photoID: photoID)
        return context.makeImage()
    }

    // MARK: 导出

    /// 把片边合成进导出像素。片边是 sRGB 图形，先按 sRGB 栅格化，
    /// 再把非透明像素转到目标色彩空间后与照片混合，保证 ProPhoto / ACES 导出不串色。
    static func composite(image: ImageRGB, config: MFilmBorderConfig,
                          filmID: String, photoID: String,
                          colorSpace: String, cctfEncoding: Bool) -> ImageRGB {
        let value = config.normalized()
        guard value.enabled else { return image }
        let layout = layout(for: CGSize(width: image.width, height: image.height), config: value)
        let width = max(1, Int(layout.canvas.width.rounded()))
        let height = max(1, Int(layout.canvas.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        context.interpolationQuality = .high
        draw(in: context, layout: layout, config: value,
             photo: nil, punch: true, filmID: filmID, photoID: photoID)
        guard let buffer = context.data else { return image }

        var output = ImageRGB(width: width, height: height)
        let offsetX = Int(layout.aperture.minX.rounded())
        let offsetY = Int(layout.aperture.minY.rounded())
        let photoWidth = image.width
        let photoHeight = image.height
        output.data.withUnsafeMutableBufferPointer { destination in
            image.data.withUnsafeBufferPointer { source in
                guard let dst = destination.baseAddress,
                      let src = source.baseAddress else { return }
                for row in 0..<photoHeight {
                    let target = ((row + offsetY) * width + offsetX) * 3
                    let origin = row * photoWidth * 3
                    dst.advanced(by: target).update(from: src.advanced(by: origin),
                                                    count: photoWidth * 3)
                }
            }
        }

        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let needsConversion = !(colorSpace == "sRGB" && cctfEncoding)
        var cache: [UInt32: Vec3] = [:]
        let sRGBKind = ColorMath.cctfKind(for: "sRGB")
        let outKind = ColorMath.cctfKind(for: colorSpace)

        output.data.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            for index in 0..<(width * height) {
                let alpha = Double(pixels[index * 4 + 3]) / 255.0
                guard alpha > 0 else { continue }
                let invAlpha = 1.0 / alpha
                let channels = (
                    UInt8(min(255, max(0, Double(pixels[index * 4]) * invAlpha))),
                    UInt8(min(255, max(0, Double(pixels[index * 4 + 1]) * invAlpha))),
                    UInt8(min(255, max(0, Double(pixels[index * 4 + 2]) * invAlpha)))
                )
                let converted: Vec3
                if needsConversion {
                    let key = (UInt32(channels.0) << 16) | (UInt32(channels.1) << 8) | UInt32(channels.2)
                    if let cached = cache[key] {
                        converted = cached
                    } else {
                        let linear = Vec3(
                            ColorMath.cctfDecode(Double(channels.0) / 255.0, kind: sRGBKind),
                            ColorMath.cctfDecode(Double(channels.1) / 255.0, kind: sRGBKind),
                            ColorMath.cctfDecode(Double(channels.2) / 255.0, kind: sRGBKind)
                        )
                        var target = ColorMath.rgbToRGB(linear, from: "sRGB", to: colorSpace)
                        if cctfEncoding {
                            target = Vec3(
                                ColorMath.cctfEncode(target.x, kind: outKind),
                                ColorMath.cctfEncode(target.y, kind: outKind),
                                ColorMath.cctfEncode(target.z, kind: outKind)
                            )
                        }
                        converted = target
                        if cache.count < 131_072 { cache[key] = target }
                    }
                } else {
                    converted = Vec3(Double(channels.0) / 255.0,
                                     Double(channels.1) / 255.0,
                                     Double(channels.2) / 255.0)
                }
                let target = index * 3
                let keep = 1.0 - alpha
                dst[target] = Float(converted.x * alpha + Double(dst[target]) * keep)
                dst[target + 1] = Float(converted.y * alpha + Double(dst[target + 1]) * keep)
                dst[target + 2] = Float(converted.z * alpha + Double(dst[target + 2]) * keep)
            }
        }
        return output
    }

    // MARK: 参数换算

    static func layout(for photo: CGSize, config: MFilmBorderConfig) -> MFilmBorderLayout {
        let gauge = config.gaugeValue
        let longSide = max(photo.width, photo.height)
        let shortSide = min(photo.width, photo.height)
        let pxPerMM = longSide / CGFloat(gauge.frameLongMM)
        var marginPerf = CGFloat(gauge.marginPerfMM) * pxPerMM * CGFloat(config.borderScale)
        var marginEnd = CGFloat(gauge.marginEndMM) * pxPerMM * CGFloat(config.borderScale)
        // 极端画幅（全景、16mm 电影）按真实尺寸会留下过宽的片边；压到肉眼还能接受的上限。
        marginPerf = min(marginPerf, shortSide * 0.30)
        marginEnd = min(marginEnd, longSide * 0.12)
        let alongX = photo.width >= photo.height
        let marginX = alongX ? marginEnd : marginPerf
        let marginY = alongX ? marginPerf : marginEnd
        let canvas = CGSize(width: photo.width + marginX * 2, height: photo.height + marginY * 2)
        let aperture = CGRect(x: marginX, y: marginY, width: photo.width, height: photo.height)
        return MFilmBorderLayout(
            photo: photo, canvas: canvas, aperture: aperture,
            marginX: marginX, marginY: marginY, pxPerMM: pxPerMM,
            alongX: alongX, gauge: gauge
        )
    }

    // MARK: 绘制

    private static func draw(in context: CGContext, layout: MFilmBorderLayout,
                             config: MFilmBorderConfig, photo: CGImage?, punch: Bool,
                             filmID: String, photoID: String) {
        let width = layout.canvas.width
        let height = layout.canvas.height
        context.saveGState()
        // 换成左上角原点，后续全部用「从上往下」的坐标排布。
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)

        let base = baseRGB(config)
        context.setFillColor(red: base.0, green: base.1, blue: base.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawBaseTexture(context, layout: layout, config: config, base: base)

        let aperture = aperturePath(layout, config: config)
        if punch {
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(aperture)
            context.fillPath()
            context.restoreGState()
        } else if let photo {
            context.saveGState()
            context.addPath(aperture)
            context.clip()
            context.translateBy(x: layout.aperture.minX, y: layout.aperture.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(photo, in: CGRect(x: 0, y: 0,
                                           width: layout.aperture.width,
                                           height: layout.aperture.height))
            context.restoreGState()
        }

        // 画幅边缘的密度线：真实扫描里画幅与片基之间总有一道更深的边。
        context.saveGState()
        context.addPath(aperture)
        context.setStrokeColor(red: 0.02, green: 0.015, blue: 0.01,
                               alpha: punch ? 0.55 : 0.65)
        context.setLineWidth(max(0.6, layout.pxPerMM * 0.12))
        context.strokePath()
        context.restoreGState()

        let perfColor = perfRGB(config)
        drawPerforations(context, layout: layout, config: config, color: perfColor)
        if config.edgeText || config.frameNumbers || config.dxCode {
            drawEdgeText(context, layout: layout, config: config,
                         filmID: filmID, photoID: photoID)
        }
        if config.gaugeValue.isSheet, config.notch {
            drawNotchCode(context, layout: layout, config: config)
        }
        drawWear(context, layout: layout, config: config, photoID: photoID)
        drawEdgeFog(context, layout: layout, config: config)

        context.restoreGState()
    }

    // MARK: 片基

    private static func baseRGB(_ config: MFilmBorderConfig) -> (CGFloat, CGFloat, CGFloat) {
        let tone = MFilmBorderBase(rawValue: config.baseTone) ?? .colorNegative
        var rgb: (Double, Double, Double)
        switch tone {
        case .colorNegative: rgb = (0.112, 0.074, 0.045)
        case .bw: rgb = (0.070, 0.069, 0.064)
        case .reversal: rgb = (0.028, 0.026, 0.022)
        case .clear: rgb = (0.60, 0.46, 0.29)
        }
        let gain = 1.0 + config.baseBrightness * 0.45
        rgb = (rgb.0 * gain, rgb.1 * gain, rgb.2 * gain)
        return (
            CGFloat(min(max(rgb.0, 0.01), 0.92)),
            CGFloat(min(max(rgb.1, 0.01), 0.92)),
            CGFloat(min(max(rgb.2, 0.01), 0.92))
        )
    }

    private static func baseLuminance(_ config: MFilmBorderConfig) -> CGFloat {
        let rgb = baseRGB(config)
        return 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
    }

    private static func perfRGB(_ config: MFilmBorderConfig) -> (CGFloat, CGFloat, CGFloat) {
        let darkBase = baseLuminance(config) < 0.30
        var value: Double = darkBase ? 0.80 : 0.10
        value += config.perfBrightness * 0.35
        value = min(max(value, 0.01), 0.98)
        if darkBase {
            return (CGFloat(value), CGFloat(value * 0.965), CGFloat(value * 0.90))
        }
        return (CGFloat(value), CGFloat(value), CGFloat(value * 0.96))
    }

    private static func textRGB(_ config: MFilmBorderConfig, filmID: String) -> (CGFloat, CGFloat, CGFloat) {
        let tone = MFilmBorderTextTone(rawValue: config.textTone) ?? .auto
        var rgb: (Double, Double, Double)
        switch tone {
        case .auto:
            if filmID.hasPrefix("fujifilm") {
                rgb = (0.30, 0.66, 0.42)
            } else if filmID.hasPrefix("kodak") {
                rgb = (0.92, 0.63, 0.24)
            } else {
                rgb = (0.86, 0.82, 0.72)
            }
        case .orange: rgb = (0.93, 0.66, 0.27)
        case .green: rgb = (0.30, 0.66, 0.42)
        case .white: rgb = (0.88, 0.85, 0.78)
        case .black: rgb = (0.06, 0.06, 0.05)
        }
        // 深色片基上的深色字看不见，自动抬亮；浅色片基同理压暗。
        if baseLuminance(config) < 0.28, rgb.0 < 0.25, rgb.1 < 0.25, rgb.2 < 0.25 {
            rgb = (0.82, 0.79, 0.71)
        }
        if baseLuminance(config) > 0.40, rgb.0 > 0.70 {
            rgb = (0.12, 0.10, 0.08)
        }
        return (CGFloat(rgb.0), CGFloat(rgb.1), CGFloat(rgb.2))
    }

    private static func drawBaseTexture(_ context: CGContext, layout: MFilmBorderLayout,
                                        config: MFilmBorderConfig,
                                        base: (CGFloat, CGFloat, CGFloat)) {
        let width = layout.canvas.width
        let height = layout.canvas.height
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(red: min(1, base.0 * 1.16), green: min(1, base.1 * 1.16),
                        blue: min(1, base.2 * 1.16), alpha: 1),
                CGColor(red: base.0 * 0.86, green: base.1 * 0.86,
                        blue: base.2 * 0.86, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: height),
                options: []
            )
        }

        // 片基颗粒：位置按照片尺寸归一化，预览与导出是同一片纹理。
        var random = MFilmBorderRandom(seed: "base-texture-\(config.gauge)-\(config.baseTone)")
        let count = 900
        for _ in 0..<count {
            let x = random.range(0, width)
            let y = random.range(0, height)
            let radius = max(0.4, layout.pxPerMM * random.range(0.02, 0.09))
            let light = random.unit() > 0.5
            let alpha = random.range(0.02, 0.07)
            context.setFillColor(
                red: light ? 1 : 0,
                green: light ? 0.97 : 0,
                blue: light ? 0.90 : 0,
                alpha: alpha
            )
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }
    }

    // MARK: 画幅角型

    private static func aperturePath(_ layout: MFilmBorderLayout,
                                     config: MFilmBorderConfig) -> CGPath {
        let rect = layout.aperture
        let corner = MFilmBorderCorner(rawValue: config.corner) ?? .rounded
        let shortSide = min(rect.width, rect.height)
        switch corner {
        case .square:
            return CGPath(rect: rect, transform: nil)
        case .rounded:
            let radius = shortSide * 0.035 * CGFloat(config.cornerScale)
            return CGPath(roundedRect: rect, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        case .chamfer:
            let cut = shortSide * 0.045 * CGFloat(config.cornerScale)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
            path.closeSubpath()
            return path
        case .ear:
            // 耳角：四个角向画幅内凹进一段圆弧，像片门压片把画面四角咬掉。
            let bite = shortSide * 0.055 * CGFloat(config.cornerScale)
            let deep = bite * 1.3
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX + bite, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - bite, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + bite),
                control: CGPoint(x: rect.maxX - deep, y: rect.minY + deep)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bite))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - bite, y: rect.maxY),
                control: CGPoint(x: rect.maxX - deep, y: rect.maxY - deep)
            )
            path.addLine(to: CGPoint(x: rect.minX + bite, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - bite),
                control: CGPoint(x: rect.minX + deep, y: rect.maxY - deep)
            )
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bite))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + bite, y: rect.minY),
                control: CGPoint(x: rect.minX + deep, y: rect.minY + deep)
            )
            path.closeSubpath()
            return path
        }
    }

    // MARK: 齿孔

    private static func drawPerforations(_ context: CGContext, layout: MFilmBorderLayout,
                                         config: MFilmBorderConfig,
                                         color: (CGFloat, CGFloat, CGFloat)) {
        let perf = config.perfValue
        guard perf != .none else { return }
        let holeLength = CGFloat(perf.lengthMM) * layout.pxPerMM * CGFloat(config.perfScale)
        let rawHeight = CGFloat(perf.heightMM) * layout.pxPerMM * CGFloat(config.perfScale)
        let marginAcross = layout.alongX ? layout.marginY : layout.marginX
        // 110 / 16mm 的孔几乎和片边一样高：压进留边，别咬到画面。
        let holeHeight = min(rawHeight, marginAcross * 0.78)
        guard holeLength > 0.5, holeHeight > 0.5 else { return }

        let alongLength = layout.alongX ? layout.aperture.width : layout.aperture.height
        let pitch = CGFloat(perf.pitchMM) * layout.pxPerMM * CGFloat(config.perfPitch)
        let count: Int
        if perf.isSingle || pitch <= 0 {
            count = max(1, Int((alongLength / max(1, layout.pxPerMM * CGFloat(layout.gauge.frameLongMM))).rounded()))
        } else {
            count = max(2, Int((alongLength / pitch).rounded()))
        }
        let span = CGFloat(max(0, count - 1)) * max(pitch, holeLength)
        let start = (layout.alongX ? layout.aperture.minX : layout.aperture.minY)
            + (alongLength - span) / 2

        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)

        let edges: [CGFloat]
        if perf.isOneEdge {
            edges = [marginAcross * 0.5]
        } else {
            if layout.alongX {
                edges = [layout.marginY * 0.5, layout.canvas.height - layout.marginY * 0.5]
            } else {
                edges = [layout.marginX * 0.5, layout.canvas.width - layout.marginX * 0.5]
            }
        }

        for edge in edges {
            for index in 0..<count {
                let center = start + CGFloat(index) * max(pitch, holeLength) + holeLength / 2
                let rect: CGRect
                if layout.alongX {
                    rect = CGRect(x: center - holeLength / 2, y: edge - holeHeight / 2,
                                  width: holeLength, height: holeHeight)
                } else {
                    rect = CGRect(x: edge - holeHeight / 2, y: center - holeLength / 2,
                                  width: holeHeight, height: holeLength)
                }
                context.addPath(perfPath(rect, perf: perf))
                context.fillPath()
            }
        }
    }

    private static func perfPath(_ rect: CGRect, perf: MFilmBorderPerf) -> CGPath {
        switch perf {
        case .bh, .cs:
            // BH / CS：上下平直、两侧外鼓的桶形孔。
            let bulge = rect.width * 0.16
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX + bulge, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - bulge, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - bulge, y: rect.maxY),
                control: CGPoint(x: rect.maxX + bulge * 0.35, y: rect.midY)
            )
            path.addLine(to: CGPoint(x: rect.minX + bulge, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + bulge, y: rect.minY),
                control: CGPoint(x: rect.minX - bulge * 0.35, y: rect.midY)
            )
            path.closeSubpath()
            return path
        case .single126, .single110, .single16:
            return CGPath(roundedRect: rect,
                          cornerWidth: min(rect.width, rect.height) * 0.22,
                          cornerHeight: min(rect.width, rect.height) * 0.22,
                          transform: nil)
        default:
            return CGPath(roundedRect: rect,
                          cornerWidth: min(rect.width, rect.height) * 0.16,
                          cornerHeight: min(rect.width, rect.height) * 0.16,
                          transform: nil)
        }
    }

    // MARK: 边字

    private static func drawEdgeText(_ context: CGContext, layout: MFilmBorderLayout,
                                     config: MFilmBorderConfig,
                                     filmID: String, photoID: String) {
        let color = textRGB(config, filmID: filmID)
        let cgColor = CGColor(red: color.0, green: color.1, blue: color.2, alpha: 0.94)
        let fontSize = max(5, min(220, layout.pxPerMM * 1.05 * CGFloat(config.textScale)))
        let label = edgeLabel(filmID: filmID, custom: config.customText)
        let tracking = fontSize * 0.10
        // 110 / 16mm 只有单侧齿孔，片边很窄：边字改排到没有齿孔的那一侧。
        let oneEdge = config.perfValue.isOneEdge

        if layout.alongX {
            if config.edgeText {
                let baseline = oneEdge
                    ? layout.canvas.height - layout.marginY * 0.16 - fontSize * 0.14
                    : layout.marginY * 0.16 + fontSize * 0.82
                drawRepeatedText(context, text: label,
                                 origin: CGPoint(x: layout.aperture.minX, y: baseline),
                                 rotation: 0, fontSize: fontSize, color: cgColor,
                                 tracking: tracking,
                                 limit: layout.canvas.width - layout.aperture.minX * 0.6,
                                 horizontal: true, step: fontSize * 1.55)
            }

            if config.frameNumbers {
                let numberSize = fontSize * 0.92
                // 有单侧齿孔时编号放到齿孔对面；双排齿孔时放在下片边。
                let baseline = oneEdge
                    ? layout.marginY * 0.16 + numberSize * 0.82
                    : layout.canvas.height - layout.marginY * 0.16 - numberSize * 0.18
                drawText(context, text: frameLabel(photoID: photoID, gauge: layout.gauge),
                         origin: CGPoint(x: layout.aperture.minX, y: baseline),
                         rotation: 0, fontSize: numberSize, color: cgColor,
                         tracking: numberSize * 0.08)
            }
            if config.dxCode, layout.gauge == .full135 || layout.gauge == .half135 {
                drawDXCode(context, layout: layout, config: config, color: cgColor,
                           photoID: photoID)
            }
        } else {
            // 竖片：边字沿左右片边竖排。基线贴近画幅一侧，字形朝片边外侧展开，避免压到齿孔。
            let textHeight = fontSize * 0.95
            let leftX = layout.marginX * 0.16 + textHeight
            let rightX = layout.canvas.width - layout.marginX * 0.16 - textHeight
            let textLength = textWidth(label, fontSize: fontSize, tracking: tracking)
            let step = textLength + fontSize * 1.1

            if config.edgeText {
                if oneEdge {
                    // 齿孔在左片边，品牌字改到右片边。
                    var y = layout.aperture.minY + fontSize
                    while y < layout.aperture.maxY - fontSize {
                        drawText(context, text: label,
                                 origin: CGPoint(x: rightX, y: y),
                                 rotation: CGFloat.pi / 2,
                                 fontSize: fontSize, color: cgColor, tracking: tracking)
                        y += step
                    }
                } else {
                    var y = layout.aperture.minY + textLength + fontSize
                    while y < layout.aperture.maxY - fontSize {
                        drawText(context, text: label,
                                 origin: CGPoint(x: leftX, y: y),
                                 rotation: -CGFloat.pi / 2,
                                 fontSize: fontSize, color: cgColor, tracking: tracking)
                        y += step
                    }
                }
            }

            if config.frameNumbers {
                let numberSize = fontSize * 0.92
                if oneEdge {
                    // 编号放到齿孔那一侧的顶端：单孔在片边中段，顶端仍然空着。
                    drawText(context, text: frameLabel(photoID: photoID, gauge: layout.gauge),
                             origin: CGPoint(x: leftX, y: layout.aperture.minY + fontSize),
                             rotation: -CGFloat.pi / 2,
                             fontSize: numberSize, color: cgColor,
                             tracking: numberSize * 0.08)
                } else {
                    drawText(context, text: frameLabel(photoID: photoID, gauge: layout.gauge),
                             origin: CGPoint(x: rightX, y: layout.aperture.minY + fontSize),
                             rotation: CGFloat.pi / 2,
                             fontSize: numberSize, color: cgColor,
                             tracking: numberSize * 0.08)
                }
            }
            if config.dxCode, layout.gauge == .full135 || layout.gauge == .half135 {
                drawDXCodeVertical(context, layout: layout, config: config,
                                   color: cgColor, photoID: photoID)
            }
        }
    }

    private static func drawRepeatedText(_ context: CGContext, text: String,
                                         origin: CGPoint, rotation: CGFloat,
                                         fontSize: CGFloat, color: CGColor,
                                         tracking: CGFloat, limit: CGFloat,
                                         horizontal: Bool, step: CGFloat) {
        var cursor = origin
        var guardCount = 0
        while guardCount < 12 {
            guardCount += 1
            if horizontal {
                guard cursor.x < limit else { break }
            } else {
                guard cursor.y < limit else { break }
            }
            drawText(context, text: text, origin: cursor, rotation: rotation,
                     fontSize: fontSize, color: color, tracking: tracking)
            if horizontal {
                cursor.x += textWidth(text, fontSize: fontSize, tracking: tracking) + step
            } else {
                cursor.y += textWidth(text, fontSize: fontSize, tracking: tracking) + step
            }
        }
    }

    private static func drawText(_ context: CGContext, text: String, origin: CGPoint,
                                 rotation: CGFloat, fontSize: CGFloat,
                                 color: CGColor, tracking: CGFloat) {
        guard !text.isEmpty else { return }
        let fontName: String
        if text.unicodeScalars.contains(where: { $0.value > 0x2E80 }) {
            fontName = "PingFangSC-Semibold"
        } else {
            fontName = "HelveticaNeue-Bold"
        }
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if rotation != 0 { context.rotate(by: rotation) }
        // 外层已经是 y 向下；文字再翻一次，字形才是正的。
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func textWidth(_ text: String, fontSize: CGFloat, tracking: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: DX 码

    private static func drawDXCode(_ context: CGContext, layout: MFilmBorderLayout,
                                   config: MFilmBorderConfig, color: CGColor,
                                   photoID: String) {
        var random = MFilmBorderRandom(seed: "dx-\(photoID)")
        let unit = layout.pxPerMM * 0.32
        let gap = unit * 0.42
        let originX = layout.aperture.maxX - (unit * 6 + gap * 5) - layout.pxPerMM
        // 下片边外侧留白：和齿孔错开，别把条码压在孔上。
        let originY = layout.canvas.height - layout.marginY * 0.16 - (unit * 2 + gap * 0.8)
        context.setFillColor(color.copy(alpha: 0.80) ?? color)
        for row in 0..<2 {
            for column in 0..<6 {
                guard random.unit() > 0.32 else { continue }
                let rect = CGRect(
                    x: originX + CGFloat(column) * (unit + gap),
                    y: originY + CGFloat(row) * (unit + gap * 0.8),
                    width: unit, height: unit
                )
                context.fill(rect)
            }
        }
    }

    private static func drawDXCodeVertical(_ context: CGContext, layout: MFilmBorderLayout,
                                           config: MFilmBorderConfig, color: CGColor,
                                           photoID: String) {
        var random = MFilmBorderRandom(seed: "dx-\(photoID)")
        let unit = layout.pxPerMM * 0.32
        let gap = unit * 0.42
        let originX = layout.canvas.width - layout.marginX * 0.16 - (unit * 2 + gap * 0.8)
        let originY = layout.aperture.maxY - (unit * 6 + gap * 5) - layout.pxPerMM
        context.setFillColor(color.copy(alpha: 0.80) ?? color)
        for row in 0..<2 {
            for column in 0..<6 {
                guard random.unit() > 0.32 else { continue }
                let rect = CGRect(
                    x: originX + CGFloat(row) * (unit + gap * 0.8),
                    y: originY + CGFloat(column) * (unit + gap),
                    width: unit, height: unit
                )
                context.fill(rect)
            }
        }
    }

    // MARK: 片缺口

    private static func drawNotchCode(_ context: CGContext, layout: MFilmBorderLayout,
                                      config: MFilmBorderConfig) {
        let color = perfRGB(config)
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 0.92)
        let unit = layout.pxPerMM * 1.6
        let right = layout.canvas.width - layout.marginX * 0.55
        let top = layout.marginY * 0.10
        // 方缺口
        context.fill(CGRect(x: right - unit * 3.6, y: top, width: unit, height: unit))
        // V 缺口
        let v = CGMutablePath()
        v.move(to: CGPoint(x: right - unit * 2.1, y: top))
        v.addLine(to: CGPoint(x: right - unit * 1.55, y: top + unit * 1.5))
        v.addLine(to: CGPoint(x: right - unit, y: top))
        v.closeSubpath()
        context.addPath(v)
        context.fillPath()
        // 半圆缺口
        context.fillEllipse(in: CGRect(x: right - unit * 0.55, y: top,
                                       width: unit * 0.9, height: unit * 0.9))
    }

    // MARK: 磨损

    private static func drawWear(_ context: CGContext, layout: MFilmBorderLayout,
                                 config: MFilmBorderConfig, photoID: String) {
        var random = MFilmBorderRandom(seed: "wear-\(photoID)-\(config.gauge)")

        // 划痕：只落在片边上，不动画面。
        let scratchCount = Int((config.scratches * 5).rounded())
        for _ in 0..<scratchCount {
            let light = random.unit() > 0.35
            let alpha = random.range(0.10, 0.34)
            context.setStrokeColor(red: light ? 1 : 0, green: light ? 0.98 : 0,
                                   blue: light ? 0.92 : 0, alpha: alpha)
            context.setLineWidth(max(0.5, layout.pxPerMM * random.range(0.02, 0.07)))
            let path = CGMutablePath()
            if layout.alongX {
                let y = random.unit() > 0.5
                    ? random.range(0, layout.marginY * 0.92)
                    : random.range(layout.canvas.height - layout.marginY * 0.92, layout.canvas.height)
                path.move(to: CGPoint(x: random.range(0, layout.canvas.width * 0.25), y: y))
                path.addLine(to: CGPoint(x: random.range(layout.canvas.width * 0.55, layout.canvas.width), y: y))
            } else {
                let x = random.unit() > 0.5
                    ? random.range(0, layout.marginX * 0.92)
                    : random.range(layout.canvas.width - layout.marginX * 0.92, layout.canvas.width)
                path.move(to: CGPoint(x: x, y: random.range(0, layout.canvas.height * 0.25)))
                path.addLine(to: CGPoint(x: x, y: random.range(layout.canvas.height * 0.55, layout.canvas.height)))
            }
            context.addPath(path)
            context.strokePath()
        }

        // 灰尘：细小白点，和划痕分开生成，避免每次改参数整片纹理重排。
        let dustCount = Int((config.dust * 140).rounded())
        for _ in 0..<dustCount {
            let firstEdge = random.unit() > 0.5
            let x: CGFloat
            let y: CGFloat
            if layout.alongX {
                x = random.range(0, layout.canvas.width)
                y = firstEdge
                    ? random.range(0, layout.marginY * 0.95)
                    : random.range(layout.canvas.height - layout.marginY * 0.95, layout.canvas.height)
            } else {
                x = firstEdge
                    ? random.range(0, layout.marginX * 0.95)
                    : random.range(layout.canvas.width - layout.marginX * 0.95, layout.canvas.width)
                y = random.range(0, layout.canvas.height)
            }
            let radius = layout.pxPerMM * random.range(0.03, 0.16)
            let light = random.unit() > 0.4
            context.setFillColor(red: light ? 1 : 0, green: light ? 0.98 : 0,
                                 blue: light ? 0.94 : 0,
                                 alpha: random.range(0.12, 0.38))
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }
    }

    private static func drawEdgeFog(_ context: CGContext, layout: MFilmBorderLayout,
                                    config: MFilmBorderConfig) {
        guard config.fog > 0.001 else { return }
        let width = layout.canvas.width
        let height = layout.canvas.height
        let depth = max(2, layout.pxPerMM * 1.4)
        let alpha = config.fog * 0.22
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(red: 0.88, green: 0.76, blue: 0.58, alpha: alpha),
                CGColor(red: 0.88, green: 0.76, blue: 0.58, alpha: 0),
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: depth), options: [])
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: height),
                                   end: CGPoint(x: 0, y: height - depth), options: [])
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: depth, y: 0), options: [])
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: width, y: 0),
                                   end: CGPoint(x: width - depth, y: 0), options: [])
    }

    // MARK: 文字内容

    static func edgeLabel(filmID: String, custom: String) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.uppercased() }
        guard let film = MobileCatalog.film(id: filmID) else { return "SPEKTRAFILM" }
        var name = film.name
        name = name.replacingOccurrences(of: "柯达", with: "KODAK")
        name = name.replacingOccurrences(of: "富士", with: "FUJIFILM")
        name = name.replacingOccurrences(of: "推一档", with: "PUSH +1")
        name = name.replacingOccurrences(of: "推两档", with: "PUSH +2")
        return name.uppercased()
    }

    private static func frameLabel(photoID: String, gauge: MFilmBorderGauge) -> String {
        var random = MFilmBorderRandom(seed: "frame-\(photoID)")
        let number: Int
        switch gauge {
        case .roll645: number = Int(random.range(1, 16))
        case .roll66: number = Int(random.range(1, 12))
        case .roll67: number = Int(random.range(1, 10))
        case .roll69: number = Int(random.range(1, 8))
        case .sheet45: return "4×5"
        default: number = Int(random.range(1, 37))
        }
        if gauge == .full135 || gauge == .half135 || gauge == .cine35 || gauge == .cine16 {
            return random.unit() > 0.5 ? "\(number)" : "\(number)A"
        }
        return "\(number)"
    }

    // MARK: 样例图

    /// 片边缩略图用的小样张：固定暖调风景，保证 7 个预设的缩略图只差片边本身。
    static func samplePhoto(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 0.82, green: 0.70, blue: 0.52, alpha: 1),
                CGColor(red: 0.45, green: 0.38, blue: 0.28, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: h),
                                       end: CGPoint(x: 0, y: h * 0.35), options: [])
        }
        context.setFillColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.35))
        context.setFillColor(red: 0.96, green: 0.88, blue: 0.70, alpha: 0.92)
        context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.58, width: w * 0.14, height: w * 0.14))
        context.setFillColor(red: 0.10, green: 0.09, blue: 0.07, alpha: 0.85)
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: 0, y: h * 0.35))
        hill.addLine(to: CGPoint(x: w * 0.28, y: h * 0.47))
        hill.addLine(to: CGPoint(x: w * 0.52, y: h * 0.36))
        hill.addLine(to: CGPoint(x: w * 0.78, y: h * 0.50))
        hill.addLine(to: CGPoint(x: w, y: h * 0.40))
        hill.addLine(to: CGPoint(x: w, y: 0))
        hill.addLine(to: CGPoint(x: 0, y: 0))
        hill.closeSubpath()
        context.addPath(hill)
        context.fillPath()
        return context.makeImage()
    }
}

// MARK: - 片边缩略图

enum MFilmBorderThumbnailCache {
    private static var cache: [String: MPlatformImage] = [:]

    static func image(for preset: MFilmBorderPreset,
                      size: CGSize = CGSize(width: 112, height: 82)) -> MPlatformImage? {
        let key = "\(preset.id)-\(Int(size.width))x\(Int(size.height))"
        if let hit = cache[key] { return hit }
        guard let sample = MFilmBorderRenderer.samplePhoto(width: 96, height: 64) else {
            return nil
        }
        let config = preset.config
        let rendered: CGImage?
        if config.enabled {
            rendered = MFilmBorderRenderer.preview(
                photo: sample, config: config,
                filmID: preset.id.hasPrefix("fuji") ? "fujifilm_pro_400h" : "kodak_portra_400",
                photoID: preset.id
            )
        } else {
            rendered = sample
        }
        guard let rendered else { return nil }
        let image = MImage.make(cgImage: rendered)
        cache[key] = image
        return image
    }
}

// MARK: - 片边预设卡

struct MFilmBorderPresetCard: View {
    let preset: MFilmBorderPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MColor.surface2)

                    if let image = MFilmBorderThumbnailCache.image(for: preset) {
                        MImage.swiftUI(image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(3)
                    }
                }
                .frame(width: 82, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? MColor.brass : MColor.hairline,
                                      lineWidth: selected ? 1.3 : 1)
                )

                Text(preset.name)
                    .font(.mSans(8, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MColor.text1 : MColor.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.95))
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 确定性随机

/// 片边纹理必须可复现：预览、缩略图、导出三处用同一个种子得到同一批划痕与灰尘。
private struct MFilmBorderRandom {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        state = hash == 0 ? 0x9E3779B97F4A7C15 : hash
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53)
    }

    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low + (high - low) * unit()
    }
}
