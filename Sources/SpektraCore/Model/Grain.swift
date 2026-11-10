import Foundation

/// 颗粒模型：逐层粒子显影统计 + 染料云模糊 + 微结构调制。
/// 逐行对应 Python `model/grain.py`；随机数只要求分布同构。
enum Grain {
    static func maxPerChannel(_ curves: [[Double]]) -> [Double] {
        var result = [Double](repeating: -.infinity, count: 3)
        for row in curves {
            for c in 0..<min(3, row.count) where row[c].isFinite { result[c] = max(result[c], row[c]) }
        }
        return result
    }

    static func maxLayers(_ layers: [[[Double]]]) -> [[Double]] {
        guard let first = layers.first else { return [] }
        let layerCount = first.count
        var result = [[Double]](repeating: [Double](repeating: -.infinity, count: 3), count: layerCount)
        for point in layers {
            for layer in 0..<min(layerCount, point.count) {
                for c in 0..<min(3, point[layer].count) where point[layer][c].isFinite {
                    result[layer][c] = max(result[layer][c], point[layer][c])
                }
            }
        }
        return result
    }

    /// 与 numpy `searchsorted(side='right')` 一致的 1D 线性插值。
    static func interpValue(_ x: Double, xp: [Double], yp: [Double]) -> Double {
        let count = xp.count
        guard count > 0, yp.count == count else { return .nan }
        if count == 1 { return yp[0] }
        if x <= xp[0] { return yp[0] }
        if x >= xp[count - 1] { return yp[count - 1] }
        var low = 0
        var high = count - 1
        while low < high {
            let mid = (low + high) / 2
            if xp[mid] <= x { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        if index < 0 { return yp[0] }
        if index >= count - 1 { return yp[count - 1] }
        let dx = xp[index + 1] - xp[index]
        let inv = dx != 0 ? 1.0 / dx : 0.0
        return yp[index] + (x - xp[index]) * inv * (yp[index + 1] - yp[index])
    }

    /// 行种子的雪崩混合（splitmix64 finalizer）。
    /// 直接把 `seed + y * Weyl` 当作种子会让相邻行共用同一条随机流的相邻位置，
    /// 在「每像素抽样次数固定」的路径上产生 45° 斜纹；这里先打散再交给 SplitMix64。
    @inline(__always)
    static func rowSeed(_ seed: UInt64, _ y: Int) -> UInt64 {
        var value = seed ^ (UInt64(truncatingIfNeeded: y) &* 0xD1B5_4A32_D192_ED03)
        value ^= value >> 30
        value = value &* 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value = value &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return value
    }

    static func layerParticleModel(density: [Double], densityMax: Double,
                                   nParticlesPerPixel: Double, grainUniformity: Double,
                                   seed: UInt64, blurParticle: Double,
                                   width: Int, height: Int) -> [Double] {
        guard densityMax > 0, nParticlesPerPixel > 0 else { return [Double](repeating: 0, count: density.count) }
        let odParticle = densityMax / nParticlesPerPixel
        var output = [Double](repeating: 0, count: density.count)

        func sample(_ source: UnsafePointer<Double>, _ destination: UnsafeMutablePointer<Double>,
                    _ range: Range<Int>, _ rng: inout SplitMix64) {
            for i in range {
                var probability = source[i] / densityMax
                if !probability.isFinite { probability = 0 }
                probability = min(max(probability, 1e-6), 1 - 1e-6)
                let saturation = 1 - probability * grainUniformity * (1 - 1e-6)
                let seeds = RandomStats.poisson(nParticlesPerPixel / saturation, &rng)
                let developed = RandomStats.binomial(seeds, probability, &rng)
                destination[i] = Double(developed) * odParticle * saturation
            }
        }

        // 按行并行，每行派生出独立种子。
        //
        // 逐像素随机流与串行版本不同（颗粒图案会重排），但颗粒本来就是按分布验收的
        // 模块（`docs/parity_report.md` 第 2 节：均值 ≤2%、标准差同量级），
        // 而它是全分辨率导出里最贵的一段：12 MP 下 11 s → 约 3 s。
        // `map` 那类纯逐像素变换不能这样并行（缺页争用），这里因为每个像素要算
        // 几十次随机采样，属于计算密集，才划算。
        if width > 0, height > 1, density.count == width * height, width * height >= 120_000 {
            output.withUnsafeMutableBufferPointer { destination in
                guard let dst = destination.baseAddress else { return }
                density.withUnsafeBufferPointer { input in
                    guard let src = input.baseAddress else { return }
                    func row(_ y: Int) {
                        // 不能用 `seed + y * Weyl`：SplitMix64 每抽一次正好加一个 Weyl 常数，
                        // 相邻行就等于同一随机流的相邻位置。每像素抽样次数固定时，下一行
                        // 会成为上一行左移几个像素的副本，颗粒退化成 45° 斜纹。
                        // 先做一次雪崩混合，保证各行种子在状态空间里彼此远离。
                        var rng = SplitMix64(seed: rowSeed(seed, y))
                        let start = y * width
                        sample(src, dst, start..<(start + width), &rng)
                    }
                    Interpolation.parallelRows(height: height, pixels: width * height, row)
                }
            }
        } else {
            var rng = SplitMix64(seed: seed)
            output.withUnsafeMutableBufferPointer { destination in
                guard let dst = destination.baseAddress else { return }
                density.withUnsafeBufferPointer { input in
                    guard let src = input.baseAddress else { return }
                    sample(src, dst, 0..<density.count, &rng)
                }
            }
        }
        if blurParticle > 0 {
            let sigma = blurParticle * sqrt(odParticle)
            output = FastGaussian.filterChannel(output, width: width, height: height, sigma: sigma)
        }
        return output
    }

    /// 对齐 numpy `(x, y, layer, rgb)` 的逐层密度插值。
    static func interpDensityCMYLayers(densityCMY: ImageRGB, densityCurves: [[Double]],
                                       densityCurvesLayers: [[[Double]]],
                                       positive: Bool) -> [[[Double]]] {
        let pixelCount = densityCMY.width * densityCMY.height
        let layerCount = densityCurvesLayers.first?.count ?? 0
        var result = [[[Double]]](repeating: [[Double]](repeating: [0, 0, 0], count: layerCount),
                                  count: pixelCount)
        guard layerCount > 0 else { return result }
        for c in 0..<3 {
            let curveColumn = densityCurves.indices.map { densityCurves[$0][c] }
            let sign: Double = positive ? -1 : 1
            for layer in 0..<layerCount {
                let layerColumn = densityCurvesLayers.indices.map { densityCurvesLayers[$0][layer][c] }
                let xp = sign == -1 ? curveColumn.map { -$0 } : curveColumn
                let yp = sign == -1 ? layerColumn.map { -$0 } : layerColumn
                for p in 0..<pixelCount {
                    let value = sign == -1 ? -Double(densityCMY.data[p * 3 + c])
                        : Double(densityCMY.data[p * 3 + c])
                    let interpolated = interpValue(value, xp: xp, yp: yp)
                    result[p][layer][c] = sign == -1 ? -interpolated : interpolated
                }
            }
        }
        return result
    }

    static func applyToDensityLayers(densityCMY: ImageRGB, pixelSizeUM: Double, params: GrainParams,
                                     densityCurves: [[Double]], densityCurvesLayers: [[[Double]]],
                                     positive: Bool) -> ImageRGB {
        let width = densityCMY.width
        let height = densityCMY.height
        let pixelCount = width * height
        let layerCount = densityCurvesLayers.first?.count ?? 0
        guard layerCount > 0 else { return densityCMY }

        let densityMaxLayers = maxLayers(densityCurvesLayers)
        var densityMaxTotal = [Double](repeating: 0, count: 3)
        for layer in 0..<layerCount {
            for c in 0..<3 { densityMaxTotal[c] += densityMaxLayers[layer][c] }
        }
        var fractions = [[Double]](repeating: [0, 0, 0], count: layerCount)
        var minLayers = [[Double]](repeating: [0, 0, 0], count: layerCount)
        for layer in 0..<layerCount {
            for c in 0..<3 {
                fractions[layer][c] = densityMaxLayers[layer][c] / densityMaxTotal[c]
                minLayers[layer][c] = fractions[layer][c] * params.densityMin[c]
            }
        }
        let pixelArea = pixelSizeUM * pixelSizeUM
        var particlesPerPixel = [[Double]](repeating: [0, 0, 0], count: layerCount)
        for layer in 0..<layerCount {
            for c in 0..<3 {
                let area = params.particleAreaUM2 * params.particleScale[c] * params.particleScaleLayers[layer]
                particlesPerPixel[layer][c] = pixelArea * fractions[layer][c] / area
            }
        }

        var output = ImageRGB(width: width, height: height)
        for c in 0..<3 {
            let curveColumn = densityCurves.indices.map { densityCurves[$0][c] }
            let sign: Double = positive ? -1 : 1
            let xp = sign == -1 ? curveColumn.map { -$0 } : curveColumn
            for layer in 0..<layerCount {
                let layerColumn = densityCurvesLayers.indices.map { densityCurvesLayers[$0][layer][c] }
                let yp = sign == -1 ? layerColumn.map { -$0 } : layerColumn
                var plane = [Double](repeating: 0, count: pixelCount)
                for p in 0..<pixelCount {
                    let value = sign == -1 ? -Double(densityCMY.data[p * 3 + c])
                        : Double(densityCMY.data[p * 3 + c])
                    let interpolated = interpValue(value, xp: xp, yp: yp)
                    plane[p] = (sign == -1 ? -interpolated : interpolated) + minLayers[layer][c]
                }
                let seed = UInt64(c + layer * 10)
                let modelled = layerParticleModel(
                    density: plane,
                    densityMax: densityMaxLayers[layer][c],
                    nParticlesPerPixel: particlesPerPixel[layer][c],
                    grainUniformity: params.uniformity[c],
                    seed: seed,
                    blurParticle: params.blurDyeCloudsUM,
                    width: width, height: height
                )
                for p in 0..<pixelCount { output.data[p * 3 + c] += Float(modelled[p]) }
            }
        }

        addMicroStructure(&output, micro: params.microStructure, pixelSizeUM: pixelSizeUM)
        for c in 0..<3 {
            for p in 0..<pixelCount {
                output.data[p * 3 + c] = Float(Double(output.data[p * 3 + c]) - params.densityMin[c])
            }
        }
        if params.blur > 0 {
            output = FastGaussian.filter(output, sigma: params.blur)
        }
        return output
    }

    static func addMicroStructure(_ density: inout ImageRGB, micro: [Double], pixelSizeUM: Double) {
        guard micro.count >= 2, pixelSizeUM > 0 else { return }
        let blurPixels = micro[0] / pixelSizeUM
        let sigma = micro[1] * 0.001 / pixelSizeUM
        guard sigma > 0.05 else { return }
        let pixelCount = density.width * density.height
        var rng = SplitMix64(seed: 7)
        var clumping = [Double](repeating: 0, count: pixelCount)
        for p in 0..<pixelCount {
            clumping[p] = RandomStats.lognormalFromMeanStd(1.0, sigma, &rng)
        }
        if blurPixels > 0.4 {
            clumping = FastGaussian.filterChannel(clumping, width: density.width, height: density.height, sigma: blurPixels)
        }
        for c in 0..<3 {
            for p in 0..<pixelCount {
                density.data[p * 3 + c] = Float(Double(density.data[p * 3 + c]) * clumping[p])
            }
        }
    }

    static func applyToDensity(densityCMY: ImageRGB, pixelSizeUM: Double, params: GrainParams,
                               densityCurves: [[Double]]) -> ImageRGB {
        let densityMaxCurves = maxPerChannel(densityCurves)
        let pixelArea = pixelSizeUM * pixelSizeUM
        let subLayers = max(params.nSubLayers, 1)
        var densityMax = [Double](repeating: 0, count: 3)
        var particles = [Double](repeating: 0, count: 3)
        for c in 0..<3 {
            densityMax[c] = densityMaxCurves[c] + params.densityMin[c]
            let area = params.particleAreaUM2 * params.particleScale[c]
            particles[c] = pixelArea / area / Double(subLayers)
        }
        let width = densityCMY.width
        let height = densityCMY.height
        let pixelCount = width * height
        var working = densityCMY
        for c in 0..<3 {
            for p in 0..<pixelCount {
                working.data[p * 3 + c] = Float(Double(working.data[p * 3 + c]) + params.densityMin[c])
            }
        }
        var output = ImageRGB(width: width, height: height)
        for c in 0..<3 {
            var plane = [Double](repeating: 0, count: pixelCount)
            for p in 0..<pixelCount { plane[p] = Double(working.data[p * 3 + c]) }
            for sub in 0..<subLayers {
                let modelled = layerParticleModel(
                    density: plane, densityMax: densityMax[c],
                    nParticlesPerPixel: particles[c], grainUniformity: params.uniformity[c],
                    seed: UInt64(c + sub * 10), blurParticle: 0,
                    width: width, height: height
                )
                for p in 0..<pixelCount { output.data[p * 3 + c] += Float(modelled[p]) }
            }
        }
        for c in 0..<3 {
            for p in 0..<pixelCount {
                output.data[p * 3 + c] = Float(
                    Double(output.data[p * 3 + c]) / Double(subLayers) - params.densityMin[c]
                )
            }
        }
        if params.blur > 0.4 {
            output = FastGaussian.filter(output, sigma: params.blur)
        }
        return output
    }

    static func apply(densityCMY: ImageRGB, pixelSizeUM: Double, params: GrainParams,
                      densityCurves: [[Double]], densityCurvesLayers: [[[Double]]],
                      profileType: String, bypass: Bool) -> ImageRGB {
        guard params.active, !bypass, pixelSizeUM > 0 else { return densityCMY }
        if !params.sublayersActive {
            return applyToDensity(densityCMY: densityCMY, pixelSizeUM: pixelSizeUM,
                                  params: params, densityCurves: densityCurves)
        }
        return applyToDensityLayers(
            densityCMY: densityCMY, pixelSizeUM: pixelSizeUM, params: params,
            densityCurves: densityCurves, densityCurvesLayers: densityCurvesLayers,
            positive: profileType == "positive"
        )
    }
}
