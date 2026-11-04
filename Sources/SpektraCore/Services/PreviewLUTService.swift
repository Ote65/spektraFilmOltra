import Foundation

/// 四段 LUT 预览预测（移植自 electron `src/spektrafilm_service/lut_preview.py`）。
///
/// 把确定性逐像素链路拆成：
///   source -> [l1] -> log_e_film -> [l2] -> cmy_film
///          -> [l3] -> log_e_print -> [l4] -> 线性 ProPhoto
///
/// 相机曝光、印相曝光、印相曝光补偿在表间按对数域偏移施加，改这些滑杆不重烘。
/// 空间/随机效果由 `debug.lutMode` 关闭；正片扫描模式没有印相段，直接跳过预测。
final class PreviewLUTService {
    /// 45³ 在真实 RAW 上 p99 会超过 1.0；65³ 实测 max 1.22 / p99 0.86。
    static let defaultResolution = 65

    static let shaperLowEV = -8.0
    static let shaperHighEV = 6.0
    static let encodedMax = 2.0
    private static let evHeadroom = 5.0
    private static let cacheLimit = 3

    // MARK: - 3D 表

    struct FloatLUT3D {
        let size: Int
        let values: [Float] // ((x * size + y) * size + z) * 3 + c

        init(size: Int, values: [Float]) {
            precondition(values.count == size * size * size * 3)
            self.size = size
            self.values = values
        }
    }

    // MARK: - 烘焙结果

    final class Bundle {
        let key: String
        let resolution: Int
        let t1: FloatLUT3D
        let t2: FloatLUT3D
        let t3: FloatLUT3D
        let t4: FloatLUT3D
        let wire1: (lo: Double, hi: Double)
        let wire2: (lo: Double, hi: Double)
        let wire3: (lo: Double, hi: Double)
        let encodedInput: Bool
        let bakedFactor: Double

        private let compPipeline: SimulationPipeline?
        private let compLock = NSLock()
        private var compRatios: [Double: Double] = [:]

        init(key: String, resolution: Int,
             t1: FloatLUT3D, t2: FloatLUT3D, t3: FloatLUT3D, t4: FloatLUT3D,
             wire1: (lo: Double, hi: Double),
             wire2: (lo: Double, hi: Double),
             wire3: (lo: Double, hi: Double),
             encodedInput: Bool, bakedFactor: Double,
             compPipeline: SimulationPipeline?) {
            self.key = key
            self.resolution = resolution
            self.t1 = t1
            self.t2 = t2
            self.t3 = t3
            self.t4 = t4
            self.wire1 = wire1
            self.wire2 = wire2
            self.wire3 = wire3
            self.encodedInput = encodedInput
            self.bakedFactor = bakedFactor
            self.compPipeline = compPipeline
        }

        /// 印相曝光补偿比值；补偿关闭时恒为 1。
        func compRatio(exposureEV: Double, compensate: Bool) -> Double {
            guard compensate, let pipeline = compPipeline else { return 1.0 }
            let key = (exposureEV * 10000).rounded() / 10000
            compLock.lock()
            if let cached = compRatios[key] {
                compLock.unlock()
                return cached
            }
            pipeline.updatePreviewCompensationMidgray(exposureEV: key)
            let factor = pipeline.previewPrintExposureFactor()
            let ratio = bakedFactor > 1e-12 ? factor / bakedFactor : factor
            compRatios[key] = ratio
            compLock.unlock()
            return ratio
        }

        /// 在预测链上跑一张输入图，返回线性 ProPhoto。
        func predict(source: ImageRGB, autoEV: Double = 0, exposureEV: Double = 0,
                     printExposure: Double = 1, compensate: Bool = false) -> ImageRGB {
            guard source.width > 0, source.height > 0 else { return source }
            let width = source.width
            let height = source.height
            let span1 = max(wire1.hi - wire1.lo, 1e-9)
            let span3 = max(wire3.hi - wire3.lo, 1e-9)

            var stage: [Double]
            var logOffset: Double
            if encodedInput {
                let scale = pow(2.0, autoEV) / PreviewLUTService.encodedMax
                let scaled = source.data.map { $0 * scale }
                stage = PreviewLUTService.lookup(t1, values: scaled, width: width, height: height, shaped: false)
                logOffset = exposureEV * log10(2.0)
            } else {
                // 自动曝光在真管线的 preprocess 阶段施加，早于 rgbToFilmRaw；
                // 因此必须挪到 t1 的 shaper 坐标上，不能放到 t1 之后。
                stage = PreviewLUTService.lookup(
                    t1, values: source.data, width: width, height: height,
                    shaped: true, shapedEVOffset: autoEV
                )
                logOffset = exposureEV * log10(2.0)
            }
            let norm1 = PreviewLUTService.offsetNormalized(stage, offset: logOffset / span1)

            stage = PreviewLUTService.lookup(t2, values: norm1, width: width, height: height, shaped: false)
            stage = PreviewLUTService.lookup(t3, values: stage, width: width, height: height, shaped: false)

            let printOffset = log10(max(printExposure, 1e-10))
            let comp = compRatio(exposureEV: exposureEV, compensate: compensate)
            let totalOffset = printOffset + (compensate ? log10(max(comp, 1e-10)) : 0)
            let norm3 = PreviewLUTService.offsetNormalized(stage, offset: totalOffset / span3)

            let linear = PreviewLUTService.lookup(t4, values: norm3, width: width, height: height, shaped: false)
            return ImageRGB(width: width, height: height, data: linear)
        }
    }

