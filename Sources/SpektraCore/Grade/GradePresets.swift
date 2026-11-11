import Foundation

struct GradePreset: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var recipe: GradeRecipe
    var builtin: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, recipe, builtin }

    init(id: String, name: String, recipe: GradeRecipe, builtin: Bool = false) {
        self.id = id
        self.name = name
        self.recipe = recipe
        self.builtin = builtin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "未命名"
        recipe = (try? c.decode(GradeRecipe.self, forKey: .recipe)) ?? GradeRecipe()
        builtin = (try? c.decode(Bool.self, forKey: .builtin)) ?? false
    }
}

struct GradeLUTEntry: Identifiable, Equatable {
    var name: String
    var path: String
    var id: String { path }
}

/// 调色预设与 LUT 库：内置 5 个预设 + 用户 JSON（Application Support/Spektrafilm）。
final class GradePresetStore {
    static let shared = GradePresetStore()

    private(set) var userPresets: [GradePreset] = []
    let directory: URL
    let lutDirectory: URL
    private var presetsURL: URL { directory.appendingPathComponent("grade_presets.json") }

    private struct Envelope: Codable {
        var schema: Int = 1
        var presets: [GradePreset]
    }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("Spektrafilm") ?? URL(fileURLWithPath: NSHomeDirectory())
        self.directory = base
        self.lutDirectory = base.appendingPathComponent("luts", isDirectory: true)
        try? FileManager.default.createDirectory(at: lutDirectory, withIntermediateDirectories: true)
        load()
    }

    var all: [GradePreset] { Self.builtins + userPresets }

    static let builtins: [GradePreset] = [
        GradePreset(id: "builtin:neutral", name: "中性", recipe: GradeRecipe(), builtin: true),

        GradePreset(
            id: "builtin:clean", name: "清透",
            recipe: GradeRecipe(
                light: LightRecipe(contrast: 8, shadows: 10, blacks: -6),
                transparency: TransparencyRecipe(tonal: 18, color: 0),
                quality: QualityRecipe(clarity: 8, texture: 0, dehaze: 0,
                                       sharpenAmount: 12, sharpenRadius: 1,
                                       sharpenThreshold: 0,
                                       noiseLuminance: 0, noiseColor: 0)
            ),
            builtin: true
        ),

        GradePreset(
            id: "builtin:warm", name: "暖调",
            recipe: GradeRecipe(
                light: LightRecipe(contrast: 6, highlights: -8),
                color: ColorRecipe(
                    temperature: 12, vibrance: 8,
                    grading: ColorGrading(
                        shadows: GradeZone(hue: 30, saturation: 8),
                        midtones: GradeZone(),
                        highlights: GradeZone(hue: 40, saturation: 18)
                    )
                ),
                transparency: TransparencyRecipe(tonal: 10, color: 0)
            ),
            builtin: true
        ),

        GradePreset(
            id: "builtin:cool-night", name: "冷夜",
            recipe: GradeRecipe(
                light: LightRecipe(exposure: -0.25, contrast: 10, blacks: -8),
                color: ColorRecipe(
                    temperature: -12, saturation: -6,
                    grading: ColorGrading(
                        shadows: GradeZone(hue: 225, saturation: 22),
                        midtones: GradeZone(),
                        highlights: GradeZone(hue: 210, saturation: 8)
                    )
                ),
                quality: QualityRecipe(clarity: 6)
            ),
            builtin: true
        ),

        GradePreset(
            id: "builtin:mono", name: "黑白",
            recipe: GradeRecipe(
                light: LightRecipe(contrast: 10, blacks: -6),
                color: ColorRecipe(saturation: -100),
                quality: QualityRecipe(clarity: 10)
            ),
            builtin: true
        ),
    ]

    @discardableResult
    func save(name: String, recipe: GradeRecipe) -> GradePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "未命名预设" : trimmed
        let preset = GradePreset(
            id: "user-\(UUID().uuidString)",
            name: resolved, recipe: recipe, builtin: false
        )
        userPresets.append(preset)
        persist()
        return preset
    }

    @discardableResult
    func delete(id: String) -> Bool {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return false }
        userPresets.remove(at: index)
        persist()
        return true
    }

    func preset(id: String) -> GradePreset? {
        all.first { $0.id == id }
    }

    // MARK: - LUT

    func luts() -> [GradeLUTEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: lutDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending }
            .map { GradeLUTEntry(name: $0.deletingPathExtension().lastPathComponent, path: $0.path) }
    }

    @discardableResult
    func importLUT(from source: URL) throws -> GradeLUTEntry {
        guard source.pathExtension.lowercased() == "cube",
              FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(domain: "grade", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "只支持 .cube 文件"
            ])
        }
        let target = lutDirectory.appendingPathComponent(source.lastPathComponent)
        var copied = false
        if source.standardizedFileURL != target.standardizedFileURL {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            copied = true
        }
        do {
            // 解析校验通过才入库，避免列表里留下“导入成功但点击无效果”的无效 LUT。
            try GradeEngine.preloadCube(path: target.path)
        } catch {
            if copied { try? FileManager.default.removeItem(at: target) }
            throw error
        }
        return GradeLUTEntry(name: target.deletingPathExtension().lastPathComponent, path: target.path)
    }

    func removeLUT(path: String) throws {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let root = lutDirectory.standardizedFileURL
        guard target.deletingLastPathComponent() == root else {
            throw NSError(domain: "grade", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "只能删除 LUT 库内的文件"
            ])
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: presetsURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            userPresets = []
            return
        }
        userPresets = envelope.presets.filter { !$0.builtin }
    }

    private func persist() {
        let envelope = Envelope(schema: 1, presets: userPresets)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: presetsURL, options: .atomic)
    }
}
