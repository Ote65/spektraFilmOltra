import Foundation

/// CIECAM16-UCS（Li & Luo 2017）正向 / 逆向变换。
/// 观看条件固定为 colour-science 的显示审阅取值：L_A = 64, Y_b = 20, Average surround。
/// 逐行对应 `colour.XYZ_to_CAM16` / `CAM16_to_XYZ` / `XYZ_to_CAM16UCS` / `CAM16UCS_to_XYZ`。
enum CAM16UCS {
    static let matrix16 = Mat3(rows: [
        [0.401288, 0.650173, -0.051461],
        [-0.250268, 1.204414, 0.045854],
        [-0.002079, 0.048952, 0.953127],
    ])
    static let matrix16Inverse = matrix16.inverted()

    static let lA = 64.0
    static let yB = 20.0
    static let surroundF = 1.0
    static let surroundC = 0.69
    static let surroundNC = 1.0

    // CAM16-UCS (Luo 2006 CAM02-UCS) 系数
    static let c1 = 0.007
    static let c2 = 0.0228
    static let epsilon = 1e-15

    struct Setup {
        let dRGB: Vec3
        let fL: Double
        let nBB: Double
        let nCB: Double
        let z: Double
        let n: Double
        let aWhite: Double
        let jpWhite: Double
    }

    static func spow(_ base: Double, _ exponent: Double) -> Double {
        let value = pow(abs(base), exponent)
        return base < 0 ? -value : value
    }

    static func safeSqrt(_ value: Double) -> Double {
        value < 0 ? .nan : sqrt(value)
    }

    static func safeDiv(_ numerator: Double, _ denominator: Double) -> Double {
        denominator == 0 ? 0 : numerator / denominator
    }

    static func postForward(_ rgb: Vec3, _ fL: Double) -> Vec3 {
        func channel(_ value: Double) -> Double {
            let compressed = pow(fL * abs(value) / 100, 0.42)
            let magnitude = 400 * compressed / (27.13 + compressed)
            return (value < 0 ? -magnitude : magnitude) + 0.1
        }
        return Vec3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }

    static func postInverse(_ rgb: Vec3, _ fL: Double) -> Vec3 {
        func channel(_ value: Double) -> Double {
            let shifted = value - 0.1
            let magnitude = abs(shifted)
            let term = 100 / fL * spow(27.13 * magnitude / (400 - magnitude), 1 / 0.42)
            return shifted < 0 ? -term : term
        }
        return Vec3(channel(rgb.x), channel(rgb.y), channel(rgb.z))
    }

    static func setup(whiteXYZ: Vec3) -> Setup {
        let white = whiteXYZ * 100
        let rgbW = matrix16.apply(white)
        let d = min(max(surroundF * (1 - (1 / 3.6) * exp((-lA - 42) / 92)), 0), 1)
        let yw = white.y
        let n = yB / yw
        let z = 1.48 + sqrt(n)
        let nBB = 0.725 * pow(1 / n, 0.2)
        let k = 1 / (5 * lA + 1)
        let k4 = pow(k, 4)
        let fL = 0.2 * k4 * (5 * lA) + 0.1 * pow(1 - k4, 2) * pow(5 * lA, 1.0 / 3.0)
        let dRGB = Vec3(
            d * yw / rgbW.x + 1 - d,
            d * yw / rgbW.y + 1 - d,
            d * yw / rgbW.z + 1 - d
        )
        let rgbWC = rgbW * dRGB
        let rgbAW = postForward(rgbWC, fL)
        let aWhite = (2 * rgbAW.x + rgbAW.y + rgbAW.z / 20 - 0.305) * nBB
        let provisional = Setup(dRGB: dRGB, fL: fL, nBB: nBB, nCB: nBB, z: z, n: n,
                                aWhite: aWhite, jpWhite: 0)
        let jpWhite = forwardJp(whiteXYZ, provisional)
        return Setup(dRGB: dRGB, fL: fL, nBB: nBB, nCB: nBB, z: z, n: n,
                     aWhite: aWhite, jpWhite: jpWhite)
    }

