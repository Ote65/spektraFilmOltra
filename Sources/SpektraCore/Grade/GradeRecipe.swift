import Foundation

/// 调色台配方：与 Python `spektrafilm_gui/grade_recipe.py` 同字段、同默认值、同钳位。
/// 缺失键取默认、越界钳位、类型错误回退默认。

enum GradeRecipeConstants {
    static let schemaVersion = 1
    static let hslBandNames = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    static let hslBandLabels = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "品红"]
    static let hslBandHues: [Double] = [358, 25, 60, 115, 180, 225, 280, 330]
    static let zoneNames = ["shadows", "midtones", "highlights"]
    static let zoneLabels = ["阴影", "中间调", "高光"]
}

private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}

private func decodedNumber<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    _ key: K,
    default fallback: Double,
    min low: Double,
    max high: Double
) -> Double {
    guard let number = try? container.decodeIfPresent(Double.self, forKey: key),
          number.isFinite else { return fallback }
    return clamp(number, low, high)
}

private func decodedString<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    _ key: K,
    default fallback: String = ""
) -> String {
    guard let text = try? container.decodeIfPresent(String.self, forKey: key) else {
        return fallback
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 光影

struct LightRecipe: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var midtones: Double = 0
    var highlightRolloff: Double = 0
    var curveHighlights: Double = 0
    var curveLights: Double = 0
    var curveDarks: Double = 0
    var curveShadows: Double = 0

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, midtones
        case highlightRolloff = "highlight_rolloff"
        case curveHighlights = "curve_highlights"
        case curveLights = "curve_lights"
        case curveDarks = "curve_darks"
        case curveShadows = "curve_shadows"
    }

    init() {}

    init(
        exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
        shadows: Double = 0, whites: Double = 0, blacks: Double = 0,
        midtones: Double = 0, highlightRolloff: Double = 0,
        curveHighlights: Double = 0, curveLights: Double = 0,
        curveDarks: Double = 0, curveShadows: Double = 0
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.midtones = midtones
        self.highlightRolloff = highlightRolloff
        self.curveHighlights = curveHighlights
        self.curveLights = curveLights
        self.curveDarks = curveDarks
        self.curveShadows = curveShadows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = decodedNumber(c, .exposure, default: 0, min: -5, max: 5)
        contrast = decodedNumber(c, .contrast, default: 0, min: -100, max: 100)
        highlights = decodedNumber(c, .highlights, default: 0, min: -100, max: 100)
        shadows = decodedNumber(c, .shadows, default: 0, min: -100, max: 100)
        whites = decodedNumber(c, .whites, default: 0, min: -100, max: 100)
        blacks = decodedNumber(c, .blacks, default: 0, min: -100, max: 100)
        midtones = decodedNumber(c, .midtones, default: 0, min: -100, max: 100)
        highlightRolloff = decodedNumber(c, .highlightRolloff, default: 0, min: 0, max: 100)
        curveHighlights = decodedNumber(c, .curveHighlights, default: 0, min: -100, max: 100)
        curveLights = decodedNumber(c, .curveLights, default: 0, min: -100, max: 100)
        curveDarks = decodedNumber(c, .curveDarks, default: 0, min: -100, max: 100)
        curveShadows = decodedNumber(c, .curveShadows, default: 0, min: -100, max: 100)
    }
}

// MARK: - 色彩

struct HslBand: Codable, Equatable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    init() {}

    init(hue: Double, saturation: Double, luminance: Double) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = decodedNumber(c, .hue, default: 0, min: -100, max: 100)
        saturation = decodedNumber(c, .saturation, default: 0, min: -100, max: 100)
        luminance = decodedNumber(c, .luminance, default: 0, min: -100, max: 100)
    }
}

struct GradeZone: Codable, Equatable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0

    enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    init() {}

    init(hue: Double, saturation: Double, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = decodedNumber(c, .hue, default: 0, min: 0, max: 360)
        saturation = decodedNumber(c, .saturation, default: 0, min: 0, max: 100)
        luminance = decodedNumber(c, .luminance, default: 0, min: -100, max: 100)
    }
}

struct ColorGrading: Codable, Equatable {
    var shadows = GradeZone()
    var midtones = GradeZone()
    var highlights = GradeZone()
    var blending: Double = 50
    var balance: Double = 0

    enum CodingKeys: String, CodingKey {
        case shadows, midtones, highlights, blending, balance
    }

    init() {}

