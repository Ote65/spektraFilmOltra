import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
#if os(iOS)
import AVFoundation
import CoreMotion
import AudioToolbox
#endif

/// 按下快门那一刻的拍摄参数。RAW 的 EXIF 不一定记录曝光补偿。
/// `exposureBias` 只保存用户的创作意图；系统自动高光保护单独记录，
/// 因为它已经改变传感器实进光量，不能在显影端再当作一次曝光补偿施加。
struct MCameraCaptureMeta: Equatable {
    var exposureBias: Double = 0
    var automaticExposureProtectionEV: Double = 0
    var captureISO: Double? = nil
    var captureExposureDuration: Double? = nil
    /// nil 表示自动白平衡。
    var temperature: Int?
    /// 快门瞬间的握持方向：横拍为 true。成片画幅据此决定，
    /// 不依赖解码后像素的宽高（RAW 的 EXIF 转正会让像素方向判断失准）。
    var capturedLandscape: Bool = false
    /// 前置 + 「镜像前置相机」开：成片镜像为取景所见（预览默认就是镜子），
    /// RAW 原片保持原始数据。缩略图与直出渲染都按这个标志翻转。
    var mirrorFront: Bool = false
}

/// 一次 RAW 拍摄的结果：临时 DNG 文件 + 取景器里用的缩略图。
struct MCameraShot: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: MPlatformImage?
    var meta = MCameraCaptureMeta()
}

/// 相机页的拍摄会话：AVCaptureSession + AVCapturePhotoOutput 的薄封装。
///
/// 两种拍摄格式：RAW（单帧 ProRAW DNG，留给后期）与 HDR（多帧融合处理图，直出成品）。
/// 所有 `@Published` 都在主线程写入；AVFoundation 的配置与启停在 `sessionQueue` 上跑。
final class MCameraSession: NSObject, ObservableObject {
    enum Permission: Equatable {
        case idle
        case requesting
        case authorized
        case denied
    }

