import Foundation

final class ScanningStage {
    private let film: Profile
    private let filmRender: FilmRenderParams
    private let printProfile: Profile
    private let printRender: PrintRenderParams
    private let scanner: ScannerParams
    private let io: IOParams
    private let settings: SettingsParams
    private let lutService: SpectralLUTService
    private let colorReference: ColorReferenceService
    private let cmyToLogXYZ: (ImageRGB) -> ImageRGB

    init(film: Profile, filmRender: FilmRenderParams, printProfile: Profile, printRender: PrintRenderParams,
         scanner: ScannerParams, io: IOParams, settings: SettingsParams,
         lutService: SpectralLUTService, colorReference: ColorReferenceService) {
        self.film = film
        self.filmRender = filmRender
        self.printProfile = printProfile
        self.printRender = printRender
        self.scanner = scanner
        self.io = io
        self.settings = settings
        self.lutService = lutService
        self.colorReference = colorReference
        self.cmyToLogXYZ = ScanningStage.makeCmyToLogXYZ(film: film, printProfile: printProfile, io: io)
        colorReference.cmyToLogXYZ = self.cmyToLogXYZ
    }

    func scan(densityChannels: ImageRGB) -> ImageRGB {
        let rgb = densityToRGB(densityChannels, useLUT: settings.useScannerLUT)
        let blurred = applyBlurAndUnsharp(rgb)
        return applyCCTFEncoding(blurred)
    }

    private func densityToRGB(_ densityChannels: ImageRGB, useLUT: Bool) -> ImageRGB {
        let densityMin: [Double]
        let densityMax: [Double]
        let scanIlluminant: [Double]
        if io.scanFilm {
            densityMin = filmRender.grain.densityMin.map { -$0 }
            densityMax = densityCurvesMax(film.data.densityCurves)
            scanIlluminant = (try? Illuminants.standard(film.info.viewingIlluminant)) ?? []
        } else {
            densityMin = densityCurvesMin(printProfile.data.densityCurves)
            densityMax = densityCurvesMax(printProfile.data.densityCurves)
            scanIlluminant = (try? Illuminants.standard(printProfile.info.viewingIlluminant)) ?? []
        }

        // computeScanner 每次返回的都是独占的新缓冲，后续步骤全部原地复用，
        // 避免在 12 MP 上反复「新分配 + 旧缓冲仍存活」。数值与逐个 `map` 完全一致。
        var xyz = lutService.computeScanner(
            densityData: densityChannels,
            function: cmyToLogXYZ,
            dataMin: densityMin,
            dataMax: densityMax,
            useLUT: useLUT,
            key: scannerCacheKey(dataMin: densityMin, dataMax: densityMax)
        )
        xyz.mapInPlace {
            Vec3(ImageMath.pow10Fast($0.x), ImageMath.pow10Fast($0.y), ImageMath.pow10Fast($0.z))
        }
        colorReference.applyBlackWhiteXYZCorrection(&xyz)

        let cmfs = ColorDataStore.shared.cmfs
        let normalization = scanIlluminant.enumerated().reduce(0.0) { partial, item in
            partial + item.element * cmfs[item.offset][1]
        }
        var illuminantXYZ = Vec3(0, 0, 0)
        for w in 0..<min(scanIlluminant.count, cmfs.count) {
            illuminantXYZ.x += scanIlluminant[w] * cmfs[w][0]
            illuminantXYZ.y += scanIlluminant[w] * cmfs[w][1]
            illuminantXYZ.z += scanIlluminant[w] * cmfs[w][2]
        }
        illuminantXYZ = illuminantXYZ / normalization
        let illuminantXY = ColorMath.xyzToXY(illuminantXYZ)

        Glare.applyGlareInPlace(&xyz, illuminantXYZ: illuminantXYZ,
                                params: io.scanFilm ? nil : printRender.glare)
        // 色彩空间查表、CAT02 求逆、比例系数都是全图常量：搬出循环。
        // 注意这里**保留原来的运算顺序**（T·x ⊙ ratios → inv → fromXYZ），
        // 只是把每像素重算的常量提前算好，所以逐像素结果与旧实现完全一致；
        // 换成「合成一个 3x3 再乘一次」写法虽然等价，但会带来 ~1e-5 的相对偏差，
        // 破坏 `docs/parity_report.md` 的 1e-9 对拍门禁。
        let conversion = Self.colorConversion(spaceName: io.outputColorSpace, illuminantXY: illuminantXY)
        xyz.mapInPlace { conversion.apply($0) }
        return compressRGB(xyz)
    }

