import Foundation
import simd

/// 视频帧的密度域↔显示域色彩转换。
///
/// LUT 烘焙固定用线性 ProPhoto 输入（见 PreviewLUTService.makeBakeParams），
/// 所以解码端要把 Rec.709 视频帧转成线性 ProPhoto；t4 输出线性 sRGB，
/// 编码端再按 Rec.709 OETF/矩阵写回 YUV。方案 6.2，任何"用 sRGB 近似"的
/// 简写都会让暗部偏色，这里显式保留完整链路。
enum VideoColorIO {
    // MARK: - 矩阵（行主序，便于直接填 MSL 的 float3x3）

    /// 线性 Rec.709 → 线性 ProPhoto，含 D65 白点适配。
    static let rec709ToProPhoto: simd_float3x3 = {
        basisMatrix(from: "ITU-R BT.709", to: "ProPhoto RGB")
    }()

    /// 线性 sRGB → 线性 Rec.709。两者原色/白点一致（同一 D65 基色），
    /// 但保留矩阵接口，未来换 BT.2020 时只改这里。
    static let srgbToRec709: simd_float3x3 = {
        basisMatrix(from: "sRGB", to: "ITU-R BT.709")
    }()

    private static func basisMatrix(from source: String, to destination: String) -> simd_float3x3 {
        let ex = ColorMath.rgbToRGB(Vec3(1, 0, 0), from: source, to: destination)
        let ey = ColorMath.rgbToRGB(Vec3(0, 1, 0), from: source, to: destination)
        let ez = ColorMath.rgbToRGB(Vec3(0, 0, 1), from: source, to: destination)
        // simd_float3x3 按列存储；MSL 的 float3x3 同样按列，直接传内存字节即可。
        return simd_float3x3(
            SIMD3<Float>(Float(ex.x), Float(ex.y), Float(ex.z)),
            SIMD3<Float>(Float(ey.x), Float(ey.y), Float(ey.z)),
            SIMD3<Float>(Float(ez.x), Float(ez.y), Float(ez.z))
        )
    }

    // MARK: - 标量转换（CPU 侧，用于参考帧测光 / 对拍）

    /// Rec.709 显示编码值 → 线性 Rec.709。
    static func rec709EOTF(_ value: Double) -> Double {
        let v = min(max(value, 0), 1)
        if v < 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    /// 线性 Rec.709 → Rec.709 显示编码值。
    static func rec709OETF(_ value: Double) -> Double {
        let v = min(max(value, 0), 1)
        if v <= 0.0031308 { return v * 12.92 }
        return 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// 把 Rec.709 显示编码的 RGB 三元组转成线性 ProPhoto（CPU 参考实现）。
    static func displayRGBToLinearProPhoto(_ rgb: Vec3) -> Vec3 {
        let linear = Vec3(rec709EOTF(rgb.x), rec709EOTF(rgb.y), rec709EOTF(rgb.z))
        let m = rec709ToProPhoto
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2
        return Vec3(
            Double(c0.x * Float(linear.x) + c1.x * Float(linear.y) + c2.x * Float(linear.z)),
            Double(c0.y * Float(linear.x) + c1.y * Float(linear.y) + c2.y * Float(linear.z)),
            Double(c0.z * Float(linear.x) + c1.z * Float(linear.y) + c2.z * Float(linear.z))
        )
    }

    /// 线性 sRGB（t4 输出）→ Rec.709 显示编码。sRGB 与 Rec.709 原色一致，
    /// 这里用 Rec.709 OETF 输出，与视频色彩标签一致。
    static func linearToDisplayRec709(_ rgb: Vec3) -> Vec3 {
        Vec3(rec709OETF(rgb.x), rec709OETF(rgb.y), rec709OETF(rgb.z))
    }
}
