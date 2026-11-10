import Foundation
import Darwin

struct PrintCurvesMorphParams: Codable {
    var active: Bool = false
    var gammaFactor: Double = 1.0
    var gammaFactorFast: Double = 1.0
    var gammaFactorSlow: Double = 1.0
    var gammaFactorRed: Double = 1.0
    var gammaFactorGreen: Double = 1.0
    var gammaFactorBlue: Double = 1.0
    var developerExhaustion: Double = 0.0
}

enum MorphCurves {
    static let sigmaFloor = 0.05
    static let gumbelLocation = -log(log(2.0))
    static let gumbelWidth = 0.5 * log(2.0) * sqrt(2.0 * .pi)

    static func normCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / sqrt(2.0))
    }

    static func signedZ(_ z: Double, profileType: String) -> Double {
        profileType == "positive" ? -z : z
    }

    static func gumbelCDF(_ z: Double) -> Double {
        exp(-exp(-(z / gumbelWidth + gumbelLocation)))
    }

    static func layerCDF(_ z: Double, profileType: String, gumbelMix: Double) -> Double {
        let cdf = normCDF(signedZ(z, profileType: profileType))
        if gumbelMix > 0 {
            return (1 - gumbelMix) * cdf + gumbelMix * gumbelCDF(signedZ(z, profileType: profileType))
        }
        return cdf
    }

    static func evaluateChannelDensity(logExposure: [Double], centers: [Double],
                                       amplitudes: [Double], sigmas: [Double],
                                       profileType: String, gumbelMix: [Double]) -> [Double] {
        var total = [Double](repeating: 0, count: logExposure.count)
        for i in 0..<centers.count {
            let mix = i < gumbelMix.count ? gumbelMix[i] : 0
            for (j, x) in logExposure.enumerated() {
                let z = (x - centers[i]) / sigmas[i]
                total[j] += amplitudes[i] * layerCDF(z, profileType: profileType, gumbelMix: mix)
            }
        }
        return total
    }

    static func evaluateFittedDensity(logExposure: [Double], model: DensityCurvesModel,
                                      profileType: String) -> [[Double]] {
        let nChannels = model.centers.count
        var output = [[Double]](repeating: [Double](repeating: 0, count: nChannels), count: logExposure.count)
        for channel in 0..<nChannels {
            let values = evaluateChannelDensity(
                logExposure: logExposure,
                centers: model.centers[channel],
                amplitudes: model.amplitudes[channel],
                sigmas: model.sigmas[channel],
                profileType: profileType,
                gumbelMix: [Double](repeating: 0, count: model.centers[channel].count)
            )
            for i in 0..<logExposure.count { output[i][channel] = values[i] }
        }
        return output
    }

    static func speedLayerIndices(_ centers: [Double]) -> (Int, Int, Int) {
        let order = centers.indices.sorted { centers[$0] < centers[$1] }
        return (order[0], order[order.count / 2], order[order.count - 1])
    }

    static func channelGammaFactor(_ params: PrintCurvesMorphParams, channel: Int) -> Double {
        switch channel {
        case 0: return params.gammaFactorRed
        case 1: return params.gammaFactorGreen
        default: return params.gammaFactorBlue
        }
    }

    static func developerExhaustionCenterOffset(centers: [Double], amplitudes: [Double],
                                                sigmas: [Double], profileType: String,
                                                gumbelMix: [Double]) -> Double {
        if gumbelMix.allSatisfy({ $0 == 0 }) { return 0 }
        let target = evaluateChannelDensity(
            logExposure: [0], centers: centers, amplitudes: amplitudes,
            sigmas: sigmas, profileType: profileType,
            gumbelMix: [Double](repeating: 0, count: gumbelMix.count)
        )[0]

        func residual(_ offset: Double) -> Double {
            evaluateChannelDensity(
                logExposure: [0], centers: centers.map { $0 + offset },
                amplitudes: amplitudes, sigmas: sigmas,
                profileType: profileType, gumbelMix: gumbelMix
            )[0] - target
        }

        if abs(residual(0)) <= 1e-12 { return 0 }
        var lo = -0.25
        var hi = 0.25
        var rLo = residual(lo)
        var rHi = residual(hi)
        for _ in 0..<12 {
            if rLo == 0 { return lo }
            if rHi == 0 { return hi }
            if rLo * rHi < 0 {
                var a = lo
                var b = hi
                for _ in 0..<80 {
                    let mid = 0.5 * (a + b)
                    let value = residual(mid)
                    if abs(value) < 1e-10 { return mid }
                    if value * residual(a) < 0 { b = mid } else { a = mid }
                }
                return 0.5 * (a + b)
            }
            lo *= 2
            hi *= 2
            rLo = residual(lo)
            rHi = residual(hi)
        }
        return 0
    }

    static func morphChannelParams(model: DensityCurvesModel, params: PrintCurvesMorphParams,
                                   channel: Int, profileType: String) -> (centers: [Double], amplitudes: [Double],
                                                                          sigmas: [Double], gumbel: [Double]) {
        var centers = model.centers[channel]
        let amplitudes = model.amplitudes[channel]
        var sigmas = model.sigmas[channel]
        let (fast, mid, slow) = speedLayerIndices(centers)
        let channelGamma = channelGammaFactor(params, channel: channel)
        let gFast = params.gammaFactor * channelGamma * params.gammaFactorFast
        let gMid = params.gammaFactor * channelGamma * params.gammaFactorSlow
        let gSlow = gMid
        sigmas[fast] = max(sigmas[fast] / gFast, sigmaFloor)
        centers[fast] /= gFast
        sigmas[mid] = max(sigmas[mid] / gMid, sigmaFloor)
        centers[mid] /= gMid
        sigmas[slow] = max(sigmas[slow] / gSlow, sigmaFloor)
        centers[slow] /= gSlow
        let gumbel = [Double](repeating: params.developerExhaustion, count: centers.count)
        let offset = developerExhaustionCenterOffset(
            centers: centers, amplitudes: amplitudes, sigmas: sigmas,
            profileType: profileType, gumbelMix: gumbel
        )
        return (centers.map { $0 + offset }, amplitudes, sigmas, gumbel)
    }

    static func applyPrintCurvesMorph(logExposure: [Double], model: DensityCurvesModel,
                                      params: PrintCurvesMorphParams,
                                      profileType: String) -> [[Double]] {
        guard params.active, let first = model.centers.first, !first.isEmpty else {
            return evaluateFittedDensity(logExposure: logExposure, model: model, profileType: profileType)
        }
        let nChannels = model.centers.count
        var output = [[Double]](repeating: [Double](repeating: 0, count: nChannels), count: logExposure.count)
        for channel in 0..<nChannels {
            let morphed = morphChannelParams(model: model, params: params, channel: channel, profileType: profileType)
            let values = evaluateChannelDensity(
                logExposure: logExposure, centers: morphed.centers,
                amplitudes: morphed.amplitudes, sigmas: morphed.sigmas,
                profileType: profileType, gumbelMix: morphed.gumbel
            )
            for i in 0..<logExposure.count { output[i][channel] = values[i] }
        }
        return output
    }
}

