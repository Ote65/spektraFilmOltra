import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CoreVideo
import Combine

/// Metal 不可用时的空实现：导出会明确报错，不静默产出错误视频。
private final class UnavailableMetalRenderer: VideoRendering {
    var hasLUT: Bool { false }
    func installLUT(_ payload: VideoLUTPayload) {}
    func render(source: CVPixelBuffer, destination: CVPixelBuffer,
                uniforms: VideoFrameUniforms, payload: VideoLUTPayload) throws {
        throw VideoError.noMetalDevice
    }
}

/// macOS 视频显影台会话。
///
/// 预览策略（用户要求）：**播放中不显影，只在暂停/seek 停下后对当前帧做单帧显影**。
/// 参数改动只重显影当前这一帧；确认满意后再点「开始渲染」跑全片导出。
/// 这样交互期间不会逐帧吃 GPU。
@MainActor
final class VideoHost: ObservableObject {
    static let shared = VideoHost()

    @Published private(set) var projects: [VideoProject] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var status = "视频库已就绪"
    @Published private(set) var exportProgress = VideoProgress()
    @Published private(set) var batchFailures: [(String, String)] = []
    @Published private(set) var isBusy = false

    // 单帧显影状态
    @Published private(set) var stillImage: NSImage?
    @Published private(set) var isDevelopingStill = false
    @Published private(set) var stillRevision = 0
    /// 当前显影帧对应的时间点；与 currentTime 不一致时 UI 继续显示原片，避免串帧。
    @Published private(set) var stillTime: Double = -1
    /// 当前显影帧对应的**原片帧**（与显影帧同一次解码）。暂停时先把它垫在播放器上，
    /// 显影帧在它上面渐显，过渡的就是同一张图，不会带上相邻帧的重影。
    @Published private(set) var stillBase: NSImage?
    /// 这张原片帧对应的时间点；与 currentTime 不一致时隐藏，避免拿旧帧盖新时间。
    @Published private(set) var stillBaseTime: Double = -1
    /// 当前显影帧的实际像素尺寸（随预览档位变化）。
    @Published private(set) var stillPixelSize = ""
    /// 起播前把显影帧淡回「同一帧的原片」，淡完才真正 play；播放器在这段时间保持冻结。
    @Published private(set) var isReturningToOriginal = false
    /// 显影帧淡入/淡回原片的时长，视图动画必须与它一致。
    static let stillFadeDuration: Double = 0.30
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false

    /// 预览渲染分辨率：1 = 完整，0.5 = 1/2，0.25 = 1/4。只影响预览抽帧，不影响成片。
    @Published var previewScale: Double = 0.5 {
        didSet { if !isPlaying { scheduleStillDevelop() } }
    }

    /// 视频缩略图（库网格用），按工程 ID 缓存磁盘路径。
    @Published private(set) var thumbnails: [String: String] = [:]

    let store: VideoProjectStore
    private let renderer: VideoRendering
    let exporter: VideoExporter
    private let pipeline: VideoFramePipeline
    private var cancellables = Set<AnyCancellable>()
    private var setupCache: [String: VideoFramePipeline.RenderSetup] = [:]
    private var stillTask: Task<Void, Never>?
    private var playGateTask: Task<Void, Never>?
    /// 暂停时从播放器取到的那一帧像素：显影和调参都直接复用它，不再重新解码。
    private var pausedBuffer: CVPixelBuffer?
    private var pausedBufferTime: Double = -1

    /// 当前工程的编辑参数（UI 直接绑定）。
    @Published private(set) var edit = PhotoEdit()
    private var baseline = PhotoEdit()

    init() {
        self.store = VideoProjectStore()
        do {
            self.renderer = try VideoMetalRenderer()
        } catch {
            self.renderer = UnavailableMetalRenderer()
        }
        self.exporter = VideoExporter(renderer: self.renderer)
        self.pipeline = VideoFramePipeline(renderer: self.renderer)
        self.projects = store.projects
        if let first = projects.first { selectedID = first.id }
        reloadEdit()
        loadThumbnailIndex()
        self.exporter.$progress
            .receive(on: RunLoop.main)
            .assign(to: \.exportProgress, on: self)
            .store(in: &cancellables)
    }

    // MARK: - 选择 / 编辑

