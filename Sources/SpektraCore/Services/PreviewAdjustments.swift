import Foundation

/// 交互预测帧的近似效果层。
///
/// LUT 只覆盖显影/印相的确定性色彩变换；对比、浓度、滤色、清晰度这些
/// 连续轴在拖动过程中没有物理求解的时间预算，这里用可解释的近似模型补上：
/// 方向与幅度对得上，停手后仍由全精度精算帧替换。
/// 颗粒不在此列：它是随机统计量，必须由物理管线计算，预测帧直接不显示颗粒。
enum PreviewAdjustments {
    struct Params {
        /// 印相黄 / 品红滤色片偏移（引擎单位，-60…60）。
        var yShift: Double = 0
        var mShift: Double = 0
        /// 印相密度曲线的 gammaFactor（>1 = 反差更高）。LUT 烘焙时曲线 morph 被归零，
        /// 所以这里补的是「当前绝对 gamma」，不是相对基线的比值。
        var gamma: Double = 1
        /// 层间抑制（1 = 中性）。LUT 烘焙时该轴固定为 1，这里补绝对强度。
        var saturation: Double = 1
        /// 清晰度 -1…1：正加锐、负柔化。
        var clarity: Double = 0

        var isNeutral: Bool {
            abs(yShift) < 1e-6 && abs(mShift) < 1e-6
                && abs(gamma - 1) < 1e-6 && abs(saturation - 1) < 1e-6
                && abs(clarity) < 1e-6
        }
    }

    // MARK: - 线性域：滤色与色浓度

    /// 线性 sRGB 上做三通道增益与饱和度。方向对齐 11.3 实测：
    /// y 正 = 偏冷（蓝升红降），m 正 = 偏绿（绿升，红蓝降）。
    static func applyLinear(_ image: ImageRGB, params: Params) -> ImageRGB {
        let y = params.yShift
        let m = params.mShift
        let saturation = params.saturation
        guard abs(y) > 1e-6 || abs(m) > 1e-6 || abs(saturation - 1) > 1e-6 else { return image }

        // 系数由精算管线在测试 RAW 上的通道均值拟合：y+40（偏冷）→ R×0.75 / G×0.96 / B×1.51，
        // m+60（品红）→ R×0.77 / G×1.42 / B×0.91；约等于按几何均值归一的通道增益。
        // 用放大机滤色片的物理方向（y 正 = 冷，m 正 = 品红）而不是 1/gamma 之类的经验方向。
        let gainR = pow(2.0, -0.0103 * y - 0.0063 * m)
        let gainG = pow(2.0, -0.0016 * y + 0.0084 * m)
        let gainB = pow(2.0, 0.0150 * y - 0.0023 * m)

        var output = image
        let width = image.width
        let height = image.height
        let source = image.data
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            func row(_ y0: Int) {
                let start = y0 * width * 3
                for p in stride(from: start, to: start + width * 3, by: 3) {
                    var red = Double(source[p]) * gainR
                    var green = Double(source[p + 1]) * gainG
                    var blue = Double(source[p + 2]) * gainB
                    if abs(saturation - 1) > 1e-6 {
                        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                        red = luma + (red - luma) * saturation
                        green = luma + (green - luma) * saturation
                        blue = luma + (blue - luma) * saturation
                    }
                    base[p] = Float(red)
                    base[p + 1] = Float(green)
                    base[p + 2] = Float(blue)
                }
            }
            Interpolation.parallelRows(height: height, pixels: width * height, row)
        }
        return output
    }

    // MARK: - 显示域：反差、清晰度、颗粒

    static func applyDisplay(_ image: ImageRGB, params: Params) -> ImageRGB {
        var output = image
        if abs(params.gamma - 1) > 1e-6 {
            output = applyContrast(output, gamma: params.gamma)
        }
        if abs(params.clarity) > 1e-6 {
            output = applyClarity(output, amount: params.clarity)
        }
        return output
    }

    /// 反差的近似：物理侧 gammaFactor > 1 会压缩密度曲线的 logE 轴 → 反差更高，
    /// 所以近似倍率与 gamma 同向（不是 1/gamma）。
    private static func applyContrast(_ image: ImageRGB, gamma: Double) -> ImageRGB {
        // 物理 gamma 压缩密度曲线的 logE 轴，落到显示对比度的幅度约为 √gamma
        // （实测 gamma 1.21 → Δsd +11%，线性映射会高估到 +21%），故取平方根。
        let strength = min(max(sqrt(max(gamma, 1e-6)), 0.5), 2.0)
        let pivot = 0.46
        var output = image
        let width = image.width
        let height = image.height
        let source = image.data
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            func row(_ y0: Int) {
                let start = y0 * width * 3
                for p in start..<(start + width * 3) {
                    let value = Double(source[p])
                    base[p] = Float(min(max(pivot + (value - pivot) * strength, 0), 1))
                }
            }
            Interpolation.parallelRows(height: height, pixels: width * height, row)
        }
        return output
    }

    /// 清晰度：3×3 盒式模糊的 unsharp，只做一次可分离卷积，代价足够低。
    private static func applyClarity(_ image: ImageRGB, amount: Double) -> ImageRGB {
        let blurred = boxBlur3(image)
        let strength = amount * 0.9
        var output = image
        let count = output.data.count
        let source = image.data
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            blurred.data.withUnsafeBufferPointer { soft in
                guard let b = soft.baseAddress else { return }
                for i in 0..<count {
                    let value = Double(source[i])
                    let soft = Double(b[i])
                    base[i] = Float(min(max(value + strength * (value - soft), 0), 1))
                }
            }
        }
        return output
    }

    private static func boxBlur3(_ image: ImageRGB) -> ImageRGB {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return image }
        let source = image.data
        var horizontal = [Double](repeating: 0, count: source.count)
        var output = image

        horizontal.withUnsafeMutableBufferPointer { h in
            guard let hb = h.baseAddress else { return }
            func row(_ y: Int) {
                let start = y * width * 3
                for x in 0..<width {
                    let p = start + x * 3
                    let left = x > 0 ? p - 3 : p
                    let right = x < width - 1 ? p + 3 : p
                    for c in 0..<3 {
                        hb[p + c] = (Double(source[left + c]) + Double(source[p + c])
                            + Double(source[right + c])) / 3
                    }
                }
            }
            Interpolation.parallelRows(height: height, pixels: width * height, row)
        }

        output.data.withUnsafeMutableBufferPointer { out in
            guard let ob = out.baseAddress else { return }
            func row(_ y: Int) {
                let start = y * width * 3
                let up = y > 0 ? start - width * 3 : start
                let down = y < height - 1 ? start + width * 3 : start
                for p in start..<(start + width * 3) {
                    ob[p] = Float((horizontal[up + (p - start)] + horizontal[p]
                        + horizontal[down + (p - start)]) / 3)
                }
            }
            Interpolation.parallelRows(height: height, pixels: width * height, row)
        }
        return output
    }

    // 颗粒不再由近似层补：哈希噪声既不像胶片颗粒，也无法和导出对齐。
    // 预测帧不显示颗粒（与原生 preview_mode 一致），停手后的精算帧跑物理颗粒。
}