    // MARK: - 缓存

    private let lock = NSLock()
    private let bakeLock = NSLock()
    private var cache: [String: Bundle] = [:]
    private var order: [String] = []

    func bundle(for params: RuntimePhotoParams, key: String,
                resolution: Int = PreviewLUTService.defaultResolution) -> Bundle? {
        guard !params.io.scanFilm else { return nil }
        if let cached = cachedBundle(key: key) { return cached }

        bakeLock.lock()
        defer { bakeLock.unlock() }
        if let cached = cachedBundle(key: key) { return cached }
        guard let built = bake(params: params, key: key, resolution: resolution) else { return nil }

        lock.lock()
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        cache[key] = built
        order.append(key)
        while order.count > PreviewLUTService.cacheLimit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        lock.unlock()
        return built
    }

    private func cachedBundle(key: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = cache[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    // MARK: - 烘焙

    private func bake(params: RuntimePhotoParams, key: String,
                      resolution: Int) -> Bundle? {
        let n = max(2, resolution)
        let bakeParams = Self.makeBakeParams(params)
        let pipe = SimulationPipeline(params: bakeParams, keepTaps: false)
        let encoded = bakeParams.io.inputCCTFDecoding
        let grid = Self.gridValues(n)

        let inputValues: [Double]
        if encoded {
            inputValues = grid.map { $0 * Self.encodedMax }
        } else {
            let lo = Self.shaperLowEV
            let span = Self.shaperHighEV - Self.shaperLowEV
            inputValues = grid.map { pow(2.0, lo + $0 * span) }
        }
        let o1 = pipe.processSegment(Self.gridImage(inputValues, n: n),
                                     inject: .rgbIn, collect: .logEFilm)
        let wire1 = Self.wire(o1, pad: Self.evHeadroom * log10(2.0), rel: 0.02)
        let t1 = Self.table(o1, n: n, lo: wire1.lo, hi: wire1.hi)

        let logGrid = Self.scaleGrid(grid, lo: wire1.lo, hi: wire1.hi)
        let o2 = pipe.processSegment(Self.gridImage(logGrid, n: n),
                                     inject: .logEFilm, collect: .cmyFilm)
        let wire2 = Self.wire(o2, pad: 0, rel: 0.02)
        let t2 = Self.table(o2, n: n, lo: wire2.lo, hi: wire2.hi)

        let densityGrid = Self.scaleGrid(grid, lo: wire2.lo, hi: wire2.hi)
        let o3 = pipe.processSegment(Self.gridImage(densityGrid, n: n),
                                     inject: .cmyFilm, collect: .logEPrint)
        let wire3 = Self.wire(o3, pad: 0, rel: 0.02)
        let t3 = Self.table(o3, n: n, lo: wire3.lo, hi: wire3.hi)

        let printGrid = Self.scaleGrid(grid, lo: wire3.lo, hi: wire3.hi)
        let o4 = pipe.processSegment(Self.gridImage(printGrid, n: n),
                                     inject: .logEPrint, collect: .rgbOut)
        let t4 = Self.rawTable(o4, n: n)

        // 补偿管线常驻：快速“拍摄曝光”会在拖动时临时关闭补偿，
        // 同一份表必须能在补偿开/关之间切换，不能因此重烘。
        let bakedFactor = pipe.previewPrintExposureFactor()
        let compPipe = SimulationPipeline(params: Self.makeCompParams(params), keepTaps: false)

        return Bundle(
            key: key, resolution: n,
            t1: t1, t2: t2, t3: t3, t4: t4,
            wire1: wire1, wire2: wire2, wire3: wire3,
            encodedInput: encoded, bakedFactor: bakedFactor,
            compPipeline: compPipe
        )
    }

    private static func makeBakeParams(_ params: RuntimePhotoParams) -> RuntimePhotoParams {
        var p = params
        p.debug.lutMode = true
        p.settings.previewMode = false
        p.io.crop = false
        p.io.upscaleFactor = 1
        p.io.outputColorSpace = "ProPhoto RGB"
        p.io.outputCCTFEncoding = false
        return p
    }

    private static func makeCompParams(_ params: RuntimePhotoParams) -> RuntimePhotoParams {
        var p = params
        p.debug.lutMode = false
        p.debug.deactivateSpatialEffects = true
        p.debug.deactivateStochasticEffects = true
        p.settings.previewMode = false
        p.camera.autoExposure = false
        p.camera.exposureCompensationEV = 0
        p.filmRender.halation.boostEV = 0
        p.scanner.whiteCorrection = false
        p.scanner.blackCorrection = false
        p.scanner.unsharpMask = [0, 0]
        p.enlarger.printExposure = 1
        p.enlarger.printExposureCompensation = true
        p.io.crop = false
        p.io.upscaleFactor = 1
        p.io.outputColorSpace = "ProPhoto RGB"
        p.io.outputCCTFEncoding = false
        return p
    }

    // MARK: - 网格

    /// table 顺序 (r, g, b)，每个通道 [0, 1]。
    private static func gridValues(_ n: Int) -> [Double] {
        var values = [Double](repeating: 0, count: n * n * n * 3)
        let denom = Double(max(n - 1, 1))
        for r in 0..<n {
            for g in 0..<n {
                for b in 0..<n {
                    let offset = ((r * n + g) * n + b) * 3
                    let vr = Double(r) / denom
                    let vg = Double(g) / denom
                    let vb = Double(b) / denom
                    values[offset] = vr
                    values[offset + 1] = vg
                    values[offset + 2] = vb
                }
            }
        }
        return values
    }

    private static func scaleGrid(_ grid: [Double],
                                  lo: Double, hi: Double) -> [Double] {
        let span = hi - lo
        return grid.map { lo + $0 * span }
    }

    /// 摊成 width = n²、height = n 的一张图；像素 (r*n+g, b)。
    private static func gridImage(_ values: [Double], n: Int) -> ImageRGB {
        var image = ImageRGB(width: n * n, height: n)
        for b in 0..<n {
            for r in 0..<n {
                for g in 0..<n {
                    let src = ((r * n + g) * n + b) * 3
                    let dst = ((b * (n * n) + r * n + g)) * 3
                    image.data[dst] = values[src]
                    image.data[dst + 1] = values[src + 1]
                    image.data[dst + 2] = values[src + 2]
                }
            }
        }
        return image
    }

    private static func wire(_ image: ImageRGB, pad: Double,
                             rel: Double) -> (lo: Double, hi: Double) {
        var lo = Double.infinity
        var hi = -Double.infinity
        for value in image.data where value.isFinite {
            lo = min(lo, value)
            hi = max(hi, value)
        }
        guard lo.isFinite, hi.isFinite else { return (0, 1) }
        let extra = (hi - lo) * rel + pad
        return (lo - extra, hi + extra)
    }

    private static func table(_ image: ImageRGB, n: Int,
                              lo: Double, hi: Double) -> FloatLUT3D {
        let denom = max(hi - lo, 1e-9)
        var values = [Float](repeating: 0, count: n * n * n * 3)
        for b in 0..<n {
            for r in 0..<n {
                for g in 0..<n {
                    let src = ((b * (n * n) + r * n + g)) * 3
                    let dst = ((r * n + g) * n + b) * 3
                    for c in 0..<3 {
                        let value = image.data[src + c]
                        let centered = (value.isFinite ? value : 0) - lo
                        values[dst + c] = Float(centered / denom)
                    }
                }
            }
        }
        return FloatLUT3D(size: n, values: values)
    }

    private static func rawTable(_ image: ImageRGB, n: Int) -> FloatLUT3D {
        var values = [Float](repeating: 0, count: n * n * n * 3)
        for b in 0..<n {
            for r in 0..<n {
                for g in 0..<n {
                    let src = ((b * (n * n) + r * n + g)) * 3
                    let dst = ((r * n + g) * n + b) * 3
                    for c in 0..<3 {
                        let value = image.data[src + c]
                        values[dst + c] = Float(value.isFinite ? value : 0)
                    }
                }
            }
        }
        return FloatLUT3D(size: n, values: values)
    }

    // MARK: - 查表

    /// 三线性插值；shaped 为 true 时先做 log2 shaper。
    static func lookup(_ lut: FloatLUT3D, values: [Double],
                       width: Int, height: Int,
                       shaped: Bool, shapedEVOffset: Double = 0) -> [Double] {
        let n = lut.size
        let scale = Double(n - 1)
        let last = n - 2
        let lo = shaperLowEV
        let span = shaperHighEV - shaperLowEV
        var output = [Double](repeating: 0, count: width * height * 3)

        output.withUnsafeMutableBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }

        func row(_ y: Int) {
            let rowStart = y * width
            for x in 0..<width {
                let p = (rowStart + x) * 3
                var i0 = 0, j0 = 0, k0 = 0
                var fr = 0.0, fg = 0.0, fb = 0.0
                for c in 0..<3 {
                    var value = values[p + c]
                    if !value.isFinite { value = 0 }
                    let index: Double
                    if shaped {
                        let positive = max(value, 1e-10)
                        index = min(max((log2(positive) + shapedEVOffset - lo) / span, 0), 1)
                    } else {
                        index = min(max(value, 0), 1)
                    }
                    let f = index * scale
                    let i = min(Int(f), last)
                    let frac = f - Double(i)
                    if c == 0 { i0 = i; fr = frac }
                    else if c == 1 { j0 = i; fg = frac }
                    else { k0 = i; fb = frac }
                }
                let i1 = i0 + 1
                let j1 = j0 + 1
                let k1 = k0 + 1

                let x00 = (i0 * n + j0) * n
                let x01 = (i0 * n + j1) * n
                let x10 = (i1 * n + j0) * n
                let x11 = (i1 * n + j1) * n
                let c000 = (x00 + k0) * 3
                let c001 = (x00 + k1) * 3
                let c010 = (x01 + k0) * 3
                let c011 = (x01 + k1) * 3
                let c100 = (x10 + k0) * 3
                let c101 = (x10 + k1) * 3
                let c110 = (x11 + k0) * 3
                let c111 = (x11 + k1) * 3

                for c in 0..<3 {
                    let v000 = Double(lut.values[c000 + c])
                    let v001 = Double(lut.values[c001 + c])
                    let v010 = Double(lut.values[c010 + c])
                    let v011 = Double(lut.values[c011 + c])
                    let v100 = Double(lut.values[c100 + c])
                    let v101 = Double(lut.values[c101 + c])
                    let v110 = Double(lut.values[c110 + c])
                    let v111 = Double(lut.values[c111 + c])

                    let value: Double
                    if fr > fg {
                        if fg > fb {
                            value = v000 + fr * (v100 - v000)
                                + fg * (v110 - v100) + fb * (v111 - v110)
                        } else if fr > fb {
                            value = v000 + fr * (v100 - v000)
                                + fb * (v101 - v100) + fg * (v111 - v101)
                        } else {
                            value = v000 + fb * (v001 - v000)
                                + fr * (v101 - v001) + fg * (v111 - v101)
                        }
                    } else {
                        if fb > fg {
                            value = v000 + fb * (v001 - v000)
                                + fg * (v011 - v001) + fr * (v111 - v011)
                        } else if fb > fr {
                            value = v000 + fb * (v001 - v000)
                                + fr * (v101 - v001) + fg * (v111 - v101)
                        } else {
                            value = v000 + fg * (v010 - v000)
                                + fr * (v110 - v010) + fb * (v111 - v110)
                        }
                    }
                    base[p + c] = value
                }
            }
        }

        if width * height >= 200_000 {
            DispatchQueue.concurrentPerform(iterations: height, execute: row)
        } else {
            for y in 0..<height { row(y) }
        }
        }
        return output
    }

