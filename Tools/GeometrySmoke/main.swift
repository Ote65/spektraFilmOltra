import Foundation
import CoreGraphics
import CoreImage

func log(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

/// 线程安全取消标记（与 App 内 MCancelFlag 同语义，harness 独立编译所以自带一份）。
final class Flag {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

var failures = 0

func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        log("PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        log("FAIL \(name) \(detail)")
    }
}

/// 每个像素写入唯一标识值（r = 列号），用于断言采样落点。
func makeUniqueImage(width: Int, height: Int) -> ImageRGB {
    var image = ImageRGB(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            image[x, y, 0] = Double(x)
            image[x, y, 1] = Double(y)
            image[x, y, 2] = 0.5
        }
    }
    return image
}

func pixel(_ image: ImageRGB, _ x: Int, _ y: Int) -> (Double, Double, Double) {
    (image[x, y, 0], image[x, y, 1], image[x, y, 2])
}

func almost(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-4 }

@main
struct GeometrySmoke {
    static func main() {
        runIdentitySmoke()
        runCropWindowSmoke()
        runRotationSmoke()
        runMirrorSmoke()
        runCancelSmoke()
        runEffectSmoke()
        runCostSmoke()
        runQuickFrameSmoke()
        runGridSmoke()
        runSnapshotSmoke()
        runPerspectiveDirectionSmoke()
        runGPUParitySmoke()
        runGPUOrientationSmoke()
        runGPUFrameSmoke()
        if failures > 0 {
            log("GEOMETRY SMOKE FAILED: \(failures)")
            exit(1)
        }
        log("GEOMETRY SMOKE OK")
    }

    /// 恒等几何直接透传，不重采样。
    private static func runIdentitySmoke() {
        let source = makeUniqueImage(width: 4, height: 2)
        let result = MPhotoGeometry().apply(to: source)
        expect(result.width == 4 && result.height == 2 && result.data == source.data,
               "identity passthrough")
    }

    /// 只裁右半：输出 2×2，逐像素应精确落在源图第 2、3 列（grid=1，双线性节点在整数上）。
    private static func runCropWindowSmoke() {
        let source = makeUniqueImage(width: 4, height: 2)
        var geometry = MPhotoGeometry()
        geometry.crop = MPhotoGeometry.Crop(x: 0.5, y: 0, width: 0.5, height: 1)
        let result = geometry.apply(to: source)
        let ok = result.width == 2 && result.height == 2
            && almost(pixel(result, 0, 0).0, 2) && almost(pixel(result, 1, 0).0, 3)
            && almost(pixel(result, 0, 1).0, 2) && almost(pixel(result, 1, 1).0, 3)
            && almost(pixel(result, 0, 1).1, 1)
        expect(ok, "crop window maps to right half",
               "got \(result.width)x\(result.height) p(0,0)=\(pixel(result, 0, 0))")
    }

    /// 顺时针 90°：4×2 → 2×4，顶行应取源图左列自下而上。
    private static func runRotationSmoke() {
        let source = makeUniqueImage(width: 4, height: 2)
        var geometry = MPhotoGeometry()
        geometry.quarterTurns = 1
        let result = geometry.apply(to: source)
        let ok = result.width == 2 && result.height == 4
            && almost(pixel(result, 0, 0).0, 0) && almost(pixel(result, 0, 0).1, 1)
            && almost(pixel(result, 1, 0).0, 0) && almost(pixel(result, 1, 0).1, 0)
            && almost(pixel(result, 0, 3).0, 3) && almost(pixel(result, 0, 3).1, 1)
        expect(ok, "quarter turn clockwise",
               "got \(result.width)x\(result.height) p(0,0)=\(pixel(result, 0, 0)) p(1,0)=\(pixel(result, 1, 0)) p(0,3)=\(pixel(result, 0, 3))")
    }

    /// 水平镜像：输出 (0,y) 应取源图最右列。
    private static func runMirrorSmoke() {
        let source = makeUniqueImage(width: 4, height: 2)
        var geometry = MPhotoGeometry()
        geometry.flippedH = true
        let result = geometry.apply(to: source)
        let ok = almost(pixel(result, 0, 0).0, 3) && almost(pixel(result, 3, 0).0, 0)
        expect(ok, "horizontal mirror flips columns",
               "p(0,0)=\(pixel(result, 0, 0)) p(3,0)=\(pixel(result, 3, 0))")
    }

