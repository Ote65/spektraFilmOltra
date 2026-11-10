import Foundation

func parityLog(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

func writeJSON(_ object: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
    parityLog("wrote \(path)")
}

func array(_ values: [Double]) -> [Double] { values }

@main
struct ParityCheck {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let caseName = env["CASE"] ?? "couplers"
        let outPath = env["OUT"] ?? "/tmp/swift_parity.json"

        switch caseName {
        case "couplers":
            try couplers(outPath: outPath)
        case "grain_stats":
            try grainStats(outPath: outPath)
        case "grain_layers":
            try grainLayers(outPath: outPath)
        case "glare_stats":
            try glareStats(outPath: outPath)
        case "diffusion_psf":
            try diffusionPSF(outPath: outPath)
        case "diffusion_apply":
            try diffusionApply(outPath: outPath)
        case "halation":
            try halation(outPath: outPath)
        case "cam16":
            try cam16(outPath: outPath)
        case "jzazbz":
            try jzazbz(outPath: outPath)
        case "output_compress":
            try outputCompress(outPath: outPath)
        case "export":
            try exportFiles(outPath: outPath)
        case "raw":
            try rawDecode(outPath: outPath)
        case "autoexposure":
            try autoExposure(outPath: outPath)
        case "resize":
            try resize(outPath: outPath)
        case "bench":
            try bench(outPath: outPath)
        case "renderer":
            try rendererCase(outPath: outPath)
        case "library":
            try libraryCase(outPath: outPath)
        default:
            throw NSError(domain: "parity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unknown CASE \(caseName)"])
        }
    }

    static func normalizedCurves(_ curves: [[Double]]) -> [[Double]] {
        var normalized = curves.map { row in row.map { $0.isFinite ? $0 : 0 } }
        for c in 0..<3 {
            var minValue = Double.infinity
            for row in normalized { minValue = min(minValue, row[c]) }
            for i in 0..<normalized.count { normalized[i][c] -= minValue }
        }
        return normalized
    }

    static func couplers(outPath: String) throws {
        let film = try ProfileStore.load("kodak_portra_400")
        let curves = normalizedCurves(film.data.densityCurves)
        let values: [Double] = [
            0.18, 0.18, 0.18,
            0.50, 0.30, 0.20,
            0.90, 0.60, 0.10,
            0.05, 0.20, 0.50,
        ]
        let logRaw = ImageRGB(width: 2, height: 2, data: values)
        var params = RuntimePhotoParams(film: film, print: try ProfileStore.load("kodak_supra_endura"))
        params.camera.autoExposure = false
        let density = DensityCurves.developSimple(
            logRaw: logRaw, logExposure: film.data.logExposure,
            densityCurves: curves, gammaFactor: [1, 1, 1]
        )
        let output = Couplers.applyDensityCorrection(
            densityCMY: density, logRaw: logRaw, pixelSizeUM: 6.0,
            logExposure: film.data.logExposure, densityCurves: curves,
            params: params.filmRender.dirCouplers, profileType: film.info.type,
            gammaFactor: 1.0
        )
        try writeJSON(["density_cmy": output.data], to: outPath)
    }

    static func grainStats(outPath: String) throws {
        let film = try ProfileStore.load("kodak_portra_400")
        let width = 128
        let height = 128
        let levels: [Double] = [0.05, 0.30, 0.60, 1.00, 1.60]
        let band = height / levels.count
        var density = ImageRGB(width: width, height: height)
        for y in 0..<height {
            let level = levels[min(y / band, levels.count - 1)]
            for x in 0..<width {
                density.setPixel(x, y, Vec3(level, level, level))
            }
        }
        var params = GrainParams()
        params.active = true
        params.sublayersActive = true
        let curves = normalizedCurves(film.data.densityCurves)
        let output = Grain.apply(
            densityCMY: density, pixelSizeUM: 6.0, params: params,
            densityCurves: curves, densityCurvesLayers: film.data.densityCurvesLayers,
            profileType: film.info.type, bypass: false
        )
        var stats: [[String: Any]] = []
        for index in 0..<levels.count {
            let start = index * band
            let end = min((index + 1) * band, height)
            var mean = [Double](repeating: 0, count: 3)
            var m2 = [Double](repeating: 0, count: 3)
            let count = Double((end - start) * width)
            for y in start..<end {
                for x in 0..<width {
                    for c in 0..<3 {
                        let value = output[x, y, c]
                        mean[c] += value
                        m2[c] += value * value
                    }
                }
            }
            var std = [Double](repeating: 0, count: 3)
            for c in 0..<3 {
                mean[c] /= count
                let variance = max(m2[c] / count - mean[c] * mean[c], 0)
                std[c] = sqrt(variance)
            }
            stats.append(["level": levels[index], "mean": mean, "std": std])
        }
        try writeJSON(["bands": stats], to: outPath)
    }

    static func grainLayers(outPath: String) throws {
        let film = try ProfileStore.load("kodak_portra_400")
        let curves = normalizedCurves(film.data.densityCurves)
        let values: [Double] = [
            0.10, 0.20, 0.30,
            0.50, 0.60, 0.70,
            1.00, 0.90, 0.80,
            1.80, 1.50, 1.20,
        ]
        let density = ImageRGB(width: 4, height: 1, data: values)
        let layers = Grain.interpDensityCMYLayers(
            densityCMY: density, densityCurves: curves,
            densityCurvesLayers: film.data.densityCurvesLayers, positive: false
        )
        var flat: [Double] = []
        for point in layers { for layer in point { for value in layer { flat.append(value) } } }
        try writeJSON(["layers": flat], to: outPath)
    }

    static func glareStats(outPath: String) throws {
        let illuminant = Vec3(0.9504, 1.0, 1.0891)
        let width = 128
        let height = 128
        let base = ImageRGB(width: width, height: height)
        let output = Glare.addGlare(base, illuminantXYZ: illuminant, params: GlareParams())
        let count = Double(width * height)
        var delta = [Double](repeating: 0, count: 3)
        var delta2 = [Double](repeating: 0, count: 3)
        for i in 0..<(width * height) {
            let r = Double(output.data[i * 3])
            let g = Double(output.data[i * 3 + 1])
            let b = Double(output.data[i * 3 + 2])
            delta[0] += r
            delta[1] += g
            delta[2] += b
            delta2[0] += r * r
            delta2[1] += g * g
            delta2[2] += b * b
        }
        var mean = [Double](repeating: 0, count: 3)
        var std = [Double](repeating: 0, count: 3)
        for c in 0..<3 {
            mean[c] = delta[c] / count
            std[c] = sqrt(max(delta2[c] / count - mean[c] * mean[c], 0))
        }
        try writeJSON(["mean": mean, "std": std], to: outPath)
    }

    static func diffusionPSF(outPath: String) throws {
        var result: [String: Any] = [:]
        for family in ["glimmerglass", "black_pro_mist", "pro_mist", "cinebloom"] {
            let psf = DiffusionFilter.psf(
                width: 21, height: 21, family: family,
                spatialScale: 1.0, pixelSizeUM: 20.0, haloWarmth: 1.0, overrides: nil
            )
            result[family] = psf
        }
        try writeJSON(result, to: outPath)
    }

    static func diffusionApply(outPath: String) throws {
        let width = 16
        let height = 16
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image.setPixel(x, y, Vec3(
                    0.02 + 0.9 * Double(x) / 15.0,
                    0.01 + 0.6 * Double(y) / 15.0,
                    0.5 * exp(-Double((x - 5) * (x - 5) + (y - 6) * (y - 6)) / 8.0)
                ))
            }
        }
        var params = DiffusionFilterParams()
        params.active = true
        params.filterFamily = "glimmerglass"
        params.strength = 0.5
        let output = DiffusionFilter.apply(image, params: params, pixelSizeUM: 20.0)
        try writeJSON(["image": output.data], to: outPath)
    }

    static func halation(outPath: String) throws {
        let width = 5
        let height = 5
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    image.data[(y * width + x) * 3 + c] =
                        Float(Double((x + 1) * (y + 2) * (c + 1)) / 100.0)
                }
            }
        }
        let output = SpatialEffects.halation(
            image, params: HalationParams(), pixelSizeUM: 6.0)
        try writeJSON(["halation": output.data.map(Double.init)], to: outPath)
    }

    static func cam16(outPath: String) throws {
        let space = ColorDataStore.shared.spaces["sRGB"]!
        let setup = CAM16UCS.setup(whiteXYZ: space.whitepoint)
        let xyz = Vec3(0.6273, 0.58464, 0.269)
        let jab = CAM16UCS.xyzToJab(xyz, setup: setup)
        let back = CAM16UCS.jabToXYZ(jab, setup: setup)
        let whiteJab = CAM16UCS.xyzToJab(space.whitepoint, setup: setup)
        try writeJSON([
            "jab": [jab.x, jab.y, jab.z],
            "back": [back.x, back.y, back.z],
            "whiteJp": whiteJab.x,
        ], to: outPath)
    }

    static func outputCompress(outPath: String) throws {
        let values: [Double] = [
            0.18, 0.18, 0.18,
            1.20, 0.10, -0.10,
            0.05, 1.40, 0.60,
            0.90, 0.85, 0.05,
        ]
        let image = ImageRGB(width: 2, height: 2, data: values)
        var params = RuntimePhotoParams(film: try ProfileStore.load("kodak_portra_400"),
                                        print: try ProfileStore.load("kodak_supra_endura"))
        let output = OutputGamutCompression.apply(
            image, algorithm: ProcessInfo.processInfo.environment["ALGO"] ?? "cam16ucs",
            knee: params.io.outputGamutCompressKnee,
            outputColorSpace: "sRGB"
        )
        try writeJSON(["rgb": output.data], to: outPath)
    }

    static func jzazbz(outPath: String) throws {
        let space = ColorDataStore.shared.spaces["sRGB"]!
        let xyz = Vec3(0.20654008, 0.12197225, 0.05136952)
        let jab = JzAzBz.xyzToJzazbz(xyz)
        let back = JzAzBz.jzazbzToXYZ(jab)
        let whiteJz = JzAzBz.xyzToJzazbz(space.whitepoint).x
        try writeJSON([
            "jab": [jab.x, jab.y, jab.z],
            "back": [back.x, back.y, back.z],
            "whiteJz": whiteJz,
        ], to: outPath)
    }

    static func exportFiles(outPath: String) throws {
        let values: [Double] = [
            0.1, 0.2, 0.3,
            0.5, 0.6, 0.7,
            0.9, 1.2, 0.05,
        ]
        let image = ImageRGB(width: 3, height: 1, data: values)
        let base = "/tmp/spektra_export"
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_16.tif"),
                             bitDepth: 16, colorSpace: "sRGB")
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_8.tif"),
                             bitDepth: 8, colorSpace: "sRGB")
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_32.tif"),
                             bitDepth: 32, colorSpace: "ProPhoto RGB", cctfEncoding: false)
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_half.exr"),
                             bitDepth: 16, colorSpace: "ACES2065-1")
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_float.exr"),
                             bitDepth: 32, colorSpace: "ACES2065-1")
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_8.png"),
                             bitDepth: 8, colorSpace: "sRGB")
        try ImageExport.save(image, to: URL(fileURLWithPath: base + "_8.jpg"),
                             bitDepth: 8, colorSpace: "sRGB")
        try writeJSON(["values": values], to: outPath)
    }

    static func rawDecode(outPath: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAW_PATH"] else {
            throw NSError(domain: "parity", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "RAW_PATH required"])
        }
        let image = try RawDecoder.decode(
            url: URL(fileURLWithPath: path),
            options: RawDecoder.Options(
                whiteBalance: env["WB"] ?? "as_shot",
                outputColorSpace: env["OUTPUT_SPACE"] ?? "ACES2065-1"
            )
        )
        let mean = image.data.reduce(0) { $0 + Double($1) } / Double(image.data.count)
        try writeJSON([
            "width": image.width,
            "height": image.height,
            "mean": mean,
            "metadata": RawDecoder.metadata(url: URL(fileURLWithPath: path)) ?? [:],
        ], to: outPath)
    }

    static func autoExposure(outPath: String) throws {
        let large = ProcessInfo.processInfo.environment["PREVIEW"] == "1"
        let width = large ? 320 : 24
        let height = large ? 200 : 16
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.02 + 0.8 * Double(x) / Double(width - 1) * Double(y + 1) / Double(height)
                image.setPixel(x, y, Vec3(value, value * 0.7, value * 0.4))
            }
        }
        if large { image = Resize.smallPreview(image, maxSize: 256) }
        let methods = ["average", "median", "center_weighted", "partial", "matrix",
                       "multi_zone", "highlight_weighted"]
        var result: [String: Double] = [:]
        for method in methods {
            result[method] = AutoExposure.measureEV(
                image: image, colorSpace: "ProPhoto RGB",
                applyCCTFDecoding: false, method: method
            )
        }
        try writeJSON(result, to: outPath)
    }

    static func resize(outPath: String) throws {
        let width = 8
        let height = 6
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.05 + 0.9 * Double(x) / Double(width - 1)
                image.setPixel(x, y, Vec3(value, value * 0.6 + 0.1 * Double(y) / Double(height - 1), 0.2))
            }
        }
        let output = Resize.upscale(image, factor: 2.0)
        try writeJSON([
            "width": output.width,
            "height": output.height,
            "values": output.data,
        ], to: outPath)
    }

    static func bench(outPath: String) throws {
        let env = ProcessInfo.processInfo.environment
        let width = Int(env["W"] ?? "640") ?? 640
        let height = Int(env["H"] ?? "480") ?? 480
        let preview = env["PREVIEW"] == "1"
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.03 + 0.85 * Double(x) / Double(width - 1)
                image.setPixel(x, y, Vec3(
                    value,
                    value * 0.7 + 0.2 * Double(y) / Double(height - 1),
                    0.3
                ))
            }
        }
        var params = RuntimePhotoParams(
            film: try ProfileStore.load("kodak_portra_400"),
            print: try ProfileStore.load("kodak_supra_endura")
        )
        params.camera.autoExposure = false
        params.settings.previewMode = preview
        params.settings.lutResolution = 17
        params.settings.useFastStats = true
        params.camera.diffusionFilter.active = env["NO_DIFF"] == nil
        params.camera.diffusionFilter.filterFamily = "black_pro_mist"
        params.camera.diffusionFilter.strength = 0.5
        params.filmRender.grain.active = env["NO_GRAIN"] == nil
        params.filmRender.halation.active = env["NO_HALATION"] == nil
        params.filmRender.dirCouplers.active = env["NO_COUPLERS"] == nil
        if env["NO_USM"] != nil { params.scanner.unsharpMask = [0, 0] }
        let pipeline = SimulationPipeline(params: params, keepTaps: false)
        var timings: [String: Double] = [:]
        var last = Date()
        let start = Date()
        _ = pipeline.process(image, progress: { label, _, _ in
            let now = Date()
            timings[label] = now.timeIntervalSince(last)
            last = now
        })
        let elapsed = Date().timeIntervalSince(start)
        try writeJSON([
            "width": width, "height": height, "preview": preview,
            "seconds": elapsed, "stages": timings,
        ], to: outPath)
    }

    static func rendererCase(outPath: String) throws {
        let width = 160
        let height = 120
        var image = ImageRGB(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value = 0.05 + 0.8 * Double(x) / Double(width - 1)
                image.setPixel(x, y, Vec3(value, value * 0.8, 0.2))
            }
        }
        var params = RuntimePhotoParams(
            film: try ProfileStore.load("kodak_portra_400"),
            print: try ProfileStore.load("kodak_supra_endura")
        )
        params.camera.autoExposure = false
        params.camera.diffusionFilter.active = true
        let renderer = PreviewRenderer()
        let semaphore = DispatchSemaphore(value: 0)
        var seconds = 0.0
        renderer.render(params: params, image: image, maxSize: 160) { outcome in
            seconds = outcome.elapsed
            semaphore.signal()
        }
        renderer.invalidate() // 过期请求应被丢弃；下一次请求仍能完成
        renderer.render(params: params, image: image, maxSize: 160) { outcome in
            seconds = outcome.elapsed
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            throw NSError(domain: "parity", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "renderer timed out"])
        }
        try writeJSON(["seconds": seconds], to: outPath)
    }

    static func libraryCase(outPath: String) throws {
        let env = ProcessInfo.processInfo.environment
        let sample = URL(fileURLWithPath: env["SAMPLE"] ??
            "/Users/megmeet/Documents/开发 APP/SpektrafilmSwift/SpektraSkin/Sources/SpektraSkin/Resources/SamplePhotos/color-chart.jpg")
        let root = URL(fileURLWithPath: "/tmp/spektra_library_test")
        try? FileManager.default.removeItem(at: root)
        let store = LibraryStore(root: root)
        let photo = try store.importPhoto(from: sample)
        let loaded = try ImageLoader.load(url: store.originalURL(for: photo))
        var thumbnailParams = try photo.makeParams()
        thumbnailParams.settings.previewMode = true
        let thumbnail = SimulationPipeline(params: thumbnailParams, keepTaps: false)
            .process(Resize.smallPreview(loaded.image, maxSize: 256)).rgbOut
        try store.writeThumbnail(id: photo.id, image: thumbnail)
        store.reload()
        guard let reloaded = store.photos.first else {
            throw NSError(domain: "parity", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "library reload failed"])
        }
        let queue = ExportQueue()
        let semaphore = DispatchSemaphore(value: 0)
        var finalState: ExportJobState?
        queue.onUpdate = { state in
            if state.isFinished {
                finalState = state
                semaphore.signal()
            }
        }
        queue.enqueue(
            ExportRequest(photoID: reloaded.id,
                          destination: URL(fileURLWithPath: "/tmp/spektra_library_export.tif"),
                          bitDepth: 16),
            photo: reloaded
        )
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            throw NSError(domain: "parity", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "export timed out"])
        }
        try writeJSON([
            "photos": store.photos.count,
            "colorSpace": loaded.colorSpace,
            "cctfDecoding": loaded.cctfDecoding,
            "width": loaded.image.width,
            "height": loaded.image.height,
            "thumbnail": store.thumbnailURL(for: reloaded)?.path ?? "",
            "exportDone": finalState?.isFinished ?? false,
            "exportError": finalState?.error ?? "",
        ], to: outPath)
    }
}
