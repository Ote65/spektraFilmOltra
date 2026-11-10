import Foundation

struct InputGamutSpec {
    var active: Bool = true
    var algorithm: String = "xy"
    var knee: [Double] = [0, 1, 6]
}

struct OutputGamutSpec {
    var algorithm: String = "cam16ucs"
    var knee: [Double] = [0, 1, 6]
}

enum GamutCompression {
    static let spectralLocus: [(Double, Double)] = {
        let cmfs = ColorDataStore.shared.cmfs
        var points: [(Double, Double)] = []
        for i in 0..<min(65, cmfs.count) {
            let total = cmfs[i][0] + cmfs[i][1] + cmfs[i][2]
            let x = cmfs[i][0] / max(total, 1e-12)
            let y = cmfs[i][1] / max(total, 1e-12)
            points.append((x, y))
        }
        if let first = points.first { points.append(first) }
        return points
    }()

    static func reinhardKnee(_ distance: Double, threshold: Double, limit: Double, power: Double) -> Double {
        guard distance > threshold else { return distance }
        let scale = limit - threshold
        let x = (distance - threshold) / scale
        let y = x / pow(1 + pow(x, power), 1 / power)
        return threshold + scale * y
    }

    static func rayPolygonDistance(origin: (Double, Double), direction: (Double, Double)) -> Double {
        let polygon = spectralLocus
        let edgeCount = polygon.count - 1
        var minimum = Double.infinity
        for k in 0..<edgeCount {
            let a = polygon[k]
            let b = polygon[k + 1]
            let ex = b.0 - a.0
            let ey = b.1 - a.1
            let dx = direction.0
            let dy = direction.1
            let denom = dx * ey - dy * ex
            if abs(denom) <= 1e-12 { continue }
            let ox = origin.0 - a.0
            let oy = origin.1 - a.1
            let t = (-ox * ey + oy * ex) / denom
            let s = (-ox * dy + oy * dx) / denom
            if t > 1e-9 && s >= 0 && s <= 1 && t < minimum {
                minimum = t
            }
        }
        return minimum
    }

    static func compressXYRadial(_ xy: (Double, Double), white: (Double, Double),
                                 threshold: Double, limit: Double, power: Double) -> (Double, Double) {
        let deltaX = xy.0 - white.0
        let deltaY = xy.1 - white.1
        let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
        if distance < 1e-9 { return xy }
        let direction = (deltaX / distance, deltaY / distance)
        let boundary = rayPolygonDistance(origin: white, direction: direction)
        let normalized = distance / max(boundary, 1e-12)
        let compressed = reinhardKnee(normalized, threshold: threshold, limit: limit, power: power)
        return (white.0 + direction.0 * compressed * boundary,
                white.1 + direction.1 * compressed * boundary)
    }

    static func compressXY(_ xy: (Double, Double), white: (Double, Double), spec: InputGamutSpec) -> (Double, Double) {
        guard spec.active else { return xy }
        if spec.algorithm == "xy" {
            return compressXYRadial(xy, white: white, threshold: spec.knee[0],
                                    limit: spec.knee[1], power: spec.knee[2])
        }
        return xy
    }

    static func remapTCLUT(_ lut: SpectralLUT, referenceIlluminantXY: (Double, Double),
                           spec: InputGamutSpec) -> SpectralLUT {
        guard spec.active else { return lut }
        let size = lut.size
        let channels = lut.channels
        var output = [Double](repeating: 0, count: lut.values.count)
        func sampleBilinear(_ x: Double, _ y: Double, _ c: Int) -> Double {
            let clampedX = min(max(x, 0), Double(size - 1))
            let clampedY = min(max(y, 0), Double(size - 1))
            let x0 = Int(floor(clampedX))
            let y0 = Int(floor(clampedY))
            let x1 = min(x0 + 1, size - 1)
            let y1 = min(y0 + 1, size - 1)
            let tx = clampedX - Double(x0)
            let ty = clampedY - Double(y0)
            let v00 = lut[x0, y0, c]
            let v10 = lut[x1, y0, c]
            let v01 = lut[x0, y1, c]
            let v11 = lut[x1, y1, c]
            return (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
        }
        for i in 0..<size {
            for j in 0..<size {
                let tc = (Double(i) / Double(size - 1), Double(j) / Double(size - 1))
                let xy = SpectralUpsampling.quad2tri(tc.0, tc.1)
                let compressed = compressXY(xy, white: referenceIlluminantXY, spec: spec)
                let compressedTC = SpectralUpsampling.tri2quad(compressed.0, compressed.1)
                let x = compressedTC.0 * Double(size - 1)
                let y = compressedTC.1 * Double(size - 1)
                for c in 0..<channels {
                    output[(i * size + j) * channels + c] = sampleBilinear(x, y, c)
                }
            }
        }
        return SpectralLUT(size: size, channels: channels, values: output)
    }
}
