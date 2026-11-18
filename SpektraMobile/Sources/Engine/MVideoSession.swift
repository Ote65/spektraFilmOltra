import Foundation
import SwiftUI
import AVFoundation
import CoreVideo
import Combine

/// iOS 视频工程仓：持有独立于照片库的 `VideoProjectStore`，
/// 负责把系统相册的视频映射成工程（同一 PHAsset 只导入一次），
/// 并给显影台发放会话。核心渲染全部复用 `Sources/SpektraCore/Video/`。
@MainActor
final class MVideoLibrary: ObservableObject {
    static let shared = MVideoLibrary()

    let store: VideoProjectStore
    private let renderer: VideoRendering

    @Published private(set) var projects: [VideoProject] = []

    private init() {
        store = VideoProjectStore()
        if let metal = try? VideoMetalRenderer() {
            renderer = metal
        } else {
            renderer = MUnavailableVideoRenderer()
        }
        projects = store.projects
    }

    /// 相册视频 → 显影会话。已有工程直接复用（保留上次调好的参数）；
    /// 没有则把下载到临时目录的源文件拷进沙盒，探测元数据后新建工程。
    func session(
        forAssetID assetID: String,
        displayName: String,
        downloadedURL: URL
    ) async throws -> MVideoSession {
        if let existing = store.projects.first(where: { $0.sourceAssetID == assetID }),
           FileManager.default.fileExists(atPath: existing.sourcePath) {
            return MVideoSession(project: existing, renderer: renderer, store: store)
        }

        let id = UUID().uuidString
        let copied = try store.copySource(from: downloadedURL, id: id)
        do {
            let info = try await VideoFramePipeline(renderer: renderer).probe(url: copied)
            var project = VideoProject(
                id: id,
                displayName: displayName,
                sourcePath: copied.path,
                duration: info.duration,
                fps: info.fps,
                pixelWidth: info.width,
                pixelHeight: info.height
            )
            project.sourceAssetID = assetID
            project.referenceTime = max(0, info.duration / 2)
            store.add(project)
            projects = store.projects
            return MVideoSession(project: project, renderer: renderer, store: store)
        } catch {
            // 探测失败时把刚拷进来的半成品目录清掉，避免留下打不开的工程。
            store.remove(id)
            projects = store.projects
            throw error
        }
    }

    func refreshProjects() {
        projects = store.projects
    }
}

/// Metal 不可用（极老设备/模拟器异常）时的兜底：显影会明确报错，
/// 绝不静默返回未显影的画面。
private final class MUnavailableVideoRenderer: VideoRendering {
    var hasLUT: Bool { false }
    func installLUT(_ payload: VideoLUTPayload) {}
    func render(source: CVPixelBuffer, destination: CVPixelBuffer,
                uniforms: VideoFrameUniforms, payload: VideoLUTPayload) throws {
        throw VideoError.noMetalDevice
    }
}

/// 视频显影台的一条快速参数轴。字段与 macOS `VideoHost.VideoAxis` 对齐，
/// 数值映射也保持一致（方案：两端同一套 `PhotoEdit`）。
struct MVideoAxis: Identifiable, Hashable {
    let id: String
    let label: String
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let suffix: String
    let value: Double
    let base: Double
    let hint: String

    var isDirty: Bool { abs(value - base) > 1e-9 }

    func text() -> String {
        var s = String(format: "%.\(decimals)f", value)
        if decimals > 0 {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if range.lowerBound < 0, value > 0 { s = "+" + s }
        return s + suffix
    }
}

/// iOS 视频显影会话。
///
/// 交互契约与 macOS 一致：**播放中不显影，只在暂停/seek 停下后对当前帧
/// 做一次单帧显影**；参数改动只重显影当前帧；确认后点「渲染视频」跑全片。
@MainActor
final class MVideoSession: ObservableObject {
    @Published private(set) var project: VideoProject
    @Published private(set) var edit: PhotoEdit

    // 单帧显影
    @Published private(set) var stillImage: MPlatformImage?
    @Published private(set) var isDevelopingStill = false
    @Published private(set) var stillRevision = 0
    /// 当前显影帧对应的时间点；与 `currentTime` 不一致时 UI 继续显示原片，避免串帧。
    @Published private(set) var stillTime: Double = -1
    @Published private(set) var status = ""

