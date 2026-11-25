import Foundation

/// 场景线性代理图的高光—主体—阴影联合分析。
///
/// 这里只决定曝光落位，不重写胶片曲线，也不把每张图的显示中值拉到同一个位置。
/// 取景流与 RAW 精算共用同一组决策规则；取景流只能提供预览高光估计，
/// 不能据此宣称 RAW 通道已经饱和。
struct SceneExposureAnalysis {
    var subjectLuminance: Double
    var medianLuminance: Double
    var highlightLuminance: Double
    var shadowLuminance: Double
    var channelClippingFraction: Double

    static let empty = SceneExposureAnalysis(
        subjectLuminance: 0.184, medianLuminance: 0.184,
        highlightLuminance: 0.184, shadowLuminance: 0.184,
        channelClippingFraction: 0)

    private static let epsilon = 1e-6
    /// 场景白场之上再保留约 2 EV 的高光落点；实际软肩仍由原胶片 / 相纸曲线决定。
    private static let highlightTarget = 4.0
    /// 自动模式最多额外下压 1.5 EV，避免点光源把整张夜景拉得过暗。
    private static let maximumHighlightProtection = 1.5
    /// 保守的 p05 阴影落位下限；它只限制继续减光，不会把低调照片自动提亮。
    private static let shadowTarget = 0.002

    var adaptiveEV: Double {
        let baseEV = log2(0.184 / max(subjectLuminance, Self.epsilon))
        let range = highlightLuminance / max(medianLuminance, Self.epsilon)
        // 低光与低调照片不机械套高光保护；中灰仍按主体意图落位。
        guard medianLuminance >= 0.004, highlightLuminance > Self.highlightTarget,
              range >= 8 else { return baseEV }
        let highlightEV = log2(Self.highlightTarget / max(highlightLuminance, Self.epsilon))
        let protected = max(highlightEV, baseEV - Self.maximumHighlightProtection)
        let shadowEV = log2(Self.shadowTarget / max(shadowLuminance, Self.epsilon))
        // 高光保护与阴影约束都只允许减光，不能越过主体曝光向上提亮。
        return min(baseEV, max(protected, min(baseEV, shadowEV)))
    }

    /// 取景 SDR 代理图的自动高光保护建议。只在明显高反差且接近显示白的区域
    /// 占有一定比例时介入；返回 0…−0.7 EV，由 AVFoundation 自行分配快门与 ISO。
    static func captureProtectionEV(_ analysis: SceneExposureAnalysis) -> Double {
        let range = analysis.highlightLuminance / max(analysis.medianLuminance, epsilon)
        guard analysis.medianLuminance >= 0.015,
              analysis.highlightLuminance >= 0.70,
              analysis.channelClippingFraction >= 0.002,
              range >= 6 else { return 0 }
        let correction = log2(0.72 / max(analysis.highlightLuminance, epsilon))
        return min(0, max(-0.7, correction))
    }

    static func analyze(image: ImageRGB, colorSpace: String,
                        applyCCTFDecoding: Bool) -> SceneExposureAnalysis {
        let count = image.width * image.height
        guard count > 0 else { return .empty }
        var luminance = [Double](repeating: 0, count: count)
        var clipped = 0
        for p in 0..<count {
            let r = Double(image.data[p * 3])
            let g = Double(image.data[p * 3 + 1])
            let b = Double(image.data[p * 3 + 2])
            if max(r, max(g, b)) >= 0.995 { clipped += 1 }
            let rgb = Vec3(r, g, b)
            let xyz = ColorMath.rgbToXYZ(
                rgb, spaceName: colorSpace, applyCCTFDecoding: applyCCTFDecoding)
            luminance[p] = max(xyz.y, epsilon)
        }
        let sorted = luminance.sorted()
        func quantile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0.184 }
            let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
            let low = Int(floor(position))
            let high = min(low + 1, sorted.count - 1)
            let mix = position - Double(low)
            return sorted[low] * (1 - mix) + sorted[high] * mix
        }
        let lowTrim = quantile(0.01)
        let highTrim = quantile(0.98)
        let normH = Double(image.height) / Double(max(image.width, image.height))
        let normW = Double(image.width) / Double(max(image.width, image.height))
        let sigma = 0.35
        var weightedLog = 0.0
        var totalWeight = 0.0
        for row in 0..<image.height {
            let y = (Double(row) / Double(max(image.height - 1, 1)) - 0.5) * normH
            for col in 0..<image.width {
                let value = luminance[row * image.width + col]
                guard value >= lowTrim, value <= highTrim else { continue }
                let x = (Double(col) / Double(max(image.width - 1, 1)) - 0.5) * normW
                let weight = exp(-(x * x + y * y) / (2 * sigma * sigma))
                weightedLog += log(max(value, epsilon)) * weight
                totalWeight += weight
            }
        }
        let subject = totalWeight > 1e-12
            ? exp(weightedLog / totalWeight)
            : quantile(0.5)
        let clippingFraction = Double(clipped) / Double(count)
        // p99 会漏掉面积不足 1% 的灯源、窗框。小面积亮部取区域内部的中位
        // 分位，避免恰好落在明暗交界；达到 1% 后继续使用原 p99 高光口径。
        let highlightFraction = clippingFraction > 0
            ? min(0.01, clippingFraction * 0.5)
            : 0.01
        return SceneExposureAnalysis(
            subjectLuminance: subject,
            medianLuminance: quantile(0.5),
            highlightLuminance: quantile(1 - highlightFraction),
            shadowLuminance: quantile(0.05),
            channelClippingFraction: clippingFraction)
    }
}

