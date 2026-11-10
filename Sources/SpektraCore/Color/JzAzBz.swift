import Foundation

/// JzAzBz（Safdar 2017）正/逆变换，包含 ST 2084 PQ。
/// 输入 XYZ 使用 Y=1 尺度（与输出色彩空间同一白点），内部按 100 cd/m² 锚定。
enum JzAzBz {
    static let b = 1.15
    static let g = 0.66
    static let d = -0.56
    static let d0 = 1.6295499532821566e-11
    static let peakLuminance = 10000.0
    static let yWhite = 100.0

    // ST 2084 常量（JzAzBz 重新优化的 m_2）
    static let m1 = 2610.0 / 4096.0 * 0.25
    static let m2 = 1.7 * 2523.0 / 32.0
    static let c1 = 3424.0 / 4096.0
    static let c2 = 2413.0 / 4096.0 * 32.0
    static let c3 = 2392.0 / 4096.0 * 32.0

    static let xyzToLMS = Mat3(rows: [
        [0.41478972, 0.579999, 0.0146480],
        [-0.2015100, 1.120649, 0.0531008],
        [-0.0166008, 0.264800, 0.6684799],
    ])
    static let lmsToXYZ = xyzToLMS.inverted()
    static let lmsPToIzazbz = Mat3(rows: [
        [0.500000, 0.500000, 0.000000],
        [3.524000, -4.066708, 0.542708],
        [0.199076, 1.096799, -1.295875],
    ])
    static let izazbzToLmsP = lmsPToIzazbz.inverted()

    static func pqForward(_ value: Double) -> Double {
        let yp = CAM16UCS.spow(value / peakLuminance, m1)
        return CAM16UCS.spow((c1 + c2 * yp) / (c3 * yp + 1), m2)
    }

    static func pqInverse(_ value: Double) -> Double {
        let vp = CAM16UCS.spow(value, 1 / m2)
        let n = max(0, vp - c1)
        return peakLuminance * CAM16UCS.spow(n / (c2 - c3 * vp), 1 / m1)
    }

    static func xyzToJzazbz(_ xyz: Vec3) -> Vec3 {
        let scaled = xyz * yWhite
        let xp = b * scaled.x - (b - 1) * scaled.z
        let yp = g * scaled.y - (g - 1) * scaled.x
        let lms = xyzToLMS.apply(Vec3(xp, yp, scaled.z))
        let lmsP = Vec3(pqForward(lms.x), pqForward(lms.y), pqForward(lms.z))
        let izazbz = lmsPToIzazbz.apply(lmsP)
        let jz = (1 + d) * izazbz.x / (1 + d * izazbz.x) - d0
        return Vec3(jz, izazbz.y, izazbz.z)
    }

    static func jzazbzToXYZ(_ jab: Vec3) -> Vec3 {
        let jzPlus = jab.x + d0
        let iz = jzPlus / (1 + d - d * jzPlus)
        let lmsP = izazbzToLmsP.apply(Vec3(iz, jab.y, jab.z))
        let lms = Vec3(pqInverse(lmsP.x), pqInverse(lmsP.y), pqInverse(lmsP.z))
        let xyzP = lmsToXYZ.apply(lms)
        let x = (xyzP.x + (b - 1) * xyzP.z) / b
        let y = (xyzP.y + (g - 1) * x) / g
        return Vec3(x, y, xyzP.z) / yWhite
    }
}
