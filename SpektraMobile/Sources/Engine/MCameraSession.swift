import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
#if os(iOS)
import AVFoundation
import CoreMotion
#endif

/// 按下快门那一刻的拍摄参数。RAW 的 EXIF 不一定记录曝光补偿，
/// 显影管线的自动曝光又会把感光差异归一化掉，所以必须显式带着这一份进入入库/显影。
struct MCameraCaptureMeta: Equatable {
    var exposureBias: Double = 0
    /// nil 表示自动白平衡。
    var temperature: Int?
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
/// 只拍 RAW（DNG）：显影台只接受 RAW，拍完由根视图入库。
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

    enum SessionError: LocalizedError {
        case noDevice
        case noRawData

        var errorDescription: String? {
            switch self {
            case .noDevice: return "找不到可用的后置摄像头"
            case .noRawData: return "这张照片没有 RAW 数据，请重试"
            }
        }
    }

    @Published private(set) var permission: Permission = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var rawAvailable = false
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

    /// 只有就绪且支持 RAW 时才允许按快门。
    var canCapture: Bool {
        isRunning && rawAvailable && !isCapturing && !isSwitchingLens && unusableReason == nil
    }

    var isRawReady: Bool {
        isRunning && rawAvailable && unusableReason == nil
    }

    /// 快门被挡住时的说明文案。
    var blockedHint: String {
        if let unusableReason { return unusableReason }
        if permission == .denied { return "没有相机权限，请到系统设置里打开" }
        if isSwitchingLens { return "正在切换镜头" }
        if isCapturing { return "正在写入 DNG…" }
        if !isRunning { return "相机还在启动" }
        if !rawAvailable { return "这台设备不提供 RAW 拍摄" }
        return "相机还没准备好"
    }

    var temperatureLabel: String { temperature.map { "\($0)K" } ?? "Auto" }

    var exposureLabel: String { String(format: "%+.1f", exposureBias) }

