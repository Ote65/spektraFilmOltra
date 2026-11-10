import Foundation

@main
struct ClaritySmoke {
    static func main() throws {
        try toneSmoke()
        try hazeSmoke()
        try castSmoke()
        log("clarity smoke: PASS")
    }

    // MARK: - 影调

    private static func toneSmoke() throws {
        let image = grayRamp(width: 256, height: 256, low: 0.02, high: 0.70)
        let analysis = try AdaptiveClarityEngine.analyze(image, mode: .standalone)
        let linear = ClarityMath.srgbToLinearImage(image)
        let before = statsLinear(linear)
        log(String(
            format: "tone before: p2=%.4f p50=%.4f black=%.3f white=%.3f enabled=%@",
            before.p2, before.p50, analysis.tone.blackScore, analysis.tone.whiteScore,
            analysis.tone.enabled ? "yes" : "no"
        ))
        guard analysis.tone.enabled else {
            throw smokeError("tone analysis did not trigger")
        }
        let controls = ClarityControls(clarity: 1.0, color: 0.0)
        let result = ClarityProcessors.tone(
            linear, analysis: analysis, controls: controls, scale: 1, mode: .standalone
        )
        let after = statsLinear(result.image)
        log(String(
            format: "tone after: p2=%.4f p50=%.4f planBlack=%.3f planWhite=%.3f enabled=%@",
            after.p2, after.p50, result.blackStrength,
            result.whiteStrength, result.enabled ? "yes" : "no"
        ))
        guard after.p2 < before.p2 * 0.85 else {
            throw smokeError("tone did not lower black point")
        }
        guard abs(after.p50 - before.p50) <= max(0.05 * before.p50, 0.003) else {
            throw smokeError("tone moved midtone too much")
        }
    }

    // MARK: - 灰雾

    private static func hazeSmoke() throws {
        let image = hazyPattern(width: 256, height: 256, transmission: 0.55, airlight: 0.75)
        let analysis = try AdaptiveClarityEngine.analyze(image, mode: .standalone)
        log(String(
            format: "haze: score=%.3f confidence=%.3f dark=%.3f enabled=%@",
            analysis.haze.score, analysis.haze.confidence,
            analysis.haze.darkChannelMedian, analysis.haze.enabled ? "yes" : "no"
        ))
        guard analysis.haze.enabled else {
            throw smokeError("haze analysis did not trigger")
        }
        let before = localContrast(image)
        let controls = ClarityControls(clarity: 0.7, color: 0.0)
        let result = try AdaptiveClarityEngine.process(
            image, analysis: analysis, controls: controls, mode: .standalone
        )
        let after = localContrast(result.image)
        log(String(
            format: "haze after: contrast %.4f -> %.4f ratio %.2f plan=%.3f",
            before, after, after / max(before, 1e-9), result.plan.dehazeStrength
        ))
        guard after > before * 1.10 else {
            throw smokeError("haze did not increase local contrast")
        }
    }

    // MARK: - 偏色

    private static func castSmoke() throws {
        let image = warmPatch(width: 256, height: 256)
        let analysis = try AdaptiveClarityEngine.analyze(image, mode: .standalone)
        let beforeCast = castMagnitude(image)
        log(String(
            format: "cast: score=%.3f confidence=%.3f magnitude=%.4f enabled=%@",
            analysis.color.castScore, analysis.color.confidence,
            beforeCast, analysis.color.enabled ? "yes" : "no"
        ))
        guard analysis.color.enabled else {
            throw smokeError("cast analysis did not trigger")
        }
        let controls = ClarityControls(clarity: 0.0, color: 1.0)
        let result = try AdaptiveClarityEngine.process(
            image, analysis: analysis, controls: controls, mode: .standalone
        )
        let afterCast = castMagnitude(result.image)
        log(String(
            format: "cast after: %.4f -> %.4f strength=%.3f",
            beforeCast, afterCast, result.plan.colorStrength
        ))
        guard afterCast < beforeCast * 0.95 else {
            throw smokeError("cast was not reduced")
        }
    }

