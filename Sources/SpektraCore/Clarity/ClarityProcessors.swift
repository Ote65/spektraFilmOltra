import Foundation

enum ClarityProcessors {
    struct DehazeResult {
        var image: ImageRGB
        var enabled: Bool
        var strength: Double
    }

    struct ToneResult {
        var image: ImageRGB
        var enabled: Bool
        var blackStrength: Double
        var whiteStrength: Double
    }

    struct LocalResult {
        var image: ImageRGB
        var enabled: Bool
        var gains: [Double]
    }

    struct ColorResult {
        var image: ImageRGB
        var enabled: Bool
        var strength: Double
    }

    // MARK: - 去雾

    static func dehaze(_ image: ImageRGB, analysis: ClarityAnalysis,
                       controls: ClarityControls, scale: Double,
                       mode: ClarityMode) -> DehazeResult {
        guard mode == .standalone,
              analysis.haze.enabled,
              controls.clarity > 0,
              scale > 0,
              !analysis.transmission.isEmpty else {
            return DehazeResult(image: image, enabled: false, strength: 0)
        }

        let strength = ClarityMath.clamp(
            controls.clarity * analysis.haze.score * analysis.haze.confidence * 0.40 * scale,
            0, 0.40
        )
        guard strength > 1e-6 else {
            return DehazeResult(image: image, enabled: false, strength: 0)
        }

        let width = image.width
        let height = image.height
        let count = width * height
        let transmission = ClarityMath.resizePlane(
            analysis.transmission, width: analysis.width, height: analysis.height,
            newWidth: width, newHeight: height
        )
        let sky = skyProtection(analysis: analysis, width: width, height: height)
        let logY = logYPlane(image)
        let s = Double(max(width, height)) / Double(max(analysis.width, 1))
        let gradient = ClarityMath.gradientMagnitude(logY, width: width, height: height)
        let dilated = ClarityMath.maxFilter(
            gradient, width: width, height: height, radius: max(1, Int(round(2 * s)))
        )
        var edge = [Double](repeating: 0, count: count)
        for i in 0..<count {
            edge[i] = 1 - ClarityMath.smoothstep(0.04, 0.16, dilated[i])
        }

        let airlight = analysis.airlight
        var output = image
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ClarityMath.parallelFor(rows: height) { y in
                for x in 0..<width {
                    let i = y * width + x
                    let t = max(transmission[i], 0.35)
                    let weight = strength * sky[i] * edge[i]
                    for c in 0..<3 {
                        let value = image.data[i * 3 + c]
                        let air = c == 0 ? airlight.x : (c == 1 ? airlight.y : airlight.z)
                        let recovered = max((value - air) / t + air, 0)
                        base[i * 3 + c] = value + weight * (recovered - value)
                    }
                }
            }
        }
        return DehazeResult(image: output, enabled: true, strength: strength)
    }

    private static func skyProtection(analysis: ClarityAnalysis, width: Int, height: Int) -> [Double] {
        var protection = [Double](repeating: 1, count: analysis.width * analysis.height)
        for i in 0..<protection.count {
            protection[i] = 1 - ClarityMath.smoothstep(0.78, 0.96, analysis.oklabL[i])
        }
        return ClarityMath.resizePlane(
            protection, width: analysis.width, height: analysis.height,
            newWidth: width, newHeight: height
        )
    }

    // MARK: - 影调

    static func tone(_ image: ImageRGB, analysis: ClarityAnalysis,
                     controls: ClarityControls, scale: Double,
                     mode: ClarityMode) -> ToneResult {
        guard mode == .standalone,
              analysis.tone.enabled,
              controls.clarity > 0, scale > 0 else {
            return ToneResult(image: image, enabled: false, blackStrength: 0, whiteStrength: 0)
        }
        let blackStrength = ClarityMath.clamp(
            controls.clarity * analysis.tone.blackScore
            * analysis.tone.support * analysis.tone.styleProtection * scale,
            0, 1
        )
        let whiteStrength = ClarityMath.clamp(
            controls.clarity * analysis.tone.whiteScore
            * analysis.tone.support * analysis.tone.styleProtection * scale,
            0, 1
        )
        guard max(blackStrength, whiteStrength) > 1e-6 else {
            return ToneResult(image: image, enabled: false, blackStrength: 0, whiteStrength: 0)
        }

        let percentiles = analysis.features.percentilesLogY
        guard percentiles.count >= 11 else {
            return ToneResult(image: image, enabled: false, blackStrength: 0, whiteStrength: 0)
        }
        let anchorsX = [percentiles[1], percentiles[3], percentiles[5], percentiles[7], percentiles[9]]
        let targetBlack = ClarityMath.logY(0.003)
        let targetWhite = ClarityMath.logY(0.92)
        let inputHighClip = clipFraction(image: image, high: true)
        let inputLowClip = clipFraction(image: image, high: false)

        func apply(_ black: Double, _ white: Double) -> (ImageRGB, Double, Double) {
            let y0 = anchorsX[0] + black * (targetBlack - anchorsX[0])
            let y4 = anchorsX[4] + white * (targetWhite - anchorsX[4])
            let anchorsY = [y0, anchorsX[1], anchorsX[2], anchorsX[3], y4]
            let lut = ClarityMath.monotoneCubicLUT(
                x: anchorsX, y: anchorsY,
                minX: ClarityMath.logMin, maxX: ClarityMath.logMax,
                count: 1024
            )
            var output = image
            output.data.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                ClarityMath.parallelFor(rows: image.height) { row in
                    for x in 0..<image.width {
                        let i = row * image.width + x
                        let r = image.data[i * 3]
                        let g = image.data[i * 3 + 1]
                        let b = image.data[i * 3 + 2]
                        let y = ClarityMath.luminance(r, g, b)
                        if y < 0.0005 { continue }
                        let mapped = ClarityMath.expLog(lut.sample(ClarityMath.logY(y)))
                        var factor = mapped / y
                        factor = ClarityMath.clamp(factor, 0.25, 4.0)
                        let maxChannel = max(r, g, b)
                        if maxChannel * factor > 1 {
                            factor = 1.0 / max(maxChannel, 1e-9)
                        }
                        base[i * 3] = r * factor
                        base[i * 3 + 1] = g * factor
                        base[i * 3 + 2] = b * factor
                    }
                }
            }
            return (output, black, white)
        }

        var (result, usedBlack, usedWhite) = apply(blackStrength, whiteStrength)
        let highDelta = clipFraction(image: result, high: true) - inputHighClip
        let lowDelta = clipFraction(image: result, high: false) - inputLowClip
        if highDelta > 0.003 || lowDelta > 0.003 {
            (result, usedBlack, usedWhite) = apply(blackStrength * 0.5, whiteStrength * 0.5)
            let retryHigh = clipFraction(image: result, high: true) - inputHighClip
            let retryLow = clipFraction(image: result, high: false) - inputLowClip
            if retryHigh > 0.003 || retryLow > 0.003 {
                return ToneResult(image: image, enabled: false, blackStrength: 0, whiteStrength: 0)
            }
        }
        return ToneResult(
            image: result, enabled: true,
            blackStrength: usedBlack, whiteStrength: usedWhite
        )
    }

    private static func clipFraction(image: ImageRGB, high: Bool) -> Double {
        let count = image.width * image.height
        var rowCounts = [Int](repeating: 0, count: image.height)
        rowCounts.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ClarityMath.parallelFor(rows: image.height) { row in
                var clipped = 0
                for x in 0..<image.width {
                    let i = row * image.width + x
                    let y = ClarityMath.luminance(
                        image.data[i * 3], image.data[i * 3 + 1], image.data[i * 3 + 2]
                    )
                    if high ? y > 0.99 : y < 0.001 { clipped += 1 }
                }
                base[row] = clipped
            }
        }
        let clipped = rowCounts.reduce(0, +)
        return Double(clipped) / Double(max(count, 1))
    }

    // MARK: - 局部层次

    static func localContrast(_ image: ImageRGB, analysis: ClarityAnalysis,
                              controls: ClarityControls, scale: Double,
                              mode: ClarityMode,
                              workingLongEdge: Int = 0,
                              hazeStrength: Double = 0) -> LocalResult {
        guard controls.clarity > 0, scale > 0,
              analysis.local.enabled else {
            return LocalResult(image: image, enabled: false, gains: [0, 0, 0])
        }
        let longEdge = max(image.width, image.height)
        let targetEdge = workingLongEdge > 0 ? min(longEdge, workingLongEdge) : longEdge
        let working = targetEdge < longEdge
            ? ClarityMath.downsampledToLongEdge(image, maxEdge: targetEdge)
            : image
        let field = localContrastField(
            working, analysis: analysis, controls: controls,
            scale: scale, mode: mode, hazeStrength: hazeStrength
        )
        let output = applyLocalLogField(
            field.logOut, sourceWidth: field.width, sourceHeight: field.height, to: image
        )
        return LocalResult(image: output, enabled: true, gains: field.gains)
    }

    private struct LocalField {
        var logOut: [Double]
        var width: Int
        var height: Int
        var gains: [Double]
    }

    private static func localContrastField(_ image: ImageRGB, analysis: ClarityAnalysis,
                                           controls: ClarityControls, scale: Double,
                                           mode: ClarityMode, hazeStrength: Double) -> LocalField {
        let width = image.width
        let height = image.height
        let longEdge = max(width, height)
        let factor = Double(longEdge) / Double(max(analysis.width, 1))
        let sigmas = ClarityAnalyzer.localSigmas.map { $0 * factor }
        let gMaxBase = mode == .film ? [0.0, 0.06, 0.03] : [0.05, 0.12, 0.06]
        let budget = 1 - 0.70 * ClarityMath.clamp(hazeStrength / 0.30, 0, 1)
        let baseGains = gMaxBase.map { $0 * controls.clarity * scale * budget }

        let logY = logYPlane(image)
        let pyramid = ClarityMath.buildLaplacianPyramid(
            logY: logY, width: width, height: height, sigmas: sigmas
        )

        let analysisGradient = ClarityMath.gradientMagnitude(
            analysis.logY, width: analysis.width, height: analysis.height
        )
        let edgeMaps: [[Double]] = ClarityAnalyzer.localSigmas.enumerated().map { index, sigma in
            let radius = max(1, Int(round(sigma * 0.5)))
            let dilated = ClarityMath.maxFilter(
                analysisGradient, width: analysis.width, height: analysis.height, radius: radius
            )
            var map = [Double](repeating: 0, count: dilated.count)
            for i in 0..<map.count {
                map[i] = 1 - ClarityMath.smoothstep(0.04, 0.16, dilated[i])
            }
            let band = pyramid.bands[min(index, pyramid.bands.count - 1)]
            return ClarityMath.resizePlane(
                map, width: analysis.width, height: analysis.height,
                newWidth: band.width, newHeight: band.height
            )
        }

        var gains = [Double](repeating: 0, count: pyramid.bands.count)
        var bands = pyramid.bands
        for index in 0..<bands.count {
            let band = bands[index]
            let scoreSource = analysis.localScoreMaps[min(index, analysis.localScoreMaps.count - 1)]
            let score = ClarityMath.resizePlane(
                scoreSource.data, width: scoreSource.width, height: scoreSource.height,
                newWidth: band.width, newHeight: band.height
            )
            let edge = edgeMaps[min(index, edgeMaps.count - 1)]
            let gain = baseGains[min(index, baseGains.count - 1)]
            gains[index] = gain
            guard gain > 1e-6, edge.count == band.data.count, score.count == band.data.count else { continue }
            for i in 0..<band.data.count {
                bands[index].data[i] *= (1 + gain * score[i] * edge[i])
            }
        }

        func reconstruct(_ bands: [ClarityMath.Plane]) -> [Double] {
            var current = pyramid.residual
            for index in stride(from: bands.count - 1, through: 0, by: -1) {
                let target = bands[index]
                let upsampled = ClarityMath.resizePlane(
                    current.data, width: current.width, height: current.height,
                    newWidth: target.width, newHeight: target.height
                )
                var merged = [Double](repeating: 0, count: upsampled.count)
                for i in 0..<merged.count { merged[i] = upsampled[i] + bands[index].data[i] }
                current = ClarityMath.Plane(data: merged, width: target.width, height: target.height)
            }
            return ClarityMath.resizePlane(
                current.data, width: current.width, height: current.height,
                newWidth: width, newHeight: height
            )
        }

        var finalLog = reconstruct(bands)
        let inputGradient = ClarityMath.gradientMagnitude(logY, width: width, height: height)
        let outputGradient = ClarityMath.gradientMagnitude(finalLog, width: width, height: height)
        let haloRatio = ClarityMath.percentile(outputGradient, 99)
            / max(ClarityMath.percentile(inputGradient, 99), 1e-9)
        if haloRatio > 1.15, bands.count > 0 {
            let index = bands.count - 1
            bands[index] = pyramid.bands[index]
            gains[index] = 0
            finalLog = reconstruct(bands)
        }
        return LocalField(logOut: finalLog, width: width, height: height, gains: gains)
    }

    private static func applyLocalLogField(_ logOut: [Double], sourceWidth: Int,
                                           sourceHeight: Int, to image: ImageRGB) -> ImageRGB {
        let width = image.width
        let height = image.height
        let field = ClarityMath.resizePlane(
            logOut, width: sourceWidth, height: sourceHeight,
            newWidth: width, newHeight: height
        )
        var output = image
        for i in 0..<(width * height) {
            let r = image.data[i * 3]
            let g = image.data[i * 3 + 1]
            let b = image.data[i * 3 + 2]
            let y = ClarityMath.luminance(r, g, b)
            guard y > 0.0005 else { continue }
            let targetY = ClarityMath.expLog(field[i])
            var factor = targetY / y
            factor = ClarityMath.clamp(factor, 0.25, 4.0)
            let maxChannel = max(r, g, b)
            if maxChannel * factor > 1 {
                factor = 1.0 / max(maxChannel, 1e-9)
            }
            output.data[i * 3] = r * factor
            output.data[i * 3 + 1] = g * factor
            output.data[i * 3 + 2] = b * factor
        }
        return output
    }

    // MARK: - 色净

    static func color(_ image: ImageRGB, analysis: ClarityAnalysis,
                      controls: ClarityControls, scale: Double,
                      mode: ClarityMode) -> ColorResult {
        guard mode == .standalone,
              controls.color > 0, scale > 0,
              analysis.color.enabled else {
            return ColorResult(image: image, enabled: false, strength: 0)
        }
        let recalculated = ClarityAnalyzer.analyzeColor(linearImage: image)
        guard recalculated.enabled else {
            return ColorResult(image: image, enabled: false, strength: 0)
        }
        var strength = ClarityMath.clamp(
            controls.color * recalculated.castScore * recalculated.confidence * 0.40 * scale,
            0, 0.40
        )
        guard strength > 1e-6 else {
            return ColorResult(image: image, enabled: false, strength: 0)
        }

        func apply(_ alpha: Double) -> (ImageRGB, Int) {
            var output = image
            var invalid = 0
            for i in 0..<(image.width * image.height) {
                let linear = Vec3(
                    image.data[i * 3], image.data[i * 3 + 1], image.data[i * 3 + 2]
                )
                let lab = ClarityMath.oklab(fromLinear: linear)
                let l = ClarityMath.clamp(lab.x, 0, 1)
                let shadowWeight = 1 - ClarityMath.smoothstep(0.15, 0.40, l)
                let highlightWeight = ClarityMath.smoothstep(0.65, 0.90, l)
                let midtoneWeight = max(0, 1 - shadowWeight - highlightWeight)
                let total = shadowWeight + midtoneWeight + highlightWeight
                let ws = total > 1e-9 ? shadowWeight / total : 0
                let wm = total > 1e-9 ? midtoneWeight / total : 0
                let wh = total > 1e-9 ? highlightWeight / total : 0
                let castA = ws * recalculated.shadowCast.x
                    + wm * recalculated.midtoneCast.x
                    + wh * recalculated.highlightCast.x
                let castB = ws * recalculated.shadowCast.y
                    + wm * recalculated.midtoneCast.y
                    + wh * recalculated.highlightCast.y
                let chroma = sqrt(lab.y * lab.y + lab.z * lab.z)
                let protection = 1 - ClarityMath.smoothstep(0.08, 0.20, chroma)
                let corrected = Vec3(
                    lab.x,
                    lab.y - alpha * castA * protection,
                    lab.z - 0.50 * alpha * castB * protection
                )
                let rgb = ClarityMath.linear(fromOklab: corrected)
                if rgb.x < -1e-6 || rgb.y < -1e-6 || rgb.z < -1e-6
                    || rgb.x > 1.02 || rgb.y > 1.02 || rgb.z > 1.02 {
                    invalid += 1
                }
                output.data[i * 3] = rgb.x
                output.data[i * 3 + 1] = rgb.y
                output.data[i * 3 + 2] = rgb.z
            }
            return (output, invalid)
        }

        var (result, invalid) = apply(strength)
        if invalid > 0 {
            strength *= 0.5
            (result, invalid) = apply(strength)
            if invalid > 0 {
                strength *= 0.5
                (result, invalid) = apply(strength)
            }
        }
        if invalid > 0 {
            return ColorResult(image: image, enabled: false, strength: 0)
        }
        return ColorResult(image: result, enabled: true, strength: strength)
    }

    // MARK: - 工具

    static func logYPlane(_ image: ImageRGB) -> [Double] {
        let count = image.width * image.height
        var output = [Double](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ClarityMath.parallelFor(rows: image.height) { row in
                for x in 0..<image.width {
                    let i = row * image.width + x
                    let y = ClarityMath.luminance(
                        image.data[i * 3], image.data[i * 3 + 1], image.data[i * 3 + 2]
                    )
                    base[i] = ClarityMath.logY(y)
                }
            }
        }
        return output
    }
}
