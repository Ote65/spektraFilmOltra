import Foundation
import Photos

enum MColorLabel: String, CaseIterable, Identifiable, Hashable {
    case red, yellow, green, blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return "红"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }
}

struct MPhoto: Identifiable, Hashable {
    let id: String
    let filename: String
    let film: String
    let paper: String
    let dimensions: String
    let isRaw: Bool
    let favorite: Bool
    let color: MColorLabel?
    let isGraded: Bool
    let exposure: String
    let thumbnailURL: URL?

    var metaLine: String {
        [film, dimensions].joined(separator: " · ")
    }

    var aspectRatio: CGFloat {
        let parts = dimensions.split(separator: "×").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 4.0 / 3.0 }
        return CGFloat(parts[0] / parts[1])
    }
}

/// 主页网格项：一条来自系统相册的照片资产（RAW 或编码图）。
/// 相册里有、但还没入库的照片 `photo` 为 nil；点开时再按需取原片入库。
struct MLibraryAsset: Identifiable, Hashable {
    /// `PHAsset.localIdentifier`
    let id: String
    /// 相册里的原始文件名，用于和已入库照片对上编辑记录。
    let filename: String
    /// 已入库时的展示信息（含调色状态、本地缩略图）。
    let photo: MPhoto?
    /// 相册资产本体：未入库时靠它取相册缩略图，入库时取原片。
    let phAsset: PHAsset?

    var isImported: Bool { photo != nil }
    var isGraded: Bool { photo?.isGraded ?? false }

    var isRawFormat: Bool {
        ImageLoader.rawSuffixes.contains((filename as NSString).pathExtension.lowercased())
    }

    /// 卡片左上角的格式角标：显影质量从 RAW 到编码图差别很大，标出来更诚实。
    var formatLabel: String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ImageLoader.rawSuffixes.contains(ext) { return "RAW" }
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "tif", "tiff": return "TIFF"
        case "png": return "PNG"
        case "webp": return "WEBP"
        default: return ext.isEmpty ? "IMG" : ext.uppercased()
        }
    }

    static func == (lhs: MLibraryAsset, rhs: MLibraryAsset) -> Bool {
        lhs.id == rhs.id && lhs.photo?.id == rhs.photo?.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 主页顶部的类型筛选：全部 / 收藏 / RAW / 已调色 / 某个系统相簿。
enum MAssetScope: Hashable {
    case all
    case favorites
    case raw
    case graded
    case album(String)

    var title: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .raw: return "RAW"
        case .graded: return "已调色"
        case .album: return "相簿"
        }
    }
}

/// 系统相册里的用户相簿。
struct MAlbum: Identifiable, Hashable {
    let id: String
    let title: String
}

struct MFilm: Identifiable, Hashable {
    let id: String
    let name: String
    let brand: String
    let kind: String
    let hue: Double
    let saturation: Double
    let brightness: Double
}

struct MPaper: Identifiable, Hashable {
    let id: String
    let name: String
    let brand: String
    let warmth: Double
    let note: String
}

struct MQuickAxis: Identifiable, Hashable {
    let id: String
    let label: String
    let group: String
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let suffix: String
    let base: Double
    var value: Double

    var isDirty: Bool { abs(value - base) > 1e-9 }

    func text(for value: Double) -> String {
        let zeroCutoff = pow(10, Double(-decimals)) * 0.5
        let normalized = abs(value) < zeroCutoff ? 0 : value
        var text = String(format: "%.\(decimals)f", normalized)
        if decimals > 0, text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if range.lowerBound < 0, normalized > 0 { text = "+" + text }
        return text + suffix
    }
}

struct MQuickGroup: Identifiable, Hashable {
    let id: String
    let title: String
    var axes: [MQuickAxis]
}

struct MProOption: Hashable {
    let value: String
    let label: String
}

enum MProControl: Hashable {
    case slider(value: Double, base: Double, range: ClosedRange<Double>, step: Double, decimals: Int, suffix: String)
    case toggle(isOn: Bool)
    case choice(options: [MProOption], value: String)
}

struct MProRow: Identifiable, Hashable {
    let id: String
    let label: String
    let control: MProControl
}

struct MProGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [MProRow]
}