    #if os(iOS)
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "spektra.camera.session", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var rawFormat: OSType?
    private var isConfigured = false
    private var captureDelegate: MCaptureDelegate?
    private var maxZoom: CGFloat = 1
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
            unusableReason = "模拟器没有相机，请在 iPhone 真机上试拍 RAW"
            return
        }
        guard unusableReason == nil else { return }

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
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
        #endif
    }

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            var format: OSType?
            var firstConfigure = false
            if !self.isConfigured {
                do {
                    format = try self.configure()
                    self.isConfigured = true
                    firstConfigure = true
                } catch {
                    DispatchQueue.main.async {
                        self.unusableReason = error.localizedDescription
                        self.permission = .authorized
                    }
                    return
                }
            } else {
                format = self.rawFormat
            }

            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            let flash = self.device?.hasFlash ?? false
            let zoomLimit = self.device?.activeFormat.videoMaxZoomFactor ?? 1
            let lenses = self.pendingLenses
            let lensMap = self.pendingLensDevices
            let currentLens = self.pendingLens(for: self.device)
            let wide = self.pendingWideDevice
            let maxEdge = self.device.map(Self.maxPhotoLongEdge) ?? 0

            DispatchQueue.main.async {
                self.rawFormat = format
                self.rawAvailable = format != nil
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
            }
        }
    }

    private func pendingLens(for device: AVCaptureDevice?) -> Lens? {
        guard let device else { return nil }
        return pendingLenses.first { $0.id == device.uniqueID }
    }

    /// 在 sessionQueue 上调用：装配输入 / 输出 / 竖屏方向，返回可用的 RAW 像素格式。
    private func configure() throws -> OSType? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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

        // 部分 Pro 机型只暴露 Apple ProRAW：不先打开这个开关，下面的格式列表会是空的，
        // 相机就会一直停在「这台设备不提供 RAW 拍摄」。
        if photoOutput.isAppleProRAWSupported, !photoOutput.isAppleProRAWEnabled {
            photoOutput.isAppleProRAWEnabled = true
        }

        // 优先 Apple ProRAW：它已经是去过马赛克的线性 DNG，显影时不用现场去马赛克，读取快好几倍；
        // Bayer RAW 虽然更"原始"，但 12MP 去马赛克在 CIRAWFilter 里要几秒，用户会以为卡死。
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        let proRAW = formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let picked = proRAW ?? formats.first

        self.device = device
        self.pendingWideDevice = device
        let built = Self.makeLenses(position: .back, wide: device,
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
    static func maxPhotoLongEdge(of device: AVCaptureDevice) -> Int {
        var edge = 0
        for dims in device.activeFormat.supportedMaxPhotoDimensions {
            edge = max(edge, max(Int(dims.width), Int(dims.height)))
        }
        return edge
    }

    /// 用水平视场角折算 35mm 等效焦距：f = 18 / tan(FOV / 2)。
    private static func equivalentFocalLength(of device: AVCaptureDevice) -> CGFloat {
        let fov = CGFloat(device.activeFormat.videoFieldOfView)
        guard fov > 1, fov < 179 else { return 0 }
        return 18 / tan(fov * .pi / 360)
    }
    #endif

    // MARK: - 拍摄

    func capture() {
        #if os(iOS)
        guard canCapture, let rawFormat else { return }
        isCapturing = true
        message = nil

        // 只拍 RAW：qualityPrioritization 只对 processed 图有意义，设了反而会被系统拒绝，所以不设。
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: nil)
        // 闪光灯必须显式写到拍摄设置上才會触发；RAW 拍摄同样靠闪光灯照亮。
        if hasFlash {
            let mode = flash.avMode
            if photoOutput.supportedFlashModes.contains(mode) {
                settings.flashMode = mode
            } else if flash == .on {
                message = "当前设备或模式不支持强制闪光"
            }
        }

        let delegate = MCaptureDelegate(
            meta: MCameraCaptureMeta(exposureBias: exposureBias, temperature: temperature)
        ) { [weak self] result in
            DispatchQueue.main.async { self?.finish(result) }
        }
        captureDelegate = delegate

        // 拍摄瞬间的重力方向决定出片朝向：横屏拍的 DNG 在快门那一刻就按重力转正，
        // 显影台拿到的是正图，不需要再手动旋转。
        let angle = Self.captureRotationAngle(for: UIDevice.current.orientation)
        sessionQueue.async { [photoOutput] in
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
    private func switchInput(to lens: Lens, target: AVCaptureDevice) {
        isSwitchingLens = true
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
            if self.photoOutput.isAppleProRAWSupported, !self.photoOutput.isAppleProRAWEnabled {
                self.photoOutput.isAppleProRAWEnabled = true
            }
            self.session.commitConfiguration()

            let formats = self.photoOutput.availableRawPhotoPixelFormatTypes
            guard let raw = formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? formats.first else {
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
            do {
                try target.lockForConfiguration()
                target.videoZoomFactor = factor
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
                self.rawAvailable = true
                self.hasFlash = target.hasFlash
                self.maxZoom = limit
                self.maxPhotoEdge = Self.maxPhotoLongEdge(of: target)
                self.zoom = appliedZoom
                self.lens = lens
            }
        }
    }

    /// 主线程调用：撤销切换、发布失败提示；failedLensIDs 的回写走 sessionQueue。
    private func failSwitch(to lens: Lens) {
        lensSwitchToken += 1
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
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let current = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first else { return }
            if current.device === wide {
                do {
                    try wide.lockForConfiguration()
                    wide.videoZoomFactor = 1
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
            let raw = formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? formats.first
            let limit = max(1, wide.activeFormat.videoMaxZoomFactor)
            do {
                try wide.lockForConfiguration()
                wide.videoZoomFactor = 1
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
                self.maxPhotoEdge = Self.maxPhotoLongEdge(of: wide)
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

    /// 前后摄像头切换。前置多数机型不提供 RAW，切不过去时退回后置并给出提示。
    func flip() {
        #if os(iOS)
        guard isRunning, !isCapturing, !isSwitchingLens, let current = device else { return }
        let target: AVCaptureDevice.Position = current.position == .front ? .back : .front
        guard let next = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target),
              let input = try? AVCaptureDeviceInput(device: next) else {
            message = "找不到可用的摄像头"
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let previous = self.session.inputs.first

            self.session.beginConfiguration()
            if let previous { self.session.removeInput(previous) }
            let attached = self.session.canAddInput(input)
            if attached { self.session.addInput(input) }
            // 换设备后格式列表会重算，ProRAW 开关也要在这个配置窗口里重新确认。
            if self.photoOutput.isAppleProRAWSupported, !self.photoOutput.isAppleProRAWEnabled {
                self.photoOutput.isAppleProRAWEnabled = true
            }
            self.session.commitConfiguration()

            let formats = attached ? self.photoOutput.availableRawPhotoPixelFormatTypes : []
            let proRAW = formats.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            let picked = proRAW ?? formats.first

            // Spektra 只拍 RAW：前置没有 RAW 就把后置装回去。
            guard picked != nil else {
                self.session.beginConfiguration()
                if let failed = self.session.inputs.first { self.session.removeInput(failed) }
                if let previous, self.session.canAddInput(previous) {
                    self.session.addInput(previous)
                }
                self.session.commitConfiguration()
                DispatchQueue.main.async {
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

            DispatchQueue.main.async {
                self.device = next
                self.wideDevice = next
                self.isFront = target == .front
                self.rawFormat = picked
                self.rawAvailable = true
                self.hasFlash = next.hasFlash
                self.maxZoom = next.activeFormat.videoMaxZoomFactor
                self.maxPhotoEdge = Self.maxPhotoLongEdge(of: next)
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
        guard let device else { return }
        let clamped = min(max(value, -3), 3)
        do {
            try device.lockForConfiguration()
            if device.exposureMode == .locked,
               device.isExposureModeSupported(.continuousAutoExposure) {
                // AE 锁定后仍要能调曝光：恢复自动测光，对焦继续保持锁定。
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(Float(clamped))
            device.unlockForConfiguration()
        } catch {
            return
        }
        exposureBias = clamped
        #endif
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
        guard let device else { return }
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
            device.unlockForConfiguration()
        } catch {
            return
        }
        isExposureLocked = false
        isoValue = device.iso
        #endif
    }

    /// 长按取景框：锁定当前对焦与曝光，作为上下拖动改 ISO 的起点。
    func lockFocusAndExposure(at point: CGPoint) {
        #if os(iOS)
        guard let device else { return }
        do {
            try device.lockForConfiguration()
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
            return
        }
        isExposureLocked = true
        isoValue = device.iso
        #endif
    }

    /// 未锁定时直接滑动：只锁曝光以便调 ISO，对焦保持当前模式。
    func lockExposure() {
        #if os(iOS)
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        } catch {
            return
        }
        isExposureLocked = true
        isoValue = device.iso
        #endif
    }

    /// 锁定后上下拖动：保持当前快门，只改 ISO（夹在格式的感光度范围内）。
    func setISO(_ value: Float) {
        #if os(iOS)
        guard let device, isExposureLocked, device.isExposureModeSupported(.custom) else { return }
        let upper = min(device.activeFormat.maxISO, 6400)
        let clamped = min(max(value, device.activeFormat.minISO), upper)
        let duration = device.exposureDuration
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: clamped, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            return
        }
        isoValue = clamped
        #endif
    }

    /// 点按取景框时解除 AE/AF 锁定，回到连续自动。
    func releaseLock() {
        #if os(iOS)
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            return
        }
        isExposureLocked = false
        isoValue = device.iso
        #endif
    }
}

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
    /// 快门按下时的曝光/色温：异步回调里不能再读已经变化的相机状态。
    private let meta: MCameraCaptureMeta
    private var finished = false

    init(meta: MCameraCaptureMeta, completion: @escaping (Result<MCameraShot, Error>) -> Void) {
        self.meta = meta
        self.completion = completion
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
        guard photo.isRawPhoto, let data = photo.fileDataRepresentation() else {
            completion(.failure(MCameraSession.SessionError.noRawData))
            return
        }

        let name = "Spektra-\(Self.stamp())-\(Int.random(in: 100...999)).dng"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            completion(.failure(error))
            return
        }
        completion(.success(MCameraShot(url: url, thumbnail: Self.thumbnail(url: url), meta: meta)))
    }

    /// 出片前就失败（如采集被中断）时只会回调这里；不复位的话 `isCapturing` 会永远卡住。
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard let error, !finished else { return }
        finished = true
        completion(.failure(error))
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 只读 DNG 内嵌预览，避免为了取景器缩略图去解码整张 RAW。
    private static func thumbnail(url: URL) -> MPlatformImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            // 先用 DNG 内嵌的小预览；只有缺失时才解整张 RAW，避免快门后立刻吃一大块内存。
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return MImage.make(cgImage: image)
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
