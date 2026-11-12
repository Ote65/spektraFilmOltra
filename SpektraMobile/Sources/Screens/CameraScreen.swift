import SwiftUI
import Combine
#if os(iOS)
import AVFoundation
#endif

/// 拍摄页：4:3 取景 + iOS 风格快门。
///
/// 拍一张 RAW（DNG）→ 交给根视图入库 → 直接进入这张照片的显影台；
/// 相册写入在后台继续，成功后清理临时文件。
struct CameraScreen: View {
    let onClose: () -> Void
    /// 拍完把 DNG 交给根视图：入库并进入这张照片的显影台。
    let onCaptured: (URL) -> Void

    @StateObject private var camera = MCameraSession()
    @Environment(\.mSafeInsets) private var insets
    @Environment(\.scenePhase) private var scenePhase

    @State private var flashOpacity: Double = 0
    @State private var focusMark: CGPoint?
    @State private var focusToken = 0
    @State private var hint: String?
    @State private var hintToken = 0
    /// 展开刻度条的那一个轴；nil 时显示三个快捷按钮。
    @State private var activeAxis: MCaptureAxis?
    @State private var scaleValue: Double = 0
    /// 长按锁定后停留在取景框上的位置（视图归一化坐标）。
    @State private var lockMark: CGPoint?
    @State private var exposureBase: Double = 0
    @State private var exposureDragTotal: CGFloat = 0
    /// 横屏拿手机时把锁定标记的文字转正，始终相对重力方向水平。
    @State private var badgeAngle: Double = 0

