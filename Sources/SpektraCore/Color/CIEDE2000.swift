import Foundation

/// CIEDE2000 色差：用于 LUT 预测档与精算结果的预检门禁。
/// 输入为线性 ProPhoto；Lab 使用 ProPhoto 自身白点（D50）。
enum CIEDE2000 {
    struct Lab {
        let l: Double
        let a: Double
        let b: Double
    }

    struct Stats {
        let max: Double
        let p99: Double
        let mean: Double
    }

    static func lab(fromProPhotoLinear rgb: Vec3) -> Lab {
        guard let space = ColorDataStore.shared.spaces["ProPhoto RGB"] else {
            return Lab(l: 0, a: 0, b: 0)
        }
        let safe = Vec3(
            rgb.x.isFinite ? rgb.x : 0,
            rgb.y.isFinite ? rgb.y : 0,
            rgb.z.isFinite ? rgb.z : 0
        )
        let xyz = space.toXYZ.apply(safe)
        let white = space.whitepoint
        let fx = f(xyz.x / max(abs(white.x), 1e-9))
        let fy = f(xyz.y / max(abs(white.y), 1e-9))
        let fz = f(xyz.z / max(abs(white.z), 1e-9))
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private static func f(_ value: Double) -> Double {
        let eps = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        return value > eps ? cbrt(value) : (kappa * value + 16) / 116
    }

    /// Sharma 2005 的 CIEDE2000 公式，kL = kC = kH = 1。
    static func deltaE(_ first: Lab, _ second: Lab) -> Double {
        let l1 = first.l, a1 = first.a, b1 = first.b
        let l2 = second.l, a2 = second.a, b2 = second.b

        let c1 = sqrt(a1 * a1 + b1 * b1)
        let c2 = sqrt(a2 * a2 + b2 * b2)
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - sqrt(cBar7 / (cBar7 + pow(25, 7))))
        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = sqrt(a1p * a1p + b1 * b1)
        let c2p = sqrt(a2p * a2p + b2 * b2)

        var h1p = atan2(b1, a1p) * 180 / .pi
        if h1p < 0 { h1p += 360 }
        var h2p = atan2(b2, a2p) * 180 / .pi
        if h2p < 0 { h2p += 360 }

        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 }
            else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp / 2 * .pi / 180)

        let lBar = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2
        var hBarP = 0.0
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 {
                hBarP = (h1p + h2p) / 2
            } else if h1p + h2p < 360 {
                hBarP = (h1p + h2p + 360) / 2
            } else {
                hBarP = (h1p + h2p - 360) / 2
            }
        }
        let t = 1
            - 0.17 * cos((hBarP - 30) * .pi / 180)
            + 0.24 * cos(2 * hBarP * .pi / 180)
            + 0.32 * cos((3 * hBarP + 6) * .pi / 180)
            - 0.20 * cos((4 * hBarP - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc

        let termL = dLp / sl
        let termC = dCp / sc
        let termH = dHp / sh
        return sqrt(termL * termL + termC * termC + termH * termH
                    + rt * termC * termH)
    }

    static func stats(reference: ImageRGB, candidate: ImageRGB) -> Stats? {
        guard reference.width == candidate.width,
              reference.height == candidate.height,
              reference.width > 0, reference.height > 0 else { return nil }
        let count = reference.width * reference.height
        var values = [Double](repeating: 0, count: count)
        for p in 0..<count {
            let r = Vec3(
                Double(reference.data[p * 3]),
                Double(reference.data[p * 3 + 1]),
                Double(reference.data[p * 3 + 2])
            )
            let c = Vec3(
                Double(candidate.data[p * 3]),
                Double(candidate.data[p * 3 + 1]),
                Double(candidate.data[p * 3 + 2])
            )
            values[p] = deltaE(lab(fromProPhotoLinear: r), lab(fromProPhotoLinear: c))
        }
        values.sort()
        let maxValue = values.last ?? 0
        let p99Index = min(values.count - 1, max(0, Int(Double(values.count - 1) * 0.99)))
        let mean = values.reduce(0, +) / Double(values.count)
        return Stats(max: maxValue, p99: values[p99Index], mean: mean)
    }
}