/// 取景曝光保护的连续平滑值与已应用量化值分开保存。
/// 否则从 −0.1 EV 回到 0 时，量化会反复得到 −0.1，保护永远无法退出。
struct CaptureExposureProtectionState {
    private(set) var smoothedEV = 0.0
    private(set) var appliedEV = 0.0

    mutating func reset() {
        smoothedEV = 0
        appliedEV = 0
    }

    mutating func proposedEV(target: Double) -> Double {
        let bounded = min(max(target, -0.7), 0)
        smoothedEV = smoothedEV * 0.65 + bounded * 0.35
        return (smoothedEV * 10).rounded() / 10
    }

    mutating func markApplied(_ value: Double) {
        appliedEV = value
    }
}

enum AutoExposure {
    static func measureEV(image: ImageRGB, colorSpace: String, applyCCTFDecoding: Bool,
                          method: String) -> Double {
        if method == "adaptive" {
            return SceneExposureAnalysis.analyze(
                image: image, colorSpace: colorSpace,
                applyCCTFDecoding: applyCCTFDecoding).adaptiveEV
        }
        var luminance = [Double](repeating: 0, count: image.width * image.height)
        for p in 0..<(image.width * image.height) {
            let rgb = Vec3(Double(image.data[p * 3]), Double(image.data[p * 3 + 1]),
                           Double(image.data[p * 3 + 2]))
            let xyz = ColorMath.rgbToXYZ(rgb, spaceName: colorSpace, applyCCTFDecoding: applyCCTFDecoding)
            luminance[p] = xyz.y
        }
        var exposure = 1.0
        switch method {
        case "average":
            exposure = luminance.reduce(0, +) / Double(luminance.count) / 0.184
        case "median":
            let sorted = luminance.sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            exposure = median / 0.184
        case "center_weighted":
            let (x, y) = normalizedCoordinates(image)
            var weighted = 0.0
            var total = 0.0
            let sigma = 0.2
            for row in 0..<image.height {
                for col in 0..<image.width {
                    let mask = exp(-(x[col] * x[col] + y[row] * y[row]) / (2 * sigma * sigma))
                    weighted += luminance[row * image.width + col] * mask
                    total += mask
                }
            }
            exposure = (weighted / max(total, 1e-20)) / 0.184
        case "partial":
            let (x, y) = normalizedCoordinates(image)
            var values: [Double] = []
            for row in 0..<image.height {
                for col in 0..<image.width {
                    let radius = sqrt(x[col] * x[col] + y[row] * y[row])
                    if radius < 0.15 { values.append(luminance[row * image.width + col]) }
                }
            }
            if values.isEmpty { values = luminance }
            exposure = values.reduce(0, +) / Double(values.count) / 0.184
        case "matrix":
            let rows = 5
            let cols = 5
            let cellH = image.height / rows
            let cellW = image.width / cols
            var means: [Double] = []
            var weights: [Double] = []
            for r in 0..<rows {
                for c in 0..<cols {
                    var sum = 0.0
                    var count = 0
                    for yy in (r * cellH)..<min((r + 1) * cellH, image.height) {
                        for xx in (c * cellW)..<min((c + 1) * cellW, image.width) {
                            sum += luminance[yy * image.width + xx]
                            count += 1
                        }
                    }
                    if count == 0 { continue }
                    means.append(sum / Double(count))
                    let dy = (Double(r) - Double(rows - 1) / 2) / (Double(rows - 1) / 2)
                    let dx = (Double(c) - Double(cols - 1) / 2) / (Double(cols - 1) / 2)
                    let distance = sqrt(dx * dx + dy * dy) / sqrt(2)
                    weights.append(0.5 * (1 + cos(.pi * distance)))
                }
            }
            let weightSum = max(weights.reduce(0, +), 1e-20)
            exposure = zip(weights, means).reduce(0) { $0 + $1.0 * $1.1 } / weightSum / 0.184
        case "multi_zone":
            let (x, y) = normalizedCoordinates(image)
            let rings: [(Double, Double, Double)] = [(0, 0.05, 0.5), (0.05, 0.25, 0.3), (0.25, 0.5, 0.2)]
            var weighted = 0.0
            var total = 0.0
            for (low, high, weight) in rings {
                var values: [Double] = []
                for row in 0..<image.height {
                    for col in 0..<image.width {
                        let radius = sqrt(x[col] * x[col] + y[row] * y[row])
                        if radius >= low && radius < high { values.append(luminance[row * image.width + col]) }
                    }
                }
                if values.isEmpty { continue }
                weighted += weight * (values.reduce(0, +) / Double(values.count))
                total += weight
            }
            exposure = (total > 0 ? weighted / total : luminance.reduce(0, +) / Double(luminance.count)) / 0.184
        case "highlight_weighted":
            var weighted = 0.0
            var total = 0.0
            for value in luminance {
                let weight = value * value
                weighted += value * weight
                total += weight
            }
            if total < 1e-12 {
                exposure = luminance.reduce(0, +) / Double(luminance.count) / 0.184
            } else {
                exposure = weighted / total / 0.184
            }
        default:
            exposure = 1
        }
        let ev = -log2(exposure)
        return ev.isFinite ? ev : 0
    }