    // MARK: - 合成图

    private static func grayRamp(width: Int, height: Int,
                                 low: Double, high: Double) -> ImageRGB {
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(max(width - 1, 1))
                let linear = low + (high - low) * t
                let encoded = ClarityMath.linearToSRGB(linear)
                let index = (y * width + x) * 3
                image.data[index] = encoded
                image.data[index + 1] = encoded
                image.data[index + 2] = encoded
            }
        }
        return image
    }

    private static func hazyPattern(width: Int, height: Int,
                                    transmission: Double, airlight: Double) -> ImageRGB {
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let base = 0.275
                    + 0.225 * cos(2 * Double.pi * Double(x) / 64)
                    * cos(2 * Double.pi * Double(y) / 64)
                let linear = base * transmission + airlight * (1 - transmission)
                let encoded = ClarityMath.linearToSRGB(linear)
                let index = (y * width + x) * 3
                image.data[index] = encoded
                image.data[index + 1] = encoded
                image.data[index + 2] = encoded
            }
        }
        return image
    }

    private static func warmPatch(width: Int, height: Int) -> ImageRGB {
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let block = (x / 16) % 4 + (y / 16) % 4
                let base = 0.16 + Double(block) * 0.012
                let r = base * 1.12
                let g = base
                let b = base * 0.88
                let index = (y * width + x) * 3
                image.data[index] = ClarityMath.linearToSRGB(r)
                image.data[index + 1] = ClarityMath.linearToSRGB(g)
                image.data[index + 2] = ClarityMath.linearToSRGB(b)
            }
        }
        return image
    }

    // MARK: - 统计

    private static func stats(_ image: ImageRGB) -> (p2: Double, p50: Double) {
        statsLinear(ClarityMath.srgbToLinearImage(image))
    }

    private static func statsLinear(_ linear: ImageRGB) -> (p2: Double, p50: Double) {
        let y = ClarityMath.luminancePlane(linear)
        var logY = [Double](repeating: 0, count: y.count)
        for i in 0..<y.count { logY[i] = ClarityMath.logY(y[i]) }
        let histogram = ClarityMath.Histogram(values: logY)
        return (ClarityMath.expLog(histogram.percentile(2)),
                ClarityMath.expLog(histogram.percentile(50)))
    }

    private static func localContrast(_ image: ImageRGB) -> Double {
        let linear = ClarityMath.srgbToLinearImage(image)
        let logY = ClarityProcessors.logYPlane(linear)
        let pyramid = ClarityMath.buildLaplacianPyramid(
            logY: logY, width: linear.width, height: linear.height,
            sigmas: ClarityAnalyzer.localSigmas
        )
        guard pyramid.bands.count > 1 else { return 0 }
        let band = pyramid.bands[1]
        var squared = [Double](repeating: 0, count: band.data.count)
        for i in 0..<squared.count { squared[i] = band.data[i] * band.data[i] }
        let smooth = FastGaussian.filterChannel(
            squared, width: band.width, height: band.height,
            sigma: ClarityAnalyzer.localSigmas[1]
        )
        var contrast = [Double](repeating: 0, count: smooth.count)
        for i in 0..<contrast.count { contrast[i] = sqrt(max(smooth[i], 0)) }
        return ClarityMath.median(contrast)
    }

    private static func castMagnitude(_ image: ImageRGB) -> Double {
        let linear = ClarityMath.srgbToLinearImage(image)
        let analysis = ClarityAnalyzer.analyzeColor(linearImage: linear)
        return sqrt(analysis.cast.x * analysis.cast.x + analysis.cast.y * analysis.cast.y)
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }

    private static func smokeError(_ message: String) -> NSError {
        NSError(domain: "clarity-smoke", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
