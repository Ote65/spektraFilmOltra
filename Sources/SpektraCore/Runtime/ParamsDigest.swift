import Foundation

/// 对齐 Python `runtime/params_builder.py` 的 `digest_params` 中与胶片相关的出厂设定。
/// 这些覆盖值不是通用默认，而是按胶片类型 / 出片型号分档。
enum ParamsDigest {
    static func applyFilmSpecifics(_ params: inout RuntimePhotoParams) {
        if params.film.info.isPositive {
            params.filmRender.dirCouplers.gammaSameLayerRGB = [0.12, 0.08, 0.06]
            params.filmRender.dirCouplers.gammaInterlayerRToGB = [0.12, 0.06]
            params.filmRender.dirCouplers.gammaInterlayerGToRB = [0.08, 0.06]
            params.filmRender.dirCouplers.gammaInterlayerBToRG = [0.06, 0.06]
        }
        if params.film.info.isNegative {
            params.filmRender.dirCouplers.gammaSameLayerRGB = [0.336, 0.319, 0.273]
            params.filmRender.dirCouplers.gammaInterlayerRToGB = [0.353, 0.302]
            params.filmRender.dirCouplers.gammaInterlayerGToRB = [0.154, 0.353]
            params.filmRender.dirCouplers.gammaInterlayerBToRG = [0.168, 0.226]
        }
        applyHalationPreset(&params)
        if params.film.info.stock == "fujifilm_velvia_100" {
            params.filmRender.dirCouplers.gammaSameLayerRGB = [0.108, 0.072, 0.054]
            params.filmRender.dirCouplers.gammaInterlayerRToGB = [0.108, 0.054]
            params.filmRender.dirCouplers.gammaInterlayerGToRB = [0.072, 0.054]
            params.filmRender.dirCouplers.gammaInterlayerBToRG = [0.054, 0.054]
        }
        if params.film.info.stock == "fujifilm_provia_100f" {
            params.filmRender.dirCouplers.gammaSameLayerRGB = [0.156, 0.104, 0.078]
            params.filmRender.dirCouplers.gammaInterlayerRToGB = [0.156, 0.078]
            params.filmRender.dirCouplers.gammaInterlayerGToRB = [0.104, 0.078]
            params.filmRender.dirCouplers.gammaInterlayerBToRG = [0.078, 0.078]
        }
    }

    static func applyHalationPreset(_ params: inout RuntimePhotoParams) {
        guard params.film.info.isFilm else { return }
        let key = "\(params.film.info.use)|\(params.film.info.antihalation)"
        let sigma: [Double]
        let strength: [Double]
        switch key {
        case "still|strong": sigma = [65, 65, 65]; strength = [0.015, 0.005, 0.0]
        case "still|weak": sigma = [65, 65, 65]; strength = [0.08, 0.02, 0.0]
        case "still|no": sigma = [65, 65, 65]; strength = [0.30, 0.10, 0.015]
        case "cine|strong": sigma = [50, 50, 50]; strength = [0.015, 0.005, 0.0]
        case "cine|weak": sigma = [50, 50, 50]; strength = [0.08, 0.02, 0.0]
        case "cine|no": sigma = [50, 50, 50]; strength = [0.30, 0.10, 0.015]
        default: return
        }
        params.filmRender.halation.halationFirstSigmaUM = sigma
        params.filmRender.halation.halationStrength = strength
    }
}
