import Foundation

enum FastGaussian {
    static let smallSigmaMax = 3.0
    static let exponentialFits3: [(Double, Double)] = [
        (0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684),
    ]
    static let exponentialFits2: [(Double, Double)] = [
        (0.6235, 0.9401), (0.3765, 2.5177),
    ]

    static func reflect(_ index: Int, _ count: Int) -> Int {
        if index >= 0 && index < count { return index }
        if index < 0 && index >= -count { return -index - 1 }
        if index >= count && index < 2 * count { return 2 * count - 1 - index }
        var value = index % (2 * count)
        if value < 0 { value += 2 * count }
        if value >= count { value = 2 * count - 1 - value }
        return value
    }

    static func kernel(sigma: Double, truncate: Double) -> ([Double], Int) {
        let radius = Int(truncate * sigma + 0.5)
        let size = 2 * radius + 1
        var values = [Double](repeating: 0, count: size)
        var total = 0.0
        for i in 0..<size {
            let x = Double(i - radius)
            let value = exp(-0.5 * pow(x / sigma, 2))
            values[i] = value
            total += value
        }
        for i in 0..<size { values[i] /= total }
        return (values, radius)
    }

    static func filterChannel(_ input: [Double], width: Int, height: Int,
                              sigma: Double, truncate: Double = 3.0) -> [Double] {
        if sigma <= 0 { return input }
        if sigma >= smallSigmaMax { return iirFilter(input, width: width, height: height, sigma: sigma) }
        let (kernel, radius) = self.kernel(sigma: sigma, truncate: truncate)
        var temporary = [Double](repeating: 0, count: input.count)
        var output = [Double](repeating: 0, count: input.count)
        let diameter = 2 * radius + 1

        // 垂直：把每一行的 2r+1 个反射行号在行外算好，内层循环不再调用 reflect。
        input.withUnsafeBufferPointer { src in
            temporary.withUnsafeMutableBufferPointer { tmp in
                kernel.withUnsafeBufferPointer { k in
                    func row(_ y: Int) {
                        var rows = [Int](repeating: 0, count: diameter)
                        for t in 0..<diameter { rows[t] = reflect(y + t - radius, height) }
                        let base = y * width
                        for x in 0..<width {
                            var sum = 0.0
                            for t in 0..<diameter {
                                sum += src[rows[t] * width + x] * k[t]
                            }
                            tmp[base + x] = sum
                        }
                    }
                    Interpolation.parallelRows(height: height, pixels: width * height, row)
                }
            }
        }

        // 水平：中间区段没有反射，拆成「内部 + 左右边缘」三段。
        temporary.withUnsafeBufferPointer { tmp in
            output.withUnsafeMutableBufferPointer { out in
                kernel.withUnsafeBufferPointer { k in
                    func row(_ y: Int) {
                        let base = y * width
                        if width > 2 * radius {
                            for x in radius..<(width - radius) {
                                var sum = 0.0
                                let start = base + x - radius
                                for t in 0..<diameter { sum += tmp[start + t] * k[t] }
                                out[base + x] = sum
                            }
                            for x in 0..<radius {
                                var sum = 0.0
                                for t in 0..<diameter {
                                    sum += tmp[base + reflect(x - radius + t, width)] * k[t]
                                }
                                out[base + x] = sum
                            }
                            for x in (width - radius)..<width {
                                var sum = 0.0
                                for t in 0..<diameter {
                                    sum += tmp[base + reflect(x - radius + t, width)] * k[t]
                                }
                                out[base + x] = sum
                            }
                        } else {
                            for x in 0..<width {
                                var sum = 0.0
                                for t in 0..<diameter {
                                    sum += tmp[base + reflect(x - radius + t, width)] * k[t]
                                }
                                out[base + x] = sum
                            }
                        }
                    }
                    Interpolation.parallelRows(height: height, pixels: width * height, row)
                }
            }
        }
        return output
    }

    static func iirCoefficients(_ sigma: Double) -> (Double, Double, Double, Double) {
        let q: Double
        if sigma >= 2.5 {
            q = 0.98711 * sigma - 0.96330
        } else {
            q = 3.97156 - 4.14554 * sqrt(1 - 0.26891 * sigma)
        }
        let q2 = q * q
        let q3 = q2 * q
        let b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3
        let b1 = 2.44413 * q + 2.85619 * q2 + 1.26661 * q3
        let b2 = -(1.4281 * q2 + 1.26661 * q3)
        let b3 = 0.422205 * q3
        let B = 1 - (b1 + b2 + b3) / b0
        return (B, b1 / b0, b2 / b0, b3 / b0)
    }

