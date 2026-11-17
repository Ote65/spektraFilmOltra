import Foundation

final class PrintingStage {
    private let film: Profile
    private let filmRender: FilmRenderParams
    private let printProfile: Profile
    private let printRender: PrintRenderParams
    private let enlarger: EnlargerParams
    private let settings: SettingsParams
    private let lutService: SpectralLUTService
    private let enlargerService: EnlargerService
    private let colorReference: ColorReferenceService
    var pixelSizeUM: Double = 1.0

    init(film: Profile, filmRender: FilmRenderParams, printProfile: Profile, printRender: PrintRenderParams,
         enlarger: EnlargerParams, settings: SettingsParams, lutService: SpectralLUTService,
         enlargerService: EnlargerService, colorReference: ColorReferenceService) {
        self.film = film
        self.filmRender = filmRender
        self.printProfile = printProfile
        self.printRender = printRender
        self.enlarger = enlarger
        self.settings = settings
        self.lutService = lutService
        self.enlargerService = enlargerService
        self.colorReference = colorReference
    }

    func expose(cmyFilmDensity: ImageRGB) -> ImageRGB {
        let densityMin = filmRender.grain.densityMin
        let cmyBlackData = densityMin.map { -$0 }
        let cmyWhiteData = densityCurvesMax(film.data.densityCurves)
        colorReference.logRawPrintBlack = filmCMYToPrintLogRaw(ImageRGB(width: 1, height: 1, data: cmyBlackData))
        colorReference.logRawPrintWhite = filmCMYToPrintLogRaw(ImageRGB(width: 1, height: 1, data: cmyWhiteData))

        var raw = lutService.computeEnlarger(
            cmyData: cmyFilmDensity,
            function: { [unowned self] image in self.filmCMYToPrintLogRaw(image) },
            dataMin: cmyBlackData,
            dataMax: cmyWhiteData,
            useLUT: settings.useEnlargerLUT,
            key: enlargerCacheKey(dataMin: cmyBlackData, dataMax: cmyWhiteData)
        )
        raw.mapInPlace {
            Vec3(ImageMath.pow10Fast($0.x), ImageMath.pow10Fast($0.y), ImageMath.pow10Fast($0.z))
        }
        let exposure = enlarger.printExposure
        raw.mapInPlace { $0 * exposure }
        let correction = colorReference.blackWhitePrintingExposureCorrection()
        raw.mapInPlace { $0 * correction }
        raw = applyDiffusion(raw, params: enlarger.diffusionFilter, pixelSizeUM: pixelSizeUM)
        raw.mapInPlace { Vec3(ImageMath.log10Safe($0.x), ImageMath.log10Safe($0.y), ImageMath.log10Safe($0.z)) }
        return raw
    }

    func develop(logRaw: ImageRGB) -> ImageRGB {
        let curves = MorphCurves.applyPrintCurvesMorph(
            logExposure: printProfile.data.logExposure,
            model: printProfile.data.densityCurvesModel,
            params: printRender.densityCurvesMorph,
            profileType: printProfile.info.type
        )
        return DensityCurves.developSimple(
            logRaw: logRaw,
            logExposure: printProfile.data.logExposure,
            densityCurves: curves,
            gammaFactor: [1, 1, 1]
        )
    }

    /// 放大机 LUT 的缓存键：滤色片、预闪、印相补偿与黑白端点都会改变烘焙函数/域。
    private func enlargerCacheKey(dataMin: [Double], dataMax: [Double]) -> String {
        var parts = ["\(film.info.stock)|\(printProfile.info.stock)|\(enlarger.illuminant)"]
        let values: [Double] = [
            enlarger.yFilterShift, enlarger.mFilterShift,
            enlarger.cFilterNeutral, enlarger.mFilterNeutral, enlarger.yFilterNeutral,
            enlarger.preflashExposure, enlarger.preflashYFilterShift, enlarger.preflashMFilterShift,
            enlargerService.compensationEV,
            enlarger.printExposureCompensation ? 1 : 0,
            enlarger.normalizePrintExposure ? 1 : 0,
        ]
        for value in values + dataMin + dataMax {
            parts.append(String(format: "%.8f", value))
        }
        return parts.joined(separator: "|")
    }

