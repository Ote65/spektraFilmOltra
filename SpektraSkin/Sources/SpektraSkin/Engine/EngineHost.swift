import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 把 SpektraCore 引擎接到 SpektraSkin 的只读快照 / 动作协议上。
@MainActor
final class EngineHost: ObservableObject {
    static let shared = EngineHost()

    @Published private(set) var revision = 0
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewIsPredicted = false
    @Published private(set) var previewRevision = 0
    @Published private(set) var preflightNotice: String?
    @Published private(set) var preflightReport: PreviewPreflightReport?
    @Published private(set) var isRendering = false
    @Published private(set) var renderPhase = RenderPhase.idle
    @Published private(set) var statusMessage = "照片库已就绪"

    let store: LibraryStore
    let renderer = PreviewRenderer()
    let exportQueue = ExportQueue()

    private(set) var selectedID: String?
    private var baseline = PhotoEdit()
    private var quickIntents: [String: Double] = [:]
    private var padIntent = CGPoint(x: 0, y: 0)
    private var loadedImage: ImageRGB?
    private var loadedColorSpace = "ProPhoto RGB"
    private var loadedCCTF = false
    private var thumbnailCache: [String: String] = [:]
    private var previewCache: [String: NSImage] = [:]
    private var previewHistogram: HistogramData?
    private var originalImage: NSImage?
    private(set) var previewScale: Double = 0.25
    private let thumbnailQueue = DispatchQueue(label: "spektra.thumbnail", qos: .utility)
    /// 换片解码队列：RAW 解码与显示图构建不在主线程做，token 丢弃过期加载。
    private let imageLoadQueue = DispatchQueue(label: "spektra.image.load", qos: .userInitiated)
    private var imageLoadToken = 0

    /// 渲染调度：参数停止变化 1s 后再提交，期间的新参数立即中断在途渲染。
    private var pendingRenderWork: DispatchWorkItem?
    private var previewRenderInFlight = false
    private var renderToken = 0
    private let previewDebounce: TimeInterval = 1.0

    /// LUT 预测档：拖动后 150 ms 出预测帧，停手 1 s 后真算替换。
    private let previewLUT = PreviewLUTService()
    private let previewLUTQueue = DispatchQueue(label: "spektra.preview.lut", qos: .userInitiated)
    private let preflightQueue = DispatchQueue(label: "spektra.preview.preflight", qos: .utility)
    private var pendingFastWork: DispatchWorkItem?
    private var fastToken = 0
    /// 真算已完成的参数代际；同代际迟到的预测帧必须丢弃。
    private var accurateCompletedFastToken = 0
    private var preflightToken = 0
    private let fastDebounce: TimeInterval = 0.15

    // MARK: - 调色台

    @Published private(set) var gradePreviewImage: NSImage?
    @Published private(set) var gradePhase = RenderPhase.idle
    @Published private(set) var gradeAnalysis: ToneAnalysis?
    @Published private(set) var gradeSourceReady = false
    @Published private(set) var gradeSourceSize = ""
    @Published private(set) var gradeRecipe = GradeRecipe()
    @Published private(set) var gradePresets: [GradePreset] = GradePresetStore.shared.all
    @Published private(set) var gradeLUTs: [GradeLUTEntry] = GradePresetStore.shared.luts()
    @Published private(set) var gradeHistogram: HistogramData?
    @Published private(set) var gradeClarityReport: ClarityReport?
    @Published private(set) var gradePreviewScale: Double = 1.0

