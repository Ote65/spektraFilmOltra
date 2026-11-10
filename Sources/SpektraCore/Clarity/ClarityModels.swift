import Foundation

/// V1.0 只处理“画面脏”：空气灰雾、被抬起的黑场、被压住的白场、光线偏色。
/// 降噪、灰尘划痕、颗粒、LUT 均不在本模块内。
enum ClarityMode: String, Codable {
    case standalone
    case film
}

enum ClarityModule: String, Codable, CaseIterable {
    case dehaze
    case tone
    case localContrast
    case color
}

struct Vec2: Equatable, Codable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

struct ClarityControls: Equatable, Codable {
    /// 通透：去雾 + 黑白场 + 局部层次。
    var clarity: Double
    /// 色净：光线偏色校正。
    var color: Double

    init(clarity: Double = 0, color: Double = 0) {
        self.clarity = clarity
        self.color = color
    }

    static let zero = ClarityControls()
}

struct ClarityFeatureSet: Codable {
    var percentilesLogY: [Double]
    var meanY: Double
    var stdY: Double
    var blackPoint: Double
    var whitePoint: Double
    var shadowFraction: Double
    var highlightFraction: Double
    var medianChroma: Double
    var medianDarkChannel: Double
    var medianLocalStdY: Double
    var localContrastByScale: [Double]
    var transmissionCoverage: Double
    var airlight: [Double]
}

struct ClarityToneAnalysis: Codable {
    var blackPoint: Double
    var whitePoint: Double
    var blackScore: Double
    var whiteScore: Double
    var support: Double
    var styleProtection: Double
    var enabled: Bool
}

struct ClarityHazeAnalysis: Codable {
    var score: Double
    var confidence: Double
    var darkChannelMedian: Double
    var localContrastMedian: Double
    var chromaMedian: Double
    var transmissionCoverage: Double
    var validCandidateFraction: Double
    var enabled: Bool
}

struct ClarityLocalAnalysis: Codable {
    var scaleScores: [Double]
    var mediumScore: Double
    var enabled: Bool
}

struct ClarityColorAnalysis: Codable {
    var cast: Vec2
    var shadowCast: Vec2
    var midtoneCast: Vec2
    var highlightCast: Vec2
    var castScore: Double
    var confidence: Double
    var candidateFraction: Double
    var blockCount: Int
    var enabled: Bool
}

struct ClarityAnalysis {
    let sourceWidth: Int
    let sourceHeight: Int
    let width: Int
    let height: Int
    let linear: ImageRGB
    let logY: [Double]
    let oklabL: [Double]
    let oklabA: [Double]
    let oklabB: [Double]
    let features: ClarityFeatureSet
    let localScoreMaps: [ClarityMath.Plane]
    let tone: ClarityToneAnalysis
    let haze: ClarityHazeAnalysis
    let local: ClarityLocalAnalysis
    let color: ClarityColorAnalysis
    let transmission: [Double]
    let airlight: Vec3
}

struct ClarityReport: Codable {
    var mode: ClarityMode
    var features: ClarityFeatureSet
    var tone: ClarityToneAnalysis
    var haze: ClarityHazeAnalysis
    var local: ClarityLocalAnalysis
    var color: ClarityColorAnalysis
    var suggestedClarity: Double
    var suggestedColor: Double
    var summary: String
}

struct ClarityPlan: Codable {
    var mode: ClarityMode
    var clarityControl: Double
    var colorControl: Double
    var dehazeEnabled: Bool
    var dehazeStrength: Double
    var toneEnabled: Bool
    var toneBlackStrength: Double
    var toneWhiteStrength: Double
    var localContrastEnabled: Bool
    var localContrastGains: [Double]
    var colorEnabled: Bool
    var colorStrength: Double
    var airlight: [Double]
    var rollbackApplied: Bool
}

struct ClarityValidation: Codable {
    var passed: Bool
    var skipped: Bool
    var highClipDelta: Double
    var lowClipDelta: Double
    var p50Change: Double
    var haloRatio: Double
    var castResidual: Double
    var contrastRatio: Double
    var issues: [ClarityModule]
}

struct ClarityResult {
    let image: ImageRGB
    let plan: ClarityPlan
    let report: ClarityReport
    let validation: ClarityValidation
}

enum ClarityError: Error {
    case emptyImage
    case invalidImage
    case cancelled
}

struct ClarityModuleScale {
    var dehaze = 1.0
    var tone = 1.0
    var localContrast = 1.0
    var color = 1.0
}
