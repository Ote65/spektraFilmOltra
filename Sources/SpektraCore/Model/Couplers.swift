import Foundation

/// DIR couplers：显影中释放的抑制剂对同层/邻层曝光的反馈。
/// 逐行对应 Python `model/couplers.py`，不得改动公式与次序。
enum Couplers {
    /// numpy `np.interp` 语义：升序 xp、端点夹取；用二分查找（与 numpy 行为一致）。
    static func npInterp(_ x: Double, xp: [Double], fp: [Double]) -> Double {
        let n = xp.count
        guard n > 0, fp.count == n else { return .nan }
        if n == 1 { return fp[0] }
        if x <= xp[0] { return fp[0] }
        if x >= xp[n - 1] { return fp[n - 1] }
        var low = 0
        var high = n - 1
        while low < high {
            let mid = (low + high) / 2
            if xp[mid] <= x { low = mid + 1 } else { high = mid }
        }
        let j = low - 1
        if j < 0 { return fp[0] }
        if j >= n - 1 { return fp[n - 1] }
        let dx = xp[j + 1] - xp[j]
        guard dx != 0 else { return fp[j] }
        let slope = (fp[j + 1] - fp[j]) / dx
        return slope * (x - xp[j]) + fp[j]
    }

    static func nanmaxPerChannel(_ curves: [[Double]]) -> [Double] {
        var result = [Double](repeating: -.infinity, count: 3)
        for row in curves {
            for c in 0..<min(3, row.count) where row[c].isFinite {
                result[c] = max(result[c], row[c])
            }
        }
        return result
    }

    static func computeMatrix(_ p: DirCouplersParams) -> [[Double]] {
        let selfGains = p.gammaSameLayerRGB.map { $0 * p.inhibitionSameLayer }
        var matrix = [[Double]](repeating: [0, 0, 0], count: 3)
        matrix[0][1] = p.gammaInterlayerRToGB[0]
        matrix[0][2] = p.gammaInterlayerRToGB[1]
        matrix[1][0] = p.gammaInterlayerGToRB[0]
        matrix[1][2] = p.gammaInterlayerGToRB[1]
        matrix[2][0] = p.gammaInterlayerBToRG[0]
        matrix[2][1] = p.gammaInterlayerBToRG[1]
        for r in 0..<3 {
            for c in 0..<3 { matrix[r][c] *= p.inhibitionInterlayer }
        }
        for c in 0..<3 { matrix[c][c] += selfGains[c] }
        return matrix
    }

    static func curvesBeforeCouplers(densityCurves: [[Double]], logExposure: [Double],
                                     matrix: [[Double]], positive: Bool) -> [[Double]] {
        let rows = densityCurves.count
        let densityMax = nanmaxPerChannel(densityCurves)
        var silver = densityCurves
        if positive {
            for j in 0..<rows {
                for c in 0..<3 { silver[j][c] = densityMax[c] - densityCurves[j][c] }
            }
        }
        var couplersAmount = [[Double]](repeating: [0, 0, 0], count: rows)
        for j in 0..<rows {
            for m in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += silver[j][k] * matrix[k][m] }
                couplersAmount[j][m] = sum
            }
        }
        var corrected = [[Double]](repeating: [0, 0, 0], count: rows)
        for i in 0..<3 {
            let xp = couplersAmount.indices.map { logExposure[$0] - couplersAmount[$0][i] }
            let fp = densityCurves.indices.map { positive ? -densityCurves[$0][i] : densityCurves[$0][i] }
            for j in 0..<rows {
                let value = npInterp(logExposure[j], xp: xp, fp: fp)
                corrected[j][i] = positive ? -value : value
            }
        }
        return corrected
    }

    static func exposureCorrection(logRaw: ImageRGB, densityCMY: ImageRGB, densityMax: [Double],
                                   matrix: [[Double]], diffusionSizePixel: Double,
                                   diffusionTailPixel: Double, diffusionTailWeight: Double,
                                   positive: Bool) -> ImageRGB {
        let pixelCount = densityCMY.width * densityCMY.height
        var correction = ImageRGB(width: densityCMY.width, height: densityCMY.height)
        for p in 0..<pixelCount {
            let base = p * 3
            let d0 = Double(densityCMY.data[base])
            let d1 = Double(densityCMY.data[base + 1])
            let d2 = Double(densityCMY.data[base + 2])
            let s0 = positive ? densityMax[0] - d0 : d0
            let s1 = positive ? densityMax[1] - d1 : d1
            let s2 = positive ? densityMax[2] - d2 : d2
            for m in 0..<3 {
                let value = s0 * matrix[0][m] + s1 * matrix[1][m] + s2 * matrix[2][m]
                correction.data[base + m] = Float(value)
            }
        }
        if diffusionSizePixel > 0 {
            let gaussian = FastGaussian.filter(correction, sigma: diffusionSizePixel)
            let tail = FastGaussian.exponentialFilter(correction, decay: diffusionTailPixel, nGaussians: 3)
            for i in 0..<correction.data.count {
                let gaussianValue = Double(gaussian.data[i])
                let tailValue = Double(tail.data[i])
                correction.data[i] = Float((1 - diffusionTailWeight) * gaussianValue
                    + diffusionTailWeight * tailValue)
            }
        }
        var output = logRaw
        for i in 0..<output.data.count {
            output.data[i] = Float(Double(logRaw.data[i]) - Double(correction.data[i]))
        }
        return output
    }

    static func applyDensityCorrection(densityCMY: ImageRGB,
                                       logRaw: ImageRGB,
                                       pixelSizeUM: Double,
                                       logExposure: [Double],
                                       densityCurves: [[Double]],
                                       params: DirCouplersParams,
                                       profileType: String,
                                       gammaFactor: Double) -> ImageRGB {
        guard params.active else { return densityCMY }
        let positive = profileType == "positive"
        var matrix = computeMatrix(params)
        for r in 0..<3 {
            for c in 0..<3 { matrix[r][c] *= params.amount }
        }
        let curves0 = curvesBeforeCouplers(
            densityCurves: densityCurves, logExposure: logExposure,
            matrix: matrix, positive: positive
        )
        let densityMax = nanmaxPerChannel(densityCurves)
        let sizePixel = params.diffusionSizeUM > 0 ? params.diffusionSizeUM / pixelSizeUM : 0
        let tailPixel = params.diffusionSizeUM > 0 ? params.diffusionTailUM / pixelSizeUM : 0
        let logRaw0 = exposureCorrection(
            logRaw: logRaw, densityCMY: densityCMY, densityMax: densityMax,
            matrix: matrix, diffusionSizePixel: sizePixel,
            diffusionTailPixel: tailPixel, diffusionTailWeight: params.diffusionTailWeight,
            positive: positive
        )
        return DensityCurves.interpolateExposureToDensity(
            logExposureRGB: logRaw0, densityCurves: curves0,
            logExposure: logExposure, gammaFactor: [gammaFactor, gammaFactor, gammaFactor]
        )
    }
}
