import Foundation
import simd

/// 密度域颗粒模型的 GPU 参数拟合。
///
/// 不做"显示域叠白噪声"：直接复用物理 `GrainParams` 的统计量，换算到
/// t2 输出 CMY 密度域的幅度包络与团簇尺度（方案 4.3）。幅度包络在中密度
/// 达峰、阴影/高光收敛，逐帧重随机。
enum VideoGrainModel {
    /// 设置页「GPU 物理颗粒」开关：落在 UserDefaults，core 与 UI 共用同一份值。
    /// 打开 = 逐像素 Poisson-Binomial 卤化银粒子；关闭 = 原 valueNoise 密度域颗粒。
    static let physicalGrainKey = "video.grain.physicalGPU"
    static var physicalGrainEnabled: Bool {
        UserDefaults.standard.object(forKey: physicalGrainKey) as? Bool ?? false
    }

    struct Fitted {
        var enabled = false
        /// CMY 密度域的每通道幅度（已乘快速轴 grain_amount）。
        var amplitude = SIMD3<Float>(0, 0, 0)
        /// 颗粒团簇 σ（像素），从 particleAreaUM2 与 pixelSizeUM 换算。
        var sigma: Float = 1
        /// 局部密度包络的起点（densityMin）。
        var densityMin = SIMD3<Float>(0.03, 0.03, 0.03)
        /// 均匀度（越接近 1 越均匀）。
        var uniformity = SIMD3<Float>(0.97, 0.99, 0.97)
        /// 帧种子基值（clipID 混合）。
        var seed: UInt32 = 0
    }

    /// - Parameters:
    ///   - edit: 复用照片的快速轴/专业参数。
    ///   - longEdgePixels: 输出的像素长边，用于 μm→px 换算。
    ///   - clipSeed: 片段稳定哈希，避免同工程不同片段颗粒同相。
    static func fit(edit: PhotoEdit, longEdgePixels: Int, clipSeed: UInt32) -> Fitted {
        let g = edit.filmRender.grain
        // quickIntents 存的是 UI 百分比（100 = 标准强度），必须 /100 才是幅度倍率。
        // 曾经这里直接用百分比当倍率，100 → 100×，画面爆成彩色雪花。
        let amount = max(0, (edit.quickIntents["grain_amount"] ?? 100.0)) / 100.0
        // UI 轴是 -100…100 的百分比，必须归一化后再当指数：
        // 之前直接把百分比当指数，滑条动 1% 就是 2 倍，几格内顶到钳位上限，看着像"没反应"。
        let sizeAxis = (edit.quickIntents["grain_size"] ?? 0.0) / 100.0

        var fitted = Fitted()
        guard g.active, amount > 0 else { return fitted }

        // filmFormatMM=35 时 1080p 长边像素尺寸 ≈ 32.4 μm；按长边线性缩放。
        let filmMM = edit.camera.filmFormatMM > 0 ? edit.camera.filmFormatMM : 35
        let pixelSizeUM = filmMM * 1000.0 / Double(max(longEdgePixels, 1))

        // 快速 grain_size 轴：0 为默认，满量程让团簇尺度约 0.33×~3×。
        // 面积按尺度平方走，柔化半径同步缩放——只改面积的话，
        // 0.65px 的固定 blur 会把尺寸变化完全吃掉，滑条看起来毫无反应。
        let sizeMul = pow(2.0, sizeAxis * 1.6)
        let areaUM2 = max(g.particleAreaUM2, 0.001) * sizeMul * sizeMul
        let sigma = sqrt(areaUM2) / max(pixelSizeUM, 1e-6) + Double(g.blur) * sizeMul
        fitted.sigma = Float(min(max(sigma, 0.4), 24))

        // 幅度：densityMin 是物理模型的密度底噪，均匀度越高暗部越收敛；
        // 快速轴只缩放幅度，不改变通道比（通道比来自物理统计）。
        let density = g.densityMin
        let uniformity = g.uniformity
        let base: Double = 0.5 * amount  // 归一化到 wire2 [0,1] 的经验系数
        fitted.amplitude = SIMD3<Float>(
            Float(base * clamp01(density[0]) * (1.15 - 0.30 * clamp01(uniformity[0]))),
            Float(base * clamp01(density[1]) * (1.15 - 0.30 * clamp01(uniformity[1]))),
            Float(base * clamp01(density[2]) * (1.15 - 0.30 * clamp01(uniformity[2])))
        )
        fitted.densityMin = SIMD3<Float>(
            Float(clamp01(density[0])), Float(clamp01(density[1])), Float(clamp01(density[2])))
        fitted.uniformity = SIMD3<Float>(
            Float(clamp01(uniformity[0])), Float(clamp01(uniformity[1])), Float(clamp01(uniformity[2])))
        fitted.seed = clipSeed
        fitted.enabled = true
        return fitted
    }

