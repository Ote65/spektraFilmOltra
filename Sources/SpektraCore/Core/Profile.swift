import Foundation

struct DensityCurvesModel {
    var modelType: String
    var centers: [[Double]]
    var amplitudes: [[Double]]
    var sigmas: [[Double]]
}

struct ProfileInfo {
    var stock: String
    var name: String
    var type: String
    var support: String
    var stage: String
    var use: String
    var antihalation: String
    var targetPrint: String?
    var channelModel: String
    var densitometer: String
    var logSensitivityDensityOverMin: Double
    var referenceIlluminant: String
    var viewingIlluminant: String

    var isPositive: Bool { type == "positive" }
    var isNegative: Bool { type == "negative" }
    var isPaper: Bool { support == "paper" }
    var isFilm: Bool { support == "film" }
    var isColor: Bool { channelModel == "color" }
    var isBW: Bool { channelModel == "bw" }
}

struct ProfileData {
    var wavelengths: [Double]
    var logSensitivity: [[Double]]
    var hanatos2025AdaptationWindowParams: [Double]
    var hanatos2025AdaptationSurfaceParams: [[Double]]
    var channelDensity: [[Double]]
    var baseDensity: [Double]
    var midscaleNeutralDensity: [Double]
    var logExposure: [Double]
    var densityCurves: [[Double]]
    var densityCurvesLayers: [[[Double]]]
    var densityCurvesModel: DensityCurvesModel
}

struct Profile {
    var metadata: [String: Any]
    var info: ProfileInfo
    var data: ProfileData

    var hanatos2025Adaptation: Hanatos2025Adaptation {
        Hanatos2025Adaptation(
            windowParams: data.hanatos2025AdaptationWindowParams,
            surfaceParams: data.hanatos2025AdaptationSurfaceParams,
            spectralGaussianBlur: 0,
            referenceIlluminant: info.referenceIlluminant,
            applyWindow: true,
            applySurface: true,
            active: nil
        )
    }
}

struct Hanatos2025Adaptation {
    var windowParams: [Double]
    var surfaceParams: [[Double]]
    var spectralGaussianBlur: Double
    var referenceIlluminant: String?
    var applyWindow: Bool
    var applySurface: Bool
    var active: Bool?
}

enum ProfileStore {
    private static let cacheLock = NSLock()
    private static var cache: [String: Profile] = [:]

    static func list() throws -> [String] {
        let dir = ResourceLocator.url("Profiles")
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static func load(_ stock: String) throws -> Profile {
        cacheLock.lock()
        if let cached = cache[stock] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let url = ResourceLocator.url("Profiles/\(stock).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoreError.missingResource("Profiles/\(stock).json")
        }
        let root = try JSONHelpers.loadObject(url)
        guard let info = root["info"] as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            throw CoreError.invalidProfile(stock)
        }
        let metadata = root["metadata"] as? [String: Any] ?? [:]
        let profile = Profile(metadata: metadata,
                              info: parseInfo(info, stock: stock),
                              data: try parseData(data, stock: stock))
        cacheLock.lock()
        cache[stock] = profile
        cacheLock.unlock()
        return profile
    }

    private static func parseInfo(_ value: [String: Any], stock: String) -> ProfileInfo {
        ProfileInfo(
            stock: JSONHelpers.string(value["stock"], default: stock),
            name: JSONHelpers.string(value["name"], default: stock),
            type: JSONHelpers.string(value["type"], default: "negative"),
            support: JSONHelpers.string(value["support"], default: "film"),
            stage: JSONHelpers.string(value["stage"], default: "filming"),
            use: JSONHelpers.string(value["use"], default: "still"),
            antihalation: JSONHelpers.string(value["antihalation"], default: "weak"),
            targetPrint: value["target_print"] as? String,
            channelModel: JSONHelpers.string(value["channel_model"], default: "color"),
            densitometer: JSONHelpers.string(value["densitometer"], default: "status_M"),
            logSensitivityDensityOverMin: JSONHelpers.double(value["log_sensitivity_density_over_min"], default: 0.2),
            referenceIlluminant: JSONHelpers.string(value["reference_illuminant"], default: "D55"),
            viewingIlluminant: JSONHelpers.string(value["viewing_illuminant"], default: "D50")
        )
    }

    private static func parseData(_ value: [String: Any], stock: String) throws -> ProfileData {
        let modelObject = value["density_curves_model"] as? [String: Any] ?? [:]
        let model = DensityCurvesModel(
            modelType: JSONHelpers.string(modelObject["model_type"], default: "cdfs"),
            centers: JSONHelpers.doubleMatrix(modelObject["centers"]),
            amplitudes: JSONHelpers.doubleMatrix(modelObject["amplitudes"]),
            sigmas: JSONHelpers.doubleMatrix(modelObject["sigmas"])
        )
        let data = ProfileData(
            wavelengths: JSONHelpers.doubleArray(value["wavelengths"]),
            logSensitivity: JSONHelpers.doubleMatrix(value["log_sensitivity"]),
            hanatos2025AdaptationWindowParams: JSONHelpers.doubleArray(value["hanatos2025_adaptation_window_params"]),
            hanatos2025AdaptationSurfaceParams: JSONHelpers.doubleMatrix(value["hanatos2025_adaptation_surface_params"]),
            channelDensity: JSONHelpers.doubleMatrix(value["channel_density"]),
            baseDensity: JSONHelpers.doubleArray(value["base_density"]),
            midscaleNeutralDensity: JSONHelpers.doubleArray(value["midscale_neutral_density"]),
            logExposure: JSONHelpers.doubleArray(value["log_exposure"]),
            densityCurves: JSONHelpers.doubleMatrix(value["density_curves"]),
            densityCurvesLayers: JSONHelpers.doubleTensor(value["density_curves_layers"]),
            densityCurvesModel: model
        )
        guard data.wavelengths.count > 0,
              data.logSensitivity.count == data.wavelengths.count,
              data.channelDensity.count == data.wavelengths.count,
              data.densityCurves.count == data.logExposure.count,
              data.densityCurves.allSatisfy({ $0.count == 3 }) else {
            throw CoreError.invalidProfile(stock)
        }
        return data
    }
}