    var current: VideoProject? {
        guard let id = selectedID else { return nil }
        return store.project(id: id)
    }

    func currentFilmName(_ id: String? = nil) -> String {
        PreviewData.presets.films.first { $0.id == (id ?? edit.filmStock) }?.name ?? (id ?? edit.filmStock)
    }
    func currentPaperName(_ id: String? = nil) -> String {
        PreviewData.presets.papers.first { $0.id == (id ?? edit.printStock) }?.name ?? (id ?? edit.printStock)
    }

    func select(id: String) {
        guard selectedID != id else { return }
        playGateTask?.cancel()
        playGateTask = nil
        isReturningToOriginal = false
        pausedBuffer = nil
        pausedBufferTime = -1
        selectedID = id
        currentTime = 0
        isPlaying = false
        stillImage = nil
        stillBase = nil
        stillTime = -1
        setupCache.removeValue(forKey: id)
        reloadEdit()
    }

    private func reloadEdit() {
        edit = current?.edit ?? PhotoEdit()
        baseline = edit
    }

    // MARK: - 缩略图（库网格与视频卡片共用）

    private var thumbnailDirectory: URL {
        store.root.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    func thumbnailURL(id: String) -> URL {
        thumbnailDirectory.appendingPathComponent("\(id).jpg")
    }

    private func loadThumbnailIndex() {
        var map: [String: String] = [:]
        for p in store.projects {
            let url = thumbnailURL(id: p.id)
            if FileManager.default.fileExists(atPath: url.path) { map[p.id] = url.path }
        }
        thumbnails = map
        for p in store.projects where map[p.id] == nil { makeThumbnail(for: p) }
    }

    /// 抽 1/3 处的帧作为卡片缩略图，长边 480，JPEG 落盘。
    private func makeThumbnail(for project: VideoProject) {
        let id = project.id
        let url = project.sourceURL
        let at = project.duration > 0 ? project.duration / 3 : 0
        let dest = thumbnailURL(id: id)
        let dir = thumbnailDirectory
        Task.detached(priority: .utility) { [weak self] in
            let asset = AVAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let t = CMTime(seconds: max(0, at), preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = VideoHost.jpegData(cg) else { return }
            try? data.write(to: dest, options: .atomic)
            await MainActor.run { self?.thumbnails[id] = dest.path }
        }
    }

    nonisolated private static func jpegData(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - 导入

    @discardableResult
    func importVideos(_ urls: [URL]) -> [String] {
        var ids: [String] = []
        for (index, url) in urls.enumerated() {
            let id = UUID().uuidString
            guard let copied = try? store.copySource(from: url, id: id) else {
                status = "导入失败：\(url.lastPathComponent)"
                continue
            }
            ids.append(id)
            let isFirst = index == 0
            Task { [weak self] in
                guard let self else { return }
                do {
                    let info = try await self.pipeline.probe(url: copied)
                    await MainActor.run {
                        var project = VideoProject(
                            id: id, displayName: url.deletingPathExtension().lastPathComponent,
                            sourcePath: copied.path, duration: info.duration, fps: info.fps,
                            pixelWidth: info.width, pixelHeight: info.height)
                        project.referenceTime = info.duration / 2
                        self.store.add(project)
                        self.refresh()
                        self.makeThumbnail(for: project)
                        self.status = "已导入 \(urls.count) 个视频"
                        if isFirst { self.select(id: id) }
                    }
                } catch {
                    await MainActor.run { self.status = "读取失败：\(error.localizedDescription)" }
                }
            }
        }
        return ids
    }

    private func refresh() { projects = store.projects }

    func remove(id: String) {
        store.remove(id)
        setupCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: thumbnailURL(id: id))
        thumbnails.removeValue(forKey: id)
        refresh()
        if selectedID == id {
            selectedID = projects.first?.id
            currentTime = 0
            stillImage = nil
            stillBase = nil
            stillTime = -1
            reloadEdit()
        }
    }

    // MARK: - 视频专用参数

    struct VideoAxis: Identifiable, Hashable {
        let id: String
        let label: String
        let range: ClosedRange<Double>
        let step: Double
        let decimals: Int
        let suffix: String
        let value: Double
        let hint: String
        /// 中性值：显影强度 100%、动态范围 35% 等有各自默认的轴据此判定是否已调。
        var neutral: Double = 0

        var isDirty: Bool { abs(value - neutral) > 1e-9 }

        func text() -> String {
            let v = abs(value) < step / 2 ? 0 : value
            var s = String(format: "%.\(decimals)f", v)
            if decimals > 0 {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            if range.lowerBound < 0, v > 0 { s = "+" + s }
            return s + suffix
        }
    }

    struct VideoAxisGroup: Identifiable {
        let id: String
        let title: String
        let axes: [VideoAxis]
    }

    /// 右侧 Inspector 的轴：显影 / 影调 / 质感三组。
    /// 前两组全部走 uniform，拖动只重显影当前帧，不重烘 LUT。
    func videoAxisGroups() -> [VideoAxisGroup] {
        let q = edit.quickIntents
        let develop = q["develop_strength"] ?? VideoFramePipeline.defaultDevelopStrength
        let dynamic = q["dynamic_range"] ?? VideoFramePipeline.defaultDynamicRange

        func grade(_ key: String) -> Double { q[key] ?? 0 }

        return [
            VideoAxisGroup(id: "develop", title: "显影", axes: [
                VideoAxis(id: "develop_strength", label: "显影强度",
                          range: 0...100, step: 1, decimals: 0, suffix: "%",
                          value: develop, hint: "与原始画面的混合比例：100% 完整显影，0% 即原片",
                          neutral: VideoFramePipeline.defaultDevelopStrength),
                VideoAxis(id: "dynamic_range", label: "动态范围",
                          range: 0...100, step: 1, decimals: 0, suffix: "%",
                          value: dynamic, hint: "胶片宽容度：压高光、抬阴影，两端细节更多",
                          neutral: VideoFramePipeline.defaultDynamicRange),
                VideoAxis(id: "camera_exposure", label: "拍摄曝光",
                          range: -3...3, step: 0.05, decimals: 2, suffix: " EV",
                          value: edit.camera.exposureCompensationEV, hint: "整片锁定的曝光偏移"),
                VideoAxis(id: "print_brightness", label: "印相亮度",
                          range: -2...2, step: 0.05, decimals: 2, suffix: "",
                          value: -log2(max(edit.enlarger.printExposure, 0.125)), hint: "相纸曝光，影响整体明度"),
            ]),
            VideoAxisGroup(id: "tone", title: "影调", axes: [
                VideoAxis(id: "grade_contrast", label: "对比",
                          range: -100...100, step: 1, decimals: 0, suffix: "",
                          value: grade("grade_contrast"), hint: "以中灰为轴，负数降对比"),
                VideoAxis(id: "grade_shadows", label: "阴影",
                          range: -100...100, step: 1, decimals: 0, suffix: "",
                          value: grade("grade_shadows"), hint: "正向提亮暗部，负向压暗"),
                VideoAxis(id: "grade_highlights", label: "高光",
                          range: -100...100, step: 1, decimals: 0, suffix: "",
                          value: grade("grade_highlights"), hint: "负向压回高光细节，正向提亮"),
                VideoAxis(id: "grade_blacks", label: "黑色",
                          range: -100...100, step: 1, decimals: 0, suffix: "",
                          value: grade("grade_blacks"), hint: "抬升或压死黑场"),
                VideoAxis(id: "grade_whites", label: "白色",
                          range: -100...100, step: 1, decimals: 0, suffix: "",
                          value: grade("grade_whites"), hint: "白点亮度"),
                VideoAxis(id: "grade_saturation", label: "饱和",
                          range: -100...100, step: 1, decimals: 0, suffix: "",
                          value: grade("grade_saturation"), hint: "按 Rec.709 亮度保真调整饱和度"),
            ]),
            VideoAxisGroup(id: "texture", title: "质感", axes: [
                VideoAxis(id: "grain_amount", label: "胶片颗粒",
                          range: 0...400, step: 10, decimals: 0, suffix: "%",
                          value: edit.quickIntents["grain_amount"] ?? 100, hint: "逐帧独立的密度域颗粒，100% 为标准",
                          neutral: 100),
                VideoAxis(id: "halation_amount", label: "光晕",
                          range: 0...3, step: 0.05, decimals: 2, suffix: "",
                          value: edit.filmRender.halation.halationAmount, hint: "高光暖色扩散"),
                VideoAxis(id: "diffusion", label: "柔光",
                          range: 0...1.5, step: 0.05, decimals: 2, suffix: "",
                          value: edit.camera.diffusionFilter.strength, hint: "镜头柔焦强度"),
                VideoAxis(id: "scanner_clarity", label: "清晰度",
                          range: 0...2, step: 0.05, decimals: 2, suffix: "",
                          value: edit.scanner.unsharpMask[1], hint: "扫描反锐化，过高会放大颗粒"),
            ]),
        ]
    }

    /// 只改 uniform 的轴：不重烘 LUT，滑条即时应答。
    private static let uniformOnlyKeys: Set<String> = [
        "develop_strength", "dynamic_range",
        "grade_contrast", "grade_shadows", "grade_highlights",
        "grade_blacks", "grade_whites", "grade_saturation",
    ]

    func applyQuick(_ key: String, value: Double) {
        var e = edit
        switch key {
        case "develop_strength", "dynamic_range",
             "grade_contrast", "grade_shadows", "grade_highlights",
             "grade_blacks", "grade_whites", "grade_saturation":
            break // 纯 uniform 轴，值直接落到 quickIntents
        case "camera_exposure":
            e.camera.exposureCompensationEV = value
        case "print_brightness":
            e.enlarger.printExposure = max(0.125, min(8, pow(2, -value)))
        case "grain_amount":
            e.filmRender.grain.active = value > 0
            e.filmRender.grain.particleAreaUM2 = 0.4
            e.filmRender.grain.blur = 0.85
        case "halation_amount":
            e.filmRender.halation.halationAmount = max(0, min(3, value))
            e.filmRender.halation.active = value > 0
        case "scanner_clarity":
            e.scanner.unsharpMask = [0.7, max(0, min(2, value))]
        case "diffusion":
            e.camera.diffusionFilter.active = value > 0
            e.camera.diffusionFilter.strength = max(0, min(1.5, value))
        default:
            return
        }
        e.quickIntents[key] = value
        commitEdit(e, affectsLUT: !Self.uniformOnlyKeys.contains(key))
    }

    func setFilm(_ id: String) {
        var e = edit
        e.filmStock = id
        commitEdit(e, affectsLUT: true)
    }

    func setPaper(_ id: String) {
        var e = edit
        e.printStock = id
        commitEdit(e, affectsLUT: true)
    }

    func resetParameters() { commitEdit(baseline, affectsLUT: true) }

    /// 库标记：收藏 / 颜色标签，与照片同一套语义。
    func toggleFavorite(id: String) {
        guard var p = store.project(id: id) else { return }
        p.favorite.toggle()
        store.update(p)
        refresh()
    }

    func setColorLabel(id: String, _ label: ColorLabel?) {
        guard var p = store.project(id: id) else { return }
        p.colorLabel = label?.rawValue
        store.update(p)
        refresh()
    }

    private func commitEdit(_ e: PhotoEdit, affectsLUT: Bool = true) {
        edit = e
        guard var p = current else { return }
        p.edit = e
        store.update(p)
        refresh()
        if affectsLUT { setupCache.removeValue(forKey: p.id) }
        // 参数改动只重显影当前帧（若处于暂停状态），不碰全片。
        scheduleStillDevelop()
    }

    func setCodec(_ codec: VideoCodec) {
        guard var p = current else { return }
        p.exportSettings.codec = codec
        store.update(p)
        refresh()
    }

    // MARK: - 单帧显影（核心）

    /// seek 请求序号：播放器视图据此把 AVPlayer 拖到同一时间点。
    @Published private(set) var seekVersion = 0
    private(set) var seekTarget: Double = 0

    /// 播放器停下/seek 后调用；播放中绝不调用。
    /// `frameBuffer` 传播放器**当前正在显示**那一帧的像素：有它就以它为准冻屏+显影，
    /// 保证渐显的两张图与屏幕上那一帧完全同源；没有则退回按时间重新抽帧。
    func playerDidPause(at time: Double, frameBuffer: CVPixelBuffer? = nil) {
        isPlaying = false
        currentTime = time
        if let frameBuffer, orientationMatches(frameBuffer) {
            pausedBuffer = frameBuffer
            pausedBufferTime = time
            // 立刻冻屏：用这一帧自己的像素替换播放器画面，视觉上无跳变。
            if let cg = pipeline.baseImage(pixelBuffer: frameBuffer, maxEdge: previewEdge()) {
                stillBase = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                stillBaseTime = time
            }
        } else {
            pausedBuffer = nil
            pausedBufferTime = -1
        }
        scheduleStillDevelop(immediate: pausedBuffer != nil)
    }

    /// 显影帧是否该盖在原片上：暂停、且这张显影帧就是当前帧。
    /// 播放中或正在淡回原片的过渡期内一律不盖，避免「渲染帧 ↔ 运动画面」的溶解。
    var showsDevelopedStill: Bool {
        guard !isPlaying, !isReturningToOriginal, stillImage != nil else { return false }
        return abs(stillTime - currentTime) < 0.08
    }

    /// 原片帧是否该垫在播放器上：暂停时用同一像素的帧替代播放器，
    /// 让渐显只发生在同一张图上；起播淡出期间继续垫着，直到真正开始播。
    var showsStillBase: Bool {
        guard !isPlaying, !isScrubbing, stillBase != nil else { return false }
        if isReturningToOriginal { return true }
        return abs(stillBaseTime - currentTime) < 0.08
    }

    /// 播放器帧的朝向是否与工程一致（旋转过的片子退回按时间抽帧，避免方向错）。
    private func orientationMatches(_ buffer: CVPixelBuffer) -> Bool {
        guard let p = current else { return false }
        let bufferLandscape = CVPixelBufferGetWidth(buffer) >= CVPixelBufferGetHeight(buffer)
        return bufferLandscape == (p.pixelWidth >= p.pixelHeight)
    }

    /// 当前预览档位对应的长边。
    private func previewEdge() -> Int? {
        guard let p = current else { return nil }
        let sourceEdge = max(p.pixelWidth, p.pixelHeight)
        return previewScale >= 0.999 ? nil : max(320, Int(Double(sourceEdge) * previewScale))
    }

    func playerDidStart() {
        isPlaying = true
        stillTask?.cancel()
        // 起播后这一帧的缓冲就用不上了，别占着几十 MB。
        pausedBuffer = nil
        pausedBufferTime = -1
    }

    /// 起播只有一条路径：有显影帧时先把显影帧淡回同一帧原片，淡完再 play。
    func togglePlay() {
        // 过渡中再按一次 = 取消起播，退回暂停显影态。
        if isReturningToOriginal {
            playGateTask?.cancel()
            playGateTask = nil
            isReturningToOriginal = false
            return
        }
        guard !isBusy else { return }

        guard showsDevelopedStill else {
            playerDidStart()
            return
        }

        isReturningToOriginal = true
        playGateTask?.cancel()
        playGateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.stillFadeDuration + 0.02) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.playGateTask = nil
            self.isReturningToOriginal = false
            self.playerDidStart()
        }
    }

    func pausePlayback() {
        // 起播过渡中被打断：取消起播，显影帧原样留着。
        playGateTask?.cancel()
        playGateTask = nil
        isReturningToOriginal = false
        guard isPlaying else { return }
        isPlaying = false
        scheduleStillDevelop()
    }

    func seek(to time: Double) {
        currentTime = time
        seekTarget = time
        seekVersion += 1
        if !isPlaying { scheduleStillDevelop() }
    }

    /// 防抖后对当前帧显影一次。参数连续拖动时只跑最后一次；
    /// 暂停那一刻已经有像素缓冲，用最短延迟，让渐显紧跟冻帧。
    func scheduleStillDevelop(immediate: Bool = false) {
        stillTask?.cancel()
        let delay: UInt64 = immediate ? 16_000_000 : 220_000_000
        stillTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self.developCurrentStill()
        }
    }