    /// XYZ（Y=1 尺度）→ CAM16-UCS 的 (J', a', b')。
    static func xyzToJab(_ xyz: Vec3, setup: Setup) -> Vec3 {
        let rgb = matrix16.apply(xyz * 100)
        let rgbC = rgb * setup.dRGB
        let rgbA = postForward(rgbC, setup.fL)

        let a = rgbA.x - 12 * rgbA.y / 11 + rgbA.z / 11
        let b = (rgbA.x + rgbA.y - 2 * rgbA.z) / 9
        let h = atan2(b, a)
        let hDegrees = (h * 180 / Double.pi).truncatingRemainder(dividingBy: 360)
        let eT = (cos(2 + hDegrees * Double.pi / 180) + 3.8) / 4

        let achromatic = (2 * rgbA.x + rgbA.y + rgbA.z / 20 - 0.305) * setup.nBB
        let j = 100 * spow(achromatic / setup.aWhite, surroundC * setup.z)

        let denominator = rgbA.x + rgbA.y + 21 * rgbA.z / 20
        let t = denominator == 0 ? 0
            : ((50000.0 / 13) * surroundNC * setup.nCB) * (eT * sqrt(a * a + b * b)) / denominator
        let c = spow(t, 0.9) * safeSqrt(j / 100) * pow(1.64 - pow(0.29, setup.n), 0.73)
        let m = c * pow(setup.fL, 0.25)

        let jp = (1 + 100 * c1) * j / (1 + c1 * j)
        let mp = log1p(c2 * m) / c2
        return Vec3(jp, mp * cos(h), mp * sin(h))
    }

    static func forwardJp(_ xyz: Vec3, _ setup: Setup) -> Double {
        xyzToJab(xyz, setup: setup).x
    }

    /// CAM16-UCS 的 (J', a', b') → XYZ（Y=1 尺度）。
    static func jabToXYZ(_ jab: Vec3, setup: Setup) -> Vec3 {
        let jp = jab.x
        let j = -jp / (c1 * jp - 1 - 100 * c1)
        let mp = sqrt(jab.y * jab.y + jab.z * jab.z)
        let h = atan2(jab.z, jab.y)
        let m = expm1(mp * c2) / c2
        let c = m / pow(setup.fL, 0.25)
        let jprime = max(j, epsilon)
        let t = spow(c / (safeSqrt(jprime / 100) * pow(1.64 - pow(0.29, setup.n), 0.73)), 1 / 0.9)
        let eT = (cos(2 + h) + 3.8) / 4
        let achromatic = setup.aWhite * spow(j / 100, 1 / (surroundC * setup.z))

        let p1 = safeDiv((50000.0 / 13) * surroundNC * setup.nCB * eT, t)
        let p2 = achromatic / setup.nBB + 0.305
        let p3 = 21.0 / 20
        let sinH = sin(h)
        let cosH = cos(h)
        let cosSin = safeDiv(cosH, sinH)
        let sinCos = safeDiv(sinH, cosH)
        let p4 = safeDiv(p1, sinH)
        let p5 = safeDiv(p1, cosH)
        let np = p2 * (2 + p3) * (460.0 / 1403)
        var a = 0.0
        var b = 0.0
        if abs(sinH) >= abs(cosH) {
            b = np / (p4 + (2 + p3) * (220.0 / 1403) * cosSin - (27.0 / 1403) + p3 * (6300.0 / 1403))
            a = b * cosSin
        } else {
            a = np / (p5 + (2 + p3) * (220.0 / 1403) - ((27.0 / 1403) - p3 * (6300.0 / 1403)) * sinCos)
            b = a * sinCos
        }
        if t == 0 { a = 0; b = 0 }

        let rgbA = Vec3(
            (460 * p2 + 451 * a + 288 * b) / 1403,
            (460 * p2 - 891 * a - 261 * b) / 1403,
            (460 * p2 - 220 * a - 6300 * b) / 1403
        )
        let rgbC = postInverse(rgbA, setup.fL)
        let rgb = Vec3(
            rgbC.x / setup.dRGB.x,
            rgbC.y / setup.dRGB.y,
            rgbC.z / setup.dRGB.z
        )
        return matrix16Inverse.apply(rgb) / 100
    }
}