    /// 取消标记：预先取消时 ImageRGB 路径原样返回、RGBA8 路径返回 nil，不再全幅算完。
    private static func runCancelSmoke() {
        let source = makeUniqueImage(width: 4, height: 2)
        var geometry = MPhotoGeometry()
        geometry.straighten = 20
        let flag = Flag()
        flag.cancel()
        let result = geometry.apply(to: source) { flag.isCancelled }
        expect(result.width == 4 && result.height == 2 && result.data == source.data,
               "cancelled ImageRGB returns input")

        let buffer = MRGBACopy.Buffer(
            width: 4, height: 2,
            pixels: [UInt8](repeating: 128, count: 4 * 2 * 4)
        )
        let image = geometry.apply(buffer: buffer, shouldCancel: { flag.isCancelled })
        expect(image == nil, "cancelled buffer returns nil")
    }

    /// 水平/透视校正必须真实改变像素（回归「效果被抵消、完全无效」）。
    private static func runEffectSmoke() {
        let source = makeUniqueImage(width: 8, height: 8)
        var straighten = MPhotoGeometry()
        straighten.straighten = 20
        let rotated = straighten.apply(to: source)
        var changed = false
        for y in 0..<8 {
            for x in 0..<8 where !almost(pixel(rotated, x, y).0, Double(x)) {
                changed = true
            }
        }
        expect(changed && rotated.width == 8, "straighten changes pixels")

        var perspective = MPhotoGeometry()
        perspective.perspectiveV = 80
        let warped = perspective.apply(to: source)
        var differs = false
        for y in 0..<8 {
            for x in 0..<8 where !almost(pixel(warped, x, y).0, Double(x))
                || !almost(pixel(warped, x, y).1, Double(y)) {
                differs = true
            }
        }
        let finite = warped.data.allSatisfy { $0.isFinite }
        expect(differs && finite, "perspective changes pixels and stays finite")
    }

    /// 精帧成本上界：单应矩阵必须每帧只构造一次。
    private static func runCostSmoke() {
        let buffer = makeGradientBuffer(width: 400, height: 300)
        var geometry = MPhotoGeometry()
        geometry.straighten = 30
        geometry.perspectiveV = 60
        geometry.perspectiveH = -40

        let start = Date()
        let image = geometry.apply(buffer: buffer)
        let elapsed = Date().timeIntervalSince(start)
        expect(image != nil && elapsed < 0.6, "corrected frame under 0.6s",
               "elapsed=\(String(format: "%.3f", elapsed))s")
    }

