import Foundation

/// 调色台引擎：线性 ProPhoto 交接图 → sRGB 编码显示图。
/// 步骤顺序与 Python `spektrafilm_gui/grade_engine.py` 保持一致：
/// 曝光/白平衡 → sRGB 编码 → 影调 → 色彩 → 通透分析 → 通透 → 清晰度/纹理
/// → 去雾 → 降噪 → 锐化 → 暗角/色差/颗粒 → LUT → 后处理。
enum GradeCancelled: Error {
    case cancelled
}

struct ToneAnalysis: Equatable {
    var blackPoint: Double
    var whitePoint: Double
    var highlightRGB: Vec3
    var shadowRGB: Vec3
    var highlightCast: String
    var shadowCast: String
    var summary: String

    static let neutral = ToneAnalysis(
        blackPoint: 0, whitePoint: 1,
        highlightRGB: Vec3(1, 1, 1), shadowRGB: Vec3(0, 0, 0),
        highlightCast: "中性", shadowCast: "中性", summary: "未分析"
    )
}

struct GradeRenderResult {
    var image: ImageRGB
    var analysis: ToneAnalysis
    /// 非 nil 表示配方里的 LUT 存在但解析失败：画面按无 LUT 渲染，调用方负责提示用户。
    var lutError: LUTParseError? = nil
}

/// LUT 解析失败：导入时阻止无效文件入库，渲染与导出时把原因交给界面提示。
struct LUTParseError: LocalizedError {
    let name: String
    let reason: String

    init(path: String, reason: String = "不是有效的 3D .cube 文件") {
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.reason = reason
    }

    var errorDescription: String? {
        "LUT 解析失败：\(name)（\(reason)）"
    }
}

enum GradeEngine {
    private static let transparencyEdgePercent = 0.4
    private static let lumaR: Double = 0.2126
    private static let lumaG: Double = 0.7152
    private static let lumaB: Double = 0.0722

    // MARK: - 源转换

    private static let proPhotoToSRGB: Mat3 = {
        let red = ColorMath.rgbToRGB(Vec3(1, 0, 0), from: "ProPhoto RGB", to: "sRGB")
        let green = ColorMath.rgbToRGB(Vec3(0, 1, 0), from: "ProPhoto RGB", to: "sRGB")
        let blue = ColorMath.rgbToRGB(Vec3(0, 0, 1), from: "ProPhoto RGB", to: "sRGB")
        return Mat3([
            red.x, green.x, blue.x,
            red.y, green.y, blue.y,
            red.z, green.z, blue.z,
        ])
    }()

