import Foundation

enum NPY {
    static func load(_ url: URL) throws -> (shape: [Int], values: [Double]) {
        let data = try Data(contentsOf: url)
        guard data.count > 10 else { throw CoreError.invalidJSON(url.lastPathComponent) }
        let magic = Array(data.prefix(6))
        guard magic == [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] else {
            throw CoreError.invalidJSON(url.lastPathComponent)
        }
        let major = data[6]
        var headerLength = 0
        var offset = 10
        if major == 1 {
            headerLength = Int(data[8]) + Int(data[9]) << 8
        } else {
            headerLength = Int(data[8]) + (Int(data[9]) << 8) + (Int(data[10]) << 16) + (Int(data[11]) << 24)
            offset = 12
        }
        guard headerLength > 0, offset + headerLength <= data.count else {
            throw CoreError.invalidJSON(url.lastPathComponent)
        }
        let headerText = String(data: data.subdata(in: offset..<(offset + headerLength)), encoding: .ascii) ?? ""
        let descriptor = extract(headerText, key: "descr")
        let shapeText = extract(headerText, key: "shape")
        let shape = parseShape(shapeText)
        let count = shape.reduce(1, *)
        let payload = data.subdata(in: (offset + headerLength)..<data.count)
        var values = [Double](repeating: 0, count: count)

        switch descriptor {
        case "<f2", "|f2":
            guard payload.count >= count * 2 else { throw CoreError.invalidJSON(url.lastPathComponent) }
            payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    let bits = raw.load(fromByteOffset: i * 2, as: UInt16.self)
                    values[i] = Double(Float16(bitPattern: bits))
                }
            }
        case "<f4", "|f4":
            guard payload.count >= count * 4 else { throw CoreError.invalidJSON(url.lastPathComponent) }
            payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    values[i] = Double(raw.load(fromByteOffset: i * 4, as: Float32.self))
                }
            }
        case "<f8", "|f8":
            guard payload.count >= count * 8 else { throw CoreError.invalidJSON(url.lastPathComponent) }
            payload.withUnsafeBytes { raw in
                for i in 0..<count {
                    values[i] = raw.load(fromByteOffset: i * 8, as: Double.self)
                }
            }
        default:
            throw CoreError.unsupported("NPY dtype \(descriptor)")
        }
        return (shape, values)
    }

    private static func extract(_ header: String, key: String) -> String {
        guard let range = header.range(of: "'\(key)':") else { return "" }
        let rest = header[range.upperBound...]
        if key == "shape" {
            guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") else { return "" }
            return String(rest[open...close])
        }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if let comma = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<comma]).trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        }
        return ""
    }

    private static func parseShape(_ text: String) -> [Int] {
        let cleaned = text.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        return cleaned.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

struct SpectralLUT {
    let size: Int
    let channels: Int
    let values: [Double]

    init(size: Int, channels: Int, values: [Double]) {
        self.size = size
        self.channels = channels
        self.values = values
    }

    subscript(x: Int, y: Int, c: Int) -> Double {
        values[(x * size + y) * channels + c]
    }
}

enum SpectralUpsampling {
    static let lut: SpectralLUT = {
        do {
            let url = ResourceLocator.url("LUTs/spectral_upsampling/irradiance_xy_tc.npy")
            let loaded = try NPY.load(url)
            guard loaded.shape.count == 3 else { throw CoreError.invalidJSON("irradiance_xy_tc.npy") }
            return SpectralLUT(size: loaded.shape[0], channels: loaded.shape[2], values: loaded.values)
        } catch {
            fatalError("Unable to load spectral LUT: \(error)")
        }
    }()

    static func tri2quad(_ x: Double, _ y: Double) -> (Double, Double) {
        let tx = x
        let ty = y
        let qy = ty / max(1.0 - tx, 1e-10)
        var qx = (1.0 - tx) * (1.0 - tx)
        qx = min(max(qx, 0), 1)
        let qyClamped = min(max(qy, 0), 1)
        return (qx, qyClamped)
    }

    static func quad2tri(_ x: Double, _ y: Double) -> (Double, Double) {
        let sqrtX = sqrt(max(x, 0))
        return (1.0 - sqrtX, y * sqrtX)
    }

    static func mitchellWeight(_ t: Double, B: Double = 1.0 / 3.0, C: Double = 1.0 / 3.0) -> Double {
        let x = abs(t)
        if x < 1 {
            return (1.0 / 6.0) * ((12 - 9 * B - 6 * C) * x * x * x + (-18 + 12 * B + 6 * C) * x * x + (6 - 2 * B))
        }
        if x < 2 {
            return (1.0 / 6.0) * ((-B - 6 * C) * x * x * x + (6 * B + 30 * C) * x * x + (-12 * B - 48 * C) * x + (8 * B + 24 * C))
        }
        return 0
    }

    static func safeIndex(_ index: Int, _ length: Int) -> Int {
        if index < 0 { return -index }
        if index >= length { return 2 * (length - 1) - index }
        return index
    }

    static func clampedCoordinate(_ coordinate: Double, _ length: Int) -> Double {
        if coordinate <= 0 { return 0 }
        let upper = Double(length - 1)
        return coordinate >= upper ? upper : coordinate
    }

    static func cubicBaseFraction(_ coordinate: Double, _ length: Int) -> (Int, Double) {
        guard coordinate.isFinite else { return (0, 0.0) }
        let clamped = clampedCoordinate(coordinate, length)
        if clamped >= Double(length - 1) { return (length - 2, 1.0) }
        let base = Int(floor(clamped))
        return (base, clamped - Double(base))
    }

    static func sample2D(_ lut: SpectralLUT, x: Double, y: Double) -> Vec3 {
        let (xBase, xFrac) = cubicBaseFraction(x, lut.size)
        let (yBase, yFrac) = cubicBaseFraction(y, lut.size)
        let wx = [
            mitchellWeight(xFrac + 1), mitchellWeight(xFrac),
            mitchellWeight(xFrac - 1), mitchellWeight(xFrac - 2),
        ]
        let wy = [
            mitchellWeight(yFrac + 1), mitchellWeight(yFrac),
            mitchellWeight(yFrac - 1), mitchellWeight(yFrac - 2),
        ]
        var out = Vec3(0, 0, 0)
        var weightSum = 0.0
        for i in 0..<4 {
            let xi = safeIndex(xBase - 1 + i, lut.size)
            for j in 0..<4 {
                let yj = safeIndex(yBase - 1 + j, lut.size)
                let weight = wx[i] * wy[j]
                weightSum += weight
                out.x += weight * lut[xi, yj, 0]
                out.y += weight * lut[xi, yj, 1]
                out.z += weight * lut[xi, yj, 2]
            }
        }
        if weightSum != 0 {
            out = out / weightSum
        }
        return out
    }

    static func rgbToTCB(_ rgb: Vec3, colorSpace: String, applyCCTFDecoding: Bool,
                         referenceIlluminant: String,
                         illuminantXY: (Double, Double)? = nil,
                         toXYZMatrix: Mat3? = nil) -> (tc: (Double, Double), b: Double) {
        let illuXY = illuminantXY ?? ((try? Illuminants.xy(referenceIlluminant)) ?? (0.3127, 0.3290))
        var working = rgb
        if applyCCTFDecoding {
            let kind = ColorMath.cctfKind(for: colorSpace)
            working = Vec3(
                ColorMath.cctfDecode(working.x, kind: kind),
                ColorMath.cctfDecode(working.y, kind: kind),
                ColorMath.cctfDecode(working.z, kind: kind)
            )
        }
        let xyz = toXYZMatrix?.apply(working) ?? ColorMath.rgbToXYZ(
            working, spaceName: colorSpace, illuminantXY: illuXY,
            applyCCTFDecoding: false, adaptation: ColorMath.cat16
        )
        let bRaw = xyz.x + xyz.y + xyz.z
        let b = bRaw.isFinite ? bRaw : 0
        let denominator = max(b, 1e-10)
        let xy = (xyz.x / denominator, xyz.y / denominator)
        return (tri2quad(xy.0, xy.1), b)
    }

    static func erf4Window(_ params: [Double]) -> [Double] {
        guard params.count >= 4 else {
            return [Double](repeating: 1, count: ColorDataStore.shared.wavelengths.count)
        }
        let cUV = params[0], sigmaUV = params[1], cIR = params[2], sigmaIR = params[3]
        let sqrt2 = sqrt(2.0)
        let wl = ColorDataStore.shared.wavelengths
        var edgeUV = [Double](repeating: 0, count: wl.count)
        var edgeIR = [Double](repeating: 0, count: wl.count)
        for i in 0..<wl.count {
            edgeUV[i] = 0.5 * (1.0 + erf((wl[i] - cUV) / (sigmaUV * sqrt2)))
            edgeIR[i] = 0.5 * (1.0 - erf((wl[i] - cIR) / (sigmaIR * sqrt2)))
        }
        return zip(edgeUV, edgeIR).map { $0 * $1 }
    }

    static func computeHanatosTCPLUT(sensitivity: [[Double]], adaptation: Hanatos2025Adaptation?,
                                     gamutSpec: InputGamutSpec? = nil) -> SpectralLUT {
        let source = lut
        let channels = 3
        let wavelengths = ColorDataStore.shared.wavelengths.count
        var window = [[Double]](repeating: [1, 1, 1], count: wavelengths)
        if let adaptation, adaptation.applyWindow, adaptation.windowParams.count >= 4 {
            let illuminant = (try? Illuminants.standard(adaptation.referenceIlluminant ?? "D55")) ??
                [Double](repeating: 1, count: wavelengths)
            let rawWindow = erf4Window(adaptation.windowParams)
            var normalization = [Double](repeating: 0, count: 3)
            var denominator = [Double](repeating: 0, count: 3)
            for w in 0..<wavelengths {
                for c in 0..<channels {
                    let value = sensitivity[w][c] * illuminant[w]
                    normalization[c] += value * rawWindow[w]
                    denominator[c] += value
                }
            }
            for w in 0..<wavelengths {
                for c in 0..<channels {
                    let norm = normalization[c] / max(denominator[c], 1e-20)
                    window[w][c] = norm != 0 ? rawWindow[w] / norm : 1.0
                }
            }
        }

        var output = [Double](repeating: 0, count: source.values.count)
        for x in 0..<source.size {
            for y in 0..<source.size {
                for c in 0..<channels {
                    var sum = 0.0
                    for w in 0..<wavelengths {
                        let s = sensitivity[w][c]
                        let spectrum = source[x, y, w]
                        sum += spectrum * s * window[w][c]
                    }
                    output[(x * source.size + y) * channels + c] = sum
                }
            }
        }
        var result = SpectralLUT(size: source.size, channels: channels, values: output)
        if let gamutSpec, gamutSpec.active {
            let reference = (try? Illuminants.xy(adaptation?.referenceIlluminant ?? "D55")) ?? (0.3127, 0.3290)
            result = GamutCompression.remapTCLUT(result, referenceIlluminantXY: reference, spec: gamutSpec)
        }
        return result
    }

    static func rgbToRawHanatos(_ rgb: Vec3, sensitivity: [[Double]], colorSpace: String,
                                 applyCCTFDecoding: Bool, referenceIlluminant: String,
                                 tcLUT: SpectralLUT,
                                 illuminantXY: (Double, Double)? = nil,
                                 toXYZMatrix: Mat3? = nil) -> Vec3 {
        let (tc, b) = rgbToTCB(rgb, colorSpace: colorSpace,
                              applyCCTFDecoding: applyCCTFDecoding,
                              referenceIlluminant: referenceIlluminant,
                              illuminantXY: illuminantXY,
                              toXYZMatrix: toXYZMatrix)
        let scale = Double(tcLUT.size - 1)
        let raw = sample2D(tcLUT, x: tc.0 * scale, y: tc.1 * scale)
        return raw * b
    }
}