    private static func offsetNormalized(_ values: [Double],
                                         offset: Double) -> [Double] {
        values.map { min(max($0 + offset, 0), 1) }
    }

    // MARK: - 显示

    static let proPhotoToSRGB: Mat3 = {
        let red = ColorMath.rgbToRGB(Vec3(1, 0, 0), from: "ProPhoto RGB", to: "sRGB")
        let green = ColorMath.rgbToRGB(Vec3(0, 1, 0), from: "ProPhoto RGB", to: "sRGB")
        let blue = ColorMath.rgbToRGB(Vec3(0, 0, 1), from: "ProPhoto RGB", to: "sRGB")
        return Mat3([
            red.x, green.x, blue.x,
            red.y, green.y, blue.y,
            red.z, green.z, blue.z,
        ])
    }()

    /// 线性 ProPhoto → 预览输出：色彩空间转换 → 镜头模糊 → CCTF。
    /// 输出色域压缩与扫描锐化留给 D1；D0 只做能保持 <50 ms 的部分。
    static func displayImage(fromLinear image: ImageRGB,
                             params: RuntimePhotoParams) -> ImageRGB {
        let width = image.width
        let height = image.height
        let target = params.io.outputColorSpace
        let matrix = proPhotoToTarget(target)
        var output = image
        output.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            func row(_ y: Int) {
                let rowStart = y * width
                for x in 0..<width {
                    let p = (rowStart + x) * 3
                    let r = image.data[p].isFinite ? image.data[p] : 0
                    let g = image.data[p + 1].isFinite ? image.data[p + 1] : 0
                    let b = image.data[p + 2].isFinite ? image.data[p + 2] : 0
                    let converted = matrix.apply(Vec3(r, g, b))
                    base[p] = converted.x
                    base[p + 1] = converted.y
                    base[p + 2] = converted.z
                }
            }
            if width * height >= 200_000 {
                DispatchQueue.concurrentPerform(iterations: height, execute: row)
            } else {
                for y in 0..<height { row(y) }
            }
        }