    // 播放 / 进度
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
    /// 预览抽帧分辨率：1 = 完整，0.5 = 1/2，0.25 = 1/4。只影响预览，不影响成片。
    @Published var previewScale: Double = 0.5 {
        didSet { if !isPlaying { scheduleStillDevelop() } }
    }
    @Published private(set) var seekVersion = 0
    @Published private(set) var seekTarget: Double = 0

    // 导出
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = VideoProgress()

    let sourceURL: URL
    let exporter: VideoExporter

    private let store: VideoProjectStore
    private let pipeline: VideoFramePipeline
    private let baseline: PhotoEdit
    private var setupCache: VideoFramePipeline.RenderSetup?
    private var stillTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false

    var duration: Double { max(0.01, project.duration) }
    var fps: Double { project.fps > 0 ? project.fps : 24 }

    init(project: VideoProject, renderer: VideoRendering, store: VideoProjectStore) {
        self.project = project
        self.edit = project.edit
        self.baseline = project.edit
        self.store = store
        self.sourceURL = project.sourceURL
        self.pipeline = VideoFramePipeline(renderer: renderer)
        self.exporter = VideoExporter(renderer: renderer)

        exporter.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.exportProgress = value }
            .store(in: &cancellables)
    }

    // MARK: - 启动

    func start() async {
        guard !didStart else { return }
        didStart = true
        currentTime = 0
        seekTarget = 0
        seekVersion += 1
        await developCurrentStill()
    }

    // MARK: - 参数轴（与 macOS 视频台同表）

    func videoAxes() -> [MVideoAxis] {
        [
            // 显影组：纯 uniform 轴，与 macOS `VideoHost.videoAxisGroups()` 的
            // 「显影」组逐条对齐（影调组属于调色台，iOS 版不做）。
            MVideoAxis(id: "develop_strength", label: "显影强度",
                       range: 0...100, step: 1, decimals: 0, suffix: "%",
                       value: edit.quickIntents["develop_strength"] ?? VideoFramePipeline.defaultDevelopStrength,
                       base: VideoFramePipeline.defaultDevelopStrength,
                       hint: "与原始画面的混合比例：100% 完整显影，0% 即原片"),
            MVideoAxis(id: "dynamic_range", label: "动态范围",
                       range: 0...100, step: 1, decimals: 0, suffix: "%",
                       value: edit.quickIntents["dynamic_range"] ?? VideoFramePipeline.defaultDynamicRange,
                       base: VideoFramePipeline.defaultDynamicRange,
                       hint: "胶片宽容度：压高光、抬阴影，两端细节更多"),
            MVideoAxis(id: "camera_exposure", label: "拍摄曝光",
                       range: -3...3, step: 0.05, decimals: 2, suffix: " EV",
                       value: edit.camera.exposureCompensationEV, base: 0,
                       hint: "整片锁定的曝光偏移"),
            MVideoAxis(id: "print_brightness", label: "印相亮度",
                       range: -2...2, step: 0.05, decimals: 2, suffix: "",
                       value: -log2(max(edit.enlarger.printExposure, 0.125)), base: 0,
                       hint: "相纸曝光，影响整体明度"),
            // 以下四条来自照片快速模式：落到 PhotoEdit 深层字段，改一次要重烘 LUT，
            // 所以比纯 uniform 轴慢一拍，但换来的色彩/反差是真实胶片链路的。
            MVideoAxis(id: "tonal_contrast", label: "画面对比度",
                       range: -100...100, step: 1, decimals: 0, suffix: "",
                       value: edit.quickIntents["tonal_contrast"] ?? 0, base: 0,
                       hint: "相纸密度曲线的反差，正值更硬"),
            MVideoAxis(id: "highlight_softening", label: "高光柔和",
                       range: 0...100, step: 1, decimals: 0, suffix: "",
                       value: edit.quickIntents["highlight_softening"] ?? 0, base: 0,
                       hint: "延长高光肩部，压住死白"),
            MVideoAxis(id: "color_density", label: "色彩浓度",
                       range: -100...100, step: 1, decimals: 0, suffix: "",
                       value: edit.quickIntents["color_density"] ?? 0, base: 0,
                       hint: "染料层间抑制，越高色越浓"),
            MVideoAxis(id: "temperature", label: "印相冷暖",
                       range: -100...100, step: 1, decimals: 0, suffix: "",
                       value: edit.quickIntents["temperature"] ?? 0, base: 0,
                       hint: "相纸滤色偏置，正值偏暖"),
            MVideoAxis(id: "grain_amount", label: "胶片颗粒",
                       range: 0...400, step: 10, decimals: 0, suffix: "%",
                       value: edit.quickIntents["grain_amount"] ?? 100, base: 100,
                       hint: "逐帧独立的密度域颗粒，100% 为标准"),
            MVideoAxis(id: "grain_size", label: "颗粒尺寸",
                       range: -100...100, step: 1, decimals: 0, suffix: "",
                       value: edit.quickIntents["grain_size"] ?? 0, base: 0,
                       hint: "团簇大小，越细越接近扫描件"),
            MVideoAxis(id: "halation_amount", label: "光晕",
                       range: 0...1, step: 0.05, decimals: 2, suffix: "",
                       value: edit.filmRender.halation.halationAmount,
                       base: baseline.filmRender.halation.halationAmount,
                       hint: "高光暖色扩散"),
            MVideoAxis(id: "diffusion", label: "柔光",
                       range: 0...1, step: 0.05, decimals: 2, suffix: "",
                       value: edit.camera.diffusionFilter.strength, base: 0,
                       hint: "镜头柔焦强度"),
            MVideoAxis(id: "scanner_clarity", label: "清晰度",
                       range: 0...1, step: 0.05, decimals: 2, suffix: "",
                       value: edit.scanner.unsharpMask.count > 1 ? edit.scanner.unsharpMask[1] : 0, base: 0,
                       hint: "扫描反锐化，过高会放大颗粒"),
        ]
    }