    func developCurrentStill() async {
        guard let p = current, !isPlaying, !isScrubbing else { return }
        isDevelopingStill = true
        defer { isDevelopingStill = false }
        let time = currentTime
        let source = p.sourceURL
        let scale = previewScale
        let sourceEdge = max(p.pixelWidth, p.pixelHeight)
        // 完整档直接用源尺寸；1/2、1/4 档缩小抽帧，显影更快。
        let edge = scale >= 0.999 ? sourceEdge : max(320, Int(Double(sourceEdge) * scale))
        do {
            let setup: VideoFramePipeline.RenderSetup
            if let cached = setupCache[p.id] {
                setup = cached
            } else {
                let cg = try await pipeline.referenceFrame(url: source, at: p.referenceTime)
                let ev = cg.map { pipeline.measureEV(cgImage: $0, method: p.edit.camera.autoExposureMethod) } ?? 0
                setup = try pipeline.prepareSetup(
                    edit: p.edit, autoEV: ev, longEdge: sourceEdge, clipID: p.id)
                setupCache[p.id] = setup
            }
            // 帧号按四舍五入取整，与导出时的累计帧计数对齐（截断会差半帧）。
            let frameIndex = Int((time * p.fps).rounded())
            // 暂停时拿到的那一帧像素优先：它就是屏幕上冻住的那一帧，显影即所长。
            let pair: (base: CGImage, developed: CGImage)?
            if let buffer = pausedBuffer, abs(pausedBufferTime - time) < 0.02 {
                pair = try pipeline.developStillPair(
                    pixelBuffer: buffer, setup: setup,
                    frameIndex: frameIndex, maxEdge: edge, edit: p.edit)
            } else {
                pair = try await pipeline.developStillPair(
                    url: source, at: time, setup: setup,
                    frameIndex: frameIndex, maxEdge: edge, edit: p.edit)
            }
            guard let pair else { return }
            try Task.checkCancellation()
            await MainActor.run {
                self.stillBase = NSImage(cgImage: pair.base,
                                         size: NSSize(width: pair.base.width, height: pair.base.height))
                self.stillBaseTime = time
                self.stillImage = NSImage(cgImage: pair.developed,
                                          size: NSSize(width: pair.developed.width, height: pair.developed.height))
                self.stillTime = time
                self.stillPixelSize = "\(pair.developed.width)×\(pair.developed.height)"
                self.stillRevision += 1
                self.status = "已显影 \(String(format: "%.2f", time))s 单帧 · \(pair.developed.width)×\(pair.developed.height)"
            }
        } catch is CancellationError {
            // 参数还在拖，等下一次防抖结果。
        } catch {
            await MainActor.run { self.status = "单帧显影失败：\(error.localizedDescription)" }
        }
    }

