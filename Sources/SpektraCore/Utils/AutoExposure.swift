import Foundation

enum AutoExposure {
    static func measureEV(image: ImageRGB, colorSpace: String, applyCCTFDecoding: Bool,
                          method: String) -> Double {
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

    private static func cubicWeights(_ t: Double) -> [Double] {
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

