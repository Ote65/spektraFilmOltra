import Foundation

struct DiffusionGroup {
    var lambdaUM: Double
    var spread: Double
    var nComponents: Int
    var alpha: Double

    init(lambdaUM: Double, spread: Double, nComponents: Int, alpha: Double = 3.0) {
        self.lambdaUM = lambdaUM
        self.spread = spread
        self.nComponents = nComponents
        self.alpha = alpha
    }
}

struct DiffusionFamily {
    var core: DiffusionGroup
    var halo: DiffusionGroup
    var bloom: DiffusionGroup
    var wCore: Double
    var wHalo: Double
    var wBloom: Double
    var haloWarmthBase: Double
}

struct DiffusionOverrides {
    var coreIntensity: Double = 1
    var haloIntensity: Double = 1
    var bloomIntensity: Double = 1
    var coreSize: Double = 1
    var haloSize: Double = 1
    var bloomSize: Double = 1

    var isIdentity: Bool {
        coreIntensity == 1 && haloIntensity == 1 && bloomIntensity == 1
            && coreSize == 1 && haloSize == 1 && bloomSize == 1
    }

    init() {}

    init(params: DiffusionFilterParams) {
        coreIntensity = params.coreIntensity
        haloIntensity = params.haloIntensity
        bloomIntensity = params.bloomIntensity
        coreSize = params.coreSize
        haloSize = params.haloSize
        bloomSize = params.bloomSize
    }
}

/// 相机 / 放大机柔光镜：能量守恒的 PSF 混合（core + 逐通道 halo + bloom）。
/// 数值表与公式逐行对应 Python `model/diffusion.py`。
enum DiffusionFilter {
    static let shapes: [String: DiffusionFamily] = [
        "glimmerglass": DiffusionFamily(
            core: DiffusionGroup(lambdaUM: 10.0, spread: 1.5, nComponents: 2),
            halo: DiffusionGroup(lambdaUM: 50.0, spread: 2.0, nComponents: 3),
            bloom: DiffusionGroup(lambdaUM: 260.0, spread: 2.5, nComponents: 4, alpha: 3.2),
            wCore: 0.60, wHalo: 0.30, wBloom: 0.10, haloWarmthBase: 0.0
        ),
        "black_pro_mist": DiffusionFamily(
            core: DiffusionGroup(lambdaUM: 16.0, spread: 1.5, nComponents: 2),
            halo: DiffusionGroup(lambdaUM: 95.0, spread: 2.0, nComponents: 3),
            bloom: DiffusionGroup(lambdaUM: 380.0, spread: 2.5, nComponents: 4, alpha: 3.5),
            wCore: 0.40, wHalo: 0.47, wBloom: 0.13, haloWarmthBase: 0.65
        ),
        "pro_mist": DiffusionFamily(
            core: DiffusionGroup(lambdaUM: 14.0, spread: 1.5, nComponents: 2),
            halo: DiffusionGroup(lambdaUM: 150.0, spread: 2.0, nComponents: 3),
            bloom: DiffusionGroup(lambdaUM: 650.0, spread: 2.5, nComponents: 4, alpha: 2.9),
            wCore: 0.28, wHalo: 0.42, wBloom: 0.30, haloWarmthBase: 0.40
        ),
        "cinebloom": DiffusionFamily(
            core: DiffusionGroup(lambdaUM: 20.0, spread: 1.5, nComponents: 2),
            halo: DiffusionGroup(lambdaUM: 200.0, spread: 2.0, nComponents: 3),
            bloom: DiffusionGroup(lambdaUM: 1000.0, spread: 2.5, nComponents: 4, alpha: 2.5),
            wCore: 0.22, wHalo: 0.30, wBloom: 0.48, haloWarmthBase: 0.85
        ),
    ]

    static let familyGain: [String: Double] = [
        "glimmerglass": 0.65,
        "black_pro_mist": 0.75,
        "pro_mist": 1.05,
        "cinebloom": 1.00,
    ]

    static let strengthBreakpoints: [Double] = [0.125, 0.25, 0.5, 1.0, 2.0]
    static let strengthFractions: [Double] = [0.10, 0.20, 0.35, 0.55, 0.75]
    static let haloWarmthAxis: [Double] = [1.30, 0.15, -1.45]

    static func strengthToScatter(strength: Double, family: String) -> Double {
        if strength <= 0 { return 0 }
        let logStrength = log2(min(max(strength, 1e-6), .greatestFiniteMagnitude))
        let logBreaks = strengthBreakpoints.map { log2($0) }
        let base = Couplers.npInterp(logStrength, xp: logBreaks, fp: strengthFractions)
        let gain = familyGain[family] ?? 1.0
        return min(max(base * gain, 0.0), 0.99)
    }

