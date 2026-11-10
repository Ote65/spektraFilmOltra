import Foundation
import Dispatch

enum ClarityMath {
    static let epsilon = 0.0001
    static let logMin = -14.0
    static let logMax = 1.5

    // MARK: - 基础

    @inline(__always)
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    @inline(__always)
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        if edge1 <= edge0 { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always)
    static func parallelFor(rows: Int, _ body: (Int) -> Void) {
        if rows >= 64 {
            DispatchQueue.concurrentPerform(iterations: rows, execute: body)
        } else {
            for row in 0..<rows { body(row) }
        }
    }

    @inline(__always)
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    @inline(__always)
    static func srgbToLinear(_ value: Double) -> Double {
        if value <= 0 { return 0 }
        if value <= 0.04045 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linearToSRGB(_ value: Double) -> Double {
        if value <= 0 { return 0 }
        if value <= 0.0031308 { return value * 12.92 }
        return 1.055 * pow(value, 1.0 / 2.4) - 0.055
    }

    @inline(__always)
    static func logY(_ y: Double) -> Double {
        log2(max(y, 0) + epsilon)
    }

    @inline(__always)
    static func expLog(_ value: Double) -> Double {
        max(pow(2.0, value) - epsilon, 0)
    }

    // MARK: - 图像转换

    static func srgbToLinearImage(_ image: ImageRGB) -> ImageRGB {
        var output = image
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: image.height) { y in
                let start = y * image.width * 3
                for i in start..<(start + image.width * 3) {
                    base[i] = Float(srgbToLinear(Double(image.data[i])))
                }
            }
        }
        return output
    }

    static func linearToSRGBImage(_ image: ImageRGB, clampToUnit: Bool = true) -> ImageRGB {
        var output = image
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: image.height) { y in
                let start = y * image.width * 3
                for i in start..<(start + image.width * 3) {
                    let value = linearToSRGB(Double(image.data[i]))
                    base[i] = Float(clampToUnit ? clamp(value, 0, 1) : value)
                }
            }
        }
        return output
    }

    static func luminancePlane(_ image: ImageRGB) -> [Double] {
        let count = image.width * image.height
        var output = [Double](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: image.height) { y in
                for x in 0..<image.width {
                    let i = y * image.width + x
                    base[i] = luminance(
                        Double(image.data[i * 3]), Double(image.data[i * 3 + 1]),
                        Double(image.data[i * 3 + 2])
                    )
                }
            }
        }
        return output
    }

    static func downsampledToLongEdge(_ image: ImageRGB, maxEdge: Int) -> ImageRGB {
        let longEdge = max(image.width, image.height)
        guard maxEdge > 0, longEdge > maxEdge else { return image }
        let scale = Double(maxEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard width != image.width || height != image.height else { return image }

        var output = ImageRGB(width: width, height: height)
        let stepX = Double(image.width) / Double(width)
        let stepY = Double(image.height) / Double(height)
        for y in 0..<height {
            let y0 = Int(floor(Double(y) * stepY))
            let y1 = min(image.height, max(y0 + 1, Int(floor(Double(y + 1) * stepY))))
            for x in 0..<width {
                let x0 = Int(floor(Double(x) * stepX))
                let x1 = min(image.width, max(x0 + 1, Int(floor(Double(x + 1) * stepX))))
                var r = 0.0, g = 0.0, b = 0.0
                var count = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let index = (yy * image.width + xx) * 3
                        r += Double(image.data[index])
                        g += Double(image.data[index + 1])
                        b += Double(image.data[index + 2])
                        count += 1
                    }
                }
                let inv = 1.0 / Double(max(count, 1))
                let index = (y * width + x) * 3
                output.data[index] = Float(r * inv)
                output.data[index + 1] = Float(g * inv)
                output.data[index + 2] = Float(b * inv)
            }
        }
        return output
    }

    // MARK: - OKLab

    static func oklab(fromLinear rgb: Vec3) -> Vec3 {
        let l = 0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z
        let m = 0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z
        let s = 0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z
        let lp = cbrt(l)
        let mp = cbrt(m)
        let sp = cbrt(s)
        return Vec3(
            0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
            1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
            0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp
        )
    }

    static func linear(fromOklab lab: Vec3) -> Vec3 {
        let lp = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let mp = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let sp = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = lp * lp * lp
        let m = mp * mp * mp
        let s = sp * sp * sp
        return Vec3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    static func oklabPlanes(_ image: ImageRGB) -> (l: [Double], a: [Double], b: [Double]) {
        let count = image.width * image.height
        var l = [Double](repeating: 0, count: count)
        var a = [Double](repeating: 0, count: count)
        var b = [Double](repeating: 0, count: count)
        l.withUnsafeMutableBufferPointer { lb in
            a.withUnsafeMutableBufferPointer { ab in
                b.withUnsafeMutableBufferPointer { bb in
                    guard let lp = lb.baseAddress, let ap = ab.baseAddress, let bp = bb.baseAddress else { return }
                    parallelFor(rows: image.height) { y in
                        for x in 0..<image.width {
                            let i = y * image.width + x
                            let lab = oklab(fromLinear: Vec3(
                                Double(image.data[i * 3]), Double(image.data[i * 3 + 1]),
                                Double(image.data[i * 3 + 2])
                            ))
                            lp[i] = lab.x
                            ap[i] = lab.y
                            bp[i] = lab.z
                        }
                    }
                }
            }
        }
        return (l, a, b)
    }

    // MARK: - 直方图

    struct Histogram {
        let bins: Int
        let minLog: Double
        let maxLog: Double
        var counts: [Int]
        var total: Int

        init(values: [Double], bins: Int = 1024, minLog: Double = -14, maxLog: Double = 1.5) {
            self.bins = bins
            self.minLog = minLog
            self.maxLog = maxLog
            self.counts = [Int](repeating: 0, count: bins)
            self.total = 0
            for value in values {
                add(value)
            }
        }

        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            let normalized = (value - minLog) / (maxLog - minLog)
            let index = Int(floor(normalized * Double(bins)))
            counts[min(max(index, 0), bins - 1)] += 1
            total += 1
        }

        func percentile(_ percent: Double) -> Double {
            guard total > 0 else { return 0 }
            let target = clamp(percent, 0, 100) / 100.0 * Double(total)
            var cumulative = 0
            for index in 0..<bins {
                let next = cumulative + counts[index]
                if Double(next) >= target {
                    let fraction = counts[index] > 0
                        ? (target - Double(cumulative)) / Double(counts[index])
                        : 0
                    return minLog + (Double(index) + fraction) / Double(bins) * (maxLog - minLog)
                }
                cumulative = next
            }
            return maxLog
        }

        func fractionBelow(_ logValue: Double) -> Double {
            guard total > 0 else { return 0 }
            let normalized = (logValue - minLog) / (maxLog - minLog)
            let index = min(max(Int(floor(normalized * Double(bins))), 0), bins - 1)
            var cumulative = 0
            for i in 0..<index { cumulative += counts[i] }
            return Double(cumulative) / Double(total)
        }

        func fractionAbove(_ logValue: Double) -> Double {
            1 - fractionBelow(logValue)
        }
    }

    static func percentile(_ values: [Double], _ percent: Double, maxSamples: Int = 100_000) -> Double {
        guard !values.isEmpty else { return 0 }
        let step = max(1, values.count / maxSamples)
        var sample: [Double] = []
        sample.reserveCapacity(values.count / step + 1)
        var index = 0
        while index < values.count {
            sample.append(values[index])
            index += step
        }
        sample.sort()
        let position = clamp(percent, 0, 100) / 100.0 * Double(sample.count - 1)
        let low = Int(floor(position))
        let high = min(low + 1, sample.count - 1)
        let fraction = position - Double(low)
        return sample[low] * (1 - fraction) + sample[high] * fraction
    }

    static func median(_ values: [Double]) -> Double {
        percentile(values, 50)
    }

    // MARK: - 平面缩放

    static func resizePlane(_ input: [Double], width: Int, height: Int,
                            newWidth: Int, newHeight: Int) -> [Double] {
        guard width > 0, height > 0, newWidth > 0, newHeight > 0 else { return [] }
        guard width != newWidth || height != newHeight else { return input }
        var output = [Double](repeating: 0, count: newWidth * newHeight)
        let stepX = Double(width) / Double(newWidth)
        let stepY = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            let sy = (Double(y) + 0.5) * stepY - 0.5
            let y0 = Int(floor(sy))
            let fy = sy - Double(y0)
            let ya = min(max(y0, 0), height - 1)
            let yb = min(max(y0 + 1, 0), height - 1)
            for x in 0..<newWidth {
                let sx = (Double(x) + 0.5) * stepX - 0.5
                let x0 = Int(floor(sx))
                let fx = sx - Double(x0)
                let xa = min(max(x0, 0), width - 1)
                let xb = min(max(x0 + 1, 0), width - 1)
                let top = input[ya * width + xa] * (1 - fx) + input[ya * width + xb] * fx
                let bottom = input[yb * width + xa] * (1 - fx) + input[yb * width + xb] * fx
                output[y * newWidth + x] = top * (1 - fy) + bottom * fy
            }
        }
        return output
    }

    static func downsamplePlaneBy2(_ input: [Double], width: Int, height: Int) -> (data: [Double], width: Int, height: Int) {
        let newWidth = max(1, width / 2)
        let newHeight = max(1, height / 2)
        var output = [Double](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let x0 = min(width - 1, x * 2)
                let x1 = min(width - 1, x * 2 + 1)
                let y0 = min(height - 1, y * 2)
                let y1 = min(height - 1, y * 2 + 1)
                output[y * newWidth + x] = (
                    input[y0 * width + x0] + input[y0 * width + x1]
                    + input[y1 * width + x0] + input[y1 * width + x1]
                ) * 0.25
            }
        }
        return (output, newWidth, newHeight)
    }

    // MARK: - 滤波

    static func boxBlur(_ input: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        guard radius > 0, width > 0, height > 0 else { return input }
        var horizontal = [Double](repeating: 0, count: input.count)
        horizontal.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: height) { y in
                let row = y * width
                var prefix = [Double](repeating: 0, count: width + 1)
                for x in 0..<width { prefix[x + 1] = prefix[x] + input[row + x] }
                for x in 0..<width {
                    let low = max(0, x - radius)
                    let high = min(width - 1, x + radius)
                    base[row + x] = (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
                }
            }
        }
        var output = [Double](repeating: 0, count: input.count)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: width) { x in
                var prefix = [Double](repeating: 0, count: height + 1)
                for y in 0..<height { prefix[y + 1] = prefix[y] + horizontal[y * width + x] }
                for y in 0..<height {
                    let low = max(0, y - radius)
                    let high = min(height - 1, y + radius)
                    base[y * width + x] = (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
                }
            }
        }
        return output
    }

    static func minFilter(_ input: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        guard radius > 0 else { return input }
        var horizontal = [Double](repeating: 0, count: input.count)
        horizontal.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: height) { y in
                for x in 0..<width {
                    var value = Double.greatestFiniteMagnitude
                    for k in max(0, x - radius)...min(width - 1, x + radius) {
                        value = min(value, input[y * width + k])
                    }
                    base[y * width + x] = value
                }
            }
        }
        var output = [Double](repeating: 0, count: input.count)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: width) { x in
                for y in 0..<height {
                    var value = Double.greatestFiniteMagnitude
                    for k in max(0, y - radius)...min(height - 1, y + radius) {
                        value = min(value, horizontal[k * width + x])
                    }
                    base[y * width + x] = value
                }
            }
        }
        return output
    }

    static func maxFilter(_ input: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        guard radius > 0 else { return input }
        var horizontal = [Double](repeating: 0, count: input.count)
        horizontal.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: height) { y in
                for x in 0..<width {
                    var value = -Double.greatestFiniteMagnitude
                    for k in max(0, x - radius)...min(width - 1, x + radius) {
                        value = max(value, input[y * width + k])
                    }
                    base[y * width + x] = value
                }
            }
        }
        var output = [Double](repeating: 0, count: input.count)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            parallelFor(rows: width) { x in
                for y in 0..<height {
                    var value = -Double.greatestFiniteMagnitude
                    for k in max(0, y - radius)...min(height - 1, y + radius) {
                        value = max(value, horizontal[k * width + x])
                    }
                    base[y * width + x] = value
                }
            }
        }
        return output
    }

    static func guidedFilter(guide: [Double], source: [Double],
                             width: Int, height: Int, radius: Int, epsilon: Double) -> [Double] {
        let count = width * height
        let meanGuide = boxBlur(guide, width: width, height: height, radius: radius)
        let meanSource = boxBlur(source, width: width, height: height, radius: radius)
        var guideSquared = [Double](repeating: 0, count: count)
        var guideSource = [Double](repeating: 0, count: count)
        for i in 0..<count {
            guideSquared[i] = guide[i] * guide[i]
            guideSource[i] = guide[i] * source[i]
        }
        let meanGuideSquared = boxBlur(guideSquared, width: width, height: height, radius: radius)
        let meanGuideSource = boxBlur(guideSource, width: width, height: height, radius: radius)

        var a = [Double](repeating: 0, count: count)
        var b = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let variance = max(meanGuideSquared[i] - meanGuide[i] * meanGuide[i], 0)
            let covariance = meanGuideSource[i] - meanGuide[i] * meanSource[i]
            a[i] = covariance / (variance + epsilon)
            b[i] = meanSource[i] - a[i] * meanGuide[i]
        }
        let meanA = boxBlur(a, width: width, height: height, radius: radius)
        let meanB = boxBlur(b, width: width, height: height, radius: radius)
        var output = [Double](repeating: 0, count: count)
        for i in 0..<count {
            output[i] = meanA[i] * guide[i] + meanB[i]
        }
        return output
    }

    static func gradientMagnitude(_ input: [Double], width: Int, height: Int) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        for y in 0..<height {
            let y0 = max(0, y - 1)
            let y1 = min(height - 1, y + 1)
            for x in 0..<width {
                let x0 = max(0, x - 1)
                let x1 = min(width - 1, x + 1)
                let dx = (input[y * width + x1] - input[y * width + x0]) * 0.5
                let dy = (input[y1 * width + x] - input[y0 * width + x]) * 0.5
                output[y * width + x] = sqrt(dx * dx + dy * dy)
            }
        }
        return output
    }

    // MARK: - 单调曲线

    struct ToneLUT {
        let values: [Double]
        let minX: Double
        let maxX: Double

        func sample(_ x: Double) -> Double {
            guard values.count > 1 else { return x }
            if x <= minX { return values[0] }
            if x >= maxX { return values[values.count - 1] }
            let normalized = (x - minX) / (maxX - minX) * Double(values.count - 1)
            let low = Int(floor(normalized))
            let high = min(low + 1, values.count - 1)
            let fraction = normalized - Double(low)
            return values[low] * (1 - fraction) + values[high] * fraction
        }
    }

    static func monotoneCubicLUT(x: [Double], y: [Double],
                                 minX: Double, maxX: Double,
                                 count: Int = 1024) -> ToneLUT {
        precondition(x.count == y.count && x.count >= 2)
        var anchorsX = x
        var anchorsY = y
        for i in 1..<anchorsX.count {
            if anchorsX[i] <= anchorsX[i - 1] { anchorsX[i] = anchorsX[i - 1] + 1e-6 }
            if anchorsY[i] < anchorsY[i - 1] { anchorsY[i] = anchorsY[i - 1] }
        }
        let segments = anchorsX.count - 1
        var slopes = [Double](repeating: 0, count: segments)
        for i in 0..<segments {
            slopes[i] = (anchorsY[i + 1] - anchorsY[i]) / (anchorsX[i + 1] - anchorsX[i])
        }
        var tangents = [Double](repeating: 0, count: anchorsX.count)
        tangents[0] = slopes[0]
        tangents[segments] = slopes[segments - 1]
        if segments > 1 {
            for i in 1..<segments {
                tangents[i] = (slopes[i - 1] + slopes[i]) * 0.5
            }
        }
        for i in 0..<segments {
            if abs(slopes[i]) < 1e-12 {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let alpha = tangents[i] / slopes[i]
            let beta = tangents[i + 1] / slopes[i]
            if alpha * alpha + beta * beta > 9 {
                let tau = 3 / sqrt(alpha * alpha + beta * beta)
                tangents[i] = tau * alpha * slopes[i]
                tangents[i + 1] = tau * beta * slopes[i]
            }
        }

        var values = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / Double(max(count - 1, 1))
            let sampleX = minX + t * (maxX - minX)
            var segment = segments - 1
            for i in 0..<segments {
                if sampleX <= anchorsX[i + 1] {
                    segment = i
                    break
                }
            }
            let x0 = anchorsX[segment]
            let x1 = anchorsX[segment + 1]
            let h = max(x1 - x0, 1e-9)
            let u = clamp((sampleX - x0) / h, 0, 1)
            let u2 = u * u
            let u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1
            let h10 = u3 - 2 * u2 + u
            let h01 = -2 * u3 + 3 * u2
            let h11 = u3 - u2
            values[index] = h00 * anchorsY[segment]
                + h10 * h * tangents[segment]
                + h01 * anchorsY[segment + 1]
                + h11 * h * tangents[segment + 1]
        }
        return ToneLUT(values: values, minX: minX, maxX: maxX)
    }

    // MARK: - 金字塔

    struct Plane {
        var data: [Double]
        var width: Int
        var height: Int
    }

    struct LaplacianPyramid {
        var bands: [Plane]
        var residual: Plane
    }

    static func buildLaplacianPyramid(logY: [Double], width: Int, height: Int,
                                      sigmas: [Double]) -> LaplacianPyramid {
        var gaussians: [Plane] = [Plane(data: logY, width: width, height: height)]
        for sigma in sigmas {
            let current = gaussians[gaussians.count - 1]
            let blurred = FastGaussian.filterChannel(
                current.data, width: current.width, height: current.height, sigma: sigma
            )
            let down = downsamplePlaneBy2(blurred, width: current.width, height: current.height)
            gaussians.append(Plane(data: down.data, width: down.width, height: down.height))
        }

        var bands: [Plane] = []
        for index in 0..<(gaussians.count - 1) {
            let fine = gaussians[index]
            let coarse = gaussians[index + 1]
            let upsampled = resizePlane(
                coarse.data, width: coarse.width, height: coarse.height,
                newWidth: fine.width, newHeight: fine.height
            )
            var band = [Double](repeating: 0, count: fine.data.count)
            for i in 0..<band.count { band[i] = fine.data[i] - upsampled[i] }
            bands.append(Plane(data: band, width: fine.width, height: fine.height))
        }
        let residual = gaussians[gaussians.count - 1]
        return LaplacianPyramid(bands: bands, residual: residual)
    }

    static func localContrastScores(_ pyramid: LaplacianPyramid,
                                    sigmas: [Double]) -> [Plane] {
        var outputs: [Plane] = []
        for index in 0..<pyramid.bands.count {
            let band = pyramid.bands[index]
            let sigma = sigmas[min(index, sigmas.count - 1)]
            var squared = [Double](repeating: 0, count: band.data.count)
            for i in 0..<squared.count { squared[i] = band.data[i] * band.data[i] }
            let smoothed = FastGaussian.filterChannel(
                squared, width: band.width, height: band.height, sigma: sigma
            )
            var contrast = [Double](repeating: 0, count: smoothed.count)
            for i in 0..<contrast.count { contrast[i] = sqrt(max(smoothed[i], 0)) }
            let reference = percentile(contrast, 60)
            var score = [Double](repeating: 0, count: contrast.count)
            for i in 0..<score.count {
                score[i] = clamp((reference - contrast[i]) / max(reference, 1e-9), 0, 1)
            }
            outputs.append(Plane(data: score, width: band.width, height: band.height))
        }
        return outputs
    }
}
