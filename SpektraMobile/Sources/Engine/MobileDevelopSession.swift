import Foundation
import SwiftUI
import os
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - 显影交接图缓存

/// 每张照片只保留「显影台最后一次显影」的交接图（1600 长边，线性 ProPhoto）。
/// 文件头带参数指纹：显影参数一变，旧文件立即失效，并在下一次显影时被整体覆盖，
/// 不会按参数累积出多份缓存。
enum MDevelopHandoffCache {
    static let maxEdge = 1600
    private static let version: UInt32 = 1
    private static let magic: [UInt8] = [0x53, 0x50, 0x4B, 0x48] // "SPKH"

    struct Header {
        let width: Int
        let height: Int
        let fingerprint: String
        let payloadOffset: Int
    }

    /// 参数指纹：编码整份 `PhotoEdit`（排序键保证跨进程稳定）。
    static func fingerprint(edit: PhotoEdit, maxEdge: Int) -> String {
        var hash: UInt64 = 0xCBF29CE484222325
        func feed(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001B3
            }
        }
        feed(magic)
        feed(withUnsafeBytes(of: version.littleEndian) { Array($0) })
        feed(withUnsafeBytes(of: UInt32(maxEdge).littleEndian) { Array($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(edit) {
            feed(data)
        }
        return String(format: "%016llx", hash)
    }

    static func hasEntry(root: URL, photoID: String, fingerprint: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL(root: root, photoID: photoID)) else {
            return false
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512),
              let header = parse(head) else { return false }
        return header.fingerprint == fingerprint
    }

    static func load(root: URL, photoID: String, fingerprint: String) -> ImageRGB? {
        guard let data = try? Data(contentsOf: fileURL(root: root, photoID: photoID)),
              let header = parse(data),
              header.fingerprint == fingerprint else {
            NSLog("MHandoff cache miss %@", photoID)
            return nil
        }
        // 缓存文件来自磁盘，像素数必须先做上限校验，避免损坏文件把尺寸乘积撑到溢出。
        guard header.width > 0, header.height > 0,
              header.width <= 16_384, header.height <= 16_384,
              header.width * header.height <= 24_000_000 else { return nil }
        let count = header.width * header.height * 3
        let byteCount = count * MemoryLayout<Float>.size
        guard header.payloadOffset + byteCount <= data.count else { return nil }
        var image = ImageRGB(width: header.width, height: header.height)
        image.data.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let dst = destination.baseAddress, let src = source.baseAddress else { return }
                memcpy(dst, src.advanced(by: header.payloadOffset), byteCount)
            }
        }
        NSLog("MHandoff cache hit %@ %dx%d", photoID, header.width, header.height)
        return image
    }

    static func store(_ image: ImageRGB, root: URL, photoID: String, fingerprint: String) {
        guard image.width > 0, image.height > 0 else { return }
        var directory = directoryURL(root: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 交接图是可再生的派生缓存，不应该占用 iCloud 备份空间。
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        var data = headerData(width: image.width, height: image.height, fingerprint: fingerprint)
        data.append(image.data.withUnsafeBufferPointer { Data(buffer: $0) })
        try? data.write(to: fileURL(root: root, photoID: photoID), options: .atomic)
        prune(root: root, keeping: photoID)
        NSLog("MHandoff cache store %@ %dx%d %.0fMB", photoID, image.width, image.height,
              Double(data.count) / 1_048_576)
    }

    static func remove(root: URL, photoID: String) {
        try? FileManager.default.removeItem(at: fileURL(root: root, photoID: photoID))
    }

    /// 设置页缓存统计：交接图张数与占用字节数。
    static func statistics(root: URL) -> (count: Int, bytes: Int64) {
        let directory = directoryURL(root: root)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return (0, 0) }
        var bytes: Int64 = 0
        for file in files {
            bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files.count, bytes)
    }

    /// 设置页清理：删掉整个交接图目录。缓存只是显影加速层，删除后下一次进调色台会重新显影。
    static func clear(root: URL) {
        try? FileManager.default.removeItem(at: directoryURL(root: root))
    }

    /// 只保留最近用过的少数几张：缓存是「最后一次显影」的加速层，不是第二份照片库。
    private static let maxEntries = 8

    private static func prune(root: URL, keeping photoID: String) {
        let directory = directoryURL(root: root)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        guard files.count > maxEntries else { return }
        let sorted = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return left < right
        }
        let protected = "\(photoID).bin"
        for file in sorted.prefix(files.count - maxEntries)
        where file.lastPathComponent != protected {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 文件布局

    private static func directoryURL(root: URL) -> URL {
        root.appendingPathComponent("Handoffs", isDirectory: true)
    }

    private static func fileURL(root: URL, photoID: String) -> URL {
        directoryURL(root: root).appendingPathComponent("\(photoID).bin")
    }

    private static func headerData(width: Int, height: Int, fingerprint: String) -> Data {
        var data = Data(magic)
        append(UInt32(version), to: &data)
        append(UInt32(width), to: &data)
        append(UInt32(height), to: &data)
        let value = Data(fingerprint.utf8)
        append(UInt32(value.count), to: &data)
        data.append(value)
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func parse(_ data: Data) -> Header? {
        guard data.count >= 20, data.prefix(4).elementsEqual(magic) else { return nil }
        var offset = 4
        func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                data.withUnsafeBytes { source in
                    guard let dst = destination.baseAddress, let src = source.baseAddress else { return }
                    memcpy(dst, src.advanced(by: offset), 4)
                }
            }
            offset += 4
            return UInt32(littleEndian: value)
        }
        guard let fileVersion = readUInt32(), fileVersion == version,
              let width = readUInt32(), let height = readUInt32(),
              let length = readUInt32(),
              offset + Int(length) <= data.count else { return nil }
        let fingerprint = String(
            data: data.subdata(in: offset..<offset + Int(length)), encoding: .utf8) ?? ""
        offset += Int(length)
        guard !fingerprint.isEmpty else { return nil }
        return Header(width: Int(width), height: Int(height),
                      fingerprint: fingerprint, payloadOffset: offset)
    }
}

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
    /// RAW 解码超时/失败时的提示：已显示预览，导出仍会重新读取原片。
    @Published private(set) var loadNote: String?
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
    /// 被专业模式接管的快速轴：滑条冻结，直到重置显影 / 重置快速。
    @Published private(set) var frozenQuickAxes: Set<String> = []
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
    /// 导入时状态：显影台重置回到这里（不碰调色台的裁切 / 边框）。
    private let initialEdit: PhotoEdit
    private var quickIntents: [String: Double]
    private var image: ImageRGB?
    private var inputColorSpace = "ProPhoto RGB"
    private var inputCCTF = false

    private var undoStack: [PhotoEdit] = []
    private var lastUndoKey = ""
    private var lastUndoTime = Date.distantPast

    private var loadToken = 0
    /// 原片解码是否在途：调色台直接复用缓存时不会主动 start()，
    /// 万一缓存刚好被淘汰，交接请求要能自己补一次解码而不是永远挂起。
    private var loadInFlight = false
    private var fastToken = 0
    private var renderToken = 0
    private var accurateDoneFastToken = -1
    private var renderInFlight = false
    private var fastInFlight = false
    private var fastDirty = false
    private var pendingSettle: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private var pendingHandoffs: [(maxEdge: Int, cacheKey: String?, completion: (ImageRGB?) -> Void)] = []
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
        // isRaw 以 LibraryStore 入库时写入的字段为准（单一口径），
        // 不再按 filename 扩展名重算，避免两处判定漂移。
        self.isRawInput = photo.isRaw
        self.store = store
        // 旧版本的库记录可能把 ARW 的内嵌预览尺寸当成原图尺寸（如 1616×1080）。
        // 这里直接读 RAW 头，取库记录与真实尺寸的较大值，已有照片也能恢复全分辨率导出。
        let storedEdge = max(photo.width, photo.height)
        let probed = LibraryStore.pixelSize(url: store.originalURL(for: photo))
        self.originalLongEdge = max(storedEdge, max(probed.width, probed.height))
        let saved = UserDefaults.standard.double(forKey: Self.previewScaleKey)
        self.previewScale = saved >= 0.125 && saved <= 1.0 ? saved : 0.25
        self.edit = photo.edit
        if let data = photo.initialEditData,
           let decoded = try? JSONDecoder().decode(PhotoEdit.self, from: data) {
            self.initialEdit = decoded
        } else {
            self.initialEdit = photo.edit
        }
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
        loadInFlight = false
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
        loadNote = nil
        loadToken += 1
        let token = loadToken
        loadInFlight = true
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
                    self.loadInFlight = false
                    self.loadTimeoutWork?.cancel()
                    self.loadTimeoutWork = nil
                    self.loadFailure = nil
                    self.errorMessage = nil
                    self.image = loaded.image
                    self.loadedEdge = max(loaded.image.width, loaded.image.height)
                    self.loadNote = loaded.usedFallback
                        ? "RAW 解码较慢 · 已显示预览"
                        : nil
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
                    self.loadInFlight = false
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

    /// 预览兜底后重试全质量解码：保留当前预览，不把界面切回空白。
    func retryFullResolution() {
        loadNote = nil
        loadOriginal(maxSize: max(1600, previewEdge))
    }

    /// 启动解码看门狗。CIRAWFilter 对个别 RAW 可能长时间不返回，
    /// 超时后先让界面进入可重试的失败态，而不是永远停在「正在读取原片…」。
    private func armLoadTimeout(token: Int) {
        loadTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.loadToken == token, !self.isLoaded else { return }
            self.loadInFlight = false
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

    // MARK: - 快速 / 专业一致性

    /// 专业控件 → 被它接管的快速轴。只有这些控件会让快速滑条冻结。
    nonisolated static func quickAxes(affectedByPro id: String) -> Set<String> {
        switch id {
        case "exposure_compensation_ev", "print_exposure_compensation":
            return ["camera_exposure"]
        case "print_exposure":
            return ["print_brightness"]
        case "gamma_factor":
            return ["tonal_contrast"]
        case "developer_exhaustion":
            return ["highlight_softening"]
        case "inhibition_interlayer", "couplers_active":
            return ["color_density"]
        case "grain_density_min", "grain_uniformity", "grain_active":
            return ["grain_amount"]
        case "particle_area_um2", "grain_blur":
            return ["grain_size"]
        case "scanner_unsharp_amount", "scanner_unsharp_sigma", "scanner_lens_blur":
            return ["scanner_clarity"]
        case "print_y_filter_shift", "print_m_filter_shift":
            return ["temperature"]
        default:
            return []
        }
    }

    private func freezeQuick(affectedByPro id: String) {
        let axes = Self.quickAxes(affectedByPro: id)
        guard !axes.isEmpty else { return }
        var frozen = Set(edit.frozenQuick ?? [])
        let before = frozen.count
        frozen.formUnion(axes)
        guard frozen.count != before else { return }
        edit.frozenQuick = frozen.sorted()
        frozenQuickAxes = frozen
    }

    private func unfreezeAllQuick() {
        edit.frozenQuick = nil
        frozenQuickAxes = []
    }

    // MARK: - 参数映射

    func applyQuick(_ id: String, _ q: Double) {
        guard MobileCatalog.quickGroups.flatMap(\.axes).contains(where: { $0.id == id }) else { return }
        // 专业模式已接管这条轴：快速滑条冻结，避免两套参数互相覆盖。
        guard !frozenQuickAxes.contains(id) else { return }
        if id == "temperature" {
            // 滑条正值 = 更暖；色盘的 x 正值 = 更冷（右「冷」），两者互为相反数。
            applyPad(x: -q, y: padY)
            return
        }
        pushUndo(key: id)
        quickIntents[id] = q
        edit.quickIntents = quickIntents
        applyQuickMapping(id: id, q: q)
        // 快速轴会写入专业字段：同步刷新 proValues，切到专业页时滑块必须跟着变化。
        publishFromEdit()
        persistSoon()
        schedulePreview()
    }

    func applyPad(x: Double, y: Double) {
        guard !frozenQuickAxes.contains("temperature") else { return }
        pushUndo(key: "pad")
        padX = min(max(x, -100), 100)
        padY = min(max(y, -100), 100)
        quickValues["temperature"] = -padX
        quickIntents["temperature"] = -padX
        // 色盘满量程 = 60 CC（原生 PAD_CC_FULL_SCALE）。
        // 纵向：上 = +M（负片印相偏绿）、下 = -M（偏品红），与盘面标注一致。
        edit.enlarger.yFilterShift = clampValue(
            baseline.enlarger.yFilterShift + 60 * padX / 100, -60, 60)
        edit.enlarger.mFilterShift = clampValue(
            baseline.enlarger.mFilterShift + 60 * padY / 100, -60, 60)
        edit.quickIntents = quickIntents
        publishFromEdit()
        persistSoon()
        schedulePreview()
    }

    /// 这些滑块参与 RAW 解码，改变后要重新解码原图，而不是只重渲染。
    private static let rawDecodeSliders: Set<String> = [
        "white_balance_temperature", "white_balance_tint",
    ]

    func applyPro(_ id: String, _ value: Double) {
        let previous = proValue(id)
        guard abs(previous - value) > 1e-9 else { return }
        pushUndo(key: "pro." + id)
        writePro(id, value)
        freezeQuick(affectedByPro: id)
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
        guard proToggleValue(id) != value else { return }
        pushUndo(key: "toggle." + id)
        writeProToggle(id, value)
        freezeQuick(affectedByPro: id)
        proToggles[id] = value
        persistSoon()
        if id == "lens_correction" {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    /// 专业页下拉项（测光方式、印相光源、柔光类型、白平衡、输出色域压缩）。
    func applyProChoice(_ id: String, _ value: String) {
        guard proChoiceValue(id) != value else { return }
        pushUndo(key: "choice." + id)
        writeProChoice(id, value)
        freezeQuick(affectedByPro: id)
        proChoices[id] = value
        persistSoon()
        if id == "white_balance" {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    private func writeProToggle(_ id: String, _ value: Bool) {
        Self.writeProToggle(id, value, into: &edit)
    }

    nonisolated static func writeProToggle(_ id: String, _ value: Bool, into edit: inout PhotoEdit) {
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
        case "lens_correction": edit.loadRaw.lensCorrection = value
        case "crop": edit.io.crop = value
        case "input_gamut_compress": edit.io.inputGamutCompressActive = value
        default: break
        }
    }

    private func writeProChoice(_ id: String, _ value: String) {
        Self.writeProChoice(id, value, into: &edit)
    }

    nonisolated static func writeProChoice(_ id: String, _ value: String, into edit: inout PhotoEdit) {
        switch id {
        case "auto_exposure_method": edit.camera.autoExposureMethod = value
        case "print_illuminant": edit.enlarger.illuminant = value
        case "camera_diffusion_family": edit.camera.diffusionFilter.filterFamily = value
        case "white_balance": edit.loadRaw.whiteBalance = value
        case "output_gamut_compress": edit.io.outputGamutCompressAlgorithm = value
        default: break
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
            guard !frozenQuickAxes.contains(control) else { continue }
            applyQuickMapping(id: control, q: q, edit: &next)
        }
        // 色盘纵向（品红/绿）没有对应的 quickIntents 字段，换胶片时必须从当前色盘位置恢复。
        next.enlarger.yFilterShift = clampValue(
            baseline.enlarger.yFilterShift + 60 * padX / 100, -60, 60)
        next.enlarger.mFilterShift = clampValue(
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
        // 内置预设是一整套完整 look：应用后快速轴回到可控状态。
        unfreezeAllQuick()
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
            guard !frozenQuickAxes.contains(control) else { continue }
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

    /// 套用用户保存的显影预设：胶片组合 + 勾选的专业参数。
    /// 与内置预设不同，这里只覆盖预设包含的专业控件，其余参数保持当前值。
    func applyUserPreset(_ preset: MUserDevelopPreset) {
        pushUndo(key: "develop.userPreset")
        var next = edit
        next.filmStock = preset.filmID
        next.printStock = preset.paperID
        next.monochrome = preset.monochrome
        if let scanFilm = Self.scanFilmForSelection(preset.filmID) {
            next.io.scanFilm = scanFilm
        }

        edit = next
        for (id, value) in preset.pro {
            switch value {
            case .number(let number):
                // 曝光补偿保存的是「保存时基线 + 调整量」，套用时换成当前基线。
                let adjusted = id == "exposure_compensation_ev"
                    ? QuickExposureMapping.presetExposure(
                        absolute: number,
                        savedBaseline: preset.exposureBaselineEV,
                        currentBaseline: baseline.camera.exposureCompensationEV)
                    : number
                writePro(id, adjusted)
            case .flag(let flag): writeProToggle(id, flag)
            case .option(let option): writeProChoice(id, option)
            }
        }
        // 预设包含会与快速轴重叠的专业控件时，冻结这些轴，避免快速滑条再覆盖回来。
        for id in preset.pro.keys {
            freezeQuick(affectedByPro: id)
        }
        // 专业预设不改快速意图；保留快速滑条的原读数，但被冻结的轴不会再生效。

        edit.quickIntents = quickIntents
        publishFromEdit()
        persistNow()
        if Self.presetTouchesRawDecode(preset) {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
    }

    private static func presetTouchesRawDecode(_ preset: MUserDevelopPreset) -> Bool {
        let rawKeys: Set<String> = [
            "white_balance", "white_balance_temperature", "white_balance_tint", "lens_correction",
        ]
        return !rawKeys.isDisjoint(with: preset.pro.keys)
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
        // 冻结轴对应的专业字段已经回到基线，可以安全解冻。
        unfreezeAllQuick()
        publishFromEdit()
        persistNow()
        schedulePreview()
    }

    /// 显影台重置：回到导入时状态。调色台的裁切 / 边框不在 PhotoEdit 内，不受影响。
    func resetAllDevelop() {
        pushUndo(key: "reset.develop.all")
        let previousLoadRaw = edit.loadRaw
        quickIntents = initialEdit.quickIntents
        edit = initialEdit
        edit.quickIntents = quickIntents
        edit.frozenQuick = nil
        baseline = initialEdit
        Self.enforcePositiveScanMode(on: &edit)
        publishFromEdit()
        persistNow()
        if edit.loadRaw != previousLoadRaw {
            scheduleRawReload()
        } else {
            schedulePreview()
        }
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
        unfreezeAllQuick()
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
        // 大图优先分带显影：内存只跟条带高度有关，不再按整张面积一刀切降采样。
        let photo = store.photos.first(where: { $0.id == photoID })
        let originalWidth = photo?.width ?? 0
        let originalHeight = photo?.height ?? 0
        let originalEdge = originalLongEdge > 0 ? originalLongEdge : max(image.width, image.height)
        let aspect = (originalWidth > 0 && originalHeight > 0)
            ? Double(min(originalWidth, originalHeight)) / Double(max(originalWidth, originalHeight))
            : 0.75
        var params: RuntimePhotoParams
        do {
            params = try edit.runtimeParams()
        } catch {
            completion(.failure(error))
            return
        }
        let plan = ExportEdge.plan(index: longEdgeIndex, originalLongEdge: originalEdge,
                                   params: params, aspect: aspect)
        let requested = plan.edge
        let clampedNote = plan.clamped ? "导出 · 内存上限 \(requested)" : "导出"
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
            guard var loaded = try? ImageLoader.load(
                url: sourceURL, maxSize: requested, rawOptions: options,
                rotationTurns: rotation, allowEncoded: true, rawTimeout: 60,
                allowPreviewFallback: false) else {
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
            var prepared = PreviewRenderer.prepared(loaded.image, maxSize: requested)
            // 解码结果与 prepared 共享同一块存储；把 loaded 的引用清掉，
            // 后续 COW / 分带分配才能拿到唯一所有权。
            loaded.image = ImageRGB(width: 0, height: 0)
            let progress: (String, Int, Int) -> Void = { label, _, _ in
                Task { @MainActor [weak self] in
                    self?.exportLabel = Self.stageLabel(label)
                }
            }
            let result: PipelineResult
            if plan.tiled {
                result = pipeline.processTiled(prepared,
                                               bandPixelBudget: plan.bandPixelBudget,
                                               progress: progress)
            } else {
                result = pipeline.process(prepared, progress: progress)
            }
            prepared = ImageRGB(width: 0, height: 0)
            var output = result.rgbOut
            if monochrome {
                output = Self.monochrome(output, colorSpace: colorSpace)
            }
            if watermarkEnabled {
                var config = watermark
                // 导出面板的勾选是这次导出的最终决定，覆盖设置里的启用位。
                config.enabled = true
                MWatermarkRenderer.compositeInPlace(
                    &output, config: config,
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

    /// 调色台导出用的内存计划：与显影台共用同一套可用内存/分带计算。
    func exportPlan(index: Int, originalEdge: Int, aspect: Double = 0.75,
                    includeGrade: Bool = false) -> ExportEdge.Plan? {
        guard let params = try? edit.runtimeParams() else { return nil }
        return ExportEdge.plan(index: index, originalLongEdge: originalEdge,
                               params: params, aspect: aspect, includeGrade: includeGrade)
    }

    /// 交接图缓存指纹：只由影响显影结果的参数决定（参数一变即失效）。
    nonisolated static func handoffFingerprint(
        edit: PhotoEdit, maxEdge: Int = MDevelopHandoffCache.maxEdge
    ) -> String {
        MDevelopHandoffCache.fingerprint(edit: edit, maxEdge: maxEdge)
    }

    /// 主页长按直接进调色台时，用库记录判断有没有可复用的交接图缓存。
    nonisolated static func handoffFingerprint(for photo: LibraryPhoto) -> String {
        handoffFingerprint(edit: photo.edit)
    }

    /// 显影 → 线性 ProPhoto 交接像素。调色台只接收这一份结果，不再接触 RAW。
    /// 若 RAW 还在解码，先挂起，解码完成或失败后再回调。
    ///
    /// 1600 长边的调色预览交接图优先走磁盘缓存：参数没变时直接读上次的显影结果，
    /// 调色台不再重复显影；参数变了则缓存指纹失效，重新显影后覆盖同一份文件。
    func prepareHandoff(maxEdge: Int = 1600, tiled: Bool = false, bandPixelBudget: Int = 0,
                        completion: @escaping (ImageRGB?) -> Void) {
        // 只缓存调色预览用的 1600 交接图；导出的其他尺寸不写缓存，
        // 避免低分辨率结果覆盖掉调色台要用的那一份。
        let cacheable = !tiled && maxEdge == MDevelopHandoffCache.maxEdge
        if cacheable {
            let fingerprint = Self.handoffFingerprint(edit: edit, maxEdge: maxEdge)
            let photoID = self.photoID
            let root = store.root
            loadQueue.async { [weak self] in
                if let cached = MDevelopHandoffCache.load(
                    root: root, photoID: photoID, fingerprint: fingerprint) {
                    completion(cached)
                    return
                }
                Task { @MainActor [weak self] in
                    self?.requestHandoff(maxEdge: maxEdge, tiled: false,
                                         bandPixelBudget: 0,
                                         cacheKey: fingerprint, completion: completion)
                }
            }
            return
        }
        requestHandoff(maxEdge: maxEdge, tiled: tiled,
                       bandPixelBudget: bandPixelBudget,
                       cacheKey: nil, completion: completion)
    }

    private func requestHandoff(maxEdge: Int, tiled: Bool, bandPixelBudget: Int,
                                cacheKey: String?,
                                completion: @escaping (ImageRGB?) -> Void) {
        if let image {
            enqueueHandoffRender(image, maxEdge: maxEdge, tiled: tiled,
                                 bandPixelBudget: bandPixelBudget,
                                 cacheKey: cacheKey, completion: completion)
            return
        }
        if errorMessage != nil {
            completion(nil)
            return
        }
        // 缓存未命中且这个会话还没开始解码（主页长按直接进调色台时不会 start()）：
        // 这里补一次解码，挂起请求，避免调色台停在「生成交接图」。
        if image == nil, !loadInFlight {
            loadOriginal(maxSize: max(1600, previewEdge))
        }
        pendingHandoffs.append((maxEdge, cacheKey, completion))
    }

    private func enqueueHandoffRender(_ previewImage: ImageRGB, maxEdge: Int,
                                      tiled: Bool, bandPixelBudget: Int,
                                      cacheKey: String?,
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
        let photoID = self.photoID
        let root = store.root
        loadQueue.async {
            var params = baseParams
            var source = previewImage
            if maxEdge > previewEdge {
                // 导出/交接要求原图尺寸：全质量解码失败时宁可失败，也不能把
                // 1600 预览放大后当成原片交出去。
                guard let loaded = try? ImageLoader.load(
                    url: url, maxSize: maxEdge, rawOptions: options,
                    rotationTurns: rotation, allowEncoded: true,
                    rawTimeout: 60, allowPreviewFallback: false) else {
                    completion(nil)
                    return
                }
                source = loaded.image
                params.io.inputColorSpace = loaded.colorSpace
                params.io.inputCCTFDecoding = loaded.cctfDecoding
            } else {
                params.io.inputColorSpace = previewSpace
                params.io.inputCCTFDecoding = previewCCTF
            }
            params.io.outputColorSpace = "ProPhoto RGB"
            params.io.outputCCTFEncoding = false
            renderer.render(params: params, image: source, maxSize: maxEdge,
                            tiled: tiled, bandPixelBudget: bandPixelBudget) { outcome in
                let result = monochrome
                    ? Self.monochrome(outcome.image, colorSpace: "ProPhoto RGB")
                    : outcome.image
                if let cacheKey, result.width > 0, result.height > 0 {
                    // 显影参数变了才会走到这里：旧缓存被同一文件覆盖，不累积。
                    MDevelopHandoffCache.store(result, root: root,
                                               photoID: photoID, fingerprint: cacheKey)
                }
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
                rotationTurns: rotation, allowEncoded: true, rawTimeout: 60,
                allowPreviewFallback: false) else {
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
            for item in items { item.completion(nil) }
            return
        }
        let items = pendingHandoffs
        pendingHandoffs.removeAll()
        for item in items {
            enqueueHandoffRender(image, maxEdge: item.maxEdge, tiled: false,
                                 bandPixelBudget: 0, cacheKey: item.cacheKey,
                                 completion: item.completion)
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
            ? clampValue(edit.printRender.densityCurvesMorph.gammaFactor, 0.5, 2.0)
            : 1
        p.saturation = edit.filmRender.dirCouplers.active
            ? clampValue(edit.filmRender.dirCouplers.inhibitionInterlayer, 0.35, 1.8)
            : 1
        p.highlightSoften = edit.printRender.densityCurvesMorph.active
            ? clampValue(edit.printRender.densityCurvesMorph.developerExhaustion / 0.6, 0, 1)
            : 0
        p.clarity = clampValue((quickIntents["scanner_clarity"] ?? 0) / 100, -1, 1)
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
        Self.applyQuickMapping(id: id, q: q, baseline: baseline,
                               quickIntents: quickIntents, edit: &edit)
    }

    private func applyQuickMapping(id: String, q: Double, edit: inout PhotoEdit) {
        Self.applyQuickMapping(id: id, q: q, baseline: baseline,
                               quickIntents: quickIntents, edit: &edit)
    }

    /// 「影调反差」与「高光柔和」共用 densityCurvesMorph.active：
    /// 任一快速轴非零时保持开启，全部归零才回落到基线状态。
    nonisolated private static func morphIsActive(baseline morph: PrintCurvesMorphParams,
                                                  quickIntents: [String: Double]) -> Bool {
        if abs(quickIntents["tonal_contrast"] ?? 0) > 1e-9 { return true }
        if abs(quickIntents["highlight_softening"] ?? 0) > 1e-9 { return true }
        return morph.active
    }

    /// 快速轴写入专业字段的唯一实现：实例、预设应用和直出模式共用。
    nonisolated static func applyQuickMapping(id: String, q: Double, baseline: PhotoEdit,
                                              quickIntents: [String: Double],
                                              edit: inout PhotoEdit) {
        switch id {
        case "camera_exposure":
            // 基线拍摄曝光非 0 时保留印相自动亮度补偿，改用印相曝光承载 EV 偏移；
            // 否则关闭补偿会撤掉基线补偿，滑条第一次离开 0 就按基线 EV 跳暗。
            QuickExposureMapping.apply(
                cameraExposure: q, baseline: baseline,
                quickIntents: quickIntents, edit: &edit)
        case "print_brightness":
            edit.enlarger.printExposure = QuickExposureMapping.printExposure(
                baseline: baseline,
                cameraEV: quickIntents["camera_exposure"] ?? 0,
                printEV: q)
        case "tonal_contrast":
            let morph = baseline.printRender.densityCurvesMorph
            edit.printRender.densityCurvesMorph.gammaFactor = clampValue(
                morph.gammaFactor * (1 + 0.35 * q / 100), 0.5, 2.0)
            edit.printRender.densityCurvesMorph.active = morphIsActive(
                baseline: morph, quickIntents: quickIntents)
        case "highlight_softening":
            // 直接复用专业模式「高光柔和」(developer_exhaustion)：
            // 拉伸密度曲线的 Gumbel 肩部，中高调被压暗、肩顶更长，高光层次更密而不死白。
            // 快速满量程只开到 0.6，保留专业页剩余的纵深。
            let morph = baseline.printRender.densityCurvesMorph
            let t = clampValue(q / 100, 0, 1)
            edit.printRender.densityCurvesMorph.developerExhaustion = clampValue(
                morph.developerExhaustion + 0.6 * t, 0, 1)
            edit.printRender.densityCurvesMorph.active = morphIsActive(
                baseline: morph, quickIntents: quickIntents)
        case "color_density":
            let b = baseline.filmRender.dirCouplers.inhibitionInterlayer
            edit.filmRender.dirCouplers.inhibitionInterlayer = clampValue(
                b * (1 + 0.5 * q / 100), 0.0, 1.5)
            edit.filmRender.dirCouplers.active = q != 0 ? true : baseline.filmRender.dirCouplers.active
        case "grain_amount":
            // 与原生 quick_controls.expected_values 对齐：强度轴只动密度地板与均匀度。
            let grain = baseline.filmRender.grain
            let t = clampValue(q / 100, -1, 1)
            edit.filmRender.grain.densityMin = grain.densityMin.map {
                clampValue($0 * (1 + 0.9 * t), 0.005, 0.08)
            }
            edit.filmRender.grain.uniformity = grain.uniformity.map {
                clampValue($0 - 0.06 * t, 0.90, 0.995)
            }
            edit.filmRender.grain.active = q <= -99 ? false : grain.active
        case "grain_size":
            // 原生独立轴：颗粒面积与边缘柔化。此前把尺寸混进强度轴，
            // 会让拉高强度时颗粒变粗、变锐，和原生不一致。
            let grain = baseline.filmRender.grain
            edit.filmRender.grain.particleAreaUM2 = clampValue(
                grain.particleAreaUM2 * pow(2, 0.9 * q / 100), 0.02, 0.8)
            edit.filmRender.grain.blur = clampValue(
                grain.blur * (1 + 0.25 * q / 100), 0, 1.5)
        case "scanner_clarity":
            let scanner = baseline.scanner
            if q > 0 {
                let amount = scanner.unsharpMask[1]
                edit.scanner.unsharpMask = [
                    scanner.unsharpMask[0],
                    clampValue(amount + (1.8 - amount) * q / 100, 0, 2),
                ]
                edit.scanner.lensBlur = scanner.lensBlur
            } else {
                edit.scanner.lensBlur = clampValue(scanner.lensBlur + 0.6 * (-q) / 100, 0, 0.8)
                edit.scanner.unsharpMask = scanner.unsharpMask
            }
        case "temperature":
            // 滑条语义：正值 = 更暖。引擎里 yFilterShift 正值偏冷，所以取负。
            // 满量程 60 CC，与原生 PAD_CC_FULL_SCALE 一致。
            edit.enlarger.yFilterShift = clampValue(
                baseline.enlarger.yFilterShift - 60 * q / 100, -60, 60)
        default:
            break
        }
    }

    private func writePro(_ id: String, _ value: Double) {
        Self.writePro(id, value, into: &edit)
    }

    /// 专业滑块的唯一写入实现：实例与直出预设共用。
    nonisolated static func writePro(_ id: String, _ value: Double, into edit: inout PhotoEdit) {
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
            edit.loadRaw.temperature = clampValue(value, 1000, 10000)
        case "white_balance_tint":
            edit.loadRaw.tint = clampValue(value, 0.5, 2.0)
        case "crop_center_x":
            edit.io.cropCenter = pair(edit.io.cropCenter, replacing: 0, with: clampValue(value, 0, 1), fallback: 0.5)
        case "crop_center_y":
            edit.io.cropCenter = pair(edit.io.cropCenter, replacing: 1, with: clampValue(value, 0, 1), fallback: 0.5)
        case "crop_size_x":
            edit.io.cropSize = pair(edit.io.cropSize, replacing: 0, with: clampValue(value, 0.1, 1), fallback: 0.1)
        case "crop_size_y":
            edit.io.cropSize = pair(edit.io.cropSize, replacing: 1, with: clampValue(value, 0.1, 1), fallback: 0.1)
        case "upscale_factor":
            edit.io.upscaleFactor = clampValue(value, 1, 4)
        default: break
        }
    }

    /// 把二元组（裁切中心/大小）的第 index 项替换掉，长度不足时先补成 fallback 对。
    nonisolated private static func pair(_ values: [Double], replacing index: Int,
                                         with value: Double, fallback: Double) -> [Double] {
        var pair = values.count == 2 ? values : [fallback, fallback]
        pair[index] = value
        return pair
    }

    nonisolated private static func pairComponent(_ values: [Double], _ index: Int,
                                                  _ fallback: Double) -> Double {
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
        case "crop_center_x": return Self.pairComponent(edit.io.cropCenter, 0, 0.5)
        case "crop_center_y": return Self.pairComponent(edit.io.cropCenter, 1, 0.5)
        case "crop_size_x": return Self.pairComponent(edit.io.cropSize, 0, 0.1)
        case "crop_size_y": return Self.pairComponent(edit.io.cropSize, 1, 0.1)
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
        padX = clampValue((edit.enlarger.yFilterShift - baseline.enlarger.yFilterShift) / 60 * 100, -100, 100)
        padY = clampValue((edit.enlarger.mFilterShift - baseline.enlarger.mFilterShift) / 60 * 100, -100, 100)
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
        frozenQuickAxes = Set(edit.frozenQuick ?? [])
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

    private func clampValue(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    nonisolated private static func clampValue(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    /// 黑白模式：按目标色彩空间的亮度权重把 RGB 归一成灰。
    /// 只发生在显影结果之后，不改变任何核心显影参数。
    nonisolated static func monochrome(_ image: ImageRGB, colorSpace: String) -> ImageRGB {
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
        case "tile": return "分带显影"
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
///
/// 大图不再一刀切降采样：先判断当前可用内存能否一次算完整张图；
/// 不够就改用「分带显影」——内存只跟条带高度有关，像素数不再被内存卡死。
/// 只有连分带都放不下（例如同时开了超大半径柔光镜）才退回按余量钳位。
enum ExportEdge {
    /// 单像素峰值估算（含阶段缓冲）。12 MP 单张实测（含工具持有的源图）约 109 B/px，
    /// 这里取 110 B/px；分带后每条带实际更低，同一口径偏保守。
    private static let pipelineBytesPerPixel = 110.0
    /// 解码临时峰值：RGBAf 16 B/px + 目标缓冲 12 B/px + Core Image 内部余量。
    private static let decodeBytesPerPixel = 44.0
    /// 编码峰值：成图 12 B/px + 16-bit 编码缓冲。编码发生在条带释放之后，单独核算。
    private static let encodeBytesPerPixel = 36.0
    /// 调色台导出额外的工作缓冲（GradeEngine 的 Double 工作图 + Float 局部滤波）。
    /// 34 MP 实测峰值常驻 1.76 GB，折算约 52 B/px，取 58 B/px 留余量。
    private static let gradeBytesPerPixel = 58.0
    /// 只使用可用内存的 60%，其余留给系统、SwiftUI 与突发分配。
    /// 之前取 0.72 时，12 MP 直出峰值可冲到 1.1 GB，iOS 会压缩页面造成严重卡顿。
    private static let safetyFraction = 0.6

    struct Plan {
        /// 实际输出长边。
        var edge: Int
        /// true：分带显影；false：整张一次算。
        var tiled: Bool
        /// 分带时每条带的目标像素数（含上下重叠）。
        var bandPixelBudget: Int
        var haloRows: Int
        var bandCount: Int
        /// 实际输出小于用户选择的尺寸。
        var clamped: Bool

        /// 调色是否走分带：分带显影时必走分带调色；整张显影但长边达到 2800
        /// （约 5 MP 起）也走分带——分带调色现在按带并行，比整幅串行快得多，
        /// 内存峰值还更低。阈值以下小图串行整幅更划算。
        /// 普通导出与直出共用这一条决策，避免两条链路分叉。
        var usesBandedGrade: Bool { tiled || edge >= 2800 }
    }

    /// 用户选定的档位换算成长边，不做内存钳位。
    static func requested(index: Int, originalLongEdge: Int) -> Int {
        switch index {
        case 1: return min(2048, max(1, originalLongEdge))
        case 2: return min(4096, max(1, originalLongEdge))
        default: return max(1, originalLongEdge)
        }
    }

    /// - Parameter banded: 解码与调色都按带处理（峰值只跟带高有关），
    ///   大图不再需要整图 RGBAf 与整图 Double 工作缓冲。
    /// - Parameter encodeBytesPerPixel: 编码阶段每像素峰值；JPEG 约 8，16-bit TIFF/EXR 约 24。
    static func plan(index: Int, originalLongEdge: Int, params: RuntimePhotoParams,
                     aspect: Double = 0.75, includeGrade: Bool = false,
                     peakLimit: Double? = nil, banded: Bool = false,
                     encodeBytesPerPixel: Double? = nil) -> Plan {
        let requestedEdge = requested(index: index, originalLongEdge: originalLongEdge)
        let available = Int(os_proc_available_memory())
        guard available > 0 else {
            return Plan(edge: requestedEdge, tiled: false, bandPixelBudget: 0,
                        haloRows: 0, bandCount: 1, clamped: false)
        }
        var budget = Double(available) * safetyFraction
        // 直出等前台即时任务再加一道硬上限：可用内存再多也不一次吃满，
        // 否则 12 MP 峰值会冲到 1.3 GB，iOS 压缩页面时整机就像卡死。
        if let peakLimit, peakLimit > 0 { budget = min(budget, peakLimit) }
        // 「放大」倍率会把输出像素成平方放大；解码仍按原图长边，
        // 所以解码、显影、编码要分别按源像素 / 输出像素核算。
        let upscale = max(params.io.upscaleFactor, 1.0)
        // 长边与短边的比例：像素数 = 长边² × aspect。裁切只会减少像素，
        // 所以用原图比例就是安全上界。
        let aspectRatio = min(max(aspect, 0.2), 1.0)
        func outputEdge(_ sourceEdge: Int) -> Int {
            max(1, Int((Double(sourceEdge) * upscale).rounded(.toNearestOrEven)))
        }
        func sourcePixels(_ edge: Int) -> Double {
            Double(edge) * Double(edge) * aspectRatio
        }
        func outputPixels(_ edge: Int) -> Double {
            let value = Double(outputEdge(edge))
            return value * value * aspectRatio
        }
        func gradePeak(_ edge: Int) -> Double {
            guard includeGrade else { return 0 }
            // 分带调色：原始输入 + Float 成品各一张整图，Double 工作缓冲按带分配；
            // 最多 3 条带并行，每条带含 halo 重叠的 Double + 辅助缓冲留 96 MB。
            if banded {
                return (sourcePixels(edge) + outputPixels(edge)) * 12 + 3 * 96 * 1024 * 1024
            }
            return outputPixels(edge) * gradeBytesPerPixel + 64 * 1024 * 1024
        }
        func singlePassPeak(_ edge: Int) -> Double {
            max(sourcePixels(edge) * decodeBytesPerPixel,
                outputPixels(edge) * pipelineBytesPerPixel) + 64 * 1024 * 1024
        }
        func encodePeak(_ edge: Int) -> Double {
            outputPixels(edge) * (encodeBytesPerPixel ?? Self.encodeBytesPerPixel)
                + 64 * 1024 * 1024
        }
        /// 分带方案。`nil` 表示这张图不能分带（柔光镜核太大）或分带也放不下。
        func tiledPlan(_ edge: Int) -> Plan? {
            guard !params.camera.diffusionFilter.active,
                  !params.enlarger.diffusionFilter.active else { return nil }
            let longEdge = outputEdge(edge)
            let pixelSize = SimulationPipeline.exportPixelSizeUM(params: params, outputLongEdge: longEdge)
            let halo = SimulationPipeline.haloRows(for: params, pixelSizeUM: pixelSize)
            // 核比条带还大时分带没有意义，退回整张/钳位。
            guard halo > 0, halo <= 1200 else { return nil }
            let width = longEdge
            let height = longEdge
            let outputCount = outputPixels(edge)
            let fixedBytes = sourcePixels(edge) * 12 + outputCount * 12 + 64 * 1024 * 1024
            let bandBudget = budget - fixedBytes
            guard bandBudget > 160 * 1024 * 1024 else { return nil }
            let bandPixels = max(1_000_000, min(8_000_000,
                                                Int(bandBudget / pipelineBytesPerPixel)))
            let rows = SimulationPipeline.tileRows(outputWidth: width, outputHeight: height,
                                                   haloRows: halo, bandPixelBudget: bandPixels)
            guard rows.bandCount > 1 else { return nil }
            let bandArea = (rows.coreRows + 2 * halo) * width
            let peak = fixedBytes + Double(bandArea) * pipelineBytesPerPixel
            // 分带解码只多一条带的 RGBAf，不再需要整图 44 B/px 的临时缓冲。
            let decodePeak = banded
                ? sourcePixels(edge) * 12 + 160 * 1024 * 1024
                : sourcePixels(edge) * decodeBytesPerPixel + 64 * 1024 * 1024
            guard max(max(max(peak, decodePeak), encodePeak(edge)), gradePeak(edge)) <= budget else {
                return nil
            }
            return Plan(edge: edge, tiled: true, bandPixelBudget: bandPixels,
                        haloRows: halo, bandCount: rows.bandCount, clamped: edge < requestedEdge)
        }

        if max(max(singlePassPeak(requestedEdge), encodePeak(requestedEdge)),
               gradePeak(requestedEdge)) <= budget {
            return Plan(edge: requestedEdge, tiled: false, bandPixelBudget: 0,
                        haloRows: 0, bandCount: 1, clamped: false)
        }
        if let tiled = tiledPlan(requestedEdge) { return tiled }

        // 连分带都放不下：二分出能安全处理的最大长边，保留旧的钳位语义。
        var low = min(512, requestedEdge)
        var high = requestedEdge
        var best: Plan?
        while low <= high {
            let mid = (low + high) / 2
            if max(max(singlePassPeak(mid), encodePeak(mid)), gradePeak(mid)) <= budget {
                best = Plan(edge: mid, tiled: false, bandPixelBudget: 0,
                            haloRows: 0, bandCount: 1, clamped: mid < requestedEdge)
                low = mid + 1
            } else if let tiled = tiledPlan(mid) {
                best = tiled
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if let best { return best }
        let floorEdge = min(1024, requestedEdge)
        return Plan(edge: floorEdge, tiled: false, bandPixelBudget: 0,
                    haloRows: 0, bandCount: 1, clamped: floorEdge < requestedEdge)
    }
}

// MARK: - 直出渲染

/// 直出模式使用的导出参数：直接读取设置页的格式 / 尺寸 / 质量 / 水印。
struct MDirectRenderSettings {
    var format: Int
    var edgeIndex: Int
    var jpegQuality: Double
    var watermark: Bool
    /// 相册不支持 EXR：直出时自动改用 JPEG，并让相机页给出一次说明。
    var downgradedFromEXR: Bool = false

    static func fromPreferences() -> MDirectRenderSettings {
        // 设置页顺序：JPEG / TIFF sRGB / TIFF ProPhoto / EXR；引擎档位：3 / 0 / 1 / 2。
        let formatMap = [3, 0, 1, 2]
        let qualityMap = [1.0, 0.95, 0.9, 0.8]
        let formatIndex = min(max(MobileSettings.defaultExportFormatIndex, 0), formatMap.count - 1)
        let qualityIndex = min(max(MobileSettings.defaultExportQualityIndex, 0), qualityMap.count - 1)
        let isEXR = formatIndex == 3
        return MDirectRenderSettings(
            format: isEXR ? 3 : formatMap[formatIndex],
            edgeIndex: MobileSettings.defaultExportEdgeIndex,
            jpegQuality: qualityMap[qualityIndex],
            watermark: MWatermarkStore.load().enabled,
            downgradedFromEXR: isEXR
        )
    }
}

struct MDirectRenderResult {
    let url: URL
    let preview: CGImage?
    let clampedEdge: Int?
    /// RAW 解码超时/失败后用了内嵌预览：成片分辨率可能低于预期，界面需要说明。
    var usedFallback: Bool = false
}

enum MDirectRenderer {
    enum RenderError: LocalizedError {
        case decodeFailed
        case emptyImage
        case cancelled
        case lut(String)

        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "原片解码失败"
            case .emptyImage: return "渲染结果为空"
            case .cancelled: return "显影已取消"
            case .lut(let message): return message
            }
        }
    }

    /// 直出跟随设置页的默认导出尺寸；原片尺寸读取失败时按 12 MP 兜底。
    static let fallbackDirectEdge = 4032

    /// 直出工程的快速控制基线：拍摄曝光是基线，其它字段保持中性。
    /// 保存原图后再次进入显影台时，快速滑条回到 0 应该回到「拍摄时的曝光」，而不是归零。
    static func makeBaseline(meta: MCameraCaptureMeta) -> PhotoEdit {
        var baseline = PhotoEdit()
        baseline.camera.exposureCompensationEV = min(max(meta.exposureBias, -3), 3)
        return baseline
    }

    /// 把显影预置解析成一份独立的 `PhotoEdit`。只使用默认基线与预设本身，不依赖库内照片。
    ///
    /// 拍摄时的曝光/色温是**基线**：预设里的曝光快速轴 / 曝光补偿专业项在它之上叠加，
    /// 这样「相机里 -1 EV + 预设再压半档」会得到 -1.5 EV，而不是互相覆盖。
    static func makeEdit(builtin: MDevelopPreset?, user: MUserDevelopPreset?,
                         meta: MCameraCaptureMeta = MCameraCaptureMeta()) -> PhotoEdit {
        let captureBaseline = makeBaseline(meta: meta)
        var edit = captureBaseline
        if let kelvin = meta.temperature, kelvin > 0 {
            edit.loadRaw.whiteBalance = "custom"
            edit.loadRaw.temperature = Double(kelvin)
            edit.loadRaw.tint = 1.0
        }
        if let preset = builtin {
            edit.filmStock = preset.filmID
            edit.printStock = preset.paperID
            edit.monochrome = preset.monochrome
            if let profile = try? ProfileStore.load(preset.filmID), profile.info.isPositive {
                edit.io.scanFilm = true
            }
            edit.quickIntents = preset.quick
            for (id, value) in preset.quick where abs(value) > 1e-9 {
                MobileDevelopSession.applyQuickMapping(
                    id: id, q: value, baseline: captureBaseline,
                    quickIntents: preset.quick, edit: &edit
                )
            }
        }
        if let preset = user {
            edit.filmStock = preset.filmID
            edit.printStock = preset.paperID
            edit.monochrome = preset.monochrome
            if let profile = try? ProfileStore.load(preset.filmID), profile.info.isPositive {
                edit.io.scanFilm = true
            }
            for (id, value) in preset.pro {
                switch value {
                case .number(let number):
                    // 曝光补偿是「拍摄基线 + 预设调整」，其余参数仍然是预设的绝对值。
                    let adjusted = id == "exposure_compensation_ev"
                        ? QuickExposureMapping.presetExposure(
                            absolute: number,
                            savedBaseline: preset.exposureBaselineEV,
                            currentBaseline: captureBaseline.camera.exposureCompensationEV,
                            captureBias: meta.exposureBias)
                        : number
                    MobileDevelopSession.writePro(id, adjusted, into: &edit)
                case .flag(let flag):
                    MobileDevelopSession.writeProToggle(id, flag, into: &edit)
                case .option(let option):
                    MobileDevelopSession.writeProChoice(id, option, into: &edit)
                }
            }
            var frozen = Set(edit.frozenQuick ?? [])
            for id in preset.pro.keys {
                frozen.formUnion(MobileDevelopSession.quickAxes(affectedByPro: id))
            }
            edit.frozenQuick = frozen.isEmpty ? nil : frozen.sorted()
        }
        return edit
    }

    /// 把片边合成进已经渲染好的成片：解码编码图 → 合成 → 按原格式重写。
    /// 这条路径不接触 RAW，也不需要显影，所以直出成片页改片边是秒级操作。
    nonisolated static func compositeBorder(
        renderedURL: URL, config: MFilmBorderConfig,
        filmID: String, photoID: String, jpegQuality: Double,
        dateLabel: String = "", timeLabel: String = ""
    ) -> URL? {
        let value = config.normalized()
        guard value.enabled else { return nil }
        guard let loaded = try? ImageLoader.load(
            url: renderedURL, maxSize: nil, allowEncoded: true) else { return nil }
        var output = loaded.image
        output = MFilmBorderRenderer.composite(
            image: output, config: value, filmID: filmID, photoID: photoID,
            colorSpace: loaded.colorSpace, cctfEncoding: loaded.cctfDecoding,
            dateLabel: dateLabel, timeLabel: timeLabel)
        let ext = renderedURL.pathExtension.lowercased()
        let bitDepth = (ext == "jpg" || ext == "jpeg") ? 8 : 16
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-bordered-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        do {
            try ImageExport.save(output, to: destination, bitDepth: bitDepth,
                                 colorSpace: loaded.colorSpace,
                                 cctfEncoding: loaded.cctfDecoding,
                                 jpegQuality: jpegQuality)
            return destination
        } catch {
            return nil
        }
    }

    static func render(sourceURL: URL, edit: PhotoEdit, grade: GradeRecipe,
                       settings: MDirectRenderSettings,
                       isCancelled: @escaping () -> Bool = { false },
                       progress: @escaping (Double) -> Void) throws -> MDirectRenderResult {
        func checkCancellation() throws {
            if isCancelled() { throw RenderError.cancelled }
        }
        /// 进度节流：每个阶段最多推 1% 一次，避免高频跨线程写 UI 抢主线程。
        var lastProgress = -1.0
        func emit(_ value: Double) {
            guard value >= 1 || value - lastProgress >= 0.01 else { return }
            lastProgress = value
            progress(value)
        }

        try checkCancellation()
        let size = LibraryStore.pixelSize(url: sourceURL)
        let originalEdge = (size.width > 0 && size.height > 0)
            ? max(max(size.width, size.height), 1)
            : Self.fallbackDirectEdge
        let aspect = (size.width > 0 && size.height > 0)
            ? Double(min(size.width, size.height)) / Double(max(size.width, size.height))
            : 0.75
        var params = try edit.runtimeParams()
        // 解码与调色都按带处理，48 MP 也能把峰值压在一条带 + 整图 Float 上；
        // 上限从 800 MB 放宽到 1.9 GB，6 GB 机型按可用内存 60% 仍会先触顶。
        let plan = ExportEdge.plan(index: settings.edgeIndex,
                                   originalLongEdge: originalEdge,
                                   params: params, aspect: aspect,
                                   includeGrade: true,
                                   peakLimit: 1900 * 1024 * 1024,
                                   banded: true,
                                   // JPEG 编码峰值低；16-bit TIFF / EXR 会多背一份
                                   // 整图编码缓冲，按默认 36 B/px 保守估计。
                                   encodeBytesPerPixel: settings.format == 3 ? 8 : nil)
        let requested = plan.edge
        // CIRAWFilter 每次 render 调用都重跑整幅去马赛克：实测 12 MP
        // 整幅 357ms vs 分带 880ms，分带解码对中小图是负优化。
        // 解码输出 ≤24 MP 时整幅一次渲染；只有 RGBA Float 整图缓冲
        // 过大（≥24 MP，>380 MB）才分带压峰值。
        let decodedPixels = Double(requested * requested) * aspect
        let decodeBandRows = decodedPixels > 24_000_000
            ? max(64, min(512, (64 << 20) / max(1, requested * 16)))
            : nil

        let ext: String
        let bitDepth: Int
        let targetSpace: String
        let targetCCTF: Bool
        switch settings.format {
        case 1:
            targetSpace = "ProPhoto RGB"; targetCCTF = false
            ext = "tif"; bitDepth = 16
        case 2:
            targetSpace = "ACES2065-1"; targetCCTF = false
            ext = "exr"; bitDepth = 16
        case 3:
            targetSpace = "sRGB"; targetCCTF = true
            ext = "jpg"; bitDepth = 8
        default:
            targetSpace = "sRGB"; targetCCTF = true
            ext = "tif"; bitDepth = 16
        }

        // 显影阶段输出线性 ProPhoto，与调色台交接图的色彩空间一致。
        params.io.outputColorSpace = "ProPhoto RGB"
        params.io.outputCCTFEncoding = false
        emit(0.04)

        guard var loaded = autoreleasepool(invoking: {
            try? ImageLoader.load(
                url: sourceURL, maxSize: requested, rawOptions: edit.rawDecoderOptions(),
                rotationTurns: edit.rotationTurns, allowEncoded: true,
                // 直出必须给结果：系统 RAW 支持首次查询可能超时，允许退回内嵌预览，
                // 否则用户只会看到「原片解码失败」。
                rawTimeout: 12, allowPreviewFallback: true,
                bandRows: decodeBandRows
            )
        }) else {
            throw RenderError.decodeFailed
        }
        let usedFallback = loaded.usedFallback
        try checkCancellation()
        params.io.inputColorSpace = loaded.colorSpace
        params.io.inputCCTFDecoding = loaded.cctfDecoding
        let pipeline = SimulationPipeline(params: params, keepTaps: false)
        pipeline.shouldCancel = isCancelled
        var prepared = PreviewRenderer.prepared(loaded.image, maxSize: requested)
        loaded.image = ImageRGB(width: 0, height: 0)
        emit(0.08)

        let result: PipelineResult = autoreleasepool {
            if plan.tiled {
                return pipeline.processTiled(prepared,
                                             bandPixelBudget: plan.bandPixelBudget) { _, current, total in
                    let fraction = total > 0 ? Double(current) / Double(total) : 0
                    emit(0.1 + 0.6 * min(1, fraction))
                }
            } else {
                return pipeline.process(prepared) { _, current, total in
                    let fraction = total > 0 ? Double(current) / Double(total) : 0
                    emit(0.1 + 0.6 * min(1, fraction))
                }
            }
        }
        prepared = ImageRGB(width: 0, height: 0)
        try checkCancellation()
        var developed = result.rgbOut
        guard developed.width > 0, developed.height > 0 else {
            throw RenderError.emptyImage
        }
        if edit.monochrome {
            developed = autoreleasepool {
                MobileDevelopSession.monochrome(developed, colorSpace: "ProPhoto RGB")
            }
        }
        emit(0.7)

        GradeEngine.prepareSourceInPlace(&developed)
        // 大图（含 48 MP）走分带调色：整图 Double 工作缓冲在 48 MP 是 1.17 GB，
        // 6 GB 机型会被系统杀掉，分带后只剩整图 Float + 一条带。
        let bandedGrade = plan.usesBandedGrade
        var graded: GradeRenderResult = try autoreleasepool {
            if bandedGrade {
                return try GradeEngine.renderTiledInPlace(
                    &developed, recipe: grade, bandRows: 256,
                    shouldCancel: isCancelled)
            }
            return try GradeEngine.renderInPlace(&developed, recipe: grade,
                                                 shouldCancel: isCancelled)
        }
        if let lutError = graded.lutError {
            throw RenderError.lut(lutError.errorDescription ?? "LUT 解析失败")
        }
        var output = graded.image
        graded.image = ImageRGB(width: 0, height: 0)
        // 预览必须在转换到导出色彩空间之前生成：ProPhoto / ACES 线性图直接显示会偏色。
        var previewSource = Resize.longEdge(output, maxSize: 1200)
        if settings.watermark {
            // 卡片上也要看到水印；预览用 sRGB 小图合成，成本远低于整图。
            var config = MWatermarkStore.load()
            config.enabled = true
            previewSource = MWatermarkRenderer.composite(
                image: previewSource, config: config,
                colorSpace: "sRGB", cctfEncoding: true
            )
        }
        let preview = PreviewRenderer.cgImage(from: previewSource)
        MobileGradeSession.convertForExport(&output,
                                            colorSpace: targetSpace,
                                            cctfEncoding: targetCCTF)
        emit(0.84)
        try checkCancellation()

        if settings.watermark {
            var config = MWatermarkStore.load()
            config.enabled = true
            MWatermarkRenderer.compositeInPlace(
                &output, config: config,
                colorSpace: targetSpace, cctfEncoding: targetCCTF
            )
        }
        emit(0.92)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try ImageExport.save(output, to: destination, bitDepth: bitDepth,
                             colorSpace: targetSpace, cctfEncoding: targetCCTF,
                             jpegQuality: settings.jpegQuality)

        emit(1.0)
        return MDirectRenderResult(url: destination, preview: preview,
                                   clampedEdge: plan.clamped ? plan.edge : nil,
                                   usedFallback: usedFallback)
    }
}
