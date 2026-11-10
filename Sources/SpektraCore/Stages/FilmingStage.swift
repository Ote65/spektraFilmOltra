import Foundation

final class FilmingStage {
    private let film: Profile
    private let filmRender: FilmRenderParams
    private let camera: CameraParams
    private let io: IOParams
    private let settings: SettingsParams
    private let lutService: SpectralLUTService
    private let enlargerService: EnlargerService
    private let colorReference: ColorReferenceService
    var pixelSizeUM: Double = 1.0

    init(film: Profile, filmRender: FilmRenderParams, camera: CameraParams, io: IOParams,
         settings: SettingsParams, lutService: SpectralLUTService,
         enlargerService: EnlargerService, colorReference: ColorReferenceService) {
        self.film = film
        self.filmRender = filmRender
        self.camera = camera
        self.io = io
        self.settings = settings
        self.lutService = lutService
        self.enlargerService = enlargerService
        self.colorReference = colorReference
        if enlargerService.printExposureCompensation {
            enlargerService.compensationEV = camera.exposureCompensationEV
        }
        self.lutService.inputGamutCompress = InputGamutSpec(
            active: io.inputGamutCompressActive,
            algorithm: io.inputGamutCompressAlgorithm,
            knee: io.inputGamutCompressKnee
        )
        let midgray = ImageRGB(width: 1, height: 1, data: [0.184, 0.184, 0.184])
        enlargerService.densitySpectralMidgray = simpleRGBToDensitySpectral(midgray)
        if enlargerService.printExposureCompensation {
            let scale = pow(2, camera.exposureCompensationEV)
            enlargerService.densitySpectralMidgrayComp = simpleRGBToDensitySpectral(
                ImageRGB(width: 1, height: 1, data: [0.184 * scale, 0.184 * scale, 0.184 * scale])
            )
        }
    }

    /// LUT 预览用：按相机曝光补偿更新印相中灰补偿密度（与 init 中的逻辑一致）。
    func updateCompensationMidgray(exposureEV: Double) {
        guard enlargerService.printExposureCompensation else { return }
        enlargerService.compensationEV = exposureEV
        let scale = pow(2, exposureEV)
        enlargerService.densitySpectralMidgrayComp = simpleRGBToDensitySpectral(
            ImageRGB(width: 1, height: 1,
                     data: [0.184 * scale, 0.184 * scale, 0.184 * scale])
        )
    }

    func autoExposure(_ image: ImageRGB) -> ImageRGB {
        guard camera.autoExposure else { return image }
        let small = Resize.smallPreview(image, maxSize: 256)
        let ev = AutoExposure.measureEV(
            image: small, colorSpace: io.inputColorSpace,
            applyCCTFDecoding: io.inputCCTFDecoding, method: camera.autoExposureMethod
        )
        return image.map { $0 * pow(2, ev) }
    }

    func expose(_ image: ImageRGB) -> ImageRGB {
        var raw = rgbToFilmRaw(image, colorSpace: io.inputColorSpace,
                               applyCCTFDecoding: io.inputCCTFDecoding)
        raw = raw.map { $0 * pow(2, camera.exposureCompensationEV) }
        raw = applyBoostHighlights(raw)
        raw = applyCameraDiffusion(raw)
        raw = applyGaussianBlurUM(raw, sigmaUM: camera.lensBlurUM)
        raw = applyHalation(raw)
        let correction = colorReference.blackWhiteFilmingExposureCorrection()
        raw = raw.map { $0 * correction }
        return raw.map { Vec3(ImageMath.log10Safe($0.x), ImageMath.log10Safe($0.y), ImageMath.log10Safe($0.z)) }
    }

    func develop(_ logRaw: ImageRGB) -> ImageRGB {
        let normalized = film.data.densityCurves.map { row in
            row.map { $0.isFinite ? $0 : 0 }
        }
        var curves = normalized
        for c in 0..<3 {
            var minValue = Double.infinity
            for row in normalized { minValue = min(minValue, row[c]) }
            for i in 0..<curves.count { curves[i][c] -= minValue }
        }
        let density = DensityCurves.developSimple(
            logRaw: logRaw,
            logExposure: film.data.logExposure,
            densityCurves: curves,
            gammaFactor: [filmRender.densityCurveGamma, filmRender.densityCurveGamma, filmRender.densityCurveGamma]
        )
        let corrected = Couplers.applyDensityCorrection(
            densityCMY: density,
            logRaw: logRaw,
            pixelSizeUM: pixelSizeUM,
            logExposure: film.data.logExposure,
            densityCurves: curves,
            params: filmRender.dirCouplers,
            profileType: film.info.type,
            gammaFactor: filmRender.densityCurveGamma
        )
        return Grain.apply(
            densityCMY: corrected,
            pixelSizeUM: pixelSizeUM,
            params: filmRender.grain,
            densityCurves: curves,
            densityCurvesLayers: film.data.densityCurvesLayers,
            profileType: film.info.type,
            bypass: false
        )
    }

