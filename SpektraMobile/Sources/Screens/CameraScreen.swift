import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// 取景框拍摄页：复古机械单反的取景器 + 黄铜快门。
///
/// 只做一件事：拍一张 RAW（DNG）后把临时文件交回给根视图入库。
struct CameraScreen: View {
    let onClose: () -> Void
    let onCaptured: (URL) -> Void

    @StateObject private var camera = MCameraSession()
    @Environment(\.mSafeInsets) private var insets
    @Environment(\.scenePhase) private var scenePhase

    @State private var gridVisible = false
    @State private var flashOpacity: Double = 0
    @State private var frame = 1
    @State private var focusMark: CGPoint?
    @State private var focusToken = 0
    @State private var hint: String?
    @State private var hintToken = 0

    var body: some View {
        ZStack {
            MColor.canvas

            viewfinder

            LinearGradient(
                colors: [
                    MColor.brass.opacity(0.06),
                    .clear,
                    MColor.filmBlue.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)

            vignette

            chrome

            bottomDeck

            noticeCard

            topBar

            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if let hint {
                hintPill(hint)
            }
        }
        .ignoresSafeArea()
        .background(MColor.canvas)
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        // 去系统设置授权后回到前台：重新读权限并补启动，否则会一直停在「需要相机权限」。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            camera.refreshPermission()
        }
        .onChange(of: camera.lastShot?.id) { _, _ in
            guard let shot = camera.lastShot else { return }
            frame = min(frame + 1, 36)
            onCaptured(shot.url)
        }
        .onChange(of: camera.message) { _, value in
            guard let value, !value.isEmpty else { return }
            showHint(value)
            camera.clearMessage()
        }
    }

    // MARK: - 画面

    @ViewBuilder
    private var viewfinder: some View {
        #if os(iOS)
        if camera.permission == .authorized, camera.unusableReason == nil {
            MCameraPreview(session: camera.session) { devicePoint, viewPoint in
                camera.focus(at: devicePoint)
                markFocus(viewPoint)
            }
        } else {
            standby
        }
        #else
        standby
        #endif
    }

