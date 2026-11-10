import Foundation

struct EnlargerParams: Codable {
    var illuminant: String = "TH-KG3"
    var printExposure: Double = 1.0
    var printExposureCompensation: Bool = true
    var normalizePrintExposure: Bool = true
    var yFilterShift: Double = 0
    var mFilterShift: Double = 0
    var yFilterNeutral: Double = 55
    var mFilterNeutral: Double = 65
    var cFilterNeutral: Double = 0
    var lensBlur: Double = 0
    var diffusionFilter = DiffusionFilterParams()
    var preflashExposure: Double = 0
    var preflashYFilterShift: Double = 0
    var preflashMFilterShift: Double = 0
}

/// 出厂中灰滤镜数据库（`filters/neutral_print_filters.json`）。
/// 结构与 Python `digest_params` 的 `apply_database_neutral_print_filters` 一致。
enum NeutralPrintFilters {
    static func lookup(filmStock: String, printStock: String, illuminant: String)
        -> (c: Double, m: Double, y: Double)? {
        guard let root = try? JSONHelpers.loadObject(
            ResourceLocator.url("filters/neutral_print_filters.json")
        ) else { return nil }
        guard let printEntry = root[printStock] as? [String: Any],
              let illuminantEntry = printEntry[illuminant] as? [String: Any],
              let values = illuminantEntry[filmStock] as? [Any],
              values.count >= 3 else { return nil }
        let c = JSONHelpers.double(values[0])
        let m = JSONHelpers.double(values[1])
        let y = JSONHelpers.double(values[2])
        return (c, m, y)
    }
}

final class EnlargerService {
    var densitySpectralMidgray: [[Double]]?
    var densitySpectralMidgrayComp: [[Double]]?
    /// 印相补偿中灰对应的拍摄曝光（EV）。共享 SpectralLUTService 时用它判断
    /// 已烘焙的放大机 LUT 是否还适用于当前曝光补偿。
    var compensationEV: Double = 0
    let printExposureCompensation: Bool
    let params: EnlargerParams

    init(params: EnlargerParams) {
        self.params = params
        self.printExposureCompensation = params.printExposureCompensation
    }

    func filteredIlluminant(_ lightSource: [Double]) -> [Double] {
        EnlargerFilters.applyCC(lightSource, cc: [
            params.cFilterNeutral,
            params.mFilterNeutral + params.mFilterShift,
            params.yFilterNeutral + params.yFilterShift,
        ])
    }

    func neutralIlluminant(_ lightSource: [Double]) -> [Double] {
        EnlargerFilters.applyCC(lightSource, cc: [
            params.cFilterNeutral,
            params.mFilterNeutral,
            params.yFilterNeutral,
        ])
    }

    func preflashIlluminant(_ lightSource: [Double]) -> [Double] {
        EnlargerFilters.applyCC(lightSource, cc: [
            params.cFilterNeutral,
            params.mFilterNeutral + params.preflashMFilterShift,
            params.yFilterNeutral + params.preflashYFilterShift,
        ])
    }
}

