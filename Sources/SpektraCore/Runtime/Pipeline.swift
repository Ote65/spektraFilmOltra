import Foundation

/// 管线内可进入/退出的 tap，用于 LUT 预览的四段烘焙。
enum PipelineTap {
    case rgbIn
    case logEFilm
    case cmyFilm
    case logEPrint
    case rgbOut
}

struct PipelineResult {
    var rgbIn: ImageRGB
    var rgbPre: ImageRGB
    var logEFilm: ImageRGB
    var cmyFilm: ImageRGB
    var logEPrint: ImageRGB?
    var cmyPrint: ImageRGB?
    var rgbOut: ImageRGB
}

final class SimulationPipeline {
    let params: RuntimePhotoParams
    private let lutService: SpectralLUTService
    private let enlargerService: EnlargerService
    private let colorReference: ColorReferenceService
    private let filming: FilmingStage
    private let printing: PrintingStage
    private let scanning: ScanningStage
    private let keepTaps: Bool
    /// 协作式取消：每个阶段结束后检查；取消时返回已完成的中间结果。
    var shouldCancel: () -> Bool = { false }

    init(params: RuntimePhotoParams, lutService sharedLUT: SpectralLUTService? = nil,
         keepTaps: Bool = true) {
        var resolved = params
        if resolved.settings.previewMode {
            resolved.enlarger.lensBlur = 0
            resolved.filmRender.dirCouplers.diffusionSizeUM = 0
            resolved.filmRender.grain.active = false
            resolved.filmRender.grain.particleAreaUM2 = 0
            resolved.filmRender.grain.blur = 0
            resolved.printRender.glare.blur = 0
            resolved.camera.lensBlurUM = 0
            resolved.scanner.lensBlur = 0
            resolved.scanner.unsharpMask = [0, 0]
        }
        ParamsDigest.applyFilmSpecifics(&resolved)
        if resolved.debug.lutMode {
            resolved.debug.deactivateSpatialEffects = true
            resolved.debug.deactivateStochasticEffects = true
            resolved.camera.autoExposure = false
            resolved.camera.exposureCompensationEV = 0
            resolved.enlarger.printExposureCompensation = false
            resolved.enlarger.printExposure = 1.0
            resolved.filmRender.halation.boostEV = 0
            resolved.scanner.whiteCorrection = false
            resolved.scanner.blackCorrection = false
            resolved.scanner.unsharpMask = [0, 0]
        }
        if resolved.debug.deactivateSpatialEffects {
            resolved.filmRender.halation.active = false
            resolved.filmRender.halation.scatterCoreUM = [0, 0, 0]
            resolved.filmRender.halation.scatterTailUM = [0, 0, 0]
            resolved.filmRender.halation.halationFirstSigmaUM = [0, 0, 0]
            resolved.filmRender.dirCouplers.diffusionSizeUM = 0
            resolved.filmRender.grain.blur = 0
            resolved.filmRender.grain.blurDyeCloudsUM = 0
            resolved.printRender.glare.blur = 0
            resolved.camera.lensBlurUM = 0
            resolved.enlarger.lensBlur = 0
            resolved.enlarger.diffusionFilter.active = false
            resolved.camera.diffusionFilter.active = false
            resolved.scanner.lensBlur = 0
            resolved.scanner.unsharpMask = [0, 0]
        }
        if resolved.debug.deactivateStochasticEffects {
            resolved.filmRender.grain.active = false
            resolved.printRender.glare.active = false
        }
        if resolved.settings.neutralPrintFiltersFromDatabase,
           let filters = NeutralPrintFilters.lookup(
               filmStock: resolved.film.info.stock,
               printStock: resolved.print.info.stock,
               illuminant: resolved.enlarger.illuminant
           ) {
            resolved.enlarger.cFilterNeutral = filters.c
            resolved.enlarger.mFilterNeutral = filters.m
            resolved.enlarger.yFilterNeutral = filters.y
        }
        self.params = resolved
        self.keepTaps = keepTaps
        self.lutService = sharedLUT ?? SpectralLUTService(resolution: resolved.settings.lutResolution)
        self.lutService.updateResolution(resolved.settings.lutResolution)
        self.enlargerService = EnlargerService(params: resolved.enlarger)
        self.colorReference = ColorReferenceService(
            film: resolved.film, printProfile: resolved.print,
            densityMin: resolved.filmRender.grain.densityMin,
            blackCorrection: resolved.scanner.blackCorrection,
            whiteCorrection: resolved.scanner.whiteCorrection,
            blackLevel: resolved.scanner.blackLevel,
            whiteLevel: resolved.scanner.whiteLevel,
            scanFilm: resolved.io.scanFilm,
            outputColorSpace: resolved.io.outputColorSpace,
            outputCCTFEncoding: resolved.io.outputCCTFEncoding
        )
        self.filming = FilmingStage(
            film: resolved.film, filmRender: resolved.filmRender, camera: resolved.camera,
            io: resolved.io, settings: resolved.settings, lutService: lutService,
            enlargerService: enlargerService, colorReference: colorReference
        )
        self.printing = PrintingStage(
            film: resolved.film, filmRender: resolved.filmRender, printProfile: resolved.print,
            printRender: resolved.printRender, enlarger: resolved.enlarger, settings: resolved.settings,
            lutService: lutService, enlargerService: enlargerService, colorReference: colorReference
        )
        self.scanning = ScanningStage(
            film: resolved.film, filmRender: resolved.filmRender, printProfile: resolved.print,
            printRender: resolved.printRender, scanner: resolved.scanner, io: resolved.io,
            settings: resolved.settings, lutService: lutService, colorReference: colorReference
        )
    }

