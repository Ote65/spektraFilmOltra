import Foundation
import SwiftUI

/// 调色会话：只接收显影会话产出的线性 ProPhoto 交接像素，
/// 不在调色台里读取 RAW，也不反向修改显影参数。
@MainActor
final class MobileGradeSession: ObservableObject {
    let photoID: String
    let filename: String
    private let store: LibraryStore
    private let develop: MobileDevelopSession

    @Published private(set) var previewImage: MPlatformImage?
    @Published private(set) var originalImage: MPlatformImage?
    @Published private(set) var isPreviewOriginal = false
    @Published private(set) var sourceReady = false
    @Published private(set) var isRendering = false
    @Published private(set) var phaseLabel = ""
    @Published private(set) var phaseProgress: Double = 0
    /// 导出独立文案，避免被「调色代理 / 调色精修」这类预览阶段覆盖。
    @Published private(set) var exportLabel = ""
    @Published private(set) var errorMessage: String?
    /// 交接图生成失败的用户可读原因；非 nil 且 sourceReady == false 时界面展示失败态与重试。
    @Published private(set) var sourceFailure: String?
    @Published private(set) var presets: [GradePreset] = []
    @Published private(set) var luts: [GradeLUTEntry] = []
    @Published private(set) var isExporting = false
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var previewAspect: CGFloat = 4.0 / 3.0
    /// 片边：只影响预览与导出，不写入调色配方。
    @Published private(set) var border = MFilmBorderConfig()
    /// 调色台预览比例（相对 1600 交接图）：1/8、1/4、1/2、1/1。
    @Published private(set) var previewScale: Double

    private let gradeQueue = DispatchQueue(label: "spektra.mobile.grade", qos: .userInitiated)
    private var source: ImageRGB?
    /// 最近一帧「无片边」的调色结果 / 原片显示图；改片边时只重合成这两张。
    private var basePreviewCG: CGImage?
    private var originalBaseCG: CGImage?
    private var borderPersistWork: DispatchWorkItem?
    private var displayRecipe = MGradeRecipe()
    private var lutPath = ""
    private var token = 0
    private var exportToken = 0
    private var activeFlag: MCancelFlag?
    private var pendingProxy: DispatchWorkItem?
    private var pendingSettle: DispatchWorkItem?
    private var proxyInFlight = false

    /// 交接图固定 1600 长边；预览比例只决定从交接图降采样的代理/精修尺寸。
    private let sourceEdge = 1600
    private var fullEdge: Int {
        max(160, Int(Double(sourceEdge) * previewScale))
    }
    /// 拖动期代理图：最多 1080，已覆盖 430pt@3x 屏幕的显示需求。
    private var proxyEdge: Int {
        max(160, min(1080, fullEdge))
    }
    private static let previewScaleKey = "mobile.grade.previewScale"

    init(photo: LibraryPhoto, store: LibraryStore, develop: MobileDevelopSession) {
        self.photoID = photo.id
        self.filename = photo.filename
        self.store = store
        self.develop = develop
        let saved = UserDefaults.standard.double(forKey: Self.previewScaleKey)
        self.previewScale = saved >= 0.125 && saved <= 1.0 ? saved : 1.0
        self.presets = GradePresetStore.shared.all
        self.luts = GradePresetStore.shared.luts()
        if let data = photo.borderData,
           let decoded = try? JSONDecoder().decode(MFilmBorderConfig.self, from: data) {
            self.border = decoded.normalized()
        }
    }

    // MARK: - 启动

