import Foundation

struct RGBSpaceInfo {
    var name: String
    var primaries: [[Double]]
    var whitepoint: Vec3
    var toXYZ: Mat3
    var fromXYZ: Mat3
}

struct ColorDataStore {
    var shapeStart: Double
    var shapeEnd: Double
    var shapeStep: Double
    var cmfs: [[Double]]
    var lms: [[Double]]
    var illuminants: [String: [Double]]
    var spaces: [String: RGBSpaceInfo]
    var mallettBasis: [[Double]]

    static let shared: ColorDataStore = {
        do {
            let url = ResourceLocator.url("Color/ColorData.json")
            let root = try JSONHelpers.loadObject(url)
            let shape = root["shape"] as? [Any] ?? []
            let cmfs = JSONHelpers.doubleMatrix(root["cmfs"])
            let lms = JSONHelpers.doubleMatrix(root["lms"])
            let illumObject = root["illuminants"] as? [String: Any] ?? [:]
            var illuminants: [String: [Double]] = [:]
            for (key, value) in illumObject {
                illuminants[key] = JSONHelpers.doubleArray(value)
            }
            let spaceObject = root["spaces"] as? [String: Any] ?? [:]
            var spaces: [String: RGBSpaceInfo] = [:]
            for (key, value) in spaceObject {
                guard let object = value as? [String: Any] else { continue }
                let primaries = JSONHelpers.doubleMatrix(object["primaries"])
                let whitepoint = JSONHelpers.doubleArray(object["whitepoint"])
                let toXYZ = JSONHelpers.doubleMatrix(object["toXYZ"])
                let fromXYZ = JSONHelpers.doubleMatrix(object["fromXYZ"])
                guard primaries.count == 3, whitepoint.count >= 2,
                      toXYZ.count == 3, fromXYZ.count == 3 else { continue }
                let white = whitepoint.count >= 3
                    ? Vec3(whitepoint[0], whitepoint[1], whitepoint[2])
                    : ColorMath.xyToXYZ(whitepoint[0], whitepoint[1])
                spaces[key] = RGBSpaceInfo(
                    name: key,
                    primaries: primaries,
                    whitepoint: white,
                    toXYZ: Mat3(rows: toXYZ),
                    fromXYZ: Mat3(rows: fromXYZ)
                )
            }
            return ColorDataStore(
                shapeStart: JSONHelpers.double(shape.first, default: 380),
                shapeEnd: shape.count > 1 ? JSONHelpers.double(shape[1], default: 780) : 780,
                shapeStep: shape.count > 2 ? JSONHelpers.double(shape[2], default: 5) : 5,
                cmfs: cmfs,
                lms: lms,
                illuminants: illuminants,
                spaces: spaces,
                mallettBasis: JSONHelpers.doubleMatrix(root["mallett_basis"])
            )
        } catch {
            fatalError("Unable to load ColorData.json: \(error)")
        }
    }()

    var wavelengths: [Double] {
        var values: [Double] = []
        var value = shapeStart
        while value <= shapeEnd + 1e-9 {
            values.append(value)
            value += shapeStep
        }
        return values
    }
}

enum CCTFKind {
    case srgb
    case proPhoto
    case gamma22
    case gamma26
    case rec2020
    case linear
}

enum ColorMath {
    static let cat16 = Mat3([
        0.401288, 0.650173, -0.051461,
        -0.250268, 1.204414, 0.045854,
        -0.002079, 0.048952, 0.953127,
    ])
    static let cat02 = Mat3([
        0.7328, 0.4296, -0.1624,
        -0.7036, 1.6975, 0.0061,
        0.0030, 0.0136, 0.9834,
    ])

    static func cctfKind(for space: String) -> CCTFKind {
        switch space {
        case "sRGB", "Display P3", "ITU-R BT.709":
            return .srgb
        case "ProPhoto RGB":
            return .proPhoto
        case "Adobe RGB (1998)":
            return .gamma22
        case "DCI-P3":
            return .gamma26
        case "ITU-R BT.2020":
            return .rec2020
        case "ACES2065-1", "ACEScg":
            return .linear
        default:
            return .srgb
        }
    }

    static func cctfDecode(_ value: Double, kind: CCTFKind) -> Double {
        switch kind {
        case .srgb:
            if value <= 0.04045 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        case .proPhoto:
            if value <= 0.03125 { return value / 16.0 }
            return pow(value, 1.8)
        case .gamma22:
            return pow(max(value, 0), 2.2)
        case .gamma26:
            return pow(max(value, 0), 2.6)
        case .rec2020:
            if value < 0.00045 { return value / 4.5 }
            return pow((value + 0.115) / 1.15, 2.4)
        case .linear:
            return value
        }
    }

    static func cctfEncode(_ value: Double, kind: CCTFKind) -> Double {
        switch kind {
        case .srgb:
            if value <= 0.0031308 { return value * 12.92 }
            return 1.055 * pow(max(value, 0), 1.0 / 2.4) - 0.055
        case .proPhoto:
            if value <= 0.001953125 { return value * 16.0 }
            return pow(max(value, 0), 1.0 / 1.8)
        case .gamma22:
            return pow(max(value, 0), 1.0 / 2.2)
        case .gamma26:
            return pow(max(value, 0), 1.0 / 2.6)
        case .rec2020:
            if value < 0.00045 / 4.5 { return value * 4.5 }
            return 1.15 * pow(max(value, 0), 1.0 / 2.4) - 0.115
        case .linear:
            return value
        }
    }