    var body: some View {
        ZStack {
            MColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                viewfinder
                controlRow
                    .frame(height: 72)
                    .padding(.top, 22)
                Spacer(minLength: 20)
                bottomRow
            }

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if let hint {
                hintPill(hint)
            }
        }
        .background(MColor.canvas)
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        // 去系统设置授权后回到前台：重新读权限并补启动。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            camera.refreshPermission()
        }
        .onChange(of: camera.lastShot?.id) { _, _ in
            handleShot()
        }
        .onChange(of: camera.message) { _, value in
            guard let value, !value.isEmpty else { return }
            showHint(value)
            camera.clearMessage()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            switch UIDevice.current.orientation {
            case .landscapeLeft: badgeAngle = 90
            case .landscapeRight: badgeAngle = -90
            case .portraitUpsideDown: badgeAngle = 180
            default: badgeAngle = 0
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MColor.text1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(MPressStyle(scale: 0.9))
            .accessibilityLabel("关闭相机")

            Spacer()

            // Spektra 只拍 RAW：这里只做状态显示，不提供开关。
            HStack(spacing: 6) {
                Circle()
                    .fill(camera.isRawReady ? MColor.filmRed : MColor.text4)
                    .frame(width: 6, height: 6)
                Text("RAW")
                    .font(.mSans(10, .semibold))
                    .foregroundStyle(MColor.text1)
                Text("4:3")
                    .font(.mSans(10, .medium))
                    .foregroundStyle(MColor.text4)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .accessibilityLabel("正在拍 RAW")
        }
        .padding(.horizontal, 16)
        .padding(.top, insets.top + 4)
    }

    // MARK: - 取景

    private var viewfinder: some View {
        ZStack {
            Color.black

            preview

            GeometryReader { geo in
                if let mark = lockMark {
                    MAELockBadge(exposure: camera.exposureBias, rotation: badgeAngle)
                        .position(x: mark.x * geo.size.width, y: mark.y * geo.size.height)
                } else if let mark = focusMark {
                    MFocusReticle()
                        .id(focusToken)
                        .position(x: mark.x * geo.size.width, y: mark.y * geo.size.height)
                }
            }
            .allowsHitTesting(false)

            VStack {
                Spacer()
                lensBar
                    .padding(.bottom, 12)
            }

            noticeCard
        }
        // 传感器是 4:3，竖着拿就是 3:4：取景框按 3:4 才和默认相机一致，不会上下裁掉一大截。
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var preview: some View {
        #if os(iOS)
        if camera.permission == .authorized, camera.unusableReason == nil {
            MCameraPreview(
                session: camera.session,
                onTap: { devicePoint, viewPoint in
                    if camera.isExposureLocked { camera.releaseLock() }
                    // 重新对焦 = 回到自动曝光，清掉上一次滑动留下的补偿。
                    camera.setExposureBias(0)
                    camera.focus(at: devicePoint)
                    lockMark = nil
                    mark(at: viewPoint)
                },
                onLongPress: { devicePoint, viewPoint in
                    MHaptic.medium()
                    exposureDragTotal = 0
                    exposureBase = camera.exposureBias
                    camera.lockFocusAndExposure(at: devicePoint)
                    withAnimation(MMotion.quick) { lockMark = viewPoint }
                },
                onDragBegin: {
                    exposureDragTotal = 0
                    exposureBase = camera.exposureBias
                },
                onISODrag: { delta in
                    // 无论是否锁定 AE/AF，滑动都是调整曝光（ISO 与快门由相机分配）。
                    exposureDragTotal += delta
                    let bias = exposureBase + Double(exposureDragTotal / 120)
                    camera.setExposureBias(bias)
                }
            )
        } else {
            standby
        }
        #else
        standby
        #endif
    }

    private var standby: some View {
        LinearGradient(
            colors: [MColor.surface1, MColor.canvas],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(
            VStack(spacing: 6) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 20, weight: .light))
                Text("4:3 · RAW")
                    .font(.mSans(9, .medium))
            }
            .foregroundStyle(MColor.text4)
        )
    }

    // MARK: - 焦段

    private var lensBar: some View {
        HStack(spacing: 2) {
            ForEach(camera.availableLenses) { lens in
                let selected = camera.lens == lens
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.quick) { camera.select(lens) }
                } label: {
                    VStack(spacing: 0) {
                        Text("\(lens.focal)")
                            .font(.mSans(11, .semibold).monospacedDigit())
                        Text(lens.zoomLabel)
                            .font(.mSans(7, .medium))
                            .opacity(0.72)
                    }
                    .foregroundStyle(selected ? MColor.brassInk : MColor.text1)
                    .frame(width: 42, height: 34)
                    .background(Capsule().fill(selected ? MColor.brass : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(lens.focal) 毫米")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: - 色温 / 曝光 / 闪光

    @ViewBuilder
    private var controlRow: some View {
        if let axis = activeAxis {
            MCaptureScaleBar(
                axis: axis,
                value: Binding(
                    get: { scaleValue },
                    set: { new in
                        scaleValue = new
                        apply(axis: axis, value: new)
                    }
                ),
                onReset: {
                    MHaptic.tick()
                    switch axis {
                    case .temperature: camera.setTemperature(nil)
                    case .exposure: camera.setExposureBias(0)
                    }
                    withAnimation(MMotion.quick) { activeAxis = nil }
                },
                onClose: {
                    withAnimation(MMotion.quick) { activeAxis = nil }
                }
            )
            .id(axis.rawValue)
            .transition(.opacity)
        } else {
            HStack(spacing: 30) {
                axisButton(
                    .temperature,
                    icon: "thermometer.medium",
                    label: camera.temperatureLabel,
                    active: camera.temperature != nil
                )

                axisButton(
                    .exposure,
                    icon: "sun.max",
                    label: camera.exposureLabel,
                    active: abs(camera.exposureBias) > 0.01
                )

                MCaptureControl(
                    icon: camera.flash.symbol,
                    label: camera.flash.title,
                    active: camera.flash != .off,
                    enabled: camera.isRawReady && camera.hasFlash
                ) {
                    MHaptic.tick()
                    camera.cycleFlash()
                }
            }
            .transition(.opacity)
        }
    }

    private func axisButton(_ axis: MCaptureAxis, icon: String,
                            label: String, active: Bool) -> some View {
        MCaptureControl(icon: icon, label: label, active: active, enabled: camera.isRawReady) {
            MHaptic.tick()
            scaleValue = axis.seedValue(temperature: camera.temperature,
                                        exposure: camera.exposureBias)
            withAnimation(MMotion.quick) { activeAxis = axis }
        }
    }

    private func apply(axis: MCaptureAxis, value: Double) {
        switch axis {
        case .temperature:
            let kelvin = Int((value / 100).rounded()) * 100
            guard kelvin != camera.temperature else { return }
            MHaptic.tick()
            camera.setTemperature(kelvin)
        case .exposure:
            let ev = (value * 10).rounded() / 10
            guard abs(ev - camera.exposureBias) > 0.001 else { return }
            MHaptic.tick()
            camera.setExposureBias(ev)
        }
    }

    // MARK: - 底部：本次拍摄预览 / 快门 / 翻转

    private var bottomRow: some View {
        HStack {
            lastShotThumbnail
                .frame(width: 58, height: 58)

            Spacer()

            shutter

            Spacer()

            Button {
                MHaptic.light()
                camera.flip()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(camera.isFront ? MColor.brassHigh : MColor.text1)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
            }
            .buttonStyle(MPressStyle(scale: 0.9))
            .frame(width: 58, height: 58)
            .accessibilityLabel("翻转相机")
        }
        .padding(.horizontal, 30)
        .padding(.bottom, max(14, insets.bottom))
    }

    /// 只显示本次拍摄的照片：`lastShot` 随这个页面一起创建 / 销毁。
    @ViewBuilder
    private var lastShotThumbnail: some View {
        if let thumbnail = camera.lastShot?.thumbnail {
            MImage.swiftUI(thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: 58, height: 58)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                )
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(MColor.text4)
                )
        }
    }

    private var shutter: some View {
        Button {
            capture()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.white.opacity(camera.canCapture ? 0.92 : 0.28),
                        lineWidth: 3
                    )
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(Color.white.opacity(camera.canCapture ? 1 : 0.28))
                    .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(MPressStyle(scale: 0.9))
        .disabled(!camera.canCapture)
        .accessibilityLabel("拍照")
    }

    // MARK: - 提示

    @ViewBuilder
    private var noticeCard: some View {
        if camera.unusableReason != nil {
            notice(camera.blockedHint, showsSettings: false)
        } else if camera.permission == .denied {
            notice("需要相机权限才能取景", showsSettings: true)
        } else if camera.permission == .requesting {
            notice("正在请求相机权限…", showsSettings: false)
        }
    }

    private func notice(_ text: String, showsSettings: Bool) -> some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.mSans(11.5, .medium))
                .foregroundStyle(MColor.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if showsSettings {
                Button {
                    openSettings()
                } label: {
                    Text("打开设置")
                        .font(.mSans(11, .semibold))
                        .foregroundStyle(MColor.brassInk)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(MColor.brass))
                }
                .buttonStyle(MPressStyle(scale: 0.94))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MColor.surface2.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        )
    }

    private func hintPill(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text1)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(MColor.surface3.opacity(0.96)))
                .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
                .padding(.bottom, 150)
        }
        .transition(.opacity.combined(with: .offset(y: 6)))
        .allowsHitTesting(false)
    }

    // MARK: - 动作

    private func capture() {
        guard camera.canCapture else {
            showHint(camera.blockedHint)
            return
        }
        MHaptic.medium()
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.8 }
        withAnimation(.easeIn(duration: 0.24).delay(0.07)) { flashOpacity = 0 }
        camera.capture()
    }

    /// 拍完交给根视图异步入库；入库完成后由根视图删除临时文件，
    /// 相册写入也由引擎在入库后统一处理，避免两边争抢同一个临时文件。
    private func handleShot() {
        guard let shot = camera.lastShot else { return }
        onCaptured(shot.url)
    }

    private func mark(at point: CGPoint) {
        focusToken += 1
        let token = focusToken
        withAnimation(MMotion.quick) { focusMark = point }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard token == focusToken else { return }
            withAnimation(MMotion.state) { focusMark = nil }
        }
    }

    private func showHint(_ text: String) {
        hintToken += 1
        let token = hintToken
        withAnimation(MMotion.state) { hint = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard token == hintToken else { return }
            withAnimation(MMotion.state) { hint = nil }
        }
    }

    private func openSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - 取景预览