struct MProPage: Identifiable, Hashable {
    let id: String
    let title: String
    let groups: [MProGroup]
}

struct MLUT: Identifiable, Hashable {
    let id: String
    let name: String
    let meta: String
    let tints: [UInt32]
}

enum MGradeTab: String, CaseIterable, Identifiable {
    case presets, light, color, texture, border
    var id: String { rawValue }
    var title: String {
        switch self {
        case .presets: return "预设"
        case .light: return "光影"
        case .color: return "色调"
        case .texture: return "质感"
        case .border: return "边框"
        }
    }
}

struct MGradeRecipe: Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var midtones: Double = 0
    var highlightRolloff: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var colorDensity: Double = 0
    var hslBands: [HslBand] = Array(repeating: HslBand(), count: 8)
    var grading = ColorGrading()
    var vignette: Double = 0
    var grain: Double = 0
    var lutName: String = "无 LUT"
    var lutStrength: Double = 0
    var curveHighlights: Double = 0
    var curveLights: Double = 0
    var curveDarks: Double = 0
    var curveShadows: Double = 0
    var clarity: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var sharpenAmount: Double = 0
    var sharpenRadius: Double = 1
    var sharpenThreshold: Double = 0
    var noiseLuminance: Double = 0
    var noiseColor: Double = 0
    var grainSize: Double = 25
    var grainRoughness: Double = 50
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 0
    var vignetteFeather: Double = 50
    var chromaticAberration: Double = 0

    /// 视图模型 → 调色引擎配方。只写既有字段，不新增算法。
    func gradeRecipe(lutPath: String) -> GradeRecipe {
        var recipe = GradeRecipe()
        recipe.light.exposure = exposure
        recipe.light.contrast = contrast
        recipe.light.highlights = highlights
        recipe.light.shadows = shadows
        recipe.light.whites = whites
        recipe.light.blacks = blacks
        recipe.light.midtones = midtones
        recipe.light.highlightRolloff = highlightRolloff
        recipe.light.curveHighlights = curveHighlights
        recipe.light.curveLights = curveLights
        recipe.light.curveDarks = curveDarks
        recipe.light.curveShadows = curveShadows
        recipe.color.temperature = temperature
        recipe.color.tint = tint
        recipe.color.saturation = saturation
        recipe.color.vibrance = vibrance
        recipe.color.colorDensity = colorDensity
        recipe.color.hsl = hslBands
        recipe.color.grading = grading
        recipe.optics.vignetteAmount = vignette
        recipe.optics.vignetteMidpoint = vignetteMidpoint
        recipe.optics.vignetteRoundness = vignetteRoundness
        recipe.optics.vignetteFeather = vignetteFeather
        recipe.optics.grainAmount = grain
        recipe.optics.grainSize = grainSize
        recipe.optics.grainRoughness = grainRoughness
        recipe.optics.chromaticAberration = chromaticAberration
        recipe.quality.clarity = clarity
        recipe.quality.texture = texture
        recipe.quality.dehaze = dehaze
        recipe.quality.sharpenAmount = sharpenAmount
        recipe.quality.sharpenRadius = sharpenRadius
        recipe.quality.sharpenThreshold = sharpenThreshold
        recipe.quality.noiseLuminance = noiseLuminance
        recipe.quality.noiseColor = noiseColor
        recipe.lut.path = lutPath
        recipe.lut.strength = lutStrength
        return recipe
    }

    /// 引擎配方 → 视图模型。
    init(grade: GradeRecipe, lutName: String) {
        exposure = grade.light.exposure
        contrast = grade.light.contrast
        highlights = grade.light.highlights
        shadows = grade.light.shadows
        whites = grade.light.whites
        blacks = grade.light.blacks
        midtones = grade.light.midtones
        highlightRolloff = grade.light.highlightRolloff
        curveHighlights = grade.light.curveHighlights
        curveLights = grade.light.curveLights
        curveDarks = grade.light.curveDarks
        curveShadows = grade.light.curveShadows
        temperature = grade.color.temperature
        tint = grade.color.tint
        saturation = grade.color.saturation
        vibrance = grade.color.vibrance
        colorDensity = grade.color.colorDensity
        hslBands = (0..<8).map { index in
            index < grade.color.hsl.count ? grade.color.hsl[index] : HslBand()
        }
        grading = grade.color.grading
        vignette = grade.optics.vignetteAmount
        vignetteMidpoint = grade.optics.vignetteMidpoint
        vignetteRoundness = grade.optics.vignetteRoundness
        vignetteFeather = grade.optics.vignetteFeather
        grain = grade.optics.grainAmount
        grainSize = grade.optics.grainSize
        grainRoughness = grade.optics.grainRoughness
        chromaticAberration = grade.optics.chromaticAberration
        clarity = grade.quality.clarity
        texture = grade.quality.texture
        dehaze = grade.quality.dehaze
        sharpenAmount = grade.quality.sharpenAmount
        sharpenRadius = grade.quality.sharpenRadius
        sharpenThreshold = grade.quality.sharpenThreshold
        noiseLuminance = grade.quality.noiseLuminance
        noiseColor = grade.quality.noiseColor
        self.lutName = lutName
        lutStrength = grade.lut.strength
    }

    init() {}
}

