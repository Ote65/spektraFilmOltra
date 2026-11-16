import Foundation

enum SpatialEffects {
    static func applyUnsharpMask(_ image: ImageRGB, sigma: Double, amount: Double) -> ImageRGB {
        guard sigma > 0, amount > 0 else { return image }
        let blurred = FastGaussian.filter(image, sigma: sigma)
        var output = image
        for i in 0..<image.data.count {
            let value = Double(image.data[i])
            let blur = Double(blurred.data[i])
            output.data[i] = Float(value + amount * (value - blur))
        }
        return output
    }

    /// 原地 USM：调用方传入独占缓冲时省掉一整张 12 MP 的 COW 拷贝。
    static func applyUnsharpMaskInPlace(_ image: inout ImageRGB, sigma: Double, amount: Double) {
        guard sigma > 0, amount > 0 else { return }
        let blurred = FastGaussian.filter(image, sigma: sigma)
        for i in 0..<image.data.count {
            let value = Double(image.data[i])
            let blur = Double(blurred.data[i])
            image.data[i] = Float(value + amount * (value - blur))
        }
    }

    static func gaussianBlurUM(_ image: ImageRGB, sigmaUM: Double, pixelSizeUM: Double) -> ImageRGB {
        guard sigmaUM > 0, pixelSizeUM > 0 else { return image }
        return FastGaussian.filter(image, sigma: sigmaUM / pixelSizeUM)
    }

    static func boostHighlights(_ image: ImageRGB, boostEV: Double, boostRange: Double,
                                protectEV: Double, midgray: Double = 0.184) -> ImageRGB {
        guard boostEV > 0 else { return image }
        let maximum = image.data.max() ?? 0
        guard maximum != 0 else { return image }
        let rawX0 = min(max(midgray * pow(2, protectEV), 0), Double(maximum))
        if rawX0 == Double(maximum) { return image }
        let a = pow(28.0, 1.0 - boostRange)
        let x0 = rawX0 / Double(maximum)
        let denominator = exp(a * (1 - x0)) - a * (1 - x0) - 1
        guard denominator > 0 else { return image }
        let k = (pow(2, boostEV) - 1) / denominator
        let boostScale = k * Double(maximum)
        let invMax = 1.0 / Double(maximum)
        var output = image
        for i in 0..<image.data.count {
            let value = Double(image.data[i])
            if value <= rawX0 {
                output.data[i] = Float(value)
            } else {
                let dx = (value - rawX0) * invMax
                output.data[i] = Float(value + boostScale * (exp(a * dx) - a * dx - 1))
            }
        }
        return output
    }

    static func halation(_ image: ImageRGB, params: HalationParams, pixelSizeUM: Double) -> ImageRGB {
        guard params.active, pixelSizeUM > 0 else { return image }
        let width = image.width
        let height = image.height
        let pixelCount = width * height
        var raw = image
        let scatterAmount = params.scatterAmount
        let scatterScale = params.scatterSpatialScale
        let tailWeights = params.scatterTailWeight
        let coreSigmas = params.scatterCoreUM.map { max($0 * scatterScale / pixelSizeUM, 1e-6) }
        let tailDecays = params.scatterTailUM.map { max($0 * scatterScale / pixelSizeUM, 1e-6) }
        if scatterAmount > 0 {
            // 逐通道处理：旧实现同时保留 core / tail 两张 RGB 整图，
            // 34 MP 下多占约 0.8 GB；这里每次只留一条通道缓冲。
            for c in 0..<3 {
                var plane = [Double](repeating: 0, count: pixelCount)
                for p in 0..<pixelCount { plane[p] = Double(raw.data[p * 3 + c]) }
                let core = FastGaussian.filterChannel(plane, width: width, height: height,
                                                      sigma: coreSigmas[c])
                let tail = FastGaussian.exponentialFilterChannel(
                    plane, width: width, height: height, decay: tailDecays[c], nGaussians: 3)
                let tailWeight = tailWeights[c]
                for p in 0..<pixelCount {
                    // 旧实现里 core / tail 是 ImageRGB，组合前已量化到 Float；
                    // 这里显式过一遍 Float，保证逐像素结果一致。
                    let scattered = (1 - tailWeight) * Double(Float(core[p]))
                        + tailWeight * Double(tail[p])
                    let original = Double(raw.data[p * 3 + c])
                    raw.data[p * 3 + c] = Float((1 - scatterAmount) * original + scatterAmount * scattered)
                }
            }
        }
        let strengths = params.halationStrength.map { $0 * params.halationAmount }
        let sigmas = params.halationFirstSigmaUM.map { max($0 * params.halationSpatialScale / pixelSizeUM, 1e-6) }
        let n = params.halationNBounces
        if n >= 1 && strengths.contains(where: { $0 > 0 }) {
            var decay = [Double](repeating: 0, count: n)
            for k in 1...n { decay[k - 1] = pow(params.halationBounceDecay, Double(k - 1)) }
            let sum = decay.reduce(0, +)
            decay = decay.map { $0 / sum }
            for c in 0..<3 where strengths[c] > 0 || params.halationRenormalize {
                var plane = [Double](repeating: 0, count: pixelCount)
                for p in 0..<pixelCount { plane[p] = Double(raw.data[p * 3 + c]) }
                // 旧实现的累加缓冲是 ImageRGB（Float），这里保持 Float 累加，
                // 避免改变多次反弹的量化顺序。
                var blur = [Float](repeating: 0, count: pixelCount)
                for k in 1...n {
                    let sigmaK = max(sigmas[c] * sqrt(Double(k)), 1e-6)
                    let component = FastGaussian.filterChannel(plane, width: width, height: height,
                                                               sigma: sigmaK)
                    let weight = decay[k - 1]
                    for p in 0..<pixelCount {
                        blur[p] += Float(weight * Double(Float(component[p])))
                    }
                }
                for p in 0..<pixelCount {
                    raw.data[p * 3 + c] += Float(strengths[c] * Double(blur[p]))
                }
            }
            if params.halationRenormalize {
                for c in 0..<3 {
                    let divisor = 1 + strengths[c]
                    for p in 0..<pixelCount {
                        raw.data[p * 3 + c] = Float(Double(raw.data[p * 3 + c]) / divisor)
                    }
                }
            }
        }
        return raw
    }

    static func diffusionFilter(_ image: ImageRGB, params: DiffusionFilterParams, pixelSizeUM: Double) -> ImageRGB {
        DiffusionFilter.apply(image, params: params, pixelSizeUM: pixelSizeUM)
    }
}