    private var gradeSource: ImageRGB?
    private var gradeOrigin: GradeOrigin = .developed
    private var gradeClarityAnalysis: ClarityAnalysis?
    private var gradeClarityToken = 0
    private var gradeClarityInFlight = false
    private var gradeProxyCache: [Int: ImageRGB] = [:]
    private let gradeRenderer = PreviewRenderer()
    private let gradeQueue = DispatchQueue(label: "spektra.grade", qos: .userInitiated)
    private let gradeLock = NSLock()
    private var gradePreviewToken = 0
    private var gradeExportToken = 0
    private var gradeSourceToken = 0
    private var gradePreviewInFlight = false
    private var gradeExportInFlight = false
    private var gradePendingProxy: DispatchWorkItem?
    private var gradePendingSettle: DispatchWorkItem?
    private var gradeIsActive = false
    /// 交接图固定按 1600 长边生成；预览精度只决定从交接图降采样的代理尺寸。
    private let gradeSourceEdge = 1600
    private var gradeFullEdge: Int {
        max(200, Int(Double(gradeSourceEdge) * gradePreviewScale))
    }
    private var gradeProxyEdge: Int {
        max(160, min(gradeSourceEdge / 2, gradeFullEdge / 2))
    }

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
        refreshThumbnailCache()
        exportQueue.onUpdate = { [weak self] state in
            guard state.isFinished, let self else { return }
            Task { @MainActor in
                self.statusMessage = state.error == nil ? "导出完成" : "导出失败：\(state.error ?? "")"
                self.revision += 1
            }
        }
    }

    func bump() { revision += 1 }

    var photos: [LibraryPhoto] { store.photos }

    func photo(with id: String) -> LibraryPhoto? {
        store.photos.first { $0.id == id }
    }

    func currentPhoto() -> LibraryPhoto? {
        if let selectedID, let photo = photo(with: selectedID) { return photo }
        return store.photos.first
    }

    func selectedEdit() -> PhotoEdit {
        currentPhoto()?.edit ?? baseline
    }

    private func refreshThumbnailCache() {
        thumbnailCache = [:]
        for photo in store.photos {
            if let path = photo.thumbnailPath { thumbnailCache[photo.id] = path }
        }
    }

    func select(photoID: String) {
        guard let photo = photo(with: photoID) else { return }
        if let previous = selectedID, let image = previewImage {
            previewCache[previous] = image
        }
        selectedID = photoID
        previewHistogram = nil
        if let data = photo.quickBaselineData,
           let decoded = try? JSONDecoder().decode(PhotoEdit.self, from: data) {
            baseline = decoded
        } else {
            baseline = photo.edit
        }
        quickIntents = photo.edit.quickIntents
        padIntent = CGPoint(
            x: photo.edit.enlarger.yFilterShift,
            y: photo.edit.enlarger.mFilterShift
        )
        statusMessage = photo.filename
        loadImage(for: photo)
    }

    private func loadImage(for photo: LibraryPhoto) {
        let url = store.originalURL(for: photo)
        imageLoadToken += 1
        let token = imageLoadToken
        imageLoadQueue.async { [weak self] in
            guard let self else { return }
            let loaded = try? ImageLoader.load(url: url)
            let display = loaded.flatMap {
                Self.displayImage(
                    $0.image, colorSpace: $0.colorSpace,
                    cctfDecoding: $0.cctfDecoding
                )
            }
            DispatchQueue.main.async {
                guard token == self.imageLoadToken else { return }
                guard let loaded else {
                    self.statusMessage = "无法读取 \(photo.filename)"
                    return
                }
                self.loadedImage = loaded.image
                self.loadedColorSpace = loaded.colorSpace
                self.loadedCCTF = loaded.cctfDecoding
                self.originalImage = display
                self.renderPreview()
                self.prewarmPreviewLUT()
                self.generateThumbnail(for: photo, image: loaded.image)
            }
        }
    }

    /// 换片后在后台预烘 LUT，首次拖滑杆不必等冷启动烘焙。
    private func prewarmPreviewLUT() {
        guard let photo = currentPhoto(), var params = try? photo.makeParams() else { return }
        params.io.inputColorSpace = loadedColorSpace
        params.io.inputCCTFDecoding = loadedCCTF
        guard !params.io.scanFilm else { return }
        let key = PreviewLUTService.cacheKey(
            edit: photo.edit, inputColorSpace: loadedColorSpace, inputCCTF: loadedCCTF
        )
        let service = previewLUT
        previewLUTQueue.asyncAfter(deadline: .now() + 0.3) {
            _ = service.bundle(for: params, key: key)
        }
    }

    private func generateThumbnail(for photo: LibraryPhoto, image: ImageRGB) {
        guard photo.thumbnailPath == nil, var params = try? photo.makeParams() else { return }
        params.io.inputColorSpace = loadedColorSpace
        params.io.inputCCTFDecoding = loadedCCTF
        let small = Resize.smallPreview(image, maxSize: 320)
        thumbnailQueue.async { [weak self] in
            let output = SimulationPipeline(params: params, keepTaps: false).process(small).rgbOut
            guard let self else { return }
            try? self.store.writeThumbnail(id: photo.id, image: output)
            DispatchQueue.main.async {
                self.refreshThumbnailCache()
                self.revision += 1
            }
        }
    }

    /// 为库中所有缺少缩略图的照片补渲染（首屏网格 / 胶片条直接显示真实画面）。
    func warmThumbnails() {
        let pending = store.photos.filter { $0.thumbnailPath == nil }
        for photo in pending {
            thumbnailQueue.async { [weak self] in
                guard let self,
                      let current = self.store.photos.first(where: { $0.id == photo.id }),
                      current.thumbnailPath == nil,
                      let loaded = try? ImageLoader.load(url: self.store.originalURL(for: current)),
                      var params = try? current.makeParams() else { return }
                params.io.inputColorSpace = loaded.colorSpace
                params.io.inputCCTFDecoding = loaded.cctfDecoding
                let small = Resize.smallPreview(loaded.image, maxSize: 320)
                let output = SimulationPipeline(params: params, keepTaps: false).process(small).rgbOut
                try? self.store.writeThumbnail(id: current.id, image: output)
                DispatchQueue.main.async {
                    self.refreshThumbnailCache()
                    self.revision += 1
                }
            }
        }
    }

    func applyQuick(_ id: String, _ q: Double) {
        guard var photo = currentPhoto() else { return }
        quickIntents[id] = q
        photo.edit.quickIntents = quickIntents
        applyQuickMapping(id: id, q: q, edit: &photo.edit)
        persist(photo)
        schedulePreviewRender()
    }

    func applyPad(_ x: Double, _ y: Double) {
        guard var photo = currentPhoto() else { return }
        padIntent = CGPoint(x: x, y: y)
        photo.edit.enlarger.yFilterShift = min(max(baseline.enlarger.yFilterShift + 40 * x / 100, -60), 60)
        photo.edit.enlarger.mFilterShift = min(max(baseline.enlarger.mFilterShift + 40 * y / 100, -60), 60)
        persist(photo)
        schedulePreviewRender()
    }

    private func persist(_ photo: LibraryPhoto) {
        var photo = photo
        if photo.edit.quickIntents.isEmpty {
            photo.quickBaselineData = nil
        } else if photo.quickBaselineData == nil {
            photo.quickBaselineData = try? JSONEncoder().encode(baseline)
        }
        try? store.update(photo)
        bump()
    }

    /// 参数变化后的调度：150 ms 出 LUT 预测帧；停手 1 s 再真算替换。
    /// 期间的新参数立即中断在途渲染/预测。
    func schedulePreviewRender() {
        guard loadedImage != nil else { return }
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        pendingFastWork?.cancel()
        pendingFastWork = nil
        fastToken += 1
        let fastTokenValue = fastToken
        preflightNotice = nil
        preflightReport = nil

        if previewRenderInFlight {
            renderToken += 1
            renderer.invalidate()
            previewRenderInFlight = false
            isRendering = false
            renderPhase = RenderPhase(
                state: .interrupted, label: "已中断，等待新参数…", index: 0, total: 1
            )
        } else {
            renderPhase = RenderPhase(
                state: .waiting, label: "等待新参数…", index: 0, total: 1
            )
        }

        let fast = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFastWork = nil
            self.renderFastPreviewNow(token: fastTokenValue)
        }
        pendingFastWork = fast
        DispatchQueue.main.asyncAfter(deadline: .now() + fastDebounce, execute: fast)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRenderWork = nil
            self.renderPreviewNow()
        }
        pendingRenderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDebounce, execute: work)
        bump()
    }

    /// 立即渲染（换片、改渲染比例、点“渲染”时使用）。
    func renderPreview() {
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        pendingFastWork?.cancel()
        pendingFastWork = nil
        fastToken += 1
        renderPreviewNow()
    }

    private func renderPreviewNow() {
        pendingFastWork?.cancel()
        pendingFastWork = nil
        guard let photo = currentPhoto(), let image = loadedImage,
              var params = try? photo.makeParams() else { return }
        params.io.inputColorSpace = loadedColorSpace
        params.io.inputCCTFDecoding = loadedCCTF
        renderToken += 1
        let token = renderToken
        previewRenderInFlight = true
        isRendering = true
        renderPhase = RenderPhase(state: .rendering, label: "显影中…", index: 0, total: 1)
        bump()
        let longEdge = max(image.width, image.height)
        let maxSize = max(160, Int(Double(longEdge) * previewScale))
        renderer.render(
            params: params,
            image: image,
            maxSize: maxSize,
            progress: { label, index, total in
                Task { @MainActor [weak self] in
                    guard let self, self.renderToken == token else { return }
                    self.renderPhase = RenderPhase(
                        state: .rendering, label: Self.stageLabel(label),
                        index: index, total: total
                    )
                }
            }
        ) { outcome in
            let histogram = Self.histogram(from: outcome.image)
            Task { @MainActor [weak self] in
                guard let self, self.renderToken == token else { return }
                self.previewImage = PreviewRenderer.nsImage(from: outcome.image)
                self.previewHistogram = histogram
                self.previewIsPredicted = false
                self.previewRevision += 1
                self.isRendering = false
                self.previewRenderInFlight = false
                self.accurateCompletedFastToken = self.fastToken
                self.renderPhase = .idle
                self.statusMessage = String(format: "预览 %.2f s", outcome.elapsed)
                self.bump()
            }
        }
    }

    /// LUT 预测帧：拖动后 150 ms 触发，只读共享烘焙结果。
    private func renderFastPreviewNow(token: Int) {
        guard let photo = currentPhoto(), let image = loadedImage,
              var params = try? photo.makeParams() else { return }
        params.io.inputColorSpace = loadedColorSpace
        params.io.inputCCTFDecoding = loadedCCTF
        let key = PreviewLUTService.cacheKey(
            edit: photo.edit, inputColorSpace: loadedColorSpace, inputCCTF: loadedCCTF
        )
        let longEdge = max(image.width, image.height)
        let scaledEdge = max(160, Int(Double(longEdge) * previewScale))
        let maxSize = min(scaledEdge, PreviewLUTService.maxPredictionEdge)
        let source = PreviewRenderer.prepared(image, maxSize: maxSize)
        let service = previewLUT
        previewLUTQueue.async { [weak self] in
            let start = Date()
            guard let bundle = service.bundle(for: params, key: key) else { return }
            var autoEV = 0.0
            if params.camera.autoExposure {
                autoEV = PreviewLUTService.measureAutoEV(
                    source: source, colorSpace: params.io.inputColorSpace,
                    applyCCTFDecoding: params.io.inputCCTFDecoding,
                    method: params.camera.autoExposureMethod
                )
            }
            let linear = bundle.predict(
                source: source, autoEV: autoEV,
                exposureEV: params.camera.exposureCompensationEV,
                printExposure: params.enlarger.printExposure,
                compensate: params.enlarger.printExposureCompensation
            )
            let display = PreviewLUTService.displayImage(fromLinear: linear, params: params)
            let image = PreviewRenderer.nsImage(from: display)
            let histogram = Self.histogram(from: display)
            let elapsed = Date().timeIntervalSince(start)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.fastToken == token,
                      self.accurateCompletedFastToken != token else { return }
                guard let image else { return }
                self.previewImage = image
                self.previewHistogram = histogram
                self.previewIsPredicted = true
                self.previewRevision += 1
                if !self.previewRenderInFlight {
                    self.isRendering = false
                    self.renderPhase = .idle
                }
                self.statusMessage = String(format: "预测 %.2f s", elapsed)
                self.bump()
            }
        }
    }

    /// 导出面板打开时调用：预测档 vs 精算的 ΔE₀₀ 预检。
    func refreshExportPreflight() {
        guard let photo = currentPhoto(), let image = loadedImage,
              var params = try? photo.makeParams() else {
            preflightNotice = nil
            preflightReport = nil
            return
        }
        params.io.inputColorSpace = loadedColorSpace
        params.io.inputCCTFDecoding = loadedCCTF
        guard !params.io.scanFilm else {
            preflightNotice = nil
            preflightReport = nil
            return
        }
        let key = PreviewLUTService.cacheKey(
            edit: photo.edit, inputColorSpace: loadedColorSpace, inputCCTF: loadedCCTF
        )
        let source = PreviewRenderer.prepared(image, maxSize: 256)
        preflightToken += 1
        let token = preflightToken
        preflightNotice = nil
        preflightReport = nil
        let service = previewLUT
        preflightQueue.async { [weak self] in
            guard let bundle = service.bundle(for: params, key: key) else { return }
            var autoEV = 0.0
            if params.camera.autoExposure {
                autoEV = PreviewLUTService.measureAutoEV(
                    source: source, colorSpace: params.io.inputColorSpace,
                    applyCCTFDecoding: params.io.inputCCTFDecoding,
                    method: params.camera.autoExposureMethod
                )
            }
            let report = PreviewPreflight.run(
                source: source, params: params, bundle: bundle, autoEV: autoEV
            )
            Task { @MainActor [weak self] in
                guard let self, self.preflightToken == token else { return }
                self.preflightReport = report
                self.preflightNotice = report?.notice
                self.bump()
            }
        }
    }

    private static func stageLabel(_ label: String) -> String {
        switch label {
        case "preprocess": return "预处理"
        case "filming.expose": return "胶片曝光"
        case "filming.develop": return "胶片显影"
        case "printing.expose": return "印相曝光"
        case "printing.develop": return "印相显影"
        case "scanning.scan_print": return "扫描打印"
        case "scanning.scan_film": return "正片扫描"
        default: return label
        }
    }

    func setFilm(_ id: String) {
        guard var photo = currentPhoto(), id != photo.edit.filmStock else { return }
        var edit = baseline
        edit.filmStock = id
        edit.quickIntents = quickIntents
        for (control, q) in quickIntents where abs(q) > 1e-9 {
            applyQuickMapping(id: control, q: q, edit: &edit)
        }
        photo.edit = edit
        persist(photo)
        schedulePreviewRender()
    }

    func setPaper(_ id: String) {
        guard var photo = currentPhoto(), id != photo.edit.printStock else { return }
        photo.edit.printStock = id
        persist(photo)
        schedulePreviewRender()
    }

    func resetParameters() {
        guard var photo = currentPhoto() else { return }
        photo.edit = baseline
        photo.edit.quickIntents = [:]
        quickIntents = [:]
        padIntent = .zero
        persist(photo)
        schedulePreviewRender()
    }

    @discardableResult
    func importPhotos(_ urls: [URL]) -> String? {
        var firstID: String?
        var imported = 0
        for url in urls {
            if let photo = try? store.importPhoto(from: url) {
                imported += 1
                firstID = firstID ?? photo.id
            }
        }
        bump()
        if let id = firstID {
            select(photoID: id)
        }
        warmThumbnails()
        statusMessage = imported > 0
            ? "已导入 \(imported) 张 RAW"
            : "未导入：显影台只支持 RAW"
        return firstID
    }

    func importFolder(_ url: URL) {
        var raws: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let file as URL in enumerator
            where ImageLoader.rawSuffixes.contains(file.pathExtension.lowercased()) {
                raws.append(file)
            }
        }
        if raws.isEmpty {
            statusMessage = "文件夹中没有 RAW"
        } else {
            importPhotos(raws)
        }
    }

    func toggleFavorite(_ photoID: String) {
        guard var photo = photo(with: photoID) else { return }
        photo.favorite.toggle()
        persist(photo)
    }

    func setColorLabel(_ photoID: String, _ label: ColorLabel?) {
        guard var photo = photo(with: photoID) else { return }
        photo.colorLabel = label?.rawValue
        persist(photo)
    }

    func removePhoto(_ photoID: String) {
        guard selectedID != photoID || store.photos.count > 1 else {
            try? store.remove(id: photoID)
            selectedID = nil
            imageLoadToken += 1
            loadedImage = nil
            previewImage = nil
            originalImage = nil
            previewCache.removeAll()
            refreshThumbnailCache()
            bump()
            return
        }
        try? store.remove(id: photoID)
        previewCache.removeValue(forKey: photoID)
        refreshThumbnailCache()
        if selectedID == photoID {
            selectedID = nil
            if let next = store.photos.first {
                select(photoID: next.id)
            } else {
                imageLoadToken += 1
                loadedImage = nil
                previewImage = nil
                originalImage = nil
            }
        }
        bump()
    }

    func setPreviewScale(_ scale: Double) {
        let value = min(max(scale, 0.125), 1.0)
        guard value != previewScale else { return }
        previewScale = value
        previewCache.removeAll()
        bump()
        renderPreview()
    }

    func exportAs(_ format: String) {
        guard let photo = currentPhoto() else {
            statusMessage = "没有可导出的照片"
            return
        }
        let exportFormat: ExportFormat
        switch format {
        case "tiff8": exportFormat = .tiff8
        case "tiff16-prophoto": exportFormat = .tiff16ProPhoto
        case "exr16": exportFormat = .exrHalf
        default: exportFormat = .tiff16
        }
        let base = (photo.filename as NSString).deletingPathExtension
        let settings = ExportSettings(filenameTemplate: "\(base)-spektra")
        var resolved = settings
        resolved.format = exportFormat
        presentSavePanel(photo: photo, settings: resolved)
    }

    /// 导出设置面板：目录已指定时直接写盘，否则退回保存面板。
    func export(_ settings: ExportSettings) {
        guard let photo = currentPhoto() else {
            statusMessage = "没有可导出的照片"
            return
        }
        if let directory = settings.directory {
            let stem = Self.expandedStem(
                settings.filenameTemplate,
                name: (photo.filename as NSString).deletingPathExtension,
                film: filmDisplayName(photo.edit.filmStock),
                paper: paperDisplayName(photo.edit.printStock)
            )
            let target = Self.uniqueDestination(
                directory: directory, stem: stem, ext: settings.format.fileExtension
            )
            enqueueExport(photo: photo, destination: target, settings: settings)
        } else {
            presentSavePanel(photo: photo, settings: settings)
        }
    }

    private func presentSavePanel(photo: LibraryPhoto, settings: ExportSettings) {
        let ext = settings.format.fileExtension
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        let stem = Self.expandedStem(
            settings.filenameTemplate,
            name: (photo.filename as NSString).deletingPathExtension,
            film: filmDisplayName(photo.edit.filmStock),
            paper: paperDisplayName(photo.edit.printStock)
        )
        panel.nameFieldStringValue = "\(stem).\(ext)"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.enqueueExport(photo: photo, destination: destination, settings: settings)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func enqueueExport(photo: LibraryPhoto, destination: URL, settings: ExportSettings) {
        exportQueue.enqueue(
            ExportRequest(
                photoID: photo.id, destination: destination,
                bitDepth: settings.format.bitDepth,
                colorSpace: settings.format.colorSpace,
                cctfEncoding: settings.format.cctfEncoding,
                longEdge: settings.longEdge
            ),
            photo: photo
        )
        statusMessage = "开始导出 \(destination.lastPathComponent)"
    }

    private static func expandedStem(
        _ template: String, name: String, film: String, paper: String
    ) -> String {
        var text = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "{name}-spektra" }
        text = text
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{film}", with: film)
            .replacingOccurrences(of: "{paper}", with: paper)
        text = text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
        if text.isEmpty { text = "\(name)-spektra" }
        return text
    }

    private static func uniqueDestination(directory: URL, stem: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appendingPathComponent("\(stem).\(ext)")
        var index = 1
        while FileManager.default.fileExists(atPath: target.path), index < 1000 {
            target = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
            index += 1
        }
        return target
    }

    func exportCurrent(to destination: URL? = nil) {
        guard let photo = currentPhoto() else { return }
        let target = destination ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("Spektrafilm-\(photo.id).tif")
        exportQueue.enqueue(
            ExportRequest(photoID: photo.id, destination: target, bitDepth: 16),
            photo: photo
        )
        statusMessage = "开始导出 \(target.lastPathComponent)"
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    /// 56 桶 RGB 直方图，取自当前预览输出（线性显示空间，桶内最大值归一）。
    private static func histogram(from image: ImageRGB, binCount: Int = 56) -> HistogramData {
        var bins = [[Double]](repeating: [Double](repeating: 0, count: binCount), count: 3)
        let pixels = image.width * image.height
        guard pixels > 0 else { return PreviewData.histogram }
        let stride = max(1, pixels / 200_000)
        var index = 0
        while index < pixels {
            for channel in 0..<3 {
                let value = min(max(image.data[index * 3 + channel], 0), 1)
                let bucket = min(binCount - 1, Int(value * Double(binCount)))
                bins[channel][bucket] += 1
            }
            index += stride
        }
        let peak = bins.flatMap { $0 }.max() ?? 0
        guard peak > 0 else { return PreviewData.histogram }
        return HistogramData(
            red: bins[0].map { $0 / peak },
            green: bins[1].map { $0 / peak },
            blue: bins[2].map { $0 / peak }
        )
    }

    /// 把线性工作图转成屏幕显示用的 sRGB 8-bit NSImage（用于“对比”原图）。
    private static func displayImage(_ image: ImageRGB, colorSpace: String,
                                     cctfDecoding: Bool) -> NSImage? {
        var output = image
        if cctfDecoding {
            let kind = ColorMath.cctfKind(for: colorSpace)
            output = output.map { Vec3(
                ColorMath.cctfDecode($0.x, kind: kind),
                ColorMath.cctfDecode($0.y, kind: kind),
                ColorMath.cctfDecode($0.z, kind: kind)
            ) }
        }
        output = output.map { pixel in
            let converted = ColorMath.rgbToRGB(pixel, from: colorSpace, to: "sRGB")
            return Vec3(converted.x, converted.y, converted.z)
        }
        let kind = ColorMath.cctfKind(for: "sRGB")
        output = output.map { Vec3(
            ColorMath.cctfEncode($0.x, kind: kind),
            ColorMath.cctfEncode($0.y, kind: kind),
            ColorMath.cctfEncode($0.z, kind: kind)
        ) }
        return PreviewRenderer.nsImage(from: output.sanitizedNonFinite())
    }

    private func applyQuickMapping(id: String, q: Double, edit: inout PhotoEdit) {
        switch id {
        case "camera_exposure":
            edit.camera.exposureCompensationEV = clamp(
                baseline.camera.exposureCompensationEV + q, -5, 5)
            // 与 Python 快速轴一致：拖动曝光时临时关闭印相自动亮度补偿，
            // 否则印相归一化会把它抵消成反差；回 0 时恢复基线设置。
            edit.enlarger.printExposureCompensation = abs(q) <= 1e-9
                ? baseline.enlarger.printExposureCompensation
                : false
        case "print_brightness":
            let b = baseline.enlarger.printExposure
            edit.enlarger.printExposure = clamp(b * pow(2, -q), 0.25, 4)
        case "tonal_contrast":
            let morph = baseline.printRender.densityCurvesMorph
            let value = clamp(morph.gammaFactor * (1 + 0.35 * q / 100), 0.5, 2.0)
            edit.printRender.densityCurvesMorph.gammaFactor = value
            edit.printRender.densityCurvesMorph.active = q != 0 ? true : morph.active
        case "color_density":
            let b = baseline.filmRender.dirCouplers.inhibitionInterlayer
            edit.filmRender.dirCouplers.inhibitionInterlayer = clamp(b * (1 + 0.5 * q / 100), 0, 1.5)
            edit.filmRender.dirCouplers.active = q != 0 ? true : baseline.filmRender.dirCouplers.active
        case "grain_amount":
            let grain = baseline.filmRender.grain
            edit.filmRender.grain.densityMin = grain.densityMin.map {
                clamp($0 * (1 + 0.9 * q / 100), 0.005, 0.08)
            }
            edit.filmRender.grain.uniformity = grain.uniformity.map {
                clamp($0 - 0.06 * q / 100, 0.90, 0.995)
            }
            edit.filmRender.grain.active = q <= -99 ? false : grain.active
        case "grain_size":
            let grain = baseline.filmRender.grain
            edit.filmRender.grain.particleAreaUM2 = clamp(
                grain.particleAreaUM2 * pow(2, 0.9 * q / 100), 0.02, 0.8)
            edit.filmRender.grain.blur = clamp(grain.blur * (1 + 0.25 * q / 100), 0, 1.5)
        case "halation_amount":
            let h = baseline.filmRender.halation
            edit.filmRender.halation.halationAmount = clamp(h.halationAmount * (1 + 1.2 * q / 100), 0, 2)
            edit.filmRender.halation.active = q <= -99 ? false : h.active
        case "halation_scale":
            let h = baseline.filmRender.halation
            edit.filmRender.halation.halationSpatialScale = clamp(
                h.halationSpatialScale * pow(2, 0.6 * q / 100), 0.5, 2.5)
        case "diffusion":
            let base = baseline.camera.diffusionFilter
            let strength: Double
            if q > 0 {
                strength = base.strength + (2.0 - base.strength) * q / 100
            } else if q < 0 {
                strength = base.strength * (1 + q / 100)
            } else {
                strength = base.strength
            }
            edit.camera.diffusionFilter.strength = clamp(strength, 0, 2)
            edit.camera.diffusionFilter.active = q <= -99 ? false : (base.active || q > 0)
        case "scanner_clarity":
            let scanner = baseline.scanner
            if q > 0 {
                let amount = scanner.unsharpMask[1]
                edit.scanner.unsharpMask = [
                    scanner.unsharpMask[0],
                    clamp(amount + (1.8 - amount) * q / 100, 0, 2),
                ]
                edit.scanner.lensBlur = scanner.lensBlur
            } else {
                edit.scanner.lensBlur = clamp(scanner.lensBlur + 0.6 * (-q) / 100, 0, 0.8)
                edit.scanner.unsharpMask = scanner.unsharpMask
            }
        default:
            break
        }
    }

    func applyPro(_ id: String, _ value: Double) {
        guard var photo = currentPhoto() else { return }
        var edit = photo.edit
        switch id {
        case "print_exposure": edit.enlarger.printExposure = value
        case "exposure_compensation_ev": edit.camera.exposureCompensationEV = value
        case "film_gamma_factor":
            edit.printRender.densityCurvesMorph.gammaFactor = value
            edit.printRender.densityCurvesMorph.active = true
        case "developer_exhaustion": edit.printRender.densityCurvesMorph.developerExhaustion = value
        case "gamma_factor": edit.printRender.densityCurvesMorph.gammaFactor = value
        case "gamma_factor_fast": edit.printRender.densityCurvesMorph.gammaFactorFast = value
        case "gamma_factor_slow": edit.printRender.densityCurvesMorph.gammaFactorSlow = value
        case "gamma_factor_red": edit.printRender.densityCurvesMorph.gammaFactorRed = value
        case "gamma_factor_green": edit.printRender.densityCurvesMorph.gammaFactorGreen = value
        case "gamma_factor_blue": edit.printRender.densityCurvesMorph.gammaFactorBlue = value
        case "white_level": edit.scanner.whiteLevel = value
        case "black_level": edit.scanner.blackLevel = value
        case "glare_percent": edit.printRender.glare.percent = value
        case "glare_roughness": edit.printRender.glare.roughness = value
        case "preflash_exposure": edit.enlarger.preflashExposure = value
        case "preflash_y": edit.enlarger.preflashYFilterShift = value
        case "preflash_m": edit.enlarger.preflashMFilterShift = value
        case "print_y_filter_shift": edit.enlarger.yFilterShift = value
        case "print_m_filter_shift": edit.enlarger.mFilterShift = value
        case "inhibition_interlayer": edit.filmRender.dirCouplers.inhibitionInterlayer = value
        case "inhibition_samelayer": edit.filmRender.dirCouplers.inhibitionSameLayer = value
        case "coupler_amount": edit.filmRender.dirCouplers.amount = value
        case "diffusion_size_um": edit.filmRender.dirCouplers.diffusionSizeUM = value
        case "particle_area_um2": edit.filmRender.grain.particleAreaUM2 = value
        case "grain_blur": edit.filmRender.grain.blur = value
        case "blur_dye_clouds_um": edit.filmRender.grain.blurDyeCloudsUM = value
        case "halation_amount": edit.filmRender.halation.halationAmount = value
        case "scatter_amount": edit.filmRender.halation.scatterAmount = value
        case "halation_spatial_scale": edit.filmRender.halation.halationSpatialScale = value
        case "boost_ev": edit.filmRender.halation.boostEV = value
        case "protect_ev": edit.filmRender.halation.protectEV = value
        case "lens_blur": edit.scanner.lensBlur = value
        case "lens_blur_um": edit.camera.lensBlurUM = value
        case "diffusion_strength": edit.camera.diffusionFilter.strength = value
        case "film_format_mm": edit.camera.filmFormatMM = value
        case "upscale_factor": edit.io.upscaleFactor = value
        default: break
        }
        photo.edit = edit
        persist(photo)
        schedulePreviewRender()
    }

    func applyProToggle(_ id: String, _ value: Bool) {
        guard var photo = currentPhoto() else { return }
        var edit = photo.edit
        switch id {
        case "print_exposure_compensation": edit.enlarger.printExposureCompensation = value
        case "auto_exposure": edit.camera.autoExposure = value
        case "white_correction": edit.scanner.whiteCorrection = value
        case "black_correction": edit.scanner.blackCorrection = value
        case "glare_active": edit.printRender.glare.active = value
        case "couplers_active": edit.filmRender.dirCouplers.active = value
        case "grain_active": edit.filmRender.grain.active = value
        case "halation_active": edit.filmRender.halation.active = value
        case "chemistry_active": edit.printRender.densityCurvesMorph.active = value
        case "camera_diffusion_active": edit.camera.diffusionFilter.active = value
        case "input_cctf_decoding": edit.io.inputCCTFDecoding = value
        case "input_crop": edit.io.crop = value
        case "saving_cctf": edit.io.outputCCTFEncoding = value
        default: break
        }
        photo.edit = edit
        persist(photo)
        schedulePreviewRender()
    }

    // MARK: - 调色台流程

    func beginGrade() {
        guard let photo = currentPhoto() else {
            statusMessage = "没有可调色的照片"
            return
        }
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        renderToken += 1
        renderer.invalidate()
        previewRenderInFlight = false
        isRendering = false
        renderPhase = .idle

        resetGradeState()
        gradeOrigin = .developed
        prepareGradeSource(for: photo)
    }

    func beginGradeDirect(photoID: String) {
        guard let photo = photo(with: photoID) else {
            statusMessage = "没有可调色的照片"
            return
        }
        pendingRenderWork?.cancel()
        pendingRenderWork = nil
        renderToken += 1
        renderer.invalidate()
        previewRenderInFlight = false
        isRendering = false
        renderPhase = .idle

        guard photo.isRaw else {
            statusMessage = "仅调色仅支持 RAW"
            return
        }
        selectedID = photoID
        statusMessage = photo.filename
        resetGradeState()
        gradeOrigin = .direct
        prepareGradeSourceDirect(for: photo)
    }

    private func resetGradeState() {
        gradePendingProxy?.cancel()
        gradePendingProxy = nil
        gradePendingSettle?.cancel()
        gradePendingSettle = nil
        gradePreviewInFlight = false
        gradeIsActive = true
        gradeRecipe = GradeRecipe()
        gradePresets = GradePresetStore.shared.all
        gradeLUTs = GradePresetStore.shared.luts()
        gradePreviewImage = nil
        gradeAnalysis = nil
        gradeHistogram = nil
        gradeClarityReport = nil
        gradeClarityAnalysis = nil
        gradeClarityInFlight = false
        gradeClarityToken += 1
        gradeSource = nil
        gradeSourceReady = false
        gradeSourceSize = ""
        gradeProxyCache = [:]
        gradeExportInFlight = false
        _ = bumpGradePreviewToken()
        _ = bumpGradeExportToken()
    }

    func endGrade() {
        gradeClarityToken += 1
        gradeClarityInFlight = false
        gradeIsActive = false
        gradePendingProxy?.cancel()
        gradePendingProxy = nil
        gradePendingSettle?.cancel()
        gradePendingSettle = nil
        _ = bumpGradePreviewToken()
        _ = bumpGradeExportToken()
        gradePreviewInFlight = false
        gradeExportInFlight = false
        gradePhase = .idle
    }

    private func prepareGradeSource(for photo: LibraryPhoto) {
        gradeSourceToken += 1
        let token = gradeSourceToken
        gradeSourceReady = false
        gradePhase = RenderPhase(
            state: .rendering, label: "生成交接图…", index: 0, total: 1
        )
        bump()

        guard let image = loadedImage, var params = try? photo.makeParams() else {
            gradePhase = .idle
            statusMessage = "无法读取交接图"
            return
        }
        params.io.inputColorSpace = loadedColorSpace
        params.io.inputCCTFDecoding = loadedCCTF
        params.io.outputColorSpace = "ProPhoto RGB"
        params.io.outputCCTFEncoding = false

        gradeRenderer.render(
            params: params,
            image: image,
            maxSize: gradeSourceEdge,
            progress: { [weak self] label, index, total in
                Task { @MainActor [weak self] in
                    guard let self, self.gradeSourceToken == token else { return }
                    self.gradePhase = RenderPhase(
                        state: .rendering,
                        label: "交接图 · \(Self.stageLabel(label))",
                        index: index, total: total
                    )
                }
            }
        ) { [weak self] outcome in
            guard let self else { return }
            self.gradeQueue.async {
                let linear = GradeEngine.prepareSource(outcome.image)
                Task { @MainActor [weak self] in
                    guard let self, self.gradeSourceToken == token else { return }
                    self.gradeSource = linear
                    self.gradeSourceReady = true
                    self.gradeSourceSize = "\(linear.width)×\(linear.height)"
                    self.gradeProxyCache = [:]
                    self.scheduleGradePreview(immediate: true)
                }
            }
        }
    }

    private func prepareGradeSourceDirect(for photo: LibraryPhoto) {
        gradeSourceToken += 1
        let token = gradeSourceToken
        gradeSourceReady = false
        gradePhase = RenderPhase(
            state: .rendering, label: "解码 RAW…", index: 0, total: 1
        )
        bump()

        let url = store.originalURL(for: photo)
        gradeQueue.async { [weak self] in
            guard let self else { return }
            do {
                var options = RawDecoder.Options()
                options.outputColorSpace = "sRGB"
                options.outputCCTFEncoding = false
                let decoded = try RawDecoder.decode(url: url, options: options)
                let source = ClarityMath.downsampledToLongEdge(
                    decoded, maxEdge: self.gradeFullEdge
                )
                Task { @MainActor [weak self] in
                    guard let self, self.gradeSourceToken == token else { return }
                    self.gradeSource = source
                    self.gradeSourceReady = true
                    self.gradeSourceSize = "\(source.width)×\(source.height)"
                    self.gradeProxyCache = [:]
                    self.scheduleClarityAnalysis()
                    self.scheduleGradePreview(immediate: true)
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.gradeSourceToken == token else { return }
                    self.gradePhase = .idle
                    self.statusMessage = "RAW 解码失败：\(error.localizedDescription)"
                    self.bump()
                }
            }
        }
    }

    private func scheduleClarityAnalysis() {
        guard gradeIsActive, let source = gradeSource,
              gradeRecipe.adaptive.enabled else { return }
        let recipe = gradeRecipe
        let clarityMode: ClarityMode = gradeOrigin == .direct ? .standalone : .film
        gradeClarityToken += 1
        let token = gradeClarityToken
        gradeClarityInFlight = true
        gradeQueue.async { [weak self] in
            guard let self else { return }
            let encoded = GradeEngine.encodedSource(source, recipe: recipe)
            let analysis = try? AdaptiveClarityEngine.analyze(encoded, mode: clarityMode)
            let report = analysis.map {
                ClarityAnalyzer.report(
                    for: $0, mode: clarityMode,
                    controls: AdaptiveClarityEngine.suggestedControls(
                        for: $0, mode: clarityMode
                    )
                )
            }
            Task { @MainActor [weak self] in
                guard let self, self.gradeClarityToken == token else { return }
                self.gradeClarityInFlight = false
                self.gradeClarityAnalysis = analysis
                self.gradeClarityReport = report
                if let report, self.gradeRecipe.adaptive.enabled,
                   self.gradeRecipe.adaptive.clarity <= 0.001,
                   self.gradeRecipe.adaptive.color <= 0.001 {
                    var updated = self.gradeRecipe
                    updated.adaptive.clarity = report.suggestedClarity
                    updated.adaptive.color = report.suggestedColor
                    self.gradeRecipe = updated
                }
                self.scheduleGradePreview()
            }
        }
    }

    @discardableResult
    private func bumpGradePreviewToken() -> Int {
        gradeLock.lock()
        gradePreviewToken += 1
        let token = gradePreviewToken
        gradeLock.unlock()
        return token
    }

    private func isCurrentGradeToken(_ token: Int) -> Bool {
        gradeLock.lock()
        defer { gradeLock.unlock() }
        return token == gradePreviewToken
    }

    @discardableResult
    private func bumpGradeExportToken() -> Int {
        gradeLock.lock()
        gradeExportToken += 1
        let token = gradeExportToken
        gradeLock.unlock()
        return token
    }

    private func isCurrentGradeExportToken(_ token: Int) -> Bool {
        gradeLock.lock()
        defer { gradeLock.unlock() }
        return token == gradeExportToken
    }

    /// 调色预览调度：交互期 120ms 节流代理图，停止输入 1.1s 后精修。
    private func scheduleGradePreview(immediate: Bool = false) {
        guard gradeIsActive, gradeSourceReady, !gradeExportInFlight else { return }
        gradePendingProxy?.cancel()
        gradePendingProxy = nil
        gradePendingSettle?.cancel()
        gradePendingSettle = nil

        if immediate {
            _ = bumpGradePreviewToken()
            renderGradePreview(edge: gradeFullEdge)
            return
        }

        if gradePreviewInFlight {
            _ = bumpGradePreviewToken()
            gradePreviewInFlight = false
            gradePhase = RenderPhase(
                state: .interrupted, label: "已中断，等待新参数…", index: 0, total: 1
            )
        } else {
            gradePhase = RenderPhase(
                state: .waiting, label: "等待调色参数…", index: 0, total: 1
            )
        }

        let proxy = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gradePendingProxy = nil
            self.renderGradePreview(edge: self.gradeProxyEdge)
        }
        gradePendingProxy = proxy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: proxy)

        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gradePendingSettle = nil
            self.gradePendingProxy?.cancel()
            self.gradePendingProxy = nil
            self.renderGradePreview(edge: self.gradeFullEdge)
        }
        gradePendingSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: settle)
        bump()
    }

    private func renderGradePreview(edge: Int) {
        guard let source = gradeSource, gradeIsActive, !gradeExportInFlight else { return }
        let recipe = gradeRecipe
        let token = bumpGradePreviewToken()
        gradePreviewInFlight = true
        gradePhase = RenderPhase(
            state: .rendering,
            label: edge < gradeFullEdge ? "调色代理…" : "调色精修…",
            index: 0, total: 1
        )
        bump()

        let clarityAnalysis = gradeClarityAnalysis
        let clarityMode: ClarityMode = gradeOrigin == .direct ? .standalone : .film
        let clarityContext: ClarityRenderContext? = {
            guard recipe.adaptive.enabled, let clarityAnalysis else { return nil }
            return ClarityRenderContext(
                analysis: clarityAnalysis, mode: clarityMode,
                workingLongEdge: min(edge, 1024), validate: false
            )
        }()

        let proxy: ImageRGB
        if let cached = gradeProxyCache[edge] {
            proxy = cached
        } else {
            proxy = GradeEngine.downsampleLinear(source, maxLongEdge: edge)
            gradeProxyCache[edge] = proxy
        }

        gradeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let result = try GradeEngine.render(
                    proxy, recipe: recipe, clarity: clarityContext,
                    shouldCancel: { !self.isCurrentGradeToken(token) }
                )
                let histogram = Self.histogram(from: result.image)
                let image = PreviewRenderer.nsImage(from: result.image)
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentGradeToken(token) else { return }
                    self.gradePreviewImage = image
                    self.gradeAnalysis = result.analysis
                    self.gradeClarityReport = result.clarityReport ?? self.gradeClarityReport
                    self.gradeHistogram = histogram
                    self.gradePreviewInFlight = false
                    self.gradePhase = .idle
                    self.bump()
                }
            } catch is GradeCancelled {
                return
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentGradeToken(token) else { return }
                    self.gradePreviewInFlight = false
                    self.gradePhase = .idle
                    self.statusMessage = "调色失败：\(error)"
                    self.bump()
                }
            }
        }
    }

    func setGradeRecipe(_ recipe: GradeRecipe) {
        guard gradeIsActive else { return }
        let previous = gradeRecipe
        gradeRecipe = recipe
        if recipe.adaptive.enabled {
            let exposureChanged = previous.light.exposure != recipe.light.exposure
                || previous.color.temperature != recipe.color.temperature
                || previous.color.tint != recipe.color.tint
            if gradeClarityAnalysis == nil || exposureChanged {
                if !gradeClarityInFlight || exposureChanged {
                    gradePendingProxy?.cancel()
                    gradePendingProxy = nil
                    gradePendingSettle?.cancel()
                    gradePendingSettle = nil
                    _ = bumpGradePreviewToken()
                    scheduleClarityAnalysis()
                }
                return
            }
        }
        scheduleGradePreview()
    }

    /// 预览分辨率切换：清掉旧代理缓存，按新尺寸立即重绘。
    func setGradePreviewScale(_ value: Double) {
        guard gradeIsActive, value != gradePreviewScale else { return }
        gradePreviewScale = value
        gradeProxyCache = [:]
        _ = bumpGradePreviewToken()
        scheduleGradePreview(immediate: true)
        bump()
    }

    func reRenderGrade() {
        guard gradeIsActive, gradeSourceReady else { return }
        scheduleGradePreview(immediate: true)
    }

    func saveGradePreset(name: String, recipe: GradeRecipe) {
        _ = GradePresetStore.shared.save(name: name, recipe: recipe)
        gradePresets = GradePresetStore.shared.all
        statusMessage = "预设已保存"
        bump()
    }

    func deleteGradePreset(id: String) {
        if GradePresetStore.shared.delete(id: id) {
            gradePresets = GradePresetStore.shared.all
            statusMessage = "预设已删除"
            bump()
        }
    }

    func importGradeLUT(from url: URL) {
        do {
            let entry = try GradePresetStore.shared.importLUT(from: url)
            gradeLUTs = GradePresetStore.shared.luts()
            var recipe = gradeRecipe
            recipe.lut.path = entry.path
            setGradeRecipe(recipe)
            statusMessage = "LUT 已导入"
        } catch {
            statusMessage = "LUT 导入失败：\(error.localizedDescription)"
        }
    }

    func exportGrade(_ settings: ExportSettings) {
        guard let photo = currentPhoto() else {
            statusMessage = "没有可导出的照片"
            return
        }
        if let directory = settings.directory {
            let name = (photo.filename as NSString).deletingPathExtension
            let stem = Self.expandedStem(
                settings.filenameTemplate, name: name,
                film: filmDisplayName(photo.edit.filmStock),
                paper: paperDisplayName(photo.edit.printStock)
            )
            let target = Self.uniqueDestination(
                directory: directory, stem: stem, ext: settings.format.fileExtension
            )
            runGradeExport(photo: photo, destination: target, settings: settings)
        } else {
            let ext = settings.format.fileExtension
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
            let name = (photo.filename as NSString).deletingPathExtension
            let stem = Self.expandedStem(
                settings.filenameTemplate, name: name,
                film: filmDisplayName(photo.edit.filmStock),
                paper: paperDisplayName(photo.edit.printStock)
            )
            panel.nameFieldStringValue = "\(stem).\(ext)"
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let destination = panel.url else { return }
                self?.runGradeExport(photo: photo, destination: destination, settings: settings)
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(panel.runModal())
            }
        }
    }

    private func runGradeExport(
        photo: LibraryPhoto, destination: URL, settings: ExportSettings
    ) {
        gradePendingProxy?.cancel()
        gradePendingProxy = nil
        gradePendingSettle?.cancel()
        gradePendingSettle = nil
        _ = bumpGradePreviewToken()
        gradeExportInFlight = true
        let recipe = gradeRecipe
        let origin = gradeOrigin
        let token = bumpGradeExportToken()
        gradePhase = RenderPhase(
            state: .rendering, label: "导出调色…", index: 0, total: 1
        )
        bump()

        gradeQueue.async { [weak self] in
            guard let self else { return }
            do {
                let sourceURL = self.store.originalURL(for: photo)
                let linear: ImageRGB
                if origin == .direct {
                    var options = RawDecoder.Options()
                    options.outputColorSpace = "sRGB"
                    options.outputCCTFEncoding = false
                    linear = try RawDecoder.decode(url: sourceURL, options: options)
                } else {
                    let loaded = try ImageLoader.load(url: sourceURL)
                    var params = try photo.makeParams()
                    params.io.inputColorSpace = loaded.colorSpace
                    params.io.inputCCTFDecoding = loaded.cctfDecoding
                    params.io.outputColorSpace = "ProPhoto RGB"
                    params.io.outputCCTFEncoding = false

                    let pipeline = SimulationPipeline(params: params, keepTaps: false)
                    pipeline.shouldCancel = { !self.isCurrentGradeExportToken(token) }
                    let full = pipeline.process(loaded.image, progress: { label, index, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.isCurrentGradeExportToken(token) else { return }
                            self.gradePhase = RenderPhase(
                                state: .rendering, label: "导出 · \(Self.stageLabel(label))",
                                index: index, total: total
                            )
                        }
                    })
                    linear = GradeEngine.prepareSource(full.rgbOut)
                }

                var clarityContext: ClarityRenderContext?
                if recipe.adaptive.enabled {
                    let encoded = GradeEngine.encodedSource(linear, recipe: recipe)
                    let analysisMode: ClarityMode = origin == .direct ? .standalone : .film
                    let analysis = try AdaptiveClarityEngine.analyze(
                        encoded, mode: analysisMode
                    )
                    clarityContext = ClarityRenderContext(
                        analysis: analysis,
                        mode: analysisMode,
                        workingLongEdge: 0, validate: true
                    )
                }
                let graded = try GradeEngine.render(
                    linear, recipe: recipe, clarity: clarityContext,
                    shouldCancel: { !self.isCurrentGradeExportToken(token) }
                )
                var output = graded.image
                if settings.longEdge > 0 {
                    output = Resize.longEdge(output, maxSize: settings.longEdge)
                }
                let targetSpace = settings.format.colorSpace ?? "sRGB"
                let targetCCTF = settings.format.cctfEncoding ?? true
                output = Self.convertForExport(
                    output, colorSpace: targetSpace, cctfEncoding: targetCCTF
                )
                try ImageExport.save(
                    output, to: destination,
                    bitDepth: settings.format.bitDepth,
                    colorSpace: targetSpace, cctfEncoding: targetCCTF
                )
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentGradeExportToken(token) else { return }
                    self.gradeExportInFlight = false
                    self.gradePhase = .idle
                    self.statusMessage = "已导出到 \(destination.lastPathComponent)"
                    self.bump()
                }
            } catch is GradeCancelled {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentGradeExportToken(token) else { return }
                    self.gradeExportInFlight = false
                    self.gradePhase = .idle
                    self.bump()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentGradeExportToken(token) else { return }
                    self.gradeExportInFlight = false
                    self.gradePhase = .idle
                    self.statusMessage = "导出失败：\(error)"
                    self.bump()
                }
            }
        }
    }

    private static func convertForExport(
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
}