    enum FlashMode: String, CaseIterable, Identifiable {
        case off, on

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "关闭"
            case .on: return "开启"
            }
        }

        var symbol: String {
            switch self {
            case .off: return "bolt.slash"
            case .on: return "bolt.fill"
            }
        }
    }

    /// 取景器里的焦段按钮：光学焦段从真实摄像头读取，
    /// 不同机型会得到各自的光学焦段（如 13/26/77 或 13/24/120）；
    /// 光学档位之间再按主摄裁切补 2×、4× 虚拟焦段（48 MP 机型的 2×
    /// 与系统相机的原生主摄裁切是同一条路径）。
    struct Lens: Identifiable, Equatable {
        /// 物理摄像头的 uniqueID；裁切焦段用 "crop-倍数" 合成 id。
        let id: String
        /// 35mm 等效焦距。
        let focal: Int
        /// 相对主摄的显示倍数。
        let zoom: CGFloat
        /// 选中时要在源摄像头上设置的 videoZoomFactor；光学镜头为 1。
        let crop: CGFloat

        init(id: String, focal: Int, zoom: CGFloat, crop: CGFloat = 1) {
            self.id = id
            self.focal = focal
            self.zoom = zoom
            self.crop = crop
        }

        static let placeholder = Lens(id: "wide", focal: 26, zoom: 1)

        var zoomLabel: String {
            let rounded = (zoom * 10).rounded() / 10
            if abs(rounded - rounded.rounded()) < 0.05 {
                return "\(Int(rounded.rounded()))×"
            }
            return String(format: "%.1f×", rounded)
        }
    }

    /// 拍摄格式。两个模式走的是两条系统管线，不能混：
    /// - `raw`：Apple ProRAW 单帧 DNG。只能 `.speed`，拿不到多帧融合，也没有增益图。
    /// - `hdr`：Apple 处理图（HEVC/HEIC），`.quality` 优先级，系统会做多帧融合（Smart HDR / Deep Fusion），
    ///   文件里带 HDR 增益图时由显影端按宽动态重建。直出走这条和 iPhone 原相机的口径一致。
    enum CaptureMode: String, CaseIterable, Identifiable {
        case raw, hdr

        var id: String { rawValue }

        var title: String { self == .raw ? "RAW" : "HDR" }

        var hint: String {
            switch self {
            case .raw: return "RAW：单帧 DNG，留给后期"
            case .hdr: return "HDR：多帧融合 HEIC，直出即成品"
            }
        }
    }

    enum SessionError: LocalizedError {
        case noDevice
        case noRawData
        case noProcessedData


        var errorDescription: String? {
            switch self {
            case .noDevice: return "找不到可用的后置摄像头"
            case .noRawData: return "这张照片没有 RAW 数据，请重试"
            case .noProcessedData: return "这张照片没有生成处理图，请重试"
            }
        }
    }

    @Published private(set) var permission: Permission = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var rawAvailable = false
    /// 设备能否输出处理图（HEVC/HEIC）。绝大多数 iPhone 都可以，模拟器不行。
    @Published private(set) var hdrAvailable = false
    /// 当前拍摄格式（RAW / HDR）。切换会重配 photoOutput，期间快门互锁。
    @Published private(set) var captureMode: CaptureMode = .raw
    /// 正在重配会话（切换 RAW / HDR、换镜头）。不允许按快门。
    @Published private(set) var isReconfiguring = false
    @Published private(set) var hasFlash = false
    /// 光学焦段（DiscoverySession 枚举）+ 主摄裁切焦段（2×/4×）合并后的按钮列表。
    @Published private(set) var availableLenses: [Lens] = [.placeholder]
    /// 当前摄像头可输出的最大照片长边（含 48 MP 高分辨率模式），直出分辨率档位用。
    @Published private(set) var maxPhotoEdge: Int = 0
    /// 正在换物理镜头：交换输入期间禁止快门。
    @Published private(set) var isSwitchingLens = false
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var lastShot: MCameraShot?
    /// 设备 / 环境层面的不可用原因（模拟器、没有摄像头）。
    @Published private(set) var unusableReason: String?
    /// 一次拍摄失败的原因，界面以 toast 呈现。
    @Published private(set) var message: String?

    @Published var flash: FlashMode = .off

    @Published private(set) var lens: Lens = .placeholder
    @Published private(set) var isFront = false
    @Published private(set) var exposureBias: Double = 0
    /// nil 表示自动白平衡。
    @Published private(set) var temperature: Int?
    /// 长按取景框后 AE/AF 进入锁定；此时上下拖动改 ISO。
    @Published private(set) var isExposureLocked = false
    /// 当前 ISO：未锁定时是设备的自动读数，锁定时是手动值。
    @Published private(set) var isoValue: Float = 0

    /// 只有就绪时才允许按快门。RAW 模式还需要设备的 RAW 格式；HDR 走处理图，不需要。
    var canCapture: Bool {
        isRunning && isReadyForCurrentMode && !isCapturing && !isSwitchingLens
            && !isReconfiguring && unusableReason == nil
    }

    /// 当前模式是否具备快门条件。
    var isReadyForCurrentMode: Bool {
        switch captureMode {
        case .raw: return rawAvailable
        case .hdr: return hdrAvailable
        }
    }

    /// 快门被挡住时的说明文案。
    var blockedHint: String {
        if let unusableReason { return unusableReason }
        if permission == .denied { return "没有相机权限，请到系统设置里打开" }
        if isSwitchingLens { return "正在切换镜头" }
        if isReconfiguring { return "正在切换拍摄格式" }
        if isCapturing { return captureMode == .raw ? "正在写入 DNG…" : "正在合成 HDR…" }
        if !isRunning { return "相机还在启动" }
        if !isReadyForCurrentMode {
            return captureMode == .raw ? "这台设备不提供 RAW 拍摄" : "这台设备不支持 HDR 处理图输出"
        }
        return "相机还没准备好"
    }

    var temperatureLabel: String { temperature.map { "\($0)K" } ?? "Auto" }

    var exposureLabel: String { String(format: "%+.1f", exposureBias) }

    #if os(iOS)
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "spektra.camera.meter", qos: .utility)
    private let sessionQueue = DispatchQueue(label: "spektra.camera.session", qos: .userInitiated)
    private var device: AVCaptureDevice?
    /// 当前设备的 RAW 像素格式。主线程专用：sessionQueue 要用时由主线程带进去，
    /// 不要在队列上直接读（会和主线程的发布互相踩）。
    private var rawFormat: OSType?
    /// 处理图编码：HEVC → HEIC；没有 HEVC 时退回 JPEG。nil 表示不支持处理图。
    private var hdrCodec: AVVideoCodecType?
    /// 会话首次 configure 时输出自带的默认尺寸档（一般是 12 MP）。sessionQueue 写入。
    /// 切回 RAW 要还原它，而不是把默认档抬到 48 MP——那会把 DNG 解码成本翻好几倍。
    private var baselinePhotoDimensions: CMVideoDimensions?
    private var isConfigured = false
    private var captureDelegate: MCaptureDelegate?
    private var maxZoom: CGFloat = 1
    /// 主线程专用：取景高光估计与用户 EV 分开；只有设备写入成功后才标记已应用值。
    private var protectionState = CaptureExposureProtectionState()
    /// 主线程专用：拍摄格式只在首次 start 时从设置恢复，之后交给徽标切换。
    private var didRestoreMode = false
    private var allowsAutomaticProtection = true
    /// 使已经排队的旧曝光写入失效。跨主线程 / sessionQueue 读取由锁保护。
    private let exposureGenerationLock = NSLock()
    private var exposureGeneration = 0
    private var lastMeterTimestamp = 0.0
    /// 当前方向的主摄，失败时回退到它。主线程专用：configure 的结果经
    /// pendingWideDevice 在 startSession 发布，flip 在主线程回调里更新。
    private var wideDevice: AVCaptureDevice?
    /// 焦段 → 物理摄像头。主线程专用。
    private var lensDevices: [String: AVCaptureDevice] = [:]
    /// 切换失败过的摄像头：后续重建焦段列表时不再出现。
    /// sessionQueue 专用：failSwitch 异步写入，configure / flip 只在 sessionQueue 读。
    private var failedLensIDs: Set<String> = []
    /// configure 在 sessionQueue 上构建，startSession 再回主线程发布。
    private var pendingLenses: [Lens] = []
    private var pendingLensDevices: [String: AVCaptureDevice] = [:]
    /// sessionQueue 专用：首次 configure 的主摄，startSession 回主线程发布为 wideDevice。
    private var pendingWideDevice: AVCaptureDevice?
    /// 镜头切换的代号：超时后作废旧请求，晚到的回调不能再改状态。
    private var lensSwitchToken = 0
    #endif

    override init() {
        super.init()
        #if os(iOS)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = .authorized
        case .notDetermined: permission = .idle
        default: permission = .denied
        }
        #endif
    }

    // MARK: - 生命周期

    func start() {
        #if os(iOS)
        if isSimulator {
            permission = .authorized
            unusableReason = "模拟器没有相机，请在 iPhone 真机上试拍"
            return
        }
        guard unusableReason == nil else { return }

        // 上次用的拍摄格式：HDR 是新的默认口径，用户手动切回 RAW 也会记住。
        // 只恢复一次：之后的模式由徽标切换，不再被冷启动覆盖。
        if !didRestoreMode {
            didRestoreMode = true
            captureMode = MobileSettings.cameraHDR ? .hdr : .raw
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .authorized
            startSession()
        case .notDetermined:
            permission = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permission = granted ? .authorized : .denied
                    if granted { self.startSession() }
                }
            }
        default:
            permission = .denied
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        resetAutomaticProtection()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
        #endif
    }

    // MARK: - 拍摄格式

    /// 切换 RAW / HDR。两种模式在 AVFoundation 里是两套配置
    /// （ProRAW 开关、qualityPrioritization、最大尺寸都不同），
    /// 必须整段拆掉重建，不能只改快门参数。
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode else { return }
        #if os(iOS)
        guard !isCapturing, !isReconfiguring else { return }
        isReconfiguring = true
        MobileSettings.cameraHDR = (mode == .hdr)
        let wasRunning = isRunning
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.teardownConfiguration()
            DispatchQueue.main.async {
                self.captureMode = mode
                self.rawFormat = nil
                self.rawAvailable = false
                self.hdrAvailable = false
                if wasRunning {
                    // isReconfiguring 留到 startSession 发布结果时再放下：
                    // 重建期间快门必须锁住。
                    self.startSession()
                } else {
                    self.isReconfiguring = false
                }
            }
        }
        #else
        captureMode = mode
        #endif
    }

    /// 点一下徽标就切到另一个模式。
    func toggleCaptureMode() {
        setCaptureMode(captureMode == .raw ? .hdr : .raw)
    }

    #if os(iOS)
    /// sessionQueue 调用：拆掉输入输出，让下一次 startSession 按新格式重新 configure。
    private func teardownConfiguration() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()
        device = nil
        hdrCodec = nil
        pendingWideDevice = nil
        isConfigured = false
    }
    #endif

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func startSession() {
        let userEV = exposureBias
        // 拍摄格式与摄像头位置在主线程读一次带进 sessionQueue：
        // configure 依赖它们决定 ProRAW 开关与优先级，切格式不会把前置跳回后置。
        let mode = captureMode
        let position: AVCaptureDevice.Position = isFront ? .front : .back
        // rawFormat 主线程专用：重配时要用上一轮的格式，就在主线程取好带进去。
        let cachedRawFormat = self.rawFormat
        // 启动是生命周期操作：只重置保护状态，不能被之后到达的曝光意图取消。
        resetAutomaticProtection()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var format: OSType?
            var firstConfigure = false
            if !self.isConfigured {
                do {
                    format = try self.configure(mode: mode, position: position)
                    self.isConfigured = true
                    firstConfigure = true
                } catch {
                    DispatchQueue.main.async {
                        self.unusableReason = error.localizedDescription
                        self.permission = .authorized
                        // 配置失败也必须放下重配锁：否则快门和格式徽标会永久卡在「正在切换」。
                        self.isReconfiguring = false
                    }
                    return
                }
            } else {
                format = cachedRawFormat
            }

            // 尺寸档在 configure 的 commit 之后再算：sessionPreset 生效后，
            // device.activeFormat 才是会话真正在用的格式，
            // 这时读 supportedMaxPhotoDimensions 才作数（写错档位会抛异常）。
            if let device = self.device {
                self.applyMaxPhotoDimensions(for: device, mode: mode)
            }

            let hdrReady = self.hdrCodec != nil

            if !self.session.isRunning {
                if let device = self.device {
                    do {
                        try device.lockForConfiguration()
                        self.applyUserExposureBias(userEV, on: device)
                        device.unlockForConfiguration()
                    } catch {}
                }
                self.session.startRunning()
            }
            let running = self.session.isRunning
            let flash = self.device?.hasFlash ?? false
            let zoomLimit = self.device?.activeFormat.videoMaxZoomFactor ?? 1
            let lenses = self.pendingLenses
            let lensMap = self.pendingLensDevices
            let currentLens = self.pendingLens(for: self.device)
            let wide = self.pendingWideDevice
            let maxEdge = self.device.map { Self.maxPhotoLongEdge(of: $0, mode: mode) } ?? 0

            DispatchQueue.main.async {
                self.rawFormat = format
                self.rawAvailable = format != nil
                self.hdrAvailable = hdrReady
                self.hasFlash = flash
                self.maxZoom = zoomLimit
                self.maxPhotoEdge = maxEdge
                if firstConfigure {
                    // wideDevice 只在主线程写：sessionQueue 的结果经 pending 值发布过来。
                    self.wideDevice = wide
                    if !lenses.isEmpty {
                        self.availableLenses = lenses
                        self.lensDevices = lensMap
                        self.lens = currentLens ?? .placeholder
                    }
                }
                self.isRunning = running
                self.isReconfiguring = false
            }
        }
    }

    private func pendingLens(for device: AVCaptureDevice?) -> Lens? {
        guard let device else { return nil }
        return pendingLenses.first { $0.id == device.uniqueID }
    }

    /// 在 sessionQueue 上调用：装配输入 / 输出 / 竖屏方向，返回可用的 RAW 像素格式。
    /// `mode` / `position` 由主线程带进来，决定 ProRAW 开关、优先级、最大尺寸与摄像头，
    /// 不在 sessionQueue 上读 @Published 状态。
    private func configure(mode: CaptureMode, position: AVCaptureDevice.Position) throws -> OSType? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: position)
                ?? AVCaptureDevice.default(for: .video) else {
            throw SessionError.noDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo
        guard session.canAddInput(input) else { throw SessionError.noDevice }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else { throw SessionError.noDevice }
        session.addOutput(photoOutput)

        // 低分辨率取景流只用于高光估计，不参与成片；拿不到时不影响 ProRAW 拍摄。
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // App 只支持竖屏：把输出连接固定成竖拍，拍到的 DNG 不需要再做旋转。
        if let connection = photoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        // 拍摄格式决定 ProRAW 开关：RAW 需要先打开它，格式列表才会出现；
        // HDR 反过来必须关掉——系统规定请求 RAW 时 photoQualityPrioritization 只能是 .speed，
        // 而多帧融合（Smart HDR / Deep Fusion）只在 .quality 下发生。
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = (mode == .raw)
        }

        // 处理图能力：优先 HEVC（编出 HEIC，可能带 HDR 增益图），拿不到退回 JPEG。
        // 两者都没有时 hdrCodec 为 nil，HDR 模式会被标成不可用。
        let codecs = photoOutput.availablePhotoCodecTypes
        hdrCodec = codecs.contains(.hevc) ? .hevc : (codecs.contains(.jpeg) ? .jpeg : nil)
        if hdrCodec != nil {
            // 系统默认是 .balanced，多帧融合在这种优先级下会退化成单帧 + 轻度处理。
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        // 别顺手开 autoDeferredPhotoDeliveryEnabled：开了就必须同时在 MCaptureDelegate 实现
        // photoOutput(_:didFinishCapturingDeferredPhotoProxy:error:)，
        // 否则 capturePhoto 会直接抛 NSInvalidArgumentException（SDK 头文件明写）。
        // 现状是刻意不开：24 MP 档因此会被静默降档到 12 MP 档，
        // 界面也已按 12 MP 上限上报（maxPhotoLongEdge 的 HDR 分支）。

        // 优先 Apple ProRAW：它已经是去过马赛克的线性 DNG，显影时不用现场去马赛克，读取快好几倍；
        // Bayer RAW 虽然更"原始"，但 12MP 去马赛克在 CIRAWFilter 里要几秒，用户会以为卡死。
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        let proRAW = formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let picked: OSType? = mode == .raw ? (proRAW ?? formats.first) : nil

        // 会话默认尺寸档（一般是 12 MP）先记下来：切回 RAW 时要还原它，
        // 否则默认 12 MP 会被悄悄抬到 48 MP（解码成本翻几倍）。
        if baselinePhotoDimensions == nil {
            baselinePhotoDimensions = photoOutput.maxPhotoDimensions
        }
        // 尺寸档不在这里设：configure 的事务还没 commit，device.activeFormat 未必是
        // sessionPreset 选定的那个格式，读它的 supportedMaxPhotoDimensions 可能拿到旧格式的列表。
        // 真正的写入放在 startSession 里、configure 返回之后（已 commit）。

        self.device = device
        self.pendingWideDevice = device
        let built = Self.makeLenses(position: position, wide: device,
                                    excluding: failedLensIDs)
        self.pendingLenses = built.lenses
        self.pendingLensDevices = built.devices
        return picked
    }

    /// 枚举当前方向的物理摄像头，用视场角折算等效焦距。
    /// 不预设任何焦段：机型有什么镜头就生成什么按钮。
    private static func makeLenses(
        position: AVCaptureDevice.Position,
        wide: AVCaptureDevice,
        excluding failed: Set<String>
    ) -> (lenses: [Lens], devices: [String: AVCaptureDevice]) {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: position
        )
        var devices = discovery.devices.filter { $0.isConnected && !$0.isSuspended }
        if !devices.contains(where: { $0.uniqueID == wide.uniqueID }) {
            devices.append(wide)
        }

        let wideFocal = equivalentFocalLength(of: wide)
        let baseFocal = wideFocal > 0 ? wideFocal : 26
        var seen = Set<String>()
        var lenses: [Lens] = []
        var mapping: [String: AVCaptureDevice] = [:]

        for camera in devices {
            guard !failed.contains(camera.uniqueID) else { continue }
            guard seen.insert(camera.uniqueID).inserted else { continue }
            let focal = equivalentFocalLength(of: camera)
            guard focal > 0 else { continue }
            let lens = Lens(id: camera.uniqueID,
                            focal: Int(focal.rounded()),
                            zoom: focal / baseFocal)
            lenses.append(lens)
            mapping[camera.uniqueID] = camera
        }

        // 视场角读取失败时至少保留主摄 1×。
        if !lenses.contains(where: { $0.id == wide.uniqueID }) {
            lenses.append(Lens(id: wide.uniqueID,
                               focal: Int(baseFocal.rounded()),
                               zoom: 1))
            mapping[wide.uniqueID] = wide
        }

        // 在主摄上补裁切变焦：光学档位之间（如 1× 与 3×/5× 之间）插 2×，
        // 只有主摄的老机型在主摄变焦范围内补到 4×。已有接近倍数的光学镜头就不补。
        let wideMaxZoom = max(1, wide.activeFormat.videoMaxZoomFactor)
        let maxOptical = lenses.map { $0.zoom }.max() ?? 1
        for factor: CGFloat in [2, 4] {
            let id = "crop-\(Int(factor))"
            guard factor <= wideMaxZoom, !failed.contains(id) else { continue }
            guard !lenses.contains(where: { abs($0.zoom - factor) < factor * 0.25 }) else { continue }
            if maxOptical > 1.25 {
                // 裁切档位必须明显低于最高的光学档位，否则不如直接用光学。
                guard factor < maxOptical * 0.8 else { continue }
            }
            lenses.append(Lens(id: id, focal: Int((baseFocal * factor).rounded()),
                               zoom: factor, crop: factor))
            mapping[id] = wide
        }

        lenses.sort { $0.focal < $1.focal }
        return (lenses, mapping)
    }

    /// 摄像头可输出的最大照片长边：当前格式支持的尺寸档位取最大
    /// （48 MP 机型这里会包含 8064×6048，普通机型是 4032×3024）。
    /// HDR 处理图拿不到 48 MP 档；而且 24 MP 档不开延迟交付就静默降档，
    /// 所以上报给界面的上限按"实际能落地的档位"算，不让界面承诺 24 MP。
    static func maxPhotoLongEdge(of device: AVCaptureDevice, mode: CaptureMode) -> Int {
        if mode == .hdr {
            let dims = Self.hdrServiceableDimensions(of: device)
            if dims.width > 0 { return max(Int(dims.width), Int(dims.height)) }
        }
        var edge = 0
        for dims in device.activeFormat.supportedMaxPhotoDimensions {
            edge = max(edge, max(Int(dims.width), Int(dims.height)))
        }
        return edge
    }

    /// HDR 处理图在**不开启延迟交付**时实际能落地的最大档位。
    /// SDK 规则（AVCapturePhotoOutput.h）：24 MP（5712×4284）"is only serviced as 24MP
    /// via deferred photo delivery" —— 不开 `autoDeferredPhotoDeliveryEnabled` 时请求 24 MP
    /// 不报错，但交付会降档。所以这里按 12 MP 档（4032×3024 ≈ 12.19 M）算上限，
    /// 宁可少报一档，也不要让界面给出兑现不了的 24 MP 选项。
    /// （定义在下面 hdrServiceableDimensions(of:)。）

    /// 按拍摄格式设置输出的最大照片尺寸。
    /// `photoOutput.maxPhotoDimensions` 是输出级、跨模式共用的：
    /// HDR 会把它抬到 24 MP 档，切回 RAW 必须显式还原会话默认档，
    /// 否则要么 ProRAW 被降档，要么默认 12 MP 被悄悄抬到 48 MP（解码成本翻几倍）。
    ///
    /// 值没变时不重复写：改这个属性会触发捕获渲染管线重配
    /// （SDK 头文件原文：Changing this property may trigger a lengthy reconfiguration of the
    /// capture render pipeline）。换镜头时每写一次就重配一次，白白掉帧。
    private func applyMaxPhotoDimensions(for device: AVCaptureDevice,
                                         mode: CaptureMode) {
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        var target = CMVideoDimensions(width: 0, height: 0)
        if mode == .hdr {
            target = Self.hdrServiceableDimensions(of: device)
        } else {
            let baseline = baselinePhotoDimensions ?? CMVideoDimensions(width: 0, height: 0)
            if baseline.width > 0,
               supported.contains(where: {
                   $0.width == baseline.width && $0.height == baseline.height
               }) {
                target = baseline
            } else if let fallback = supported.filter({
                Int($0.width) * Int($0.height) <= Int(baseline.width) * Int(baseline.height)
            }).max(by: {
                Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
            }), fallback.width > 0 {
                // 换了摄像头，原档位不在它的支持列表里：退到不超过原档的最大可选档。
                target = fallback
            }
        }
        guard target.width > 0 else { return }
        let current = photoOutput.maxPhotoDimensions
        guard current.width != target.width || current.height != target.height else { return }
        photoOutput.maxPhotoDimensions = target
    }

    /// 处理图（非 RAW）在**不开启延迟交付**时能落地的尺寸档。
    /// 48 MP 只对 ProRAW 开放；24 MP（5712×4284）按 SDK 规则
    /// 「is only serviced as 24MP via deferred photo delivery」——
    /// 不开 autoDeferredPhotoDeliveryEnabled 时请求 24 MP 不报错，但拿到的更小。
    /// 所以上限按 12 MP 档（4032×3024 ≈ 12.19 M）算：上报给界面和实际请求用同一个口径。
    /// 没有可选档位时返回 0，表示交回会话默认尺寸，不强行设置 maxPhotoDimensions。
    static func hdrServiceableDimensions(of device: AVCaptureDevice) -> CMVideoDimensions {
        // 允许到 13 M：12 MP 的 12.19 M 放得进，24 MP 的 24.47 M 与 48 MP 的 48.7 M 都挡掉。
        let pixelBudget = 13_000_000
        var best = CMVideoDimensions(width: 0, height: 0)
        for dims in device.activeFormat.supportedMaxPhotoDimensions {
            let pixels = Int(dims.width) * Int(dims.height)
            guard pixels > 0, pixels <= pixelBudget else { continue }
            if pixels > Int(best.width) * Int(best.height) { best = dims }
        }
        return best
    }

    /// 用水平视场角折算 35mm 等效焦距：f = 18 / tan(FOV / 2)。
    private static func equivalentFocalLength(of device: AVCaptureDevice) -> CGFloat {
        let fov = CGFloat(device.activeFormat.videoFieldOfView)
        guard fov > 1, fov < 179 else { return 0 }
        return 18 / tan(fov * .pi / 360)
    }
    #endif

    // MARK: - 拍摄

    #if os(iOS)
    @discardableResult
    private func invalidateExposureWrites() -> Int {
        exposureGenerationLock.lock()
        exposureGeneration &+= 1
        let generation = exposureGeneration
        exposureGenerationLock.unlock()
        return generation
    }

    private func exposureWriteIsCurrent(_ generation: Int) -> Bool {
        exposureGenerationLock.lock()
        defer { exposureGenerationLock.unlock() }
        return generation == exposureGeneration
    }

    private func currentExposureGeneration() -> Int {
        exposureGenerationLock.lock()
        defer { exposureGenerationLock.unlock() }
        return exposureGeneration
    }

    /// 主线程调用：手动 EV、锁定、切镜头或停止时，旧异步曝光写入一律失效。
    @discardableResult
    private func resetAutomaticProtection(allowAutomatic: Bool? = nil) -> Int {
        if let allowAutomatic { allowsAutomaticProtection = allowAutomatic }
        protectionState.reset()
        return invalidateExposureWrites()
    }

    /// sessionQueue 调用，设备已 lockForConfiguration。自动保护已在采集端生效，
    /// 显影端只收到用户 EV，不会重复补偿。
    private func applyUserExposureBias(_ userEV: Double, on device: AVCaptureDevice) {
        let target = min(max(Float(userEV), device.minExposureTargetBias),
                         device.maxExposureTargetBias)
        device.setExposureTargetBias(target)
    }
    #endif

    /// - Parameter onWillCapture: 真实曝光时刻的反馈（音效）。由相机页注入，
    ///   在系统播放快门音、物理闪光点亮的同一刻触发，避免音效比画面早半拍。
    func capture(onWillCapture: (() -> Void)? = nil) {
        #if os(iOS)
        guard canCapture else { return }
        let mode = captureMode
        // 快门这一刻的格式参数先取到本地：settings 在 sessionQueue 上使用，
        // 不能在那边再读 @Published。
        let rawFormat = self.rawFormat
        isCapturing = true
        message = nil
        // 冻结取景测光：已经排队的旧写入不能越过这次快门继续改变目标偏差。
        invalidateExposureWrites()
        let userEV = exposureBias
        let allowsAutomatic = allowsAutomaticProtection && !isExposureLocked

        let settings: AVCapturePhotoSettings
        switch mode {
        case .raw:
            guard let rawFormat else { isCapturing = false; return }
            // 单帧 DNG。系统规定请求 RAW 时 qualityPrioritization 只能是 .speed，
            // 也因此 RAW 这条路永远拿不到多帧融合和增益图——这是硬件管线约束，不是取舍。
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: nil)
            settings.photoQualityPrioritization = .speed
        case .hdr:
            // 编码类型以快门这一刻设备实际支持的为准：换镜头后可用的编码可能变。
            // 传了不支持的 codec，AVFoundation 会直接抛异常而不是返回错误。
            let codecs = photoOutput.availablePhotoCodecTypes
            let codec: AVVideoCodecType? = codecs.contains(.hevc)
                ? .hevc
                : (codecs.contains(.jpeg) ? .jpeg : nil)
            guard let codec else {
                isCapturing = false
                message = "当前镜头不支持 HDR 处理图"
                return
            }
            // 处理图走 .quality：系统才会做多帧融合（Smart HDR / Deep Fusion），
            // 输出的 HEIC 在支持的机型上带 HDR 增益图，显影端按宽动态重建。
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            settings.photoQualityPrioritization =
                photoOutput.maxPhotoQualityPrioritization == .quality ? .quality : .balanced
            // 尺寸直接用输出上那个已被校验过的值：settings 的 maxPhotoDimensions 必须落在
            // 当前 activeFormat 的 supportedMaxPhotoDimensions 里，传一个跨镜头残留的旧值会抛异常。
            // 不显式赋值时系统就是用它，这里显式写等同，只是把语义摆明。
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        }
        // 闪光灯必须显式写到拍摄设置上才會触发；两种模式靠闪光灯照亮的方式一样。
        if hasFlash {
            let flashMode = flash.avMode
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            } else if flash == .on {
                message = "当前设备或模式不支持强制闪光"
            }
        }

        // 拍摄瞬间的重力方向决定出片朝向：横屏拍的 DNG 在快门那一刻就按重力转正，
        // 显影台拿到的是正图，不需要再手动旋转。
        let angle = Self.captureRotationAngle(for: UIDevice.current.orientation)
        // 横拍（0° / 180°）记为横向，成片画幅据此把所选比例旋转过来：
        // 9:16 横拍输出 16:9 横幅。竖向只认 90°/270°，flat 等中间态回退竖幅。
        let capturedLandscape = angle == 0 || angle == 180
        let delegate = MCaptureDelegate(
            meta: MCameraCaptureMeta(
                exposureBias: userEV,
                automaticExposureProtectionEV: 0,
                temperature: temperature,
                capturedLandscape: capturedLandscape,
                mirrorFront: isFront && MobileSettings.cameraMirrorFront),
            isHDR: mode == .hdr,
            onWillCapture: onWillCapture
        ) { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
        captureDelegate = delegate
        sessionQueue.async { [weak self, photoOutput] in
            if let device = self?.device {
                delegate.recordActualExposureBias(
                    device.exposureTargetBias, userEV: userEV,
                    automatic: allowsAutomatic && device.exposureMode == .continuousAutoExposure)
            }
            if let connection = photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                } else {
                    let orientation: AVCaptureVideoOrientation =
                        angle == 0 ? .landscapeRight :
                        angle == 90 ? .portrait :
                        angle == 180 ? .landscapeLeft : .portraitUpsideDown
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = orientation
                    }
                }
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
        #endif
    }

    /// UIDevice 重力方向 → 输出缓冲顺时针转角（AVCam 映射：设备 landscapeLeft 对应缓冲 0°）。
    static func captureRotationAngle(for orientation: UIDeviceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    #if os(iOS)
    private func finish(_ result: Result<MCameraShot, Error>) {
        isCapturing = false
        captureDelegate = nil
        switch result {
        case .success(let shot):
            lastShot = shot
        case .failure(let error):
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
    #endif

    func clearMessage() {
        message = nil
    }

    /// 从系统设置授权返回前台时重新对齐权限，并补一次启动。
    func refreshPermission() {
        #if os(iOS)
        guard !isSimulator else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard permission != .authorized else { return }
            permission = .authorized
            start()
        case .denied, .restricted:
            permission = .denied
        case .notDetermined:
            permission = .idle
        @unknown default:
            break
        }
        #endif
    }

    // MARK: - 控制

    func cycleFlash() {
        guard hasFlash else { return }
        let all = FlashMode.allCases
        let index = all.firstIndex(of: flash) ?? 0
        flash = all[(index + 1) % all.count]
    }

    /// 选焦段：光学按钮对应一颗真实摄像头，裁切按钮落在主摄的变焦倍率上。
    func select(_ lens: Lens) {
        #if os(iOS)
        guard !isSwitchingLens, let target = lensDevices[lens.id] else { return }
        if device === target {
            applyNativeZoom(for: lens)
        } else {
            switchInput(to: lens, target: target)
        }
        #endif
    }

    #if os(iOS)
    private func applyNativeZoom(for lens: Lens) {
        guard let device else { return }
        let limit = max(1, device.activeFormat.videoMaxZoomFactor)
        let factor = min(max(1, lens.crop), limit)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        } catch {
            return
        }
        zoom = device.videoZoomFactor
        maxZoom = limit
        self.lens = lens
    }

    /// 换物理镜头：重挂输入后重新确认 RAW 格式，失败就退回主摄。
    /// HDR 模式不要求 RAW 格式（走处理图），只有 RAW 模式才把「没有 RAW 格式」当失败。
    private func switchInput(to lens: Lens, target: AVCaptureDevice) {
        isSwitchingLens = true
        let userEV = exposureBias
        let restoreManualExposure = !allowsAutomaticProtection || abs(userEV) > 0.001
        // 拍摄格式在主线程读一次带进 sessionQueue：决定 ProRAW 开关与是否强求 RAW 格式。
        let mode = captureMode
        // 切镜头不是曝光写入：代际变化只该作废旧曝光任务，不能取消切换本身。
        resetAutomaticProtection()
        lensSwitchToken += 1
        let token = lensSwitchToken

        // 坏镜头可能在换输入时卡住：超时直接移除该焦段并恢复 UI，主线程始终不等它。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.lensSwitchToken == token, self.isSwitchingLens else { return }
            self.failSwitch(to: lens)
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let previous = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
                  let next = try? AVCaptureDeviceInput(device: target) else {
                DispatchQueue.main.async { self.failSwitch(to: lens) }
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(previous)
            guard self.session.canAddInput(next) else {
                self.session.addInput(previous)
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.failSwitch(to: lens) }
                return
            }
            self.session.addInput(next)
            // 换设备后格式列表会重算：RAW 打开 ProRAW；HDR 必须关掉，否则优先级被锁成 .speed。
            if self.photoOutput.isAppleProRAWSupported {
                self.photoOutput.isAppleProRAWEnabled = (mode == .raw)
            }
            self.session.commitConfiguration()

            let formats = self.photoOutput.availableRawPhotoPixelFormatTypes
            let raw = mode == .raw
                ? (formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? formats.first)
                : nil
            // 只有 RAW 模式才要求拿到 RAW 格式。
            guard mode == .hdr || raw != nil else {
                self.session.beginConfiguration()
                self.session.removeInput(next)
                if self.session.canAddInput(previous) {
                    self.session.addInput(previous)
                }
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.failSwitch(to: lens) }
                return
            }

            if let connection = self.photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }

            let limit = max(1, target.activeFormat.videoMaxZoomFactor)
            let factor = min(max(1, lens.crop), limit)
            // 新镜头的支持档位可能不同：按格式重设最大尺寸，HDR 档位要带回去写进 settings。
            self.applyMaxPhotoDimensions(for: target, mode: mode)
            do {
                try target.lockForConfiguration()
                target.videoZoomFactor = factor
                if restoreManualExposure {
                    self.applyUserExposureBias(userEV, on: target)
                }
                target.unlockForConfiguration()
            } catch {
                // 输入已经切好，倍率保持现状也能拍。
            }
            let appliedZoom = target.videoZoomFactor

            DispatchQueue.main.async {
                guard self.lensSwitchToken == token else { return }
                self.isSwitchingLens = false
                self.device = target
                self.rawFormat = raw
                // raw 在 HDR 模式下是 nil：这里按实际拿到的格式发布，不能硬写成 true。
                self.rawAvailable = raw != nil
                self.hasFlash = target.hasFlash
                self.maxZoom = limit
                self.maxPhotoEdge = Self.maxPhotoLongEdge(of: target, mode: self.captureMode)
                self.zoom = appliedZoom
                self.lens = lens
            }
        }
    }

    /// 主线程调用：撤销切换、发布失败提示；failedLensIDs 的回写走 sessionQueue。
    private func failSwitch(to lens: Lens) {
        lensSwitchToken += 1
        resetAutomaticProtection()
        isSwitchingLens = false
        if lens.id == wideDevice?.uniqueID {
            message = "镜头切换失败"
        } else {
            // 失败的光学焦段从列表移除，后续翻转镜头也不再出现。
            sessionQueue.async { self.failedLensIDs.insert(lens.id) }
            availableLenses.removeAll { $0.id == lens.id }
            lensDevices[lens.id] = nil
            message = "\(lens.focal)mm 镜头不可用"
        }
        restoreWideInput()
    }

    /// 失败后回到当前方向的主摄 1×。
    private func restoreWideInput() {
        guard let wide = wideDevice else { return }
        let userEV = exposureBias
        let generation = currentExposureGeneration()
        // 拍摄格式在主线程读一次带进 sessionQueue：回退后要按它重设最大尺寸档。
        let mode = captureMode
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation) else { return }
            guard let current = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first else { return }
            if current.device === wide {
                do {
                    try wide.lockForConfiguration()
                    wide.videoZoomFactor = 1
                    self.applyUserExposureBias(userEV, on: wide)
                    wide.unlockForConfiguration()
                } catch {}
                DispatchQueue.main.async {
                    self.zoom = 1
                    self.applyWideLensState()
                }
                return
            }
            guard let input = try? AVCaptureDeviceInput(device: wide) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()

            // 换设备后格式列表会重算，Key 的 ProRAW 开关按当前拍摄格式重设；
            // 最大尺寸档也跟着新设备的支持列表重设。
            if self.photoOutput.isAppleProRAWSupported {
                self.photoOutput.isAppleProRAWEnabled = (mode == .raw)
            }
            self.applyMaxPhotoDimensions(for: wide, mode: mode)

            if let connection = self.photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }

            let formats = self.photoOutput.availableRawPhotoPixelFormatTypes
            // 拍摄格式决定要不要 RAW：HDR 走处理图，不该把 Bayer 格式写进 rawFormat。
            let raw = mode == .raw
                ? (formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? formats.first)
                : nil
            let limit = max(1, wide.activeFormat.videoMaxZoomFactor)
            do {
                try wide.lockForConfiguration()
                wide.videoZoomFactor = 1
                self.applyUserExposureBias(userEV, on: wide)
                wide.unlockForConfiguration()
            } catch {}

            DispatchQueue.main.async {
                self.device = wide
                if let raw {
                    self.rawFormat = raw
                    self.rawAvailable = true
                }
                self.hasFlash = wide.hasFlash
                self.maxZoom = limit
                self.maxPhotoEdge = Self.maxPhotoLongEdge(of: wide, mode: self.captureMode)
                self.zoom = 1
                self.applyWideLensState()
            }
        }
    }

    private func applyWideLensState() {
        guard let wide = wideDevice,
              let wideLens = availableLenses.first(where: { $0.id == wide.uniqueID }) else { return }
        lens = wideLens
    }
    #endif

    /// 前后摄像头切换。RAW 模式前置多数机型不提供 ProRAW，切不过去时退回后置并提示；
    /// HDR 走处理图，没有 RAW 也能正常切。
    func flip() {
        #if os(iOS)
        guard isRunning, !isCapturing, !isSwitchingLens, !isReconfiguring, let current = device else {
            return
        }
        let target: AVCaptureDevice.Position = current.position == .front ? .back : .front
        guard let next = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target),
              let input = try? AVCaptureDeviceInput(device: next) else {
            message = "找不到可用的摄像头"
            return
        }
        // 拍摄格式在主线程带进 sessionQueue：决定 ProRAW 开关与是否要求 RAW 格式。
        let mode = captureMode
        // 找到目标摄像头后才重置状态：失败时曝光标签与设备实际偏差保持一致。
        isSwitchingLens = true
        let previousEV = exposureBias
        let previousAllowsAutomatic = allowsAutomaticProtection
        exposureBias = 0
        resetAutomaticProtection(allowAutomatic: true)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let previous = self.session.inputs.first

            self.session.beginConfiguration()
            if let previous { self.session.removeInput(previous) }
            let attached = self.session.canAddInput(input)
            if attached { self.session.addInput(input) }
            // 换设备后格式列表会重算，ProRAW 开关按当前拍摄格式重设：
            // RAW 要打开才有格式；HDR 必须关掉，否则 qualityPrioritization 被限制成 .speed。
            if self.photoOutput.isAppleProRAWSupported {
                self.photoOutput.isAppleProRAWEnabled = (mode == .raw)
            }
            self.session.commitConfiguration()

            let formats = attached ? self.photoOutput.availableRawPhotoPixelFormatTypes : []
            let proRAW = formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            let picked: OSType? = mode == .raw ? (proRAW ?? formats.first) : nil

            // 只有 RAW 模式才要求设备给得出 RAW 格式：前置多数机型没有 ProRAW，
            // 那种情况下把后置装回去。HDR 走处理图，前置一样能拍。
            guard mode == .hdr || picked != nil else {
                self.session.beginConfiguration()
                if let failed = self.session.inputs.first { self.session.removeInput(failed) }
                if let previous, self.session.canAddInput(previous) {
                    self.session.addInput(previous)
                }
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.isSwitchingLens = false
                    // 切换失败退回原输入，恢复用户原来的曝光意图与自动保护开关。
                    self.exposureBias = previousEV
                    self.resetAutomaticProtection(allowAutomatic: previousAllowsAutomatic)
                    self.message = target == .front
                        ? "这台 iPhone 的前置镜头不提供 RAW，已切回后置"
                        : "切换摄像头失败"
                }
                return
            }

            if let connection = self.photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }

            let built = Self.makeLenses(position: target, wide: next,
                                        excluding: self.failedLensIDs)
            // 新摄像头的支持档位可能不同：RAW 提回默认档，HDR 设成它自己的 24 MP 档。
            self.applyMaxPhotoDimensions(for: next, mode: mode)

            DispatchQueue.main.async {
                self.isSwitchingLens = false
                self.device = next
                self.wideDevice = next
                self.isFront = target == .front
                self.rawFormat = picked
                // 前置摄像头通常没有 RAW：HDR 模式 picked 也可能是 nil。
                self.rawAvailable = picked != nil
                self.hasFlash = next.hasFlash
                self.maxZoom = next.activeFormat.videoMaxZoomFactor
                self.maxPhotoEdge = Self.maxPhotoLongEdge(of: next, mode: self.captureMode)
                self.availableLenses = built.lenses
                self.lensDevices = built.devices
                self.lens = built.lenses.first(where: { $0.id == next.uniqueID }) ?? .placeholder
                self.zoom = 1
                self.exposureBias = 0
                self.temperature = nil
                self.isExposureLocked = false
                self.flash = next.hasFlash ? self.flash : .off
            }
        }
        #endif
    }

    /// 曝光补偿按 -1 → -0.5 → 0 → +0.5 → +1 循环（快捷按钮用）。
    func cycleExposure() {
        let steps: [Double] = [-1, -0.5, 0, 0.5, 1]
        let index = steps.firstIndex { abs($0 - exposureBias) < 0.01 } ?? 2
        setExposureBias(steps[(index + 1) % steps.count])
    }

    func setExposureBias(_ value: Double) {
        #if os(iOS)
        guard device != nil else { return }
        let clamped = min(max(value, -3), 3)
        exposureBias = clamped
        // 非零 EV 是持续的手动意图；显式回到 0 才恢复自动高光保护。
        let generation = resetAutomaticProtection(allowAutomatic: clamped == 0)
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.exposureMode != .continuousAutoExposure,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                self.applyUserExposureBias(clamped, on: device)
                device.unlockForConfiguration()
            } catch {
                return
            }
            let iso = device.iso
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.isExposureLocked = false
                self.isoValue = iso
            }
        }
        #endif
    }

    /// 取景分析在主线程做时间平滑，再到会话串行队列设置目标偏差。
    /// 代际校验保证旧帧不能覆盖手动 EV、AE 锁定、手动 ISO 或快门状态。
    private func updateAutomaticProtection(_ analysis: SceneExposureAnalysis) {
        guard allowsAutomaticProtection, !isExposureLocked, !isCapturing,
              !isSwitchingLens, isRunning else { return }
        let target = SceneExposureAnalysis.captureProtectionEV(analysis)
        let quantized = protectionState.proposedEV(target: target)
        guard quantized != protectionState.appliedEV else { return }
        let userEV = exposureBias
        let generation = currentExposureGeneration()
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device,
                  device.exposureMode == .continuousAutoExposure else { return }
            let total = min(max(Float(userEV + quantized),
                                device.minExposureTargetBias),
                            device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(total)
                device.unlockForConfiguration()
            } catch { return }
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.protectionState.markApplied(quantized)
            }
        }
    }

    /// 色温按 自动 → 3200K → 4300K → 5600K → 7000K 循环。
    func cycleTemperature() {
        let steps: [Int?] = [nil, 3200, 4300, 5600, 7000]
        let index = steps.firstIndex { $0 == temperature } ?? 0
        setTemperature(steps[(index + 1) % steps.count])
    }

    /// nil 表示回到自动白平衡；否则按开尔文锁定白平衡。
    func setTemperature(_ kelvin: Int?) {
        #if os(iOS)
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if let kelvin {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(kelvin), tint: 0
                )
                var gains = device.deviceWhiteBalanceGains(for: values)
                let limit = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), limit)
                gains.greenGain = min(max(gains.greenGain, 1), limit)
                gains.blueGain = min(max(gains.blueGain, 1), limit)
                try device.setWhiteBalanceModeLocked(with: gains)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            return
        }
        #endif
        temperature = kelvin
    }

    /// `point` 是 AVCaptureVideoPreviewLayer 的设备坐标（左上 0,0）。
    func focus(at point: CGPoint) {
        #if os(iOS)
        guard device != nil else { return }
        let userEV = exposureBias
        let generation = resetAutomaticProtection(allowAutomatic: true)
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                self.applyUserExposureBias(userEV, on: device)
                device.unlockForConfiguration()
            } catch { return }
            let iso = device.iso
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.isExposureLocked = false
                self.isoValue = iso
            }
        }
        #endif
    }

    /// 长按取景框：锁定当前对焦与曝光，作为上下拖动改 ISO 的起点。
    func lockFocusAndExposure(at point: CGPoint) {
        #if os(iOS)
        guard device != nil else { return }
        let userEV = exposureBias
        let wasLocked = isExposureLocked
        isExposureLocked = true
        let generation = resetAutomaticProtection()
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                self.applyUserExposureBias(userEV, on: device)
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                }
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    if self.exposureWriteIsCurrent(generation) {
                        self.isExposureLocked = wasLocked
                    }
                }
                return
            }
            let iso = device.iso
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.isExposureLocked = true
                self.isoValue = iso
            }
        }
        #endif
    }

    /// 未锁定时直接滑动：只锁曝光以便调 ISO，对焦保持当前模式。
    func lockExposure() {
        #if os(iOS)
        guard device != nil else { return }
        let userEV = exposureBias
        let wasLocked = isExposureLocked
        isExposureLocked = true
        let generation = resetAutomaticProtection()
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                self.applyUserExposureBias(userEV, on: device)
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    if self.exposureWriteIsCurrent(generation) {
                        self.isExposureLocked = wasLocked
                    }
                }
                return
            }
            let iso = device.iso
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.isExposureLocked = true
                self.isoValue = iso
            }
        }
        #endif
    }

    /// 锁定后上下拖动：保持当前快门，只改 ISO（夹在格式的感光度范围内）。
    func setISO(_ value: Float) {
        #if os(iOS)
        guard device != nil, isExposureLocked else { return }
        let generation = invalidateExposureWrites()
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device,
                  device.isExposureModeSupported(.custom) else { return }
            let upper = min(device.activeFormat.maxISO, 6400)
            let clamped = min(max(value, device.activeFormat.minISO), upper)
            let duration = device.exposureDuration
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: duration, iso: clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { return }
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.isoValue = clamped
            }
        }
        #endif
    }

    /// 点按取景框时解除 AE/AF 锁定，回到连续自动。
    func releaseLock() {
        #if os(iOS)
        guard device != nil else { return }
        let userEV = exposureBias
        let generation = resetAutomaticProtection(allowAutomatic: true)
        sessionQueue.async { [weak self] in
            guard let self, self.exposureWriteIsCurrent(generation),
                  let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                self.applyUserExposureBias(userEV, on: device)
                device.unlockForConfiguration()
            } catch { return }
            let iso = device.iso
            DispatchQueue.main.async {
                guard self.exposureWriteIsCurrent(generation) else { return }
                self.isExposureLocked = false
                self.isoValue = iso
            }
        }
        #endif
    }
}