    func start() {
        isRendering = true
        phaseLabel = "生成交接图"
        phaseProgress = 0
        sourceFailure = nil
        errorMessage = nil
        let filmID = develop.filmID
        let borderConfig = border
        develop.prepareHandoff(maxEdge: sourceEdge) { [weak self] image in
            guard let self else { return }
            guard let image else {
                Task { @MainActor in
                    self.isRendering = false
                    self.phaseLabel = ""
                    self.errorMessage = "交接图生成失败"
                    self.sourceFailure = "无法生成调色用的交接图，请重试。若仍失败，请返回显影台检查原片。"
                }
                return
            }
            let linear = GradeEngine.prepareSource(image)
            // 交接图是线性 ProPhoto；对比原图必须先转成线性 sRGB 再显示编码，
            // 否则会把 ProPhoto 当成 sRGB 直接编码，出现明显偏色。
            let display = PreviewLUTService.displayImage(fromLinear: linear)
            let baseOriginal = PreviewRenderer.cgImage(from: display)
            let framedOriginal = baseOriginal.map {
                MFilmBorderRenderer.preview(
                    photo: $0, config: borderConfig, filmID: filmID, photoID: self.photoID
                ) ?? $0
            }
            Task { @MainActor in
                self.source = linear
                self.sourceReady = true
                self.sourceFailure = nil
                self.errorMessage = nil
                self.isRendering = false
                self.phaseLabel = ""
                self.originalBaseCG = baseOriginal
                if let framedOriginal {
                    self.originalImage = MImage.make(cgImage: framedOriginal)
                    self.previewAspect = CGFloat(framedOriginal.width) / CGFloat(max(1, framedOriginal.height))
                } else {
                    self.previewAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
                }
                self.schedule(immediate: true)
            }
        }
    }

    /// 交接图失败后的手动重试。
    func retrySource() {
        guard !sourceReady, !isExporting else { return }
        start()
    }

    func cancel() {
        token += 1
        exportToken += 1
        pendingProxy?.cancel()
        pendingSettle?.cancel()
    }

    /// 导出面板显示用：原图真实长边。
    var exportOriginalEdge: Int {
        let photo = store.photos.first(where: { $0.id == photoID })
        return max(photo?.width ?? 0, photo?.height ?? 0)
    }

    /// 调色台预览比例：只改变从 1600 交接图降采样的尺寸，不影响导出与配方。
    func setPreviewScale(_ scale: Double) {
        let value = min(max(scale, 0.125), 1.0)
        guard abs(value - previewScale) > 1e-9 else { return }
        previewScale = value
        UserDefaults.standard.set(value, forKey: Self.previewScaleKey)
        guard sourceReady, !isExporting else { return }
        schedule(immediate: true)
    }

    // MARK: - 片边

    /// 只改片边时不必重跑调色：拿当前「无片边」帧重新合成即可。
    private func applyBorderToPreview() {
        guard let base = basePreviewCG else { return }
        let framed = MFilmBorderRenderer.preview(
            photo: base, config: border, filmID: develop.filmID, photoID: photoID
        ) ?? base
        previewImage = MImage.make(cgImage: framed)
        previewAspect = CGFloat(framed.width) / CGFloat(max(1, framed.height))
        if let original = originalBaseCG {
            let framedOriginal = MFilmBorderRenderer.preview(
                photo: original, config: border, filmID: develop.filmID, photoID: photoID
            ) ?? original
            originalImage = MImage.make(cgImage: framedOriginal)
        }
    }

    func setBorder(_ config: MFilmBorderConfig) {
        let value = config.normalized()
        guard value != border else { return }
        border = value
        persistBorderSoon()
        applyBorderToPreview()
    }

    func setBorderPreset(_ preset: MFilmBorderPreset) {
        var value = preset.config
        value.enabled = preset.id != "none"
        value.preset = preset.id
        setBorder(value)
    }

    func updateBorder(_ mutate: (inout MFilmBorderConfig) -> Void) {
        var value = border
        mutate(&value)
        value = value.normalized()
        if !value.enabled {
            value.preset = "none"
        } else {
            let matchesPreset = MFilmBorderPreset.preset(id: value.preset).map {
                $0.id != "none" && $0.config.matches(value)
            } ?? false
            value.preset = matchesPreset ? value.preset : "custom"
        }
        setBorder(value)
    }

    func resetBorder() {
        setBorder(MFilmBorderConfig())
    }

    private func persistBorderSoon() {
        borderPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistBorderNow() }
        borderPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistBorderNow() {
        guard var photo = store.photos.first(where: { $0.id == photoID }) else { return }
        photo.borderData = try? JSONEncoder().encode(border)
        try? store.update(photo)
    }

    // MARK: - 配方

    func apply(_ ui: MGradeRecipe) {
        displayRecipe = ui
        schedule()
    }

    func setLUT(entry: GradeLUTEntry?) {
        if let entry {
            lutPath = entry.path
            displayRecipe.lutName = entry.name
            if displayRecipe.lutStrength <= 0 { displayRecipe.lutStrength = 60 }
        } else {
            lutPath = ""
            displayRecipe.lutName = "无 LUT"
            displayRecipe.lutStrength = 0
        }
        schedule()
    }

