import Foundation
import SwiftUI
import os
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 单张照片的显影会话：真实 RAW 解码 → 物理显影 → 双层预览（LUT 预测 + 精算）+ 参数映射 + 撤销。
/// 只写 `PhotoEdit` 的既有字段，不改任何算法。
@MainActor
final class MobileDevelopSession: ObservableObject {
    // MARK: - 对外状态

    @Published private(set) var previewImage: MPlatformImage?
    @Published private(set) var originalImage: MPlatformImage?
    @Published private(set) var isPredicted = false
    @Published private(set) var isRendering = false
    @Published private(set) var phaseLabel = ""
    @Published private(set) var phaseProgress: Double = 0
    /// 导出有独立的进度文案：预览渲染和导出共用一套 phaseLabel 会互相覆盖，
    /// 导出面板上就会显示「胶片显影」这种预览阶段的字。
    @Published private(set) var exportLabel = ""
    @Published private(set) var errorMessage: String?
    /// 原片读取失败的用户可读原因。非 nil 且 isLoaded == false 时，界面应展示失败态与重试入口，
    /// 而不是继续显示「正在读取原片…」。
    @Published private(set) var loadFailure: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var isExporting = false
    @Published private(set) var previewAspect: CGFloat = 4.0 / 3.0
    /// 预览渲染比例（相对原图长边）：1/8、1/4、1/2、1/1。
    @Published private(set) var previewScale: Double

    @Published private(set) var quickValues: [String: Double] = [:]
    @Published private(set) var padX: Double = 0
    @Published private(set) var padY: Double = 0
    @Published private(set) var proValues: [String: Double] = [:]
    @Published private(set) var proToggles: [String: Bool] = [:]
    @Published private(set) var proChoices: [String: String] = [:]
    @Published private(set) var filmID: String
    @Published private(set) var paperID: String
    @Published private(set) var canUndo = false
    /// 黑白模式：显影结果之后的亮度归一，只属于显影预设，不写入核心参数。
    @Published private(set) var isMonochrome = false

    // MARK: - 标识

    let photoID: String
    let filename: String
    /// 输入是否为 RAW：JPEG/HEIC/PNG 没有可调的 RAW 解码参数（白平衡/镜头校正）。
    let isRawInput: Bool
    private let store: LibraryStore
    /// 原图路径：导出与交接按需重新解码，预览不常驻全分辨率。
    private var originalURL: URL = URL(fileURLWithPath: "/dev/null")
    /// 参数落盘后通知照片库刷新列表。
    var onPersist: ((LibraryPhoto) -> Void)?

    // MARK: - 内部状态

    private let renderer = PreviewRenderer()
    private let handoffRenderer = PreviewRenderer()
    private let lutService = PreviewLUTService()
    private let loadQueue = DispatchQueue(label: "spektra.mobile.develop.load", qos: .userInitiated)
    private let lutQueue = DispatchQueue(label: "spektra.mobile.develop.lut", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "spektra.mobile.develop.export", qos: .userInitiated)

    private var edit: PhotoEdit
    private var baseline: PhotoEdit
    private var quickIntents: [String: Double]
    private var image: ImageRGB?
    private var inputColorSpace = "ProPhoto RGB"
    private var inputCCTF = false

    private var undoStack: [PhotoEdit] = []
    private var lastUndoKey = ""
    private var lastUndoTime = Date.distantPast

    private var loadToken = 0
    private var fastToken = 0
    private var renderToken = 0
    private var accurateDoneFastToken = -1
    private var renderInFlight = false
    private var fastInFlight = false
    private var fastDirty = false
    private var pendingSettle: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private var pendingHandoffs: [(Int, (ImageRGB?) -> Void)] = []
    /// 白平衡/镜头校正变化后重新解码原图的防抖任务；拖动过程中合并成一次。
    private var pendingRawReload: DispatchWorkItem?
    /// 原片解码看门狗：CIRAWFilter 在部分 RAW 上可能长时间不返回，超时后让界面进入失败态，
    /// 用户仍可重试；迟到的解码结果会因 loadToken 不变而正常收尾。
    private var loadTimeoutWork: DispatchWorkItem?
    private static let loadTimeout: TimeInterval = 25

    /// 原图长边（导入时写入库里的真实像素尺寸）。预览比例与导出「原始」都基于它，
    /// 不能用预览缓冲的 1600 长边，否则 12 MP 原图会被当成 1600 长边导出。
    private var originalLongEdge: Int
    /// 当前解码进内存的预览图长边；调大渲染比例时需要按需重解码原图。
    private var loadedEdge = 0
    private static let previewScaleKey = "mobile.develop.previewScale"
    /// 精算帧长边 = 原图长边 × 预览比例；上限由当前解码缓冲决定。
    private var previewEdge: Int {
        let base = originalLongEdge > 0 ? originalLongEdge : loadedEdge
        guard base > 0 else { return 1280 }
        let scaled = Int((Double(base) * previewScale).rounded())
        // 1/4 档按 12 MP 原图算只有 1008 长边，铺到 3x 屏会被放大 1.3 倍读成锯齿；
        // 因此 1/4 及以上至少给到屏幕宽 1280，1/8 仍保留给极速预览。
        let floorEdge = previewScale >= 0.25 ? 1280 : 160
        return min(base, max(scaled, floorEdge))
    }
    /// 拖动期的预测帧：长边按屏幕密度给到 1280，低于这个值在 3x 屏上放大后会读成锯齿。
    private var fastPreviewEdge: Int {
        min(previewEdge, 1280)
    }
    /// 交互预测用的查找表：65³ 与桌面门禁同档，33³ 在暗部渐变上会出现肉眼可见的色阶断层。
    private let fastResolution = 65
    /// 停手后多久回落精算帧。精算已从 1.69 s 降到 0.91 s（1280 预览），
    /// 防抖可以从 0.5 s 收紧到 0.32 s，停手到清晰画面的总延迟从 ~2.2 s 降到 ~1.2 s。
    private let settleDelay: TimeInterval = 0.32

    init(photo: LibraryPhoto, store: LibraryStore) {
        self.photoID = photo.id
        self.filename = photo.filename
        self.isRawInput = ImageLoader.rawSuffixes.contains(
            (photo.filename as NSString).pathExtension.lowercased()
        )
        self.store = store
        // 旧版本的库记录可能把 ARW 的内嵌预览尺寸当成原图尺寸（如 1616×1080）。
        // 这里直接读 RAW 头，取库记录与真实尺寸的较大值，已有照片也能恢复全分辨率导出。
        let storedEdge = max(photo.width, photo.height)
        let probed = LibraryStore.pixelSize(url: store.originalURL(for: photo))
        self.originalLongEdge = max(storedEdge, max(probed.width, probed.height))
        let saved = UserDefaults.standard.double(forKey: Self.previewScaleKey)
        self.previewScale = saved >= 0.125 && saved <= 1.0 ? saved : 0.25
        self.edit = photo.edit
        if let data = photo.quickBaselineData,
           let decoded = try? JSONDecoder().decode(PhotoEdit.self, from: data) {
            self.baseline = decoded
        } else {
            self.baseline = photo.edit
        }
        self.quickIntents = photo.edit.quickIntents
        self.filmID = photo.edit.filmStock
        self.paperID = photo.edit.printStock
        publishFromEdit()
    }

    // MARK: - 启动

    func start() {
        load()
    }

    func cancel() {
        loadToken += 1
        fastToken += 1
        renderToken += 1
        pendingSettle?.cancel()
        pendingRawReload?.cancel()
        pendingRawReload = nil
        loadTimeoutWork?.cancel()
        loadTimeoutWork = nil
        persistWork?.cancel()
        fastDirty = false
        renderer.invalidate()
        handoffRenderer.invalidate()
    }

    /// 离开页面时把参数写盘。
    func finish() {
        persistWork?.cancel()
        persistNow()
    }

    /// 导出面板显示用：原图真实长边，避免用户再猜「原始」到底多大。
    var exportOriginalEdge: Int {
        originalLongEdge > 0 ? originalLongEdge : loadedEdge
    }

