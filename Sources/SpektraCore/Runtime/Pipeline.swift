import Foundation

/// 管线内可进入/退出的 tap，用于 LUT 预览的四段烘焙。
enum PipelineTap {
    case rgbIn
    case logEFilm
    case cmyFilm
    case logEPrint
    case rgbOut
}

struct PipelineResult {
    var rgbIn: ImageRGB
    var rgbPre: ImageRGB
    var logEFilm: ImageRGB
    var cmyFilm: ImageRGB
    var logEPrint: ImageRGB?
    var cmyPrint: ImageRGB?
    var rgbOut: ImageRGB
}

final class SimulationPipeline {
    let params: RuntimePhotoParams
    private let lutService: SpectralLUTService
    private let enlargerService: EnlargerService
    private let colorReference: ColorReferenceService
    private let filming: FilmingStage
    private let printing: PrintingStage
    private let scanning: ScanningStage
    private let keepTaps: Bool
    /// 协作式取消：每个阶段结束后检查；取消时返回已完成的中间结果。
    var shouldCancel: () -> Bool = { false }

    init(params: RuntimePhotoParams, lutService sharedLUT: SpectralLUTService? = nil,
         keepTaps: Bool = true) {
        var resolved = params
        if resolved.settings.previewMode {
            resolved.enlarger.lensBlur = 0
            resolved.filmRender.dirCouplers.diffusionSizeUM = 0
            resolved.filmRender.grain.active = false
            resolved.filmRender.grain.particleAreaUM2 = 0
            resolved.filmRender.grain.blur = 0
            resolved.printRender.glare.blur = 0
            resolved.camera.lensBlurUM = 0
            resolved.scanner.lensBlur = 0
            resolved.scanner.unsharpMask = [0, 0]
        }
        ParamsDigest.applyFilmSpecifics(&resolved)
        if resolved.debug.lutMode {
            resolved.debug.deactivateSpatialEffects = true
            resolved.debug.deactivateStochasticEffects = true
            resolved.camera.autoExposure = false
            resolved.camera.exposureCompensationEV = 0
            resolved.enlarger.printExposureCompensation = false
            resolved.enlarger.printExposure = 1.0
            resolved.filmRender.halation.boostEV = 0
            resolved.scanner.whiteCorrection = false
            resolved.scanner.blackCorrection = false
            resolved.scanner.unsharpMask = [0, 0]
        }
        if resolved.debug.deactivateSpatialEffects {
            resolved.filmRender.halation.active = false
            resolved.filmRender.halation.scatterCoreUM = [0, 0, 0]
            resolved.filmRender.halation.scatterTailUM = [0, 0, 0]
            resolved.filmRender.halation.halationFirstSigmaUM = [0, 0, 0]
            resolved.filmRender.dirCouplers.diffusionSizeUM = 0
            resolved.filmRender.grain.blur = 0
            resolved.filmRender.grain.blurDyeCloudsUM = 0
            resolved.printRender.glare.blur = 0
            resolved.camera.lensBlurUM = 0
            resolved.enlarger.lensBlur = 0
            resolved.enlarger.diffusionFilter.active = false
            resolved.camera.diffusionFilter.active = false
            resolved.scanner.lensBlur = 0
            resolved.scanner.unsharpMask = [0, 0]
        }
        if resolved.debug.deactivateStochasticEffects {
            resolved.filmRender.grain.active = false
            resolved.printRender.glare.active = false
        }
        if resolved.settings.neutralPrintFiltersFromDatabase,
           let filters = NeutralPrintFilters.lookup(
               filmStock: resolved.film.info.stock,
               printStock: resolved.print.info.stock,
               illuminant: resolved.enlarger.illuminant
           ) {
            resolved.enlarger.cFilterNeutral = filters.c
            resolved.enlarger.mFilterNeutral = filters.m
            resolved.enlarger.yFilterNeutral = filters.y
        }
        self.params = resolved
        self.keepTaps = keepTaps
        self.lutService = sharedLUT ?? SpectralLUTService(resolution: resolved.settings.lutResolution)
        self.lutService.updateResolution(resolved.settings.lutResolution)
        self.enlargerService = EnlargerService(params: resolved.enlarger)
        self.colorReference = ColorReferenceService(
            film: resolved.film, printProfile: resolved.print,
            densityMin: resolved.filmRender.grain.densityMin,
            blackCorrection: resolved.scanner.blackCorrection,
            whiteCorrection: resolved.scanner.whiteCorrection,
            blackLevel: resolved.scanner.blackLevel,
            whiteLevel: resolved.scanner.whiteLevel,
            scanFilm: resolved.io.scanFilm,
            outputColorSpace: resolved.io.outputColorSpace,
            outputCCTFEncoding: resolved.io.outputCCTFEncoding
        )
        self.filming = FilmingStage(
            film: resolved.film, filmRender: resolved.filmRender, camera: resolved.camera,
            io: resolved.io, settings: resolved.settings, lutService: lutService,
            enlargerService: enlargerService, colorReference: colorReference
        )
        self.printing = PrintingStage(
            film: resolved.film, filmRender: resolved.filmRender, printProfile: resolved.print,
            printRender: resolved.printRender, enlarger: resolved.enlarger, settings: resolved.settings,
            lutService: lutService, enlargerService: enlargerService, colorReference: colorReference
        )
        self.scanning = ScanningStage(
            film: resolved.film, filmRender: resolved.filmRender, printProfile: resolved.print,
            printRender: resolved.printRender, scanner: resolved.scanner, io: resolved.io,
            settings: resolved.settings, lutService: lutService, colorReference: colorReference
        )
    }

