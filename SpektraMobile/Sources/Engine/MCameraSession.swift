import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
#if os(iOS)
import AVFoundation
#endif

/// 一次 RAW 拍摄的结果：临时 DNG 文件 + 取景器里用的缩略图。
struct MCameraShot: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: MPlatformImage?
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
        case off, auto, on

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "关闭"
            case .auto: return "自动"
            case .on: return "开启"
            }
        }

        var symbol: String {
            switch self {
            case .off: return "bolt.slash"
            case .auto: return "bolt"
            case .on: return "bolt.fill"
            }
        }
    }

    /// 取景器里的焦段按钮：数字是 35mm 等效焦距，`zoom` 是折算到设备上的变焦倍数。
    enum Lens: Int, CaseIterable, Identifiable {
        case wide = 26
        case standard = 35
        case portrait = 50
        case tele = 77

        var id: Int { rawValue }
        var focal: Int { rawValue }

        var zoom: CGFloat {
            switch self {
            case .wide: return 1
            case .standard: return 1.5
            case .portrait: return 2
            case .tele: return 3
            }
        }

        var zoomLabel: String {
            zoom == zoom.rounded() ? "\(Int(zoom))×" : String(format: "%.1f×", zoom)
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
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var lastShot: MCameraShot?
    /// 设备 / 环境层面的不可用原因（模拟器、没有摄像头）。
    @Published private(set) var unusableReason: String?
    /// 一次拍摄失败的原因，界面以 toast 呈现。
    @Published private(set) var message: String?

    @Published var flash: FlashMode = .off

    @Published private(set) var lens: Lens = .wide
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
        isRunning && rawAvailable && !isCapturing && unusableReason == nil
    }

    var isRawReady: Bool {
        isRunning && rawAvailable && unusableReason == nil
    }

    /// 快门被挡住时的说明文案。
    var blockedHint: String {
        if let unusableReason { return unusableReason }
        if permission == .denied { return "没有相机权限，请到系统设置里打开" }
        if isCapturing { return "正在写入 DNG…" }
        if !isRunning { return "相机还在启动" }
        if !rawAvailable { return "这台设备不提供 RAW 拍摄" }
        return "相机还没准备好"
    }

    var temperatureLabel: String { temperature.map { "\($0)K" } ?? "Auto" }

    var exposureLabel: String { String(format: "%+.1f", exposureBias) }

    /// 只有设备变焦能到的焦段才显示。
    var availableLenses: [Lens] {
        #if os(iOS)
        let limit = max(1, maxZoom)
        return Lens.allCases.filter { $0.zoom <= limit + 0.05 }
        #else
        return [.wide]
        #endif
    }

    #if os(iOS)
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "spektra.camera.session", qos: .userInitiated)
    private var device: AVCaptureDevice?
    private var rawFormat: OSType?
    private var isConfigured = false
    private var captureDelegate: MCaptureDelegate?
    private var maxZoom: CGFloat = 1
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
            if !self.isConfigured {
                do {
                    format = try self.configure()
                    self.isConfigured = true
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

            DispatchQueue.main.async {
                self.rawFormat = format
                self.rawAvailable = format != nil
                self.hasFlash = flash
                self.maxZoom = zoomLimit
                self.isRunning = running
            }
        }
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
        return picked
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
                if flash == .auto, !photoOutput.isFlashScene {
                    // 自动档在亮场景不触发是系统行为；明示出来，免得以为开关坏了。
                    message = "自动闪光：场景亮度足够，本次未触发闪光"
                } else {
                    settings.flashMode = mode
                }
            } else if flash == .on {
                message = "当前设备或模式不支持强制闪光"
            }
        }

        let delegate = MCaptureDelegate { [weak self] result in
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

    /// 选焦段：把 35mm 等效焦距折算成设备变焦倍数。
    func select(_ lens: Lens) {
        #if os(iOS)
        guard let device else { return }
        let target = min(lens.zoom, max(1, maxZoom))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
        } catch {
            return
        }
        zoom = device.videoZoomFactor
        self.lens = lens
        #endif
    }

    /// 前后摄像头切换。前置多数机型不提供 RAW，切不过去时退回后置并给出提示。
    func flip() {
        #if os(iOS)
        guard isRunning, !isCapturing, let current = device else { return }
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

            DispatchQueue.main.async {
                self.device = next
                self.isFront = target == .front
                self.rawFormat = picked
                self.rawAvailable = true
                self.hasFlash = next.hasFlash
                self.maxZoom = next.activeFormat.videoMaxZoomFactor
                self.zoom = 1
                self.lens = .wide
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
        case .auto: return .auto
        case .on: return .on
        }
    }
}

/// AVCapturePhotoOutput 的代理：把 RAW 数据落到临时 DNG，并顺手取一张缩略图。
private final class MCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<MCameraShot, Error>) -> Void
    private var finished = false

    init(completion: @escaping (Result<MCameraShot, Error>) -> Void) {
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
        completion(.success(MCameraShot(url: url, thumbnail: Self.thumbnail(url: url))))
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
