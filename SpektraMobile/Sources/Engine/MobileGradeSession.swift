import Foundation
import SwiftUI

/// 调色台的源像素来源。
enum MGradeSource {
    /// 显影台交接过来的显影结果（正常链路）。
    case developed
    /// 直接调色：原片解码后直接进入调色台，不跑胶片显影。
    case original
}

/// 调色会话：只接收显影会话产出的线性 ProPhoto 交接像素，
/// 不在调色台里读取 RAW，也不反向修改显影参数。
@MainActor
final class MobileGradeSession: ObservableObject {
    let photoID: String
    let filename: String
    private let store: LibraryStore
    private let develop: MobileDevelopSession
    private let sourceMode: MGradeSource

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
    /// 配方引用的 LUT 解析失败时的提示；同一原因只提示一次，切换 LUT 后自动清空。
    @Published private(set) var lutFailure: String?
    @Published private(set) var previewAspect: CGFloat = 4.0 / 3.0
    /// 片边：只影响预览与导出，不写入调色配方。
    @Published private(set) var border = MFilmBorderConfig()
    /// 裁切与校正几何：只作用于照片本身，片边在裁切完成后才合成。
    @Published private(set) var geometry = MPhotoGeometry()
    /// 裁切页取景底图：完整交接图的调色结果，不含任何几何变换。
    @Published private(set) var cropBaseImage: CGImage?
    /// 裁切底图生成失败的原因；非 nil 时裁切页展示错误与重试入口，而不是无限转圈。
    @Published private(set) var cropBaseFailure: String?
    /// 调色台预览比例（相对 1600 交接图）：1/8、1/4、1/2、1/1。
    @Published private(set) var previewScale: Double

    /// 片边日期戳的默认字样：拍摄日期与时间（EXIF 缺失时为空，不画日期戳）。
    private let captureDateLabel: String
    private let captureTimeLabel: String

    private let gradeQueue = DispatchQueue(label: "spektra.mobile.grade", qos: .userInitiated)
    private var source: ImageRGB?
    /// 未经裁切/校正的完整交接图；几何变化时从它重新生成 source。
    private var pristineSource: ImageRGB?
    /// 最近一帧「无片边」的调色结果 / 原片显示图；改片边时只重合成这两张。
    private var basePreviewCG: CGImage?
    private var originalBaseCG: CGImage?
    /// 未经几何变换的原片显示图。
    private var pristineOriginalCG: CGImage?
    private var borderPersistWork: DispatchWorkItem?
    private var geometryPersistWork: DispatchWorkItem?
    /// 裁切取景底图的目标长边：取景只需要屏幕分辨率，压缩快照能显著降低拖动期采样成本。
    private let cropBaseEdge = 1200
    /// 生成快照时的配方与 LUT，用于下次进裁切页时判断能否直接复用。
    private var cropBaseRecipe: MGradeRecipe?
    private var cropBaseLUTPath: String?
    /// 裁切几何重采样专用队列：整幅 apply 不堵调色预览所在的 gradeQueue。
    private let geometryQueue = DispatchQueue(label: "spektra.mobile.grade.geometry", qos: .userInitiated)
    /// 在算的几何帧取消标记：新几何请求一到就取消旧帧计算。
    private var geometryFlag: MCancelFlag?
    /// 片边重合成单独一条队列：滑条拖动时只保留最新一帧，主线程只做赋值。
    private let borderQueue = DispatchQueue(label: "spektra.mobile.grade.border", qos: .userInitiated)
    /// 新的片边请求一来就取消上一帧合成，避免拖动滑条时任务排队造成延迟。
    private var borderFlag: MCancelFlag?
    private var displayRecipe = MGradeRecipe()
    private var lutPath = ""
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