    private func load() {
        // 初始化按预览比例决定解码尺寸：1/4 只需 1600 内的缓冲，1/2、1/1 直接解码到原图。
        loadOriginal(maxSize: max(1600, previewEdge))
    }

    /// 按指定长边重新解码原图并刷新预览缓冲。调大渲染比例时复用同一入口。
    private func loadOriginal(maxSize: Int) {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else {
            isRendering = false
            phaseLabel = ""
            errorMessage = "照片不在库中"
            loadFailure = "照片不在库中，请回到首页重新导入。"
            return
        }
        let originalURL = store.originalURL(for: photo)
        self.originalURL = originalURL
        loadFailure = nil
        errorMessage = nil
        loadToken += 1
        let token = loadToken
        // 比例切换时丢弃仍在途的旧尺寸精算帧，避免旧图覆盖新解码缓冲。
        renderToken += 1
        renderer.invalidate()
        isRendering = true
        phaseLabel = isRawInput ? "读取 RAW" : "读取照片"
        phaseProgress = 0
        // 解码参数在主线程取好，后台队列只做像素工作。
        let options = rawOptions()
        let rotation = edit.rotationTurns
        armLoadTimeout(token: token)
        loadQueue.async { [weak self] in
            do {
                let loaded = try ImageLoader.load(
                    url: originalURL, maxSize: maxSize, rawOptions: options,
                    rotationTurns: rotation, allowEncoded: true)
                let preview = Resize.longEdge(loaded.image, maxSize: maxSize)
                let display = Self.displayImage(preview, colorSpace: loaded.colorSpace,
                                                cctfDecoding: loaded.cctfDecoding)
                let original = PreviewRenderer.cgImage(from: display)
                Task { @MainActor [weak self] in
                    guard let self, self.loadToken == token else { return }
                    self.loadTimeoutWork?.cancel()
                    self.loadTimeoutWork = nil
                    self.loadFailure = nil
                    self.errorMessage = nil
                    self.image = loaded.image
                    self.loadedEdge = max(loaded.image.width, loaded.image.height)
                    // 库里的宽高缺失时才退回解码缓冲的长边（此时至少能保证导出不被预览尺寸误缩）。
                    if self.originalLongEdge <= 0 { self.originalLongEdge = self.loadedEdge }
                    self.inputColorSpace = loaded.colorSpace
                    self.inputCCTF = loaded.cctfDecoding
                    self.isLoaded = true
                    self.previewAspect = CGFloat(loaded.image.width) / CGFloat(max(1, loaded.image.height))
                    if let original {
                        self.originalImage = MImage.make(cgImage: original)
                    }
                    self.isRendering = false
                    self.phaseLabel = ""
                    self.prewarmLUT()
                    self.schedulePreview(immediate: true)
                    self.flushHandoffs()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.loadToken == token else { return }
                    self.loadTimeoutWork?.cancel()
                    self.loadTimeoutWork = nil
                    self.isRendering = false
                    self.phaseLabel = ""
                    self.errorMessage = String(describing: error)
                    self.loadFailure = Self.loadFailureText(for: error)
                    self.flushHandoffs()
                }
            }
        }
    }

    /// 读取失败后的手动重试。保留当前预览比例；旧的在途解码会因 loadToken 变化被丢弃。
    func retryLoad() {
        guard !isLoaded else { return }
        loadOriginal(maxSize: max(1600, previewEdge))
    }