    func process(_ input: ImageRGB, progress: ((String, Int, Int) -> Void)? = nil) -> PipelineResult {
        let total = params.io.scanFilm ? 4 : 6
        var step = 0
        func advance(_ label: String) {
            step += 1
            progress?(label, step, total)
        }
        let empty = ImageRGB(width: 0, height: 0)
        let rgbIn = keepTaps ? input : empty

        // 全分辨率下每个整图缓冲是 293 MB（4032×3024，Double×3ch）。
        // `keepTaps == false`（导出、预览渲染）时用 Optional 逐段释放已经用完的中间结果，
        // 把同时存活的整图缓冲从 7 份压到 3 份；峰值内存随之下降。
        // `keepTaps == true`（LUT 四段烘焙）必须保留，行为与改动前完全一致。
        var pre: ImageRGB? = preprocess(input)
        advance("preprocess")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: empty, cmyFilm: empty,
                                   logEPrint: nil, cmyPrint: nil, rgbOut: pre ?? input)
        }
        var logFilm: ImageRGB? = filming.expose(pre ?? input)
        advance("filming.expose")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty, cmyFilm: empty,
                                   logEPrint: nil, cmyPrint: nil, rgbOut: pre ?? input)
        }
        if !keepTaps { pre = nil }
        var cmyFilm: ImageRGB? = filming.develop(logFilm ?? input)
        advance("filming.develop")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                                   cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                                   logEPrint: nil, cmyPrint: nil, rgbOut: cmyFilm ?? input)
        }
        if params.io.scanFilm {
            var out = scanning.scan(densityChannels: cmyFilm ?? input)
            out.sanitizeNonFinite()
            advance("scanning.scan_film")
            return PipelineResult(
                rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                logEPrint: nil, cmyPrint: nil, rgbOut: out
            )
        }
        if !keepTaps { logFilm = nil }
        var logPrint: ImageRGB? = printing.expose(cmyFilmDensity: cmyFilm ?? input)
        advance("printing.expose")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                                   cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                                   logEPrint: keepTaps ? (logPrint ?? empty) : empty,
                                   cmyPrint: nil, rgbOut: cmyFilm ?? input)
        }
        if !keepTaps { cmyFilm = nil }
        var cmyPrint: ImageRGB? = printing.develop(logRaw: logPrint ?? input)
        advance("printing.develop")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                                   cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                                   logEPrint: keepTaps ? (logPrint ?? empty) : empty,
                                   cmyPrint: keepTaps ? (cmyPrint ?? empty) : empty, rgbOut: cmyPrint ?? input)
        }
        if !keepTaps { logPrint = nil }
        var out = scanning.scan(densityChannels: cmyPrint ?? input)
        out.sanitizeNonFinite()
        advance("scanning.scan_print")
        return PipelineResult(
            rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
            logEFilm: keepTaps ? (logFilm ?? empty) : empty,
            cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
            logEPrint: keepTaps ? (logPrint ?? empty) : empty,
            cmyPrint: keepTaps ? (cmyPrint ?? empty) : empty, rgbOut: out
        )
    }

    /// 从指定 tap 进入、在指定 tap 退出，跳过前/后阶段；用于 LUT 预览烘焙。
    /// `inject != .rgbIn` 时不做 preprocess，按输入图长边更新胶片/印相像素尺寸。
    func processSegment(_ input: ImageRGB, inject: PipelineTap,
                        collect: PipelineTap) -> ImageRGB {
        guard input.width > 0, input.height > 0 else { return input }
        if inject != .rgbIn {
            let longEdge = max(input.width, input.height)
            let pixelSize = params.camera.filmFormatMM * 1000 / Double(max(longEdge, 1))
            filming.pixelSizeUM = pixelSize
            printing.pixelSizeUM = pixelSize
        }
        if inject == collect { return input }

        var image = input
        if inject == .rgbIn {
            image = preprocess(input)
            if collect == .rgbIn { return image }
        }

        if inject == .rgbIn || inject == .logEFilm {
            if inject == .rgbIn { image = filming.expose(image) }
            if collect == .logEFilm { return image }
            image = filming.develop(image)
            if collect == .cmyFilm { return image }
        }

        if params.io.scanFilm {
            if collect == .rgbOut {
                var out = scanning.scan(densityChannels: image)
                out.sanitizeNonFinite()
                return out
            }
            return image
        }

        if inject == .cmyFilm {
            image = printing.expose(cmyFilmDensity: image)
            if collect == .logEPrint { return image }
        } else if inject == .logEPrint || inject == .rgbOut {
            if collect == .logEPrint { return image }
        }

        image = printing.develop(logRaw: image)
        var out = scanning.scan(densityChannels: image)
        out.sanitizeNonFinite()
        return out
    }

    /// LUT 预览：按相机曝光补偿重算印相中灰补偿密度。
    func updatePreviewCompensationMidgray(exposureEV: Double) {
        filming.updateCompensationMidgray(exposureEV: exposureEV)
    }

    /// LUT 预览：当前补偿设置下的印相中灰曝光因子。
    func previewPrintExposureFactor() -> Double {
        printing.rawExposureFactorMidgray()
    }

    private func preprocess(_ input: ImageRGB) -> ImageRGB {
        var image = input
        image = filming.autoExposure(image)
        if params.io.crop {
            image = Resize.crop(image, center: params.io.cropCenter, size: params.io.cropSize)
        }
        let longEdge = max(image.width, image.height)
        filming.pixelSizeUM = params.camera.filmFormatMM * 1000 / Double(longEdge)
        if params.io.upscaleFactor != 1 {
            filming.pixelSizeUM /= params.io.upscaleFactor
            image = Resize.upscale(image, factor: params.io.upscaleFactor)
        }
        printing.pixelSizeUM = filming.pixelSizeUM
        return image
    }
}

