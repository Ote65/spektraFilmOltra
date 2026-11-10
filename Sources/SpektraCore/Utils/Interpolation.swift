import Foundation

enum Interpolation {
    static func interp1D(image: ImageRGB, xAxis: [Double], yValues: [[Double]]) -> ImageRGB {
        var output = image
        let count = xAxis.count
        guard count >= 2 else { return output }
        var invDX = [Double](repeating: 0, count: count - 1)
        for i in 0..<(count - 1) {
            let dx = xAxis[i + 1] - xAxis[i]
            invDX[i] = dx != 0 ? 1.0 / dx : 0
        }
        var flatY = [Double](repeating: 0, count: count * 3)
        for i in 0..<count {
            for c in 0..<3 { flatY[i * 3 + c] = yValues[i][c] }
        }

        let width = image.width
        let height = image.height
        let src = image.data
        output.data.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            xAxis.withUnsafeBufferPointer { axis in
                flatY.withUnsafeBufferPointer { y in
                    invDX.withUnsafeBufferPointer { inv in
                        func row(_ y0: Int) {
                            let start = y0 * width
                            // 行首用一次二分，其后按空间连续性爬坡，通常 0–2 步。
                            var low0 = segment(axis, count: count, value: Double(src[start * 3]))
                            var low1 = segment(axis, count: count, value: Double(src[start * 3 + 1]))
                            var low2 = segment(axis, count: count, value: Double(src[start * 3 + 2]))
                            for x in 0..<width {
                                let p = (start + x) * 3
                                for c in 0..<3 {
                                    let value = Double(src[p + c])
                                    if value <= axis[0] {
                                        base[p + c] = Float(y[c])
                                        continue
                                    }
                                    if value >= axis[count - 1] {
                                        base[p + c] = Float(y[(count - 1) * 3 + c])
                                        continue
                                    }
                                    switch c {
                                    case 0:
                                        advance(axis, count: count, stride: 1, channel: 0,
                                                value: value, low: &low0)
                                        base[p] = Float(lerp(axis, y, inv, low0, low0 * 3, low0, value))
                                    case 1:
                                        advance(axis, count: count, stride: 1, channel: 0,
                                                value: value, low: &low1)
                                        base[p + 1] = Float(lerp(axis, y, inv, low1, low1 * 3 + 1,
                                                                low1, value))
                                    default:
                                        advance(axis, count: count, stride: 1, channel: 0,
                                                value: value, low: &low2)
                                        base[p + 2] = Float(lerp(axis, y, inv, low2, low2 * 3 + 2,
                                                                low2, value))
                                    }
                                }
                            }
                        }
                        parallelRows(height: height, pixels: width * height, row)
                    }
                }
            }
        }
        return output
    }

    static func interp1D(image: ImageRGB, xAxisPerChannel: [[Double]], yValues: [[Double]]) -> ImageRGB {
        var output = image
        let count = xAxisPerChannel.count
        guard count >= 2 else { return output }
        var flatAxis = [Double](repeating: 0, count: count * 3)
        var flatY = [Double](repeating: 0, count: count * 3)
        var invDX = [Double](repeating: 0, count: (count - 1) * 3)
        for i in 0..<count {
            for c in 0..<3 {
                flatAxis[i * 3 + c] = xAxisPerChannel[i][c]
                flatY[i * 3 + c] = yValues[i][c]
            }
        }
        for i in 0..<(count - 1) {
            for c in 0..<3 {
                let dx = flatAxis[(i + 1) * 3 + c] - flatAxis[i * 3 + c]
                invDX[i * 3 + c] = dx != 0 ? 1.0 / dx : 0
            }
        }

        let width = image.width
        let height = image.height
        let src = image.data
        output.data.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            flatAxis.withUnsafeBufferPointer { axis in
                flatY.withUnsafeBufferPointer { y in
                    invDX.withUnsafeBufferPointer { inv in
                        func row(_ y0: Int) {
                            let start = y0 * width
                            var low0 = segmentChannel(axis, count: count, c: 0, value: Double(src[start * 3]))
                            var low1 = segmentChannel(axis, count: count, c: 1, value: Double(src[start * 3 + 1]))
                            var low2 = segmentChannel(axis, count: count, c: 2, value: Double(src[start * 3 + 2]))
                            for x in 0..<width {
                                let p = (start + x) * 3
                                for c in 0..<3 {
                                    let value = Double(src[p + c])
                                    if value <= axis[c] {
                                        base[p + c] = Float(y[c])
                                        continue
                                    }
                                    if value >= axis[(count - 1) * 3 + c] {
                                        base[p + c] = Float(y[(count - 1) * 3 + c])
                                        continue
                                    }
                                    switch c {
                                    case 0:
                                        advance(axis, count: count, stride: 3, channel: 0,
                                                value: value, low: &low0)
                                        base[p] = Float(lerp(axis, y, inv, low0 * 3, low0 * 3,
                                                            low0 * 3, value))
                                    case 1:
                                        advance(axis, count: count, stride: 3, channel: 1,
                                                value: value, low: &low1)
                                        base[p + 1] = Float(lerp(axis, y, inv, low1 * 3 + 1,
                                                                low1 * 3 + 1, low1 * 3 + 1, value))
                                    default:
                                        advance(axis, count: count, stride: 3, channel: 2,
                                                value: value, low: &low2)
                                        base[p + 2] = Float(lerp(axis, y, inv, low2 * 3 + 2,
                                                                low2 * 3 + 2, low2 * 3 + 2, value))
                                    }
                                }
                            }
                        }
                        parallelRows(height: height, pixels: width * height, row)
                    }
                }
            }
        }
        return output
    }

    @inline(__always)
    private static func lerp(_ axis: UnsafeBufferPointer<Double>,
                             _ y: UnsafeBufferPointer<Double>,
                             _ inv: UnsafeBufferPointer<Double>,
                             _ axisIndex: Int, _ yIndex: Int, _ invIndex: Int,
                             _ value: Double) -> Double {
        // 三个缓冲的布局各不相同：轴可能是单通道（stride 1）或逐通道（stride 3），
        // y 恒为 3 通道，inv 则是调用方决定的 (count-1) 或 (count-1)*3。
        let t = (value - axis[axisIndex]) * inv[invIndex]
        return y[yIndex] + t * (y[yIndex + 3] - y[yIndex])
    }


    /// 单调轴上从上一像素的分段出发爬坡：空间连续时通常 0–2 步，结果与二分完全一致。
    @inline(__always)
    private static func advance(_ axis: UnsafeBufferPointer<Double>, count: Int, stride: Int,
                                channel: Int, value: Double, low: inout Int) {
        while low + 1 < count && axis[(low + 1) * stride + channel] <= value { low += 1 }
        while low > 0 && axis[low * stride + channel] > value { low -= 1 }
    }

    /// 单调递增轴上的分段定位：返回满足 `axis[low] <= value < axis[low + 1]` 的 low。
    /// 原实现从 1 开始逐点扫描，512 点曲线 × 3 通道会让每个像素退化成 ~1500 次比较。
    @inline(__always)
    private static func segment(_ axis: UnsafeBufferPointer<Double>, count: Int,
                                value: Double) -> Int {
        var lo = 1
        var hi = count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if axis[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    @inline(__always)
    private static func segmentChannel(_ axis: UnsafeBufferPointer<Double>, count: Int,
                                       c: Int, value: Double) -> Int {
        var lo = 1
        var hi = count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if axis[mid * 3 + c] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// 像素数够多时按行并行；小图保持串行，避免线程调度开销。
    @inline(__always)
    static func parallelRows(height: Int, pixels: Int, _ body: (Int) -> Void) {
        if pixels >= 120_000 && height > 1 {
            DispatchQueue.concurrentPerform(iterations: height, execute: body)
        } else {
            for y in 0..<height { body(y) }
        }
    }

}

struct LUT3D {
    let size: Int
    let values: [Double] // size^3 * 3

    init(size: Int, values: [Double]) {
        self.size = size
        self.values = values
        precondition(values.count == size * size * size * 3)
    }

    subscript(x: Int, y: Int, z: Int, c: Int) -> Double {
        values[((x * size + y) * size + z) * 3 + c]
    }
}

struct PreparedPCHIP3D {
    let lut: LUT3D
    let slopeX: [Double]
    let slopeY: [Double]
    let slopeZ: [Double]
    let cellMin: [Double]
    let cellMax: [Double]
}

enum LUTInterpolation {
    static func fillMonotoneSlopes(_ values: [Double]) -> [Double] {
        let size = values.count
        var slopes = [Double](repeating: 0, count: size)
        if size == 1 { return slopes }
        var deltas = [Double](repeating: 0, count: size - 1)
        for i in 0..<(size - 1) { deltas[i] = values[i + 1] - values[i] }
        if size == 2 {
            slopes[0] = deltas[0]
            slopes[1] = deltas[0]
            return slopes
        }
        var left = 0.5 * (3.0 * deltas[0] - deltas[1])
        if left * deltas[0] <= 0 {
            left = 0
        } else if deltas[0] * deltas[1] < 0 && abs(left) > abs(3.0 * deltas[0]) {
            left = 3.0 * deltas[0]
        }
        slopes[0] = left
        for i in 1..<(size - 1) {
            let previous = deltas[i - 1]
            let next = deltas[i]
            if previous == 0 || next == 0 || previous * next <= 0 {
                slopes[i] = 0
            } else {
                slopes[i] = 2.0 * previous * next / (previous + next)
            }
        }
        var right = 0.5 * (3.0 * deltas[size - 2] - deltas[size - 3])
        if right * deltas[size - 2] <= 0 {
            right = 0
        } else if deltas[size - 2] * deltas[size - 3] < 0 && abs(right) > abs(3.0 * deltas[size - 2]) {
            right = 3.0 * deltas[size - 2]
        }
        slopes[size - 1] = right
        return slopes
    }

    static func preparePCHIP(_ lut: LUT3D) -> PreparedPCHIP3D {
        let size = lut.size
        let valueCount = size * size * size * 3
        var slopeX = [Double](repeating: 0, count: valueCount)
        var slopeY = [Double](repeating: 0, count: valueCount)
        var slopeZ = [Double](repeating: 0, count: valueCount)
        let cellCount = (size - 1) * (size - 1) * (size - 1) * 3
        var cellMin = [Double](repeating: 0, count: cellCount)
        var cellMax = [Double](repeating: 0, count: cellCount)
        let cellStrideC = (size - 1) * (size - 1) * (size - 1)

        for j in 0..<size {
            for k in 0..<size {
                for c in 0..<3 {
                    var line = [Double](repeating: 0, count: size)
                    for i in 0..<size { line[i] = lut[i, j, k, c] }
                    let slopes = fillMonotoneSlopes(line)
                    for i in 0..<size { slopeX[((i * size + j) * size + k) * 3 + c] = slopes[i] }
                }
            }
        }
        for i in 0..<size {
            for k in 0..<size {
                for c in 0..<3 {
                    var line = [Double](repeating: 0, count: size)
                    for j in 0..<size { line[j] = lut[i, j, k, c] }
                    let slopes = fillMonotoneSlopes(line)
                    for j in 0..<size { slopeY[((i * size + j) * size + k) * 3 + c] = slopes[j] }
                }
            }
        }
        for i in 0..<size {
            for j in 0..<size {
                for c in 0..<3 {
                    var line = [Double](repeating: 0, count: size)
                    for k in 0..<size { line[k] = lut[i, j, k, c] }
                    let slopes = fillMonotoneSlopes(line)
                    for k in 0..<size { slopeZ[((i * size + j) * size + k) * 3 + c] = slopes[k] }
                }
            }
        }
        for i in 0..<(size - 1) {
            for j in 0..<(size - 1) {
                for k in 0..<(size - 1) {
                    for c in 0..<3 {
                        var minValue = lut[i, j, k, c]
                        var maxValue = minValue
                        for di in 0...1 {
                            for dj in 0...1 {
                                for dk in 0...1 {
                                    let sample = lut[i + di, j + dj, k + dk, c]
                                    if sample < minValue { minValue = sample }
                                    if sample > maxValue { maxValue = sample }
                                }
                            }
                        }
                        let index = (((i * (size - 1) + j) * (size - 1) + k) * 3) + c
                        cellMin[index] = minValue
                        cellMax[index] = maxValue
                    }
                }
            }
        }
        _ = cellStrideC
        return PreparedPCHIP3D(
            lut: lut, slopeX: slopeX, slopeY: slopeY, slopeZ: slopeZ,
            cellMin: cellMin, cellMax: cellMax
        )
    }

    private static func hermite(_ y0: Double, _ y1: Double, _ m0: Double, _ m1: Double, _ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * y0 + h10 * m0 + h01 * y1 + h11 * m1
    }

    private static func mix(_ v0: Double, _ v1: Double, _ t: Double) -> Double {
        v0 + t * (v1 - v0)
    }

    private static func bilinearMix(_ v00: Double, _ v10: Double, _ v01: Double,
                                    _ v11: Double, _ tx: Double, _ ty: Double) -> Double {
        mix(mix(v00, v10, tx), mix(v01, v11, tx), ty)
    }

    private static func clamp(_ value: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        value < minValue ? minValue : (value > maxValue ? maxValue : value)
    }

    static func sample(_ prepared: PreparedPCHIP3D, _ r: Double, _ g: Double, _ b: Double) -> Vec3 {
        let size = prepared.lut.size
        let (i, tr) = SpectralUpsampling.cubicBaseFraction(r, size)
        let (j, tg) = SpectralUpsampling.cubicBaseFraction(g, size)
        let (k, tb) = SpectralUpsampling.cubicBaseFraction(b, size)
        var out = Vec3(0, 0, 0)
        let cellBase = (((i * (size - 1) + j) * (size - 1) + k) * 3)
        for c in 0..<3 {
            let v000 = hermite(prepared.lut[i, j, k, c], prepared.lut[i + 1, j, k, c],
                               prepared.slopeX[stride(i, j, k, c, size)],
                               prepared.slopeX[stride(i + 1, j, k, c, size)], tr)
            let v010 = hermite(prepared.lut[i, j + 1, k, c], prepared.lut[i + 1, j + 1, k, c],
                               prepared.slopeX[stride(i, j + 1, k, c, size)],
                               prepared.slopeX[stride(i + 1, j + 1, k, c, size)], tr)
            let v001 = hermite(prepared.lut[i, j, k + 1, c], prepared.lut[i + 1, j, k + 1, c],
                               prepared.slopeX[stride(i, j, k + 1, c, size)],
                               prepared.slopeX[stride(i + 1, j, k + 1, c, size)], tr)
            let v011 = hermite(prepared.lut[i, j + 1, k + 1, c], prepared.lut[i + 1, j + 1, k + 1, c],
                               prepared.slopeX[stride(i, j + 1, k + 1, c, size)],
                               prepared.slopeX[stride(i + 1, j + 1, k + 1, c, size)], tr)

            let sy00 = mix(prepared.slopeY[stride(i, j, k, c, size)],
                           prepared.slopeY[stride(i + 1, j, k, c, size)], tr)
            let sy10 = mix(prepared.slopeY[stride(i, j + 1, k, c, size)],
                           prepared.slopeY[stride(i + 1, j + 1, k, c, size)], tr)
            let sy01 = mix(prepared.slopeY[stride(i, j, k + 1, c, size)],
                           prepared.slopeY[stride(i + 1, j, k + 1, c, size)], tr)
            let sy11 = mix(prepared.slopeY[stride(i, j + 1, k + 1, c, size)],
                           prepared.slopeY[stride(i + 1, j + 1, k + 1, c, size)], tr)

            let vz0 = hermite(v000, v010, sy00, sy10, tg)
            let vz1 = hermite(v001, v011, sy01, sy11, tg)

            let sz0 = bilinearMix(prepared.slopeZ[stride(i, j, k, c, size)],
                                  prepared.slopeZ[stride(i + 1, j, k, c, size)],
                                  prepared.slopeZ[stride(i, j + 1, k, c, size)],
                                  prepared.slopeZ[stride(i + 1, j + 1, k, c, size)], tr, tg)
            let sz1 = bilinearMix(prepared.slopeZ[stride(i, j, k + 1, c, size)],
                                  prepared.slopeZ[stride(i + 1, j, k + 1, c, size)],
                                  prepared.slopeZ[stride(i, j + 1, k + 1, c, size)],
                                  prepared.slopeZ[stride(i + 1, j + 1, k + 1, c, size)], tr, tg)

            let interpolated = hermite(vz0, vz1, sz0, sz1, tb)
            let cellIndex = cellBase + c
            out[c] = clamp(interpolated, prepared.cellMin[cellIndex], prepared.cellMax[cellIndex])
        }
        return out
    }

    private static func stride(_ x: Int, _ y: Int, _ z: Int, _ c: Int, _ size: Int) -> Int {
        ((x * size + y) * size + z) * 3 + c
    }

    static func applyPCHIP(_ prepared: PreparedPCHIP3D, image: ImageRGB) -> ImageRGB {
        var output = image
        let scale = Double(prepared.lut.size - 1)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let r = image[x, y, 0] * scale
                let g = image[x, y, 1] * scale
                let b = image[x, y, 2] * scale
                output.setPixel(x, y, sample(prepared, r, g, b))
            }
        }
        return output
    }
}