extension EngineHost {
    func filmDisplayName(_ stock: String) -> String {
        PreviewData.films.first { $0.id == stock }?.name ?? stock
    }

    func paperDisplayName(_ stock: String) -> String {
        PreviewData.papers.first { $0.id == stock }?.name ?? stock
    }

    func photoItem(_ photo: LibraryPhoto) -> PhotoItem {
        PhotoItem(
            id: photo.id,
            filename: photo.filename,
            asset: "",
            film: filmDisplayName(photo.edit.filmStock),
            paper: paperDisplayName(photo.edit.printStock),
            dimensions: "\(photo.width)×\(photo.height)",
            isRaw: photo.isRaw,
            favorite: photo.favorite,
            color: photo.colorLabel.flatMap(ColorLabel.init(rawValue:)),
            isGraded: !photo.edit.quickIntents.isEmpty,
            thumbnailPath: thumbnailCache[photo.id] ?? photo.thumbnailPath
        )
    }

    func librarySnapshot() -> LibrarySnapshot {
        let items = store.photos.map(photoItem)
        return LibrarySnapshot(
            folderCount: 1,
            photoCount: items.count,
            sectionTitle: "全部照片",
            sectionCount: "\(items.count) 张照片",
            folders: [
                FolderItem(id: "all", name: "全部照片", count: items.count, isCurrent: true),
            ],
            photos: items,
            statusMessage: statusMessage,
            currentID: selectedID
        )
    }