    func process(_ input: ImageRGB, progress: ((String, Int, Int) -> Void)? = nil) -> PipelineResult {
        let total = params.io.scanFilm ? 4 : 6
        var step = 0
        func advance(_ label: String) {
            step += 1
            progress?(label, step, total)
        }
        let empty = ImageRGB(width: 0, height: 0)
        let rgbIn = keepTaps ? input : empty

        // 全分辨率下每个整图缓冲是 293 MB（4032×3024，Double×3ch）。
        // `keepTaps == false`（导出、预览渲染）时用 Optional 逐段释放已经用完的中间结果，
        // 把同时存活的整图缓冲从 7 份压到 3 份；峰值内存随之下降。
        // `keepTaps == true`（LUT 四段烘焙）必须保留，行为与改动前完全一致。
        var pre: ImageRGB? = preprocess(input)
        advance("preprocess")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: empty, cmyFilm: empty,
                                   logEPrint: nil, cmyPrint: nil, rgbOut: pre ?? input)
        }
        var logFilm: ImageRGB? = filming.expose(pre ?? input)
        advance("filming.expose")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty, cmyFilm: empty,
                                   logEPrint: nil, cmyPrint: nil, rgbOut: pre ?? input)
        }
        if !keepTaps { pre = nil }
        var cmyFilm: ImageRGB? = filming.develop(logFilm ?? input)
        advance("filming.develop")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                                   cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                                   logEPrint: nil, cmyPrint: nil, rgbOut: cmyFilm ?? input)
        }
        if params.io.scanFilm {
            var out = scanning.scan(densityChannels: cmyFilm ?? input)
            out.sanitizeNonFinite()
            advance("scanning.scan_film")
            return PipelineResult(
                rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                logEPrint: nil, cmyPrint: nil, rgbOut: out
            )
        }
        if !keepTaps { logFilm = nil }
        var logPrint: ImageRGB? = printing.expose(cmyFilmDensity: cmyFilm ?? input)
        advance("printing.expose")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                                   cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                                   logEPrint: keepTaps ? (logPrint ?? empty) : empty,
                                   cmyPrint: nil, rgbOut: cmyFilm ?? input)
        }
        if !keepTaps { cmyFilm = nil }
        var cmyPrint: ImageRGB? = printing.develop(logRaw: logPrint ?? input)
        advance("printing.develop")
        if shouldCancel() {
            return PipelineResult(rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
                                   logEFilm: keepTaps ? (logFilm ?? empty) : empty,
                                   cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
                                   logEPrint: keepTaps ? (logPrint ?? empty) : empty,
                                   cmyPrint: keepTaps ? (cmyPrint ?? empty) : empty, rgbOut: cmyPrint ?? input)
        }
        if !keepTaps { logPrint = nil }
        var out = scanning.scan(densityChannels: cmyPrint ?? input)
        out.sanitizeNonFinite()
        advance("scanning.scan_print")
        return PipelineResult(
            rgbIn: rgbIn, rgbPre: keepTaps ? (pre ?? empty) : empty,
            logEFilm: keepTaps ? (logFilm ?? empty) : empty,
            cmyFilm: keepTaps ? (cmyFilm ?? empty) : empty,
            logEPrint: keepTaps ? (logPrint ?? empty) : empty,
            cmyPrint: keepTaps ? (cmyPrint ?? empty) : empty, rgbOut: out
        )
    }

    // MARK: - 分带导出

    /// 分带计划：只描述尺寸，不持有像素。
    struct TilePlan {
        var coreRows: Int
        var haloRows: Int
        var bandCount: Int
        var outputWidth: Int
        var outputHeight: Int
    }

    /// 显影里最大的空间核（单位：行）。分带时每条带上下各留这么多行，
    /// 核心区才不会被条带边界影响。数值按各阶段的核半径保守取 3σ。
    static func haloRows(for params: RuntimePhotoParams, pixelSizeUM: Double) -> Int {
        guard pixelSizeUM > 0 else { return 8 }
        var halo = 8.0
        let couplers = params.filmRender.dirCouplers
        if couplers.active && couplers.diffusionSizeUM > 0 {
            let gaussianSigma = couplers.diffusionSizeUM / pixelSizeUM
            // exponentialFilter 里最大的高斯分量是 decay × 2.7684。
            let tailSigma = 2.7684 * couplers.diffusionTailUM / pixelSizeUM
            halo = max(halo, 3.0 * max(gaussianSigma, tailSigma))
        }
        let halation = params.filmRender.halation
        if halation.active {
            let n = max(halation.halationNBounces, 1)
            let bounceSigma = (halation.halationFirstSigmaUM.map {
                $0 * halation.halationSpatialScale
            }.max() ?? 0) * sqrt(Double(n))
            let tailSigma = 2.7684 * (halation.scatterTailUM.map {
                $0 * halation.scatterSpatialScale
            }.max() ?? 0)
            let coreSigma = halation.scatterCoreUM.map {
                $0 * halation.scatterSpatialScale
            }.max() ?? 0
            halo = max(halo, 3.0 * max(bounceSigma, tailSigma, coreSigma) / pixelSizeUM)
        }
        if params.filmRender.grain.active {
            halo = max(halo, 3.0 * params.filmRender.grain.blur)
            let microBlurUM = params.filmRender.grain.microStructure.first ?? 0
            halo = max(halo, 3.0 * microBlurUM / pixelSizeUM)
        }
        halo = max(halo, 3.0 * params.scanner.unsharpMask[0])
        halo = max(halo, 3.0 * params.scanner.lensBlur)
        halo = max(halo, 3.0 * params.printRender.glare.blur)
        halo = max(halo, 3.0 * params.filmRender.glare.blur)
        halo = max(halo, 3.0 * params.camera.lensBlurUM / pixelSizeUM)
        return Int(ceil(halo)) + 8
    }

    /// 按可用带宽预算算核心行数与条带数。
    static func tileRows(outputWidth: Int, outputHeight: Int, haloRows: Int,
                         bandPixelBudget: Int) -> (coreRows: Int, bandCount: Int) {
        let width = max(outputWidth, 1)
        let usable = max(64, bandPixelBudget / width - 2 * haloRows)
        let coreRows = min(max(64, usable), max(outputHeight, 1))
        let bandCount = max(1, (outputHeight + coreRows - 1) / coreRows)
        return (coreRows, bandCount)
    }

    /// 分带导出的像素尺寸：按最终输出长边反算胶片像素尺寸。
    static func exportPixelSizeUM(params: RuntimePhotoParams, outputLongEdge: Int) -> Double {
        params.camera.filmFormatMM * 1000 / Double(max(outputLongEdge, 1))
    }

    func tilePlan(for input: ImageRGB, bandPixelBudget: Int = 6_000_000) -> TilePlan? {
        let geometry = preprocessGeometry(input)
        guard geometry.outputWidth > 0, geometry.outputHeight > 0 else { return nil }
        let halo = Self.haloRows(for: params, pixelSizeUM: geometry.pixelSizeUM)
        let rows = Self.tileRows(outputWidth: geometry.outputWidth,
                                 outputHeight: geometry.outputHeight,
                                 haloRows: halo, bandPixelBudget: bandPixelBudget)
        return TilePlan(coreRows: rows.coreRows, haloRows: halo,
                        bandCount: rows.bandCount,
                        outputWidth: geometry.outputWidth,
                        outputHeight: geometry.outputHeight)
    }

    private struct PreprocessGeometry {
        var cropX = 0
        var cropY = 0
        var cropWidth = 0
        var cropHeight = 0
        var outputWidth = 0
        var outputHeight = 0
        var factor = 1.0
        var exposureScale = 1.0
        var pixelSizeUM = 1.0
    }

    /// 把 `preprocess` 拆成「全图常量」：自动曝光、裁切矩形、放大倍数。
    /// 条带采样严格复用同一套坐标公式，保证与整张处理的结果一致。
    private func preprocessGeometry(_ input: ImageRGB) -> PreprocessGeometry {
        var geometry = PreprocessGeometry()
        if params.camera.autoExposure {
            let small = Resize.smallPreview(input, maxSize: 256)
            let ev = AutoExposure.measureEV(
                image: small, colorSpace: params.io.inputColorSpace,
                applyCCTFDecoding: params.io.inputCCTFDecoding,
                method: params.camera.autoExposureMethod
            )
            geometry.exposureScale = pow(2, ev)
        }
        var cropX = 0
        var cropY = 0
        var cropWidth = input.width
        var cropHeight = input.height
        if params.io.crop {
            // 与 Resize.crop 完全相同的归一化 → 像素矩形换算。
            let shape = (Double(input.height), Double(input.width))
            let center = params.io.cropCenter
            let size = params.io.cropSize
            let centerNormalized = (center.count > 1 ? center[1] : 0.5,
                                    center.count > 0 ? center[0] : 0.5)
            let sizeNormalized = (size.count > 1 ? size[1] : 1.0,
                                  size.count > 0 ? size[0] : 1.0)
            let cn = (round(shape.0 * centerNormalized.0), round(shape.1 * centerNormalized.1))
            var sz = (round(max(shape.0, shape.1) * sizeNormalized.0),
                      round(max(shape.0, shape.1) * sizeNormalized.1))
            var origin = (round(cn.0 - sz.0 / 2), round(cn.1 - sz.1 / 2))
            origin.0 = max(origin.0, 0)
            origin.1 = max(origin.1, 0)
            if origin.0 + sz.0 > shape.0 { origin.0 = shape.0 - sz.0 }
            if origin.1 + sz.1 > shape.1 { origin.1 = shape.1 - sz.1 }
            sz.0 = max(sz.0, 1)
            sz.1 = max(sz.1, 1)
            cropY = Int(origin.0)
            cropX = Int(origin.1)
            cropHeight = Int(sz.0)
            cropWidth = Int(sz.1)
        }
        let factor = params.io.upscaleFactor
        let outputWidth = factor == 1 ? cropWidth
            : max(1, Int((Double(cropWidth) * factor).rounded(.toNearestOrEven)))
        let outputHeight = factor == 1 ? cropHeight
            : max(1, Int((Double(cropHeight) * factor).rounded(.toNearestOrEven)))
        var pixelSize = params.camera.filmFormatMM * 1000 / Double(max(max(cropWidth, cropHeight), 1))
        if factor != 1 { pixelSize /= factor }
        geometry.cropX = cropX
        geometry.cropY = cropY
        geometry.cropWidth = cropWidth
        geometry.cropHeight = cropHeight
        geometry.outputWidth = outputWidth
        geometry.outputHeight = outputHeight
        geometry.factor = factor
        geometry.pixelSizeUM = pixelSize
        return geometry
    }

    private struct ColumnTable {
        var indices: [Int] = []
        var weights: [Double] = []
    }

    private func makeColumnTable(_ geometry: PreprocessGeometry) -> ColumnTable {
        var table = ColumnTable()
        guard geometry.factor != 1,
              geometry.outputWidth > 0, geometry.cropWidth > 0 else { return table }
        let stepX = Double(geometry.cropWidth) / Double(geometry.outputWidth)
        table.indices.reserveCapacity(geometry.outputWidth * 4)
        table.weights.reserveCapacity(geometry.outputWidth * 4)
        for x in 0..<geometry.outputWidth {
            let sourceX = (Double(x) + 0.5) * stepX - 0.5
            let baseX = Int(floor(sourceX))
            let fraction = sourceX - Double(baseX)
            let weights = Resize.cubicWeights(fraction)
            for i in 0..<4 {
                table.indices.append(geometry.cropX + FastGaussian.reflect(baseX - 1 + i, geometry.cropWidth))
                table.weights.append(weights[i])
            }
        }
        return table
    }

    /// 采样一条带：`bandTop` 是这一带第一行在最终画面里的行号。
    private func fillBand(_ band: inout ImageRGB, from input: ImageRGB,
                          geometry: PreprocessGeometry, bandTop: Int,
                          columns: ColumnTable) {
        let width = band.width
        guard width > 0, band.height > 0 else { return }
        if geometry.factor == 1 {
            let scale = geometry.exposureScale
            band.data.withUnsafeMutableBufferPointer { destination in
                guard let dst = destination.baseAddress else { return }
                input.data.withUnsafeBufferPointer { source in
                    guard let src = source.baseAddress else { return }
                    for row in 0..<band.height {
                        let globalY = bandTop + row
                        let sourceRow = (geometry.cropY + globalY) * input.width + geometry.cropX
                        let destinationRow = row * width
                        if scale == 1 {
                            let bytes = width * 3 * MemoryLayout<Float>.size
                            UnsafeMutableRawPointer(dst + destinationRow * 3)
                                .copyMemory(from: UnsafeRawPointer(src + sourceRow * 3),
                                            byteCount: bytes)
                        } else {
                            for x in 0..<width {
                                let sourceIndex = (sourceRow + x) * 3
                                let destinationIndex = (destinationRow + x) * 3
                                dst[destinationIndex] = Float(Double(src[sourceIndex]) * scale)
                                dst[destinationIndex + 1] = Float(Double(src[sourceIndex + 1]) * scale)
                                dst[destinationIndex + 2] = Float(Double(src[sourceIndex + 2]) * scale)
                            }
                        }
                    }
                }
            }
            return
        }
        let stepY = Double(geometry.cropHeight) / Double(max(geometry.outputHeight, 1))
        for row in 0..<band.height {
            let globalY = bandTop + row
            let sourceY = (Double(globalY) + 0.5) * stepY - 0.5
            let baseY = Int(floor(sourceY))
            let fraction = sourceY - Double(baseY)
            let weightsY = Resize.cubicWeights(fraction)
            var rows = [Int](repeating: 0, count: 4)
            for j in 0..<4 {
                rows[j] = geometry.cropY + FastGaussian.reflect(baseY - 1 + j, geometry.cropHeight)
            }
            let destinationRow = row * width * 3
            for x in 0..<width {
                var value = Vec3(0, 0, 0)
                for j in 0..<4 {
                    let rowBase = rows[j] * input.width
                    let weightY = weightsY[j]
                    for i in 0..<4 {
                        let sourceIndex = (rowBase + columns.indices[x * 4 + i]) * 3
                        let weight = weightY * columns.weights[x * 4 + i]
                        let r = Double(Float(Double(input.data[sourceIndex]) * geometry.exposureScale))
                        let g = Double(Float(Double(input.data[sourceIndex + 1]) * geometry.exposureScale))
                        let b = Double(Float(Double(input.data[sourceIndex + 2]) * geometry.exposureScale))
                        value = value + Vec3(r, g, b) * weight
                    }
                }
                let index = destinationRow + x * 3
                band.data[index] = Float(value.x)
                band.data[index + 1] = Float(value.y)
                band.data[index + 2] = Float(value.z)
            }
        }
    }

    /// 单条带完整显影。`rowOffset` 是条带第一行在整张图里的行号，
    /// 颗粒与眩光用它保持跨带连续。
    private func runBand(_ input: ImageRGB, rowOffset: Int, rowSeeded: Bool) -> ImageRGB {
        var logFilm: ImageRGB? = filming.expose(input)
        var cmyFilm: ImageRGB? = filming.develop(
            logFilm ?? input, rowOffset: rowOffset, rowSeeded: rowSeeded)
        logFilm = nil
        if params.io.scanFilm {
            var out = scanning.scan(densityChannels: cmyFilm ?? input,
                                    rowOffset: rowOffset, rowSeeded: rowSeeded)
            out.sanitizeNonFinite()
            return out
        }
        var logPrint: ImageRGB? = printing.expose(cmyFilmDensity: cmyFilm ?? input)
        cmyFilm = nil
        var cmyPrint: ImageRGB? = printing.develop(logRaw: logPrint ?? input)
        logPrint = nil
        var out = scanning.scan(densityChannels: cmyPrint ?? input,
                                rowOffset: rowOffset, rowSeeded: rowSeeded)
        out.sanitizeNonFinite()
        return out
    }

    /// 分带处理整张图。返回的 `rgbOut` 是完整成品，其余 tap 为空。
    /// 内存峰值 ≈ 输入 + 输出 + 一条带（含上下重叠）。
    func processTiled(_ input: ImageRGB, bandPixelBudget: Int = 6_000_000,
                      progress: ((String, Int, Int) -> Void)? = nil) -> PipelineResult {
        let empty = ImageRGB(width: 0, height: 0)
        guard input.width > 0, input.height > 0 else {
            return PipelineResult(rgbIn: empty, rgbPre: empty, logEFilm: empty,
                                  cmyFilm: empty, logEPrint: nil, cmyPrint: nil, rgbOut: input)
        }
        let geometry = preprocessGeometry(input)
        guard geometry.outputWidth > 0, geometry.outputHeight > 0 else {
            return PipelineResult(rgbIn: empty, rgbPre: empty, logEFilm: empty,
                                  cmyFilm: empty, logEPrint: nil, cmyPrint: nil, rgbOut: input)
        }
        filming.pixelSizeUM = geometry.pixelSizeUM
        printing.pixelSizeUM = geometry.pixelSizeUM
        let halo = Self.haloRows(for: params, pixelSizeUM: geometry.pixelSizeUM)
        let rows = Self.tileRows(outputWidth: geometry.outputWidth,
                                 outputHeight: geometry.outputHeight,
                                 haloRows: halo, bandPixelBudget: bandPixelBudget)
        let columns = makeColumnTable(geometry)
        var output = ImageRGB(width: geometry.outputWidth, height: geometry.outputHeight)
        let rowSeeded = rows.bandCount > 1
        var bandStart = 0
        var bandIndex = 0
        while bandStart < geometry.outputHeight {
            if shouldCancel() { break }
            let coreEnd = min(bandStart + rows.coreRows, geometry.outputHeight)
            let bandTop = max(0, bandStart - halo)
            let bandBottom = min(geometry.outputHeight, coreEnd + halo)
            var band = ImageRGB(width: geometry.outputWidth, height: bandBottom - bandTop)
            fillBand(&band, from: input, geometry: geometry, bandTop: bandTop, columns: columns)
            var processed = runBand(band, rowOffset: bandTop, rowSeeded: rowSeeded)
            band = empty
            // 只把核心行写进成品；上下重叠行已经完成使命。
            let coreRows = coreEnd - bandStart
            let localStart = bandStart - bandTop
            output.data.withUnsafeMutableBufferPointer { destination in
                guard let dst = destination.baseAddress else { return }
                processed.data.withUnsafeBufferPointer { source in
                    guard let src = source.baseAddress else { return }
                    let bytes = coreRows * geometry.outputWidth * 3 * MemoryLayout<Float>.size
                    UnsafeMutableRawPointer(dst + bandStart * geometry.outputWidth * 3)
                        .copyMemory(from: UnsafeRawPointer(src + localStart * geometry.outputWidth * 3),
                                    byteCount: bytes)
                }
            }
            processed = empty
            bandIndex += 1
            progress?("tile", bandIndex, rows.bandCount)
            bandStart = coreEnd
        }
        return PipelineResult(rgbIn: empty, rgbPre: empty, logEFilm: empty,
                              cmyFilm: empty, logEPrint: nil, cmyPrint: nil, rgbOut: output)
    }

    /// 从指定 tap 进入、在指定 tap 退出，跳过前/后阶段；用于 LUT 预览烘焙。
    /// `inject != .rgbIn` 时不做 preprocess，按输入图长边更新胶片/印相像素尺寸。
    func processSegment(_ input: ImageRGB, inject: PipelineTap,
                        collect: PipelineTap) -> ImageRGB {
        guard input.width > 0, input.height > 0 else { return input }
        if inject != .rgbIn {
            let longEdge = max(input.width, input.height)
            let pixelSize = params.camera.filmFormatMM * 1000 / Double(max(longEdge, 1))
            filming.pixelSizeUM = pixelSize
            printing.pixelSizeUM = pixelSize
        }
        if inject == collect { return input }

        var image = input
        if inject == .rgbIn {
            image = preprocess(input)
            if collect == .rgbIn { return image }
        }

        if inject == .rgbIn || inject == .logEFilm {
            if inject == .rgbIn { image = filming.expose(image) }
            if collect == .logEFilm { return image }
            image = filming.develop(image)
            if collect == .cmyFilm { return image }
        }

        if params.io.scanFilm {
            if collect == .rgbOut {
                var out = scanning.scan(densityChannels: image)
                out.sanitizeNonFinite()
                return out
            }
            return image
        }

        if inject == .cmyFilm {
            image = printing.expose(cmyFilmDensity: image)
            if collect == .logEPrint { return image }
        } else if inject == .logEPrint || inject == .rgbOut {
            if collect == .logEPrint { return image }
        }

        image = printing.develop(logRaw: image)
        var out = scanning.scan(densityChannels: image)
        out.sanitizeNonFinite()
        return out
    }

    /// LUT 预览：按相机曝光补偿重算印相中灰补偿密度。
    func updatePreviewCompensationMidgray(exposureEV: Double) {
        filming.updateCompensationMidgray(exposureEV: exposureEV)
    }

    /// LUT 预览：当前补偿设置下的印相中灰曝光因子。
    func previewPrintExposureFactor() -> Double {
        printing.rawExposureFactorMidgray()
    }

    private func preprocess(_ input: ImageRGB) -> ImageRGB {
        var image = input
        image = filming.autoExposure(image)
        if params.io.crop {
            image = Resize.crop(image, center: params.io.cropCenter, size: params.io.cropSize)
        }
        let longEdge = max(image.width, image.height)
        filming.pixelSizeUM = params.camera.filmFormatMM * 1000 / Double(longEdge)
        if params.io.upscaleFactor != 1 {
            filming.pixelSizeUM /= params.io.upscaleFactor
            image = Resize.upscale(image, factor: params.io.upscaleFactor)
        }
        printing.pixelSizeUM = filming.pixelSizeUM
        return image
    }
}