#if os(iOS)
/// AVCaptureVideoPreviewLayer 的 SwiftUI 容器；点击对焦，长按锁定 AE/AF，按住上下拖动改 ISO。
struct MCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint, CGPoint) -> Void
    let onLongPress: (CGPoint, CGPoint) -> Void
    let onDragBegin: () -> Void
    let onISODrag: (CGFloat) -> Void

    func makeUIView(context: Context) -> MPreviewView {
        let view = MPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: MPreviewView, context: Context) {
        uiView.previewLayer.session = session
        apply(to: uiView)
    }

    private func apply(to view: MPreviewView) {
        view.onTap = onTap
        view.onLongPress = onLongPress
        view.onDragBegin = onDragBegin
        view.onISODrag = onISODrag
    }
}

final class MPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onLongPress: ((CGPoint, CGPoint) -> Void)?
    var onDragBegin: (() -> Void)?
    var onISODrag: ((CGFloat) -> Void)?

    private var lastTranslation: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        onTap?(devicePoint(point), normalized(point))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: self)
            onLongPress?(devicePoint(point), normalized(point))
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastTranslation = .zero
            onDragBegin?()
        case .changed:
            let translation = gesture.translation(in: self)
            let delta = verticalDelta(
                dx: translation.x - lastTranslation.x,
                dy: translation.y - lastTranslation.y
            )
            lastTranslation = translation
            onISODrag?(delta)
        case .ended, .cancelled, .failed:
            lastTranslation = .zero
        default:
            break
        }
    }

    /// 手指位移换算成「沿重力向上为正」的调节量：
    /// 竖屏是屏幕上下，横屏是屏幕左右（此时重力方向落在屏幕横向）。
    private func verticalDelta(dx: CGFloat, dy: CGFloat) -> CGFloat {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown: return dy
        case .landscapeLeft: return dx
        case .landscapeRight: return -dx
        default: return -dy
        }
    }

    private func devicePoint(_ point: CGPoint) -> CGPoint {
        previewLayer.captureDevicePointConverted(fromLayerPoint: point)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x / max(1, bounds.width), 0), 1),
            y: min(max(point.y / max(1, bounds.height), 0), 1)
        )
    }
}
#endif