    private static func normalizedCoordinates(_ image: ImageRGB) -> ([Double], [Double]) {
        let normH = Double(image.height) / Double(max(image.width, image.height))
        let normW = Double(image.width) / Double(max(image.width, image.height))
        let x = (0..<image.width).map { (Double($0) / Double(image.width) - 0.5) * normW }
        let y = (0..<image.height).map { (Double($0) / Double(image.height) - 0.5) * normH }
        return (x, y)
    }
}

enum Resize {
    /// 对齐 skimage `rescale(..., order=0)`：输出尺寸 `round(scale*dim)`，
    /// 采样坐标 `(i+0.5)*(in/out)-0.5`，最近邻 + 镜像边界。
    static func smallPreview(_ image: ImageRGB, maxSize: Int = 256) -> ImageRGB {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxSize else { return image }
        let scale = Double(maxSize) / Double(longEdge)
        let width = max(Int((Double(image.width) * scale).rounded(.toNearestOrEven)), 1)
        let height = max(Int((Double(image.height) * scale).rounded(.toNearestOrEven)), 1)
        guard width != image.width || height != image.height else { return image }
        var output = ImageRGB(width: width, height: height)
        let stepX = Double(image.width) / Double(width)
        let stepY = Double(image.height) / Double(height)
        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) * stepY - 0.5
            let indexY = FastGaussian.reflect(Int(floor(sourceY + 0.5)), image.height)
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) * stepX - 0.5
                let indexX = FastGaussian.reflect(Int(floor(sourceX + 0.5)), image.width)
                output.setPixel(x, y, image.pixel(indexX, indexY))
            }
        }
        return output
    }

    /// 按长边上限做双线性降采样；用于导出「长边像素」。原图不超过上限时原样返回。
    static func longEdge(_ image: ImageRGB, maxSize: Int) -> ImageRGB {
        guard maxSize > 0 else { return image }
        let long = max(image.width, image.height)
        guard long > maxSize else { return image }
        let scale = Double(maxSize) / Double(long)
        let width = max(Int((Double(image.width) * scale).rounded(.toNearestOrEven)), 1)
        let height = max(Int((Double(image.height) * scale).rounded(.toNearestOrEven)), 1)
        guard width != image.width || height != image.height else { return image }
        var output = ImageRGB(width: width, height: height)
        let stepX = Double(image.width) / Double(width)
        let stepY = Double(image.height) / Double(height)
        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) * stepY - 0.5
            let baseY = Int(floor(sourceY))
            let fy = sourceY - Double(baseY)
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) * stepX - 0.5
                let baseX = Int(floor(sourceX))
                let fx = sourceX - Double(baseX)
                let x0 = FastGaussian.reflect(baseX, image.width)
                let x1 = FastGaussian.reflect(baseX + 1, image.width)
                let y0 = FastGaussian.reflect(baseY, image.height)
                let y1 = FastGaussian.reflect(baseY + 1, image.height)
                let top = image.pixel(x0, y0) * (1 - fx) + image.pixel(x1, y0) * fx
                let bottom = image.pixel(x0, y1) * (1 - fx) + image.pixel(x1, y1) * fx
                output.setPixel(x, y, top * (1 - fy) + bottom * fy)
            }
        }
        return output
    }

    /// 双三次（Catmull-Rom）放大。用于 `upscale_factor > 1`。
    /// Python 侧是 skimage `rescale(order=3)`（带 B 样条预滤波），两者视觉等价但非逐位一致。
    static func upscale(_ image: ImageRGB, factor: Double) -> ImageRGB {
        guard factor > 0, factor != 1 else { return image }
        let width = max(1, Int((Double(image.width) * factor).rounded(.toNearestOrEven)))
        let height = max(1, Int((Double(image.height) * factor).rounded(.toNearestOrEven)))
        var output = ImageRGB(width: width, height: height)
        let stepX = Double(image.width) / Double(width)
        let stepY = Double(image.height) / Double(height)
        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) * stepY - 0.5
            let baseY = Int(floor(sourceY))
            let fy = sourceY - Double(baseY)
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) * stepX - 0.5
                let baseX = Int(floor(sourceX))
                let fx = sourceX - Double(baseX)
                let weightsX = cubicWeights(fx)
                let weightsY = cubicWeights(fy)
                var value = Vec3(0, 0, 0)
                for j in 0..<4 {
                    let sy = FastGaussian.reflect(baseY - 1 + j, image.height)
                    for i in 0..<4 {
                        let sx = FastGaussian.reflect(baseX - 1 + i, image.width)
                        let weight = weightsX[i] * weightsY[j]
                        value = value + image.pixel(sx, sy) * weight
                    }
                }
                output.setPixel(x, y, value)
            }
        }
        return output
    }

    static func cubicWeights(_ t: Double) -> [Double] {
        let t2 = t * t
        let t3 = t2 * t
        return [
            (-t3 + 2 * t2 - t) / 2,
            (3 * t3 - 5 * t2 + 2) / 2,
            (-3 * t3 + 4 * t2 + t) / 2,
            (t3 - t2) / 2,
        ]
    }

    static func crop(_ image: ImageRGB, center: [Double], size: [Double]) -> ImageRGB {
        let shape = (Double(image.height), Double(image.width))
        let centerNormalized = (center[1], center[0])
        let sizeNormalized = (size[1], size[0])
        var cn = (round(shape.0 * centerNormalized.0), round(shape.1 * centerNormalized.1))
        var sz = (round(max(shape.0, shape.1) * sizeNormalized.0), round(max(shape.0, shape.1) * sizeNormalized.1))
        var x0 = (round(cn.0 - sz.0 / 2), round(cn.1 - sz.1 / 2))
        x0.0 = max(x0.0, 0)
        x0.1 = max(x0.1, 0)
        if x0.0 + sz.0 > shape.0 { x0.0 = shape.0 - sz.0 }
        if x0.1 + sz.1 > shape.1 { x0.1 = shape.1 - sz.1 }
        sz.0 = max(sz.0, 1)
        sz.1 = max(sz.1, 1)
        let width = Int(sz.1)
        let height = Int(sz.0)
        var output = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                output.setPixel(x, y, image.pixel(Int(x0.1) + x, Int(x0.0) + y))
            }
        }
        return output
    }
}

extension ImageRGB {
    /// 顺时针旋转 90° × turns（0–3）。只做像素重排，不重新采样。
    func rotatedClockwise(_ turns: Int) -> ImageRGB {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return self }
        let swapped = t % 2 == 1
        var output = ImageRGB(width: swapped ? height : width,
                              height: swapped ? width : height)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                switch t {
                case 1: output.setPixel(height - 1 - y, x, value)
                case 2: output.setPixel(width - 1 - x, height - 1 - y, value)
                default: output.setPixel(y, width - 1 - x, value)
                }
            }
        }
        return output
    }
}

