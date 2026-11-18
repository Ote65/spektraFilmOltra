import Foundation

/// 复用 `PreviewLUTService` 烘焙四段 65³ LUT，导出 GPU payload。
/// 不改照片核心：只调用 bake 结果，全部连续轴由 uniform 施加（方案 3.1）。
final class VideoLUTBaker: @unchecked Sendable {
    private let preview = PreviewLUTService()

    /// 烘焙 LUT。参考帧测光得到的 autoEV 由调用方作为 uniform 传入，
    /// 因此不进烘焙键（避免逐帧/逐测光重复烘焙）。
    /// - Parameters:
    ///   - edit: 视频工程持有的照片参数
    ///   - resolution: 65³
    /// - Returns: GPU payload；scanFilm（正片）v1 不支持，返回 nil
    func bake(edit: PhotoEdit, resolution: Int = PreviewLUTService.defaultResolution) -> VideoLUTPayload? {
        var e = edit
        // 视频输入固定线性 ProPhoto：帧先在 VideoColorIO 转成线性 ProPhoto。
        e.io.inputColorSpace = "ProPhoto RGB"
        e.io.inputCCTFDecoding = false
        e.io.outputColorSpace = "sRGB"
        e.io.outputCCTFEncoding = false
        e.io.scanFilm = false
        e.camera.autoExposure = false

        let key = PreviewLUTService.cacheKey(
            edit: e, inputColorSpace: e.io.inputColorSpace, inputCCTF: e.io.inputCCTFDecoding)

        guard let params = try? e.runtimeParams(),
              let bundle = preview.bundle(for: params, key: key, resolution: resolution) else {
            return nil
        }
        return VideoLUTPayload(
            resolution: bundle.resolution,
            t1: bundle.t1, t2: bundle.t2, t3: bundle.t3, t4: bundle.t4,
            wire1: bundle.wire1, wire2: bundle.wire2, wire3: bundle.wire3,
            encodedInput: bundle.encodedInput, bakedFactor: bundle.bakedFactor,
            cacheKey: key
        )
    }

    /// 计算印相曝光补偿比值（复用 Bundle 的补偿管线，不重烘）。
    func compRatio(edit: PhotoEdit, payload: VideoLUTPayload) -> Double {
        guard edit.enlarger.printExposureCompensation else { return 1.0 }
        var e = edit
        e.io.inputColorSpace = "ProPhoto RGB"
        e.io.inputCCTFDecoding = false
        e.io.outputColorSpace = "sRGB"
        e.io.outputCCTFEncoding = false
        e.io.scanFilm = false
        e.camera.autoExposure = false
        guard let params = try? e.runtimeParams(),
              let bundle = preview.bundle(for: params, key: payload.cacheKey,
                                          resolution: payload.resolution) else {
            return 1.0
        }
        return bundle.compRatio(exposureEV: edit.camera.exposureCompensationEV, compensate: true)
    }
}