// MARK: - 显影预设

/// 显影阶段预设：只动胶片、相纸、快速显影轴与黑白模式，
/// 不引入任何调色台参数，避免两套管线互相污染。
struct MDevelopPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let filmID: String
    let paperID: String
    let quick: [String: Double]
    let monochrome: Bool
}

enum MobileDevelopPresets {
    static let all: [MDevelopPreset] = [
        MDevelopPreset(
            id: "standard", name: "标准负片", note: "Portra 400 · 中性基线",
            filmID: "kodak_portra_400", paperID: "kodak_supra_endura",
            quick: [:], monochrome: false
        ),
        MDevelopPreset(
            id: "warm-portrait", name: "暖调人像", note: "暖 10 CC · 肤色提亮",
            filmID: "kodak_portra_400", paperID: "kodak_portra_endura",
            quick: ["camera_exposure": 0.1, "print_brightness": 0.08,
                    "temperature": 10, "color_density": 4],
            monochrome: false
        ),
        MDevelopPreset(
            id: "clear-landscape", name: "清透风光", note: "Ektar 100 · 高清晰",
            filmID: "kodak_ektar_100", paperID: "kodak_supra_endura",
            quick: ["tonal_contrast": 12, "scanner_clarity": 18, "color_density": 8],
            monochrome: false
        ),
        MDevelopPreset(
            id: "fuji-fresh", name: "富士清新", note: "Pro 400H · 冷调干净",
            filmID: "fujifilm_pro_400h", paperID: "fujifilm_crystal_archive_typeii",
            quick: ["temperature": -6, "color_density": 10, "tonal_contrast": 4],
            monochrome: false
        ),
        MDevelopPreset(
            id: "cinema-night", name: "电影夜色", note: "Vision3 500T · 低照度",
            filmID: "kodak_vision3_500t", paperID: "kodak_2383",
            quick: ["camera_exposure": -0.2, "print_brightness": -0.12,
                    "tonal_contrast": 8, "temperature": -8],
            monochrome: false
        ),
        MDevelopPreset(
            id: "soft-light", name: "柔光", note: "Portra 800 · 低清晰高颗粒",
            filmID: "kodak_portra_800", paperID: "kodak_portra_endura",
            quick: ["print_brightness": 0.1, "scanner_clarity": -14, "grain_amount": 12],
            monochrome: false
        ),
        MDevelopPreset(
            id: "bw-neutral", name: "黑白", note: "中性灰 · 中颗粒",
            filmID: "kodak_portra_400", paperID: "kodak_supra_endura",
            quick: ["tonal_contrast": 14, "grain_amount": 18,
                    "grain_size": 10, "scanner_clarity": 8],
            monochrome: true
        ),
        MDevelopPreset(
            id: "bw-hard", name: "硬调黑白", note: "高反差 · 深黑",
            filmID: "kodak_ektar_100", paperID: "kodak_supra_endura",
            quick: ["camera_exposure": -0.1, "tonal_contrast": 26,
                    "grain_amount": 8, "grain_size": -10],
            monochrome: true
        ),
    ]
}

enum MScreen: Hashable {
    case home
    case camera
    case develop
    case grade
    case settings
}

enum MGradeEntry: Hashable {
    case handoff
    case direct
}
