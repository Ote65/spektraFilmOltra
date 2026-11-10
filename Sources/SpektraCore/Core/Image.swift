import Foundation

/// 3 通道 HWC 图像。存储用 `Float`（12 字节/像素）：12 MP 一张是 146 MB，
/// 是 `Double`（24 字节/像素、293 MB）的一半，而所有算术仍在 `Double` 里做
/// —— 精度只在写回时落到 float32，逐像素变换的中间结果不受影响。
///
/// 读写都必须显式转换（`Double(data[i])` / `Float(value)`），
/// 这样编译器不会把整条链路悄悄降级成 float32。
struct ImageRGB {
    var width: Int
    var height: Int
    var data: [Float] // HWC, 3 channels

    init(width: Int, height: Int, data: [Float]? = nil) {
        self.width = width
        self.height = height
        let count = width * height * 3
        self.data = data ?? [Float](repeating: 0, count: count)
        precondition(self.data.count == count)
    }

    /// 从双精度缓冲构造（预测表、外部管线给的都是 `[Double]`）。
    init(width: Int, height: Int, data: [Double]) {
        self.width = width
        self.height = height
        let count = width * height * 3
        precondition(data.count == count)
        self.data = [Float](repeating: 0, count: count)
        for i in 0..<count { self.data[i] = Float(data[i]) }
    }

    init(width: Int, height: Int, r: Double, g: Double, b: Double) {
        self.width = width
        self.height = height
        self.data = [Float](repeating: 0, count: width * height * 3)
        let fr = Float(r), fg = Float(g), fb = Float(b)
        for i in 0..<(width * height) {
            data[i * 3] = fr
            data[i * 3 + 1] = fg
            data[i * 3 + 2] = fb
        }
    }

    subscript(x: Int, y: Int, c: Int) -> Double {
        get { Double(data[(y * width + x) * 3 + c]) }
        set { data[(y * width + x) * 3 + c] = Float(newValue) }
    }

    @inline(__always)
    static func value(_ data: [Float], _ index: Int) -> Double { Double(data[index]) }

    func pixel(_ x: Int, _ y: Int) -> Vec3 {
        Vec3(self[x, y, 0], self[x, y, 1], self[x, y, 2])
    }

    mutating func setPixel(_ x: Int, _ y: Int, _ value: Vec3) {
        self[x, y, 0] = value.x
        self[x, y, 1] = value.y
        self[x, y, 2] = value.z
    }

    /// 逐像素变换。
    ///
    /// **串行，但走裸指针**：早先的 `pixel()` / `setPixel()` 版本每像素做一次
    /// `Vec3` 装箱 + 三次带越界检查的 subscript，12 MP 单趟就要多花几百毫秒。
    ///
    /// 不要改成 `DispatchQueue.concurrentPerform`：管线里每次 map 都要新分配
    /// 一整张 12 MP 缓冲，多线程首次触页会在内核页表锁上打架。实测 4032 全流程
    /// 从 18.1 s 劣化到 23.7 s（user time 31 s → 126 s，全是缺页等待）。
    func map(_ transform: (Vec3) -> Vec3) -> ImageRGB {
        let width = self.width
        let height = self.height
        let count = width * height * 3
        guard count > 0 else { return ImageRGB(width: width, height: height) }
        let source = data
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            source.withUnsafeBufferPointer { input in
                guard let src = input.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let value = transform(Vec3(Double(src[offset]),
                                               Double(src[offset + 1]),
                                               Double(src[offset + 2])))
                    dst[offset] = Float(value.x)
                    dst[offset + 1] = Float(value.y)
                    dst[offset + 2] = Float(value.z)
                    offset += 3
                }
            }
        }
        return ImageRGB(width: width, height: height, data: out)
    }

    /// 原地逐像素变换。用于「上一步的结果已经是独占临时缓冲」的场景：
    /// 单独调用 `map` 会再分配一整个 12 MP 缓冲，这里直接写回原缓冲。
    ///
    /// 与 `map` 的区别只在内存，不在数值：同样的逐像素运算，同样的串行顺序。
    mutating func mapInPlace(_ transform: (Vec3) -> Vec3) {
        let count = data.count
        guard count > 0 else { return }
        data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let value = transform(Vec3(Double(base[offset]),
                                           Double(base[offset + 1]),
                                           Double(base[offset + 2])))
                base[offset] = Float(value.x)
                base[offset + 1] = Float(value.y)
                base[offset + 2] = Float(value.z)
                offset += 3
            }
        }
    }

    /// 把 NaN / ±Inf 归零。RAW 极端高光或零密度会在幂运算里产生非有限值，
    /// 后续色域压缩的查表索引不能承受这些值。
    func sanitizedNonFinite() -> ImageRGB {
        var output = self
        output.sanitizeNonFinite()
        return output
    }

    /// 原地版本。`var output = self` 之后第一次写入会触发整块 COW 拷贝
    /// （12 MP 就是再多 146 MB）；调用方拿到的本来就是临时结果时用这个。
    mutating func sanitizeNonFinite() {
        for i in 0..<data.count where !data[i].isFinite {
            data[i] = 0
        }
    }
}

enum ImageMath {
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    static func log10Safe(_ value: Double) -> Double {
        log10(max(value, 0) + 1e-10)
    }

    static func pow10(_ value: Double) -> Double {
        pow(10.0, value)
    }

    /// 逐像素热路径专用：`exp2` / `log2` 在 Apple silicon 上比 `pow(10,·)` / `log10`
    /// 少一次常数折叠，扫描阶段每像素要算上百次。
    static let log2ToLog10 = 0.301_029_995_663_981_2
    static let log10ToLog2 = 3.321_928_094_887_362_4

    @inline(__always)
    static func pow10Fast(_ value: Double) -> Double {
        exp2(value * log10ToLog2)
    }

    @inline(__always)
    static func log10Fast(_ value: Double) -> Double {
        log2(max(value, 0) + 1e-10) * log2ToLog10
    }
}