    init(
        shadows: GradeZone = GradeZone(), midtones: GradeZone = GradeZone(),
        highlights: GradeZone = GradeZone(), blending: Double = 50, balance: Double = 0
    ) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.blending = blending
        self.balance = balance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = (try? c.decodeIfPresent(GradeZone.self, forKey: .shadows))
            ?? GradeZone()
        midtones = (try? c.decodeIfPresent(GradeZone.self, forKey: .midtones))
            ?? GradeZone()
        highlights = (try? c.decodeIfPresent(GradeZone.self, forKey: .highlights))
            ?? GradeZone()
        blending = decodedNumber(c, .blending, default: 50, min: 0, max: 100)
        balance = decodedNumber(c, .balance, default: 0, min: -100, max: 100)
    }
}

struct ColorRecipe: Codable, Equatable {
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var hueShift: Double = 0
    var colorDensity: Double = 0
    var hsl: [HslBand] = Array(repeating: HslBand(), count: 8)
    var grading = ColorGrading()

    enum CodingKeys: String, CodingKey {
        case temperature, tint, vibrance, saturation
        case hueShift = "hue_shift"
        case colorDensity = "color_density"
        case hsl, grading
    }

    init() {}

    init(
        temperature: Double = 0, tint: Double = 0, vibrance: Double = 0,
        saturation: Double = 0, hueShift: Double = 0, colorDensity: Double = 0,
        hsl: [HslBand] = Array(repeating: HslBand(), count: 8),
        grading: ColorGrading = ColorGrading()
    ) {
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
        self.saturation = saturation
        self.hueShift = hueShift
        self.colorDensity = colorDensity
        self.hsl = hsl
        self.grading = grading
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = decodedNumber(c, .temperature, default: 0, min: -100, max: 100)
        tint = decodedNumber(c, .tint, default: 0, min: -100, max: 100)
        vibrance = decodedNumber(c, .vibrance, default: 0, min: -100, max: 100)
        saturation = decodedNumber(c, .saturation, default: 0, min: -100, max: 100)
        hueShift = decodedNumber(c, .hueShift, default: 0, min: -180, max: 180)
        colorDensity = decodedNumber(c, .colorDensity, default: 0, min: 0, max: 100)
        var bands = (try? c.decodeIfPresent([HslBand].self, forKey: .hsl))
            ?? []
        bands = Array(bands.prefix(8))
        while bands.count < 8 { bands.append(HslBand()) }
        hsl = bands
        grading = (try? c.decodeIfPresent(ColorGrading.self, forKey: .grading))
            ?? ColorGrading()
    }
}

// MARK: - 通透 / 画质 / 光学 / LUT

struct TransparencyRecipe: Codable, Equatable {
    var tonal: Double = 0
    var color: Double = 0

    enum CodingKeys: String, CodingKey { case tonal, color }

    init() {}

    init(tonal: Double, color: Double) {
        self.tonal = tonal
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tonal = decodedNumber(c, .tonal, default: 0, min: 0, max: 100)
        color = decodedNumber(c, .color, default: 0, min: 0, max: 100)
    }
}

struct QualityRecipe: Codable, Equatable {
    var clarity: Double = 0
    var texture: Double = 0
    var dehaze: Double = 0
    var sharpenAmount: Double = 0
    var sharpenRadius: Double = 1
    var sharpenThreshold: Double = 0
    var noiseLuminance: Double = 0
    var noiseColor: Double = 0

    enum CodingKeys: String, CodingKey {
        case clarity, texture, dehaze
        case sharpenAmount = "sharpen_amount"
        case sharpenRadius = "sharpen_radius"
        case sharpenThreshold = "sharpen_threshold"
        case noiseLuminance = "noise_luminance"
        case noiseColor = "noise_color"
    }

    init() {}

    init(
        clarity: Double = 0, texture: Double = 0, dehaze: Double = 0,
        sharpenAmount: Double = 0, sharpenRadius: Double = 1,
        sharpenThreshold: Double = 0, noiseLuminance: Double = 0,
        noiseColor: Double = 0
    ) {
        self.clarity = clarity
        self.texture = texture
        self.dehaze = dehaze
        self.sharpenAmount = sharpenAmount
        self.sharpenRadius = sharpenRadius
        self.sharpenThreshold = sharpenThreshold
        self.noiseLuminance = noiseLuminance
        self.noiseColor = noiseColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clarity = decodedNumber(c, .clarity, default: 0, min: -100, max: 100)
        texture = decodedNumber(c, .texture, default: 0, min: -100, max: 100)
        dehaze = decodedNumber(c, .dehaze, default: 0, min: -100, max: 100)
        sharpenAmount = decodedNumber(c, .sharpenAmount, default: 0, min: 0, max: 100)
        sharpenRadius = decodedNumber(c, .sharpenRadius, default: 1, min: 0.5, max: 3)
        sharpenThreshold = decodedNumber(c, .sharpenThreshold, default: 0, min: 0, max: 100)
        noiseLuminance = decodedNumber(c, .noiseLuminance, default: 0, min: 0, max: 100)
        noiseColor = decodedNumber(c, .noiseColor, default: 0, min: 0, max: 100)
    }
}