    /// 无相机时（模拟器 / 未授权）的取景待机画面。
    private var standby: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x2A2418), Color(hex: 0x14120D), MColor.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [MColor.brass.opacity(0.12), .clear],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 12,
                endRadius: 320
            )
            Image(systemName: "camera.aperture")
                .font(.system(size: 132, weight: .ultraLight))
                .foregroundStyle(MColor.brass.opacity(0.10))
        }
    }

    private var vignette: some View {
        RadialGradient(
            colors: [.clear, Color.black.opacity(0.58)],
            center: .center,
            startRadius: 110,
            endRadius: 440
        )
        .allowsHitTesting(false)
    }

    // MARK: - 取景框线条与读数

    private var chrome: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                cornerMarks(size: size)

                if gridVisible {
                    thirds(size: size)
                        .transition(.opacity)
                }

                centerCross

                if let mark = focusMark {
                    MFocusReticle()
                        .position(x: mark.x * size.width, y: mark.y * size.height)
                }

                VStack {
                    Spacer()
                    readouts
                        .padding(.horizontal, MMetric.pageMargin)
                        .padding(.bottom, 204)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func cornerMarks(size: CGSize) -> some View {
        let inset: CGFloat = 22
        let length: CGFloat = 26
        return Path { path in
            path.move(to: CGPoint(x: inset, y: inset + length))
            path.addLine(to: CGPoint(x: inset, y: inset))
            path.addLine(to: CGPoint(x: inset + length, y: inset))

            path.move(to: CGPoint(x: size.width - inset - length, y: inset))
            path.addLine(to: CGPoint(x: size.width - inset, y: inset))
            path.addLine(to: CGPoint(x: size.width - inset, y: inset + length))

            path.move(to: CGPoint(x: size.width - inset, y: size.height - inset - length))
            path.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
            path.addLine(to: CGPoint(x: size.width - inset - length, y: size.height - inset))

            path.move(to: CGPoint(x: inset + length, y: size.height - inset))
            path.addLine(to: CGPoint(x: inset, y: size.height - inset))
            path.addLine(to: CGPoint(x: inset, y: size.height - inset - length))
        }
        .stroke(MColor.brass.opacity(0.62), lineWidth: 1)
    }

    private func thirds(size: CGSize) -> some View {
        Path { path in
            for index in 1...2 {
                let x = size.width * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))

                let y = size.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 0.75, dash: [1, 5]))
    }

    private var centerCross: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.34))
                .frame(width: 1, height: 16)
            Rectangle()
                .fill(Color.white.opacity(0.34))
                .frame(width: 16, height: 1)
            Circle()
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                .frame(width: 44, height: 44)
        }
    }

    private var readouts: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("RAW · DNG")
                    .font(.mSans(8, .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.white.opacity(0.72))
                Text(camera.hasFlash ? camera.flash.title : "无内闪")
                    .font(.mSans(7.5, .medium))
                    .tracking(1.0)
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            Spacer(minLength: 0)

            Text(camera.zoom > 1.01 ? "\(Int(camera.zoom))×" : "1×")
                .font(.mSans(9, .semibold).monospacedDigit())
                .tracking(1.0)
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                Button {
                    MHaptic.light()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MColor.text1)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.black.opacity(0.44)))
                        .overlay(Circle().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(MPressStyle(scale: 0.92))

                Spacer(minLength: 0)

                VStack(spacing: 3) {
                    Text("SPEKTRAFILM")
                        .font(.mSans(9, .semibold))
                        .tracking(2.6)
                        .foregroundStyle(MColor.text1.opacity(0.92))
                    Text("MODEL 35 · 1968")
                        .font(.mSans(7, .medium))
                        .tracking(1.8)
                        .foregroundStyle(MColor.text3)
                }

                Spacer(minLength: 0)

                rawBadge
                    .fixedSize()
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.top, insets.top + 10)

            Spacer()
        }
    }

    private var rawBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(camera.isRawReady ? MColor.filmRed : MColor.text4)
                .frame(width: 5, height: 5)
                .shadow(color: camera.isRawReady ? MColor.filmRed.opacity(0.9) : .clear, radius: 3)

            Text("RAW")
                .font(.mSans(7, .semibold))
                .tracking(1.1)
                .foregroundStyle(camera.isRawReady ? MColor.text1 : MColor.text4)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Capsule().fill(Color.black.opacity(0.44)))
        .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
    }

    // MARK: - 底部机身

    private var bottomDeck: some View {
        VStack {
            Spacer()

            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    MToolDisc(
                        icon: "square.grid.3x3",
                        active: gridVisible
                    ) {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { gridVisible.toggle() }
                    }

                    MToolDisc(
                        icon: camera.flash.symbol,
                        active: camera.flash != .off
                    ) {
                        MHaptic.tick()
                        camera.cycleFlash()
                    }
                    .opacity(camera.hasFlash ? 1 : 0.42)

                    MToolDisc(
                        icon: "arrow.up.left.and.arrow.down.right",
                        active: camera.zoom > 1.01
                    ) {
                        camera.toggleZoom()
                    }
                }

                HStack(alignment: .center) {
                    lastShot
                        .frame(width: 56, height: 56)

                    Spacer(minLength: 0)

                    shutter

                    Spacer(minLength: 0)

                    counter
                        .frame(width: 56)
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, insets.bottom + 16)
        }
    }

    private var lastShot: some View {
        ZStack {
            if let image = camera.lastShot?.thumbnail {
                MImage.swiftUI(image)
                    .resizable()
                    .scaledToFill()
            } else {
                MColor.surface1
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(MColor.text4)
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        )
    }

    private var counter: some View {
        VStack(spacing: 1) {
            Text(String(format: "%02d", frame))
                .font(.mSans(15, .semibold).monospacedDigit())
                .foregroundStyle(MColor.text1)
            Text("/ 36")
                .font(.mSans(7, .medium).monospacedDigit())
                .tracking(0.6)
                .foregroundStyle(MColor.text4)
        }
        .frame(width: 56, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(MColor.surface1.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(MColor.hairline, lineWidth: 1)
        )
    }

    private var shutter: some View {
        Button(action: capture) {
            ZStack {
                Circle()
                    .fill(MColor.surface1)
                    .overlay(Circle().strokeBorder(MColor.brass.opacity(0.45), lineWidth: 1))

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [MColor.brassHigh, MColor.brass, MColor.brassDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(7)

                Circle()
                    .fill(MColor.brassInk)
                    .padding(15)

                Image(systemName: "camera.aperture")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(MColor.brassHigh)
            }
            .frame(width: 82, height: 82)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(MColor.filmRed)
                    .frame(width: 3, height: 9)
                    .offset(y: -1)
            }
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        }
        .buttonStyle(MPressStyle(scale: 0.93))
        .disabled(!camera.canCapture)
        .opacity(camera.canCapture ? 1 : 0.55)
        .accessibilityLabel("拍摄")
    }

    // MARK: - 提示与授权

    private func hintPill(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text1)
                .padding(.horizontal, 15)
                .frame(height: 36)
                .background(Capsule().fill(MColor.surface3.opacity(0.96)))
                .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
                .padding(.bottom, insets.bottom + 196)
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var noticeCard: some View {
        if let reason = camera.unusableReason {
            noticeScrim {
                noticeBody(
                    icon: "video.slash",
                    title: "取景器不可用",
                    detail: reason
                )
            }
        } else if camera.permission == .denied {
            noticeScrim {
                noticeBody(
                    icon: "camera.metering.unknown",
                    title: "需要相机权限",
                    detail: "拍 RAW 必须先允许访问相机。授权后回到这里即可取景。",
                    actionTitle: "打开设置",
                    action: openSettings
                )
            }
        } else if camera.permission == .requesting {
            noticeScrim {
                noticeBody(
                    icon: "camera.aperture",
                    title: "正在请求相机权限",
                    detail: "请在系统弹窗里选择「允许」。"
                )
            }
        }
    }

    private func noticeScrim<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            content()
                .padding(.horizontal, 36)
        }
    }

    private func noticeBody(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(MColor.brass)

            Text(title)
                .font(.mSans(14, .semibold))
                .foregroundStyle(MColor.text1)

            Text(detail)
                .font(.mSans(11))
                .foregroundStyle(MColor.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.mSans(12, .semibold))
                        .foregroundStyle(MColor.brassInk)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Capsule().fill(MColor.brass))
                }
                .buttonStyle(MPressStyle(scale: 0.94))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MColor.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        )
    }

    // MARK: - 动作

    private func capture() {
        guard camera.canCapture else {
            showHint(camera.blockedHint)
            return
        }
        MHaptic.medium()
        withAnimation(.easeOut(duration: 0.05)) { flashOpacity = 0.9 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            withAnimation(.easeIn(duration: 0.26)) { flashOpacity = 0 }
        }
        camera.capture()
    }

    private func markFocus(_ point: CGPoint) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
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
/// AVCaptureVideoPreviewLayer 的 SwiftUI 容器；点击时把「设备坐标 + 视图归一化坐标」一起交出去。
struct MCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> MPreviewView {
        let view = MPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: MPreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.onTap = onTap
    }
}

final class MPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        let normalized = CGPoint(
            x: min(max(point.x / max(1, bounds.width), 0), 1),
            y: min(max(point.y / max(1, bounds.height), 0), 1)
        )
        onTap?(devicePoint, normalized)
    }
}
#endif

// MARK: - 零件

private struct MToolDisc: View {
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? MColor.brassHigh : MColor.text3)
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.black.opacity(0.46)))
                .overlay(
                    Circle().strokeBorder(
                        active ? MColor.brass.opacity(0.55) : MColor.hairlineStrong,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(MPressStyle(scale: 0.9))
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