    func editorSnapshot(for photoID: String) -> EditorSnapshot {
        guard let photo = self.photo(with: photoID) ?? currentPhoto() else {
            return previewEditorSnapshot()
        }
        let item = photoItem(photo)
        let strip = [photo] + store.photos.filter { $0.id != photo.id }.prefix(3)
        let image = (photo.id == selectedID) ? previewImage : previewCache[photo.id]
        let edit = photo.edit
        let baselineEdit = (photo.id == selectedID) ? baseline : edit
        return EditorSnapshot(
            photo: item,
            filmName: filmDisplayName(edit.filmStock),
            paperName: paperDisplayName(edit.printStock),
            filmstrip: strip.map(photoItem),
            quickGroups: quickGroups(edit: edit, baseline: baselineEdit),
            proPages: proPages(edit: edit, film: filmDisplayName(edit.filmStock),
                               paper: paperDisplayName(edit.printStock)),
            histogram: (photo.id == selectedID ? previewHistogram : nil) ?? PreviewData.histogram,
            dirtyCount: edit.quickIntents.filter { abs($0.value) > 1e-9 }.count,
            currentFilmID: edit.filmStock,
            currentPaperID: edit.printStock,
            stripCount: store.photos.count,
            previewImage: image,
            originalImage: photo.id == selectedID ? originalImage : nil,
            previewScale: previewScale,
            renderPhase: photo.id == selectedID ? renderPhase : .idle,
            previewIsPredicted: photo.id == selectedID ? previewIsPredicted : false,
            previewRevision: photo.id == selectedID ? previewRevision : 0,
            preflightNotice: photo.id == selectedID ? preflightNotice : nil
        )
    }