    private func printResponse() -> (sensitivity: [[Double]], illuminant: [Double]) {
        let logSensitivity = printProfile.data.logSensitivity
        var sensitivity = [[Double]](repeating: [0, 0, 0], count: logSensitivity.count)
        for w in 0..<logSensitivity.count {
            for c in 0..<3 {
                let value = pow(10, logSensitivity[w][c])
                sensitivity[w][c] = value.isFinite ? value : 0
            }
        }
        let lightSource = (try? Illuminants.standard(enlarger.illuminant)) ?? []
        return (sensitivity, enlargerService.filteredIlluminant(lightSource))
    }

    /// LUT 预览用：当前补偿设置下的中灰曝光因子（不经过 LUT）。
    func rawExposureFactorMidgray() -> Double {
        let response = printResponse()
        return computeExposureFactorMidgray(
            sensitivity: response.sensitivity, printIlluminant: response.illuminant
        )
    }

    private func filmCMYToPrintLogRaw(_ cmyFilmDensity: ImageRGB) -> ImageRGB {
        let (sensitivity, printIlluminant) = printResponse()
        let wavelengthCount = min(min(film.data.channelDensity.count,
                                      sensitivity.count), printIlluminant.count)
        var raw = DensityCurves.spectralIntegral(
            channelDensity: film.data.channelDensity,
            baseDensity: film.data.baseDensity,
            densityCMY: cmyFilmDensity,
            weights: sensitivity,
            light: { density, w in self.densityToLight(density, printIlluminant[w]) },
            wavelengthCount: wavelengthCount
        )
        let pixelCount = cmyFilmDensity.width * cmyFilmDensity.height
        let factor = computeExposureFactorMidgray(sensitivity: sensitivity, printIlluminant: printIlluminant)
        raw.mapInPlace { $0 * factor }
        if enlarger.preflashExposure > 0 {
            let lightSource = (try? Illuminants.standard(enlarger.illuminant)) ?? []
            let preflashIlluminant = enlargerService.preflashIlluminant(lightSource)
            let baseDensity = film.data.baseDensity
            for p in 0..<pixelCount {
                for c in 0..<3 {
                    var sum = 0.0
                    for w in 0..<baseDensity.count {
                        let light = densityToLight(baseDensity[w], preflashIlluminant[w])
                        sum += light * sensitivity[w][c]
                    }
                    raw.data[p * 3 + c] += Float(sum * enlarger.preflashExposure)
                }
            }
        }
        raw.mapInPlace { Vec3(ImageMath.log10Safe($0.x), ImageMath.log10Safe($0.y), ImageMath.log10Safe($0.z)) }
        return raw
    }

    private func computeExposureFactorMidgray(sensitivity: [[Double]], printIlluminant: [Double]) -> Double {
        func factor(for densitySpectral: [[Double]]) -> Double {
            let density = densitySpectral[0]
            var raw = [Double](repeating: 0, count: 3)
            for c in 0..<3 {
                var sum = 0.0
                for w in 0..<density.count {
                    let light = densityToLight(density[w], printIlluminant[w])
                    sum += light * sensitivity[w][c]
                }
                raw[c] = max(sum, 1e-10)
            }
            let logMean = (log(raw[0]) + log(raw[1]) + log(raw[2])) / 3
            return 1.0 / exp(logMean)
        }

        guard let midgray = enlargerService.densitySpectralMidgray else { return 1 }
        let factorMidgray = factor(for: midgray)
        let factorComp: Double
        if let comp = enlargerService.densitySpectralMidgrayComp {
            factorComp = factor(for: comp)
        } else {
            factorComp = 1
        }
        if enlarger.printExposureCompensation && !enlarger.normalizePrintExposure {
            return factorComp / factorMidgray
        } else if enlarger.normalizePrintExposure && enlarger.printExposureCompensation {
            return factorComp
        } else if enlarger.normalizePrintExposure && !enlarger.printExposureCompensation {
            return factorMidgray
        }
        return 1
    }