    init(photo: LibraryPhoto, store: LibraryStore, develop: MobileDevelopSession,
         source: MGradeSource = .developed) {
        self.photoID = photo.id
        self.filename = photo.filename
        self.store = store
        self.develop = develop
        self.sourceMode = source
        let stamp = MFilmBorderRenderer.captureStamp(url: store.originalURL(for: photo))
        self.captureDateLabel = stamp.date
        self.captureTimeLabel = stamp.time
        let saved = UserDefaults.standard.double(forKey: Self.previewScaleKey)
        self.previewScale = saved >= 0.125 && saved <= 1.0 ? saved : 1.0
        self.presets = GradePresetStore.shared.all
        self.luts = GradePresetStore.shared.luts()
        if let remembered = MFilmBorderMemory.load() {
            self.border = remembered
        } else if let data = photo.borderData,
                  let decoded = try? JSONDecoder().decode(MFilmBorderConfig.self, from: data) {
            // 旧版本按照片保存：迁移成记忆参数，但片边开关与做旧归零。
            self.border = MFilmBorderMemory.remembered(decoded)
        }
        if let data = photo.cropData,
           let decoded = try? JSONDecoder().decode(MPhotoGeometry.self, from: data) {
            self.geometry = decoded.normalized()
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
        let geometry = geometry
        handoff(maxEdge: sourceEdge) { [weak self] image in
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
            let pristineOriginal = PreviewRenderer.cgImage(from: display)
            let warped = geometry.apply(to: linear)
            let warpedOriginal = pristineOriginal.flatMap { geometry.apply(to: $0) }
            let framedOriginal = warpedOriginal.map {
                MFilmBorderRenderer.preview(
                    photo: $0, config: borderConfig, filmID: filmID, photoID: self.photoID,
                    dateLabel: self.captureDateLabel,
                    timeLabel: self.captureTimeLabel
                ) ?? $0
            }
            Task { @MainActor in
                self.pristineSource = linear
                self.source = warped
                // 交接图重做后旧的裁切快照失效。
                self.cropBaseImage = nil
                self.cropBaseRecipe = nil
                self.cropBaseLUTPath = nil
                self.cropBaseFailure = nil
                self.sourceReady = true
                self.sourceFailure = nil
                self.errorMessage = nil
                self.isRendering = false
                self.phaseLabel = ""
                self.pristineOriginalCG = pristineOriginal
                self.originalBaseCG = warpedOriginal ?? pristineOriginal
                if let framedOriginal {
                    self.originalImage = MImage.make(cgImage: framedOriginal)
                    self.previewAspect = CGFloat(framedOriginal.width) / CGFloat(max(1, framedOriginal.height))
                } else {
                    self.previewAspect = CGFloat(warped.width) / CGFloat(max(1, warped.height))
                }
                self.schedule(immediate: true)
            }
        }
    }

    /// 交接像素：正常链路走显影结果，直接调色入口走原片。
    private func handoff(maxEdge: Int, completion: @escaping (ImageRGB?) -> Void) {
        switch sourceMode {
        case .developed:
            develop.prepareHandoff(maxEdge: maxEdge, completion: completion)
        case .original:
            develop.prepareOriginalHandoff(maxEdge: maxEdge, completion: completion)
        }
    }

    /// 交接图失败后的手动重试。
    func retrySource() {
        guard !sourceReady, !isExporting else { return }
        start()
    }

    // MARK: - 裁切与校正

    /// 裁切页取景底图：完整交接图按当前配方调色，但不带任何几何变换。
    /// 所有失败路径都会回写 `cropBaseFailure`，保证裁切页有错误文案与重试入口。
    /// 生成时先压到 `cropBaseEdge`：取景只需要屏幕分辨率，压缩快照换来拖动期的分钟级成本下降。
    func prepareCropBase() {
        cropBaseFailure = nil
        guard let pristine = pristineSource else {
            cropBaseFailure = "交接图还在准备中，稍后再试裁切。"
            return
        }
        guard !isExporting else {
            cropBaseFailure = "正在导出，完成后再试。"
            return
        }
        // 同一配方下直接复用上一次的快照，第二次进裁切页不再等调色。
        if cropBaseImage != nil, cropBaseRecipe == displayRecipe, cropBaseLUTPath == lutPath {
            return
        }
        cropBaseImage = nil
        let recipe = displayRecipe.gradeRecipe(lutPath: lutPath)
        let uiRecipe = displayRecipe
        let recipeKey = lutPath
        let edge = cropBaseEdge
        gradeQueue.async { [weak self] in
            var image: CGImage?
            var failure: String?
            do {
                let input = GradeEngine.downsampleLinear(pristine, maxLongEdge: edge)
                let result = try GradeEngine.render(input, recipe: recipe)
                image = PreviewRenderer.cgImage(from: result.image)
                if image == nil { failure = "裁切底图生成失败，请重试。" }
            } catch {
                failure = (error as? LUTParseError)?.errorDescription
                    ?? "裁切底图生成失败，请重试。"
            }
            Task { @MainActor [weak self] in
                guard let self, !self.isExporting else { return }
                self.cropBaseImage = image
                self.cropBaseFailure = failure
                if failure == nil {
                    self.cropBaseRecipe = uiRecipe
                    self.cropBaseLUTPath = recipeKey
                }
            }
        }
    }

    /// 关闭裁切页：只清错误态，保留已生成的压缩快照供下次直接复用。
    func clearCropBase() {
        cropBaseFailure = nil
    }

    /// 确认裁切：几何只作用在交接图本身，片边随后才合成，不会裁到片边。
    /// 整幅重采样放在专用队列（不堵 gradeQueue 的调色预览），
    /// 且带行级取消标记：新几何请求一到就取消旧帧计算，只保留最新一帧。
    func setGeometry(_ value: MPhotoGeometry) {
        let target = value.normalized()
        guard target != geometry else { return }
        geometry = target
        persistGeometrySoon()
        guard sourceReady, !isExporting, let pristine = pristineSource else { return }

        geometryFlag?.cancel()
        let flag = MCancelFlag()
        geometryFlag = flag

        pendingProxy?.cancel()
        pendingSettle?.cancel()
        proxyInFlight = false
        isRendering = true
        phaseLabel = "应用裁切"
        phaseProgress = 0

        let original = pristineOriginalCG
        let borderConfig = border
        let filmID = develop.filmID
        let photoID = self.photoID
        let dateLabel = captureDateLabel
        let timeLabel = captureTimeLabel

        geometryQueue.async { [weak self] in
            let warped = target.apply(to: pristine) { flag.isCancelled }
            guard !flag.isCancelled else { return }
            let warpedOriginal = original.flatMap {
                flag.isCancelled ? nil : target.apply(to: $0) { flag.isCancelled }
            }
            guard !flag.isCancelled else { return }
            let framed = warpedOriginal.map {
                MFilmBorderRenderer.preview(
                    photo: $0, config: borderConfig, filmID: filmID, photoID: photoID,
                    dateLabel: dateLabel, timeLabel: timeLabel
                ) ?? $0
            }
            Task { @MainActor [weak self] in
                guard let self, self.geometry == target, !flag.isCancelled else { return }
                self.source = warped
                self.originalBaseCG = warpedOriginal ?? original
                if let framed {
                    self.originalImage = MImage.make(cgImage: framed)
                    self.previewAspect = CGFloat(framed.width) / CGFloat(max(1, framed.height))
                } else {
                    self.previewAspect = CGFloat(warped.width) / CGFloat(max(1, warped.height))
                }
                self.isRendering = false
                self.phaseLabel = ""
                self.schedule(immediate: true)
            }
        }
    }

    func resetGeometry() {
        setGeometry(MPhotoGeometry())
    }

    private func persistGeometrySoon() {
        geometryPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistGeometryNow() }
        geometryPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistGeometryNow() {
        guard var photo = store.photos.first(where: { $0.id == photoID }) else { return }
        photo.cropData = try? JSONEncoder().encode(geometry)
        try? store.update(photo)
    }

    func cancel() {
        exportToken += 1
        borderFlag?.cancel()
        geometryFlag?.cancel()
        pendingProxy?.cancel()
        pendingSettle?.cancel()
    }

    /// LUT 卡片沿用当前胶片的图标，保持调色台与显影台同一套视觉。
    var filmID: String { develop.filmID }

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
    /// 合成在后台队列做，拖动片边参数滑条时主线程只负责最后赋值。
    private func applyBorderToPreview() {
        let base = basePreviewCG
        let original = originalBaseCG
        guard base != nil || original != nil else { return }
        borderFlag?.cancel()
        let flag = MCancelFlag()
        borderFlag = flag
        let config = border
        let filmID = develop.filmID
        let identifier = photoID
        let dateLabel = captureDateLabel
        let timeLabel = captureTimeLabel
        borderQueue.async { [weak self] in
            // 排到队首时已有更新的请求就直接放弃，旧帧不再合成。
            guard !flag.isCancelled else { return }
            let framed = base.map {
                MFilmBorderRenderer.preview(
                    photo: $0, config: config, filmID: filmID, photoID: identifier,
                    dateLabel: dateLabel, timeLabel: timeLabel
                ) ?? $0
            }
            guard !flag.isCancelled else { return }
            let framedOriginal = original.map {
                MFilmBorderRenderer.preview(
                    photo: $0, config: config, filmID: filmID, photoID: identifier,
                    dateLabel: dateLabel, timeLabel: timeLabel
                ) ?? $0
            }
            guard !flag.isCancelled else { return }
            Task { @MainActor [weak self] in
                guard let self, self.borderFlag === flag else { return }
                if let framed {
                    self.previewImage = MImage.make(cgImage: framed)
                    self.previewAspect = CGFloat(framed.width) / CGFloat(max(1, framed.height))
                }
                if let framedOriginal {
                    self.originalImage = MImage.make(cgImage: framedOriginal)
                }
            }
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
        // 参数记忆跨照片生效；片边开关与做旧不写入记忆。
        MFilmBorderMemory.save(border)
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

    /// 按 LUT 名称回写会话内的 LUT 路径（撤销 / 重置配方时与 UI 的 lutName 保持同步）。
    func syncLUTPath(name: String) {
        lutPath = name == "无 LUT" ? "" : (luts.first { $0.name == name }?.path ?? "")
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
    func importLUT(url: URL) throws -> GradeLUTEntry {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let entry = try GradePresetStore.shared.importLUT(from: url)
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
        if proxyInFlight { proxyInFlight = false }
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
        activeFlag?.cancel()
        let flag = MCancelFlag()
        activeFlag = flag
        let recipe = displayRecipe.gradeRecipe(lutPath: lutPath)
        let borderConfig = border
        let filmID = develop.filmID
        let photoID = self.photoID
        let dateLabel = captureDateLabel
        let timeLabel = captureTimeLabel
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
                let lutMessage = result.lutError?.errorDescription
                let cgImage = PreviewRenderer.cgImage(from: result.image)
                let framed = cgImage.map {
                    MFilmBorderRenderer.preview(
                        photo: $0, config: borderConfig, filmID: filmID, photoID: photoID,
                        dateLabel: dateLabel, timeLabel: timeLabel
                    ) ?? $0
                }
                Task { @MainActor [weak self] in
                    guard let self, self.activeFlag === flag, let framed else { return }
                    self.basePreviewCG = cgImage
                    self.lutFailure = lutMessage
                    if self.border == borderConfig {
                        self.previewImage = MImage.make(cgImage: framed)
                        self.previewAspect = CGFloat(framed.width) / CGFloat(max(1, framed.height))
                    } else if cgImage != nil {
                        // 渲染期间又改了片边：以最新片边重新合成，避免回退成旧边框。
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

    /// `jpegQuality` 仅在 JPEG 档生效，取值 0…1；`includeWatermark` 是导出面板的单次水印开关。
    func export(format: Int, longEdgeIndex: Int, jpegQuality: Double = 0.95,
                includeWatermark: Bool = true,
                completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isExporting, sourceReady else {
            completion(.failure(MobileExportError.busy))
            return
        }
        let originalEdge = max(store.photos.first(where: { $0.id == photoID })?.width ?? 0,
                               store.photos.first(where: { $0.id == photoID })?.height ?? 0)
        let borderConfig = border
        let filmID = develop.filmID
        let dateLabel = captureDateLabel
        let timeLabel = captureTimeLabel
        let watermarkEnabled = includeWatermark
        let watermark = MWatermarkStore.load()
        let rawEdge = ExportEdge.requested(index: longEdgeIndex, originalLongEdge: originalEdge)
        // 片边会把成品放大一圈：开启片边时「原始」也按内存余量钳位，避免大图导出被 jetsam。
        let edge = (longEdgeIndex == 0 && !borderConfig.enabled)
            ? rawEdge
            : ExportEdge.clampToMemoryBudget(rawEdge)
        let recipe = displayRecipe.gradeRecipe(lutPath: lutPath)
        let geometry = geometry
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
        handoff(maxEdge: edge) { [weak self] image in
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
                    let warped = geometry.apply(to: linear)
                    let result = try GradeEngine.render(warped, recipe: recipe)
                    if let lutError = result.lutError { throw lutError }
                    var output = Self.convertForExport(
                        result.image, colorSpace: targetSpace, cctfEncoding: targetCCTF)
                    // 水印属于照片本身：先压进画面，再合成片边，避免盖到片基与边字上。
                    if watermarkEnabled {
                        Task { @MainActor in self.exportLabel = "合成水印" }
                        var config = watermark
                        // 导出面板的勾选是这次导出的最终决定，覆盖设置里的启用位。
                        config.enabled = true
                        output = MWatermarkRenderer.composite(
                            image: output, config: config,
                            colorSpace: targetSpace, cctfEncoding: targetCCTF
                        )
                    }
                    if borderConfig.enabled {
                        Task { @MainActor in self.exportLabel = "合成片边" }
                        output = MFilmBorderRenderer.composite(
                            image: output, config: borderConfig,
                            filmID: filmID, photoID: exportPhotoID,
                            colorSpace: targetSpace, cctfEncoding: targetCCTF,
                            dateLabel: dateLabel, timeLabel: timeLabel
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