    static func iirFilter(_ input: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        guard sigma >= 0.5 else {
            return filterChannel(input, width: width, height: height, sigma: sigma, truncate: 3.0)
        }
        guard width > 0, height > 0 else { return input }
        let (B, B1, B2, B3) = iirCoefficients(sigma)
        var temporary = [Double](repeating: 0, count: input.count)
        var output = [Double](repeating: 0, count: input.count)

        // 横向递归：每行独立，可按行并行。
        input.withUnsafeBufferPointer { src in
            temporary.withUnsafeMutableBufferPointer { tmp in
                func row(_ y: Int) {
                    let base = y * width
                    var w1 = src[base]
                    var w2 = w1
                    var w3 = w1
                    for x in 0..<width {
                        let w = B * src[base + x] + B1 * w1 + B2 * w2 + B3 * w3
                        tmp[base + x] = w
                        w3 = w2
                        w2 = w1
                        w1 = w
                    }
                    var y1 = tmp[base + width - 1]
                    var y2 = y1
                    var y3 = y1
                    for x in stride(from: width - 1, through: 0, by: -1) {
                        let value = B * tmp[base + x] + B1 * y1 + B2 * y2 + B3 * y3
                        tmp[base + x] = value
                        y3 = y2
                        y2 = y1
                        y1 = value
                    }
                }
                Interpolation.parallelRows(height: height, pixels: width * height, row)
            }
        }

        // 纵向递归：每列独立，可按列并行（不同列写不同下标，无竞争）。
        temporary.withUnsafeBufferPointer { tmp in
            output.withUnsafeMutableBufferPointer { out in
                func column(_ x: Int) {
                    var w1 = tmp[x]
                    var w2 = w1
                    var w3 = w1
                    for y in 0..<height {
                        let index = y * width + x
                        let w = B * tmp[index] + B1 * w1 + B2 * w2 + B3 * w3
                        out[index] = w
                        w3 = w2
                        w2 = w1
                        w1 = w
                    }
                    var y1 = out[(height - 1) * width + x]
                    var y2 = y1
                    var y3 = y1
                    for y in stride(from: height - 1, through: 0, by: -1) {
                        let index = y * width + x
                        let value = B * out[index] + B1 * y1 + B2 * y2 + B3 * y3
                        out[index] = value
                        y3 = y2
                        y2 = y1
                        y1 = value
                    }
                }
                Interpolation.parallelRows(height: width, pixels: width * height, column)
            }
        }
        return output
    }

    static func filter(_ image: ImageRGB, sigma: [Double], truncate: Double = 3.0) -> ImageRGB {
        var output = image
        for c in 0..<3 {
            var channel = [Double](repeating: 0, count: image.width * image.height)
            for i in 0..<channel.count { channel[i] = Double(image.data[i * 3 + c]) }
            let filtered = filterChannel(channel, width: image.width, height: image.height,
                                         sigma: sigma[c], truncate: truncate)
            for i in 0..<filtered.count { output.data[i * 3 + c] = Float(filtered[i]) }
        }
        return output
    }

    static func filter(_ image: ImageRGB, sigma: Double, truncate: Double = 3.0) -> ImageRGB {
        filter(image, sigma: [sigma, sigma, sigma], truncate: truncate)
    }

    static func exponentialFilter(_ image: ImageRGB, decay: [Double], nGaussians: Int = 3) -> ImageRGB {
        let fits = nGaussians == 2 ? exponentialFits2 : exponentialFits3
        var result = ImageRGB(width: image.width, height: image.height)
        for (index, fit) in fits.enumerated() {
            let component = filter(image, sigma: decay.map { $0 * fit.1 })
            for c in 0..<3 {
                for i in 0..<(image.width * image.height) {
                    let value = Float(fit.0 * Double(component.data[i * 3 + c]))
                    if index == 0 { result.data[i * 3 + c] = value }
                    else { result.data[i * 3 + c] += value }
                }
            }
        }
        return result
    }

    static func exponentialFilter(_ image: ImageRGB, decay: Double, nGaussians: Int = 3) -> ImageRGB {
        exponentialFilter(image, decay: [decay, decay, decay], nGaussians: nGaussians)
    }
}