    func applyQuick(_ key: String, value: Double) {
        var e = edit
        switch key {
        // 落到深层字段的轴：视频渲染在 `frameUniforms` 里直接读这些字段。
        case "camera_exposure":
            e.camera.exposureCompensationEV = min(max(value, -3), 3)
        case "print_brightness":
            e.enlarger.printExposure = max(0.125, min(8, pow(2, -value)))
        case "halation_amount":
            e.filmRender.halation.halationAmount = min(max(value, 0), 1)
            e.filmRender.halation.active = value > 0
        case "diffusion":
            e.camera.diffusionFilter.active = value > 0
            e.camera.diffusionFilter.strength = min(max(value, 0), 1)
        case "scanner_clarity":
            let radius = e.scanner.unsharpMask.count > 0 ? e.scanner.unsharpMask[0] : 0.7
            e.scanner.unsharpMask = [radius, min(max(value, 0), 1)]
        case "grain_amount":
            // 颗粒幅度由 `VideoGrainModel` 按 quickIntents 的百分比现算；
            // 这里不再硬编码 particleAreaUM2，否则会把「颗粒尺寸」轴的选择覆盖掉。
            e.filmRender.grain.active = value > 0
        // 显影 / 宽容度 / 画面对比度 / 色彩浓度 / 印相冷暖 / 高光柔和 / 颗粒尺寸：
        // 全部由 `frameUniforms` 从 quickIntents 取值。视频 LUT 烘焙时这些字段被
        // 显式归零（见 PreviewLUTService.makeBakeParams），写深层字段既不会改变
        // LUT，也不会改变画面——以前正是因此"滑条动了但画面没反应"。
        default:
            break
        }
        e.quickIntents[key] = value
        commitEdit(e)
    }

    func setFilm(_ id: String) {
        var e = edit
        e.filmStock = id
        commitEdit(e, rebakeLUT: true)
    }

    func setPaper(_ id: String) {
        var e = edit
        e.printStock = id
        commitEdit(e, rebakeLUT: true)
    }

    func resetParameters() {
        commitEdit(baseline, rebakeLUT: true)
    }

    func setCodec(_ codec: VideoCodec) {
        var p = project
        p.exportSettings.codec = codec
        project = p
        store.update(p)
    }

