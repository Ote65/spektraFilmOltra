import Foundation

enum ClarityAnalyzer {
    static let analysisLongEdge = 1024
    static let colorAnalysisLongEdge = 512
    static let localSigmas: [Double] = [2.0, 6.0, 14.0]

    static func analyze(_ image: ImageRGB, mode: ClarityMode) throws -> ClarityAnalysis {
        guard image.width > 0, image.height > 0 else { throw ClarityError.emptyImage }
        guard image.data.count == image.width * image.height * 3 else {
            throw ClarityError.invalidImage
        }

        let analysisEncoded = ClarityMath.downsampledToLongEdge(
            image, maxEdge: analysisLongEdge
        )
        let linear = ClarityMath.srgbToLinearImage(analysisEncoded)
        let width = linear.width
        let height = linear.height
        let count = width * height

        let y = ClarityMath.luminancePlane(linear)
        var logY = [Double](repeating: 0, count: count)
        for i in 0..<count { logY[i] = ClarityMath.logY(y[i]) }
        let oklab = ClarityMath.oklabPlanes(linear)
        var chroma = [Double](repeating: 0, count: count)
        for i in 0..<count {
            chroma[i] = sqrt(oklab.a[i] * oklab.a[i] + oklab.b[i] * oklab.b[i])
        }

        let histogram = ClarityMath.Histogram(values: logY)
        let percentileValues = [1, 2, 5, 10, 25, 50, 75, 90, 95, 98, 99].map {
            histogram.percentile(Double($0))
        }
        let p2 = percentileValues[1]
        let p5 = percentileValues[2]
        let p50 = percentileValues[5]
        let p95 = percentileValues[8]
        let p98 = percentileValues[9]
        let blackPoint = ClarityMath.expLog(p2)
        let whitePoint = ClarityMath.expLog(p98)
        let shadowSupport = histogram.fractionBelow(p5)
        let highlightSupport = histogram.fractionAbove(p95)

        let meanY = y.reduce(0, +) / Double(max(count, 1))
        var variance = 0.0
        for value in y { variance += (value - meanY) * (value - meanY) }
        let stdY = sqrt(variance / Double(max(count, 1)))
        let shadowFraction = histogram.fractionBelow(ClarityMath.logY(0.05))
        let highlightFraction = histogram.fractionAbove(ClarityMath.logY(0.60))
        let medianChroma = ClarityMath.median(chroma)

        let meanYMap = ClarityMath.boxBlur(y, width: width, height: height, radius: 4)
        var ySquared = [Double](repeating: 0, count: count)
        for i in 0..<count { ySquared[i] = y[i] * y[i] }
        let meanYSquared = ClarityMath.boxBlur(ySquared, width: width, height: height, radius: 4)
        var localStdY = [Double](repeating: 0, count: count)
        for i in 0..<count {
            localStdY[i] = sqrt(max(meanYSquared[i] - meanYMap[i] * meanYMap[i], 0))
        }
        let medianLocalStdY = ClarityMath.median(localStdY)

        let haze = analyzeHaze(
            linear: linear, chroma: chroma,
            medianLocalStdY: medianLocalStdY, width: width, height: height
        )

        let localBase = ClarityMath.downsamplePlaneBy2(logY, width: width, height: height)
        let localSigmasHalf = localSigmas.map { $0 * 0.5 }
        let pyramid = ClarityMath.buildLaplacianPyramid(
            logY: localBase.data, width: localBase.width, height: localBase.height,
            sigmas: localSigmasHalf
        )
        let scoreMaps = ClarityMath.localContrastScores(pyramid, sigmas: localSigmasHalf)
        let scaleScores = scoreMaps.map { ClarityMath.median($0.data) }
        let mediumScore = scaleScores.count > 1 ? scaleScores[1] : (scaleScores.first ?? 0)
        let local = ClarityLocalAnalysis(
            scaleScores: scaleScores,
            mediumScore: mediumScore,
            enabled: mediumScore > 0.10
        )

        let color = analyzeColor(linearImage: linear)
        let tone = analyzeTone(
            blackPoint: blackPoint, whitePoint: whitePoint,
            p50: ClarityMath.expLog(p50),
            shadowSupport: shadowSupport, highlightSupport: highlightSupport,
            shadowFraction: shadowFraction, highlightFraction: highlightFraction,
            mode: mode
        )

        let features = ClarityFeatureSet(
            percentilesLogY: percentileValues,
            meanY: meanY,
            stdY: stdY,
            blackPoint: blackPoint,
            whitePoint: whitePoint,
            shadowFraction: shadowFraction,
            highlightFraction: highlightFraction,
            medianChroma: medianChroma,
            medianDarkChannel: haze.analysis.darkChannelMedian,
            medianLocalStdY: medianLocalStdY,
            localContrastByScale: scaleScores,
            transmissionCoverage: haze.analysis.transmissionCoverage,
            airlight: [haze.airlight.x, haze.airlight.y, haze.airlight.z]
        )

        return ClarityAnalysis(
            sourceWidth: image.width,
            sourceHeight: image.height,
            width: width,
            height: height,
            linear: linear,
            logY: logY,
            oklabL: oklab.l,
            oklabA: oklab.a,
            oklabB: oklab.b,
            features: features,
            localScoreMaps: scoreMaps,
            tone: tone,
            haze: haze.analysis,
            local: local,
            color: color,
            transmission: haze.transmission,
            airlight: haze.airlight
        )
    }

