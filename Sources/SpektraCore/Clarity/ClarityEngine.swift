import Foundation

enum AdaptiveClarityEngine {
    struct ProcessOutput {
        var linear: ImageRGB
        var plan: ClarityPlan
    }

    static func analyze(_ image: ImageRGB, mode: ClarityMode) throws -> ClarityAnalysis {
        try ClarityAnalyzer.analyze(image, mode: mode)
    }

    static func suggestedControls(for analysis: ClarityAnalysis,
                                  mode: ClarityMode = .standalone) -> ClarityControls {
        if mode == .film {
            return ClarityControls(
                clarity: ClarityMath.clamp(0.70 * analysis.local.mediumScore, 0, 0.85),
                color: 0
            )
        }
        return ClarityAnalyzer.suggestedControls(for: analysis)
    }

    static func optimize(_ image: ImageRGB, mode: ClarityMode,
                         validateResult: Bool = true,
                         workingLongEdge: Int = 0,
                         shouldCancel: (() -> Bool)? = nil) throws -> ClarityResult {
        let analysis = try analyze(image, mode: mode)
        let controls = suggestedControls(for: analysis, mode: mode)
        return try process(
            image, analysis: analysis, controls: controls,
            mode: mode, validateResult: validateResult,
            workingLongEdge: workingLongEdge, shouldCancel: shouldCancel
        )
    }

    static func process(_ image: ImageRGB, analysis: ClarityAnalysis,
                        controls: ClarityControls, mode: ClarityMode,
                        validateResult: Bool = true,
                        workingLongEdge: Int = 0,
                        shouldCancel: (() -> Bool)? = nil) throws -> ClarityResult {
        guard image.width > 0, image.height > 0 else { throw ClarityError.emptyImage }
        let linearInput = ClarityMath.srgbToLinearImage(image)
        var scales = ClarityModuleScale()
        var output = try processOnce(
            linearInput, analysis: analysis, controls: controls,
            mode: mode, scales: scales, workingLongEdge: workingLongEdge,
            shouldCancel: shouldCancel
        )
        var validation: ClarityValidation
        if validateResult {
            validation = validate(
                input: linearInput, output: output.linear, analysis: analysis, plan: output.plan
            )
        } else {
            validation = ClarityValidation(
                passed: true, skipped: true,
                highClipDelta: 0, lowClipDelta: 0, p50Change: 0,
                haloRatio: 1, castResidual: 0, contrastRatio: 1, issues: []
            )
        }
        if validateResult, !validation.passed, !validation.issues.isEmpty {
            for issue in validation.issues {
                switch issue {
                case .dehaze: scales.dehaze = 0.5
                case .tone: scales.tone = 0.5
                case .localContrast: scales.localContrast = 0.5
                case .color: scales.color = 0.5
                }
            }
            output = try processOnce(
                linearInput, analysis: analysis, controls: controls,
                mode: mode, scales: scales, workingLongEdge: workingLongEdge,
                shouldCancel: shouldCancel
            )
            output.plan.rollbackApplied = true
            validation = validate(
                input: linearInput, output: output.linear,
                analysis: analysis, plan: output.plan
            )
        }
        let srgb = ClarityMath.linearToSRGBImage(output.linear, clampToUnit: true)
        let report = ClarityAnalyzer.report(
            for: analysis, mode: mode, controls: controls
        )
        return ClarityResult(
            image: srgb,
            plan: output.plan,
            report: report,
            validation: validation
        )
    }

    // MARK: - 单次处理

    private static func processOnce(_ linear: ImageRGB, analysis: ClarityAnalysis,
                                    controls: ClarityControls, mode: ClarityMode,
                                    scales: ClarityModuleScale, workingLongEdge: Int,
                                    shouldCancel: (() -> Bool)?) throws -> ProcessOutput {
        func checkCancel() throws {
            if shouldCancel?() == true { throw ClarityError.cancelled }
        }
        try checkCancel()

        let dehaze = ClarityProcessors.dehaze(
            linear, analysis: analysis, controls: controls,
            scale: scales.dehaze, mode: mode
        )
        var current = dehaze.image
        try checkCancel()

        let tone = ClarityProcessors.tone(
            current, analysis: analysis, controls: controls,
            scale: scales.tone, mode: mode
        )
        current = tone.image
        try checkCancel()

        let local = ClarityProcessors.localContrast(
            current, analysis: analysis, controls: controls,
            scale: scales.localContrast, mode: mode,
            workingLongEdge: workingLongEdge, hazeStrength: dehaze.strength
        )
        current = local.image
        try checkCancel()

        let color = ClarityProcessors.color(
            current, analysis: analysis, controls: controls,
            scale: scales.color, mode: mode
        )
        current = color.image
        try checkCancel()

        let plan = ClarityPlan(
            mode: mode,
            clarityControl: controls.clarity,
            colorControl: controls.color,
            dehazeEnabled: dehaze.enabled,
            dehazeStrength: dehaze.strength,
            toneEnabled: tone.enabled,
            toneBlackStrength: tone.blackStrength,
            toneWhiteStrength: tone.whiteStrength,
            localContrastEnabled: local.enabled,
            localContrastGains: local.gains,
            colorEnabled: color.enabled,
            colorStrength: color.strength,
            airlight: [analysis.airlight.x, analysis.airlight.y, analysis.airlight.z],
            rollbackApplied: false
        )
        return ProcessOutput(linear: current, plan: plan)
    }

