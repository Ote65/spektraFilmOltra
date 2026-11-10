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
        var raw = image
        let scatterAmount = params.scatterAmount
        let scatterScale = params.scatterSpatialScale
        let tailWeights = params.scatterTailWeight
        let coreSigmas = params.scatterCoreUM.map { max($0 * scatterScale / pixelSizeUM, 1e-6) }
        let tailDecays = params.scatterTailUM.map { max($0 * scatterScale / pixelSizeUM, 1e-6) }
        if scatterAmount > 0 {
            let core = FastGaussian.filter(raw, sigma: coreSigmas)
            let tail = FastGaussian.exponentialFilter(raw, decay: tailDecays, nGaussians: 3)
            for c in 0..<3 {
                for i in 0..<(image.width * image.height) {
                    let scattered = (1 - tailWeights[c]) * Double(core.data[i * 3 + c])
                        + tailWeights[c] * Double(tail.data[i * 3 + c])
                    let original = Double(raw.data[i * 3 + c])
                    raw.data[i * 3 + c] = Float((1 - scatterAmount) * original + scatterAmount * scattered)
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
            var blur = ImageRGB(width: image.width, height: image.height)
            for k in 1...n {
                let sigmaK = sigmas.map { max($0 * sqrt(Double(k)), 1e-6) }
                let component = FastGaussian.filter(raw, sigma: sigmaK)
                let weight = decay[k - 1]
                for i in 0..<blur.data.count { blur.data[i] += Float(weight * Double(component.data[i])) }
            }
            for c in 0..<3 {
                for i in 0..<(image.width * image.height) {
                    raw.data[i * 3 + c] += Float(strengths[c] * Double(blur.data[i * 3 + c]))
                }
            }
            if params.halationRenormalize {
                for c in 0..<3 {
                    for i in 0..<(image.width * image.height) {
                        raw.data[i * 3 + c] = Float(Double(raw.data[i * 3 + c]) / (1 + strengths[c]))
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
