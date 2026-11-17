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
    /// 相机拍摄（RAW/Live/人像/全景/相机 EXIF）；false 表示保存、截图或下载。
    var isCaptured: Bool = true
    /// 仅靠文件名/子类型无法确定来源，等待 EXIF 精修。
    var captureNeedsProbe: Bool = false

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
    /// 相机拍摄：RAW / Live / 人像 / 全景 / 相机 EXIF。
    case captured
    /// 保存：截图、网页下载、聊天保存、AirDrop 等非拍摄来源。
    case saved
    case favorites
    case raw
    case graded
    case album(String)

    var title: String {
        switch self {
        case .all: return "全部"
        case .captured: return "拍摄"
        case .saved: return "保存"
        case .favorites: return "收藏"
        case .raw: return "RAW"
        case .graded: return "已调色"
        case .album: return "相簿"
        }
    }

    /// 拍摄/保存是「全部」之上的来源过滤，需要先拿到完整相册列表。
    var isOriginFilter: Bool {
        self == .captured || self == .saved
    }
}

/// 系统相册里的用户相簿。
struct MAlbum: Identifiable, Hashable {
    let id: String
    let title: String
}

/// 主页允许出现的格式：RAW / JPEG / HEIC(HEIF)。PNG、GIF、WebP、TIFF 一律不进筛选。
enum MAssetFormat {
    static func isAllowed(filename: String, isRaw: Bool) -> Bool {
        if isRaw { return true }
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "heif": return true
        default: return false
        }
    }

    static func isAllowed(originalPath: String) -> Bool {
        let ext = (originalPath as NSString).pathExtension.lowercased()
        if ImageLoader.rawSuffixes.contains(ext) { return true }
        switch ext {
        case "jpg", "jpeg", "heic", "heif": return true
        default: return false
        }
    }
}

/// 相册来源分类：先用零额外 IO 的信号给出结论，模糊项标记出来交给 EXIF 精修。
enum MCaptureClassifier {
    struct Verdict {
        let isCaptured: Bool
        let confident: Bool
    }

    private static let cameraSizes: Set<String> = [
        "4032x3024", "3024x4032", "4032x2268", "2268x4032",
        "5712x4284", "4284x5712", "8064x6048", "6048x8064",
    ]