    private func previewEditorSnapshot() -> EditorSnapshot {
        let item = PhotoItem(
            id: "empty", filename: "未选择照片", asset: "window-still",
            film: "—", paper: nil, dimensions: "0×0", isRaw: false,
            favorite: false, color: nil, isGraded: false
        )
        return EditorSnapshot(
            photo: item, filmName: "—", paperName: "—", filmstrip: [],
            quickGroups: PreviewData.quickGroups, proPages: PreviewData.proPages,
            histogram: PreviewData.histogram, dirtyCount: 0,
            currentFilmID: "kodak_portra_400", currentPaperID: "kodak_supra_endura",
            stripCount: 0
        )
    }

    func gradeSnapshot(for photoID: String) -> GradeSnapshot {
        guard let photo = self.photo(with: photoID) else {
            return GradeSnapshot(photo: PhotoItem(
                id: "empty", filename: "未选择照片", asset: "window-still",
                film: "—", paper: nil, dimensions: "0×0", isRaw: false,
                favorite: false, color: nil, isGraded: false
            ), handoffMeta: "")
        }
        let item = photoItem(photo)
        let active = photo.id == selectedID && gradeIsActive
        let meta: String
        if active {
            if gradeSourceReady {
                let source = gradeOrigin == .direct
                    ? "RAW 直入 · 线性 sRGB"
                    : "线性交接图 · sRGB 显示"
                meta = "\(gradeSourceSize) · \(source)"
            } else {
                meta = gradeOrigin == .direct ? "正在解码 RAW…" : "正在生成交接图…"
            }
        } else {
            meta = "调色台"
        }
        return GradeSnapshot(
            photo: item,
            handoffMeta: meta,
            previewImage: active ? gradePreviewImage : nil,
            sourceReady: active && gradeSourceReady,
            sourceSize: active ? gradeSourceSize : "",
            analysis: active ? gradeAnalysis : nil,
            presets: gradePresets,
            luts: gradeLUTs,
            recipe: gradeRecipe,
            phase: active ? gradePhase : .idle,
            histogram: active ? (gradeHistogram ?? PreviewData.histogram) : PreviewData.histogram,
            statusMessage: statusMessage,
            origin: gradeOrigin,
            clarityReport: active ? gradeClarityReport : nil,
            previewScale: gradePreviewScale
        )
    }