#if os(iOS)
extension MCameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite, timestamp - lastMeterTimestamp >= 0.20 else { return }
        lastMeterTimestamp = timestamp
        guard let analysis = MCameraPreviewMeter.analysis(from: sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.updateAutomaticProtection(analysis)
        }
    }
}

/// 取景 BGRA → 约 64 px 的线性 sRGB 代理图。只抽样，不创建全尺寸 CI 中间图。
private enum MCameraPreviewMeter {
    static func analysis(from sampleBuffer: CMSampleBuffer) -> SceneExposureAnalysis? {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixels)?
                .assumingMemoryBound(to: UInt8.self) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixels)
        let sourceHeight = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard sourceWidth > 0, sourceHeight > 0, stride >= sourceWidth * 4 else { return nil }
        let stepX = max(1, sourceWidth / 64)
        let stepY = max(1, sourceHeight / 64)
        let width = (sourceWidth + stepX - 1) / stepX
        let height = (sourceHeight + stepY - 1) / stepY
        var proxy = ImageRGB(width: width, height: height)
        for y in 0..<height {
            let sourceY = min(sourceHeight - 1, y * stepY + stepY / 2)
            for x in 0..<width {
                let sourceX = min(sourceWidth - 1, x * stepX + stepX / 2)
                let p = sourceY * stride + sourceX * 4
                let b = ColorMath.cctfDecode(Double(base[p]) / 255, kind: .srgb)
                let g = ColorMath.cctfDecode(Double(base[p + 1]) / 255, kind: .srgb)
                let r = ColorMath.cctfDecode(Double(base[p + 2]) / 255, kind: .srgb)
                proxy.setPixel(x, y, Vec3(r, g, b))
            }
        }
        return SceneExposureAnalysis.analyze(
            image: proxy, colorSpace: "sRGB", applyCCTFDecoding: false)
    }
}
#endif

