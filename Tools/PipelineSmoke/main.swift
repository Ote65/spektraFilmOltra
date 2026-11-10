import Foundation

func logLine(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

@main
struct PipelineSmoke {
    static func main() throws {
        let film = try ProfileStore.load("kodak_portra_400")
        let paper = try ProfileStore.load("kodak_supra_endura")
        if ProcessInfo.processInfo.environment["SPEKTRA_DUMP_INTERP"] != nil {
            let curves = MorphCurves.applyPrintCurvesMorph(
                logExposure: paper.data.logExposure,
                model: paper.data.densityCurvesModel,
                params: PrintCurvesMorphParams(),
                profileType: paper.info.type
            )
            let x = 0.041299865491
            let single = ImageRGB(width: 1, height: 1, data: [x, x, x])
            let out = DensityCurves.developSimple(
                logRaw: single, logExposure: paper.data.logExposure,
                densityCurves: curves, gammaFactor: [1, 1, 1]
            )
            logLine("interp x \(String(format: "%.12f", x))")
            logLine("logE 110 \(String(format: "%.12f", paper.data.logExposure[110])) 111 \(String(format: "%.12f", paper.data.logExposure[111]))")
            logLine("curve 110 \(String(format: "%.12f", curves[110][0])) 111 \(String(format: "%.12f", curves[111][0]))")
            logLine("interp out \(String(format: "%.12f", out.data[0]))")
        }
        if ProcessInfo.processInfo.environment["SPEKTRA_DUMP_MORPH"] != nil {
            let curves = MorphCurves.applyPrintCurvesMorph(
                logExposure: paper.data.logExposure,
                model: paper.data.densityCurvesModel,
                params: PrintCurvesMorphParams(),
                profileType: paper.info.type
            )
            for i in [0, 64, 109, 110, 111, 112, 128, 200, 255] {
                logLine("morph \(i) " + String(format: "%.12f %.12f %.12f",
                    curves[i][0], curves[i][1], curves[i][2]))
            }
        }
        if ProcessInfo.processInfo.environment["SPEKTRA_DUMP_CAT"] != nil {
            let source = ColorMath.xyToXYZ(0.3457, 0.3585)
            let destination = ColorMath.xyToXYZ(0.3127, 0.329)
            for basis in [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)] {
                let value = ColorMath.adapt(basis, sourceWhite: source, destinationWhite: destination, transform: ColorMath.cat02)
                logLine("cat \(String(format: "%.12f %.12f %.12f", value.x, value.y, value.z))")
            }
        }
        if ProcessInfo.processInfo.environment["SPEKTRA_DUMP_COLOR"] != nil {
            let xyz = Vec3(0.2, 0.3, 0.4)
            let rgb = ColorMath.xyzToRGB(xyz, spaceName: "sRGB", illuminantXY: (0.3457, 0.3585),
                                         applyCCTFEncoding: false)
            logLine("color \(String(format: "%.12f %.12f %.12f", rgb.x, rgb.y, rgb.z))")
        }
        var params = RuntimePhotoParams(film: film, print: paper)
        params.camera.autoExposure = false
        params.camera.exposureCompensationEV = 0
        params.camera.diffusionFilter.active = false
        params.filmRender.grain.active = false
        params.filmRender.halation.active = false
        params.filmRender.dirCouplers.active = false
        params.printRender.glare.active = false
        params.enlarger.diffusionFilter.active = false
        params.scanner.lensBlur = 0
        params.scanner.unsharpMask = [0, 0]
        params.scanner.blackCorrection = false
        params.scanner.whiteCorrection = false
        params.io.inputGamutCompressActive = ProcessInfo.processInfo.environment["SPEKTRA_NO_INPUT_COMPRESS"] == nil
        params.io.outputGamutCompressAlgorithm = "off"
        params.settings.useEnlargerLUT = ProcessInfo.processInfo.environment["SPEKTRA_NO_ENLARGER_LUT"] == nil
        params.settings.useScannerLUT = ProcessInfo.processInfo.environment["SPEKTRA_NO_SCANNER_LUT"] == nil
        params.settings.lutResolution = 17
        params.settings.useFastStats = false
        params.io.scanFilm = false
        if ProcessInfo.processInfo.environment["SPEKTRA_NO_CCTF"] != nil {
            params.io.outputCCTFEncoding = false
        }
        let env = ProcessInfo.processInfo.environment
        if env["SPEKTRA_COUPLERS"] != nil { params.filmRender.dirCouplers.active = true }
        if env["SPEKTRA_GRAIN"] != nil {
            params.filmRender.grain.active = true
            params.filmRender.grain.sublayersActive = true
        }
        if env["SPEKTRA_GLARE"] != nil { params.printRender.glare.active = true }
        if let algorithm = env["SPEKTRA_OUTPUT"] {
            params.io.outputGamutCompressAlgorithm = algorithm
        }
        if env["SPEKTRA_ENLARGER_DIFFUSION"] != nil {
            params.enlarger.diffusionFilter.active = true
            params.enlarger.diffusionFilter.filterFamily = "black_pro_mist"
            params.enlarger.diffusionFilter.strength = 0.5
        }
        let spatial = ProcessInfo.processInfo.environment["SPEKTRA_SPATIAL"] != nil
        if spatial {
            params.filmRender.halation.active = true
            params.scanner.unsharpMask = [0.7, 0.7]
        }
        let values: [Double] = [
            0.18, 0.18, 0.18,
            0.50, 0.30, 0.20,
            0.90, 0.60, 0.10,
            0.05, 0.20, 0.50,
        ]
        var image = ImageRGB(width: 2, height: 2, data: values)
        if spatial {
            image = ImageRGB(width: 32, height: 24)
            for y in 0..<24 {
                for x in 0..<32 {
                    let dx = Double(x) - 8
                    let dy = Double(y) - 8
                    let glow = 0.8 * exp(-(dx * dx + dy * dy) / 30)
                    image.setPixel(x, y, Vec3(
                        0.03 + glow + 0.1 * Double(x) / 31,
                        0.02 + 0.6 * glow + 0.2 * Double(y) / 23,
                        0.01 + 0.3 * glow + 0.1 * Double(x + y) / 54
                    ))
                }
            }
        }
        let pipeline = SimulationPipeline(params: params)
        let result = pipeline.process(image, progress: { label, step, total in
            logLine("progress \(label) \(step)/\(total)")
        })
        let sampleIndices = spatial ? [0, 8 * 32 + 8, 10 * 32 + 20, 23 * 32 + 31] : [0, 1, 2, 3]
        for (name, img) in [
            ("rgb_pre", result.rgbPre),
            ("log_e_film", result.logEFilm),
            ("cmy_film", result.cmyFilm),
            ("log_e_print", result.logEPrint!),
            ("cmy_print", result.cmyPrint!),
            ("rgb_out", result.rgbOut),
        ] {
            for index in sampleIndices {
                logLine("\(name) \(index) " + String(format: "%.12f %.12f %.12f",
                     img.data[index * 3], img.data[index * 3 + 1], img.data[index * 3 + 2]))
            }
        }
        _ = image
    }
}

