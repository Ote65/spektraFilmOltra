import Foundation

/// 扫描眩光：屏幕/镜头杂散光在 XYZ 上的加性随机底噪。
/// 对应 Python `model/glare.py`；随机项只要求统计同构。
enum Glare {
    static func addGlare(_ xyz: ImageRGB, illuminantXYZ: Vec3, params: GlareParams?,
                         seed: UInt64 = 11) -> ImageRGB {
        var output = xyz
        applyGlareInPlace(&output, illuminantXYZ: illuminantXYZ, params: params, seed: seed)
        return output
    }

    /// 原地加眩光。调用方传入的是独占临时缓冲时用它，省掉一整块 12 MP 的 COW 拷贝。
    /// 每个像素只依赖自己的值，所以在原缓冲上写回是安全的，数值与 `addGlare` 一致。
    /// `rowSeeded` 供分带导出使用：每行按绝对行号播种，条带之间不会重复同一段噪声。
    static func applyGlareInPlace(_ xyz: inout ImageRGB, illuminantXYZ: Vec3, params: GlareParams?,
                                  seed: UInt64 = 11, rowOffset: Int = 0,
                                  rowSeeded: Bool = false) {
        guard let params, params.active, params.percent > 0 else { return }
        let width = xyz.width
        let height = xyz.height
        let count = width * height
        var amount = [Double](repeating: 0, count: count)
        if rowSeeded {
            for y in 0..<height {
                // 与颗粒一致：先做雪崩混合再播种，避免相邻行共用同一随机流的相邻位置。
                var rng = SplitMix64(seed: Grain.rowSeed(seed, rowOffset + y))
                let start = y * width
                for i in start..<(start + width) {
                    amount[i] = RandomStats.lognormalFromMeanStd(
                        params.percent, params.roughness * params.percent, &rng
                    )
                }
            }
        } else {
            var rng = SplitMix64(seed: seed)
            for i in 0..<count {
                amount[i] = RandomStats.lognormalFromMeanStd(
                    params.percent, params.roughness * params.percent, &rng
                )
            }
        }
        amount = FastGaussian.filterChannel(amount, width: width, height: height, sigma: params.blur)
        xyz.data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<count {
                let value = amount[i] / 100
                base[i * 3] = Float(Double(base[i * 3]) + value * illuminantXYZ.x)
                base[i * 3 + 1] = Float(Double(base[i * 3 + 1]) + value * illuminantXYZ.y)
                base[i * 3 + 2] = Float(Double(base[i * 3 + 2]) + value * illuminantXYZ.z)
            }
        }
    }
}
