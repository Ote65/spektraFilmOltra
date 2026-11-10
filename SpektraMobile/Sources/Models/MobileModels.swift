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

/// 主页网格项：一条来自系统相册的 RAW 资产。
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

    static func == (lhs: MLibraryAsset, rhs: MLibraryAsset) -> Bool {
        lhs.id == rhs.id && lhs.photo?.id == rhs.photo?.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
    case presets, light, color, curve
    var id: String { rawValue }
    var title: String {
        switch self {
        case .presets: return "预设"
        case .light: return "光影"
        case .color: return "色调"
        case .curve: return "曲线"
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
    var vignette: Double = 0
    var grain: Double = 0
    var lutName: String = "无 LUT"
    var lutStrength: Double = 0
    var curveHighlights: Double = 0
    var curveLights: Double = 0
    var curveDarks: Double = 0
    var curveShadows: Double = 0

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
        recipe.optics.vignetteAmount = vignette
        recipe.optics.grainAmount = grain
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
        vignette = grade.optics.vignetteAmount
        grain = grade.optics.grainAmount
        self.lutName = lutName
        lutStrength = grade.lut.strength
    }

    init() {}
}

enum MScreen: Hashable {
    case home
    case develop
    case grade
}

enum MGradeEntry: Hashable {
    case handoff
    case direct
}
