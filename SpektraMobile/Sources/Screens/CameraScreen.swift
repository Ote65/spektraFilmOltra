import SwiftUI
#if os(iOS)
import AVFoundation
#endif

/// 拍摄页：4:3 取景 + iOS 风格快门。
///
/// 只做两件事：拍一张 RAW（DNG），然后写进系统相册。
/// 不入库、也不跳显影台 —— 主页会自己扫描相册里的 RAW。
struct CameraScreen: View {
    let onClose: () -> Void

    @StateObject private var camera = MCameraSession()
    @Environment(\.mSafeInsets) private var insets
    @Environment(\.scenePhase) private var scenePhase

    @State private var flashOpacity: Double = 0
    @State private var focusMark: CGPoint?
    @State private var focusToken = 0
    @State private var hint: String?
    @State private var hintToken = 0

    var body: some View {
        ZStack {
            MColor.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                viewfinder
                controlRow
                    .padding(.top, 26)
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
            saveLastShot()
        }
        .onChange(of: camera.message) { _, value in
            guard let value, !value.isEmpty else { return }
            showHint(value)
            camera.clearMessage()
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
                if let mark = focusMark {
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
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
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
            MCameraPreview(session: camera.session) { devicePoint, viewPoint in
                camera.focus(at: devicePoint)
                mark(at: viewPoint)
            }
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

    private var controlRow: some View {
        HStack(spacing: 30) {
            MCaptureControl(
                icon: "thermometer.medium",
                label: camera.temperatureLabel,
                active: camera.temperature != nil,
                enabled: camera.isRawReady
            ) {
                MHaptic.tick()
                camera.cycleTemperature()
            }

            MCaptureControl(
                icon: "sun.max",
                label: camera.exposureLabel,
                active: abs(camera.exposureBias) > 0.01,
                enabled: camera.isRawReady
            ) {
                MHaptic.tick()
                camera.cycleExposure()
            }

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

    /// 拍完只写系统相册；入库交给主页的相册扫描。
    private func saveLastShot() {
        guard let shot = camera.lastShot else { return }
        PhotoLibraryExport.save(shot.url) { outcome in
            switch outcome {
            case .saved:
                // 只有写进相册后才删临时文件：失败时先留着，别把刚拍的 RAW 一起丢了。
                try? FileManager.default.removeItem(at: shot.url)
                showHint("已保存到相册")
            case .denied: showHint("没有相册写入权限，照片没能保存")
            case .failed: showHint("保存到相册失败")
            }
        }
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