    func quickValue(_ id: String, edit: PhotoEdit, baseline: PhotoEdit) -> Double {
        switch id {
        case "camera_exposure":
            return edit.camera.exposureCompensationEV - baseline.camera.exposureCompensationEV
        case "print_brightness":
            let b = baseline.enlarger.printExposure
            guard b > 0, edit.enlarger.printExposure > 0 else { return 0 }
            return -log2(edit.enlarger.printExposure / b)
        case "tonal_contrast":
            let b = baseline.printRender.densityCurvesMorph.gammaFactor
            guard b > 0 else { return 0 }
            return (edit.printRender.densityCurvesMorph.gammaFactor / b - 1) / 0.35 * 100
        case "color_density":
            let b = baseline.filmRender.dirCouplers.inhibitionInterlayer
            guard b > 0 else { return 0 }
            return (edit.filmRender.dirCouplers.inhibitionInterlayer / b - 1) / 0.5 * 100
        case "grain_amount":
            let b = baseline.filmRender.grain.densityMin[0]
            guard b > 0 else { return 0 }
            return (edit.filmRender.grain.densityMin[0] / b - 1) / 0.9 * 100
        case "grain_size":
            let b = baseline.filmRender.grain.particleAreaUM2
            guard b > 0 else { return 0 }
            return log2(edit.filmRender.grain.particleAreaUM2 / b) / 0.9 * 100
        case "halation_amount":
            let b = baseline.filmRender.halation.halationAmount
            guard b > 0 else { return 0 }
            return (edit.filmRender.halation.halationAmount / b - 1) / 1.2 * 100
        case "halation_scale":
            let b = baseline.filmRender.halation.halationSpatialScale
            guard b > 0 else { return 0 }
            return log2(edit.filmRender.halation.halationSpatialScale / b) / 0.6 * 100
        case "diffusion":
            let editFilter = edit.camera.diffusionFilter
            let base = baseline.camera.diffusionFilter
            if !editFilter.active {
                return base.active || editFilter.strength != base.strength ? -100 : 0
            }
            if abs(editFilter.strength - base.strength) > 1e-9 {
                if editFilter.strength > base.strength {
                    return (editFilter.strength - base.strength)
                        / max(2 - base.strength, 1e-6) * 100
                }
                return (editFilter.strength / max(base.strength, 1e-6) - 1) * 100
            }
            return 0
        case "scanner_clarity":
            let bAmount = baseline.scanner.unsharpMask[1]
            let amount = edit.scanner.unsharpMask[1]
            if abs(amount - bAmount) > 1e-9 {
                return (amount - bAmount) / max(1.8 - bAmount, 1e-6) * 100
            }
            let blurDelta = edit.scanner.lensBlur - baseline.scanner.lensBlur
            guard abs(blurDelta) > 1e-9 else { return 0 }
            return -blurDelta / 0.6 * 100
        default:
            return 0
        }
    }

