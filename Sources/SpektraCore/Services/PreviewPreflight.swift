import Foundation

struct PreviewPreflightReport {
    let model: CIEDE2000.Stats
    let effects: CIEDE2000.Stats
    let ok: Bool
    let notice: String?
}

/// 导出前预检：LUT 预测 vs 确定性精算，以及确定性 vs 完整效果。
enum PreviewPreflight {
    static func run(source: ImageRGB, params: RuntimePhotoParams,
                    bundle: PreviewLUTService.Bundle,
                    autoEV: Double) -> PreviewPreflightReport? {
        guard !params.io.scanFilm else { return nil }

        let predicted = bundle.predict(
            source: source, autoEV: autoEV,
            exposureEV: params.camera.exposureCompensationEV,
            printExposure: params.enlarger.printExposure,
            compensate: params.enlarger.printExposureCompensation
        )

        var deterministic = params
        deterministic.debug.lutMode = false
        deterministic.debug.deactivateSpatialEffects = true
        deterministic.debug.deactivateStochasticEffects = true
        deterministic.settings.previewMode = false
        deterministic.filmRender.halation.boostEV = 0
        deterministic.scanner.whiteCorrection = false
        deterministic.scanner.blackCorrection = false
        deterministic.scanner.unsharpMask = [0, 0]
        deterministic.io.crop = false
        deterministic.io.upscaleFactor = 1
        deterministic.io.outputColorSpace = "ProPhoto RGB"
        deterministic.io.outputCCTFEncoding = false

        let deterministicImage = SimulationPipeline(
            params: deterministic, keepTaps: false
        ).process(source).rgbOut

        var full = params
        full.debug.lutMode = false
        full.settings.previewMode = false
        full.io.crop = false
        full.io.upscaleFactor = 1
        full.io.outputColorSpace = "ProPhoto RGB"
        full.io.outputCCTFEncoding = false
        let fullImage = SimulationPipeline(
            params: full, keepTaps: false
        ).process(source).rgbOut

        guard let model = CIEDE2000.stats(
            reference: deterministicImage, candidate: predicted
        ), let effects = CIEDE2000.stats(
            reference: deterministicImage, candidate: fullImage
        ) else { return nil }

        let ok = model.max <= 2.0 && model.p99 <= 1.0
        let notice: String?
        if !ok {
            notice = "预测预览与精算结果存在可见差异，交付按精算结果。"
        } else if effects.p99 > 0.5 {
            notice = "预览为预测帧，不含颗粒/光晕等特效；导出按完整精算生成。"
        } else {
            notice = nil
        }
        return PreviewPreflightReport(
            model: model, effects: effects, ok: ok, notice: notice
        )
    }
}