#if os(iOS)
private extension MCameraSession.FlashMode {
    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .on: return .on
        }
    }
}

/// AVCapturePhotoOutput 的代理：把 RAW 数据落到临时 DNG，并顺手取一张缩略图。
private final class MCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<MCameraShot, Error>) -> Void
    /// 这次请求的是处理图（HDR）还是 RAW。决定接受哪种数据、落什么扩展名。
    private let isHDR: Bool
    /// 快门按下时的曝光/色温：异步回调里不能再读已经变化的相机状态。
    private var meta: MCameraCaptureMeta
    /// 真实曝光时刻的反馈回调。系统在这个回调之后立刻播系统快门音、点亮物理闪光，
    /// 所以自定义音效必须放在这里触发，才不会比真实闪光早半拍。
    private let onWillCapture: (() -> Void)?
    private var finished = false

    init(meta: MCameraCaptureMeta, isHDR: Bool, onWillCapture: (() -> Void)?,
         completion: @escaping (Result<MCameraShot, Error>) -> Void) {
        self.meta = meta
        self.isHDR = isHDR
        self.onWillCapture = onWillCapture
        self.completion = completion
    }

    /// capturePhoto 前在 sessionQueue 记录设备实际目标偏差；用户 EV 与自动保护分别入库。
    func recordActualExposureBias(_ bias: Float, userEV: Double, automatic: Bool) {
        meta.automaticExposureProtectionEV = automatic ? Double(bias) - userEV : 0
    }

    /// 系统在这个回调之后才会播放系统快门音。这里释放它的 SystemSound(1108) 资源，
    /// 让系统音哑掉，只留下 App 自己的快门/闪光音效——否则两个声音会重叠成双响。
    /// 1108 是 iOS 系统快门音的遗留 ID，社区广泛使用；释放是幂等的，重复拍照安全。
    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        #if os(iOS)
        AudioServicesDisposeSystemSoundID(SystemSoundID(1108))
        #endif
        onWillCapture?()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard !finished else { return }
        finished = true

        if let error {
            completion(.failure(error))
            return
        }
        // RAW 请求应当回 DNG，HDR 请求应当回处理图；两者都不是就是没拿到数据。
        guard photo.isRawPhoto || isHDR, let data = photo.fileDataRepresentation() else {
            completion(.failure(isHDR
                ? MCameraSession.SessionError.noProcessedData
                : MCameraSession.SessionError.noRawData))
            return
        }

        // RAW 落 .dng；HDR 处理图按真实容器落 .heic / .jpg。
        // 扩展名不能靠猜：ImageLoader 用扩展名决定 inputColorSpace 与 HDR 增益图的读取路径。
        let ext = photo.isRawPhoto ? "dng" : Self.processedExtension(for: data)
        let name = "Spektra-\(Self.stamp())-\(Int.random(in: 100...999)).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            completion(.failure(error))
            return
        }
        var actualMeta = meta
        if let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] {
                actualMeta.captureISO = iso.first?.doubleValue
            }
            if let duration = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
                actualMeta.captureExposureDuration = duration.doubleValue
            }
        }
        completion(.success(MCameraShot(
            url: url,
            thumbnail: Self.thumbnail(url: url, mirrored: actualMeta.mirrorFront),
            meta: actualMeta)))
    }

    /// 出片前就失败（如采集被中断）时只会回调这里；不复位的话 `isCapturing` 会永远卡住。
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard let error, !finished else { return }
        finished = true
        completion(.failure(error))
    }

    /// 处理图真实容器：HEVC 编出的是 HEIC，退回 JPEG 时是 JPEG。
    /// 扩展名决定 ImageLoader 的解码路径（HEIC 才读得到 HDR 增益图），
    /// 所以 ImageIO 认不出类型时不能一律写 jpg——按容器盒式嗅探兜底。
    private static func processedExtension(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) as String? else {
            return Self.sniffContainerExtension(data)
        }
        return uti.contains("heic") || uti.contains("heif") ? "heic" : "jpg"
    }

    /// 容器嗅探：ISO-BMFF（HEIF/HEIC）第 4–8 字节是 "ftyp"，紧接着是品牌名；
    /// 其余（JPEG 的 FF D8 也落这里）按 JPEG 记。
    private static func sniffContainerExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12,
              bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 else {
            return "jpg"
        }
        let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
        switch brand {
        case "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1":
            return "heic"
        default:
            return "jpg"
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 只读内嵌预览，避免为了取景器缩略图去解码整张原片。
    /// 前置镜像拍摄时把缩略图翻成预览所见，成片渲染同样会镜像，两边一致。
    /// RAW（DNG）与 HDR（HEIC）走同一条 ImageIO 缩略图路径，不用分模式。
    private static func thumbnail(url: URL, mirrored: Bool) -> MPlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            // 优先用文件内嵌的小预览；只有缺失时才解整张原片，避免快门后立刻吃一大块内存。
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        guard mirrored, let flipped = image.mirroredHorizontally else {
            return MImage.make(cgImage: image)
        }
        return MImage.make(cgImage: flipped)
    }
}
#endif