    /// - Parameter rebakeLUT: 只有改胶片/相纸/重置这类进入 LUT 的字段才需要重烘。
    ///   参数轴全部走 uniform 或现算模型，重烘 65³ LUT 只会让拖动卡住。
    private func commitEdit(_ e: PhotoEdit, rebakeLUT: Bool = false) {
        edit = e
        var p = project
        p.edit = e
        project = p
        store.update(p)
        if rebakeLUT {
            setupCache = nil
        }
        // 参数改动只重显影当前帧（暂停状态下），不碰全片。
        scheduleStillDevelop()
    }

    // MARK: - 播放状态（由播放器视图回调）

    func playerDidPause(at time: Double) {
        isPlaying = false
        currentTime = min(max(0, time), duration)
        scheduleStillDevelop()
    }

    func playerDidStart() {
        isPlaying = true
        stillTask?.cancel()
    }

    func togglePlay() {
        if isPlaying {
            pausePlayback()
        } else {
            playerDidStart()
        }
    }

    func pausePlayback() {
        guard isPlaying else { return }
        isPlaying = false
        scheduleStillDevelop()
    }

    func seek(to time: Double) {
        let t = min(max(0, time), duration)
        currentTime = t
        seekTarget = t
        seekVersion += 1
        if !isPlaying { scheduleStillDevelop() }
    }

    // MARK: - 单帧显影

    /// 防抖后对当前帧显影一次。参数连续拖动时只跑最后一次。
    func scheduleStillDevelop() {
        stillTask?.cancel()
        stillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await self?.developCurrentStill()
        }
    }

    func developCurrentStill() async {
        guard !isPlaying, !isScrubbing else { return }
        isDevelopingStill = true
        defer { isDevelopingStill = false }

        let time = currentTime
        let sourceEdge = max(project.pixelWidth, project.pixelHeight)
        // 完整档直接用源尺寸；1/2、1/4 档缩小抽帧，显影更快。
        let edge = previewScale >= 0.999
            ? sourceEdge
            : max(320, Int(Double(sourceEdge) * previewScale))

        do {
            let setup = try await preparedSetup()
            try Task.checkCancellation()
            guard let cg = try await pipeline.developStill(
                url: sourceURL,
                at: time,
                setup: setup,
                frameIndex: Int(time * fps),
                maxEdge: edge,
                // 当前 edit 必须显式传入：参数轴不重烘 LUT，
                // setup.edit 还是上次烘焙时的快照，不传就永远是旧参数。
                edit: edit
            ) else { return }
            try Task.checkCancellation()
            stillImage = MImage.make(cgImage: cg)
            stillTime = time
            stillRevision += 1
            status = "已显影 \(String(format: "%.2f", time))s 单帧 · \(cg.width)×\(cg.height)"
        } catch is CancellationError {
            // 参数还在拖，等下一次防抖结果。
        } catch {
            status = "单帧显影失败：\(error.localizedDescription)"
            NSLog("MStill failed t=%.2f %@", time, error.localizedDescription)
        }
    }

    /// 参考帧测光 + LUT 烘焙只做一次；参数改动会清缓存。
    private func preparedSetup() async throws -> VideoFramePipeline.RenderSetup {
        if let setupCache { return setupCache }
        let reference = min(max(0, project.referenceTime), max(0, project.duration - 0.05))
        let cg = try await pipeline.referenceFrame(url: sourceURL, at: reference)
        let ev = cg.map { pipeline.measureEV(cgImage: $0, method: edit.camera.autoExposureMethod) } ?? 0
        let setup = try pipeline.prepareSetup(
            edit: edit,
            autoEV: ev,
            longEdge: max(project.pixelWidth, project.pixelHeight),
            clipID: project.id
        )
        setupCache = setup
        return setup
    }

    // MARK: - 全片渲染

    /// 返回是否成功。成功后由界面负责写入系统相册。
    func renderFull(destination: URL) async -> Bool {
        guard !isExporting else { return false }
        isExporting = true
        isPlaying = false
        defer { isExporting = false }

        do {
            let setup = try await preparedSetup()
            try await exporter.export(
                project: project,
                source: sourceURL,
                destination: destination,
                autoEV: setup.autoEV,
                longEdge: max(project.pixelWidth, project.pixelHeight)
            )
            status = "渲染完成：\(destination.lastPathComponent)"
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func cancelExport() {
        exporter.cancel()
    }
}