    private func densityCurvesMax(_ curves: [[Double]]) -> [Double] {
        var result = [Double](repeating: -.infinity, count: 3)
        for row in curves {
            for c in 0..<3 where row[c].isFinite {
                result[c] = max(result[c], row[c])
            }
        }
        return result
    }

    private func densityToLight(_ density: Double, _ light: Double) -> Double {
        let value = ImageMath.pow10Fast(-density) * light
        return value.isFinite ? value : 0
    }

    private func applyDiffusion(_ image: ImageRGB, params: DiffusionFilterParams, pixelSizeUM: Double) -> ImageRGB {
        SpatialEffects.diffusionFilter(image, params: params, pixelSizeUM: pixelSizeUM)
    }
}

/// 快速「拍摄曝光」轴与印相自动亮度补偿的联动规则。
///
/// 补偿开启时，拍摄曝光的变化会被印相补偿归一化。原生 quick_controls 因此在拖动
/// 拍摄曝光时关闭补偿，让曝光变化可见；但如果基线本身带着非 0 拍摄曝光（相机的
/// -1 EV / -2 EV），关闭补偿会把基线的补偿一并撤掉，画面第一帧就按基线 EV 突变。
/// 这里在基线 EV 非 0 时保留补偿，改用印相曝光承载快速轴的 EV 偏移，保证滑条
/// 从 0 起步时亮度连续；基线 EV 为 0 时仍按原生行为关补偿。
enum QuickExposureMapping {
    /// 关补偿会撤掉非 0 的基线补偿，需要改用印相曝光承载。
    static func keepsPrintCompensation(baseline: PhotoEdit) -> Bool {
        baseline.enlarger.printExposureCompensation
            && abs(baseline.camera.exposureCompensationEV) > 1e-9
    }

    /// 印相曝光 = 基线印相曝光 × 2^-(快速曝光偏移 + 印相明暗偏移)。
    /// 两条快速轴共用 printExposure，必须一起计算，后拖动的轴不能覆盖另一条轴的偏移。
    static func printExposure(baseline: PhotoEdit, cameraEV: Double,
                              printEV: Double) -> Double {
        let carried = keepsPrintCompensation(baseline: baseline) ? cameraEV : 0
        let value = baseline.enlarger.printExposure * pow(2, -(carried + printEV))
        return min(max(value, 0.25), 4)
    }

    /// 把「拍摄曝光」的 q 写进 edit：EV 恒为基线 + q；补偿与印相曝光按上面的规则联动。
    static func apply(cameraExposure q: Double, baseline: PhotoEdit,
                      quickIntents: [String: Double], edit: inout PhotoEdit) {
        edit.camera.exposureCompensationEV = min(
            max(baseline.camera.exposureCompensationEV + q, -5), 5)
        if keepsPrintCompensation(baseline: baseline) {
            edit.enlarger.printExposureCompensation =
                baseline.enlarger.printExposureCompensation
            edit.enlarger.printExposure = printExposure(
                baseline: baseline,
                cameraEV: q,
                printEV: quickIntents["print_brightness"] ?? 0)
        } else {
            edit.enlarger.printExposureCompensation =
                abs(q) <= 1e-9 ? baseline.enlarger.printExposureCompensation : false
        }
    }

    /// 用户预设里的曝光补偿按「相对保存时基线的调整量」复现。
    /// 旧预设没有保存基线，仍按绝对值覆盖，避免误加拍摄曝光。
    static func presetExposure(absolute value: Double, savedBaseline: Double?,
                               currentBaseline: Double) -> Double {
        guard let savedBaseline else { return value }
        return min(max(value - savedBaseline + currentBaseline, -5), 5)
    }
}