    static func suggestedControls(for analysis: ClarityAnalysis) -> ClarityControls {
        let toneScore = max(analysis.tone.blackScore, analysis.tone.whiteScore)
        let clarity = ClarityMath.clamp(
            0.45 * analysis.haze.score
            + 0.35 * toneScore
            + 0.20 * analysis.local.mediumScore,
            0, 0.85
        )
        let color = ClarityMath.clamp(
            0.50 * analysis.color.castScore * analysis.color.confidence,
            0, 0.50
        )
        return ClarityControls(
            clarity: analysis.haze.enabled || analysis.tone.enabled || analysis.local.enabled ? clarity : 0,
            color: analysis.color.enabled ? color : 0
        )
    }

    static func report(for analysis: ClarityAnalysis, mode: ClarityMode,
                       controls: ClarityControls) -> ClarityReport {
        let summary = String(
            format: "灰雾 %.0f%% · 黑场 %.0f%% · 白场 %.0f%% · 偏色 %.0f%%",
            analysis.haze.score * 100,
            analysis.tone.blackScore * 100,
            analysis.tone.whiteScore * 100,
            analysis.color.castScore * 100
        )
        return ClarityReport(
            mode: mode,
            features: analysis.features,
            tone: analysis.tone,
            haze: analysis.haze,
            local: analysis.local,
            color: analysis.color,
            suggestedClarity: controls.clarity,
            suggestedColor: controls.color,
            summary: summary
        )
    }

    // MARK: - 影调

    private static func analyzeTone(blackPoint: Double, whitePoint: Double, p50: Double,
                                    shadowSupport: Double, highlightSupport: Double,
                                    shadowFraction: Double, highlightFraction: Double,
                                    mode: ClarityMode) -> ClarityToneAnalysis {
        let blackScore = ClarityMath.smoothstep(0.002, 0.015, blackPoint)
        let whiteScore = 1 - ClarityMath.smoothstep(0.55, 0.85, whitePoint)
        let support = ClarityMath.clamp(
            min(shadowSupport, highlightSupport) / 0.01, 0.40, 1.00
        )
        var styleProtection = 1.0
        if p50 < 0.05, shadowFraction > 0.60 { styleProtection = 0.50 }
        if p50 > 0.60, highlightFraction > 0.60 { styleProtection = 0.50 }
        if mode == .film { styleProtection = 0 }
        let enabled = styleProtection > 0 && max(blackScore, whiteScore) > 0.10
        return ClarityToneAnalysis(
            blackPoint: blackPoint,
            whitePoint: whitePoint,
            blackScore: blackScore,
            whiteScore: whiteScore,
            support: support,
            styleProtection: styleProtection,
            enabled: enabled
        )
    }