        // D0 不做全量输出色域压缩（CAM16 在 800×600 上约 260 ms）；
        // 预测档只走矩阵 + CCTF，色域压缩留给 D1/导出。
        var rgb = output
        if params.scanner.lensBlur > 0 {
            rgb = SpatialEffects.gaussianBlurUM(
                rgb, sigmaUM: params.scanner.lensBlur, pixelSizeUM: 1
            )
        }
        // D0 不叠扫描锐化：预测图还缺颗粒/眩光/光晕等平滑项，
        // 单独加 USM 会把局部反差推得比真算更高，D1 会补齐。
        guard params.io.outputCCTFEncoding else {
            return rgb.sanitizedNonFinite()
        }
        let kind = ColorMath.cctfKind(for: target)
        var encoded = rgb
        encoded.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            func row(_ y: Int) {
                let rowStart = y * width
                for x in 0..<width {
                    let p = (rowStart + x) * 3
                    base[p] = clamp(ColorMath.cctfEncode(base[p], kind: kind))
                    base[p + 1] = clamp(ColorMath.cctfEncode(base[p + 1], kind: kind))
                    base[p + 2] = clamp(ColorMath.cctfEncode(base[p + 2], kind: kind))
                }
            }
            if width * height >= 200_000 {
                DispatchQueue.concurrentPerform(iterations: height, execute: row)
            } else {
                for y in 0..<height { row(y) }
            }
        }
        return encoded.sanitizedNonFinite()
    }

    private static func proPhotoToTarget(_ target: String) -> Mat3 {
        if target == "sRGB" { return proPhotoToSRGB }
        let red = ColorMath.rgbToRGB(Vec3(1, 0, 0), from: "ProPhoto RGB", to: target)
        let green = ColorMath.rgbToRGB(Vec3(0, 1, 0), from: "ProPhoto RGB", to: target)
        let blue = ColorMath.rgbToRGB(Vec3(0, 0, 1), from: "ProPhoto RGB", to: target)
        return Mat3([
            red.x, green.x, blue.x,
            red.y, green.y, blue.y,
            red.z, green.z, blue.z,
        ])
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - 自动曝光与键

    static func measureAutoEV(source: ImageRGB, colorSpace: String,
                              applyCCTFDecoding: Bool, method: String) -> Double {
        let small = Resize.smallPreview(source, maxSize: 256)
        return AutoExposure.measureEV(
            image: small, colorSpace: colorSpace,
            applyCCTFDecoding: applyCCTFDecoding, method: method
        )
    }

    /// 烘焙键：连续轴（相机曝光、自动曝光、印相曝光/补偿）与快速意图不参与。
    static func cacheKey(edit: PhotoEdit, inputColorSpace: String,
                         inputCCTF: Bool) -> String {
        var e = edit
        e.camera.autoExposure = false
        e.camera.exposureCompensationEV = 0
        e.enlarger.printExposure = 1
        // 补偿管线常驻，补偿开关不参与烘焙键。
        e.enlarger.printExposureCompensation = false
        e.quickIntents = [:]
        e.io.inputColorSpace = inputColorSpace
        e.io.inputCCTFDecoding = inputCCTF
        e.io.crop = false
        e.io.upscaleFactor = 1
        e.io.outputColorSpace = "ProPhoto RGB"
        e.io.outputCCTFEncoding = false
        e.debug.lutMode = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(e)) ?? Data()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