    /// 稳定 clip 哈希（FNV-1a 64 位截低 32）。
    static func clipSeed(for id: String) -> UInt32 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return UInt32(truncatingIfNeeded: hash)
    }

    /// 物理颗粒 GPU 参数：把 GrainParams 的统计量换算成逐像素 Poisson-Binomial 的粒子数。
    /// 与照片端 `Grain.applyToDensity` 同源：n = pixelArea / particleArea，
    /// odParticle = densityMax / n；模糊与微结构直接沿用物理参数。
    struct PhysicalFitted {
        var enabled = false
        var n: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
        var densityMax: Float = 1.0
        var blurPx: Float = 0.65
        var microPx: Float = 0
        var uniformity: SIMD3<Float> = SIMD3<Float>(0.97, 0.99, 0.97)
    }

    /// - longEdgePixels：输出长边，用于 μm→px；filmFormatMM 取相机画幅。
    /// - sublayersActive 时按 particleScaleLayers 分摊到单层，层数取 nSubLayers（默认 1）。
    static func fitPhysical(edit: PhotoEdit, longEdgePixels: Int) -> PhysicalFitted {
        let g = edit.filmRender.grain
        var out = PhysicalFitted()
        guard g.active else { return out }

        let amount = max(0, (edit.quickIntents["grain_amount"] ?? 100.0)) / 100.0
        guard amount > 0 else { return out }
        let sizeAxis = (edit.quickIntents["grain_size"] ?? 0.0) / 100.0

        let filmMM = edit.camera.filmFormatMM > 0 ? edit.camera.filmFormatMM : 35
        let pixelSizeUM = filmMM * 1000.0 / Double(max(longEdgePixels, 1))
        let pixelArea = pixelSizeUM * pixelSizeUM

        // grain_size 快轴：面积随尺度平方，与 valueNoise 路径保持一致。
        let sizeMul = pow(2.0, sizeAxis * 1.6)
        let areaUM2 = max(g.particleAreaUM2, 0.001) * sizeMul * sizeMul
        let subLayers = g.sublayersActive ? max(g.nSubLayers, 1) : 1
        // 与 Grain.applyToDensity 一致：particles[c] = pixelArea / (area*scale[c]) / subLayers。
        // 幅度随 grain_amount 缩放：通过 n 反向缩放（n 越小颗粒越粗越大）。
        let nScale = max(pixelArea / areaUM2 / Double(subLayers), 1)
        let amountFactor = 1.0 / max(amount, 1e-3)   // amount=1 基准；越大 n 越小→颗粒越显著
        out.n = SIMD3<Float>(
            Float(min(max(nScale * amountFactor / max(g.particleScale[0], 1e-3), 1), 2_000_000)),
            Float(min(max(nScale * amountFactor / max(g.particleScale[1], 1e-3), 1), 2_000_000)),
            Float(min(max(nScale * amountFactor / max(g.particleScale[2], 1e-3), 1), 2_000_000)))

        // 密度上限：物理 density_max ≈ 2.2 + densityMin；这里用归一化 wire 域，
        // 取 valueNoise 幅度标定量级，确保增量落在 [0,1] 内可见但不溢出。
        out.densityMax = 1.0
        // dye-cloud blur + final blur 合并；微结构 σ = micro[1]*0.001/pixelSizeUM。
        out.blurPx = Float(min(max(g.blur * sizeMul, 0), 24))
        out.microPx = g.microStructure.count > 1
            ? Float(g.microStructure[1] * 0.001 / max(pixelSizeUM, 1e-6)) : 0
        out.uniformity = SIMD3<Float>(
            Float(clamp01(g.uniformity[0])), Float(clamp01(g.uniformity[1])),
            Float(clamp01(g.uniformity[2])))
        out.enabled = true
        return out
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }
}