    /// 正则只编译一次。整库扫描时每个资产都临时编译正则会产生大量分配，
    /// 冷启动/安装后首次扫描会被拖成几十秒，表现就是「App 点了没反应」。
    private static let hashedNameRegex = try! NSRegularExpression(pattern: #"^[0-9a-f]{16,}"#)
    private static let imgNameRegex = try! NSRegularExpression(pattern: #"^img_\d{4,5}$"#)
    private static let cameraNameRegex = try! NSRegularExpression(
        pattern: #"^(dsc|dscf|dscn|pxl|mvimg|gopr|dji|_mg|l100|p\d{7})[_-]?\d*$"#)

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// 基于 PHAsset 的零 IO 判定：子类型与 RAW 直接给结论，其余交给文件名规则。
    static func classify(asset: PHAsset, filename: String, isRaw: Bool) -> Verdict {
        if isRaw { return Verdict(isCaptured: true, confident: true) }
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoScreenshot) {
            return Verdict(isCaptured: false, confident: true)
        }
        if subtypes.contains(.photoLive)
            || subtypes.contains(.photoPanorama)
            || subtypes.contains(.photoDepthEffect) {
            return Verdict(isCaptured: true, confident: true)
        }
        return classify(filename: filename, isRaw: false,
                        pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                        preferSavedWhenUnknown: true)
    }

    static func classify(filename: String, isRaw: Bool) -> Verdict {
        classify(filename: filename, isRaw: isRaw, pixelWidth: 0, pixelHeight: 0)
    }

    /// 文件名 + 扩展名 + 尺寸的规则；`confident == false` 时由上层按需读 EXIF。
    /// `preferSavedWhenUnknown`：未知命名且非标准相机尺寸时先归到「保存」，避免网络图混进「拍摄」。
    static func classify(filename: String, isRaw: Bool,
                         pixelWidth: Int, pixelHeight: Int,
                         preferSavedWhenUnknown: Bool = false) -> Verdict {
        if isRaw { return Verdict(isCaptured: true, confident: true) }
        let name = filename.lowercased()
        let ext = (name as NSString).pathExtension
        if ext == "gif" || ext == "webp" || ext == "bmp" {
            return Verdict(isCaptured: false, confident: true)
        }
        if name.contains("screenshot") || name.contains("screen shot") || name.contains("截图") {
            return Verdict(isCaptured: false, confident: true)
        }
        if name.contains("wx_camera") { return Verdict(isCaptured: true, confident: false) }
        if name.contains("mmexport") || name.contains("wechat") || name.contains("download")
            || name.contains("saved") || name.contains("img_copy") {
            return Verdict(isCaptured: false, confident: true)
        }
        // iPhone 相机不产 PNG；相册里的 PNG 基本是截图或保存图。
        if ext == "png" { return Verdict(isCaptured: false, confident: true) }
        let base = (name as NSString).deletingPathExtension
        if matches(Self.hashedNameRegex, base) {
            return Verdict(isCaptured: false, confident: true)
        }
        if matches(Self.imgNameRegex, base) {
            if ext == "heic" || ext == "dng" || isStandardCameraSize(pixelWidth, pixelHeight) {
                return Verdict(isCaptured: true, confident: true)
            }
            return Verdict(isCaptured: true, confident: false)
        }
        if matches(Self.cameraNameRegex, base) {
            return Verdict(isCaptured: true, confident: true)
        }
        // 未知命名先看尺寸：标准相机尺寸更像拍摄，其余先归保存；两者都交给 EXIF 精修。
        if preferSavedWhenUnknown {
            return Verdict(isCaptured: isStandardCameraSize(pixelWidth, pixelHeight),
                           confident: false)
        }
        // 本地库（已导入）未知命名按拍摄保留，避免把真照片藏起来。
        return Verdict(isCaptured: true, confident: false)
    }

    private static func isStandardCameraSize(_ width: Int, _ height: Int) -> Bool {
        width > 0 && height > 0 && cameraSizes.contains("\(width)x\(height)")
    }
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

    /// 按组覆盖调色配方：只写入选中的组，未选中的组保持当前值。
    /// LUT 名称由会话按路径解析，这里只同步强度。
    mutating func merge(_ grade: GradeRecipe, groups: Set<MGradeGroupKey>) {
        if groups.contains(.light) {
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
        }
        if groups.contains(.color) {
            temperature = grade.color.temperature
            tint = grade.color.tint
            saturation = grade.color.saturation
            vibrance = grade.color.vibrance
            colorDensity = grade.color.colorDensity
            hslBands = (0..<8).map { index in
                index < grade.color.hsl.count ? grade.color.hsl[index] : HslBand()
            }
            grading = grade.color.grading
        }
        if groups.contains(.optics) {
            vignette = grade.optics.vignetteAmount
            vignetteMidpoint = grade.optics.vignetteMidpoint
            vignetteRoundness = grade.optics.vignetteRoundness
            vignetteFeather = grade.optics.vignetteFeather
            grain = grade.optics.grainAmount
            grainSize = grade.optics.grainSize
            grainRoughness = grade.optics.grainRoughness
            chromaticAberration = grade.optics.chromaticAberration
        }
        if groups.contains(.quality) {
            clarity = grade.quality.clarity
            texture = grade.quality.texture
            dehaze = grade.quality.dehaze
            sharpenAmount = grade.quality.sharpenAmount
            sharpenRadius = grade.quality.sharpenRadius
            sharpenThreshold = grade.quality.sharpenThreshold
            noiseLuminance = grade.quality.noiseLuminance
            noiseColor = grade.quality.noiseColor
        }
        if groups.contains(.lut) {
            lutStrength = grade.lut.strength
        }
    }
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

// MARK: - 用户显影预设

/// 专业参数值：滑块 / 开关 / 下拉统一编码。
enum MProValue: Codable, Hashable {
    case number(Double)
    case flag(Bool)
    case option(String)

    private enum CodingKeys: String, CodingKey { case kind, number, flag, option }
    private enum Kind: String, Codable { case number, flag, option }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .number: self = .number(try c.decode(Double.self, forKey: .number))
        case .flag: self = .flag(try c.decode(Bool.self, forKey: .flag))
        case .option: self = .option(try c.decode(String.self, forKey: .option))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let value):
            try c.encode(Kind.number, forKey: .kind)
            try c.encode(value, forKey: .number)
        case .flag(let value):
            try c.encode(Kind.flag, forKey: .kind)
            try c.encode(value, forKey: .flag)
        case .option(let value):
            try c.encode(Kind.option, forKey: .kind)
            try c.encode(value, forKey: .option)
        }
    }
}

/// 用户保存的显影预设：胶片组合 + 勾选的专业参数。
struct MUserDevelopPreset: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = Date()
    var filmID: String
    var paperID: String
    var monochrome: Bool
    var pro: [String: MProValue]
    /// 保存预设时的拍摄曝光基线；曝光补偿的 pro 值按「基线 + 调整量」解释。
    /// 旧预设没有该字段，仍按绝对值套用，避免误加拍摄曝光。
    var exposureBaselineEV: Double? = nil
    var schema: Int = 1
}

/// 用户显影预设存储：与调色预设一致，落在 Application Support/Spektrafilm 的 JSON 文件里。
final class MDevelopPresetStore {
    static let shared = MDevelopPresetStore()

    private(set) var userPresets: [MUserDevelopPreset] = []
    private let directory: URL
    private var presetsURL: URL { directory.appendingPathComponent("develop_presets.json") }

    private struct Envelope: Codable {
        var schema: Int = 1
        var presets: [MUserDevelopPreset]
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Spektrafilm") ?? URL(fileURLWithPath: NSHomeDirectory())
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func reload() {
        load()
    }

