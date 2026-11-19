import Foundation

/// GPU 传输结构：四段 65³ LUT + 段间 wire 归一化 + 全部 uniform。
///
/// 数值完全来自 `PreviewLUTService.Bundle`，GPU 侧严格复刻
/// `Bundle.predict` 的查表顺序与偏移，保证视频与照片同色（方案 3.2）。
struct VideoLUTPayload {
    let resolution: Int
    let t1: PreviewLUTService.FloatLUT3D
    let t2: PreviewLUTService.FloatLUT3D
    let t3: PreviewLUTService.FloatLUT3D
    let t4: PreviewLUTService.FloatLUT3D

    let wire1: (lo: Double, hi: Double)
    let wire2: (lo: Double, hi: Double)
    let wire3: (lo: Double, hi: Double)
    let encodedInput: Bool
    let bakedFactor: Double

    /// 烘焙键；切工程/重启据此复用 payload。
    let cacheKey: String

    /// 采样次序：shaper → t1 → 相机EV → t2 → (颗粒在密度域) → t3 → 印相EV+补偿 → t4。
    var span1: Double { max(wire1.hi - wire1.lo, 1e-9) }
    var span2: Double { max(wire2.hi - wire2.lo, 1e-9) }
    var span3: Double { max(wire3.hi - wire3.lo, 1e-9) }

    /// 相机曝光在 t1 归一化坐标上的偏移：exposureEV * log10(2) / span1。
    func cameraOffset(exposureEV: Double) -> Double {
        exposureEV * log10(2.0) / span1
    }

    /// 印相曝光 + 补偿在 wire3 坐标上的偏移。
    func printOffset(printExposure: Double, compRatio: Double, compensate: Bool) -> Double {
        let base = log10(max(printExposure, 1e-10))
        let comp = compensate ? log10(max(compRatio, 1e-10)) : 0
        return (base + comp) / span3
    }

    /// 四张表摊成全精度字节流供 Metal 3D 纹理上传（rgba32Float）。
    /// 布局与 CPU 一致：`((r*n + g)*n + b)*3 + c`；Metal 3D 纹理用
    /// width=b, height=g, depth=r，故纹理 (x=b, y=g, z=r) 正好按此线性序。
    /// 用 float32 而非 float16：显存仅 ≈4.4MB/张，换来与 CPU predict 的 bit 级一致。
    struct PackedTable {
        let data: Data
        let size: Int
    }

    func packed(_ lut: PreviewLUTService.FloatLUT3D) -> PackedTable {
        let n = lut.size
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        for r in 0..<n {
            for g in 0..<n {
                for b in 0..<n {
                    let src = ((r * n + g) * n + b) * 3
                    let dst = ((r * n + g) * n + b) * 4
                    floats[dst] = lut.values[src]
                    floats[dst + 1] = lut.values[src + 1]
                    floats[dst + 2] = lut.values[src + 2]
                    floats[dst + 3] = 1
                }
            }
        }
        return PackedTable(
            data: Data(bytes: floats, count: floats.count * MemoryLayout<Float>.size),
            size: n
        )
    }

    /// 单像素预测（CPU 参考，用于 M0 对拍门禁）。严格复刻 Bundle.predict 的
    /// 三线性查表顺序与 clamp，颗粒关闭，因此可直接与 GPU 单帧逐像素比对。
    func predictLinear(
        input: SIMD3<Float>, autoEV: Double, exposureEV: Double,
        printExposure: Double, compensate: Bool, compRatio: Double
    ) -> SIMD3<Float> {
        let stage0 = encodedInput
            ? input * Float(pow(2.0, autoEV) / PreviewLUTService.encodedMax)
            : input
        var stage = simdFloat3ToArray(stage0)
        let shaped = !encodedInput

        PreviewLUTService.lookupInPlace(
            t1, values: &stage, width: 1, height: 1,
            shaped: shaped, shapedEVOffset: encodedInput ? 0 : autoEV)
        PreviewLUTService.applyOffset(&stage, offset: cameraOffset(exposureEV: exposureEV))
        PreviewLUTService.lookupInPlace(t2, values: &stage, width: 1, height: 1, shaped: false)
        PreviewLUTService.lookupInPlace(t3, values: &stage, width: 1, height: 1, shaped: false)
        PreviewLUTService.applyOffset(
            &stage,
            offset: printOffset(printExposure: printExposure, compRatio: compRatio, compensate: compensate))
        PreviewLUTService.lookupInPlace(t4, values: &stage, width: 1, height: 1, shaped: false)
        return SIMD3<Float>(Float(stage[0]), Float(stage[1]), Float(stage[2]))
    }

    private func simdFloat3ToArray(_ v: SIMD3<Float>) -> [Double] {
        [Double(v.x), Double(v.y), Double(v.z)]
    }
}