    func quickGroups(edit: PhotoEdit, baseline: PhotoEdit) -> [QuickGroup] {
        let printOnly: Set<String> = ["print_brightness", "tonal_contrast"]
        let disabledReason = edit.io.scanFilm
            ? "正片扫描模式：管线跳过印相阶段，本项不参与成像"
            : nil
        return PreviewData.quickGroups.map { group in
            let axes = group.axes.map { axis in
                QuickAxis(
                    id: axis.id, label: axis.label, range: axis.range,
                    step: axis.step, decimals: axis.decimals, suffix: axis.suffix,
                    baseValue: 0,
                    value: quickValue(axis.id, edit: edit, baseline: baseline),
                    unavailableReason: printOnly.contains(axis.id) ? disabledReason : nil
                )
            }
            let pad = group.pad.map { template in
                QuickPad(
                    title: template.title,
                    x: (edit.enlarger.yFilterShift - baseline.enlarger.yFilterShift) / 40 * 100,
                    y: (edit.enlarger.mFilterShift - baseline.enlarger.mFilterShift) / 40 * 100
                )
            }
            return QuickGroup(id: group.id, title: group.title, axes: axes, pad: pad)
        }
    }

    func proValue(_ id: String, edit: PhotoEdit) -> Double? {
        let morph = edit.printRender.densityCurvesMorph
        switch id {
        case "print_exposure": return edit.enlarger.printExposure
        case "exposure_compensation_ev": return edit.camera.exposureCompensationEV
        case "film_gamma_factor": return morph.gammaFactor
        case "developer_exhaustion": return morph.developerExhaustion
        case "gamma_factor": return morph.gammaFactor
        case "gamma_factor_fast": return morph.gammaFactorFast
        case "gamma_factor_slow": return morph.gammaFactorSlow
        case "gamma_factor_red": return morph.gammaFactorRed
        case "gamma_factor_green": return morph.gammaFactorGreen
        case "gamma_factor_blue": return morph.gammaFactorBlue
        case "white_level": return edit.scanner.whiteLevel
        case "black_level": return edit.scanner.blackLevel
        case "glare_percent": return edit.printRender.glare.percent
        case "glare_roughness": return edit.printRender.glare.roughness
        case "preflash_exposure": return edit.enlarger.preflashExposure
        case "preflash_y": return edit.enlarger.preflashYFilterShift
        case "preflash_m": return edit.enlarger.preflashMFilterShift
        case "print_y_filter_shift": return edit.enlarger.yFilterShift
        case "print_m_filter_shift": return edit.enlarger.mFilterShift
        case "inhibition_interlayer": return edit.filmRender.dirCouplers.inhibitionInterlayer
        case "inhibition_samelayer": return edit.filmRender.dirCouplers.inhibitionSameLayer
        case "coupler_amount": return edit.filmRender.dirCouplers.amount
        case "diffusion_size_um": return edit.filmRender.dirCouplers.diffusionSizeUM
        case "particle_area_um2": return edit.filmRender.grain.particleAreaUM2
        case "grain_blur": return edit.filmRender.grain.blur
        case "blur_dye_clouds_um": return edit.filmRender.grain.blurDyeCloudsUM
        case "halation_amount": return edit.filmRender.halation.halationAmount
        case "scatter_amount": return edit.filmRender.halation.scatterAmount
        case "halation_spatial_scale": return edit.filmRender.halation.halationSpatialScale
        case "boost_ev": return edit.filmRender.halation.boostEV
        case "protect_ev": return edit.filmRender.halation.protectEV
        case "lens_blur": return edit.scanner.lensBlur
        case "lens_blur_um": return edit.camera.lensBlurUM
        case "diffusion_strength": return edit.camera.diffusionFilter.strength
        case "film_format_mm": return edit.camera.filmFormatMM
        case "upscale_factor": return edit.io.upscaleFactor
        default: return nil
        }
    }

