import Foundation

final class ColorReferenceService {
    private let film: Profile
    private let printProfile: Profile
    private let densityMin: [Double]
    private let scanFilm: Bool
    private let outputColorSpace: String
    private let outputCCTFEncoding: Bool

    private let blackCorrection: Bool
    private let whiteCorrection: Bool
    private let blackLevel: Double
    private let whiteLevel: Double

    private var yBlack: Double?
    private var yWhite: Double?

    var cmyToLogXYZ: ((ImageRGB) -> ImageRGB)?
    var logRawPrintBlack: ImageRGB?
    var logRawPrintWhite: ImageRGB?

    init(film: Profile, printProfile: Profile, densityMin: [Double],
         blackCorrection: Bool, whiteCorrection: Bool,
         blackLevel: Double, whiteLevel: Double,
         scanFilm: Bool, outputColorSpace: String, outputCCTFEncoding: Bool) {
        self.film = film
        self.printProfile = printProfile
        self.densityMin = densityMin
        self.blackCorrection = blackCorrection
        self.whiteCorrection = whiteCorrection
        self.blackLevel = ColorMath.cctfDecode(blackLevel, kind: .srgb)
        self.whiteLevel = ColorMath.cctfDecode(whiteLevel, kind: .srgb)
        self.scanFilm = scanFilm
        self.outputColorSpace = outputColorSpace
        self.outputCCTFEncoding = outputCCTFEncoding
    }

    private func updateCMYBlackWhiteReferences(inPrint: Bool = false) {
        guard blackCorrection || whiteCorrection else { return }
        if scanFilm && film.info.type == "negative" { return }
        guard let cmyToLogXYZ else { return }

        if scanFilm && film.info.type == "positive" && !inPrint {
            let cmyBlack = ImageRGB(width: 1, height: 1, data: densityCurvesMax(film.data.densityCurves))
            let cmyWhite = ImageRGB(width: 1, height: 1, data: [0, 0, 0])
            let blackXYZ = cmyToLogXYZ(cmyBlack)
            let whiteXYZ = cmyToLogXYZ(cmyWhite)
            yBlack = pow(10, Double(blackXYZ.data[1]))
            yWhite = pow(10, Double(whiteXYZ.data[1]))
        } else if !scanFilm && printProfile.info.type == "negative" && inPrint {
            guard let logRawPrintBlack, let logRawPrintWhite else { return }
            let cmyBlack = DensityCurves.developSimple(
                logRaw: logRawPrintBlack,
                logExposure: printProfile.data.logExposure,
                densityCurves: printProfile.data.densityCurves,
                gammaFactor: [1, 1, 1]
            )
            let cmyWhite = DensityCurves.developSimple(
                logRaw: logRawPrintWhite,
                logExposure: printProfile.data.logExposure,
                densityCurves: printProfile.data.densityCurves,
                gammaFactor: [1, 1, 1]
            )
            let blackXYZ = cmyToLogXYZ(cmyBlack)
            let whiteXYZ = cmyToLogXYZ(cmyWhite)
            yBlack = pow(10, Double(blackXYZ.data[1]))
            yWhite = pow(10, Double(whiteXYZ.data[1]))
        }
    }

    private func correctionFunction() -> (m: Double, q: Double, midgray: Double) {
        var white = whiteLevel
        var black = blackLevel
        if blackCorrection && !whiteCorrection, let yWhite { white = yWhite }
        if whiteCorrection && !blackCorrection, let yBlack { black = yBlack }
        let m = (white - black) / ((yWhite ?? 0) - (yBlack ?? 0) + 1e-10)
        let q = black - m * (yBlack ?? 0)
        let midgray = (0.184 - q) / m
        return (m, q, midgray)
    }