    /// 启动解码看门狗。CIRAWFilter 对个别 RAW 可能长时间不返回，
    /// 超时后先让界面进入可重试的失败态，而不是永远停在「正在读取原片…」。
    private func armLoadTimeout(token: Int) {
        loadTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.loadToken == token, !self.isLoaded else { return }
            self.isRendering = false
            self.phaseLabel = ""
            self.errorMessage = "读取超时"
            self.loadFailure = "读取原片超时，可能是当前系统不支持该 RAW 格式。"
            self.flushHandoffs()
        }
        loadTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: work)
    }

    private static func loadFailureText(for error: Error) -> String {
        "无法解码这张原片，可能是当前系统不支持该 RAW 格式。"
    }

    // MARK: - 渲染比例

    /// 预览渲染比例：1/8、1/4、1/2、1/1（相对原图长边）。与 Swift 主线的 previewScale 一致；
    /// 调大时按需重解码原图，调小时直接复用现有缓冲。
    func setPreviewScale(_ scale: Double) {
        let value = min(max(scale, 0.125), 1.0)
        guard abs(value - previewScale) > 1e-9 else { return }
        previewScale = value
        UserDefaults.standard.set(value, forKey: Self.previewScaleKey)
        let needed = previewEdge
        if needed > loadedEdge {
            loadOriginal(maxSize: needed)
        } else {
            schedulePreview(immediate: true)
        }
    }

    /// 顺时针旋转 90°：纯几何变换，直接转动已解码缓冲与预览图，不重跑显影。
    func rotateClockwise() {
        guard isLoaded, let image else { return }
        pushUndo(key: "rotate")
        edit.rotationTurns = (edit.rotationTurns + 1) % 4
        self.image = image.rotatedClockwise(1)
        // 丢弃在途的旧方向渲染结果，避免稍后回写成未旋转画面。
        fastToken += 1
        renderToken += 1
        renderer.invalidate()
        isRendering = false
        phaseLabel = ""
        phaseProgress = 0
        if let previewImage, let rotated = previewImage.quarterTurnedClockwise {
            self.previewImage = rotated
            previewAspect = rotated.size.width / max(1, rotated.size.height)
        }
        if let originalImage, let rotated = originalImage.quarterTurnedClockwise {
            self.originalImage = rotated
        }
        persistSoon()
    }

    // MARK: - RAW 解码参数

    /// 当前编辑里的 RAW 解码选项。白平衡/镜头校正只在解码阶段生效，
    /// 改动后必须重新解码原图，而不是只重渲染。
    private func rawOptions() -> RawDecoder.Options {
        edit.rawDecoderOptions()
    }

    /// 重解码防抖：与停手精算同一档，拖动白平衡时不会每格都解一次 RAW。
    private func scheduleRawReload() {
        pendingRawReload?.cancel()
        guard image != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRawReload = nil
            self.loadOriginal(maxSize: max(1600, self.previewEdge))
        }
        pendingRawReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    /// 选片时的正片扫描规则：参考 digest_after_selection 直接把 scan_film 设成 is_positive。
    private static func scanFilmForSelection(_ stock: String) -> Bool? {
        (try? ProfileStore.load(stock))?.info.isPositive
    }

    /// 只对正片强制开启；负片保留用户手动「查看底片」的选择。
    private static func enforcePositiveScanMode(on edit: inout PhotoEdit) {
        guard let profile = try? ProfileStore.load(edit.filmStock), profile.info.isPositive else { return }
        edit.io.scanFilm = true
    }

    // MARK: - 参数映射

    func applyQuick(_ id: String, _ q: Double) {
        guard MobileCatalog.quickGroups.flatMap(\.axes).contains(where: { $0.id == id }) else { return }
        if id == "temperature" {
            // 滑条正值 = 更暖；色盘的 x 正值 = 更冷（右「冷」），两者互为相反数。
            applyPad(x: -q, y: padY)
            return
        }
        pushUndo(key: id)
        quickIntents[id] = q
        edit.quickIntents = quickIntents
        applyQuickMapping(id: id, q: q)
        quickValues[id] = q
        persistSoon()
        schedulePreview()
    }

    func applyPad(x: Double, y: Double) {
        pushUndo(key: "pad")
        padX = min(max(x, -100), 100)
        padY = min(max(y, -100), 100)
        quickValues["temperature"] = -padX
        quickIntents["temperature"] = -padX
        // 色盘满量程 = 60 CC（原生 PAD_CC_FULL_SCALE）。
        // 纵向：上 = +M（负片印相偏绿）、下 = -M（偏品红），与盘面标注一致。
        edit.enlarger.yFilterShift = clamp(
            baseline.enlarger.yFilterShift + 60 * padX / 100, -60, 60)
        edit.enlarger.mFilterShift = clamp(
            baseline.enlarger.mFilterShift + 60 * padY / 100, -60, 60)
        edit.quickIntents = quickIntents
        persistSoon()
        schedulePreview()
    }

    /// 这些滑块参与 RAW 解码，改变后要重新解码原图，而不是只重渲染。
    private static let rawDecodeSliders: Set<String> = [
        "white_balance_temperature", "white_balance_tint",
    ]

    func applyPro(_ id: String, _ value: Double) {
        pushUndo(key: "pro." + id)
        writePro(id, value)
        edit.quickIntents = quickIntents
        proValues[id] = value
        persistSoon()
        if Self.rawDecodeSliders.contains(id) {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    func applyProToggle(_ id: String, _ value: Bool) {
        pushUndo(key: "toggle." + id)
        var reloadsRaw = false
        switch id {
        case "auto_exposure": edit.camera.autoExposure = value
        case "print_exposure_compensation": edit.enlarger.printExposureCompensation = value
        case "normalize_print_exposure": edit.enlarger.normalizePrintExposure = value
        case "couplers_active": edit.filmRender.dirCouplers.active = value
        case "camera_diffusion_active": edit.camera.diffusionFilter.active = value
        case "enlarger_diffusion_active": edit.enlarger.diffusionFilter.active = value
        case "print_glare_active": edit.printRender.glare.active = value
        case "grain_active": edit.filmRender.grain.active = value
        case "grain_sublayers_active": edit.filmRender.grain.sublayersActive = value
        case "halation_active": edit.filmRender.halation.active = value
        case "halation_renormalize": edit.filmRender.halation.halationRenormalize = value
        case "film_glare_active": edit.filmRender.glare.active = value
        case "white_correction": edit.scanner.whiteCorrection = value
        case "black_correction": edit.scanner.blackCorrection = value
        case "scan_film": edit.io.scanFilm = value
        case "lens_correction":
            edit.loadRaw.lensCorrection = value
            reloadsRaw = true
        case "crop": edit.io.crop = value
        case "input_gamut_compress": edit.io.inputGamutCompressActive = value
        default: break
        }
        proToggles[id] = value
        persistSoon()
        if reloadsRaw {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    /// 专业页下拉项（测光方式、印相光源、柔光类型、白平衡、输出色域压缩）。
    func applyProChoice(_ id: String, _ value: String) {
        pushUndo(key: "choice." + id)
        var reloadsRaw = false
        switch id {
        case "auto_exposure_method": edit.camera.autoExposureMethod = value
        case "print_illuminant": edit.enlarger.illuminant = value
        case "camera_diffusion_family": edit.camera.diffusionFilter.filterFamily = value
        case "white_balance":
            edit.loadRaw.whiteBalance = value
            reloadsRaw = true
        case "output_gamut_compress": edit.io.outputGamutCompressAlgorithm = value
        default: return
        }
        proChoices[id] = value
        persistSoon()
        if reloadsRaw {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    func setFilm(_ id: String) {
        guard id != edit.filmStock else { return }
        pushUndo(key: "film")
        // 以当前编辑为底：换胶片只换 stock 与胶片派生项，专业页的颗粒/光晕/扫描等改动必须保留。
        var next = edit
        next.filmStock = id
        // 正片必须走「扫描胶片」链路；参考 digest_after_selection 在选片时按 is_positive 设定。
        if let scanFilm = Self.scanFilmForSelection(id) {
            next.io.scanFilm = scanFilm
        }
        next.quickIntents = quickIntents
        for (control, q) in quickIntents where abs(q) > 1e-9 {
            applyQuickMapping(id: control, q: q, edit: &next)
        }
        // 色盘纵向（品红/绿）没有对应的 quickIntents 字段，换胶片时必须从当前色盘位置恢复。
        next.enlarger.yFilterShift = clamp(
            baseline.enlarger.yFilterShift + 60 * padX / 100, -60, 60)
        next.enlarger.mFilterShift = clamp(
            baseline.enlarger.mFilterShift + 60 * padY / 100, -60, 60)
        edit = next
        filmID = id
        publishFromEdit()
        persistNow()
        schedulePreview()
    }

    func setPaper(_ id: String) {
        guard id != edit.printStock else { return }
        pushUndo(key: "paper")
        edit.printStock = id
        paperID = id
        persistNow()
        schedulePreview()
    }

    /// 黑白模式只影响最终显示/导出，不改核心显影参数。
    func setMonochrome(_ value: Bool) {
        guard value != edit.monochrome else { return }
        pushUndo(key: "monochrome")
        edit.monochrome = value
        edit.quickIntents = quickIntents
        isMonochrome = value
        persistSoon()
        schedulePreview()
    }

    /// 当前参数是否与某个显影预设完全一致。
    func matches(_ preset: MDevelopPreset) -> Bool {
        guard filmID == preset.filmID,
              paperID == preset.paperID,
              edit.monochrome == preset.monochrome,
              abs(padY) <= 0.5 else { return false }
        let axes = MobileCatalog.quickGroups.flatMap(\.axes)
        for axis in axes {
            let expected = preset.quick[axis.id] ?? axis.base
            let actual = quickIntents[axis.id] ?? axis.base
            if abs(expected - actual) > 1e-9 { return false }
        }
        return true
    }

    /// 套用显影预设：只写胶片、相纸、快速显影轴与黑白模式，
    /// 先把快速派生字段回滚到基线再按预设重算，避免参数叠加漂移。
    func applyDevelopPreset(_ preset: MDevelopPreset) {
        pushUndo(key: "develop.preset")
        var next = edit
        next.filmStock = preset.filmID
        next.printStock = preset.paperID
        next.monochrome = preset.monochrome
        if let scanFilm = Self.scanFilmForSelection(preset.filmID) {
            next.io.scanFilm = scanFilm
        }

        quickIntents = preset.quick
        next.quickIntents = quickIntents
        next.camera.exposureCompensationEV = baseline.camera.exposureCompensationEV
        next.enlarger.printExposure = baseline.enlarger.printExposure
        next.enlarger.printExposureCompensation = baseline.enlarger.printExposureCompensation
        next.enlarger.yFilterShift = baseline.enlarger.yFilterShift
        next.enlarger.mFilterShift = baseline.enlarger.mFilterShift
        next.printRender.densityCurvesMorph = baseline.printRender.densityCurvesMorph
        next.filmRender.dirCouplers = baseline.filmRender.dirCouplers
        next.filmRender.grain = baseline.filmRender.grain
        next.scanner = baseline.scanner
        for (control, q) in quickIntents where abs(q) > 1e-9 {
            applyQuickMapping(id: control, q: q, edit: &next)
        }

        edit = next
        filmID = preset.filmID
        paperID = preset.paperID
        isMonochrome = preset.monochrome
        publishFromEdit()
        persistNow()
        schedulePreview()
    }

    func resetQuick() {
        pushUndo(key: "reset.quick")
        quickIntents = [:]
        edit.quickIntents = [:]
        edit.camera.exposureCompensationEV = baseline.camera.exposureCompensationEV
        edit.enlarger.printExposure = baseline.enlarger.printExposure
        edit.enlarger.printExposureCompensation = baseline.enlarger.printExposureCompensation
        edit.enlarger.yFilterShift = baseline.enlarger.yFilterShift
        edit.enlarger.mFilterShift = baseline.enlarger.mFilterShift
        edit.printRender.densityCurvesMorph = baseline.printRender.densityCurvesMorph
        edit.filmRender.dirCouplers = baseline.filmRender.dirCouplers
        edit.filmRender.grain = baseline.filmRender.grain
        edit.scanner = baseline.scanner
        publishFromEdit()
        persistNow()
        schedulePreview()
    }

    func resetPro() {
        pushUndo(key: "reset.pro")
        let previousLoadRaw = edit.loadRaw
        edit = baseline
        edit.filmStock = filmID
        edit.printStock = paperID
        // 基线可能是在旧版本/旧会话里捕获的：正片仍必须走扫描胶片。
        Self.enforcePositiveScanMode(on: &edit)
        quickIntents = [:]
        edit.quickIntents = [:]
        publishFromEdit()
        persistNow()
        if edit.loadRaw != previousLoadRaw {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let previousLoadRaw = edit.loadRaw
        edit = previous
        quickIntents = previous.quickIntents
        canUndo = !undoStack.isEmpty
        lastUndoKey = ""
        publishFromEdit()
        persistNow()
        if edit.loadRaw != previousLoadRaw {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    // MARK: - 导出

    /// 导出请求：`format` 0 sRGB TIFF16、1 ProPhoto 线性 TIFF16、2 ACES 线性 EXR、3 JPEG。
    /// `jpegQuality` 仅在 JPEG 档生效，取值 0…1；`includeWatermark` 是导出面板的单次水印开关。
    func export(format: Int, longEdgeIndex: Int, jpegQuality: Double = 0.95,
                includeWatermark: Bool = true,
                completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isExporting, let image else {
            completion(.failure(MobileExportError.busy))
            return
        }
        // “原始”必须用库里记录的原图像素尺寸，而不是预览缓冲的 1600 长边。
        // 但原始档同样可能超过前台内存预算（48 MP ProRAW 峰值可达数 GB），
        // 因此所有档位都按可用内存钳位，实际尺寸通过 exportLabel 明确告诉用户。
        let originalEdge = originalLongEdge > 0 ? originalLongEdge : max(image.width, image.height)
        let requested = ExportEdge.resolve(index: longEdgeIndex, originalLongEdge: originalEdge)
        let rawEdge = ExportEdge.requested(index: longEdgeIndex, originalLongEdge: originalEdge)
        let clampedNote = requested < rawEdge ? "导出 · 内存上限 \(requested)" : "导出"
        var params: RuntimePhotoParams
        do {
            params = try edit.runtimeParams()
        } catch {
            completion(.failure(error))
            return
        }
        params.io.inputColorSpace = inputColorSpace
        params.io.inputCCTFDecoding = inputCCTF
        let ext: String
        let bitDepth: Int
        switch format {
        case 1:
            params.io.outputColorSpace = "ProPhoto RGB"
            params.io.outputCCTFEncoding = false
            ext = "tif"; bitDepth = 16
        case 2:
            params.io.outputColorSpace = "ACES2065-1"
            params.io.outputCCTFEncoding = false
            ext = "exr"; bitDepth = 16
        case 3:
            params.io.outputColorSpace = "sRGB"
            params.io.outputCCTFEncoding = true
            ext = "jpg"; bitDepth = 8
        default:
            params.io.outputColorSpace = "sRGB"
            params.io.outputCCTFEncoding = true
            ext = "tif"; bitDepth = 16
        }
        let colorSpace = params.io.outputColorSpace
        let cctf = params.io.outputCCTFEncoding
        let destination = Self.exportURL(filename: filename, ext: ext)
        let sourceURL = originalURL
        let options = rawOptions()
        let rotation = edit.rotationTurns
        // 水印只在最终导出合成，不进入预览链路；导出面板的勾选可单次关闭。
        let watermarkEnabled = includeWatermark
        let watermark = MWatermarkStore.load()
        let monochrome = edit.monochrome
        isExporting = true
        exportLabel = clampedNote
        exportQueue.async { [weak self] in
            // 导出按目标长边重新解码原图：预览缓存是缩小版，不能拿它放大。
            guard let loaded = try? ImageLoader.load(
                url: sourceURL, maxSize: requested, rawOptions: options,
                rotationTurns: rotation, allowEncoded: true) else {
                Task { @MainActor [weak self] in
                    self?.isExporting = false
                    self?.exportLabel = ""
                    completion(.failure(MobileExportError.decodeFailed))
                }
                return
            }
            var exportParams = params
            exportParams.io.inputColorSpace = loaded.colorSpace
            exportParams.io.inputCCTFDecoding = loaded.cctfDecoding
            let pipeline = SimulationPipeline(params: exportParams, keepTaps: false)
            let prepared = PreviewRenderer.prepared(loaded.image, maxSize: requested)
            let result = pipeline.process(prepared, progress: { label, _, _ in
                Task { @MainActor [weak self] in
                    self?.exportLabel = Self.stageLabel(label)
                }
            })
            var output = result.rgbOut
            if monochrome {
                output = Self.monochrome(output, colorSpace: colorSpace)
            }
            if watermarkEnabled {
                var config = watermark
                // 导出面板的勾选是这次导出的最终决定，覆盖设置里的启用位。
                config.enabled = true
                output = MWatermarkRenderer.composite(
                    image: output, config: config,
                    colorSpace: colorSpace, cctfEncoding: cctf
                )
            }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ImageExport.save(output, to: destination, bitDepth: bitDepth,
                                     colorSpace: colorSpace, cctfEncoding: cctf,
                                     jpegQuality: jpegQuality)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isExporting = false
                    self.exportLabel = ""
                    completion(.success(destination))
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isExporting = false
                    self.exportLabel = ""
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - 交接给调色台

    /// 显影 → 线性 ProPhoto 交接像素。调色台只接收这一份结果，不再接触 RAW。
    /// 若 RAW 还在解码，先挂起，解码完成或失败后再回调。
    func prepareHandoff(maxEdge: Int = 1600, completion: @escaping (ImageRGB?) -> Void) {
        if let image {
            renderHandoff(image, maxEdge: maxEdge, completion: completion)
            return
        }
        if errorMessage != nil {
            completion(nil)
            return
        }
        pendingHandoffs.append((maxEdge, completion))
    }

    private func renderHandoff(_ previewImage: ImageRGB, maxEdge: Int,
                               completion: @escaping (ImageRGB?) -> Void) {
        guard let baseParams = try? edit.runtimeParams() else {
            completion(nil)
            return
        }
        let renderer = handoffRenderer
        let url = originalURL
        let previewEdge = max(previewImage.width, previewImage.height)
        let previewSpace = inputColorSpace
        let previewCCTF = inputCCTF
        let options = rawOptions()
        let rotation = edit.rotationTurns
        let monochrome = edit.monochrome
        loadQueue.async {
            var params = baseParams
            var source = previewImage
            if maxEdge > previewEdge,
               let loaded = try? ImageLoader.load(url: url, maxSize: maxEdge, rawOptions: options,
                                                  rotationTurns: rotation, allowEncoded: true) {
                source = loaded.image
                params.io.inputColorSpace = loaded.colorSpace
                params.io.inputCCTFDecoding = loaded.cctfDecoding
            } else {
                params.io.inputColorSpace = previewSpace
                params.io.inputCCTFDecoding = previewCCTF
            }
            params.io.outputColorSpace = "ProPhoto RGB"
            params.io.outputCCTFEncoding = false
            renderer.render(params: params, image: source, maxSize: maxEdge) { outcome in
                let result = monochrome
                    ? Self.monochrome(outcome.image, colorSpace: "ProPhoto RGB")
                    : outcome.image
                completion(result)
            }
        }
    }

    /// 直接调色入口：只解码原片并转换到线性 ProPhoto，不跑胶片显影。
    /// 与 `prepareHandoff` 不同，这里不依赖显影预览，也不写回任何显影参数。
    func prepareOriginalHandoff(maxEdge: Int = 1600,
                                completion: @escaping (ImageRGB?) -> Void) {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else {
            completion(nil)
            return
        }
        let url = store.originalURL(for: photo)
        let options = rawOptions()
        let rotation = edit.rotationTurns
        loadQueue.async {
            guard var loaded = try? ImageLoader.load(
                url: url, maxSize: maxEdge, rawOptions: options,
                rotationTurns: rotation, allowEncoded: true) else {
                completion(nil)
                return
            }
            // 先取走像素再清空 loaded 的引用：mapInPlace 写回时才是独占缓冲，
            // 不会因为 COW 再分配第二份全尺寸图像（48 MP 下省掉约 0.6 GB）。
            var output = loaded.image
            loaded.image = ImageRGB(width: 0, height: 0)
            // RAW 解码结果已经是线性 ProPhoto；JPEG / HEIC 等编码图要按 ICC 与 CCTF 转过去。
            if loaded.colorSpace != "ProPhoto RGB" || loaded.cctfDecoding {
                let kind = ColorMath.cctfKind(for: loaded.colorSpace)
                let needsDecode = loaded.cctfDecoding
                let sourceSpace = loaded.colorSpace
                output.mapInPlace { rgb in
                    var linear = rgb
                    if needsDecode {
                        linear = Vec3(
                            ColorMath.cctfDecode(rgb.x, kind: kind),
                            ColorMath.cctfDecode(rgb.y, kind: kind),
                            ColorMath.cctfDecode(rgb.z, kind: kind)
                        )
                    }
                    return ColorMath.rgbToRGB(linear, from: sourceSpace, to: "ProPhoto RGB")
                }
            }
            completion(output)
        }
    }

    private func flushHandoffs() {
        guard let image else {
            let items = pendingHandoffs
            pendingHandoffs.removeAll()
            for (_, completion) in items { completion(nil) }
            return
        }
        let items = pendingHandoffs
        pendingHandoffs.removeAll()
        for (edge, completion) in items {
            renderHandoff(image, maxEdge: edge, completion: completion)
        }
    }

    // MARK: - 渲染

    /// 换片后在后台预烘预测表，首次拖滑杆不必等冷启动烘焙。
    private func prewarmLUT() {
        guard MobileSettings.predictivePreviewEnabled else { return }
        guard var params = try? edit.runtimeParams(), !params.io.scanFilm else { return }
        params.io.inputColorSpace = inputColorSpace
        params.io.inputCCTFDecoding = inputCCTF
        // 缓存键要编码整份 PhotoEdit，必须放到 lutQueue 计算，不能占主线程。
        let editSnapshot = edit
        let inputSpace = inputColorSpace
        let inputCCTF = inputCCTF
        let service = lutService
        let resolution = fastResolution
        lutQueue.asyncAfter(deadline: .now() + 0.3) {
            let key = PreviewLUTService.cacheKey(
                edit: editSnapshot, inputColorSpace: inputSpace, inputCCTF: inputCCTF)
            _ = service.bundle(for: params, key: key, resolution: resolution)
        }
    }

    private func schedulePreview(immediate: Bool = false) {
        guard image != nil else { return }
        pendingSettle?.cancel()
        fastToken += 1
        if renderInFlight {
            renderToken += 1
            renderer.invalidate()
            renderInFlight = false
        }
        if immediate {
            fastDirty = false
            renderAccurate()
            return
        }
        // 关闭「双层预览预测」后不再出 LUT 预测帧：拖动期间保持上一帧，
        // 停手后直接走真实物理精算。代价是拖动时没有即时反馈，换来决定性。
        if !MobileSettings.predictivePreviewEnabled {
            fastDirty = false
            isRendering = true
            phaseLabel = "显影中"
            phaseProgress = 0
            let settle = DispatchWorkItem { [weak self] in
                self?.pendingSettle = nil
                self?.renderAccurate()
            }
            pendingSettle = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: settle)
            return
        }
        isRendering = true
        phaseLabel = ""
        phaseProgress = 0
        requestFast()
        let settle = DispatchWorkItem { [weak self] in
            self?.pendingSettle = nil
            self?.renderAccurate()
        }
        pendingSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: settle)
    }

    /// 拖动期间按“在途 + 补跑”节流，不再用 150ms 防抖，否则连续拖动永远出不了预测帧。
    private func requestFast() {
        if fastInFlight {
            fastDirty = true
            return
        }
        startFast()
    }

    private func renderAccurate() {
        guard let image, var params = try? edit.runtimeParams() else { return }
        params.io.inputColorSpace = inputColorSpace
        params.io.inputCCTFDecoding = inputCCTF
        // 精算帧必须与导出走同一套物理参数：颗粒、眩光、清晰度都不为预览让步
        // （原生 `controller._configure_simulation_params` 同样强制 preview_mode = False）。
        // 任何近似层叠加都会让预览与导出的方向/质感对不上。
        renderToken += 1
        let token = renderToken
        renderInFlight = true
        isRendering = true
        phaseLabel = "显影中"
        phaseProgress = 0
        let monochrome = edit.monochrome
        let outputColorSpace = params.io.outputColorSpace
        renderer.render(
            params: params,
            image: image,
            maxSize: previewEdge,
            progress: { label, index, total in
                Task { @MainActor [weak self] in
                    guard let self, self.renderToken == token else { return }
                    self.phaseLabel = Self.stageLabel(label)
                    self.phaseProgress = total > 0 ? Double(index) / Double(total) : 0
                }
            }
        ) { [weak self] outcome in
            let rgb = monochrome
                ? Self.monochrome(outcome.image, colorSpace: outputColorSpace)
                : outcome.image
            let display = PreviewRenderer.cgImage(from: rgb)
            Task { @MainActor [weak self] in
                guard let self, self.renderToken == token else { return }
                if let display, !outcome.cancelled {
                    self.previewImage = MImage.make(cgImage: display)
                }
                self.isPredicted = false
                self.isRendering = false
                self.renderInFlight = false
                self.phaseLabel = ""
                self.phaseProgress = 0
                self.accurateDoneFastToken = self.fastToken
            }
        }
    }

    /// 拖动期近似层的输入：LUT 烘焙时这些连续轴被固定在中性值，
    /// 这里按「绝对量」补回当前强度（不是相对基线的比值，否则基线非中性时预测会偏）。
    private func previewAdjustments() -> PreviewAdjustments.Params {
        var p = PreviewAdjustments.Params()
        p.yShift = edit.enlarger.yFilterShift
        p.mShift = edit.enlarger.mFilterShift
        p.gamma = edit.printRender.densityCurvesMorph.active
            ? clamp(edit.printRender.densityCurvesMorph.gammaFactor, 0.5, 2.0)
            : 1
        p.saturation = edit.filmRender.dirCouplers.active
            ? clamp(edit.filmRender.dirCouplers.inhibitionInterlayer, 0.35, 1.8)
            : 1
        p.highlightSoften = edit.printRender.densityCurvesMorph.active
            ? clamp(edit.printRender.densityCurvesMorph.developerExhaustion / 0.6, 0, 1)
            : 0
        p.clarity = clamp((quickIntents["scanner_clarity"] ?? 0) / 100, -1, 1)
        return p
    }

    private func startFast() {
        guard MobileSettings.predictivePreviewEnabled else { return }
        guard let image, var params = try? edit.runtimeParams(), !params.io.scanFilm else { return }
        params.io.inputColorSpace = inputColorSpace
        params.io.inputCCTFDecoding = inputCCTF
        // 缓存键会编码整份 PhotoEdit；拖动时每秒可触发数十次，必须在 lutQueue 上算。
        let editSnapshot = edit
        let inputSpace = inputColorSpace
        let inputCCTF = inputCCTF
        let source = PreviewRenderer.prepared(image, maxSize: fastPreviewEdge)
        let service = lutService
        let token = fastToken
        let resolution = fastResolution
        // 交互近似参数在主线程取好，后台只做像素运算。
        let adjustments = previewAdjustments()
        let monochrome = edit.monochrome
        fastInFlight = true
        fastDirty = false
        lutQueue.async { [weak self] in
            let key = PreviewLUTService.cacheKey(
                edit: editSnapshot, inputColorSpace: inputSpace, inputCCTF: inputCCTF)
            guard let bundle = service.bundle(
                for: params, key: key, resolution: resolution
            ) else {
                Task { @MainActor [weak self] in
                    self?.finishFast(token: token, cgImage: nil)
                }
                return
            }
            var autoEV = 0.0
            if params.camera.autoExposure {
                autoEV = PreviewLUTService.measureAutoEV(
                    source: source, colorSpace: params.io.inputColorSpace,
                    applyCCTFDecoding: params.io.inputCCTFDecoding,
                    method: params.camera.autoExposureMethod)
            }
            let linear = bundle.predict(
                source: source, autoEV: autoEV,
                exposureEV: params.camera.exposureCompensationEV,
                printExposure: params.enlarger.printExposure,
                compensate: params.enlarger.printExposureCompensation)
            let adjusted = PreviewAdjustments.applyLinear(linear, params: adjustments)
            let encoded = PreviewLUTService.displayImage(fromLinear: adjusted)
            let display = PreviewAdjustments.applyDisplay(encoded, params: adjustments)
            let finalDisplay = monochrome
                ? Self.monochrome(display, colorSpace: "sRGB")
                : display
            let cgImage = PreviewRenderer.cgImage(from: finalDisplay)
            Task { @MainActor [weak self] in
                self?.finishFast(token: token, cgImage: cgImage)
            }
        }
    }

    private func finishFast(token: Int, cgImage: CGImage?) {
        fastInFlight = false
        if let cgImage, token > accurateDoneFastToken {
            previewImage = MImage.make(cgImage: cgImage)
            isPredicted = true
        }
        if fastDirty, !renderInFlight {
            startFast()
        }
    }

    // MARK: - 写入

    private func applyQuickMapping(id: String, q: Double) {
        applyQuickMapping(id: id, q: q, edit: &edit)
    }

    /// 「影调反差」与「高光柔和」共用 densityCurvesMorph.active：
    /// 任一快速轴非零时保持开启，全部归零才回落到基线状态。
    private func morphIsActive(baseline morph: PrintCurvesMorphParams) -> Bool {
        if abs(quickIntents["tonal_contrast"] ?? 0) > 1e-9 { return true }
        if abs(quickIntents["highlight_softening"] ?? 0) > 1e-9 { return true }
        return morph.active
    }

    private func applyQuickMapping(id: String, q: Double, edit: inout PhotoEdit) {
        switch id {
        case "camera_exposure":
            edit.camera.exposureCompensationEV = clamp(
                baseline.camera.exposureCompensationEV + q, -5, 5)
            // 原生 quick_controls：拖动拍摄曝光时先关掉印相自动亮度补偿，
            // 否则补偿会把曝光变化抵消掉（±1 EV 只差 0.01 L），回到 0 时恢复基线。
            edit.enlarger.printExposureCompensation =
                abs(q) <= 1e-9 ? baseline.enlarger.printExposureCompensation : false
        case "print_brightness":
            let b = baseline.enlarger.printExposure
            edit.enlarger.printExposure = clamp(b * pow(2, -q), 0.25, 4)
        case "tonal_contrast":
            let morph = baseline.printRender.densityCurvesMorph
            edit.printRender.densityCurvesMorph.gammaFactor = clamp(
                morph.gammaFactor * (1 + 0.35 * q / 100), 0.5, 2.0)
            edit.printRender.densityCurvesMorph.active = morphIsActive(baseline: morph)
        case "highlight_softening":
            // 直接复用专业模式「高光柔和」(developer_exhaustion)：
            // 拉伸密度曲线的 Gumbel 肩部，中高调被压暗、肩顶更长，高光层次更密而不死白。
            // 快速满量程只开到 0.6，保留专业页剩余的纵深。
            let morph = baseline.printRender.densityCurvesMorph
            let t = clamp(q / 100, 0, 1)
            edit.printRender.densityCurvesMorph.developerExhaustion = clamp(
                morph.developerExhaustion + 0.6 * t, 0, 1)
            edit.printRender.densityCurvesMorph.active = morphIsActive(baseline: morph)
        case "color_density":
            let b = baseline.filmRender.dirCouplers.inhibitionInterlayer
            edit.filmRender.dirCouplers.inhibitionInterlayer = clamp(
                b * (1 + 0.5 * q / 100), 0.0, 1.5)
            edit.filmRender.dirCouplers.active = q != 0 ? true : baseline.filmRender.dirCouplers.active
        case "grain_amount":
            // 与原生 quick_controls.expected_values 对齐：强度轴只动密度地板与均匀度。
            let grain = baseline.filmRender.grain
            let t = clamp(q / 100, -1, 1)
            edit.filmRender.grain.densityMin = grain.densityMin.map {
                clamp($0 * (1 + 0.9 * t), 0.005, 0.08)
            }
            edit.filmRender.grain.uniformity = grain.uniformity.map {
                clamp($0 - 0.06 * t, 0.90, 0.995)
            }
            edit.filmRender.grain.active = q <= -99 ? false : grain.active
        case "grain_size":
            // 原生独立轴：颗粒面积与边缘柔化。此前把尺寸混进强度轴，
            // 会让拉高强度时颗粒变粗、变锐，和原生不一致。
            let grain = baseline.filmRender.grain
            edit.filmRender.grain.particleAreaUM2 = clamp(
                grain.particleAreaUM2 * pow(2, 0.9 * q / 100), 0.02, 0.8)
            edit.filmRender.grain.blur = clamp(
                grain.blur * (1 + 0.25 * q / 100), 0, 1.5)
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
        case "temperature":
            // 滑条语义：正值 = 更暖。引擎里 yFilterShift 正值偏冷，所以取负。
            // 满量程 60 CC，与原生 PAD_CC_FULL_SCALE 一致。
            edit.enlarger.yFilterShift = clamp(
                baseline.enlarger.yFilterShift - 60 * q / 100, -60, 60)
        default:
            break
        }
    }

    private func writePro(_ id: String, _ value: Double) {
        switch id {
        case "exposure_compensation_ev": edit.camera.exposureCompensationEV = value
        case "print_exposure": edit.enlarger.printExposure = value
        case "gamma_factor":
            edit.printRender.densityCurvesMorph.gammaFactor = value
            edit.printRender.densityCurvesMorph.active = true
        case "developer_exhaustion":
            edit.printRender.densityCurvesMorph.developerExhaustion = value
            edit.printRender.densityCurvesMorph.active = true
        case "gamma_factor_fast":
            edit.printRender.densityCurvesMorph.gammaFactorFast = value
            edit.printRender.densityCurvesMorph.active = true
        case "gamma_factor_slow":
            edit.printRender.densityCurvesMorph.gammaFactorSlow = value
            edit.printRender.densityCurvesMorph.active = true
        case "gamma_factor_red":
            edit.printRender.densityCurvesMorph.gammaFactorRed = value
            edit.printRender.densityCurvesMorph.active = true
        case "gamma_factor_green":
            edit.printRender.densityCurvesMorph.gammaFactorGreen = value
            edit.printRender.densityCurvesMorph.active = true
        case "gamma_factor_blue":
            edit.printRender.densityCurvesMorph.gammaFactorBlue = value
            edit.printRender.densityCurvesMorph.active = true
        case "film_density_curve_gamma": edit.filmRender.densityCurveGamma = value
        case "print_y_filter_shift": edit.enlarger.yFilterShift = value
        case "print_m_filter_shift": edit.enlarger.mFilterShift = value
        case "inhibition_interlayer": edit.filmRender.dirCouplers.inhibitionInterlayer = value
        case "inhibition_samelayer": edit.filmRender.dirCouplers.inhibitionSameLayer = value
        case "coupler_amount": edit.filmRender.dirCouplers.amount = value
        case "film_format_mm": edit.camera.filmFormatMM = value
        case "diffusion_size_um": edit.filmRender.dirCouplers.diffusionSizeUM = value
        case "preflash_exposure": edit.enlarger.preflashExposure = value
        case "preflash_y_filter_shift": edit.enlarger.preflashYFilterShift = value
        case "preflash_m_filter_shift": edit.enlarger.preflashMFilterShift = value
        case "camera_lens_blur_um": edit.camera.lensBlurUM = value
        case "camera_diffusion_strength": edit.camera.diffusionFilter.strength = value
        case "camera_diffusion_spatial_scale": edit.camera.diffusionFilter.spatialScale = value
        case "camera_diffusion_halo_warmth": edit.camera.diffusionFilter.haloWarmth = value
        case "enlarger_diffusion_strength": edit.enlarger.diffusionFilter.strength = value
        case "enlarger_diffusion_spatial_scale": edit.enlarger.diffusionFilter.spatialScale = value
        case "print_glare_percent": edit.printRender.glare.percent = value
        case "print_glare_roughness": edit.printRender.glare.roughness = value
        case "print_glare_blur": edit.printRender.glare.blur = value
        case "film_glare_percent": edit.filmRender.glare.percent = value
        case "film_glare_roughness": edit.filmRender.glare.roughness = value
        case "film_glare_blur": edit.filmRender.glare.blur = value
        case "halation_amount": edit.filmRender.halation.halationAmount = value
        case "halation_scatter_amount": edit.filmRender.halation.scatterAmount = value
        case "halation_scatter_scale": edit.filmRender.halation.scatterSpatialScale = value
        case "halation_spatial_scale": edit.filmRender.halation.halationSpatialScale = value
        case "halation_boost_ev": edit.filmRender.halation.boostEV = value
        case "halation_boost_range": edit.filmRender.halation.boostRange = value
        case "halation_protect_ev": edit.filmRender.halation.protectEV = value
        case "halation_n_bounces":
            edit.filmRender.halation.halationNBounces = max(1, Int(value.rounded()))
        case "halation_bounce_decay": edit.filmRender.halation.halationBounceDecay = value
        case "grain_density_min":
            edit.filmRender.grain.densityMin = [value, value, value]
        case "grain_uniformity":
            edit.filmRender.grain.uniformity = [value, value, value]
        case "grain_blur": edit.filmRender.grain.blur = value
        case "grain_dye_clouds": edit.filmRender.grain.blurDyeCloudsUM = value
        case "scanner_unsharp_amount":
            edit.scanner.unsharpMask = [edit.scanner.unsharpMask[0], value]
        case "scanner_unsharp_sigma":
            edit.scanner.unsharpMask = [value, edit.scanner.unsharpMask[1]]
        case "scanner_lens_blur": edit.scanner.lensBlur = value
        case "white_level": edit.scanner.whiteLevel = value
        case "black_level": edit.scanner.blackLevel = value
        case "particle_area_um2": edit.filmRender.grain.particleAreaUM2 = value
        // MARK: 输入（RAW 解码与预处理）
        case "white_balance_temperature":
            edit.loadRaw.temperature = clamp(value, 1000, 10000)
        case "white_balance_tint":
            edit.loadRaw.tint = clamp(value, 0.5, 2.0)
        case "crop_center_x":
            edit.io.cropCenter = pair(edit.io.cropCenter, replacing: 0, with: clamp(value, 0, 1), fallback: 0.5)
        case "crop_center_y":
            edit.io.cropCenter = pair(edit.io.cropCenter, replacing: 1, with: clamp(value, 0, 1), fallback: 0.5)
        case "crop_size_x":
            edit.io.cropSize = pair(edit.io.cropSize, replacing: 0, with: clamp(value, 0.1, 1), fallback: 0.1)
        case "crop_size_y":
            edit.io.cropSize = pair(edit.io.cropSize, replacing: 1, with: clamp(value, 0.1, 1), fallback: 0.1)
        case "upscale_factor":
            edit.io.upscaleFactor = clamp(value, 1, 4)
        default: break
        }
    }

    /// 把二元组（裁切中心/大小）的第 index 项替换掉，长度不足时先补成 fallback 对。
    private func pair(_ values: [Double], replacing index: Int,
                      with value: Double, fallback: Double) -> [Double] {
        var pair = values.count == 2 ? values : [fallback, fallback]
        pair[index] = value
        return pair
    }

    private func pairComponent(_ values: [Double], _ index: Int, _ fallback: Double) -> Double {
        values.indices.contains(index) ? values[index] : fallback
    }

    /// 专业行的基线读数：用于判断滑条是否被改过，避免拿目录默认值误判。
    func proBaseline(_ id: String) -> Double {
        proValue(id, in: baseline)
    }

    private func proValue(_ id: String) -> Double {
        proValue(id, in: edit)
    }

    private func proValue(_ id: String, in edit: PhotoEdit) -> Double {
        switch id {
        case "exposure_compensation_ev": return edit.camera.exposureCompensationEV
        case "print_exposure": return edit.enlarger.printExposure
        case "gamma_factor": return edit.printRender.densityCurvesMorph.gammaFactor
        case "developer_exhaustion": return edit.printRender.densityCurvesMorph.developerExhaustion
        case "gamma_factor_fast": return edit.printRender.densityCurvesMorph.gammaFactorFast
        case "gamma_factor_slow": return edit.printRender.densityCurvesMorph.gammaFactorSlow
        case "gamma_factor_red": return edit.printRender.densityCurvesMorph.gammaFactorRed
        case "gamma_factor_green": return edit.printRender.densityCurvesMorph.gammaFactorGreen
        case "gamma_factor_blue": return edit.printRender.densityCurvesMorph.gammaFactorBlue
        case "film_density_curve_gamma": return edit.filmRender.densityCurveGamma
        case "print_y_filter_shift": return edit.enlarger.yFilterShift
        case "print_m_filter_shift": return edit.enlarger.mFilterShift
        case "inhibition_interlayer":
            return edit.filmRender.dirCouplers.inhibitionInterlayer
        case "inhibition_samelayer":
            return edit.filmRender.dirCouplers.inhibitionSameLayer
        case "coupler_amount": return edit.filmRender.dirCouplers.amount
        case "film_format_mm": return edit.camera.filmFormatMM
        case "diffusion_size_um": return edit.filmRender.dirCouplers.diffusionSizeUM
        case "preflash_exposure": return edit.enlarger.preflashExposure
        case "preflash_y_filter_shift": return edit.enlarger.preflashYFilterShift
        case "preflash_m_filter_shift": return edit.enlarger.preflashMFilterShift
        case "camera_lens_blur_um": return edit.camera.lensBlurUM
        case "camera_diffusion_strength": return edit.camera.diffusionFilter.strength
        case "camera_diffusion_spatial_scale": return edit.camera.diffusionFilter.spatialScale
        case "camera_diffusion_halo_warmth": return edit.camera.diffusionFilter.haloWarmth
        case "enlarger_diffusion_strength": return edit.enlarger.diffusionFilter.strength
        case "enlarger_diffusion_spatial_scale": return edit.enlarger.diffusionFilter.spatialScale
        case "print_glare_percent": return edit.printRender.glare.percent
        case "print_glare_roughness": return edit.printRender.glare.roughness
        case "print_glare_blur": return edit.printRender.glare.blur
        case "film_glare_percent": return edit.filmRender.glare.percent
        case "film_glare_roughness": return edit.filmRender.glare.roughness
        case "film_glare_blur": return edit.filmRender.glare.blur
        case "halation_amount": return edit.filmRender.halation.halationAmount
        case "halation_scatter_amount": return edit.filmRender.halation.scatterAmount
        case "halation_scatter_scale": return edit.filmRender.halation.scatterSpatialScale
        case "halation_spatial_scale": return edit.filmRender.halation.halationSpatialScale
        case "halation_boost_ev": return edit.filmRender.halation.boostEV
        case "halation_boost_range": return edit.filmRender.halation.boostRange
        case "halation_protect_ev": return edit.filmRender.halation.protectEV
        case "halation_n_bounces": return Double(edit.filmRender.halation.halationNBounces)
        case "halation_bounce_decay": return edit.filmRender.halation.halationBounceDecay
        case "grain_density_min": return edit.filmRender.grain.densityMin.first ?? 0.03
        case "grain_uniformity": return edit.filmRender.grain.uniformity.first ?? 0.97
        case "grain_blur": return edit.filmRender.grain.blur
        case "grain_dye_clouds": return edit.filmRender.grain.blurDyeCloudsUM
        case "scanner_unsharp_amount": return edit.scanner.unsharpMask[1]
        case "scanner_unsharp_sigma": return edit.scanner.unsharpMask[0]
        case "scanner_lens_blur": return edit.scanner.lensBlur
        case "white_level": return edit.scanner.whiteLevel
        case "black_level": return edit.scanner.blackLevel
        case "particle_area_um2": return edit.filmRender.grain.particleAreaUM2
        case "white_balance_temperature": return edit.loadRaw.temperature
        case "white_balance_tint": return edit.loadRaw.tint
        case "crop_center_x": return pairComponent(edit.io.cropCenter, 0, 0.5)
        case "crop_center_y": return pairComponent(edit.io.cropCenter, 1, 0.5)
        case "crop_size_x": return pairComponent(edit.io.cropSize, 0, 0.1)
        case "crop_size_y": return pairComponent(edit.io.cropSize, 1, 0.1)
        case "upscale_factor": return edit.io.upscaleFactor
        default: return 0
        }
    }

    private func proToggleValue(_ id: String) -> Bool {
        switch id {
        case "auto_exposure": return edit.camera.autoExposure
        case "print_exposure_compensation": return edit.enlarger.printExposureCompensation
        case "normalize_print_exposure": return edit.enlarger.normalizePrintExposure
        case "couplers_active": return edit.filmRender.dirCouplers.active
        case "camera_diffusion_active": return edit.camera.diffusionFilter.active
        case "enlarger_diffusion_active": return edit.enlarger.diffusionFilter.active
        case "print_glare_active": return edit.printRender.glare.active
        case "grain_active": return edit.filmRender.grain.active
        case "grain_sublayers_active": return edit.filmRender.grain.sublayersActive
        case "halation_active": return edit.filmRender.halation.active
        case "halation_renormalize": return edit.filmRender.halation.halationRenormalize
        case "film_glare_active": return edit.filmRender.glare.active
        case "white_correction": return edit.scanner.whiteCorrection
        case "black_correction": return edit.scanner.blackCorrection
        case "scan_film": return edit.io.scanFilm
        case "lens_correction": return edit.loadRaw.lensCorrection
        case "crop": return edit.io.crop
        case "input_gamut_compress": return edit.io.inputGamutCompressActive
        default: return false
        }
    }

    private func proChoiceValue(_ id: String) -> String {
        switch id {
        case "auto_exposure_method": return edit.camera.autoExposureMethod
        case "print_illuminant": return edit.enlarger.illuminant
        case "camera_diffusion_family": return edit.camera.diffusionFilter.filterFamily
        case "white_balance": return edit.loadRaw.whiteBalance
        case "output_gamut_compress": return edit.io.outputGamutCompressAlgorithm
        default: return ""
        }
    }

    func choiceValue(_ id: String) -> String {
        proChoices[id] ?? proChoiceValue(id)
    }

    private func publishFromEdit() {
        var quick: [String: Double] = [:]
        for group in MobileCatalog.quickGroups {
            for axis in group.axes {
                quick[axis.id] = quickIntents[axis.id] ?? axis.base
            }
        }
        padX = clamp((edit.enlarger.yFilterShift - baseline.enlarger.yFilterShift) / 60 * 100, -100, 100)
        padY = clamp((edit.enlarger.mFilterShift - baseline.enlarger.mFilterShift) / 60 * 100, -100, 100)
        quick["temperature"] = -padX
        quickValues = quick

        var values: [String: Double] = [:]
        var toggles: [String: Bool] = [:]
        var choices: [String: String] = [:]
        for page in MobileCatalog.proPages {
            for group in page.groups {
                for row in group.rows {
                    switch row.control {
                    case .slider:
                        values[row.id] = proValue(row.id)
                    case .toggle:
                        toggles[row.id] = proToggleValue(row.id)
                    case .choice:
                        choices[row.id] = proChoiceValue(row.id)
                    }
                }
            }
        }
        proValues = values
        proToggles = toggles
        proChoices = choices
        filmID = edit.filmStock
        paperID = edit.printStock
        isMonochrome = edit.monochrome
    }

    private func pushUndo(key: String) {
        let now = Date()
        if lastUndoKey == key, now.timeIntervalSince(lastUndoTime) < 1.2 {
            lastUndoTime = now
            return
        }
        lastUndoKey = key
        lastUndoTime = now
        undoStack.append(edit)
        if undoStack.count > 40 { undoStack.removeFirst() }
        canUndo = true
    }

    private func persistSoon() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistWork = nil
            self?.persistNow()
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func persistNow() {
        guard var photo = store.photos.first(where: { $0.id == photoID }) else { return }
        edit.quickIntents = quickIntents
        photo.edit = edit
        if quickIntents.isEmpty {
            photo.quickBaselineData = nil
        } else if photo.quickBaselineData == nil {
            photo.quickBaselineData = try? JSONEncoder().encode(baseline)
        }
        try? store.update(photo)
        onPersist?(photo)
    }

    // MARK: - 工具

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    /// 黑白模式：按目标色彩空间的亮度权重把 RGB 归一成灰。
    /// 只发生在显影结果之后，不改变任何核心显影参数。
    private nonisolated static func monochrome(_ image: ImageRGB, colorSpace: String) -> ImageRGB {
        let weights = luminanceWeights(for: colorSpace)
        return image.map { pixel in
            let value = pixel.x * weights.0 + pixel.y * weights.1 + pixel.z * weights.2
            return Vec3(value, value, value)
        }
    }

    private nonisolated static func luminanceWeights(for colorSpace: String) -> (Double, Double, Double) {
        switch colorSpace {
        case "ProPhoto RGB":
            return (0.2880402, 0.7118741, 0.0000857)
        case "ACES2065-1":
            return (0.2722287, 0.6740818, 0.0536895)
        default:
            return (0.2126, 0.7152, 0.0722)
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

    /// 输入原片转成屏幕 sRGB，供长按对比使用。
    private nonisolated static func displayImage(_ image: ImageRGB, colorSpace: String,
                                                 cctfDecoding: Bool) -> ImageRGB {
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
        return output.sanitizedNonFinite()
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

enum MobileExportError: Error {
    case busy
    case decodeFailed
}

/// 导出长边档位：0 原始（原图真实像素，不静默降采样）、1 2048、2 4096。
enum ExportEdge {
    /// 单像素实测峰值：ImageRGB 改为 Float32 后，12.19 MP 全流程峰值约 1.45 GB，
    /// 折算约 119 B/px（含阶段缓冲与工具自身持有）。乘 1.1 取 130 B/px 做安全余量。
    private static let bytesPerPixelFootprint = 130.0

    static func resolve(index: Int, originalLongEdge: Int) -> Int {
        let edge = requested(index: index, originalLongEdge: originalLongEdge)
        // 原始档也必须钳位：48 MP 级原片按 119 B/px 的全流程峰值会超过前台预算，
        // 直接按原尺寸导出会被系统 jetsam。调用方负责把实际尺寸展示给用户。
        return clampToMemoryBudget(edge)
    }

    /// 用户选定的档位换算成长边，不做内存钳位。
    static func requested(index: Int, originalLongEdge: Int) -> Int {
        switch index {
        case 1: return min(2048, max(1, originalLongEdge))
        case 2: return min(4096, max(1, originalLongEdge))
        default: return max(1, originalLongEdge)
        }
    }

    /// 显式档位（2048/4096）按当前进程可用内存回退长边，避免把 App 撑到 jetsam。
    /// 4:3 画幅下长边 L 的像素数 ≈ 0.75·L²；峰值 ≈ 像素数 × bytesPerPixelFootprint。
    static func clampToMemoryBudget(_ edge: Int) -> Int {
        let available = Int(os_proc_available_memory())
        guard available > 0 else { return edge }
        let budget = Double(available) * 0.60
        let maxEdge = Int(sqrt(budget / (0.75 * bytesPerPixelFootprint)))
        guard maxEdge > 0 else { return edge }
        // 不要钳到 1/2 以下：宁可让系统去回收，也不要导出到几乎不可用的尺寸。
        // 但也不能把小于 1024 的原图反向放大，所以下限取 min(edge, 1024)。
        let floorEdge = min(edge, 1024)
        return max(floorEdge, min(edge, maxEdge))
    }
}
