import Foundation

func log(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

@main
struct CoreSmoke {
    static func main() throws {
        log("start")
        let store = ColorDataStore.shared
        log("cmfs \(store.cmfs.count) \(store.cmfs.first?.count ?? 0)")
        log("spaces \(store.spaces.keys.sorted())")
        let profile = try ProfileStore.load("kodak_portra_400")
        log("profile \(profile.info.name) \(profile.data.wavelengths.count) \(profile.data.logSensitivity.count) \(profile.data.densityCurves.count)")
        log("lut \(SpectralUpsampling.lut.size) \(SpectralUpsampling.lut.channels)")
        let sensitivity = profile.data.logSensitivity.map { row in
            row.map { value in
                let v = pow(10.0, value)
                return v.isFinite ? v : 0
            }
        }
        var adaptation = profile.hanatos2025Adaptation
        adaptation.applyWindow = true
        adaptation.applySurface = false
        let tcLUT = SpectralUpsampling.computeHanatosTCPLUT(sensitivity: sensitivity, adaptation: adaptation)
        let samples: [(String, Vec3)] = [
            ("gray18", Vec3(0.184, 0.184, 0.184)),
            ("white", Vec3(1, 1, 1)),
            ("red", Vec3(1, 0, 0)),
            ("green", Vec3(0, 1, 0)),
            ("blue", Vec3(0, 0, 1)),
            ("skin", Vec3(0.65, 0.42, 0.32)),
        ]
        for (name, rgb) in samples {
            let raw = SpectralUpsampling.rgbToRawHanatos(
                rgb, sensitivity: sensitivity, colorSpace: "ProPhoto RGB",
                applyCCTFDecoding: false, referenceIlluminant: profile.info.referenceIlluminant,
                tcLUT: tcLUT
            )
            log("\(name) \(String(format: "%.9f %.9f %.9f", raw.x, raw.y, raw.z))")
        }

        let interpReport = try runScalarInterpolationSmoke()
        log("scalar interp max diff \(interpReport)")
        let libraryReport = try runLibraryIndexOrderingSmoke()
        log("library index ordering \(libraryReport)")
    }

    /// 回归：标量轴 interp1D 的倒数缓冲只有 count-1 项，lerp 不能按 3 通道步长取下标。
    /// 修复前这里会读到缓冲区外，斜率变成随机值。
    private static func runScalarInterpolationSmoke() throws -> Double {
        let axis: [Double] = [0, 0.05, 0.2, 0.45, 0.8, 1.2, 1.8, 2.5, 3.2, 4.0]
        let yValues: [[Double]] = axis.map { value in
            [value * 2 + 0.5, 1.2 - value * 0.25, 0.3 + value * value * 0.5]
        }
        let samples: [Double] = [
            -0.6, -0.1, 0.01, 0.05, 0.12, 0.2, 0.32, 0.45, 0.62, 0.8,
            1.0, 1.2, 1.5, 1.8, 2.15, 2.5, 2.85, 3.2, 3.6, 4.0, 4.4,
        ]
        var image = ImageRGB(width: samples.count, height: 1)
        for (index, value) in samples.enumerated() {
            image[index, 0, 0] = value
            image[index, 0, 1] = value
            image[index, 0, 2] = value
        }
        let output = Interpolation.interp1D(image: image, xAxis: axis, yValues: yValues)

        func reference(_ value: Double, _ channel: Int) -> Double {
            if value <= axis[0] { return yValues[0][channel] }
            if value >= axis[axis.count - 1] { return yValues[axis.count - 1][channel] }
            var index = 1
            while index < axis.count, axis[index] <= value { index += 1 }
            let low = index - 1
            let t = (value - axis[low]) / (axis[low + 1] - axis[low])
            return yValues[low][channel] + t * (yValues[low + 1][channel] - yValues[low][channel])
        }

        var worst = 0.0
        for (index, value) in samples.enumerated() {
            for channel in 0..<3 {
                worst = max(worst, abs(output[index, 0, channel] - reference(value, channel)))
            }
        }
        // float32 存储，单次写回量化误差 ~1e-7。
        guard worst <= 1e-5 else {
            throw NSError(domain: "smoke", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "scalar interp1D drift: \(worst)"
            ])
        }
        return worst
    }

    /// 回归：索引的异步快照写不能覆盖更晚的同步保存。
    /// 先排队一次旧快照，再同步导入第二张；落盘后索引必须包含两张。
    private static func runLibraryIndexOrderingSmoke() throws -> Int {
        // 旧索引没有 loadRaw 子对象：解码必须回退默认值，否则加字段会让整库读成空。
        let legacyEdit = Data(#"{"filmStock":"kodak_portra_400","printStock":"kodak_supra_endura"}"#.utf8)
        let decodedEdit = try JSONDecoder().decode(PhotoEdit.self, from: legacyEdit)
        guard decodedEdit.loadRaw.whiteBalance == "as_shot",
              decodedEdit.loadRaw.lensCorrection,
              decodedEdit.camera.exposureCompensationEV == 0 else {
            throw NSError(domain: "smoke", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "legacy PhotoEdit decode lost defaults"
            ])
        }

        let root = URL(fileURLWithPath: "/tmp/spektra_core_smoke_library")
        try? FileManager.default.removeItem(at: root)
        let store = LibraryStore(root: root)
        let temp = URL(fileURLWithPath: "/tmp/spektra_core_smoke_source.dng")
        let bytes = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        try bytes.write(to: temp)

        let first = try store.importPhoto(from: temp)
        var edited = first
        edited.favorite = true
        // 异步快照 = 1 张，尚未落盘。
        try store.update(edited)
        // 同步保存 = 2 张，必须排在前面那次异步写之后。
        let secondURL = URL(fileURLWithPath: "/tmp/spektra_core_smoke_source2.dng")
        try bytes.write(to: secondURL)
        _ = try store.importPhoto(from: secondURL)
        Thread.sleep(forTimeInterval: 0.15)

        let indexURL = root.appendingPathComponent("index.json")
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode([LibraryPhoto].self, from: data)
        guard decoded.count == 2 else {
            throw NSError(domain: "smoke", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "index lost photos: \(decoded.count)"
            ])
        }

        // 移除也必须先落盘再删文件：索引里不应留下指向已删原图的条目。
        try store.remove(id: first.id)
        let afterRemove = try JSONDecoder().decode(
            [LibraryPhoto].self, from: try Data(contentsOf: indexURL))
        guard afterRemove.count == 1, !afterRemove.contains(where: { $0.id == first.id }) else {
            throw NSError(domain: "smoke", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "remove kept stale entry"
            ])
        }
        return decoded.count
    }
}