    static func resolveFamily(_ family: String, overrides: DiffusionOverrides?) -> DiffusionFamily {
        guard let base = shapes[family] else {
            preconditionFailure("Unknown diffusion filter family: \(family)")
        }
        guard let overrides, !overrides.isIdentity else { return base }
        let wCore = base.wCore * max(overrides.coreIntensity, 0)
        let wHalo = base.wHalo * max(overrides.haloIntensity, 0)
        let wBloom = base.wBloom * max(overrides.bloomIntensity, 0)
        let total = wCore + wHalo + wBloom
        if total <= 0 { return base }
        var resolved = base
        resolved.core.lambdaUM = base.core.lambdaUM * max(overrides.coreSize, 1e-6)
        resolved.halo.lambdaUM = base.halo.lambdaUM * max(overrides.haloSize, 1e-6)
        resolved.bloom.lambdaUM = base.bloom.lambdaUM * max(overrides.bloomSize, 1e-6)
        resolved.wCore = wCore / total
        resolved.wHalo = wHalo / total
        resolved.wBloom = wBloom / total
        return resolved
    }

    static func bloomMaxLambdaUM(family: String, overrides: DiffusionOverrides?) -> Double {
        let config = resolveFamily(family, overrides: overrides)
        return config.bloom.lambdaUM * config.bloom.spread
    }

