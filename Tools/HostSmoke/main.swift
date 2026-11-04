import Foundation
import AppKit

@main
@MainActor
struct HostSmoke {
    static func main() async throws {
        // 非有限像素回归：色域压缩不允许再因 NaN/Inf 索引陷阱崩溃。
        var edge = ImageRGB(width: 3, height: 1, data: [
            .nan, .infinity, -.infinity,
            1e300, -1e300, 0,
            0.18, 0.18, 0.18,
        ])
        for algorithm in ["cam16ucs", "oklch", "oklrab", "jzazbz", "aces_rgc"] {
            let out = OutputGamutCompression.apply(
                edge, algorithm: algorithm, knee: [0, 1, 6],
                outputColorSpace: "sRGB"
            )
            let finite = out.data.allSatisfy(\.isFinite)
            if !finite { throw NSError(domain: "smoke", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "non-finite output from \(algorithm)"
            ]) }
        }
        edge.data[0] = 0
        edge.data[1] = 0
        edge.data[2] = 0

        let gradeReport = try runGradeSmoke()
        let lutReport = try runLUTSmoke()

        let args = ProcessInfo.processInfo.environment
        guard let rawPath = args["RAW_PATH"], FileManager.default.fileExists(atPath: rawPath) else {
            let data = try JSONSerialization.data(
                withJSONObject: ["edgeCompression": "finite", "raw": "skipped",
                                 "grade": gradeReport, "lut": lutReport],
                options: [.sortedKeys, .prettyPrinted]
            )
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        let rawURL = URL(fileURLWithPath: rawPath)
        let root = URL(fileURLWithPath: "/tmp/spektra_host_smoke")
        try? FileManager.default.removeItem(at: root)
        let store = LibraryStore(root: root)
        let photo = try store.importPhoto(from: rawURL)
        let host = EngineHost(store: store)

        host.select(photoID: photo.id)
        var waited = 0.0
        while host.previewImage == nil && waited < 180 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
            if host.previewImage == nil && waited > 30 && host.statusMessage.contains("无法读取") {
                throw NSError(domain: "smoke", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: host.statusMessage
                ])
            }
        }
        guard host.previewImage != nil else {
            throw NSError(domain: "smoke", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "RAW preview never arrived: \(host.statusMessage)"
            ])
        }
        let firstElapsed = host.statusMessage
        let snapshot = host.editorSnapshot(for: photo.id)

        host.applyQuick("camera_exposure", 1.0)
        let compensationWhileExposure =
            host.currentPhoto()?.edit.enlarger.printExposureCompensation ?? true
        host.applyQuick("camera_exposure", 0)
        let compensationAtRest =
            host.currentPhoto()?.edit.enlarger.printExposureCompensation ?? false
        if compensationWhileExposure || !compensationAtRest {
            throw NSError(domain: "smoke", code: 6, userInfo: [
                NSLocalizedDescriptionKey:
                    "camera_exposure 未按参考关闭/恢复印相自动亮度补偿"
            ])
        }

        host.applyQuick("camera_exposure", 1.0)
        host.applyQuick("tonal_contrast", 40)
        var second = 0.0
        var sawFastPreview = false
        while (host.isRendering || host.renderPhase.isBusy || host.previewIsPredicted)
            && second < 120 {
            if host.previewIsPredicted { sawFastPreview = true }
            try await Task.sleep(nanoseconds: 100_000_000)
            second += 0.1
        }

        let sweep = try runParameterSweep(rawPath: rawPath)
        if let monotonic = sweep["compOffMonotonic"] as? Bool, !monotonic {
            throw NSError(domain: "smoke", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "关闭补偿后拍摄曝光未单调提亮"
            ])
        }
        if let delta = sweep["compOffMaxMeanDelta"] as? Double, delta > 0.02 {
            throw NSError(domain: "smoke", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "拍摄曝光预测与精算平均亮度差过大：\(delta)"
            ])
        }
        host.refreshExportPreflight()
        let preflightWait = await wait(60) { host.preflightReport != nil }

        let exportURL = URL(fileURLWithPath: "/tmp/spektra_host_smoke_export.tif")
        try? FileManager.default.removeItem(at: exportURL)
        host.exportCurrent(to: exportURL)
        var exportWait = 0.0
        var exportSize = 0
        while exportWait < 300 {
            if let attributes = try? FileManager.default.attributesOfItem(
                atPath: exportURL.path), let value = attributes[.size] as? Int, value > 0 {
                exportSize = value
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            exportWait += 0.2
        }
        let exported = exportSize > 0

        // 调色台整链：交接图 → 调色预览 → 暖调重渲 → 导出。
        host.beginGrade()
        let sourceWait = await wait(120) { host.gradeSourceReady }
        let firstGradeWait = await wait(120) {
            host.gradePreviewImage != nil && !host.gradePhase.isBusy
        }
        let warm = GradeRecipe(
            light: LightRecipe(contrast: 8, shadows: 10),
            color: ColorRecipe(temperature: 12, vibrance: 8),
            transparency: TransparencyRecipe(tonal: 18, color: 0)
        )
        host.setGradeRecipe(warm)
        let recipeWait = await wait(120) {
            !host.gradePhase.isBusy && host.gradeAnalysis != nil
        }

        let gradeDirectory = URL(fileURLWithPath: "/tmp/spektra_host_smoke_grade")
        try? FileManager.default.removeItem(at: gradeDirectory)
        host.exportGrade(ExportSettings(
            format: .tiff16, longEdge: 1200,
            directory: gradeDirectory, filenameTemplate: "{name}-grade-smoke"
        ))
        var gradeExportWait = 0.0
        var gradeFile: URL?
        while gradeExportWait < 400 {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: gradeDirectory, includingPropertiesForKeys: nil
            )) ?? []
            if let first = contents.first {
                gradeFile = first
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            gradeExportWait += 0.2
        }
        var gradeBytes = 0
        if let gradeFile,
           let attributes = try? FileManager.default.attributesOfItem(atPath: gradeFile.path),
           let value = attributes[.size] as? Int {
            gradeBytes = value
        }

        let report: [String: Any] = [
            "raw": rawURL.lastPathComponent,
            "edgeCompression": "finite",
            "previewReady": host.previewImage != nil,
            "firstStatus": firstElapsed,
            "asSeconds": waited,
            "quickAxes": snapshot.quickGroups.flatMap(\.axes).count,
            "proRows": snapshot.proPages.flatMap(\.groups).flatMap(\.rows).count,
            "renderAfterEdit": second,
            "quickCompDuringExposure": compensationWhileExposure,
            "quickCompAtRest": compensationAtRest,
            "fastPreviewSeen": sawFastPreview,
            "preflightWait": preflightWait,
            "realModelMax": host.preflightReport?.model.max ?? -1,
            "realModelP99": host.preflightReport?.model.p99 ?? -1,
            "realEffectsP99": host.preflightReport?.effects.p99 ?? -1,
            "realPreflightOK": host.preflightReport?.ok ?? false,
            "realPreflightNotice": host.preflightNotice ?? "",
            "sweep": sweep,
            "exported": exported,
            "exportWait": exportWait,
            "exportBytes": exportSize,
            "status": host.statusMessage,
            "grade": gradeReport,
            "lut": lutReport,
            "gradeSourceWait": sourceWait,
            "gradeFirstPreviewWait": firstGradeWait,
            "gradeRecipeWait": recipeWait,
            "gradePreviewReady": host.gradePreviewImage != nil,
            "gradeExportWait": gradeExportWait,
            "gradeExportBytes": gradeBytes,
            "gradeExportPath": gradeFile?.lastPathComponent ?? "",
            "gradeAnalysis": host.gradeAnalysis?.summary ?? "",
        ]
        let data = try JSONSerialization.data(withJSONObject: report,
                                              options: [.sortedKeys, .prettyPrinted])
        print(String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func wait(_ timeout: Double, _ condition: () -> Bool) async -> Double {
        var elapsed = 0.0
        while !condition() && elapsed < timeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
            elapsed += 0.1
        }
        return elapsed
    }

    /// 真实 RAW 上的参数扫描：预测与精算的亮度/反差/色差对比。
    private static func runParameterSweep(rawPath: String) throws -> [String: Any] {
        let loaded = try ImageLoader.load(url: URL(fileURLWithPath: rawPath))
        var edit = PhotoEdit()
        edit.io.inputColorSpace = loaded.colorSpace
        edit.io.inputCCTFDecoding = loaded.cctfDecoding
        let base = try edit.runtimeParams()
        let key = PreviewLUTService.cacheKey(
            edit: edit, inputColorSpace: loaded.colorSpace, inputCCTF: loaded.cctfDecoding
        )
        let service = PreviewLUTService()
        let source = PreviewRenderer.prepared(loaded.image, maxSize: 256)
        guard let bundle = service.bundle(for: base, key: key) else { return [:] }

        func autoEV(_ params: RuntimePhotoParams) -> Double {
            guard params.camera.autoExposure else { return 0 }
            return PreviewLUTService.measureAutoEV(
                source: source, colorSpace: params.io.inputColorSpace,
                applyCCTFDecoding: params.io.inputCCTFDecoding,
                method: params.camera.autoExposureMethod
            )
        }

        func deterministic(_ params: RuntimePhotoParams) -> ImageRGB {
            var p = params
            p.debug.lutMode = false
            p.debug.deactivateSpatialEffects = true
            p.debug.deactivateStochasticEffects = true
            p.settings.previewMode = false
            p.filmRender.halation.boostEV = 0
            p.scanner.whiteCorrection = false
            p.scanner.blackCorrection = false
            p.scanner.unsharpMask = [0, 0]
            p.io.crop = false
            p.io.upscaleFactor = 1
            p.io.outputColorSpace = "ProPhoto RGB"
            p.io.outputCCTFEncoding = false
            return SimulationPipeline(params: p, keepTaps: false).process(source).rgbOut
        }

        func lumaStats(_ image: ImageRGB) -> (mean: Double, std: Double) {
            let values = stride(from: 0, to: image.data.count, by: 3).map { i -> Double in
                0.2126 * image.data[i] + 0.7152 * image.data[i + 1] + 0.0722 * image.data[i + 2]
            }
            let mean = values.reduce(0, +) / Double(max(values.count, 1))
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(max(values.count, 1))
            return (mean, sqrt(max(variance, 0)))
        }

        func trueDisplay(_ params: RuntimePhotoParams, effects: Bool = true) -> ImageRGB {
            var p = params
            p.settings.previewMode = false
            p.io.crop = false
            p.io.upscaleFactor = 1
            p.io.outputColorSpace = "sRGB"
            p.io.outputCCTFEncoding = true
            if !effects {
                p.debug.deactivateSpatialEffects = true
                p.debug.deactivateStochasticEffects = true
                p.filmRender.halation.boostEV = 0
                p.scanner.whiteCorrection = false
                p.scanner.blackCorrection = false
                p.scanner.unsharpMask = [0, 0]
            }
            return SimulationPipeline(params: p, keepTaps: false).process(source).rgbOut
        }

        func summarize(_ params: RuntimePhotoParams) -> [String: Double] {
            let predicted = bundle.predict(
                source: source, autoEV: autoEV(params),
                exposureEV: params.camera.exposureCompensationEV,
                printExposure: params.enlarger.printExposure,
                compensate: params.enlarger.printExposureCompensation
            )
            let det = deterministic(params)
            let stats = CIEDE2000.stats(reference: det, candidate: predicted)
            let p = lumaStats(predicted)
            let d = lumaStats(det)
            let predictedDisplay = PreviewLUTService.displayImage(
                fromLinear: predicted, params: params
            )
            let actualDisplay = trueDisplay(params)
            let noFxDisplay = trueDisplay(params, effects: false)
            let pd = lumaStats(predictedDisplay)
            let ad = lumaStats(actualDisplay)
            let nd = lumaStats(noFxDisplay)
            return [
                "modelMax": stats?.max ?? -1,
                "modelP99": stats?.p99 ?? -1,
                "predMean": p.mean,
                "detMean": d.mean,
                "predStd": p.std,
                "detStd": d.std,
                "meanDelta": p.mean - d.mean,
                "dispPredMean": pd.mean,
                "dispTrueMean": ad.mean,
                "dispPredStd": pd.std,
                "dispTrueStd": ad.std,
                "dispMeanDelta": pd.mean - ad.mean,
                "dispNoFxMean": nd.mean,
                "dispNoFxStd": nd.std,
            ]
        }

        var report: [String: Any] = [:]
        report["ev0"] = summarize(base)
        for ev in [-2.0, -1.0, 1.0, 2.0] {
            var p = base
            p.camera.exposureCompensationEV = ev
            report["ev\(ev)"] = summarize(p)
        }
        var compOffMeans: [Double] = []
        var compOffMaxMeanDelta = 0.0
        for ev in [-2.0, -1.0, 0.0, 1.0, 2.0] {
            var p = base
            p.camera.exposureCompensationEV = ev
            p.enlarger.printExposureCompensation = false
            let summary = summarize(p)
            report["compOff_ev\(ev)"] = summary
            compOffMeans.append(summary["dispPredMean"] ?? 0)
            compOffMaxMeanDelta = max(
                compOffMaxMeanDelta, abs(summary["dispMeanDelta"] ?? 0)
            )
        }
        report["compOffMonotonic"] = zip(compOffMeans, compOffMeans.dropFirst())
            .allSatisfy { $0 < $1 }
        report["compOffMaxMeanDelta"] = compOffMaxMeanDelta
        for brightness in [0.5, 0.7, 1.4, 2.0] {
            var p = base
            p.enlarger.printExposure = brightness
            report["print\(brightness)"] = summarize(p)
        }
        return report
    }

    /// LUT 预览回归：烘焙、预测 vs 精算、ΔE₀₀ 门禁与查表耗时。
    private static func runLUTSmoke() throws -> [String: Any] {
        let edit = PhotoEdit()
        guard let params = try? edit.runtimeParams() else {
            throw NSError(domain: "smoke", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "无法载入默认 profile"
            ])
        }
        let key = PreviewLUTService.cacheKey(
            edit: edit,
            inputColorSpace: params.io.inputColorSpace,
            inputCCTF: params.io.inputCCTFDecoding
        )
        var compOffEdit = edit
        compOffEdit.enlarger.printExposureCompensation = false
        let compOffKey = PreviewLUTService.cacheKey(
            edit: compOffEdit,
            inputColorSpace: params.io.inputColorSpace,
            inputCCTF: params.io.inputCCTFDecoding
        )
        let service = PreviewLUTService()
        let source = makeLinearImage(96, 72)
        let bakeStart = Date()
        guard let bundle = service.bundle(for: params, key: key) else {
            throw NSError(domain: "smoke", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "LUT 烘焙失败"
            ])
        }
        let bakeMs = Date().timeIntervalSince(bakeStart) * 1000

        var autoEV = 0.0
        if params.camera.autoExposure {
            autoEV = PreviewLUTService.measureAutoEV(
                source: source, colorSpace: params.io.inputColorSpace,
                applyCCTFDecoding: params.io.inputCCTFDecoding,
                method: params.camera.autoExposureMethod
            )
        }
        guard let preflight = PreviewPreflight.run(
            source: source, params: params, bundle: bundle, autoEV: autoEV
        ) else {
            throw NSError(domain: "smoke", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "预检失败"
            ])
        }

        var directParams = params
        directParams.debug.lutMode = true
        directParams.settings.previewMode = false
        directParams.io.crop = false
        directParams.io.upscaleFactor = 1
        directParams.io.outputColorSpace = "ProPhoto RGB"
        directParams.io.outputCCTFEncoding = false
        let direct = SimulationPipeline(
            params: directParams, keepTaps: false
        ).process(source).rgbOut
        let smallPredicted = bundle.predict(
            source: source, autoEV: 0, exposureEV: 0,
            printExposure: 1, compensate: false
        )
        var maxAbs = 0.0
        for i in 0..<direct.data.count {
            maxAbs = max(maxAbs, abs(direct.data[i] - smallPredicted.data[i]))
        }
        let large = makeLinearImage(800, 600)
        let predictStart = Date()
        let predicted = bundle.predict(
            source: large, autoEV: autoEV,
            exposureEV: params.camera.exposureCompensationEV,
            printExposure: params.enlarger.printExposure,
            compensate: params.enlarger.printExposureCompensation
        )
        let predictMs = Date().timeIntervalSince(predictStart) * 1000
        let displayStart = Date()
        let displayed = PreviewLUTService.displayImage(
            fromLinear: predicted, params: params
        )
        let displayMs = Date().timeIntervalSince(displayStart) * 1000
        let finite = predicted.data.allSatisfy(\.isFinite)
            && displayed.data.allSatisfy(\.isFinite)

        let pairs: [((Double, Double, Double), (Double, Double, Double), Double)] = [
            ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
            ((50, 3.1571, -77.2803), (50, 0, -82.7485), 2.8615),
            ((50, 2.8361, -74.0200), (50, 0, -82.7485), 3.4412),
            ((50, -1.3802, -84.2814), (50, 0, -82.7485), 1.0000),
            ((50, -1.1848, -84.8006), (50, 0, -82.7485), 1.0000),
            ((50, -0.9009, -85.5211), (50, 0, -82.7485), 1.0000),
        ]
        var deltaEError = 0.0
        for (first, second, expected) in pairs {
            let a = CIEDE2000.Lab(l: first.0, a: first.1, b: first.2)
            let b = CIEDE2000.Lab(l: second.0, a: second.1, b: second.2)
            deltaEError = max(deltaEError, abs(CIEDE2000.deltaE(a, b) - expected))
        }

        return [
            "resolution": bundle.resolution,
            "bakeMs": bakeMs,
            "predictMs": predictMs,
            "displayMs": displayMs,
            "predictedFinite": finite,
            "autoEV": autoEV,
            "modelMax": preflight.model.max,
            "modelP99": preflight.model.p99,
            "effectsMax": preflight.effects.max,
            "effectsP99": preflight.effects.p99,
            "preflightOK": preflight.ok,
            "notice": preflight.notice ?? "",
            "deltaEMaxError": deltaEError,
            "modelAbsDiff": maxAbs,
            "compCacheKeyStable": compOffKey == key,
        ]
    }

    private static func makeLinearImage(_ width: Int, _ height: Int) -> ImageRGB {
        var data = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(max(width - 1, 1))
                let v = Double(y) / Double(max(height - 1, 1))
                let p = (y * width + x) * 3
                data[p] = 0.01 + 2.4 * pow(u, 2.4) + 0.02 * v
                data[p + 1] = 0.01 + 1.2 * pow(v, 2.0) + 0.3 * pow(u, 1.2)
                data[p + 2] = 0.02 + 0.9 * pow((u + v) / 2, 1.8)
            }
        }
        return ImageRGB(width: width, height: height, data: data)
    }

    /// 调色引擎回归：identity 配方与 sRGB 编码一致、暖调输出有限、identity LUT 不改变像素。
    private static func runGradeSmoke() throws -> [String: Any] {
        let width = 32
        let height = 32
        var data = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 3
                data[index] = Double(x) / Double(width - 1)
                data[index + 1] = Double(y) / Double(height - 1)
                data[index + 2] = Double((x + y) % 17) / 17.0
            }
        }
        let source = ImageRGB(width: width, height: height, data: data)
        let identity = try GradeEngine.render(source, recipe: GradeRecipe(), analyze: false)

        func encode(_ value: Double) -> Double {
            let positive = max(value, 0)
            return positive <= 0.0031308
                ? positive * 12.92
                : 1.055 * pow(positive, 1.0 / 2.4) - 0.055
        }
        var identityDiff = 0.0
        for i in 0..<data.count {
            let expected = min(max(encode(data[i]), 0), 1)
            identityDiff = max(identityDiff, abs(identity.image.data[i] - expected))
        }

        let warm = GradeRecipe(
            light: LightRecipe(contrast: 6, highlights: -8),
            color: ColorRecipe(
                temperature: 12, vibrance: 8,
                grading: ColorGrading(
                    shadows: GradeZone(hue: 30, saturation: 8),
                    highlights: GradeZone(hue: 40, saturation: 18)
                )
            ),
            transparency: TransparencyRecipe(tonal: 10, color: 0)
        )
        let warmResult = try GradeEngine.render(source, recipe: warm, analyze: false)
        let warmFinite = warmResult.image.data.allSatisfy(\.isFinite)

        let lutURL = URL(fileURLWithPath: "/tmp/spektra_smoke_identity.cube")
        let cube = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        try cube.write(to: lutURL, atomically: true, encoding: .utf8)
        let lutRecipe = GradeRecipe(lut: LutRecipe(path: lutURL.path, strength: 100))
        let lutResult = try GradeEngine.render(source, recipe: lutRecipe, analyze: false)
        var lutDiff = 0.0
        for i in 0..<data.count {
            lutDiff = max(lutDiff, abs(lutResult.image.data[i] - identity.image.data[i]))
        }

        return [
            "identityMaxDiff": identityDiff,
            "warmFinite": warmFinite,
            "lutIdentityMaxDiff": lutDiff,
        ]
    }
}