    /// 扫描 LUT 的缓存键：片基/相纸与黑白端点变化后必须重烘。
    private func scannerCacheKey(dataMin: [Double], dataMax: [Double]) -> String {
        var parts = ["\(film.info.stock)|\(printProfile.info.stock)|\(io.scanFilm)|\(io.outputColorSpace)"]
        for value in dataMin + dataMax {
            parts.append(String(format: "%.8f", value))
        }
        return parts.joined(separator: "|")
    }

    /// 与 `ColorMath.xyzToRGB(..., applyCCTFEncoding: false)` 等价的预计算版本。
    struct ColorConversion {
        var fromXYZ: Mat3
        var inverseCAT: Mat3
        var ratios: Vec3
        var adapts: Bool

        @inline(__always)
        func apply(_ xyz: Vec3) -> Vec3 {
            guard adapts else { return fromXYZ.apply(xyz) }
            return fromXYZ.apply(inverseCAT.apply(ColorMath.cat02.apply(xyz) * ratios))
        }
    }

    static func colorConversion(spaceName: String, illuminantXY: (Double, Double)?) -> ColorConversion {
        guard let space = ColorDataStore.shared.spaces[spaceName] else {
            return ColorConversion(fromXYZ: .identity, inverseCAT: .identity,
                                   ratios: Vec3(1, 1, 1), adapts: false)
        }
        guard let xy = illuminantXY else {
            return ColorConversion(fromXYZ: space.fromXYZ, inverseCAT: .identity,
                                   ratios: Vec3(1, 1, 1), adapts: false)
        }
        let source = ColorMath.xyToXYZ(xy.0, xy.1)
        let destination = space.whitepoint
        guard source.y > 1e-20, destination.y > 1e-20 else {
            return ColorConversion(fromXYZ: space.fromXYZ, inverseCAT: .identity,
                                   ratios: Vec3(1, 1, 1), adapts: false)
        }
        let transform = ColorMath.cat02
        let sourceLMS = transform.apply(source)
        let destinationLMS = transform.apply(destination)
        let ratios = Vec3(
            destinationLMS.x / sourceLMS.x,
            destinationLMS.y / sourceLMS.y,
            destinationLMS.z / sourceLMS.z
        )
        return ColorConversion(fromXYZ: space.fromXYZ, inverseCAT: transform.inverted(),
                               ratios: ratios, adapts: true)
    }

    private func applyBlurAndUnsharp(_ rgb: ImageRGB) -> ImageRGB {
        var output = applyGaussianBlur(rgb, sigma: scanner.lensBlur)
        let sigma = scanner.unsharpMask[0]
        let amount = scanner.unsharpMask[1]
        if sigma > 0 && amount > 0 {
            output = applyUnsharpMask(output, sigma: sigma, amount: amount)
        }
        return output
    }

    private func applyCCTFEncoding(_ rgb: ImageRGB) -> ImageRGB {
        guard io.outputCCTFEncoding else { return rgb }
        let kind = ColorMath.cctfKind(for: io.outputColorSpace)
        // 这里的 `rgbToRGB(from:to:)` 看似同一个空间、可以省掉，但它是 Python 参考
        // 实现的一部分：省掉会让输出相对偏差达到 ~1e-5，破坏 1e-9 对拍门禁。
        return rgb.map { value in
            let converted = ColorMath.rgbToRGB(value, from: io.outputColorSpace, to: io.outputColorSpace)
            return Vec3(
                ColorMath.cctfEncode(converted.x, kind: kind),
                ColorMath.cctfEncode(converted.y, kind: kind),
                ColorMath.cctfEncode(converted.z, kind: kind)
            )
        }
    }