    func blackWhiteFilmingExposureCorrection() -> Double {
        guard blackCorrection || whiteCorrection else { return 1 }
        guard film.info.type != "negative" else { return 1 }
        guard scanFilm, film.info.type == "positive" else { return 1 }
        let densityMidgray = -log10(0.184)
        updateCMYBlackWhiteReferences(inPrint: false)
        guard let cmyToLogXYZ else { return 1 }
        let black = ImageRGB(width: 1, height: 1, data: densityCurvesMax(film.data.densityCurves))
        let white = ImageRGB(width: 1, height: 1, data: [0, 0, 0])
        _ = cmyToLogXYZ(black)
        _ = cmyToLogXYZ(white)
        let corrected = correctionFunction().midgray
        let densityMidgrayCorrected = -log10(corrected)
        let densityCurveAverage = channelMean(film.data.densityCurves)
        let densityMinAverage = mean(film.data.baseDensity)
        let logExposureMidgrayCorrected = -interp(
            x: -(densityMidgrayCorrected - densityMinAverage),
            xp: densityCurveAverage.map { -$0 },
            fp: film.data.logExposure
        )
        let logExposureMidgray = -interp(
            x: -(densityMidgray - densityMinAverage),
            xp: densityCurveAverage.map { -$0 },
            fp: film.data.logExposure
        )
        let exposureCorrection = pow(10, logExposureMidgrayCorrected - logExposureMidgray)
        return 1 / exposureCorrection
    }

    func blackWhitePrintingExposureCorrection() -> Double {
        guard blackCorrection || whiteCorrection else { return 1 }
        guard printProfile.info.type == "negative" else { return 1 }
        let densityMidgray = -log10(0.184)
        updateCMYBlackWhiteReferences(inPrint: true)
        let corrected = correctionFunction().midgray
        let densityMidgrayCorrected = -log10(corrected)
        let densityCurveAverage = channelMean(printProfile.data.densityCurves)
        let densityMinAverage = mean(printProfile.data.baseDensity)
        let logExposureMidgrayCorrected = interp(
            x: densityMidgrayCorrected - densityMinAverage,
            xp: densityCurveAverage, fp: printProfile.data.logExposure
        )
        let logExposureMidgray = interp(
            x: densityMidgray - densityMinAverage,
            xp: densityCurveAverage, fp: printProfile.data.logExposure
        )
        return pow(10, logExposureMidgrayCorrected - logExposureMidgray)
    }

    func blackWhiteXYZCorrection(_ xyz: ImageRGB) -> ImageRGB {
        var output = xyz
        applyBlackWhiteXYZCorrection(&output)
        return output
    }

    /// 原地版本：调用方传入独占临时缓冲时用，省掉 293 MB 的 COW 拷贝。
    /// 每个像素只读自己的 Y 再做通道缩放，写回同一位置是安全的。
    func applyBlackWhiteXYZCorrection(_ xyz: inout ImageRGB) {
        guard blackCorrection || whiteCorrection else { return }
        if scanFilm && film.info.type == "negative" { return }
        let (m, q, _) = correctionFunction()
        let count = xyz.width * xyz.height
        xyz.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for p in 0..<count {
                let y = Double(base[p * 3 + 1])
                let corrected = min(max(m * y + q, 0), 1)
                let scale = corrected / (y + 1e-10)
                base[p * 3] = Float(Double(base[p * 3]) * scale)
                base[p * 3 + 1] = Float(corrected)
                base[p * 3 + 2] = Float(Double(base[p * 3 + 2]) * scale)
            }
        }
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

    private func channelMean(_ curves: [[Double]]) -> [Double] {
        var result = [Double](repeating: 0, count: 3)
        for row in curves {
            for c in 0..<3 { result[c] += row[c] }
        }
        let count = Double(curves.count)
        return result.map { $0 / count }
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private func interp(x: Double, xp: [Double], fp: [Double]) -> Double {
        guard let first = xp.first, let last = xp.last, fp.count == xp.count else { return .nan }
        if x <= first { return fp[0] }
        if x >= last { return fp[fp.count - 1] }
        var low = 0
        var high = xp.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if xp[mid] <= x { low = mid } else { high = mid }
        }
        let t = (x - xp[low]) / (xp[low + 1] - xp[low])
        return fp[low] + t * (fp[low + 1] - fp[low])
    }
}