    func applyPreset(_ preset: GradePreset) {
        let name = preset.recipe.lut.path.isEmpty
            ? "无 LUT"
            : (luts.first(where: { $0.path == preset.recipe.lut.path })?.name
                ?? URL(fileURLWithPath: preset.recipe.lut.path).lastPathComponent)
        lutPath = preset.recipe.lut.path
        displayRecipe = MGradeRecipe(grade: preset.recipe, lutName: name)
        schedule()
    }

    @discardableResult
    func importLUT(url: URL) -> GradeLUTEntry? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let entry = try? GradePresetStore.shared.importLUT(from: url) else { return nil }
        luts = GradePresetStore.shared.luts()
        setLUT(entry: entry)
        return entry
    }

    @discardableResult
    func savePreset(name: String) -> GradePreset {
        let preset = GradePresetStore.shared.save(
            name: name, recipe: displayRecipe.gradeRecipe(lutPath: lutPath))
        presets = GradePresetStore.shared.all
        return preset
    }

    // MARK: - 渲染

    private func schedule(immediate: Bool = false) {
        guard sourceReady, !isExporting else { return }
        pendingProxy?.cancel()
        pendingSettle?.cancel()
        if immediate {
            render(edge: fullEdge)
            return
        }
        if proxyInFlight { token += 1; proxyInFlight = false }
        let proxy = DispatchWorkItem { [weak self] in
            self?.pendingProxy = nil
            self?.render(edge: self?.proxyEdge ?? 800)
        }
        pendingProxy = proxy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: proxy)
        let settle = DispatchWorkItem { [weak self] in
            self?.pendingSettle = nil
            self?.pendingProxy?.cancel()
            self?.pendingProxy = nil
            self?.render(edge: self?.fullEdge ?? 1600)
        }
        pendingSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: settle)
    }

    private func render(edge: Int) {
        guard let source else { return }
        token += 1
        activeFlag?.cancel()
        let flag = MCancelFlag()
        activeFlag = flag
        let recipe = displayRecipe.gradeRecipe(lutPath: lutPath)
        let borderConfig = border
        let filmID = develop.filmID
        let photoID = self.photoID
        proxyInFlight = edge <= proxyEdge
        isRendering = true
        phaseLabel = edge <= proxyEdge ? "调色代理" : "调色精修"
        phaseProgress = 0
        gradeQueue.async { [weak self] in
            let input = GradeEngine.downsampleLinear(source, maxLongEdge: edge)
            do {
                let result = try GradeEngine.render(
                    input, recipe: recipe,
                    shouldCancel: { flag.isCancelled })
                let cgImage = PreviewRenderer.cgImage(from: result.image)
                let framed = cgImage.map {
                    MFilmBorderRenderer.preview(
                        photo: $0, config: borderConfig, filmID: filmID, photoID: photoID
                    ) ?? $0
                }
                Task { @MainActor [weak self] in
                    guard let self, self.activeFlag === flag, let framed else { return }
                    self.basePreviewCG = cgImage
                    if self.border == borderConfig {
                        self.previewImage = MImage.make(cgImage: framed)
                        self.previewAspect = CGFloat(framed.width) / CGFloat(max(1, framed.height))
                    } else if let cgImage {
                        // 渲染期间又改了片边：以最新片边重新合成，避免回退成旧边框。
                        self.basePreviewCG = cgImage
                        self.applyBorderToPreview()
                    }
                    self.isRendering = false
                    self.proxyInFlight = false
                    self.phaseLabel = ""
                    self.phaseProgress = 0
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.activeFlag === flag else { return }
                    self.isRendering = false
                    self.proxyInFlight = false
                    self.phaseLabel = ""
                }
            }
        }
    }

    // MARK: - 导出

    /// `jpegQuality` 仅在 JPEG 档生效，取值 0…1。
    func export(format: Int, longEdgeIndex: Int, jpegQuality: Double = 0.95,
                completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isExporting, sourceReady else {
            completion(.failure(MobileExportError.busy))
            return
        }
        let originalEdge = max(store.photos.first(where: { $0.id == photoID })?.width ?? 0,
                               store.photos.first(where: { $0.id == photoID })?.height ?? 0)
        let borderConfig = border
        let filmID = develop.filmID
        let rawEdge = ExportEdge.requested(index: longEdgeIndex, originalLongEdge: originalEdge)
        // 片边会把成品放大一圈：开启片边时「原始」也按内存余量钳位，避免大图导出被 jetsam。
        let edge = (longEdgeIndex == 0 && !borderConfig.enabled)
            ? rawEdge
            : ExportEdge.clampToMemoryBudget(rawEdge)
        let recipe = displayRecipe.gradeRecipe(lutPath: lutPath)
        let targetSpace: String
        let targetCCTF: Bool
        let ext: String
        let bitDepth: Int
        switch format {
        case 1:
            targetSpace = "ProPhoto RGB"; targetCCTF = false; ext = "tif"; bitDepth = 16
        case 2:
            targetSpace = "ACES2065-1"; targetCCTF = false; ext = "exr"; bitDepth = 16
        case 3:
            targetSpace = "sRGB"; targetCCTF = true; ext = "jpg"; bitDepth = 8
        default:
            targetSpace = "sRGB"; targetCCTF = true; ext = "tif"; bitDepth = 16
        }
        let destination = Self.exportURL(filename: filename, ext: ext)
        isExporting = true
        exportToken += 1
        let current = exportToken
        phaseLabel = "导出调色"
        exportLabel = "导出调色"
        phaseProgress = 0
        develop.prepareHandoff(maxEdge: edge) { [weak self] image in
            guard let self else { return }
            guard let image else {
                Task { @MainActor in
                    self.isExporting = false
                    self.exportLabel = ""
                    completion(.failure(MobileExportError.busy))
                }
                return
            }
            let exportPhotoID = self.photoID
            self.gradeQueue.async {
                do {
                    let linear = GradeEngine.prepareSource(image)
                    let result = try GradeEngine.render(linear, recipe: recipe)
                    var output = Self.convertForExport(
                        result.image, colorSpace: targetSpace, cctfEncoding: targetCCTF)
                    if borderConfig.enabled {
                        Task { @MainActor in self.exportLabel = "合成片边" }
                        output = MFilmBorderRenderer.composite(
                            image: output, config: borderConfig,
                            filmID: filmID, photoID: exportPhotoID,
                            colorSpace: targetSpace, cctfEncoding: targetCCTF
                        )
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ImageExport.save(output, to: destination, bitDepth: bitDepth,
                                         colorSpace: targetSpace, cctfEncoding: targetCCTF,
                                         jpegQuality: jpegQuality)
                    Task { @MainActor in
                        guard self.exportToken == current else { return }
                        self.isExporting = false
                        self.exportLabel = ""
                        self.phaseProgress = 0
                        self.lastSavedURL = destination
                        completion(.success(destination))
                    }
                } catch {
                    Task { @MainActor in
                        guard self.exportToken == current else { return }
                        self.isExporting = false
                        self.exportLabel = ""
                        self.phaseProgress = 0
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - 工具

    private nonisolated static func convertForExport(
        _ image: ImageRGB, colorSpace: String, cctfEncoding: Bool
    ) -> ImageRGB {
        if colorSpace == "sRGB" && cctfEncoding { return image }
        let sourceKind = ColorMath.cctfKind(for: "sRGB")
        let targetKind = ColorMath.cctfKind(for: colorSpace)
        return image.map { pixel in
            let decoded = Vec3(
                ColorMath.cctfDecode(pixel.x, kind: sourceKind),
                ColorMath.cctfDecode(pixel.y, kind: sourceKind),
                ColorMath.cctfDecode(pixel.z, kind: sourceKind)
            )
            let converted = ColorMath.rgbToRGB(decoded, from: "sRGB", to: colorSpace)
            if cctfEncoding {
                return Vec3(
                    ColorMath.cctfEncode(converted.x, kind: targetKind),
                    ColorMath.cctfEncode(converted.y, kind: targetKind),
                    ColorMath.cctfEncode(converted.z, kind: targetKind)
                )
            }
            return converted
        }
    }

    private static func exportURL(filename: String, ext: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spektrafilm/Exports", isDirectory: true)
        let stem = (filename as NSString).deletingPathExtension
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return base.appendingPathComponent("\(stem)-\(formatter.string(from: Date())).\(ext)")
    }
}

/// 跨线程取消标记：渲染在后台队列执行，主线程只负责置位。
final class MCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