    /// 线性 ProPhoto float → 线性 sRGB float（原地版，导出大图时省一张整图）。
    static func prepareSourceInPlace(_ image: inout ImageRGB) {
        let matrix = proPhotoToSRGB
        let count = image.data.count
        image.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = 0
            while index < count {
                let converted = matrix.apply(Vec3(Double(base[index]),
                                                  Double(base[index + 1]),
                                                  Double(base[index + 2])))
                base[index] = Float(converted.x)
                base[index + 1] = Float(converted.y)
                base[index + 2] = Float(converted.z)
                index += 3
            }
        }
    }

    /// 线性 ProPhoto float → 线性 sRGB float。
    static func prepareSource(_ image: ImageRGB) -> ImageRGB {
        let matrix = proPhotoToSRGB
        var output = image
        for i in 0..<(image.width * image.height) {
            let r = Double(image.data[i * 3])
            let g = Double(image.data[i * 3 + 1])
            let b = Double(image.data[i * 3 + 2])
            let converted = matrix.apply(Vec3(r, g, b))
            output.data[i * 3] = Float(converted.x)
            output.data[i * 3 + 1] = Float(converted.y)
            output.data[i * 3 + 2] = Float(converted.z)
        }
        return output
    }

    /// 线性图按长边上限降采样（与调色代理图一致）。
    static func downsampleLinear(_ image: ImageRGB, maxLongEdge: Int) -> ImageRGB {
        guard maxLongEdge > 0 else { return image }
        return Resize.longEdge(image, maxSize: maxLongEdge)
    }

    @discardableResult
    static func render(
        _ sourceLinearSRGB: ImageRGB,
        recipe: GradeRecipe,
        analyze: Bool = true,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> GradeRenderResult {
        guard sourceLinearSRGB.width > 0, sourceLinearSRGB.height > 0 else {
            return GradeRenderResult(image: sourceLinearSRGB, analysis: .neutral)
        }
        let width = sourceLinearSRGB.width
        let height = sourceLinearSRGB.height
        let count = width * height
        var data = [Double](repeating: 0, count: count * 3)
        for i in 0..<(count * 3) { data[i] = Double(sourceLinearSRGB.data[i]) }
        return try renderPrepared(&data, width: width, height: height, recipe: recipe,
                                  analyze: analyze, shouldCancel: shouldCancel)
    }

    /// 导出专用：把源图读进工作缓冲后立刻把源缓冲置空，
    /// 大图在后续滤镜阶段不再多背一张整图（34 MP 下约 400 MB）。
    @discardableResult
    static func renderInPlace(
        _ source: inout ImageRGB,
        recipe: GradeRecipe,
        analyze: Bool = true,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> GradeRenderResult {
        guard source.width > 0, source.height > 0 else {
            return GradeRenderResult(image: source, analysis: .neutral)
        }
        let width = source.width
        let height = source.height
        let count = width * height
        var data = [Double](repeating: 0, count: count * 3)
        source.data.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<(count * 3) { data[i] = Double(base[i]) }
        }
        source = ImageRGB(width: 0, height: 0)
        return try renderPrepared(&data, width: width, height: height, recipe: recipe,
                                  analyze: analyze, shouldCancel: shouldCancel)
    }

    /// 分带调色：整图只保留 Float 成品，工作缓冲按带分配，带与带并行跑。
    ///
    /// 48 MP 的整图 Double 工作缓冲是 1.17 GB，加辅助 Float 图会到 1.6 GB，
    /// 6 GB 机型直接被 jetsam；这里改成逐带读 Double、逐带写回 Float，
    /// 峰值 = 整图 Float + 并发带。带间完全独立（颗粒按带号播种、halo 重叠
    /// 只读未处理的源图），所以直接并发，默认最多 3 条带同时在算。
    /// 局部滤镜按整图短边算半径，靠 `halo` 行重叠保证带与带之间没有接缝；
    /// 暗角 / 色差 / 颗粒用绝对行号，避免每条带各自重新居中。
    @discardableResult
    static func renderTiledInPlace(
        _ image: inout ImageRGB,
        recipe: GradeRecipe,
        bandRows: Int = 512,
        maxConcurrentBands: Int = 3,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> GradeRenderResult {
        guard image.width > 0, image.height > 0 else {
            return GradeRenderResult(image: image, analysis: .neutral)
        }
        let width = image.width
        let height = image.height
        let fullShortEdge = max(1, min(width, height))
        let halo = bandHalo(width: width, height: height, recipe: recipe)
        let rows = max(64, bandRows)
        let (analysis, airlight) = globalStats(image, recipe: recipe)
        // halo 行必须是**未处理**的原始输入：如果直接读回上一条带的成品，
        // 局部滤镜在带边界会看到「已锐化 / 已降噪」与「原始」混在一起的输入，
        // 结果就是每条带的第一行出现一条接缝。因此源图与成品必须各占一份整图
        // Float（48 MP 约 585 MB，已计入 ExportEdge 的 gradePeak 预算）；
        // 成品缓冲显式分配，不靠写回时的隐式 COW 复制。
        let source = image
        var output = ImageRGB(width: width, height: height)

        let bandCount = (height + rows - 1) / rows
        let state = GradeBandState()
        let slots = DispatchSemaphore(value: max(1, min(maxConcurrentBands, bandCount)))
        let queue = DispatchQueue(label: "spektra.grade.bands", attributes: .concurrent)
        let group = DispatchGroup()
        // 指针只在 withUnsafe… 作用域内有效：提交与等待都写在作用域内部，
        // 数组在整个并发段里没有结构变更，基址稳定，各带只写互不重叠的行段。
        source.data.withUnsafeBufferPointer { srcRaw in
            output.data.withUnsafeMutableBufferPointer { dstRaw in
                guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
                for bandIndex in 0..<bandCount {
                    if state.cancelled { break }
                    group.enter()
                    slots.wait()
                    queue.async {
                        defer { slots.signal(); group.leave() }
                        if state.cancelled { return }
                        if shouldCancel?() == true { state.markCancelled(); return }
                        let top = bandIndex * rows
                        let coreRows = min(rows, height - top)
                        let bandTop = max(0, top - halo)
                        let bandBottom = min(height, top + coreRows + halo)
                        let bandHeight = bandBottom - bandTop
                        let count = width * bandHeight
                        var data = [Double](repeating: 0, count: count * 3)
                        data.withUnsafeMutableBufferPointer { destination in
                            guard let out = destination.baseAddress else { return }
                            let start = bandTop * width * 3
                            for i in 0..<(count * 3) { out[i] = Double(src[start + i]) }
                        }

                        applyExposureWB(&data, count: count,
                                        exposure: recipe.light.exposure,
                                        temperature: recipe.color.temperature,
                                        tint: recipe.color.tint)
                        srgbEncode(&data, count: count)
                        applyTone(&data, width: width, height: bandHeight, light: recipe.light)
                        applyColor(&data, count: count, color: recipe.color)
                        applyTransparency(&data, count: count, recipe: recipe.transparency,
                                          analysis: analysis)
                        applyClarityStructure(&data, width: width, height: bandHeight,
                                              quality: recipe.quality, fullShortEdge: fullShortEdge)
                        applyDehaze(&data, width: width, height: bandHeight,
                                    amount: recipe.quality.dehaze, fullShortEdge: fullShortEdge,
                                    airlight: airlight)
                        applyNoiseReduction(&data, width: width, height: bandHeight,
                                            quality: recipe.quality, fullShortEdge: fullShortEdge)
                        applySharpening(&data, width: width, height: bandHeight,
                                        quality: recipe.quality, fullShortEdge: fullShortEdge)
                        applyOptics(&data, width: width, height: bandHeight,
                                    optics: recipe.optics,
                                    rowOffset: bandTop, fullHeight: height,
                                    fullShortEdge: fullShortEdge,
                                    seed: 20240101 &+ UInt64(bandIndex &* 7919),
                                    banded: true)
                        let lutError = applyLUT(&data, count: count, path: recipe.lut.path,
                                                strength: recipe.lut.strength)
                        postprocess(&data)
                        if let lutError { state.recordLUTError(lutError); return }

                        let coreStart = top - bandTop
                        data.withUnsafeBufferPointer { band in
                            guard let bandBase = band.baseAddress else { return }
                            let rowsToCopy = coreRows * width * 3
                            let srcOffset = coreStart * width * 3
                            let dstOffset = top * width * 3
                            for i in 0..<rowsToCopy { dst[dstOffset + i] = Float(band[srcOffset + i]) }
                        }
                    }
                }
                group.wait()
            }
        }
        if state.cancelled { throw GradeCancelled.cancelled }
        if let lutError = state.lutError {
            image = ImageRGB(width: 0, height: 0)
            return GradeRenderResult(image: ImageRGB(width: 0, height: 0),
                                     analysis: analysis, lutError: lutError)
        }
        image = ImageRGB(width: 0, height: 0)
        return GradeRenderResult(image: output, analysis: analysis)
    }

    /// 分带调色需要向上下多读的行数：覆盖所有局部滤镜的最大半径。
    private static func bandHalo(width: Int, height: Int, recipe: GradeRecipe) -> Int {
        let shortEdge = Double(max(1, min(width, height)))
        var radius = 0.0
        let quality = recipe.quality
        if abs(quality.clarity) > 1e-6 || abs(quality.texture) > 1e-6 {
            radius = max(radius, shortEdge * 0.008)
        }
        if quality.dehaze > 1e-6 {
            let window = max(3.0, (shortEdge * 0.02).rounded())
            radius = max(radius, window / 2)
        }
        if quality.noiseLuminance > 1e-6 || quality.noiseColor > 1e-6 {
            radius = max(radius, shortEdge * 0.0025)
        }
        if quality.sharpenAmount > 1e-6 {
            let scale = max(0.6, min(2.0, shortEdge / 1080))
            radius = max(radius, quality.sharpenRadius * scale * 2.6)
        }
        if recipe.optics.grainAmount > 1e-6 {
            let scale = max(0.6, min(3.0, shortEdge / 1080))
            radius = max(radius, (0.6 + recipe.optics.grainSize / 100 * 3.0) * scale)
        }
        if recipe.optics.chromaticAberration > 1e-6 {
            radius = max(radius, Double(max(width, height)) * 0.004 / 2)
        }
        return max(16, Int(ceil(radius)) + 12)
    }

    /// 全局统计只取 1200 长边代理图，保证每条带用同一份黑场 / 白场 / 空气光。
    private static func globalStats(
        _ image: ImageRGB, recipe: GradeRecipe
    ) -> (ToneAnalysis, Double) {
        let proxy = Resize.longEdge(image, maxSize: 1200)
        var data = [Double](repeating: 0, count: proxy.width * proxy.height * 3)
        proxy.data.withUnsafeBufferPointer { source in
            data.withUnsafeMutableBufferPointer { destination in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
                for i in 0..<(proxy.width * proxy.height * 3) { dst[i] = Double(src[i]) }
            }
        }
        let count = proxy.width * proxy.height
        applyExposureWB(&data, count: count,
                        exposure: recipe.light.exposure,
                        temperature: recipe.color.temperature,
                        tint: recipe.color.tint)
        srgbEncode(&data, count: count)
        applyTone(&data, width: proxy.width, height: proxy.height, light: recipe.light)
        applyColor(&data, count: count, color: recipe.color)
        let analysis = analyzeTone(data, width: proxy.width, height: proxy.height)
        guard recipe.quality.dehaze > 1e-6 else { return (analysis, 0) }
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count { samples[i] = Float(luma(data, i)) }
        return (analysis, max(percentile(samples, 99), 0.30))
    }

    private static func renderPrepared(
        _ data: inout [Double],
        width: Int,
        height: Int,
        recipe: GradeRecipe,
        analyze: Bool,
        shouldCancel: (() -> Bool)?
    ) throws -> GradeRenderResult {
        let count = width * height

        func checkCancel() throws {
            if shouldCancel?() == true { throw GradeCancelled.cancelled }
        }

        try checkCancel()
        applyExposureWB(&data, count: count,
                        exposure: recipe.light.exposure,
                        temperature: recipe.color.temperature,
                        tint: recipe.color.tint)
        srgbEncode(&data, count: count)
        try checkCancel()
        applyTone(&data, width: width, height: height, light: recipe.light)
        try checkCancel()
        applyColor(&data, count: count, color: recipe.color)
        let analysis = analyze
            ? analyzeTone(data, width: width, height: height)
            : ToneAnalysis.neutral
        try checkCancel()
        applyTransparency(&data, count: count, recipe: recipe.transparency, analysis: analysis)
        applyClarityStructure(&data, width: width, height: height, quality: recipe.quality)
        try checkCancel()
        applyDehaze(&data, width: width, height: height, amount: recipe.quality.dehaze)
        applyNoiseReduction(&data, width: width, height: height, quality: recipe.quality)
        try checkCancel()
        applySharpening(&data, width: width, height: height, quality: recipe.quality)
        applyOptics(&data, width: width, height: height, optics: recipe.optics)
        try checkCancel()
        let lutError = applyLUT(&data, count: count, path: recipe.lut.path, strength: recipe.lut.strength)

        postprocess(&data)
        return GradeRenderResult(
            image: ImageRGB(width: width, height: height, data: data),
            analysis: analysis,
            lutError: lutError
        )
    }

    // MARK: - 基础工具

    private static func luma(_ data: [Double], _ index: Int) -> Double {
        data[index * 3] * lumaR + data[index * 3 + 1] * lumaG + data[index * 3 + 2] * lumaB
    }

    private static func srgbEncode(_ data: inout [Double], count: Int) {
        for i in 0..<(count * 3) {
            let value = data[i]
            let positive = max(value, 0)
            let encoded = positive <= 0.0031308
                ? positive * 12.92
                : 1.055 * pow(positive, 1.0 / 2.4) - 0.055
            data[i] = encoded
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        if edge1 <= edge0 { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func boxBlur(_ values: [Float], width: Int, height: Int,
                                radius: Double) -> [Float] {
        guard width > 0, height > 0 else { return values }
        let size = max(3, Int((radius * 2).rounded()) | 1)
        let half = size / 2
        var horizontal = [Float](repeating: 0, count: values.count)
        var prefix = [Double](repeating: 0, count: max(width, height) + 1)

        for y in 0..<height {
            let row = y * width
            prefix[0] = 0
            for x in 0..<width {
                prefix[x + 1] = prefix[x] + Double(values[row + x])
            }
            for x in 0..<width {
                let low = max(0, x - half)
                let high = min(width - 1, x + half)
                horizontal[row + x] = Float((prefix[high + 1] - prefix[low]) / Double(high - low + 1))
            }
        }

        var output = [Float](repeating: 0, count: values.count)
        for x in 0..<width {
            prefix[0] = 0
            for y in 0..<height {
                prefix[y + 1] = prefix[y] + Double(horizontal[y * width + x])
            }
            for y in 0..<height {
                let low = max(0, y - half)
                let high = min(height - 1, y + half)
                output[y * width + x] = Float((prefix[high + 1] - prefix[low]) / Double(high - low + 1))
            }
        }
        return output
    }

    private static func minimumFilter(_ values: [Float], width: Int, height: Int,
                                      size: Int) -> [Float] {
        let half = max(1, size / 2)
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var value = Float.greatestFiniteMagnitude
                for k in max(0, x - half)...min(width - 1, x + half) {
                    value = min(value, values[row + k])
                }
                horizontal[row + x] = value
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        for x in 0..<width {
            for y in 0..<height {
                var value = Float.greatestFiniteMagnitude
                for k in max(0, y - half)...min(height - 1, y + half) {
                    value = min(value, horizontal[k * width + x])
                }
                output[y * width + x] = value
            }
        }
        return output
    }

    private static func percentile(_ values: [Double], _ percent: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * percent / 100
        let low = Int(floor(position))
        let high = min(low + 1, sorted.count - 1)
        let fraction = position - Double(low)
        return sorted[low] * (1 - fraction) + sorted[high] * fraction
    }

    private static func percentile(_ values: [Float], _ percent: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * percent / 100
        let low = Int(floor(position))
        let high = min(low + 1, sorted.count - 1)
        let fraction = position - Double(low)
        return Double(sorted[low]) * (1 - fraction) + Double(sorted[high]) * fraction
    }

    private static func postprocess(_ data: inout [Double]) {
        for i in 0..<data.count {
            let value = data[i]
            if !value.isFinite {
                data[i] = value < 0 ? 0 : (value > 0 ? 1 : 0)
            } else {
                data[i] = min(max(value, 0), 1)
            }
        }
    }

    // MARK: - 影调

    private static func applyExposureWB(
        _ data: inout [Double], count: Int,
        exposure: Double, temperature: Double, tint: Double
    ) {
        guard abs(exposure) > 1e-6 || abs(temperature) > 1e-6 || abs(tint) > 1e-6 else { return }
        let exposureGain = abs(exposure) > 1e-6 ? pow(2.0, exposure) : 1
        let temp = temperature / 100
        let tnt = tint / 100
        let redGain = pow(2.0, 0.35 * temp + 0.12 * tnt)
        let greenGain = pow(2.0, -0.30 * tnt)
        let blueGain = pow(2.0, -0.35 * temp + 0.12 * tnt)
        for i in 0..<count {
            data[i * 3] *= exposureGain * redGain
            data[i * 3 + 1] *= exposureGain * greenGain
            data[i * 3 + 2] *= exposureGain * blueGain
        }
    }

    private static func applyContrast(_ data: inout [Double], count: Int, contrast: Double) {
        guard abs(contrast) > 1e-6 else { return }
        let strength = pow(2.0, 1.25 * contrast / 100)
        for i in 0..<(count * 3) {
            let p = min(max(data[i], 0), 1)
            if p < 0.5 {
                let lowInput = max(2 * p, 0)
                data[i] = 0.5 * pow(lowInput, strength)
            } else {
                let highInput = max(2 * (1 - p), 0)
                data[i] = 1 - 0.5 * pow(highInput, strength)
            }
        }
    }

    /// 影调分区权重表。旧实现把五个区都压在中灰附近，且白/黑区权重最高只有 0.03，
    /// 导致滑块几乎不可见；这里改为每个区各自的连续钟形权重，并把黑/白场真正落到端点。
    /// 与 Swift 主线 `3f21e0c` 一致。
    private static func toneMaskTable(center: Double, width: Double, gateDark: Bool) -> [Double] {
        let steps = 512
        var table = [Double](repeating: 0, count: steps + 1)
        for index in 0...steps {
            let y = Double(index) / Double(steps)
            let z = (y - center) / width
            var value = exp(-0.5 * z * z)
            if gateDark { value *= smoothstep(0.0, 0.07, y) }
            table[index] = value
        }
        return table
    }

    private static func sampleMask(_ table: [Double], _ y: Double) -> Double {
        // luma 传播 NaN 时 Int(position) 会直接运行时崩溃；非有限像素跳过影调即可，
        // 最终仍由 postprocess 统一清洗。
        guard !table.isEmpty, y.isFinite else { return 0 }
        let position = y * Double(table.count - 1)
        let low = Int(position)
        if low >= table.count - 1 { return table[table.count - 1] }
        let fraction = position - Double(low)
        return table[low] * (1 - fraction) + table[low + 1] * fraction
    }

    private static func applyToneMasks(_ data: inout [Double], count: Int, light: LightRecipe) {
        let shadows = light.shadows
        let blacks = light.blacks
        let highlights = light.highlights
        let whites = light.whites
        let midtones = light.midtones
        let hasShadows = abs(shadows) > 1e-6
        let hasBlacks = abs(blacks) > 1e-6
        let hasHighlights = abs(highlights) > 1e-6
        let hasWhites = abs(whites) > 1e-6
        let hasMidtones = abs(midtones) > 1e-6
        guard hasShadows || hasBlacks || hasHighlights || hasWhites || hasMidtones else {
            return
        }

        let shadowTable = hasShadows
            ? toneMaskTable(center: 0.26, width: 0.19, gateDark: true) : []
        let highlightTable = hasHighlights
            ? toneMaskTable(center: 0.74, width: 0.18, gateDark: false) : []
        let midtoneTable = hasMidtones
            ? toneMaskTable(center: 0.47, width: 0.20, gateDark: false) : []

        for i in 0..<count {
            let y = min(max(luma(data, i), 0), 1)
            var delta = 0.0
            if hasShadows {
                delta += shadows / 100 * 0.28 * sampleMask(shadowTable, y)
            }
            if hasBlacks {
                // 黑场是端点控制：从纯黑一路铺到约 0.6，而不是只擦最暗的 13% 像素。
                // 旧的高斯钟形让 +100 也只抬 0.09 L，看似「完全没反应」。
                delta += blacks / 100 * 0.24 * (1 - smoothstep(0.05, 0.60, y))
            }
            if hasHighlights {
                delta += highlights / 100 * 0.26 * sampleMask(highlightTable, y)
            }
            if hasWhites {
                // 白场同理：从约 0.4 开始抬升，避开「正向被 1.0 截断吃掉」的区间。
                delta += whites / 100 * 0.24 * smoothstep(0.40, 0.95, y)
            }
            if hasMidtones {
                delta += midtones / 100 * 0.16 * sampleMask(midtoneTable, y)
            }
            data[i * 3] += delta
            data[i * 3 + 1] += delta
            data[i * 3 + 2] += delta
        }
    }

    private static func applyHighlightRolloff(_ data: inout [Double], count: Int,
                                              rolloff: Double) {
        guard rolloff > 1e-6 else { return }
        let strength = rolloff / 100 * 1.5
        for i in 0..<(count * 3) {
            let over = max(data[i] - 0.55, 0)
            data[i] -= strength * over * over
        }
    }

    /// 点曲线：四个分段量是 0…1 输入域上的偏移，在 6 个节点间做单调三次插值（PCHIP）后逐通道查表。
    /// 旧实现把四段钟形权重相加，S 形拖动会在中灰附近互相抵消甚至反相，
    /// 表现为「拖了曲线但画面不动 / 中间调被拉灰」。
    private static func applyParametricCurve(_ data: inout [Double], count: Int,
                                             light: LightRecipe) {
        let amounts: [Double] = [
            0,
            light.curveShadows,
            light.curveDarks,
            light.curveLights,
            light.curveHighlights,
            0,
        ]
        guard amounts.contains(where: { abs($0) > 1e-6 }) else { return }

        let xs: [Double] = [0, 0.12, 0.35, 0.62, 0.88, 1]
        var ys = zip(xs, amounts).map { min(max($0 + $1 / 100, 0), 1) }
        // 端点固定，避免把纯黑/纯白整段压扁。
        ys[0] = 0
        ys[ys.count - 1] = 1

        let slopes = monotoneSlopes(xs: xs, ys: ys)
        let steps = 1024
        var lookup = [Double](repeating: 0, count: steps)
        for index in 0..<steps {
            let x = Double(index) / Double(steps - 1)
            var segment = xs.count - 2
            for i in 0..<(xs.count - 1) where x <= xs[i + 1] {
                segment = i
                break
            }
            let h = xs[segment + 1] - xs[segment]
            let t = h > 1e-9 ? min(max((x - xs[segment]) / h, 0), 1) : 0
            let t2 = t * t
            let t3 = t2 * t
            let value = (2 * t3 - 3 * t2 + 1) * ys[segment]
                + (t3 - 2 * t2 + t) * h * slopes[segment]
                + (-2 * t3 + 3 * t2) * ys[segment + 1]
                + (t3 - t2) * h * slopes[segment + 1]
            lookup[index] = min(max(value, 0), 1)
        }

        for i in 0..<(count * 3) {
            let position = min(max(data[i], 0), 1) * Double(steps - 1)
            let low = Int(position)
            if low >= steps - 1 {
                data[i] = lookup[steps - 1]
            } else {
                let fraction = position - Double(low)
                data[i] = lookup[low] * (1 - fraction) + lookup[low + 1] * fraction
            }
        }
    }

    /// Fritsch–Carlson 单调斜率：保证插值曲线不会在两个节点之间反向回头。
    private static func monotoneSlopes(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = xs[i + 1] - xs[i]
            delta[i] = h[i] > 1e-9 ? (ys[i + 1] - ys[i]) / h[i] : 0
        }
        var slopes = [Double](repeating: 0, count: n)
        slopes[0] = delta[0]
        slopes[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            slopes[i] = delta[i - 1] * delta[i] <= 0
                ? 0
                : (delta[i - 1] + delta[i]) / 2
        }
        for i in 0..<(n - 1) where abs(delta[i]) > 1e-9 {
            let alpha = slopes[i] / delta[i]
            let beta = slopes[i + 1] / delta[i]
            let radius = alpha * alpha + beta * beta
            if radius > 9 {
                let tau = 3 / radius.squareRoot()
                slopes[i] = tau * alpha * delta[i]
                slopes[i + 1] = tau * beta * delta[i]
            }
        }
        return slopes
    }

    private static func applyTone(_ data: inout [Double], width: Int, height: Int,
                                  light: LightRecipe) {
        let count = width * height
        applyContrast(&data, count: count, contrast: light.contrast)
        applyToneMasks(&data, count: count, light: light)
        applyHighlightRolloff(&data, count: count, rolloff: light.highlightRolloff)
        applyParametricCurve(&data, count: count, light: light)
    }

    // MARK: - HSV

    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let red = min(max(r, 0), 1)
        let green = min(max(g, 0), 1)
        let blue = min(max(b, 0), 1)
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 1e-12 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
                if hue < 0 { hue += 6 }
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
        }
        let saturation = maximum > 1e-12 ? delta / maximum : 0
        return (hue, saturation, maximum)
    }

    private static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        if s <= 1e-12 { return (v, v, v) }
        let hue = (h * 6).truncatingRemainder(dividingBy: 6)
        let index = Int(floor(hue))
        let fraction = hue - Double(index)
        let p = v * (1 - s)
        let q = v * (1 - s * fraction)
        let t = v * (1 - s * (1 - fraction))
        switch index % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    private static func hueChroma(_ hueDegrees: Double) -> Vec3 {
        let (r, g, b) = hsvToRGB((hueDegrees / 360).truncatingRemainder(dividingBy: 1), 1, 1)
        let mean = (r + g + b) / 3
        var vector = Vec3(r - mean, g - mean, b - mean)
        let scale = max(abs(vector.x), abs(vector.y), abs(vector.z))
        if scale > 1e-12 {
            vector = Vec3(vector.x / scale, vector.y / scale, vector.z / scale)
        }
        return vector
    }

    // MARK: - 色彩

    private static func applySaturation(_ data: inout [Double], count: Int,
                                       color: ColorRecipe) {
        let saturation = color.saturation
        let vibrance = color.vibrance
        let density = color.colorDensity
        guard abs(saturation) > 1e-6 || abs(vibrance) > 1e-6 || density > 1e-6 else { return }
        for i in 0..<count {
            let r = data[i * 3]
            let g = data[i * 3 + 1]
            let b = data[i * 3 + 2]
            let y = luma(data, i)
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let pixelSaturation = maximum > 1e-4 ? (maximum - minimum) / maximum : 0
            let vibFactor = 1 + vibrance / 100 * pow(max(1 - pixelSaturation, 0), 1.25)
            var factor = (1 + saturation / 100) * vibFactor
            factor *= 1 + density / 100 * 0.5
            factor = max(factor, 0)
            data[i * 3] = y + (r - y) * factor
            data[i * 3 + 1] = y + (g - y) * factor
            data[i * 3 + 2] = y + (b - y) * factor
        }
    }

    private static func applyHueShift(_ data: inout [Double], count: Int, shift: Double) {
        guard abs(shift) > 1e-6 else { return }
        for i in 0..<count {
            var (h, s, v) = rgbToHSV(data[i * 3], data[i * 3 + 1], data[i * 3 + 2])
            h = (h + shift / 360).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            let (r, g, b) = hsvToRGB(h, s, v)
            data[i * 3] = r
            data[i * 3 + 1] = g
            data[i * 3 + 2] = b
        }
    }

    private static func applyHslBands(_ data: inout [Double], count: Int,
                                      color: ColorRecipe) {
        let bands = Array(color.hsl.prefix(8))
        guard !bands.isEmpty, bands.contains(where: {
            abs($0.hue) > 1e-6 || abs($0.saturation) > 1e-6 || abs($0.luminance) > 1e-6
        }) else { return }
        let centers = GradeRecipeConstants.hslBandHues
        let sigma = 24.0
        for i in 0..<count {
            var (hue, saturation, value) = rgbToHSV(
                data[i * 3], data[i * 3 + 1], data[i * 3 + 2]
            )
            let hueDegrees = hue * 360
            var weights = [Double](repeating: 0, count: bands.count)
            var hueDelta = 0.0
            var saturationFactor = 0.0
            var luminanceDelta = 0.0
            for index in 0..<bands.count {
                let band = bands[index]
                var delta = (hueDegrees - centers[index] + 180).truncatingRemainder(dividingBy: 360)
                if delta < 0 { delta += 360 }
                delta -= 180
                let weight = exp(-0.5 * pow(delta / sigma, 2))
                weights[index] = weight
                hueDelta += weight * (band.hue / 100 * 30)
                saturationFactor += weight * (band.saturation / 100 * 0.5)
                luminanceDelta += weight * (band.luminance / 100 * 0.15)
            }
            let total = max(weights.reduce(0, +), 1e-6)
            hue = (hueDegrees + hueDelta / total).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            hue /= 360
            saturation = min(max(saturation * (1 + saturationFactor / total), 0), 1)
            value = min(max(value + luminanceDelta / total, 0), 1)
            let (r, g, b) = hsvToRGB(hue, saturation, value)
            data[i * 3] = r
            data[i * 3 + 1] = g
            data[i * 3 + 2] = b
        }
    }

    private static func applyColorGrading(_ data: inout [Double], count: Int,
                                          color: ColorRecipe) {
        let grading = color.grading
        let zones = [grading.shadows, grading.midtones, grading.highlights]
        guard zones.contains(where: { abs($0.saturation) > 1e-6 || abs($0.luminance) > 1e-6 })
        else { return }
        let balance = grading.balance / 100
        let spread = 0.16 + 0.16 * grading.blending / 100
        let centers = [0.18 - 0.04 * balance, 0.50 + 0.02 * balance, 0.82 + 0.04 * balance]
        let sigmas = [spread, spread * 0.9, spread]
        let chromas = zones.map { hueChroma($0.hue) }
        for i in 0..<count {
            let y = luma(data, i)
            for index in 0..<3 {
                let zone = zones[index]
                let mask = exp(-0.5 * pow((y - centers[index]) / sigmas[index], 2))
                if abs(zone.saturation) > 1e-6 {
                    let chroma = chromas[index] * (zone.saturation / 100 * 0.12)
                    data[i * 3] += chroma.x * mask
                    data[i * 3 + 1] += chroma.y * mask
                    data[i * 3 + 2] += chroma.z * mask
                }
                if abs(zone.luminance) > 1e-6 {
                    let delta = zone.luminance / 100 * 0.08 * mask
                    data[i * 3] += delta
                    data[i * 3 + 1] += delta
                    data[i * 3 + 2] += delta
                }
            }
        }
    }

    private static func applyColor(_ data: inout [Double], count: Int, color: ColorRecipe) {
        applySaturation(&data, count: count, color: color)
        applyHueShift(&data, count: count, shift: color.hueShift)
        applyHslBands(&data, count: count, color: color)
        applyColorGrading(&data, count: count, color: color)
    }

    // MARK: - 通透

    static func analyzeTone(_ data: [Double], width: Int, height: Int) -> ToneAnalysis {
        let count = width * height
        guard count > 0 else { return .neutral }
        let step = max(1, Int(sqrt(Double(count) / 200_000.0)))
        var samples: [Double] = []
        samples.reserveCapacity((count / step) + 1)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                samples.append(luma(data, y * width + x))
                x += step
            }
            y += step
        }
        let black = percentile(samples, transparencyEdgePercent)
        let shadowCut = percentile(samples, 10)
        let highlightCut = percentile(samples, 90)
        var white = percentile(samples, 100 - transparencyEdgePercent)
        if white <= black { white = min(1, black + 0.06) }

        var shadowRGB = Vec3(0, 0, 0)
        var shadowCount = 0
        var highlightRGB = Vec3(0, 0, 0)
        var highlightCount = 0
        for i in 0..<count {
            let lumaValue = luma(data, i)
            if lumaValue <= shadowCut {
                shadowRGB = shadowRGB + Vec3(data[i * 3], data[i * 3 + 1], data[i * 3 + 2])
                shadowCount += 1
            }
            if lumaValue >= highlightCut {
                highlightRGB = highlightRGB + Vec3(data[i * 3], data[i * 3 + 1], data[i * 3 + 2])
                highlightCount += 1
            }
        }
        if shadowCount == 0 { shadowRGB = Vec3(0, 0, 0); shadowCount = count }
        if highlightCount == 0 { highlightRGB = Vec3(0, 0, 0); highlightCount = count }
        shadowRGB = shadowRGB / Double(max(shadowCount, 1))
        highlightRGB = highlightRGB / Double(max(highlightCount, 1))

        let shadowCast = castName(shadowRGB)
        let highlightCast = castName(highlightRGB)
        let summary = String(
            format: "黑场 %.1f%% · 白场 %.1f%% · 高光%@ · 阴影%@",
            black * 100, white * 100, highlightCast, shadowCast
        )
        return ToneAnalysis(
            blackPoint: black, whitePoint: white,
            highlightRGB: highlightRGB, shadowRGB: shadowRGB,
            highlightCast: highlightCast, shadowCast: shadowCast, summary: summary
        )
    }

    private static func castName(_ rgb: Vec3) -> String {
        let mean = (rgb.x + rgb.y + rgb.z) / 3
        let deviation = (rgb.x - mean, rgb.y - mean, rgb.z - mean)
        if max(abs(deviation.0), abs(deviation.1), abs(deviation.2)) < 0.015 { return "中性" }
        let redHigh = deviation.0 > 0.015
        let greenHigh = deviation.1 > 0.015
        let blueHigh = deviation.2 > 0.015
        let redLow = deviation.0 < -0.015
        let greenLow = deviation.1 < -0.015
        let blueLow = deviation.2 < -0.015
        if redHigh && greenHigh && blueLow { return "偏黄" }
        if redHigh && blueHigh && greenLow { return "偏品红" }
        if greenHigh && blueHigh && redLow { return "偏青" }
        if redHigh && greenLow && blueLow { return "偏红" }
        if greenHigh && redLow && blueLow { return "偏绿" }
        if blueHigh && redLow && greenLow { return "偏蓝" }
        return "偏色"
    }

    private static func applyTransparency(
        _ data: inout [Double], count: Int,
        recipe: TransparencyRecipe, analysis: ToneAnalysis
    ) {
        let tonal = recipe.tonal / 100
        if tonal > 1e-6 {
            let span = max(analysis.whitePoint - analysis.blackPoint, 0.06)
            for i in 0..<(count * 3) {
                let leveled = min(max((data[i] - analysis.blackPoint) / span, 0), 1)
                data[i] = data[i] * (1 - tonal) + leveled * tonal
            }
        }

        let colorAmount = recipe.color / 100
        guard colorAmount > 1e-6 else { return }
        let highlightMean = (analysis.highlightRGB.x + analysis.highlightRGB.y
            + analysis.highlightRGB.z) / 3
        let shadowMean = (analysis.shadowRGB.x + analysis.shadowRGB.y
            + analysis.shadowRGB.z) / 3
        let whiteDelta = Vec3(
            min(max(-(analysis.highlightRGB.x - highlightMean), -0.05), 0.05),
            min(max(-(analysis.highlightRGB.y - highlightMean), -0.05), 0.05),
            min(max(-(analysis.highlightRGB.z - highlightMean), -0.05), 0.05)
        )
        let blackDelta = Vec3(
            min(max(-(analysis.shadowRGB.x - shadowMean), -0.05), 0.05),
            min(max(-(analysis.shadowRGB.y - shadowMean), -0.05), 0.05),
            min(max(-(analysis.shadowRGB.z - shadowMean), -0.05), 0.05)
        )
        for i in 0..<count {
            let y = luma(data, i)
            let whiteMask = smoothstep(0.52, 0.96, y)
            let blackMask = 1 - smoothstep(0.06, 0.34, y)
            data[i * 3] += whiteDelta.x * whiteMask * colorAmount
                + blackDelta.x * blackMask * colorAmount
            data[i * 3 + 1] += whiteDelta.y * whiteMask * colorAmount
                + blackDelta.y * blackMask * colorAmount
            data[i * 3 + 2] += whiteDelta.z * whiteMask * colorAmount
                + blackDelta.z * blackMask * colorAmount
        }
    }

    // MARK: - 画质

    private static func coreDetailInPlace(_ detail: inout [Float], threshold: Double) {
        let squaredThreshold = threshold * threshold
        for i in 0..<detail.count {
            let value = Double(detail[i])
            let squared = value * value
            detail[i] = Float(value * squared / (squared + squaredThreshold))
        }
    }

    private static func applyClarityStructure(
        _ data: inout [Double], width: Int, height: Int, quality: QualityRecipe,
        fullShortEdge: Int? = nil
    ) {
        let clarity = quality.clarity
        let texture = quality.texture
        guard abs(clarity) > 1e-6 || abs(texture) > 1e-6 else { return }
        let count = width * height
        // 分带时按整图短边算半径，否则条带的短边会让清晰度半径和整图不一致。
        let shortEdge = fullShortEdge ?? max(1, min(width, height))
        var logLuma = [Float](repeating: 0, count: count)
        for i in 0..<count {
            logLuma[i] = Float(log2(max(luma(data, i), 1e-4)))
        }
        let steps: [(Double, Double, Double)] = [
            (clarity, 0.008, 0.35),
            (texture, 0.003, 0.25),
        ]
        for (amount, ratio, sigma) in steps where abs(amount) > 1e-6 {
            let radius = max(1, Double(shortEdge) * ratio)
            let base = boxBlur(logLuma, width: width, height: height, radius: radius)
            for i in 0..<count {
                let detail = Double(logLuma[i]) - Double(base[i])
                let shaped = detail / (1 + pow(detail / sigma, 2))
                let gain = pow(2.0, amount / 100 * 0.5 * shaped)
                data[i * 3] *= gain
                data[i * 3 + 1] *= gain
                data[i * 3 + 2] *= gain
            }
        }
    }

    private static func applyDehaze(_ data: inout [Double], width: Int, height: Int,
                                   amount: Double, fullShortEdge: Int? = nil,
                                   airlight airlightOverride: Double? = nil) {
        guard abs(amount) > 1e-6 else { return }
        let count = width * height
        if amount < 0 {
            let strength = min(1, abs(amount) / 100)
            for i in 0..<(count * 3) {
                data[i] = data[i] * (1 - 0.25 * strength) + 0.18 * strength
            }
            return
        }
        let strength = 1 - pow(1 - amount / 100, 2)
        let shortEdge = fullShortEdge ?? max(1, min(width, height))
        var dark = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let minimum = min(min(data[i * 3], data[i * 3 + 1]), data[i * 3 + 2])
            dark[i] = Float(minimum)
        }
        let window = max(3, Int((Double(shortEdge) * 0.02).rounded()) | 1)
        let darkSmooth = minimumFilter(dark, width: width, height: height, size: window)
        // 分带时空气光由调用方从整图代理统一算好，避免每条带各算一份出现亮度台阶。
        let airlight: Double
        if let airlightOverride {
            airlight = airlightOverride
        } else {
            var lumaSamples = [Float](repeating: 0, count: count)
            for i in 0..<count { lumaSamples[i] = Float(luma(data, i)) }
            airlight = max(percentile(lumaSamples, 99), 0.30)
        }
        for i in 0..<count {
            let transmission = min(max(
                1 - strength * 0.95 * Double(darkSmooth[i]) / max(airlight, 0.1), 0.1
            ), 1)
            data[i * 3] = airlight + (data[i * 3] - airlight) / transmission
            data[i * 3 + 1] = airlight + (data[i * 3 + 1] - airlight) / transmission
            data[i * 3 + 2] = airlight + (data[i * 3 + 2] - airlight) / transmission
        }
    }

    private static func applyNoiseReduction(
        _ data: inout [Double], width: Int, height: Int, quality: QualityRecipe,
        fullShortEdge: Int? = nil
    ) {
        let luminance = quality.noiseLuminance / 100
        let chroma = quality.noiseColor / 100
        guard luminance > 1e-6 || chroma > 1e-6 else { return }
        let count = width * height
        let shortEdge = fullShortEdge ?? max(1, min(width, height))
        if luminance > 1e-6 {
            var y = [Float](repeating: 0, count: count)
            for i in 0..<count { y[i] = Float(luma(data, i)) }
            let smooth = boxBlur(y, width: width, height: height,
                                 radius: max(0.8, Double(shortEdge) * 0.0015))
            for i in 0..<count {
                let delta = (Double(smooth[i]) - Double(y[i])) * (luminance * 0.85)
                data[i * 3] += delta
                data[i * 3 + 1] += delta
                data[i * 3 + 2] += delta
            }
        }
        if chroma > 1e-6 {
            var cr = [Float](repeating: 0, count: count)
            var cb = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let y = luma(data, i)
                cr[i] = Float(data[i * 3] - y)
                cb[i] = Float(data[i * 3 + 2] - y)
            }
            let radius = max(1, Double(shortEdge) * 0.0025)
            let crSmooth = boxBlur(cr, width: width, height: height, radius: radius)
            for i in 0..<count {
                data[i * 3] += (Double(crSmooth[i]) - Double(cr[i])) * (chroma * 0.85)
            }
            let cbSmooth = boxBlur(cb, width: width, height: height, radius: radius)
            for i in 0..<count {
                data[i * 3 + 2] += (Double(cbSmooth[i]) - Double(cb[i])) * (chroma * 0.85)
            }
        }
    }

    private static func applySharpening(
        _ data: inout [Double], width: Int, height: Int, quality: QualityRecipe,
        fullShortEdge: Int? = nil
    ) {
        let amount = quality.sharpenAmount / 100
        guard amount > 1e-6 else { return }
        let count = width * height
        let shortEdge = fullShortEdge ?? max(1, min(width, height))
        let scale = max(0.6, min(2.0, Double(shortEdge) / 1080))
        let radius = quality.sharpenRadius * scale
        var y = [Float](repeating: 0, count: count)
        for i in 0..<count { y[i] = Float(luma(data, i)) }
        let blurOne = boxBlur(y, width: width, height: height,
                              radius: max(0.6, radius * 0.9))
        let blurWide = boxBlur(y, width: width, height: height,
                               radius: max(1.2, radius * 2.6))
        let threshold = 0.002 + quality.sharpenThreshold / 100 * 0.06
        var detail = [Float](repeating: 0, count: count)
        for i in 0..<count { detail[i] = y[i] - blurOne[i] }
        coreDetailInPlace(&detail, threshold: threshold)
        var wide = [Float](repeating: 0, count: count)
        for i in 0..<count { wide[i] = blurOne[i] - blurWide[i] }
        coreDetailInPlace(&wide, threshold: threshold)
        for i in 0..<count {
            let delta = (Double(detail[i]) + 0.5 * Double(wide[i])) * (amount * 2)
            data[i * 3] += delta
            data[i * 3 + 1] += delta
            data[i * 3 + 2] += delta
        }
    }

    // MARK: - 光学

    private static func applyVignette(_ data: inout [Double], width: Int, height: Int,
                                      optics: OpticsRecipe,
                                      rowOffset: Int = 0, fullHeight: Int? = nil) {
        let amount = optics.vignetteAmount / 100
        guard abs(amount) > 1e-6 else { return }
        let roundness = optics.vignetteRoundness / 100
        let midpoint = 0.20 + optics.vignetteMidpoint / 100 * 1.10
        let feather = max(0.05, optics.vignetteFeather / 100)
        let halfWidth = max(Double(width) / 2, 1)
        // 分带时暗角必须按整图中心算，否则每条带都会重新居中，出现明暗台阶。
        let centerY = Double(fullHeight ?? height) / 2
        let halfHeight = max(Double(fullHeight ?? height) / 2, 1)
        for y in 0..<height {
            let ny = (Double(y + rowOffset) - centerY) / halfHeight * (1 - 0.25 * roundness)
            for x in 0..<width {
                let nx = (Double(x) - Double(width) / 2) / halfWidth * (1 + 0.25 * roundness)
                let radius = sqrt(nx * nx + ny * ny)
                let mask = smoothstep(midpoint - feather / 2, midpoint + feather / 2, radius)
                let factor = max(1 - amount * mask, 0)
                let index = (y * width + x) * 3
                data[index] *= factor
                data[index + 1] *= factor
                data[index + 2] *= factor
            }
        }
    }

    private static func bilinearSample(
        _ channel: [Float], width: Int, height: Int,
        x: Double, y: Double
    ) -> Double {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let xa = min(max(x0, 0), width - 1)
        let xb = min(max(x0 + 1, 0), width - 1)
        let ya = min(max(y0, 0), height - 1)
        let yb = min(max(y0 + 1, 0), height - 1)
        let top = Double(channel[ya * width + xa]) * (1 - fx) + Double(channel[ya * width + xb]) * fx
        let bottom = Double(channel[yb * width + xa]) * (1 - fx) + Double(channel[yb * width + xb]) * fx
        return top * (1 - fy) + bottom * fy
    }

    private static func applyChromaticAberration(
        _ data: inout [Double], width: Int, height: Int, amount: Double,
        rowOffset: Int = 0, fullHeight: Int? = nil
    ) {
        let strength = amount / 100 * 0.004
        guard strength > 1e-6 else { return }
        let count = width * height
        var red = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        for i in 0..<count {
            red[i] = Float(data[i * 3])
            blue[i] = Float(data[i * 3 + 2])
        }
        let fullH = fullHeight ?? height
        let cy = Double(fullH) / 2
        let cx = Double(width) / 2
        var outputRed = [Float](repeating: 0, count: count)
        var outputBlue = [Float](repeating: 0, count: count)
        for y in 0..<height {
            // 分带采样：纵向按整图坐标偏移，再折回本条带的局部行号。
            let absoluteY = Double(y + rowOffset)
            let redY = cy + (absoluteY - cy) * (1 + strength) - Double(rowOffset)
            let blueY = cy + (absoluteY - cy) * (1 - strength) - Double(rowOffset)
            for x in 0..<width {
                let index = y * width + x
                outputRed[index] = Float(bilinearSample(
                    red, width: width, height: height,
                    x: cx + (Double(x) - cx) * (1 + strength),
                    y: redY
                ))
                outputBlue[index] = Float(bilinearSample(
                    blue, width: width, height: height,
                    x: cx + (Double(x) - cx) * (1 - strength),
                    y: blueY
                ))
            }
        }
        for i in 0..<count {
            data[i * 3] = Double(outputRed[i])
            data[i * 3 + 2] = Double(outputBlue[i])
        }
    }

    private static let grainLock = NSLock()
    private static var grainCache: [String: [Float]] = [:]

    /// 确定性噪声；与 numpy `default_rng(20240101)` 不逐位一致，但同尺寸同种子稳定。
    /// `useCache` 为 false 时（分带调色）每次按带的种子现算，避免所有带复用同一张噪声。
    private static func grainNoise(width: Int, height: Int, seed: UInt64 = 20240101,
                                   useCache: Bool = true) -> [Float] {
        let key = "\(width)x\(height)"
        if useCache {
            grainLock.lock()
            if let cached = grainCache[key] {
                grainLock.unlock()
                return cached
            }
            grainLock.unlock()
        }
        var noise = [Float](repeating: 0, count: width * height)
        var state: UInt64 = seed
        func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        for i in stride(from: 0, to: noise.count, by: 2) {
            let u1 = max(next(), 1e-12)
            let u2 = next()
            let radius = sqrt(-2 * log(u1))
            let angle = 2 * Double.pi * u2
            noise[i] = Float(radius * cos(angle))
            if i + 1 < noise.count { noise[i + 1] = Float(radius * sin(angle)) }
        }
        if useCache {
            grainLock.lock()
            // 大图噪声很大，只保留最近两份，避免缓存反噬内存。
            if grainCache.count >= 2 { grainCache.removeAll() }
            grainCache[key] = noise
            grainLock.unlock()
        }
        return noise
    }

    private static func applyGrain(_ data: inout [Double], width: Int, height: Int,
                                   optics: OpticsRecipe, fullShortEdge: Int? = nil,
                                   seed: UInt64 = 20240101, useCache: Bool = true) {
        let amount = optics.grainAmount / 100
        guard amount > 1e-6 else { return }
        let count = width * height
        var noise = grainNoise(width: width, height: height, seed: seed, useCache: useCache)
        let scale = max(0.6, min(3.0, Double(fullShortEdge ?? min(width, height)) / 1080))
        let sigma = (0.6 + optics.grainSize / 100 * 3.0) * scale
        if sigma > 0.9 {
            noise = boxBlur(noise, width: width, height: height, radius: sigma)
        }
        let roughness = optics.grainRoughness / 100
        if roughness > 1e-6 {
            for i in 0..<count {
                let value = Double(noise[i])
                noise[i] = Float((value < 0 ? -1 : 1) * pow(abs(value), 1 - roughness * 0.7))
            }
        }
        var mean = 0.0
        for value in noise { mean += Double(value) }
        mean /= Double(count)
        var variance = 0.0
        for value in noise {
            let delta = Double(value) - mean
            variance += delta * delta
        }
        let deviation = sqrt(variance / Double(count))
        if deviation > 1e-6 {
            for i in 0..<count { noise[i] = Float(Double(noise[i]) / deviation) }
        }
        for i in 0..<count {
            let y = luma(data, i)
            let weight = 0.4 + 0.6 * 4 * y * max(1 - y, 0)
            let delta = Double(noise[i]) * (amount * 0.06) * weight
            data[i * 3] += delta
            data[i * 3 + 1] += delta
            data[i * 3 + 2] += delta
        }
    }

    private static func applyOptics(_ data: inout [Double], width: Int, height: Int,
                                    optics: OpticsRecipe,
                                    rowOffset: Int = 0, fullHeight: Int? = nil,
                                    fullShortEdge: Int? = nil,
                                    seed: UInt64 = 20240101,
                                    banded: Bool = false) {
        applyVignette(&data, width: width, height: height, optics: optics,
                      rowOffset: rowOffset, fullHeight: fullHeight)
        applyChromaticAberration(&data, width: width, height: height,
                                 amount: optics.chromaticAberration,
                                 rowOffset: rowOffset, fullHeight: fullHeight)
        applyGrain(&data, width: width, height: height, optics: optics,
                   fullShortEdge: fullShortEdge, seed: seed, useCache: !banded)
    }

    // MARK: - LUT

    private struct LUTCube {
        var size: Int
        var values: [Double]
        var domainMin: Vec3
        var domainMax: Vec3
    }

    private static let lutLock = NSLock()
    private static var lutCache: [String: LUTCube] = [:]

    static func parseCube(path: String) throws -> (Int, [Double], Vec3, Vec3) {
        let url = URL(fileURLWithPath: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var domainMin = Vec3(0, 0, 0)
        var domainMax = Vec3(1, 1, 1)
        var values: [Double] = []
        var is1D = false
        // 兼容 CRLF / CR / LF 与空格 / 制表符：Windows 导出的 .cube 常见 CRLF + tab，
        // 只按 "\n" 和 " " 切分会把整份文件当成一行，造成解析静默失败。
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.first?.uppercased() else { continue }
            switch key {
            case "LUT_3D_SIZE":
                size = fields.dropFirst().first.flatMap { Int($0) } ?? 0
            case "LUT_1D_SIZE":
                is1D = true
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let parts = fields.dropFirst().prefix(3).compactMap { Double($0) }
                if parts.count == 3 {
                    if key == "DOMAIN_MIN" {
                        domainMin = Vec3(parts[0], parts[1], parts[2])
                    } else {
                        domainMax = Vec3(parts[0], parts[1], parts[2])
                    }
                }
            case "TITLE":
                continue
            default:
                if key.hasPrefix("LUT_3D_INPUT") || key.hasPrefix("LUT_1D_INPUT") { continue }
                let parts = fields.prefix(3).compactMap { Double($0) }
                if parts.count == 3 { values.append(contentsOf: parts) }
            }
        }
        guard !is1D else {
            throw LUTParseError(path: path, reason: "只支持 3D .cube，1D LUT 暂不支持")
        }
        guard size >= 2 else { throw LUTParseError(path: path) }
        let expected = size * size * size * 3
        guard values.count >= expected else {
            throw LUTParseError(path: path, reason: "LUT 数据行数不足")
        }
        return (size, Array(values.prefix(expected)), domainMin, domainMax)
    }

    /// 导入校验：把 .cube 完整解析一次并写入缓存，失败直接抛错；成功后点击即可命中缓存。
    static func preloadCube(path: String) throws {
        _ = try loadCube(path: path)
    }

    private static func loadCube(path: String) throws -> LUTCube {
        lutLock.lock()
        if let cached = lutCache[path] {
            lutLock.unlock()
            return cached
        }
        lutLock.unlock()
        let parsed = try parseCube(path: path)
        let cube = LUTCube(size: parsed.0, values: parsed.1,
                           domainMin: parsed.2, domainMax: parsed.3)
        lutLock.lock()
        if lutCache.count >= 8 { lutCache.removeAll() }
        lutCache[path] = cube
        lutLock.unlock()
        return cube
    }

    /// 返回 nil 表示 LUT 已应用或配方本来就没启用 LUT；非 nil 表示解析失败，调用方需提示用户。
    private static func applyLUT(_ data: inout [Double], count: Int, path: String,
                                 strength: Double) -> LUTParseError? {
        guard !path.isEmpty, strength > 1e-6 else { return nil }
        let cube: LUTCube
        do {
            cube = try loadCube(path: path)
        } catch let error as LUTParseError {
            return error
        } catch {
            return LUTParseError(path: path)
        }
        let size = cube.size
        let spanX = max(cube.domainMax.x - cube.domainMin.x, 1e-6)
        let spanY = max(cube.domainMax.y - cube.domainMin.y, 1e-6)
        let spanZ = max(cube.domainMax.z - cube.domainMin.z, 1e-6)
        let mix = strength / 100

        func lutValue(_ r: Int, _ g: Int, _ b: Int, channel: Int) -> Double {
            cube.values[((b * size + g) * size + r) * 3 + channel]
        }

        for i in 0..<count {
            let r = data[i * 3]
            let g = data[i * 3 + 1]
            let b = data[i * 3 + 2]
            let cr = min(max((r - cube.domainMin.x) / spanX, 0), 1) * Double(size - 1)
            let cg = min(max((g - cube.domainMin.y) / spanY, 0), 1) * Double(size - 1)
            let cb = min(max((b - cube.domainMin.z) / spanZ, 0), 1) * Double(size - 1)
            let r0 = Int(floor(cr)), g0 = Int(floor(cg)), b0 = Int(floor(cb))
            let r1 = min(r0 + 1, size - 1), g1 = min(g0 + 1, size - 1)
            let b1 = min(b0 + 1, size - 1)
            let fr = cr - Double(r0), fg = cg - Double(g0), fb = cb - Double(b0)

            for channel in 0..<3 {
                let c000 = lutValue(r0, g0, b0, channel: channel)
                let c001 = lutValue(r1, g0, b0, channel: channel)
                let c010 = lutValue(r0, g1, b0, channel: channel)
                let c011 = lutValue(r1, g1, b0, channel: channel)
                let c100 = lutValue(r0, g0, b1, channel: channel)
                let c101 = lutValue(r1, g0, b1, channel: channel)
                let c110 = lutValue(r0, g1, b1, channel: channel)
                let c111 = lutValue(r1, g1, b1, channel: channel)
                let c00 = c000 * (1 - fr) + c001 * fr
                let c01 = c010 * (1 - fr) + c011 * fr
                let c10 = c100 * (1 - fr) + c101 * fr
                let c11 = c110 * (1 - fr) + c111 * fr
                let c0 = c00 * (1 - fg) + c01 * fg
                let c1 = c10 * (1 - fg) + c11 * fg
                let graded = c0 * (1 - fb) + c1 * fb
                data[i * 3 + channel] = data[i * 3 + channel] * (1 - mix) + graded * mix
            }
        }
        return nil
    }
}

/// 分带并行的共享状态：取消标记与首个 LUT 错误，用锁保护。
/// 带与带只写互不重叠的行段，像素本身不需要加锁；这里只收敛跨带共享的控制信号。
private final class GradeBandState: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _lutError: LUTParseError?

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    func markCancelled() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    func recordLUTError(_ error: LUTParseError) {
        lock.lock()
        if _lutError == nil { _lutError = error }
        lock.unlock()
    }

    var lutError: LUTParseError? {
        lock.lock()
        defer { lock.unlock() }
        return _lutError
    }
}
