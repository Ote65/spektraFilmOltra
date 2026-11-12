import Foundation
import Darwin

enum Akima {
    static func interpolate(x: [Double], y: [Double], at query: [Double]) -> [Double] {
        precondition(x.count == y.count && x.count >= 2)
        let n = x.count
        if n == 2 {
            let slope = (y[1] - y[0]) / (x[1] - x[0])
            return query.map { y[0] + slope * ($0 - x[0]) }
        }
        var deltas = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { deltas[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i]) }
        var m = [Double](repeating: 0, count: n + 3)
        for i in 0..<(n - 1) { m[2 + i] = deltas[i] }
        m[1] = 2 * m[2] - m[3]
        m[0] = 2 * m[1] - m[2]
        m[n + 1] = 2 * m[n] - m[n - 1]
        m[n + 2] = 2 * m[n + 1] - m[n]
        var derivatives = [Double](repeating: 0, count: n)
        var f12 = [Double](repeating: 0, count: n)
        var f1 = [Double](repeating: 0, count: n)
        var f2 = [Double](repeating: 0, count: n)
        for i in 0..<n {
            f1[i] = abs(m[i + 3] - m[i + 2])
            f2[i] = abs(m[i + 1] - m[i])
            f12[i] = f1[i] + f2[i]
        }
        let threshold = 1e-9 * (f12.max() ?? 0)
        for i in 0..<n {
            if f12[i] > threshold {
                derivatives[i] = m[i + 1] + (f2[i] / f12[i]) * (m[i + 2] - m[i + 1])
            } else {
                derivatives[i] = 0.5 * (m[i + 3] + m[i])
            }
        }
        return query.map { value in
            if value <= x[0] {
                return y[0] + derivatives[0] * (value - x[0])
            }
            if value >= x[n - 1] {
                return y[n - 1] + derivatives[n - 1] * (value - x[n - 1])
            }
            var lo = 0
            var hi = n - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if x[mid] <= value { lo = mid } else { hi = mid }
            }
            let h = x[lo + 1] - x[lo]
            let t = (value - x[lo]) / h
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            return h00 * y[lo] + h10 * h * derivatives[lo] + h01 * y[lo + 1] + h11 * h * derivatives[lo + 1]
        }
    }
}

enum FilterData {
    static func loadCSV(_ relative: String) throws -> ([Double], [Double]) {
        let url = ResourceLocator.url(relative)
        let text = try String(contentsOf: url, encoding: .utf8)
        var xs: [Double] = []
        var ys: [Double] = []
        var seen = Set<Double>()
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2,
                  let x = Double(parts[0]), let y = Double(parts[1]) else { continue }
            if seen.contains(x) { continue }
            seen.insert(x)
            xs.append(x)
            ys.append(y)
        }
        return (xs, ys)
    }

    static func transmittance(name: String, type: String, brand: String, percent: Bool) throws -> [Double] {
        let relative = "Filters/\(type)/\(brand)/\(name).csv"
        let (x, y) = try loadCSV(relative)
        let scale = percent ? 100.0 : 1.0
        return Akima.interpolate(x: x, y: y.map { $0 / scale }, at: ColorDataStore.shared.wavelengths)
    }
}

enum Illuminants {
    static let wavelengths = ColorDataStore.shared.wavelengths
    static let kg3: [Double] = {
        (try? FilterData.transmittance(name: "KG3", type: "heat_absorbing", brand: "schott", percent: false)) ??
            [Double](repeating: 1, count: wavelengths.count)
    }()
    static let lens: [Double] = {
        (try? FilterData.transmittance(name: "canon_24_f28_is", type: "lens_transmission", brand: "canon", percent: true)) ??
            [Double](repeating: 1, count: wavelengths.count)
    }()

    static func blackBody(_ temperature: Double) -> [Double] {
        let c2 = 1.4388e-2 // m·K, CIE/ITS-90 value
        return wavelengths.map { wavelength in
            let lambda = wavelength * 1e-9
            return 1.0 / (pow(lambda, 5) * (exp(c2 / (lambda * temperature)) - 1.0))
        }
    }

    static func standard(_ name: String) throws -> [Double] {
        // 与 Python 参考实现的别名保持一致：
        // 电影印片（2383/2393）的观察光源写的是 K75P，实际数据键为 Kinoton 75P；
        // 钨丝灯胶片参考光源写 T，实际数据键为 Incandescent。
        if name == "K75P" { return try standard("Kinoton 75P") }
        if name == "T" { return try standard("Incandescent") }
        var values: [Double]
        if name.hasPrefix("BB") {
            let temperature = Double(name.dropFirst(2)) ?? 3400
            values = blackBody(temperature)
        } else if name == "TH-KG3" || name == "TH-KG3-L" {
            values = zip(blackBody(3400), kg3).map { $0 * $1 }
            if name == "TH-KG3-L" {
                values = zip(values, lens).map { $0 * $1 }
            }
        } else if let stored = ColorDataStore.shared.illuminants[name] {
            values = stored
        } else {
            throw CoreError.missingResource("illuminant \(name)")
        }
        let mean = values.reduce(0, +) / Double(values.count)
        if mean != 0 {
            values = values.map { $0 / mean }
        }
        return values
    }

    static func xy(_ name: String) throws -> (Double, Double) {
        let illum = try standard(name)
        let cmfs = ColorDataStore.shared.cmfs
        var xyz = Vec3(0, 0, 0)
        for i in 0..<min(illum.count, cmfs.count) {
            xyz.x += illum[i] * cmfs[i][0]
            xyz.y += illum[i] * cmfs[i][1]
            xyz.z += illum[i] * cmfs[i][2]
        }
        return ColorMath.xyzToXY(xyz)
    }
}

enum EnlargerFilters {
    static let customDichroic: [[Double]] = {
        let wl = ColorDataStore.shared.wavelengths
        var filters = [[Double]](repeating: [0, 0, 0], count: wl.count)
        for (i, wavelength) in wl.enumerated() {
            filters[i][2] = erf((wavelength - 516.0) / 12.0)
            if wavelength <= 550 {
                filters[i][1] = -erf((wavelength - 500.0) / 8.0)
            } else {
                filters[i][1] = erf((wavelength - 610.0) / 8.0)
            }
            filters[i][0] = -erf((wavelength - 607.0) / 8.0)
            for c in 0..<3 {
                filters[i][c] = filters[i][c] / 2 + 0.5
            }
        }
        return filters
    }()

    static func applyCC(_ illuminant: [Double], cc: [Double]) -> [Double] {
        let transmittance = cc.map { pow(10.0, -$0 / 100.0) }
        var output = illuminant
        for i in 0..<illuminant.count {
            var product = 1.0
            for c in 0..<3 {
                let dimmed = 1 - (1 - customDichroic[i][c]) * (1 - transmittance[c])
                product *= dimmed
            }
            output[i] = illuminant[i] * product
        }
        return output
    }
}

enum BandPassFilter {
    static func compute(uv: (Double, Double, Double), ir: (Double, Double, Double)) -> [Double] {
        let wl = ColorDataStore.shared.wavelengths
        let ampUV = min(max(uv.0, 0), 1)
        let ampIR = min(max(ir.0, 0), 1)
        return wl.map { wavelength in
            let uvValue = 1 - ampUV + ampUV * (0.5 * erf((wavelength - uv.1) / uv.2) + 0.5)
            let irValue = 1 - ampIR + ampIR * (0.5 * erf((wavelength - ir.1) / (-ir.2)) + 0.5)
            return uvValue * irValue
        }
    }
}