    // MARK: - 验证

    private static func validate(input: ImageRGB, output: ImageRGB,
                                 analysis: ClarityAnalysis,
                                 plan: ClarityPlan) -> ClarityValidation {
        let inputClips = clipFractions(input)
        let outputClips = clipFractions(output)
        let highDelta = outputClips.high - inputClips.high
        let lowDelta = outputClips.low - inputClips.low

        let inputP50 = ClarityMath.expLog(analysis.features.percentilesLogY[5])
        let outputP50 = percentile50(output)
        let p50Change = abs(outputP50 - inputP50) / max(inputP50, 0.001)
        let p50Exceeded = abs(outputP50 - inputP50) > max(0.05 * inputP50, 0.003)

        let inputLog = ClarityProcessors.logYPlane(input)
        let outputLog = ClarityProcessors.logYPlane(output)
        let inputGradient = ClarityMath.gradientMagnitude(
            inputLog, width: input.width, height: input.height
        )
        let outputGradient = ClarityMath.gradientMagnitude(
            outputLog, width: output.width, height: output.height
        )
        let haloRatio = ClarityMath.percentile(outputGradient, 99)
            / max(ClarityMath.percentile(inputGradient, 99), 1e-9)

        let contrastRatio = mediumLocalContrast(output)
            / max(mediumLocalContrast(input), 1e-9)

        let castAnalysis = ClarityAnalyzer.analyzeColor(linearImage: output)
        let castResidual = sqrt(
            castAnalysis.cast.x * castAnalysis.cast.x
            + castAnalysis.cast.y * castAnalysis.cast.y
        )

        var issues: [ClarityModule] = []
        if highDelta > 0.003 || lowDelta > 0.003 || p50Exceeded {
            issues.append(.tone)
            if highDelta > 0.003, plan.dehazeEnabled { issues.append(.dehaze) }
        }
        if haloRatio > 1.15 {
            issues.append(.localContrast)
        }
        if plan.colorEnabled, castResidual > 0.015 {
            issues.append(.color)
        }
        if plan.localContrastEnabled,
           contrastRatio < 1.05 || contrastRatio > 1.60 {
            issues.append(.localContrast)
        } else if plan.dehazeEnabled,
                  contrastRatio < 1.05 || contrastRatio > 1.60 {
            issues.append(.dehaze)
        }

        var unique: [ClarityModule] = []
        for issue in issues where !unique.contains(issue) { unique.append(issue) }

        return ClarityValidation(
            passed: unique.isEmpty,
            skipped: false,
            highClipDelta: highDelta,
            lowClipDelta: lowDelta,
            p50Change: p50Change,
            haloRatio: haloRatio,
            castResidual: castResidual,
            contrastRatio: contrastRatio,
            issues: unique
        )
    }

    private static func clipFractions(_ image: ImageRGB) -> (high: Double, low: Double) {
        let count = image.width * image.height
        var high = 0
        var low = 0
        for i in 0..<count {
            let y = ClarityMath.luminance(
                image.data[i * 3], image.data[i * 3 + 1], image.data[i * 3 + 2]
            )
            if y > 0.99 { high += 1 }
            if y < 0.001 { low += 1 }
        }
        return (Double(high) / Double(max(count, 1)), Double(low) / Double(max(count, 1)))
    }

    private static func percentile50(_ image: ImageRGB) -> Double {
        let small = ClarityMath.downsampledToLongEdge(image, maxEdge: 1024)
        let y = ClarityMath.luminancePlane(small)
        var logY = [Double](repeating: 0, count: y.count)
        for i in 0..<y.count { logY[i] = ClarityMath.logY(y[i]) }
        let histogram = ClarityMath.Histogram(values: logY)
        return ClarityMath.expLog(histogram.percentile(50))
    }

    private static func mediumLocalContrast(_ image: ImageRGB) -> Double {
        let small = ClarityMath.downsampledToLongEdge(image, maxEdge: 1024)
        let logY = ClarityProcessors.logYPlane(small)
        let pyramid = ClarityMath.buildLaplacianPyramid(
            logY: logY, width: small.width, height: small.height,
            sigmas: ClarityAnalyzer.localSigmas
        )
        guard pyramid.bands.count > 1 else { return 0 }
        let band = pyramid.bands[1]
        let sigma = ClarityAnalyzer.localSigmas[1]
        var squared = [Double](repeating: 0, count: band.data.count)
        for i in 0..<squared.count { squared[i] = band.data[i] * band.data[i] }
        let smoothed = FastGaussian.filterChannel(
            squared, width: band.width, height: band.height, sigma: sigma
        )
        var contrast = [Double](repeating: 0, count: smoothed.count)
        for i in 0..<contrast.count { contrast[i] = sqrt(max(smoothed[i], 0)) }
        return ClarityMath.median(contrast)
    }
}