struct OpticsRecipe: Codable, Equatable {
    var vignetteAmount: Double = 0
    var vignetteMidpoint: Double = 50
    var vignetteRoundness: Double = 0
    var vignetteFeather: Double = 50
    var grainAmount: Double = 0
    var grainSize: Double = 25
    var grainRoughness: Double = 50
    var chromaticAberration: Double = 0

    enum CodingKeys: String, CodingKey {
        case vignetteAmount = "vignette_amount"
        case vignetteMidpoint = "vignette_midpoint"
        case vignetteRoundness = "vignette_roundness"
        case vignetteFeather = "vignette_feather"
        case grainAmount = "grain_amount"
        case grainSize = "grain_size"
        case grainRoughness = "grain_roughness"
        case chromaticAberration = "chromatic_aberration"
    }

    init() {}

    init(
        vignetteAmount: Double = 0, vignetteMidpoint: Double = 50,
        vignetteRoundness: Double = 0, vignetteFeather: Double = 50,
        grainAmount: Double = 0, grainSize: Double = 25,
        grainRoughness: Double = 50, chromaticAberration: Double = 0
    ) {
        self.vignetteAmount = vignetteAmount
        self.vignetteMidpoint = vignetteMidpoint
        self.vignetteRoundness = vignetteRoundness
        self.vignetteFeather = vignetteFeather
        self.grainAmount = grainAmount
        self.grainSize = grainSize
        self.grainRoughness = grainRoughness
        self.chromaticAberration = chromaticAberration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vignetteAmount = decodedNumber(c, .vignetteAmount, default: 0, min: -100, max: 100)
        vignetteMidpoint = decodedNumber(c, .vignetteMidpoint, default: 50, min: 0, max: 100)
        vignetteRoundness = decodedNumber(c, .vignetteRoundness, default: 0, min: -100, max: 100)
        vignetteFeather = decodedNumber(c, .vignetteFeather, default: 50, min: 0, max: 100)
        grainAmount = decodedNumber(c, .grainAmount, default: 0, min: 0, max: 100)
        grainSize = decodedNumber(c, .grainSize, default: 25, min: 0, max: 100)
        grainRoughness = decodedNumber(c, .grainRoughness, default: 50, min: 0, max: 100)
        chromaticAberration = decodedNumber(c, .chromaticAberration, default: 0, min: 0, max: 100)
    }
}

struct LutRecipe: Codable, Equatable {
    var path: String = ""
    var strength: Double = 100

    enum CodingKeys: String, CodingKey { case path, strength }

    init() {}

    init(path: String, strength: Double) {
        self.path = path
        self.strength = strength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = decodedString(c, .path)
        strength = decodedNumber(c, .strength, default: 100, min: 0, max: 100)
    }
}

// MARK: - 顶层

struct GradeRecipe: Codable, Equatable {
    var schema: Int = GradeRecipeConstants.schemaVersion
    var light = LightRecipe()
    var color = ColorRecipe()
    var transparency = TransparencyRecipe()
    var quality = QualityRecipe()
    var optics = OpticsRecipe()
    var lut = LutRecipe()

    enum CodingKeys: String, CodingKey {
        case schema, light, color, transparency, quality, optics, lut
    }

    init() {}

    init(
        light: LightRecipe = LightRecipe(), color: ColorRecipe = ColorRecipe(),
        transparency: TransparencyRecipe = TransparencyRecipe(),
        quality: QualityRecipe = QualityRecipe(), optics: OpticsRecipe = OpticsRecipe(),
        lut: LutRecipe = LutRecipe()
    ) {
        self.light = light
        self.color = color
        self.transparency = transparency
        self.quality = quality
        self.optics = optics
        self.lut = lut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = Int(decodedNumber(c, .schema, default: 1, min: 0, max: 1))
        light = (try? c.decodeIfPresent(LightRecipe.self, forKey: .light))
            ?? LightRecipe()
        color = (try? c.decodeIfPresent(ColorRecipe.self, forKey: .color))
            ?? ColorRecipe()
        transparency = (try? c.decodeIfPresent(TransparencyRecipe.self, forKey: .transparency))
            ?? TransparencyRecipe()
        quality = (try? c.decodeIfPresent(QualityRecipe.self, forKey: .quality))
            ?? QualityRecipe()
        optics = (try? c.decodeIfPresent(OpticsRecipe.self, forKey: .optics))
            ?? OpticsRecipe()
        lut = (try? c.decodeIfPresent(LutRecipe.self, forKey: .lut))
            ?? LutRecipe()
    }