    private func rgbToFilmRaw(_ rgb: ImageRGB, colorSpace: String, applyCCTFDecoding: Bool) -> ImageRGB {
        var sensitivity = film.data.logSensitivity.map { row in
            row.map { value in
                let v = pow(10, value)
                return v.isFinite ? v : 0
            }
        }
        if camera.filterUV[0] > 0 || camera.filterIR[0] > 0 {
            let illum = (try? Illuminants.standard(film.info.referenceIlluminant)) ?? []
            let band = BandPassFilter.compute(
                uv: (camera.filterUV[0], camera.filterUV[1], camera.filterUV[2]),
                ir: (camera.filterIR[0], camera.filterIR[1], camera.filterIR[2])
            )
            var normalization = [Double](repeating: 0, count: 3)
            var denominator = [Double](repeating: 0, count: 3)
            for w in 0..<sensitivity.count {
                for c in 0..<3 {
                    let base = sensitivity[w][c] * illum[w]
                    normalization[c] += base * band[w]
                    denominator[c] += base
                }
            }
            for w in 0..<sensitivity.count {
                for c in 0..<3 {
                    let norm = normalization[c] / max(denominator[c], 1e-20)
                    sensitivity[w][c] *= band[w] / max(norm, 1e-20)
                }
            }
        }

        guard settings.rgbToRawMethod == "hanatos2025" else { return rgb }
        var adaptation = film.hanatos2025Adaptation
        adaptation.applyWindow = settings.applyHanatos2025AdaptationWindow
        adaptation.applySurface = settings.applyHanatos2025AdaptationSurface
        adaptation.spectralGaussianBlur = settings.spectralGaussianBlur
        let tcLUT = lutService.getFilmingTCLUT(sensitivity: sensitivity, adaptation: adaptation)
        let illuminantXY = (try? Illuminants.xy(film.info.referenceIlluminant)) ?? (0.3127, 0.3290)
        let toXYZMatrix = ColorMath.rgbToXYZMatrix(
            spaceName: colorSpace, illuminantXY: illuminantXY, adaptation: ColorMath.cat16
        )
        var output = rgb
        for row in 0..<rgb.height {
            for col in 0..<rgb.width {
                let raw = SpectralUpsampling.rgbToRawHanatos(
                    rgb.pixel(col, row), sensitivity: sensitivity, colorSpace: colorSpace,
                    applyCCTFDecoding: applyCCTFDecoding,
                    referenceIlluminant: film.info.referenceIlluminant, tcLUT: tcLUT,
                    illuminantXY: illuminantXY, toXYZMatrix: toXYZMatrix
                )
                output.setPixel(col, row, raw)
            }
        }
        return output
    }

    private func simpleRGBToDensitySpectral(_ rgb: ImageRGB) -> [[Double]] {
        let raw = rgbToFilmRaw(rgb, colorSpace: "sRGB", applyCCTFDecoding: false)
        let logRaw = raw.map { Vec3(ImageMath.log10Safe($0.x), ImageMath.log10Safe($0.y), ImageMath.log10Safe($0.z)) }
        let density = DensityCurves.developSimple(
            logRaw: logRaw, logExposure: film.data.logExposure,
            densityCurves: film.data.densityCurves,
            gammaFactor: [filmRender.densityCurveGamma, filmRender.densityCurveGamma, filmRender.densityCurveGamma]
        )
        return DensityCurves.computeDensitySpectral(
            channelDensity: film.data.channelDensity, densityCMY: density,
            baseDensity: film.data.baseDensity
        )
    }

    private func applyBoostHighlights(_ image: ImageRGB) -> ImageRGB {
        SpatialEffects.boostHighlights(
            image,
            boostEV: filmRender.halation.boostEV,
            boostRange: filmRender.halation.boostRange,
            protectEV: filmRender.halation.protectEV
        )
    }
    private func applyCameraDiffusion(_ image: ImageRGB) -> ImageRGB {
        SpatialEffects.diffusionFilter(image, params: camera.diffusionFilter, pixelSizeUM: pixelSizeUM)
    }
    private func applyGaussianBlurUM(_ image: ImageRGB, sigmaUM: Double) -> ImageRGB {
        SpatialEffects.gaussianBlurUM(image, sigmaUM: sigmaUM, pixelSizeUM: pixelSizeUM)
    }
    private func applyHalation(_ image: ImageRGB) -> ImageRGB {
        SpatialEffects.halation(image, params: filmRender.halation, pixelSizeUM: pixelSizeUM)
    }
}

