import Foundation

final class SpectralLUTService {
    private(set) var resolution: Int
    var inputGamutCompress = InputGamutSpec()
    private var filmingTCLUT: SpectralLUT?
    private var filmingKey: [Double]?
    private var enlargerLUT: PreparedPCHIP3D?
    private var enlargerKey: String?
    private var scannerLUT: PreparedPCHIP3D?
    private var scannerKey: String?

    init(resolution: Int) {
        self.resolution = resolution
    }

    /// 共享 LUT 服务时用于切换分辨率；分辨率变化会清空阶段 LUT。
    func updateResolution(_ value: Int) {
        guard value != resolution else { return }
        resolution = value
        invalidateStageLUTs()
    }

    /// 胶片/相纸或滤色片变化后需清空阶段 LUT。
    func invalidateStageLUTs() {
        enlargerLUT = nil
        enlargerKey = nil
        scannerLUT = nil
        scannerKey = nil
    }

    func getFilmingTCLUT(sensitivity: [[Double]], adaptation: Hanatos2025Adaptation) -> SpectralLUT {
        let flat = sensitivity.flatMap { $0 }
        if let filmingTCLUT, let filmingKey, filmingKey == flat {
            return filmingTCLUT
        }
        let lut = SpectralUpsampling.computeHanatosTCPLUT(
            sensitivity: sensitivity, adaptation: adaptation, gamutSpec: inputGamutCompress
        )
        filmingTCLUT = lut
        filmingKey = flat
        return lut
    }

    func compute3D(function: (ImageRGB) -> ImageRGB, dataMin: [Double], dataMax: [Double]) -> LUT3D {
        let steps = resolution
        var values = [Double](repeating: 0, count: steps * steps * steps * 3)
        for i in 0..<steps {
            let x = dataMin[0] + (dataMax[0] - dataMin[0]) * Double(i) / Double(steps - 1)
            for j in 0..<steps {
                let y = dataMin[1] + (dataMax[1] - dataMin[1]) * Double(j) / Double(steps - 1)
                for k in 0..<steps {
                    let z = dataMin[2] + (dataMax[2] - dataMin[2]) * Double(k) / Double(steps - 1)
                    let image = ImageRGB(width: 1, height: 1, data: [x, y, z])
                    let result = function(image)
                    let offset = ((i * steps + j) * steps + k) * 3
                    values[offset] = Double(result.data[0])
                    values[offset + 1] = Double(result.data[1])
                    values[offset + 2] = Double(result.data[2])
                }
            }
        }
        return LUT3D(size: steps, values: values)
    }

    static func normalized(_ image: ImageRGB, dataMin: [Double], dataMax: [Double]) -> ImageRGB {
        var output = image
        for p in 0..<(image.width * image.height) {
            for c in 0..<3 {
                let range = dataMax[c] - dataMin[c]
                let value = range != 0 ? (Double(image.data[p * 3 + c]) - dataMin[c]) / range : 0
                output.data[p * 3 + c] = Float(value)
            }
        }
        return output
    }

    func computeEnlarger(cmyData: ImageRGB, function: (ImageRGB) -> ImageRGB,
                        dataMin: [Double], dataMax: [Double], useLUT: Bool,
                        key: String) -> ImageRGB {
        guard useLUT else { return function(cmyData) }
        // 放大机 LUT 的烘焙函数包含滤色片、预闪与印相曝光补偿：共享服务时
        // 只要这些输入变了，旧表就不再生效，必须重烘，否则预览会把参数变化吃掉。
        if enlargerLUT == nil || enlargerKey != key {
            let lut = compute3D(function: function, dataMin: dataMin, dataMax: dataMax)
            enlargerLUT = LUTInterpolation.preparePCHIP(lut)
            enlargerKey = key
        }
        let normalized = Self.normalized(cmyData, dataMin: dataMin, dataMax: dataMax)
        return LUTInterpolation.applyPCHIP(enlargerLUT!, image: normalized)
    }

    func computeScanner(densityData: ImageRGB, function: (ImageRGB) -> ImageRGB,
                        dataMin: [Double], dataMax: [Double], useLUT: Bool,
                        key: String) -> ImageRGB {
        guard useLUT else { return function(densityData) }
        if scannerLUT == nil || scannerKey != key {
            let lut = compute3D(function: function, dataMin: dataMin, dataMax: dataMax)
            scannerLUT = LUTInterpolation.preparePCHIP(lut)
            scannerKey = key
        }
        let normalized = Self.normalized(densityData, dataMin: dataMin, dataMax: dataMax)
        return LUTInterpolation.applyPCHIP(scannerLUT!, image: normalized)
    }
}