// MARK: - 水平仪

#if os(iOS)
/// 基于重力投影的相机水平仪：水平模式三横杠，俯拍模式双十字。
///
/// `roll` 已经扣除当前握持方向的旋转，所以水平拿稳时无论竖拍还是横拍都接近 0；
/// 视图再按 `deviceAngle` 旋转，横屏时参考线跟着重力方向转，不会停在竖屏。
@MainActor
final class MLevelMonitor: ObservableObject {
    enum Mode {
        case horizontal
        case topDown
    }

    /// 相对当前握持方向的倾角（度）：水平时为 0，俯拍时是画面内的旋转偏差。
    @Published private(set) var roll: Double = 0
    @Published private(set) var pitch: Double = 0
    @Published private(set) var isLevel = false
    @Published private(set) var mode: Mode = .horizontal
    /// 设备相对竖屏的旋转角（度）：0 / 90 / -90 / 180，供覆盖层整体旋转。
    @Published private(set) var deviceAngle: Double = 0
    /// 世界竖直方向在屏幕上的投影（x 向右、y 向下），俯拍时移动十字像气泡一样浮向高处。
    @Published private(set) var planarTilt = CGSize.zero

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var running = false
    private var hapticArmed = true
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    /// 低通后的重力向量：传感器抖动会让参考线高频跳动，先平滑再算角度。
    private var smoothGravity = SIMD3<Double>(0, 0, 0)
    private var hasSample = false