    // MARK: - 灰雾

    private struct HazeResult {
        var analysis: ClarityHazeAnalysis
        var transmission: [Double]
        var airlight: Vec3
    }

    private static func analyzeHaze(linear: ImageRGB, chroma: [Double],
                                    medianLocalStdY: Double,
                                    width: Int, height: Int) -> HazeResult {
        let small = ClarityMath.downsampledToLongEdge(linear, maxEdge: 512)
        let sw = small.width
        let sh = small.height
        let count = sw * sh
        let smallY = ClarityMath.luminancePlane(small)
        let smallChroma = ClarityMath.resizePlane(
            chroma, width: width, height: height, newWidth: sw, newHeight: sh
        )

        var dark = [Double](repeating: 0, count: count)
        for i in 0..<count {
            dark[i] = min(
                Double(small.data[i * 3]),
                Double(small.data[i * 3 + 1]),
                Double(small.data[i * 3 + 2])
            )
        }
        let darkRadius = max(2, Int(round(7.0 * Double(sw) / Double(width))))
        let darkFiltered = ClarityMath.minFilter(
            dark, width: sw, height: sh, radius: darkRadius
        )
        let candidateCount = max(1, Int(Double(count) * 0.001))
        let threshold = darkChannelThreshold(darkFiltered, targetCount: candidateCount)

        var candidateR: [Double] = []
        var candidateG: [Double] = []
        var candidateB: [Double] = []
        candidateR.reserveCapacity(candidateCount * 2)
        candidateG.reserveCapacity(candidateCount * 2)
        candidateB.reserveCapacity(candidateCount * 2)
        for i in 0..<count {
            guard darkFiltered[i] >= threshold else { continue }
            let r = Double(small.data[i * 3])
            let g = Double(small.data[i * 3 + 1])
            let b = Double(small.data[i * 3 + 2])
            if r > 0.98 || g > 0.98 || b > 0.98 { continue }
            let lab = ClarityMath.oklab(fromLinear: Vec3(r, g, b))
            if lab.x > 0.90 { continue }
            candidateR.append(r)
            candidateG.append(g)
            candidateB.append(b)
        }
        let airlight: Vec3
        if candidateR.isEmpty {
            airlight = Vec3(0.80, 0.80, 0.80)
        } else {
            airlight = Vec3(
                ClarityMath.median(candidateR),
                ClarityMath.median(candidateG),
                ClarityMath.median(candidateB)
            )
        }
        let validCandidateFraction = Double(candidateR.count) / Double(max(count, 1))

        var transmission = [Double](repeating: 1, count: count)
        for i in 0..<count {
            let r = Double(small.data[i * 3]) / max(airlight.x, 1e-6)
            let g = Double(small.data[i * 3 + 1]) / max(airlight.y, 1e-6)
            let b = Double(small.data[i * 3 + 2]) / max(airlight.z, 1e-6)
            transmission[i] = ClarityMath.clamp(1 - 0.90 * min(r, g, b), 0.35, 1)
        }
        let guideRadius = max(3, Int(round(20.0 * Double(sw) / Double(width))))
        transmission = ClarityMath.guidedFilter(
            guide: smallY, source: transmission,
            width: sw, height: sh, radius: guideRadius, epsilon: 0.001
        )

        var coverageCount = 0
        for value in transmission where value < 0.95 { coverageCount += 1 }
        let coverage = Double(coverageCount) / Double(max(count, 1))

        let medianDark = ClarityMath.median(darkFiltered)
        let medianChroma = ClarityMath.median(smallChroma)
        let sDark = ClarityMath.smoothstep(0.10, 0.35, medianDark)
        let sContrast = 1 - ClarityMath.smoothstep(0.04, 0.12, medianLocalStdY)
        let sColor = 1 - ClarityMath.smoothstep(0.025, 0.08, medianChroma)
        let score = 0.40 * sDark + 0.35 * sContrast + 0.25 * sColor

        let qAirlight = ClarityMath.smoothstep(0.0002, 0.0015, validCandidateFraction)
        let qSpatial = ClarityMath.smoothstep(0.20, 0.50, coverage)
        let disagreement = max(abs(sDark - sContrast), abs(sContrast - sColor))
        let qConsistency = 1 - ClarityMath.smoothstep(0.20, 0.50, disagreement)
        let confidence = qAirlight * qSpatial * qConsistency
        let enabled = score > 0.45 && confidence > 0.55

        let analysis = ClarityHazeAnalysis(
            score: score,
            confidence: confidence,
            darkChannelMedian: medianDark,
            localContrastMedian: medianLocalStdY,
            chromaMedian: medianChroma,
            transmissionCoverage: coverage,
            validCandidateFraction: validCandidateFraction,
            enabled: enabled
        )
        let fullTransmission = ClarityMath.resizePlane(
            transmission, width: sw, height: sh, newWidth: width, newHeight: height
        )
        return HazeResult(analysis: analysis, transmission: fullTransmission, airlight: airlight)
    }