    // MARK: - 全片渲染

    func renderFull(destination: URL) async {
        guard let p = current else { return }
        isBusy = true
        isPlaying = false
        status = "开始渲染全片…"
        do {
            let cg = try await pipeline.referenceFrame(url: p.sourceURL, at: p.referenceTime)
            let ev = cg.map { pipeline.measureEV(cgImage: $0, method: p.edit.camera.autoExposureMethod) } ?? 0
            try await exporter.export(
                project: p, source: p.sourceURL, destination: destination,
                autoEV: ev, longEdge: max(p.pixelWidth, p.pixelHeight))
            await MainActor.run {
                self.isBusy = false
                self.status = "渲染完成：\(destination.lastPathComponent)"
            }
        } catch {
            await MainActor.run {
                self.isBusy = false
                self.status = error.localizedDescription
            }
        }
    }

    /// 批量：同一参数串行导出；失败不阻塞后续。
    func exportBatch(ids: [String], directory: URL) async {
        batchFailures = []
        let snapshot = projects
        for id in ids {
            guard let p = snapshot.first(where: { $0.id == id }) else { continue }
            selectedID = id
            let name = "\(p.displayName)-film-\(Self.stamp()).\(p.exportSettings.codec.fileExtension)"
            let dest = directory.appendingPathComponent(name)
            do {
                let cg = try await pipeline.referenceFrame(url: p.sourceURL, at: p.referenceTime)
                let ev = cg.map { pipeline.measureEV(cgImage: $0, method: p.edit.camera.autoExposureMethod) } ?? 0
                try await exporter.export(
                    project: p, source: p.sourceURL, destination: dest,
                    autoEV: ev, longEdge: max(p.pixelWidth, p.pixelHeight))
            } catch {
                batchFailures.append((p.displayName, error.localizedDescription))
            }
        }
        status = batchFailures.isEmpty ? "批量渲染完成" : "批量渲染完成，\(batchFailures.count) 个失败"
    }

    func cancelExport() { exporter.cancel() }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