    /// 水平对齐容差（度）。太严会很难对准，这里按「肉眼可接受」放到 1.6°。
    private static let levelTolerance = 1.6
    private static let levelReleaseTolerance = 3.0
    private static let topDownTolerance = 2.5
    private static let topDownPitch = 85.0

    func start() {
        #if os(iOS)
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        hasSample = false
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        queue.qualityOfService = .userInitiated
        haptic.prepare()
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = SIMD3<Double>(
                Double(motion.gravity.x),
                Double(motion.gravity.y),
                Double(motion.gravity.z)
            )
            Task { @MainActor [weak self] in
                self?.handle(gravity: gravity)
            }
        }
        #endif
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func handle(gravity: SIMD3<Double>) {
        #if os(iOS)
        if hasSample {
            smoothGravity = smoothGravity * 0.78 + gravity * 0.22
        } else {
            smoothGravity = gravity
            hasSample = true
        }
        let g = smoothGravity

        // UIDeviceOrientation.landscapeLeft 是「Home 键在右侧」，对应设备逆时针转 90°，
        // 此时屏幕平面里的重力投影是 +90°，所以补偿角取 +90；右侧横屏反之。
        let angle: Double
        switch UIDevice.current.orientation {
        case .landscapeLeft: angle = 90
        case .landscapeRight: angle = -90
        case .portraitUpsideDown: angle = 180
        default: angle = 0
        }
        if deviceAngle != angle { deviceAngle = angle }

        // 设备坐标系中的倾角；减去握持方向后才是「相对参考线」的偏差。
        let rawRoll = atan2(-g.x, -g.y) * 180 / .pi
        var tilt = rawRoll - angle
        while tilt > 180 { tilt -= 360 }
        while tilt < -180 { tilt += 360 }
        let newPitch = asin(min(1, max(-1, -g.z))) * 180 / .pi

        // 只在小数点后第二位变化时才发布，减少无意义的 SwiftUI 失效。
        if abs(tilt - roll) > 0.03 { roll = tilt }
        if abs(newPitch - pitch) > 0.03 { pitch = newPitch }
        let planar = CGSize(width: -g.x, height: g.y)
        if abs(planar.width - planarTilt.width) > 0.002
            || abs(planar.height - planarTilt.height) > 0.002 {
            planarTilt = planar
        }

        if mode == .horizontal, newPitch >= 45 {
            mode = .topDown
        } else if mode == .topDown, newPitch < 42 {
            mode = .horizontal
        }

        let aligned: Bool
        switch mode {
        case .horizontal:
            aligned = abs(tilt) <= Self.levelTolerance
        case .topDown:
            aligned = abs(tilt) <= Self.topDownTolerance && newPitch >= Self.topDownPitch
        }

        if aligned, hapticArmed {
            hapticArmed = false
            haptic.impactOccurred(intensity: 0.7)
            haptic.prepare()
        } else if !aligned {
            switch mode {
            case .horizontal where abs(tilt) > Self.levelReleaseTolerance:
                hapticArmed = true
            case .topDown where abs(tilt) > Self.topDownTolerance + 1.0
                || newPitch < Self.topDownPitch - 3:
                hapticArmed = true
            default:
                break
            }
        }

        if isLevel != aligned { isLevel = aligned }
        #endif
    }
}
#else
/// 非 iOS 预览构建的占位：保证 SwiftUI 视图可以编译，不产生任何传感器行为。
@MainActor
final class MLevelMonitor: ObservableObject {
    enum Mode {
        case horizontal
        case topDown
    }

    @Published private(set) var roll: Double = 0
    @Published private(set) var pitch: Double = 0
    @Published private(set) var isLevel = false
    @Published private(set) var mode: Mode = .horizontal
    @Published private(set) var deviceAngle: Double = 0
    @Published private(set) var planarTilt = CGSize.zero

    func start() {}
    func stop() {}
}
#endif