    // MARK: - 偏色

    private static func darkChannelThreshold(_ values: [Double], targetCount: Int) -> Double {
        guard !values.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 1024)
        for value in values {
            let index = min(max(Int(value * 1023), 0), 1023)
            histogram[index] += 1
        }
        var cumulative = 0
        for index in stride(from: 1023, through: 0, by: -1) {
            cumulative += histogram[index]
            if cumulative >= targetCount { return Double(index) / 1023 }
        }
        return 0
    }

    static func analyzeColor(linearImage: ImageRGB) -> ClarityColorAnalysis {
        let small = ClarityMath.downsampledToLongEdge(
            linearImage, maxEdge: colorAnalysisLongEdge
        )
        let count = small.width * small.height
        let oklab = ClarityMath.oklabPlanes(small)
        var chroma = [Double](repeating: 0, count: count)
        for i in 0..<count {
            chroma[i] = sqrt(oklab.a[i] * oklab.a[i] + oklab.b[i] * oklab.b[i])
        }
        return analyzeColor(oklab: oklab, chroma: chroma, width: small.width, height: small.height)
    }

    static func analyzeColor(oklab: (l: [Double], a: [Double], b: [Double]),
                             chroma: [Double], width: Int, height: Int) -> ClarityColorAnalysis {
        let count = width * height

        let meanL = ClarityMath.boxBlur(oklab.l, width: width, height: height, radius: 4)
        var lSquared = [Double](repeating: 0, count: count)
        for i in 0..<count { lSquared[i] = oklab.l[i] * oklab.l[i] }
        let meanLSquared = ClarityMath.boxBlur(lSquared, width: width, height: height, radius: 4)
        let meanC = ClarityMath.boxBlur(chroma, width: width, height: height, radius: 4)
        var cSquared = [Double](repeating: 0, count: count)
        for i in 0..<count { cSquared[i] = chroma[i] * chroma[i] }
        let meanCSquared = ClarityMath.boxBlur(cSquared, width: width, height: height, radius: 4)

        var candidates = [Bool](repeating: false, count: count)
        var candidateCount = 0
        for i in 0..<count {
            let l = oklab.l[i]
            guard l > 0.12, l < 0.90, chroma[i] < 0.045 else { continue }
            let sigmaL = sqrt(max(meanLSquared[i] - meanL[i] * meanL[i], 0))
            let sigmaC = sqrt(max(meanCSquared[i] - meanC[i] * meanC[i], 0))
            guard sigmaL < 0.06, sigmaC < 0.035 else { continue }
            let highlightProtection = 1 - ClarityMath.smoothstep(0.88, 0.98, l)
            let confidence = (1 - ClarityMath.smoothstep(0.015, 0.06, sigmaL))
                * (1 - ClarityMath.smoothstep(0.008, 0.035, sigmaC))
                * highlightProtection
            guard confidence >= 0.5 else { continue }
            candidates[i] = true
            candidateCount += 1
        }

        guard candidateCount > 0 else {
            return ClarityColorAnalysis(
                cast: Vec2(0, 0), shadowCast: Vec2(0, 0),
                midtoneCast: Vec2(0, 0), highlightCast: Vec2(0, 0),
                castScore: 0, confidence: 0, candidateFraction: 0,
                blockCount: 0, enabled: false
            )
        }

        let columns = 8
        let rows = 8
        let blockWidth = max(1, width / columns)
        let blockHeight = max(1, height / rows)
        var blockA: [Double] = []
        var blockB: [Double] = []
        var blockL: [Double] = []
        for row in 0..<rows {
            let y0 = row * blockHeight
            let y1 = min(height, y0 + blockHeight)
            for column in 0..<columns {
                let x0 = column * blockWidth
                let x1 = min(width, x0 + blockWidth)
                var aValues: [Double] = []
                var bValues: [Double] = []
                var lValues: [Double] = []
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let index = yy * width + xx
                        guard candidates[index] else { continue }
                        aValues.append(oklab.a[index])
                        bValues.append(oklab.b[index])
                        lValues.append(oklab.l[index])
                    }
                }
                guard aValues.count >= 20 else { continue }
                blockA.append(ClarityMath.median(aValues))
                blockB.append(ClarityMath.median(bValues))
                blockL.append(ClarityMath.median(lValues))
            }
        }

        let blockCount = blockA.count
        guard blockCount >= 4 else {
            return ClarityColorAnalysis(
                cast: Vec2(0, 0), shadowCast: Vec2(0, 0),
                midtoneCast: Vec2(0, 0), highlightCast: Vec2(0, 0),
                castScore: 0, confidence: 0,
                candidateFraction: Double(candidateCount) / Double(max(count, 1)),
                blockCount: blockCount, enabled: false
            )
        }

        let castA = ClarityMath.median(blockA)
        let castB = ClarityMath.median(blockB)
        let castMagnitude = sqrt(castA * castA + castB * castB)
        let castScore = ClarityMath.smoothstep(0.006, 0.025, castMagnitude)

        var directionX = 0.0
        var directionY = 0.0
        for i in 0..<blockCount {
            let magnitude = sqrt(blockA[i] * blockA[i] + blockB[i] * blockB[i])
            guard magnitude > 1e-9 else { continue }
            directionX += blockA[i] / magnitude
            directionY += blockB[i] / magnitude
        }
        let direction = sqrt(directionX * directionX + directionY * directionY) / Double(blockCount)
        let sampleConfidence = ClarityMath.smoothstep(4, 12, Double(blockCount))
        let confidence = sampleConfidence * direction

        func zoneCast(shadow: Bool, highlight: Bool) -> Vec2 {
            var aValues: [Double] = []
            var bValues: [Double] = []
            for i in 0..<blockCount {
                let l = blockL[i]
                let isShadow = l < 0.40
                let isHighlight = l > 0.65
                if shadow == isShadow && highlight == isHighlight {
                    aValues.append(blockA[i])
                    bValues.append(blockB[i])
                }
            }
            guard aValues.count >= 2 else { return Vec2(castA, castB) }
            return Vec2(ClarityMath.median(aValues), ClarityMath.median(bValues))
        }

        let shadowCast = zoneCast(shadow: true, highlight: false)
        let highlightCast = zoneCast(shadow: false, highlight: true)
        let midtoneCast = zoneCast(shadow: false, highlight: false)

        return ClarityColorAnalysis(
            cast: Vec2(castA, castB),
            shadowCast: shadowCast,
            midtoneCast: midtoneCast,
            highlightCast: highlightCast,
            castScore: castScore,
            confidence: confidence,
            candidateFraction: Double(candidateCount) / Double(max(count, 1)),
            blockCount: blockCount,
            enabled: castScore >= 0.05 && confidence >= 0.30
        )
    }
}