// MARK: - 零件

/// 相机页可展开为刻度条的两个连续轴。
private enum MCaptureAxis: String, Identifiable {
    case temperature
    case exposure

    var id: String { rawValue }

    var range: ClosedRange<Double> {
        switch self {
        case .temperature: return 2000...8000
        case .exposure: return -2...2
        }
    }

    var step: Double {
        switch self {
        case .temperature: return 100
        case .exposure: return 0.1
        }
    }

    var icon: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .exposure: return "sun.max"
        }
    }

    func label(_ value: Double) -> String {
        switch self {
        case .temperature: return "\(Int(value.rounded()))K"
        case .exposure: return String(format: "%.1f", value)
        }
    }

    func seedValue(temperature: Int?, exposure: Double) -> Double {
        switch self {
        case .temperature: return Double(temperature ?? 5600)
        case .exposure: return exposure
        }
    }
}

/// iPhone 原相机式刻度条：顶部读数，下面一排竖线，当前值金色高亮。
private struct MCaptureScaleBar: View {
    let axis: MCaptureAxis
    @Binding var value: Double
    let onReset: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: axis.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MColor.brassInk)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(MColor.brass))
            }
            .buttonStyle(MPressStyle(scale: 0.92))
            .accessibilityLabel("收起刻度")

            VStack(spacing: 8) {
                Text(axis.label(value))
                    .font(.mSans(22, .medium).monospacedDigit())
                    .foregroundStyle(MColor.text1)

                MTickRuler(range: axis.range, step: axis.step, value: $value)
                    .frame(height: 26)
            }
            .frame(maxWidth: .infinity)

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MColor.text3)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(MPressStyle(scale: 0.92))
            .accessibilityLabel("复位")
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
    }
}

/// 长按后的 AE/AF 锁定标记：黄色方框 + 当前曝光补偿，滑动时数值实时变化。
private struct MAELockBadge: View {
    let exposure: Double
    let rotation: Double
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.9), lineWidth: 1)
                .frame(width: 56, height: 56)
            Text("AE/AF 锁定 · \(String(format: "%+.1f", exposure)) EV")
                .font(.mSans(9, .semibold).monospacedDigit())
                .foregroundStyle(Color.yellow)
        }
        .rotationEffect(.degrees(rotation))
        .scaleEffect(appeared ? 1 : 1.25)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}

private struct MCaptureControl: View {
    let icon: String
    let label: String
    let active: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? MColor.brassInk : MColor.text2)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(active ? MColor.brass : Color.white.opacity(0.07)))
                    .overlay(
                        Circle().strokeBorder(
                            active ? Color.clear : MColor.hairlineStrong,
                            lineWidth: 1
                        )
                    )

                Text(label)
                    .font(.mSans(9, .medium).monospacedDigit())
                    .foregroundStyle(active ? MColor.brassHigh : MColor.text4)
            }
        }
        .buttonStyle(MPressStyle(scale: 0.92))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct MFocusReticle: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(MColor.brassHigh.opacity(0.92), lineWidth: 1)
                .frame(width: 52, height: 52)
            Circle()
                .fill(MColor.brassHigh.opacity(0.9))
                .frame(width: 3, height: 3)
        }
        .scaleEffect(appeared ? 1 : 1.35)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }
}