    static func expandGroup(_ group: DiffusionGroup, kind: String) -> ([Double], [Double]) {
        let center = group.lambdaUM
        let spread = group.spread
        let n = max(group.nComponents, 1)
        if n == 1 || spread <= 1 {
            return ([center], [1.0])
        }
        let logLow = log(center / spread)
        let logHigh = log(center * spread)
        var lambdas = [Double](repeating: 0, count: n)
        var weights = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = n == 1 ? 0.0 : Double(i) / Double(n - 1)
            lambdas[i] = exp(logLow + (logHigh - logLow) * t)
            weights[i] = kind == "bloom" ? pow(lambdas[i], 2.0 - group.alpha) : 1.0
        }
        let total = weights.reduce(0, +)
        for i in 0..<n { weights[i] /= total }
        return (lambdas, weights)
    }

    static func haloChannelWeights(weights: [Double], warmth: Double) -> [[Double]] {
        let n = weights.count
        if n < 2 { return [weights, weights, weights] }
        let clamped = min(max(warmth, -1.5), 1.5)
        var gradient = [Double](repeating: 0, count: n)
        for i in 0..<n { gradient[i] = n == 1 ? 0 : -1.0 + 2.0 * Double(i) / Double(n - 1) }
        let weightSum = weights.reduce(0, +)
        var average = 0.0
        for i in 0..<n { average += gradient[i] * weights[i] }
        average /= weightSum
        for i in 0..<n { gradient[i] -= average }
        let target = weightSum
        var result = [[Double]](repeating: weights, count: 3)
        for c in 0..<3 {
            var raw = [Double](repeating: 0, count: n)
            var sum = 0.0
            for i in 0..<n {
                raw[i] = max(weights[i] * (1.0 + clamped * haloWarmthAxis[c] * gradient[i]), 0.0)
                sum += raw[i]
            }
            if sum > 0 {
                for i in 0..<n { result[c][i] = raw[i] * (target / sum) }
            }
        }
        return result
    }

    static func psf(width: Int, height: Int, family: String, spatialScale: Double,
                    pixelSizeUM: Double, haloWarmth: Double,
                    overrides: DiffusionOverrides?) -> [Double] {
        let config = resolveFamily(family, overrides: overrides)
        let scale = max(spatialScale, 1e-6)
        let effectiveWarmth = config.haloWarmthBase + haloWarmth
        let (coreLambdas, coreWeights) = expandGroup(config.core, kind: "core")
        let (haloLambdas, haloWeights) = expandGroup(config.halo, kind: "halo")
        let (bloomLambdas, bloomWeights) = expandGroup(config.bloom, kind: "bloom")
        let haloPerChannel = haloChannelWeights(weights: haloWeights, warmth: effectiveWarmth)

        let corePx = coreLambdas.map { $0 * scale / pixelSizeUM }
        let haloPx = haloLambdas.map { $0 * scale / pixelSizeUM }
        let bloomPx = bloomLambdas.map { $0 * scale / pixelSizeUM }

        let centerX = width / 2
        let centerY = height / 2
        var radius = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x - centerX)
                let dy = Double(y - centerY)
                radius[y * width + x] = sqrt(dx * dx + dy * dy)
            }
        }

        func exponentialSum(_ lambdas: [Double], _ weights: [Double]) -> [Double] {
            var total = [Double](repeating: 0, count: radius.count)
            for k in 0..<lambdas.count {
                let lambda = max(lambdas[k], 1e-6)
                let amplitude = weights[k] / (2.0 * Double.pi * lambda * lambda)
                for i in 0..<total.count { total[i] += amplitude * exp(-radius[i] / lambda) }
            }
            return total
        }

        let core = exponentialSum(corePx, coreWeights).map { config.wCore * $0 }
        let bloom = exponentialSum(bloomPx, bloomWeights).map { config.wBloom * $0 }
        var halo = [[Double]](repeating: [Double](repeating: 0, count: radius.count), count: 3)
        for c in 0..<3 {
            let component = exponentialSum(haloPx, haloPerChannel[c])
            for i in 0..<component.count { halo[c][i] = config.wHalo * component[i] }
        }

        var output = [Double](repeating: 0, count: radius.count * 3)
        for c in 0..<3 {
            var sum = 0.0
            for i in 0..<radius.count { sum += core[i] + halo[c][i] + bloom[i] }
            let scaleFactor = sum > 0 ? 1.0 / sum : 0
            for i in 0..<radius.count {
                output[i * 3 + c] = (core[i] + halo[c][i] + bloom[i]) * scaleFactor
            }
        }
        return output
    }

    /// numpy `np.pad(mode="reflect")` 边界映射（不含边缘重复）。
    static func numpyReflect(_ index: Int, _ count: Int) -> Int {
        if count <= 1 { return 0 }
        var value = index
        while value < 0 || value >= count {
            if value < 0 { value = -value } else { value = 2 * count - 2 - value }
        }
        return value
    }

    static func apply(_ image: ImageRGB, params: DiffusionFilterParams, pixelSizeUM: Double) -> ImageRGB {
        guard params.active, params.strength > 0, params.spatialScale > 0, pixelSizeUM > 0 else {
            return image
        }
        let family = params.filterFamily
        guard shapes[family] != nil else { return image }
        let scatter = strengthToScatter(strength: params.strength, family: family)
        guard scatter > 0 else { return image }
        let overrides = DiffusionOverrides(params: params)
        let bloomMaxLambdaPx = bloomMaxLambdaUM(family: family, overrides: overrides)
            * params.spatialScale / pixelSizeUM
        var radius = Int(ceil(max(8.0 * bloomMaxLambdaPx, 5.0)))
        radius = min(radius, max(min(image.width, image.height) / 2 - 1, 1))
        guard radius > 0 else { return image }

        let psf = psf(
            width: 2 * radius + 1, height: 2 * radius + 1,
            family: family, spatialScale: params.spatialScale,
            pixelSizeUM: pixelSizeUM, haloWarmth: params.haloWarmth,
            overrides: overrides
        )
        let paddedWidth = image.width + 2 * radius
        let paddedHeight = image.height + 2 * radius
        var output = image
        output.data.withUnsafeMutableBufferPointer { destination in
            image.data.withUnsafeBufferPointer { source in
                DispatchQueue.concurrentPerform(iterations: 3) { c in
                    var padded = [Double](repeating: 0, count: paddedWidth * paddedHeight)
                    for y in 0..<paddedHeight {
                        let sourceY = numpyReflect(y - radius, image.height)
                        for x in 0..<paddedWidth {
                            let sourceX = numpyReflect(x - radius, image.width)
                            padded[y * paddedWidth + x] =
                                Double(source[(sourceY * image.width + sourceX) * 3 + c])
                        }
                    }
                    var channelKernel = [Double](repeating: 0, count: psf.count / 3)
                    for i in 0..<(psf.count / 3) { channelKernel[i] = psf[i * 3 + c] }
                    let blurred = FFTConvolution.convolveSame(
                        image: padded, width: paddedWidth, height: paddedHeight,
                        kernel: channelKernel, kernelWidth: 2 * radius + 1,
                        kernelHeight: 2 * radius + 1
                    )
                    for y in 0..<image.height {
                        for x in 0..<image.width {
                            let index = (y + radius) * paddedWidth + (x + radius)
                            let value = (1 - scatter) * padded[index] + scatter * blurred[index]
                            destination[(y * image.width + x) * 3 + c] = Float(value)
                        }
                    }
                }
            }
        }
        return output
    }
}   