    private static func makeCmyToLogXYZ(film: Profile, printProfile: Profile, io: IOParams) -> (ImageRGB) -> ImageRGB {
        let scanFilm = io.scanFilm
        let channelDensity = scanFilm ? film.data.channelDensity : printProfile.data.channelDensity
        let baseDensity = scanFilm ? film.data.baseDensity : printProfile.data.baseDensity
        let scanIlluminant = (try? Illuminants.standard(
            scanFilm ? film.info.viewingIlluminant : printProfile.info.viewingIlluminant
        )) ?? []
        let cmfs = ColorDataStore.shared.cmfs
        let normalization = scanIlluminant.enumerated().reduce(0.0) { partial, item in
            partial + item.element * cmfs[item.offset][1]
        }
        return { densityCMY in
            let wavelengthCount = min(channelDensity.count, scanIlluminant.count, cmfs.count)
            guard wavelengthCount > 0 else {
                return ImageRGB(width: densityCMY.width, height: densityCMY.height)
            }
            var integrated = DensityCurves.spectralIntegral(
                channelDensity: channelDensity,
                baseDensity: baseDensity,
                densityCMY: densityCMY,
                weights: cmfs,
                light: { density, w in
                    let value = ImageMath.pow10Fast(-density) * scanIlluminant[w]
                    return value.isFinite ? value : 0
                },
                wavelengthCount: wavelengthCount
            )
            Self.applyLogXYZ(into: &integrated, normalization: normalization)
            return integrated
        }
    }

    /// XYZ 积分 → log10。原地做：原先 `var output = integrated` + 同时持有 `source`
    /// 会强制一次 12 MP 的 COW 拷贝（293 MB），这里直接写回同一缓冲。
    private static func applyLogXYZ(into image: inout ImageRGB, normalization: Double) {
        let width = image.width
        let height = image.height
        let scale = 1.0 / max(normalization, 1e-20)
        image.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            func row(_ y: Int) {
                let start = y * width * 3
                for p in start..<(start + width * 3) {
                    base[p] = Float(ImageMath.log10Fast(Double(base[p]) * scale))
                }
            }
            Interpolation.parallelRows(height: height, pixels: width * height, row)
        }
    }

    private func densityCurvesMax(_ curves: [[Double]]) -> [Double] {
        var result = [Double](repeating: -.infinity, count: 3)
        for row in curves {
            for c in 0..<3 where row[c].isFinite { result[c] = max(result[c], row[c]) }
        }
        return result
    }

    private func densityCurvesMin(_ curves: [[Double]]) -> [Double] {
        var result = [Double](repeating: .infinity, count: 3)
        for row in curves {
            for c in 0..<3 where row[c].isFinite { result[c] = min(result[c], row[c]) }
        }
        return result
    }

    private func applyGaussianBlur(_ image: ImageRGB, sigma: Double) -> ImageRGB {
        SpatialEffects.gaussianBlurUM(image, sigmaUM: sigma, pixelSizeUM: 1)
    }

    private func applyUnsharpMask(_ image: ImageRGB, sigma: Double, amount: Double) -> ImageRGB {
        SpatialEffects.applyUnsharpMask(image, sigma: sigma, amount: amount)
    }

    private func addGlare(_ xyz: ImageRGB, illuminantXYZ: Vec3, glare: GlareParams?) -> ImageRGB {
        Glare.addGlare(xyz, illuminantXYZ: illuminantXYZ, params: glare)
    }

    private func compressRGB(_ rgb: ImageRGB) -> ImageRGB {
        OutputGamutCompression.apply(
            rgb,
            algorithm: io.outputGamutCompressAlgorithm,
            knee: io.outputGamutCompressKnee,
            outputColorSpace: io.outputColorSpace
        )
    }
}

