import Foundation

struct DiffusionFilterParams: Codable {
    var active: Bool = false
    var filterFamily: String = "black_pro_mist"
    var strength: Double = 0.5
    var spatialScale: Double = 1.0
    var haloWarmth: Double = 0.0
    var coreIntensity: Double = 1.0
    var coreSize: Double = 1.0
    var haloIntensity: Double = 1.0
    var haloSize: Double = 1.0
    var bloomIntensity: Double = 1.0
    var bloomSize: Double = 1.0
}

struct CameraParams: Codable {
    var exposureCompensationEV: Double = 0.0
    var autoExposure: Bool = true
    var autoExposureMethod: String = "center_weighted"
    var lensBlurUM: Double = 0.0
    var filmFormatMM: Double = 35.0
    var filterUV: [Double] = [0, 410, 8]
    var filterIR: [Double] = [0, 675, 15]
    var diffusionFilter = DiffusionFilterParams()
}

struct ScannerParams: Codable {
    var lensBlur: Double = 0.0
    var whiteCorrection: Bool = false
    var blackCorrection: Bool = false
    var whiteLevel: Double = 0.98
    var blackLevel: Double = 0.01
    var unsharpMask: [Double] = [0.7, 0.7]
}

struct GrainParams: Codable {
    var active: Bool = true
    var sublayersActive: Bool = true
    var particleAreaUM2: Double = 0.2
    var particleScale: [Double] = [1.6, 1.6, 3.2]
    var particleScaleLayers: [Double] = [2.0, 1.0, 0.5]
    var densityMin: [Double] = [0.03, 0.03, 0.03]
    var uniformity: [Double] = [0.97, 0.99, 0.97]
    var blur: Double = 0.65
    var blurDyeCloudsUM: Double = 1.0
    var microStructure: [Double] = [0.2, 30]
    var nSubLayers: Int = 1
}

struct HalationParams: Codable {
    var active: Bool = true
    var scatterAmount: Double = 1.0
    var scatterSpatialScale: Double = 1.0
    var halationAmount: Double = 1.0
    var halationSpatialScale: Double = 1.0
    var scatterCoreUM: [Double] = [2.2, 2.0, 1.6]
    var scatterTailUM: [Double] = [9.3, 9.7, 9.1]
    var scatterTailWeight: [Double] = [0.78, 0.65, 0.67]
    var boostEV: Double = 0.0
    var boostRange: Double = 0.3
    var protectEV: Double = 4.0
    var halationStrength: [Double] = [0.05, 0.015, 0.0]
    var halationFirstSigmaUM: [Double] = [65, 65, 65]
    var halationNBounces: Int = 3
    var halationBounceDecay: Double = 0.5
    var halationRenormalize: Bool = true
}

struct DirCouplersParams: Codable {
    var active: Bool = true
    var amount: Double = 1.0
    var inhibitionSameLayer: Double = 1.0
    var inhibitionInterlayer: Double = 1.0
    var gammaSameLayerRGB: [Double] = [0.341, 0.324, 0.273]
    var gammaInterlayerRToGB: [Double] = [0.355, 0.305]
    var gammaInterlayerGToRB: [Double] = [0.154, 0.358]
    var gammaInterlayerBToRG: [Double] = [0.171, 0.225]
    var diffusionSizeUM: Double = 20.0
    var diffusionTailUM: Double = 200.0
    var diffusionTailWeight: Double = 0.06
}

struct GlareParams: Codable {
    var active: Bool = true
    var percent: Double = 0.03
    var roughness: Double = 0.7
    var blur: Double = 0.5
}

struct FilmRenderParams: Codable {
    var densityCurveGamma: Double = 1.0
    var grain = GrainParams()
    var halation = HalationParams()
    var dirCouplers = DirCouplersParams()
    var glare = GlareParams()
}

struct PrintRenderParams: Codable {
    var glare = GlareParams()
    var densityCurvesMorph = PrintCurvesMorphParams()
}

struct IOParams: Codable {
    var inputColorSpace: String = "ProPhoto RGB"
    var inputCCTFDecoding: Bool = false
    var outputColorSpace: String = "sRGB"
    var outputCCTFEncoding: Bool = true
    var scanFilm: Bool = false
    var crop: Bool = false
    var cropCenter: [Double] = [0.5, 0.5]
    var cropSize: [Double] = [0.1, 0.1]
    var upscaleFactor: Double = 1.0
    var inputGamutCompressActive: Bool = true
    var inputGamutCompressAlgorithm: String = "xy"
    var inputGamutCompressKnee: [Double] = [0, 1, 6]
    var outputGamutCompressAlgorithm: String = "cam16ucs"
    var outputGamutCompressKnee: [Double] = [0, 1, 6]
}

struct DebugParams: Codable {
    var deactivateSpatialEffects: Bool = false
    var deactivateStochasticEffects: Bool = false
    var lutMode: Bool = false
}

/// RAW 解码参数：只在解码阶段生效，不进 RuntimePhotoParams。
/// 对应参考实现 `load_raw`（白平衡 / 色温 / 色调 / 镜头校正）。
struct LoadRawParams: Codable, Equatable {
    var whiteBalance: String = "as_shot"
    var temperature: Double = 5500
    var tint: Double = 1.0
    var lensCorrection: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case whiteBalance, temperature, tint, lensCorrection
    }

    /// 索引里可能没有这个子对象（旧版本只存过 as_shot + 镜头校正默认值），
    /// 逐字段回退默认，避免整库解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        whiteBalance = try container.decodeIfPresent(String.self, forKey: .whiteBalance) ?? "as_shot"
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 5500
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 1.0
        lensCorrection = try container.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? true
    }
}

struct SettingsParams: Codable {
    var rgbToRawMethod: String = "hanatos2025"
    var applyHanatos2025AdaptationWindow: Bool = true
    var applyHanatos2025AdaptationSurface: Bool = false
    var spectralGaussianBlur: Double = 0
    var useEnlargerLUT: Bool = true
    var useScannerLUT: Bool = true
    var lutResolution: Int = 17
    var useFastStats: Bool = false
    var previewMaxSize: Int = 640
    var previewMode: Bool = false
    var neutralPrintFiltersFromDatabase: Bool = true
}

struct RuntimePhotoParams {
    var film: Profile
    var print: Profile
    var filmRender = FilmRenderParams()
    var printRender = PrintRenderParams()
    var camera = CameraParams()
    var enlarger = EnlargerParams()
    var scanner = ScannerParams()
    var io = IOParams()
    var debug = DebugParams()
    var settings = SettingsParams()
}