    /// 拖动期快帧预算：压缩快照 1100 长边 → 输出 640、关闭超采样。
    /// 这是用户拖刻度时每一帧的真实成本，取 5 次中位数要求 < 60ms（≈15fps）。
    private static func runQuickFrameSmoke() {
        let buffer = makeGradientBuffer(width: 1100, height: 825)
        var geometry = MPhotoGeometry()
        geometry.straighten = 22
        geometry.perspectiveV = 45
        geometry.perspectiveH = -30

        var times: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            _ = geometry.apply(buffer: buffer, maxLongEdge: 640, maxGrid: 1)
            times.append(Date().timeIntervalSince(start))
        }
        times.sort()
        let median = times[times.count / 2]
        expect(median < 0.06, "quick frame budget under 60ms",
               "median=\(String(format: "%.3f", median))s all=\(times.map { String(format: "%.3f", $0) })")
    }

    /// 快帧必须真的跳过超采样：同一几何下 maxGrid=1 的耗时应明显低于 maxGrid=3。
    private static func runGridSmoke() {
        let buffer = makeGradientBuffer(width: 1100, height: 825)
        var geometry = MPhotoGeometry()
        geometry.straighten = 22
        geometry.perspectiveV = 45

        let fineStart = Date()
        _ = geometry.apply(buffer: buffer, maxLongEdge: 640, maxGrid: 3)
        let fine = Date().timeIntervalSince(fineStart)
        let quickStart = Date()
        _ = geometry.apply(buffer: buffer, maxLongEdge: 640, maxGrid: 1)
        let quick = Date().timeIntervalSince(quickStart)
        expect(quick < fine, "maxGrid=1 skips supersampling",
               "quick=\(String(format: "%.3f", quick))s fine=\(String(format: "%.3f", fine))s")
    }

    /// 压缩快照入内存时降采样，而不是先读整幅再缩。
    private static func runSnapshotSmoke() {
        let wide = makeGradientBuffer(width: 1600, height: 1200)
        guard let image = MRGBACopy.makeImage(pixels: wide.pixels,
                                              width: wide.width, height: wide.height) else {
            expect(false, "snapshot downsample on read", "makeImage failed")
            return
        }
        guard let buffer = MRGBACopy.read(image, maxLongEdge: 1100) else {
            expect(false, "snapshot downsample on read", "read failed")
            return
        }
        expect(buffer.width == 1100 && buffer.height == 825,
               "snapshot downsample on read",
               "got \(buffer.width)x\(buffer.height)")

        let full = MRGBACopy.read(image)
        expect(full?.width == 1600 && full?.height == 1200, "read without cap keeps size")
    }

    private static func makeGradientBuffer(width: Int, height: Int) -> MRGBACopy.Buffer {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = UInt8(i % 256)
            pixels[i * 4 + 1] = UInt8((i / 251) % 256)
            pixels[i * 4 + 2] = UInt8((i / 997) % 256)
            pixels[i * 4 + 3] = 255
        }
        return MRGBACopy.Buffer(width: width, height: height, pixels: pixels)
    }

    // MARK: - GPU（Core Image）取景路径

    /// 透视方向：正值必须把画面的一侧放大（采样范围变窄），才叫校正。
    /// 之前 `perspScale` 把最窄边放大回满幅，校正量被抵消，看起来就只剩整体放大。
    private static func runPerspectiveDirectionSmoke() {
        let n = 48
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 4
                pixels[i] = UInt8(x * 255 / (n - 1))
                pixels[i + 1] = 128
                pixels[i + 2] = 128
            }
        }
        let buffer = MRGBACopy.Buffer(width: n, height: n, pixels: pixels)

        var geometry = MPhotoGeometry()
        geometry.perspectiveV = 80
        guard let out = geometry.apply(buffer: buffer, maxLongEdge: n, maxGrid: 1),
              let read = MRGBACopy.read(out) else {
            expect(false, "perspective zooms the narrow edge", "render failed")
            return
        }
        func span(_ row: Int) -> Int {
            var low = 255, high = 0
            for x in 4..<(out.width - 4) {
                let value = Int(read.pixels[(row * out.width + x) * 4])
                low = min(low, value)
                high = max(high, value)
            }
            return high - low
        }
        let top = span(2)
        let bottom = span(out.height - 3)
        expect(top < bottom, "perspective zooms the narrow edge",
               "topSpan=\(top) bottomSpan=\(bottom)")
    }

    /// 裁切页预览现在走 Core Image。这里用连续梯度图对比 GPU 与 CPU 的落点，
    /// 确认两条实现是同一个几何（否则用户看到的取景与最终导出会对不上）。
    private static func runGPUParitySmoke() {
        let width = 800, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 255 / max(1, width - 1))
                pixels[i + 1] = UInt8(y * 255 / max(1, height - 1))
                pixels[i + 2] = 128
            }
        }
        guard let cg = MRGBACopy.makeImage(pixels: pixels, width: width, height: height) else {
            expect(false, "GPU perspective matches CPU", "makeImage failed")
            return
        }
        let buffer = MRGBACopy.Buffer(width: width, height: height, pixels: pixels)
        let context = CIContext(options: [.cacheIntermediates: false])

        var geometry = MPhotoGeometry()
        geometry.straighten = 12
        geometry.perspectiveV = 30
        guard let cpu = geometry.apply(buffer: buffer, maxLongEdge: 400, maxGrid: 1) else {
            expect(false, "GPU perspective matches CPU", "cpu render failed")
            return
        }
        guard let gpu = geometry.previewImage(
            from: CIImage(cgImage: cg), maxLongEdge: 400, context: context) else {
            expect(false, "GPU perspective matches CPU", "gpu render failed")
            return
        }
        guard let cpuBuffer = MRGBACopy.read(cpu), let gpuBuffer = MRGBACopy.read(gpu) else {
            expect(false, "GPU perspective matches CPU", "read back failed")
            return
        }
        // GPU 取景图按外接框出图（照片会溢出原画幅），CPU 输出是原画幅。
        // 这里把原画幅在 GPU 图里的位置算出来，再按归一化坐标逐点比对同一套几何。
        let bounds = geometry.warpBounds(sourceWidth: width, sourceHeight: height)
        let x0 = (0 - bounds.minX) / bounds.width * Double(gpu.width)
        let x1 = (1 - bounds.minX) / bounds.width * Double(gpu.width)
        let y0 = (0 - bounds.minY) / bounds.height * Double(gpu.height)
        let y1 = (1 - bounds.minY) / bounds.height * Double(gpu.height)
        var maxDiff = 0
        for v in [0.2, 0.5, 0.8] {
            for u in [0.2, 0.5, 0.8] {
                let cx = min(max(Int(u * Double(cpu.width)), 1), cpu.width - 2)
                let cy = min(max(Int(v * Double(cpu.height)), 1), cpu.height - 2)
                let gx = min(max(Int(x0 + u * (x1 - x0)), 1), gpu.width - 2)
                let gy = min(max(Int(y0 + v * (y1 - y0)), 1), gpu.height - 2)
                let ci = (cy * cpu.width + cx) * 4
                let gi = (gy * gpu.width + gx) * 4
                for c in 0..<3 {
                    maxDiff = max(maxDiff,
                                  abs(Int(cpuBuffer.pixels[ci + c]) - Int(gpuBuffer.pixels[gi + c])))
                }
            }
        }
        expect(maxDiff <= 12, "GPU perspective matches CPU",
               "maxDiff=\(maxDiff) cpu=\(cpu.width)x\(cpu.height) gpu=\(gpu.width)x\(gpu.height)")
    }

    /// 旋转 + 镜像方向必须与 CPU 一致（90° 网格上应完全对齐）。
    private static func runGPUOrientationSmoke() {
        let width = 400, height = 300
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 255 / max(1, width - 1))
                pixels[i + 1] = UInt8(y * 255 / max(1, height - 1))
                pixels[i + 2] = 128
            }
        }
        guard let cg = MRGBACopy.makeImage(pixels: pixels, width: width, height: height) else {
            expect(false, "GPU orientation matches CPU", "makeImage failed")
            return
        }
        let buffer = MRGBACopy.Buffer(width: width, height: height, pixels: pixels)
        let context = CIContext(options: [.cacheIntermediates: false])

        for turns in 0...3 {
            for flipped in [false, true] {
                // 恒等几何时 CPU 走透传（不缩放），没有可比性。
                if turns == 0, !flipped { continue }
                var geometry = MPhotoGeometry()
                geometry.quarterTurns = turns
                geometry.flippedH = flipped
                guard let cpu = geometry.apply(buffer: buffer, maxLongEdge: 200, maxGrid: 1),
                      let gpu = geometry.previewImage(
                        from: CIImage(cgImage: cg), maxLongEdge: 200, context: context),
                      cpu.width == gpu.width, cpu.height == gpu.height,
                      let cpuBuffer = MRGBACopy.read(cpu),
                      let gpuBuffer = MRGBACopy.read(gpu) else {
                    expect(false, "GPU orientation matches CPU", "turns=\(turns) flip=\(flipped) size mismatch")
                    return
                }
                var maxDiff = 0
                for y in stride(from: 2, to: cpu.height - 2, by: 7) {
                    for x in stride(from: 2, to: cpu.width - 2, by: 7) {
                        let i = (y * cpu.width + x) * 4
                        for c in 0..<3 {
                            maxDiff = max(maxDiff,
                                          abs(Int(cpuBuffer.pixels[i + c]) - Int(gpuBuffer.pixels[i + c])))
                        }
                    }
                }
                if maxDiff > 14 {
                    expect(false, "GPU orientation matches CPU",
                           "turns=\(turns) flip=\(flipped) maxDiff=\(maxDiff)")
                    return
                }
            }
        }
        expect(true, "GPU orientation matches CPU", "4 rotations x mirror")
    }

    /// GPU 单帧预算：裁切页拖动时的每一帧都要落在这里。
    private static func runGPUFrameSmoke() {
        guard let source = makeGradientImage(width: 1100, height: 825) else {
            expect(false, "GPU frame budget under 12ms", "makeImage failed")
            return
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        var geometry = MPhotoGeometry()
        geometry.straighten = 22
        geometry.perspectiveV = 45
        geometry.perspectiveH = -30
        let ci = CIImage(cgImage: source)

        var times: [Double] = []
        for _ in 0..<10 {
            let start = Date()
            _ = geometry.previewImage(from: ci, maxLongEdge: 1000, context: context)
            times.append(Date().timeIntervalSince(start))
        }
        times.sort()
        let median = times[times.count / 2]
        expect(median < 0.012, "GPU frame budget under 12ms",
               "median=\(String(format: "%.2f", median * 1000))ms")
    }

    private static func makeGradientImage(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 255 / max(1, width - 1))
                pixels[i + 1] = UInt8(y * 255 / max(1, height - 1))
                pixels[i + 2] = 128
            }
        }
        return MRGBACopy.makeImage(pixels: pixels, width: width, height: height)
    }
}