    func value(for path: String) -> Double {
        switch path {
        case "light.exposure": return light.exposure
        case "light.contrast": return light.contrast
        case "light.highlights": return light.highlights
        case "light.shadows": return light.shadows
        case "light.whites": return light.whites
        case "light.blacks": return light.blacks
        case "light.midtones": return light.midtones
        case "light.highlight_rolloff": return light.highlightRolloff
        case "light.curve_highlights": return light.curveHighlights
        case "light.curve_lights": return light.curveLights
        case "light.curve_darks": return light.curveDarks
        case "light.curve_shadows": return light.curveShadows
        case "color.temperature": return color.temperature
        case "color.tint": return color.tint
        case "color.vibrance": return color.vibrance
        case "color.saturation": return color.saturation
        case "color.hue_shift": return color.hueShift
        case "color.color_density": return color.colorDensity
        case "transparency.tonal": return transparency.tonal
        case "transparency.color": return transparency.color
        case "quality.clarity": return quality.clarity
        case "quality.texture": return quality.texture
        case "quality.dehaze": return quality.dehaze
        case "quality.sharpen_amount": return quality.sharpenAmount
        case "quality.sharpen_radius": return quality.sharpenRadius
        case "quality.sharpen_threshold": return quality.sharpenThreshold
        case "quality.noise_luminance": return quality.noiseLuminance
        case "quality.noise_color": return quality.noiseColor
        case "optics.vignette_amount": return optics.vignetteAmount
        case "optics.vignette_midpoint": return optics.vignetteMidpoint
        case "optics.vignette_roundness": return optics.vignetteRoundness
        case "optics.vignette_feather": return optics.vignetteFeather
        case "optics.grain_amount": return optics.grainAmount
        case "optics.grain_size": return optics.grainSize
        case "optics.grain_roughness": return optics.grainRoughness
        case "optics.chromatic_aberration": return optics.chromaticAberration
        case "lut.strength": return lut.strength
        default: return 0
        }
    }

    mutating func setValue(_ value: Double, for path: String) {
        switch path {
        case "light.exposure": light.exposure = value
        case "light.contrast": light.contrast = value
        case "light.highlights": light.highlights = value
        case "light.shadows": light.shadows = value
        case "light.whites": light.whites = value
        case "light.blacks": light.blacks = value
        case "light.midtones": light.midtones = value
        case "light.highlight_rolloff": light.highlightRolloff = value
        case "light.curve_highlights": light.curveHighlights = value
        case "light.curve_lights": light.curveLights = value
        case "light.curve_darks": light.curveDarks = value
        case "light.curve_shadows": light.curveShadows = value
        case "color.temperature": color.temperature = value
        case "color.tint": color.tint = value
        case "color.vibrance": color.vibrance = value
        case "color.saturation": color.saturation = value
        case "color.hue_shift": color.hueShift = value
        case "color.color_density": color.colorDensity = value
        case "transparency.tonal": transparency.tonal = value
        case "transparency.color": transparency.color = value
        case "quality.clarity": quality.clarity = value
        case "quality.texture": quality.texture = value
        case "quality.dehaze": quality.dehaze = value
        case "quality.sharpen_amount": quality.sharpenAmount = value
        case "quality.sharpen_radius": quality.sharpenRadius = value
        case "quality.sharpen_threshold": quality.sharpenThreshold = value
        case "quality.noise_luminance": quality.noiseLuminance = value
        case "quality.noise_color": quality.noiseColor = value
        case "optics.vignette_amount": optics.vignetteAmount = value
        case "optics.vignette_midpoint": optics.vignetteMidpoint = value
        case "optics.vignette_roundness": optics.vignetteRoundness = value
        case "optics.vignette_feather": optics.vignetteFeather = value
        case "optics.grain_amount": optics.grainAmount = value
        case "optics.grain_size": optics.grainSize = value
        case "optics.grain_roughness": optics.grainRoughness = value
        case "optics.chromatic_aberration": optics.chromaticAberration = value
        case "lut.strength": lut.strength = value
        default: break
        }
    }

    var dirtyCount: Int {
        let neutral = GradeRecipe()
        var count = 0
        if light != neutral.light { count += 1 }
        if color != neutral.color { count += 1 }
        if transparency != neutral.transparency { count += 1 }
        if quality != neutral.quality { count += 1 }
        if optics != neutral.optics { count += 1 }
        if lut != neutral.lut { count += 1 }
        return count
    }
}