    func proToggle(_ id: String, edit: PhotoEdit) -> Bool? {
        switch id {
        case "print_exposure_compensation": return edit.enlarger.printExposureCompensation
        case "auto_exposure": return edit.camera.autoExposure
        case "white_correction": return edit.scanner.whiteCorrection
        case "black_correction": return edit.scanner.blackCorrection
        case "glare_active": return edit.printRender.glare.active
        case "couplers_active": return edit.filmRender.dirCouplers.active
        case "grain_active": return edit.filmRender.grain.active
        case "halation_active": return edit.filmRender.halation.active
        case "chemistry_active": return edit.printRender.densityCurvesMorph.active
        case "camera_diffusion_active": return edit.camera.diffusionFilter.active
        case "input_cctf_decoding": return edit.io.inputCCTFDecoding
        case "input_crop": return edit.io.crop
        case "saving_cctf": return edit.io.outputCCTFEncoding
        default: return nil
        }
    }

    func proPages(edit: PhotoEdit, film: String, paper: String) -> [ParamPage] {
        PreviewData.proPages(film: film, paper: paper).map { page in
            ParamPage(id: page.id, title: page.title, groups: page.groups.map { group in
                ParamGroup(id: group.id, title: group.title, rows: group.rows.map { row in
                    switch row.control {
                    case .slider(let template, _, _):
                        guard let value = proValue(row.id, edit: edit) else { return row }
                        return ParamRow(
                            id: row.id, label: row.label,
                            control: .slider(value: value, valueText: format(value),
                                             dirty: abs(value - template) > 1e-9),
                            isEnabled: row.isEnabled
                        )
                    case .toggle(let template):
                        guard let value = proToggle(row.id, edit: edit) else { return row }
                        return ParamRow(
                            id: row.id, label: row.label,
                            control: .toggle(isOn: value),
                            isEnabled: row.isEnabled || template
                        )
                    case .choice:
                        return row
                    }
                })
            })
        }
    }

    private func format(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        if text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