    static func rgbToRGB(_ rgb: Vec3, from sourceName: String, to destinationName: String,
                        adaptation: Mat3 = ColorMath.cat02) -> Vec3 {
        guard let source = ColorDataStore.shared.spaces[sourceName],
              let destination = ColorDataStore.shared.spaces[destinationName] else {
            return Vec3(.nan, .nan, .nan)
        }
        let xyz = source.toXYZ.apply(rgb)
        let adapted = adapt(xyz, sourceWhite: source.whitepoint,
                            destinationWhite: destination.whitepoint, transform: adaptation)
        return destination.fromXYZ.apply(adapted)
    }

    /// 预先把「RGB → 适配到目标白点的 XYZ」合成单个 3×3 矩阵，供逐像素路径复用。
    static func rgbToXYZMatrix(spaceName: String, illuminantXY: (Double, Double),
                               adaptation: Mat3 = ColorMath.cat16) -> Mat3? {
        guard let space = ColorDataStore.shared.spaces[spaceName] else { return nil }
        let source = space.whitepoint
        let destination = xyToXYZ(illuminantXY.0, illuminantXY.1)
        let sourceLMS = adaptation.apply(source)
        let destinationLMS = adaptation.apply(destination)
        let ratio = Mat3([
            destinationLMS.x / sourceLMS.x, 0, 0,
            0, destinationLMS.y / sourceLMS.y, 0,
            0, 0, destinationLMS.z / sourceLMS.z,
        ])
        return adaptation.inverted() * ratio * adaptation * space.toXYZ
    }

    static func rgbToXYZ(_ rgb: Vec3, spaceName: String, illuminantXY: (Double, Double)? = nil,
                         applyCCTFDecoding: Bool = false, adaptation: Mat3 = ColorMath.cat16) -> Vec3 {
        guard let space = ColorDataStore.shared.spaces[spaceName] else {
            return Vec3(.nan, .nan, .nan)
        }
        var working = rgb
        if applyCCTFDecoding {
            let kind = cctfKind(for: spaceName)
            working = Vec3(
                cctfDecode(working.x, kind: kind),
                cctfDecode(working.y, kind: kind),
                cctfDecode(working.z, kind: kind)
            )
        }
        var xyz = space.toXYZ.apply(working)
        if let xy = illuminantXY {
            let destination = xyToXYZ(xy.0, xy.1)
            xyz = adapt(xyz, sourceWhite: space.whitepoint, destinationWhite: destination, transform: adaptation)
        }
        return xyz
    }

    static func xyzToRGB(_ xyz: Vec3, spaceName: String, illuminantXY: (Double, Double)? = nil,
                         applyCCTFEncoding: Bool = false, adaptation: Mat3 = ColorMath.cat02) -> Vec3 {
        guard let space = ColorDataStore.shared.spaces[spaceName] else {
            return Vec3(.nan, .nan, .nan)
        }
        var working = xyz
        if let xy = illuminantXY {
            let source = xyToXYZ(xy.0, xy.1)
            working = adapt(working, sourceWhite: source, destinationWhite: space.whitepoint, transform: adaptation)
        }
        var rgb = space.fromXYZ.apply(working)
        if applyCCTFEncoding {
            let kind = cctfKind(for: spaceName)
            rgb = Vec3(
                cctfEncode(rgb.x, kind: kind),
                cctfEncode(rgb.y, kind: kind),
                cctfEncode(rgb.z, kind: kind)
            )
        }
        return rgb
    }

    static func adapt(_ xyz: Vec3, sourceWhite: Vec3, destinationWhite: Vec3, transform: Mat3) -> Vec3 {
        guard sourceWhite.y > 1e-20, destinationWhite.y > 1e-20 else { return xyz }
        let sourceLMS = transform.apply(sourceWhite)
        let destinationLMS = transform.apply(destinationWhite)
        let inverse = transform.inverted()
        let ratios = Vec3(
            destinationLMS.x / sourceLMS.x,
            destinationLMS.y / sourceLMS.y,
            destinationLMS.z / sourceLMS.z
        )
        let scaled = transform.apply(xyz) * ratios
        return inverse.apply(scaled)
    }

    static func xyToXYZ(_ x: Double, _ y: Double) -> Vec3 {
        guard y != 0 else { return Vec3(0, 0, 0) }
        return Vec3(x / y, 1.0, (1.0 - x - y) / y)
    }

    static func xyzToXY(_ xyz: Vec3) -> (Double, Double) {
        let sum = xyz.x + xyz.y + xyz.z
        guard sum != 0 else { return (0, 0) }
        return (xyz.x / sum, xyz.y / sum)
    }

    static func xyToRGB(_ x: Double, _ y: Double, luminance: Double, spaceName: String,
                        applyCCTFEncoding: Bool = false) -> Vec3 {
        let xyz = xyToXYZ(x, y) * luminance
        return xyzToRGB(xyz, spaceName: spaceName, applyCCTFEncoding: applyCCTFEncoding)
    }
}

