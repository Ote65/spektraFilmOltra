import Foundation

/// 可复现的随机数发生器（SplitMix64）。Python 侧 numba 并行 RNG 本身
/// 不可逐像素复现，因此这里只要求分布算法同构。
struct SplitMix64 {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) {
        self.state = seed
        self.spare = nil
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        let value = Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return value > 0 ? value : Double.leastNonzeroMagnitude
    }

    mutating func nextNormal() -> Double {
        if let value = spare {
            spare = nil
            return value
        }
        var u1 = nextDouble()
        var u2 = nextDouble()
        if u1 <= 0 { u1 = Double.leastNonzeroMagnitude }
        let radius = sqrt(-2.0 * log(u1))
        let theta = 2.0 * Double.pi * u2
        spare = radius * sin(theta)
        return radius * cos(theta)
    }
}

enum RandomStats {
    static func poisson(_ lambda: Double, _ rng: inout SplitMix64) -> Int64 {
        if lambda <= 0 { return 0 }
        if lambda < 30 {
            let limit = exp(-lambda)
            var probability = 1.0
            var k: Int64 = 0
            while probability > limit {
                k += 1
                probability *= rng.nextDouble()
            }
            return k - 1
        }
        let z = rng.nextNormal()
        let sample = (lambda + sqrt(lambda) * z).rounded(.toNearestOrEven)
        return sample < 0 ? 0 : Int64(sample)
    }

    static func binomial(_ n: Int64, _ p: Double, _ rng: inout SplitMix64) -> Int64 {
        if p <= 0 { return 0 }
        if p >= 1 { return n }
        // 对称采样：p > 0.5 时改数「未显影」粒子，避免反演法在 p≈1 时线性走 n 次。
        let flipped = p > 0.5
        let q = flipped ? 1 - p : p
        let value = binomialLower(n, q, &rng)
        return flipped ? n - value : value
    }

    private static func binomialLower(_ n: Int64, _ p: Double, _ rng: inout SplitMix64) -> Int64 {
        if n < 25 {
            var count: Int64 = 0
            for _ in 0..<n where rng.nextDouble() < p { count += 1 }
            return count
        }
        let mean = Double(n) * p
        let variance = Double(n) * p * (1.0 - p)
        if variance > 10 {
            let z = rng.nextNormal()
            let approx = (mean + sqrt(variance) * z).rounded(.toNearestOrEven)
            if approx < 0 { return 0 }
            if approx > Double(n) { return n }
            return Int64(approx)
        }
        let u = rng.nextDouble()
        var cdf = 0.0
        var probability = pow(1.0 - p, Double(n))
        var k: Int64 = 0
        while cdf < u && k <= n {
            cdf += probability
            if k < n {
                probability = probability * (Double(n - k) / Double(k + 1)) * (p / (1.0 - p))
            }
            k += 1
        }
        return k - 1
    }

    static func lognormalFromMeanStd(_ mean: Double, _ std: Double, _ rng: inout SplitMix64) -> Double {
        if mean <= 0 { return exp(0.0) }
        let sigma2 = log(1.0 + (std * std) / (mean * mean))
        let sigma = sqrt(sigma2)
        let mu = log(mean) - sigma2 / 2.0
        if sigma < 1e-6 { return exp(mu) }
        return exp(mu + sigma * rng.nextNormal())
    }
}
