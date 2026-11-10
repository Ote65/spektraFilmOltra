import Foundation
import Darwin

/// 性能基线工具：在 macOS 上用同一套 SpektraCore 量化解码 / 精算 / LUT 预测 / 导出编码成本。
/// 用法：
///   SPEKTRA_BENCH_IMAGE=/path/to/photo.dng ./bench.sh
/// 环境变量：
///   SPEKTRA_BENCH_SIZES=960,1600,2048,4096   精算长边档位，默认 960,1600,4032
///   SPEKTRA_BENCH_LUT=33,65                   LUT 分辨率，默认 33,65
///   SPEKTRA_BENCH_ROUNDS=1                   每档重复次数

@main
struct Bench {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SPEKTRA_BENCH_IMAGE"] else {
            FileHandle.standardError.write("缺少 SPEKTRA_BENCH_IMAGE\n".data(using: .utf8)!)
            exit(2)
        }
        let sizes = (env["SPEKTRA_BENCH_SIZES"] ?? "960,1600,4032")
            .split(separator: ",").compactMap { Int($0) }
        let lutSizes = (env["SPEKTRA_BENCH_LUT"] ?? "33,65")
            .split(separator: ",").compactMap { Int($0) }
        let rounds = max(1, Int(env["SPEKTRA_BENCH_ROUNDS"] ?? "1") ?? 1)

        let url = URL(fileURLWithPath: path)
        if env["SPEKTRA_BENCH_THUMB"] != nil {
            let start = Date()
            do {
                let image = try RawDecoder.decodeThumbnail(url: url, maxSize: 1600)
                line("thumbnail \(image.width)x\(image.height) \(String(format: "%.2f s", Date().timeIntervalSince(start)))")
            } catch {
                line("thumbnail failed: \(error)  \(String(format: "%.2f s", Date().timeIntervalSince(start)))")
            }
            return
        }
        var edit = PhotoEdit()
        let detected = ImageLoader.detectColorSpace(url: url)
        edit.io.inputColorSpace = detected.space
        edit.io.inputCCTFDecoding = detected.cctfDecoding

        let decodeStart = Date()
        let loaded = try ImageLoader.load(url: url)
        let decodeElapsed = Date().timeIntervalSince(decodeStart)
        let rawMemory = memoryMB(loaded.image)

        line("== Spektrafilm 性能基线 ==")
        line("图片: \(url.lastPathComponent)")
        line("尺寸: \(loaded.image.width)x\(loaded.image.height)  (\(String(format: "%.1f", Double(loaded.image.width * loaded.image.height) / 1_000_000)) MP)")
        line("输入: \(loaded.colorSpace)  CCTF解码=\(loaded.cctfDecoding)")
        line("解码耗时: \(ms(decodeElapsed))")
        line("单缓冲内存: \(String(format: "%.1f", rawMemory)) MB  (Double×3ch)")
        line("进程常驻: \(String(format: "%.1f", rssMB())) MB")
        line("")

        var params = try edit.runtimeParams()
        params.io.inputColorSpace = loaded.colorSpace
        params.io.inputCCTFDecoding = loaded.cctfDecoding
        if env["SPEKTRA_BENCH_NO_STOCHASTIC"] != nil {
            params.debug.deactivateStochasticEffects = true
        }
        // 与 `MobileDevelopSession.renderAccurate` 的实际预览配置对齐：
        // 打开 previewMode（关空间效应）并关掉随机颗粒，颗粒由近似层补。
        if env["SPEKTRA_BENCH_PREVIEW"] != nil {
            params.settings.previewMode = true
            params.debug.deactivateStochasticEffects = true
        }

        line("--- 精算管线 SimulationPipeline ---")
        for size in sizes {
            let prepared = PreviewRenderer.prepared(loaded.image, maxSize: size)
            var best = Double.infinity
            var result: PipelineResult?
            for _ in 0..<rounds {
                let start = Date()
                let pipe = SimulationPipeline(params: params, keepTaps: false)
                var stageTimes: [(String, Double)] = []
                var last = Date()
                result = pipe.process(prepared, progress: { label, _, _ in
                    stageTimes.append((label, Date().timeIntervalSince(last)))
                    last = Date()
                })
                best = min(best, Date().timeIntervalSince(start))
                if size == sizes[0] {
                    for (label, seconds) in stageTimes {
                        let padded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
                        line("        \(padded) \(String(format: "%8.3f s", seconds))")
                    }
                }
            }
            let pixels = prepared.width * prepared.height
            let total = Double(pixels) / 1_000_000
            line(String(format: "%5d 长边  %4dx%-4d  %6.2f MP  %8.2f s  %6.1f MP/s",
                        size, prepared.width, prepared.height, total, best, total / best))
            if let result {
                let outMem = memoryMB(result.rgbOut)
                line("         输出缓冲 \(String(format: "%.1f", outMem)) MB   进程常驻 \(String(format: "%.0f", rssMB())) MB")
                // SPEKTRA_BENCH_DUMP=<dir> 时把结果落盘，用于改动前后对拍：
                // `out-<size>.png` 供人眼看，`out-<size>.bin` 是原始数据（逐值比对，float32）。
                if let dumpDir = env["SPEKTRA_BENCH_DUMP"], !dumpDir.isEmpty {
                    let dir = URL(fileURLWithPath: dumpDir)
                    try? ImageExport.save(result.rgbOut, to: dir.appendingPathComponent("out-\(size).png"),
                                           bitDepth: 8, colorSpace: "sRGB")
                    var raw = Data()
                    raw.reserveCapacity(result.rgbOut.data.count * MemoryLayout<Float>.size)
                    result.rgbOut.data.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        let bytes = UnsafeRawPointer(base)
                            .assumingMemoryBound(to: UInt8.self)
                        raw.append(bytes, count: buffer.count * MemoryLayout<Float>.size)
                    }
                    try? raw.write(to: dir.appendingPathComponent("out-\(size).bin"))
                }
            }
        }

        line("")
        line("--- LUT 预测快路径 ---")
        guard !params.io.scanFilm else {
            line("正片扫描模式，跳过预测")
            return
        }
        let previewSource = PreviewRenderer.prepared(loaded.image, maxSize: 960)
        let key = PreviewLUTService.cacheKey(
            edit: edit, inputColorSpace: loaded.colorSpace, inputCCTF: loaded.cctfDecoding)
        for size in lutSizes {
            let service = PreviewLUTService()
            let bakeStart = Date()
            _ = service.bundle(for: params, key: key, resolution: size)
            let bakeElapsed = Date().timeIntervalSince(bakeStart)
            line(String(format: "烘焙 %2d³: %8.3f s", size, bakeElapsed))

            let warm = PreviewLUTService()
            _ = warm.bundle(for: params, key: key, resolution: size)
            var best = Double.infinity
            for _ in 0..<max(2, rounds) {
                guard let bundle = warm.bundle(for: params, key: key, resolution: size) else { continue }
                let start = Date()
                _ = bundle.predict(source: previewSource)
                best = min(best, Date().timeIntervalSince(start))
            }
            line(String(format: "预测 %2d³ @960: %8.3f s", size, best))
        }
        line("")
        line("--- 预测帧参数敏感度（交互近似层）---")
        if let bundle = PreviewLUTService().bundle(for: params, key: key, resolution: 33) {
            let neutral = predict(bundle, previewSource)
            let cases: [(String, PreviewAdjustments.Params)] = [
                ("印相冷暖 +100", PreviewAdjustments.Params(yShift: 60)),
                ("品红/绿 +100", PreviewAdjustments.Params(mShift: 60)),
                ("反差 +100", PreviewAdjustments.Params(gamma: 1.35)),
                ("色浓度 +100", PreviewAdjustments.Params(saturation: 1.5)),
                ("清晰度 +100", PreviewAdjustments.Params(clarity: 1)),
            ]
            for (name, axes) in cases {
                let changed = predict(bundle, previewSource, axes: axes)
                let padded = name.padding(toLength: 14, withPad: " ", startingAt: 0)
                line("\(padded)  平均Δ \(String(format: "%5.2f", meanDelta(neutral, changed)))/255"
                    + "  最大Δ \(String(format: "%5.1f", maxDelta(neutral, changed)))/255")
            }
            let combos = PreviewAdjustments.Params(
                yShift: 60, mShift: 60, gamma: 1.35, saturation: 1.5, clarity: 1)
            let all = predict(bundle, previewSource, axes: combos)
            let padded = "全部拉满".padding(toLength: 14, withPad: " ", startingAt: 0)
            line("\(padded)  平均Δ \(String(format: "%5.2f", meanDelta(neutral, all)))/255"
                + "  最大Δ \(String(format: "%5.1f", maxDelta(neutral, all)))/255")
        }

        line("")
        line("进程峰值常驻: \(String(format: "%.0f", peakRSSMB())) MB")
    }

    private static func predict(_ bundle: PreviewLUTService.Bundle, _ source: ImageRGB,
                                axes: PreviewAdjustments.Params = PreviewAdjustments.Params()) -> [Double] {
        let linear = bundle.predict(source: source)
        let adjusted = PreviewAdjustments.applyLinear(linear, params: axes)
        let encoded = PreviewLUTService.displayImage(fromLinear: adjusted)
        let display = PreviewAdjustments.applyDisplay(encoded, params: axes)
        return display.data.map { min(max(Double($0), 0), 1) * 255 }
    }

    private static func meanDelta(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in 0..<a.count { sum += abs(a[i] - b[i]) }
        return sum / Double(a.count)
    }

    private static func maxDelta(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var maximum = 0.0
        for i in 0..<a.count { maximum = max(maximum, abs(a[i] - b[i])) }
        return maximum
    }

    private static func memoryMB(_ image: ImageRGB) -> Double {
        // float32 存储：每像素 3 通道 × 4 字节。
        Double(image.data.count * 4) / 1_000_000
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private static func line(_ text: String) {
        print(text)
    }

    private static func rssMB() -> Double {
        Double(taskInfo().resident_size) / 1_000_000
    }

    private static func peakRSSMB() -> Double {
        Double(taskInfo().resident_size_max) / 1_000_000
    }

    private static func taskInfo() -> mach_task_basic_info {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result != KERN_SUCCESS { return mach_task_basic_info() }
        return info
    }
}
