import Foundation

enum DensityCurves {
    static func computeDensitySpectral(channelDensity: [[Double]], densityCMY: ImageRGB,
                                       baseDensity: [Double]?) -> [[Double]] {
        let pixelCount = densityCMY.width * densityCMY.height
        let wavelengthCount = channelDensity.count
        var output = [[Double]](repeating: [Double](repeating: 0, count: wavelengthCount), count: pixelCount)
        for p in 0..<pixelCount {
            let r = Double(densityCMY.data[p * 3])
            let g = Double(densityCMY.data[p * 3 + 1])
            let b = Double(densityCMY.data[p * 3 + 2])
            for w in 0..<wavelengthCount {
                let row = channelDensity[w]
                var value = r * row[0] + g * row[1] + b * row[2]
                if let baseDensity, w < baseDensity.count {
                    value += baseDensity[w]
                }
                output[p][w] = value
            }
        }
        return output
    }

    /// 单像素的 CMY 密度 → 光谱密度（逐波长展开）。
    static func densitySpectrum(channelDensity: [[Double]], baseDensity: [Double]?,
                                r: Double, g: Double, b: Double,
                                wavelengthCount: Int) -> [Double] {
        var output = [Double](repeating: 0, count: wavelengthCount)
        for w in 0..<wavelengthCount {
            let row = channelDensity[w]
            var value = r * row[0] + g * row[1] + b * row[2]
            if let baseDensity, w < baseDensity.count { value += baseDensity[w] }
            output[w] = value
        }
        return output
    }

    /// 逐像素把 CMY 密度展开成光谱、乘以光强、再按权重积分成三通道。
    ///
    /// 替代 `computeDensitySpectral` + 逐像素循环的两段式写法：后者会为每个像素分配
    /// 一条波长数组（12MP × 70 波长 ≈ 400MB 临时内存 + 百万级堆分配），是扫描/印相阶段的主要开销。
    static func spectralIntegral(channelDensity: [[Double]], baseDensity: [Double]?,
                                 densityCMY: ImageRGB, weights: [[Double]],
                                 light: (Double, Int) -> Double,
                                 wavelengthCount: Int? = nil) -> ImageRGB {
        let width = densityCMY.width
        let height = densityCMY.height
        let pixelCount = width * height
        let count = min(min(channelDensity.count, weights.count), wavelengthCount ?? Int.max)
        guard count > 0, pixelCount > 0 else {
            return ImageRGB(width: width, height: height)
        }
        let wavelengthCount = count

        var flatDensity = [Double](repeating: 0, count: wavelengthCount * 3)
        var flatWeights = [Double](repeating: 0, count: wavelengthCount * 3)
        var flatBase = [Double](repeating: 0, count: wavelengthCount)
        for w in 0..<wavelengthCount {
            let row = channelDensity[w]
            let weight = weights[w]
            for c in 0..<3 {
                flatDensity[w * 3 + c] = row[c]
                flatWeights[w * 3 + c] = weight[c]
            }
            if let baseDensity, w < baseDensity.count { flatBase[w] = baseDensity[w] }
        }

        let input = densityCMY.data
        var output = [Double](repeating: 0, count: pixelCount * 3)
        output.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            flatDensity.withUnsafeBufferPointer { cd in
                flatWeights.withUnsafeBufferPointer { wt in
                    flatBase.withUnsafeBufferPointer { bd in
                        func row(_ y: Int) {
                            let start = y * width
                            for p in start..<(start + width) {
                                let offset = p * 3
                                let r = Double(input[offset])
                                let g = Double(input[offset + 1])
                                let b = Double(input[offset + 2])
                                var acc0 = 0.0
                                var acc1 = 0.0
                                var acc2 = 0.0
                                for w in 0..<wavelengthCount {
                                    let i = w * 3
                                    let densityValue = r * cd[i] + g * cd[i + 1] + b * cd[i + 2] + bd[w]
                                    let value = light(densityValue, w)
                                    acc0 += value * wt[i]
                                    acc1 += value * wt[i + 1]
                                    acc2 += value * wt[i + 2]
                                }
                                base[offset] = acc0
                                base[offset + 1] = acc1
                                base[offset + 2] = acc2
                            }
                        }
                        Interpolation.parallelRows(height: height, pixels: pixelCount, row)
                    }
                }
            }
        }
        return ImageRGB(width: width, height: height, data: output)
    }

    static func interpolateExposureToDensity(logExposureRGB: ImageRGB, densityCurves: [[Double]],
                                             logExposure: [Double], gammaFactor: [Double]) -> ImageRGB {
        var xAxis = [[Double]](repeating: [0, 0, 0], count: logExposure.count)
        for i in 0..<logExposure.count {
            for c in 0..<3 {
                xAxis[i][c] = logExposure[i] / gammaFactor[c]
            }
        }
        return Interpolation.interp1D(image: logExposureRGB, xAxisPerChannel: xAxis, yValues: densityCurves)
    }

    static func developSimple(logRaw: ImageRGB, logExposure: [Double], densityCurves: [[Double]],
                              gammaFactor: [Double]) -> ImageRGB {
        interpolateExposureToDensity(
            logExposureRGB: logRaw, densityCurves: densityCurves,
            logExposure: logExposure, gammaFactor: gammaFactor
        )
    }
}