    func isNameTaken(_ name: String, excluding id: String? = nil) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        if MobileDevelopPresets.all.contains(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }) { return true }
        return userPresets.contains {
            $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
    }

    @discardableResult
    func save(_ preset: MUserDevelopPreset) -> MUserDevelopPreset {
        var resolved = preset
        resolved.name = resolved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolved.name.isEmpty { resolved.name = "未命名预设" }
        userPresets.append(resolved)
        persist()
        return resolved
    }

    @discardableResult
    func delete(id: String) -> Bool {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return false }
        userPresets.remove(at: index)
        persist()
        return true
    }

    func restore(_ preset: MUserDevelopPreset, at index: Int? = nil) {
        guard !userPresets.contains(where: { $0.id == preset.id }) else { return }
        if let index, index >= 0, index <= userPresets.count {
            userPresets.insert(preset, at: index)
        } else {
            userPresets.append(preset)
        }
        persist()
    }

    func preset(id: String) -> MUserDevelopPreset? {
        userPresets.first { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: presetsURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            userPresets = []
            return
        }
        userPresets = envelope.presets
    }

    private func persist() {
        let envelope = Envelope(presets: userPresets)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: presetsURL, options: .atomic)
    }
}

enum MScreen: Hashable {
    case home
    case camera
    case develop
    case grade
    case settings
}

/// 直出模式的画幅比例：拍摄永远是 RAW 全幅（4:3），比例只在渲染时居中裁切，
/// 同时写入库记录的 cropData，让调色台的裁切功能保持同一构图。
enum MDirectAspect: String, CaseIterable, Identifiable {
    /// 传感器 4:3 与 3:4 是同一比例，只保留竖幅一档（也是默认）。
    case portrait3_4 = "3:4"
    case square = "1:1"
    case portrait9_16 = "9:16"

    var id: String { rawValue }

    var label: String { rawValue }

    /// 目标宽高比（宽/高）。
    var ratio: Double {
        switch self {
        case .portrait3_4: return 3.0 / 4
        case .square: return 1
        case .portrait9_16: return 9.0 / 16
        }
    }

    /// 按拍摄朝向取目标宽高比（宽/高）。档位是竖幅语义；
    /// 横屏拍摄时画布是横的，取倒数得到「选定比例横过来」的完整横幅，
    /// 而不是把横幅硬裁成竖幅。1:1 两种朝向相同。
    func ratio(width: Int, height: Int) -> Double {
        width > height ? 1.0 / ratio : ratio
    }
}

/// 直出分辨率档位：按总像素（MP）显示，换算成长边交给导出预算。
/// 档位长边超过传感器最大长边时不提供（放大没有意义）。
enum MDirectResolution: String, CaseIterable, Identifiable {
    case mp8 = "8MP"
    case mp12 = "12MP"
    case mp24 = "24MP"
    case maximum = "MAX"

    var id: String { rawValue }
    var label: String { rawValue }

    /// 目标长边；nil 表示原片全尺寸。
    var longEdge: Int? {
        switch self {
        case .mp8: return 3264
        case .mp12: return 4032
        case .mp24: return 5712
        case .maximum: return nil
        }
    }

    /// 传感器最大长边能否撑起这一档。
    func available(forMaxEdge maxEdge: Int) -> Bool {
        guard let edge = longEdge else { return true }
        return maxEdge >= edge
    }
}

/// 直出保存请求：根视图负责决定是否保留 RAW 与工程。
struct MDirectSaveRequest {
    let rawURL: URL
    let renderedURL: URL
    let edit: PhotoEdit
    let grade: GradeRecipe
    /// 直出成片页选择的片边；保存时在后台合成到成片，不重新显影。
    var border = MFilmBorderConfig()
    /// 快速控制基线（含拍摄曝光）；重新打开显影台时快速滑条回到 0 不会丢掉拍摄曝光。
    var baseline: PhotoEdit? = nil
    /// 相机页选择的画幅比例；保存时写进 cropData，与调色台裁切共用。
    var aspect: MDirectAspect = .portrait3_4
}

enum MDirectSaveOutcome {
    case saved(String)
    case denied
    case failed(String)
}

/// 直出成片页「进入显影台」请求：把原始 DNG 入库，并沿用拍摄时选择的显影 / 调色预设。
struct MDirectDevelopRequest {
    let rawURL: URL
    let renderedURL: URL
    let edit: PhotoEdit
    let grade: GradeRecipe
    var baseline: PhotoEdit? = nil
    /// 相机页选择的画幅比例；入库时写进 cropData，调色台裁切直接呈现同一构图。
    var aspect: MDirectAspect = .portrait3_4
}

enum MDirectDevelopOutcome {
    case opened
    case failed(String)
}

/// 全局 Toast 的可选操作（例如删除预设后的“撤销”）。
struct MToastAction {
    let title: String
    let handler: () -> Void
}

enum MGradeEntry: Hashable {
    case handoff
    case direct
}
