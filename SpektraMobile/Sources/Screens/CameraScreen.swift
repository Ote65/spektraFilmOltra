import SwiftUI
import Combine
#if os(iOS)
import AVFoundation
import AVKit
#endif

private enum MDirectCardPhase {
    case developing
    case ready(MDirectRenderResult)
    case failed(String)
}

/// 拍摄页：4:3 取景 + iOS 风格快门。
///
/// 拍一张 RAW（DNG）→ 交给根视图入库 → 直接进入这张照片的显影台；
/// 相册写入在后台继续，成功后清理临时文件。
struct CameraScreen: View {
    let onClose: () -> Void
    /// 拍完把 DNG 交给根视图：入库，并按 `enterDevelop` 决定是否进入显影台。
    /// `meta` 是快门瞬间的曝光/色温，必须一起入库，显影才会复现拍摄意图。
    let onCaptured: (URL, Bool, MCameraCaptureMeta) -> Void
    /// 直出保存：根视图决定是否保留 RAW 工程，并写系统相册。
    let onDirectSave: (MDirectSaveRequest) async -> MDirectSaveOutcome
    /// 直出成片页进入显影台：原片入库，并沿用拍摄时选择的显影 / 调色预设。
    let onDirectDevelop: (MDirectDevelopRequest) async -> MDirectDevelopOutcome

    @StateObject private var camera = MCameraSession()
    @StateObject private var level = MLevelMonitor()
    @Environment(\.mSafeInsets) private var insets
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("mobile.camera.timer") private var timerSeconds = 0
    @AppStorage("mobile.camera.grid") private var gridEnabled = false
    @AppStorage(MobileSettings.cameraLevelKey) private var levelEnabled = true
    @AppStorage(MobileSettings.cameraVolumeShutterKey) private var volumeShutter = true
    @AppStorage(MobileSettings.cameraMirrorFrontKey) private var mirrorFront = false
    @AppStorage(MobileSettings.cameraEnterDevelopKey) private var enterDevelopAfterShot = true

    @State private var timerMenuOpen = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    // 直出模式
    @AppStorage("mobile.camera.direct") private var directMode = false
    @AppStorage("mobile.camera.directDevelop") private var directDevelopID = "standard"
    @AppStorage("mobile.camera.directGrade") private var directGradeID = "builtin:neutral"
    @State private var directPickerOpen = false
    @State private var directLongPressed = false
    @State private var directCard: MDirectCardPhase?
    @State private var directProgress: Double = 0
    @State private var directPhoto: MPlatformImage?
    @State private var directPreviewToken = 0
    @State private var directRawURL: URL?
    @State private var directEdit: PhotoEdit?
    @State private var directRecipe: GradeRecipe?
    /// 快速控制基线（拍摄曝光）；保存原图时写进库记录。
    @State private var directBaseline: PhotoEdit?
    @State private var directSaving = false
    /// 正在把原片入库并打开显影台：按钮显示进度，避免重复点击。
    @State private var directOpeningDevelop = false
    @State private var directToken = 0
    /// 取消令牌：关闭相机 / 重拍时立刻停止后台显影，避免继续占用内存与 CPU。
    @State private var directCancel: MDirectRenderToken?
    /// 直出按钮在根坐标系里的位置：预设菜单从按钮下方弹出，而不是从屏幕顶部下移。
    @State private var directButtonFrame: CGRect = .zero
    /// 成片页的片边：默认沿用跨照片记忆（冷启动关闭）。
    @State private var directBorder = MFilmBorderMemory.load() ?? MFilmBorderConfig()
    @State private var directBorderOpen = false
    /// 片边面板实测高度：面板展开时按它缩放并上移预览，保证整张照片露出。
    @State private var directBorderPanelHeight: CGFloat = 480
    /// 未加片边的成片预览：换片边时只重合成这一张，不重新显影。
    @State private var directPreviewCG: CGImage?
    /// 直出画幅比例：拍摄仍是 RAW 全幅，渲染时居中裁切，并写进 cropData。
    @AppStorage("m.directAspect") private var directAspectRaw: String = MDirectAspect.original.rawValue
    /// 直出分辨率档位：按总像素显示，渲染时按目标长边解码。
    @AppStorage("m.directResolution") private var directResolutionRaw: String = MDirectResolution.maximum.rawValue

    private var directAspect: MDirectAspect {
        MDirectAspect(rawValue: directAspectRaw) ?? .original
    }

    private var directResolution: MDirectResolution {
        MDirectResolution(rawValue: directResolutionRaw) ?? .maximum
    }

    /// 传感器撑不起所选档位时（如切到前置）退回 MAX，避免放大出图。
    private var effectiveResolution: MDirectResolution {
        let edge = camera.maxPhotoEdge
        if edge > 0, !directResolution.available(forMaxEdge: edge) { return .maximum }
        return directResolution
    }

    /// 分辨率菜单：传感器尺寸未知时先全量展示，就绪后按最大长边过滤。
    private var selectableResolutions: [MDirectResolution] {
        let edge = camera.maxPhotoEdge
        guard edge > 0 else { return MDirectResolution.allCases }
        return MDirectResolution.allCases.filter { $0.available(forMaxEdge: edge) }
    }

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

            // 显影独立页：不再把相机取景留在背后。相机已 stop，黑色背景只承载相纸与进度。
            if directCard == nil {
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
            }

            if let hint {
                hintPill(hint)
                    .zIndex(12)
            }

            // 常驻一层透明 GeometryReader：开关只控制内部面板的插入/移除，
            // 这样面板的 scale 过渡才会真正生效。此前把过渡挂在外层条件插入的
            // GeometryReader 上，SwiftUI 会先用默认 opacity 过渡整层淡入，
            // 面板看起来就是「渐显」而不是从按钮下方弹出来。
            directPickerLayer
                .allowsHitTesting(directPickerOpen)

            if let directCard {
                directCardView(directCard)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .coordinateSpace(name: "cameraRoot")
        .onPreferenceChange(MDirectButtonFrameKey.self) { directButtonFrame = $0 }
        .background(MColor.canvas)
        .preferredColorScheme(.dark)
        .onAppear {
            camera.start()
            syncLevelMonitor()
            normalizeDirectSelection()
            showDebugDirectImageIfNeeded()
            if DebugLaunch.directPicker {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    withAnimation(Self.directPickerFade) { directPickerOpen = true }
                }
            }
        }
        .onDisappear {
            cancelCountdown()
            level.stop()
            camera.stop()
            directCancel?.cancel()
            directToken += 1
            if !directSaving {
                if let raw = directRawURL { try? FileManager.default.removeItem(at: raw) }
                if case .ready(let result) = directCard {
                    try? FileManager.default.removeItem(at: result.url)
                }
            }
        }
        // 去系统设置授权后回到前台：重新读权限并补启动。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                cancelCountdown()
                level.stop()
                return
            }
            camera.refreshPermission()
            syncLevelMonitor()
        }
        .onChange(of: levelEnabled) { _, _ in syncLevelMonitor() }
        .onChange(of: countdown) { _, _ in syncLevelMonitor() }
        .onChange(of: camera.permission) { _, _ in syncLevelMonitor() }
        .onChange(of: camera.unusableReason) { _, _ in syncLevelMonitor() }
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
        ZStack {
            HStack(spacing: 8) {
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

                // 直出模式：RAW 标签换成画幅比例按钮，点击选择裁切比例。
                if directMode {
                    Menu {
                        Section("画幅") {
                            ForEach(MDirectAspect.allCases) { option in
                                Button {
                                    MHaptic.tick()
                                    directAspectRaw = option.rawValue
                                } label: {
                                    if directAspect == option {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        }
                        Section("分辨率") {
                            ForEach(selectableResolutions) { option in
                                Button {
                                    MHaptic.tick()
                                    directResolutionRaw = option.rawValue
                                } label: {
                                    if directResolution == option {
                                        Label(option.label, systemImage: "checkmark")
                                    } else {
                                        Text(option.label)
                                    }
                                }
                            }
                        }
                    } label: {
                        aspectBadge
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    rawBadge
                }
            }

            // 工具按钮整体居中，RAW 标签仍在右侧。
            HStack(spacing: 8) {
                cameraToolButton(icon: "timer", active: timerSeconds > 0,
                                 badge: timerSeconds > 0 ? "\(timerSeconds)s" : nil,
                                 label: timerMenuOpen ? "收起计时器菜单" : "拍摄计时器") {
                    withAnimation(MMotion.pill) { timerMenuOpen.toggle() }
                }

                if timerMenuOpen {
                    timerMenuRow
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.45, anchor: .leading)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.45, anchor: .leading)
                                .combined(with: .opacity)
                        ))
                } else {
                    cameraToolButton(icon: "square.grid.3x3", active: gridEnabled,
                                     label: gridEnabled ? "关闭网格线" : "显示网格线") {
                        withAnimation(MMotion.quick) { gridEnabled.toggle() }
                    }

                    directModeButton
                }
            }
            .animation(MMotion.pill, value: timerMenuOpen)
        }
        .padding(.horizontal, 16)
        // 先定 44pt 内容高度，再加安全区上边距；顺序反过来会让 51pt 的 padding
        // 被 44pt 的 frame 居中压缩，按钮实际会跑到状态栏 / 灵动岛下面。
        .frame(height: 44)
        .padding(.top, insets.top + 4)
    }

    /// Spektra 只拍 RAW：这里只做状态显示，不提供开关。
    private var rawBadge: some View {
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

    /// 直出模式的画幅按钮：与 RAW 标签同位同尺寸，显示当前比例。
    private var aspectBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "crop")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MColor.brass)
            Text(directAspect.label)
                .font(.mSans(10, .semibold))
                .foregroundStyle(MColor.text1)
            Text(effectiveResolution.label)
                .font(.mSans(10, .semibold))
                .foregroundStyle(MColor.brassHigh)
            Text("RAW")
                .font(.mSans(10, .medium))
                .foregroundStyle(MColor.text4)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .contentShape(Capsule())
        .accessibilityLabel("画幅比例 \(directAspect.label)")
    }

    private func cameraToolButton(icon: String, active: Bool, badge: String? = nil,
                                  label: String, action: @escaping () -> Void) -> some View {
        Button {
            MHaptic.tick()
            action()
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(active ? MColor.brassInk : MColor.text1)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(active ? MColor.brass : Color.white.opacity(0.08)))
                if let badge {
                    Text(badge)
                        .font(.mSans(7.5, .semibold))
                        .foregroundStyle(active ? MColor.brassInk : MColor.text2)
                        .padding(.horizontal, 4)
                        .frame(height: 12)
                        .background(Capsule().fill(MColor.surface1.opacity(0.9)))
                        .offset(y: 12)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    private var directModeButton: some View {
        Button {
            if directLongPressed {
                directLongPressed = false
                return
            }
            // 菜单开着时，再点一次按钮只负责收回，不切换直出状态。
            if directPickerOpen {
                withAnimation(Self.directPickerFade) { directPickerOpen = false }
                return
            }
            MHaptic.tick()
            withAnimation(MMotion.quick) {
                directMode.toggle()
            }
            if directMode {
                showHint("长按选择预设")
            }
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(directMode ? MColor.brassInk : MColor.text1)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(directMode ? MColor.brass : Color.white.opacity(0.08)))
                if directMode {
                    Circle()
                        .fill(MColor.brassInk)
                        .frame(width: 3, height: 3)
                        .offset(y: 12)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.92))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MDirectButtonFrameKey.self,
                    value: proxy.frame(in: .named("cameraRoot"))
                )
            }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                directLongPressed = true
                normalizeDirectSelection()
                MHaptic.medium()
                withAnimation(Self.directPickerFade) { directPickerOpen = true }
            }
        )
        .accessibilityLabel(directMode ? "关闭直出模式" : "打开直出模式")
        .accessibilityHint("长按选择显影与调色预设")
    }

    /// 计时器二级菜单：原地向右展开，把网格与直出按钮挤出去；再点计时器收回。
    private var timerMenuRow: some View {
        HStack(spacing: 3) {
            ForEach([0, 3, 5, 10], id: \.self) { seconds in
                Button {
                    MHaptic.tick()
                    timerSeconds = seconds
                    withAnimation(MMotion.pill) { timerMenuOpen = false }
                } label: {
                    Text(seconds == 0 ? "关" : "\(seconds)")
                        .font(.mSans(11, .semibold).monospacedDigit())
                        .foregroundStyle(timerSeconds == seconds ? MColor.brassInk : MColor.text2)
                        .frame(width: 38, height: 34)
                        .background(
                            Capsule().fill(timerSeconds == seconds
                                           ? MColor.brass
                                           : Color.white.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(MPressStyle(scale: 0.92))
                .accessibilityLabel(seconds == 0 ? "关闭计时器" : "\(seconds) 秒计时")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))
        .frame(height: 40)
    }

    // MARK: - 取景辅助

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                for index in 1...2 {
                    let x = geo.size.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))

                    let y = geo.size.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.32), lineWidth: 0.6)
            .shadow(color: .black.opacity(0.25), radius: 1)
        }
        .allowsHitTesting(false)
    }

    private func countdownOverlay(_ seconds: Int) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { cancelCountdown() }

            // 只有倒计时本身：数字 + 每秒走一圈的环，不再出现「轻点取消」等说明文字。
            MCountdownDial(seconds: seconds)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 取景

    private var viewfinder: some View {
        ZStack {
            Color.black

            preview

            if gridEnabled {
                gridOverlay
                    .transition(.opacity)
            }

            if levelEnabled,
               camera.permission == .authorized,
               camera.unusableReason == nil,
               countdown == nil {
                MLevelOverlay(monitor: level)
                    .transition(.opacity)
            }

            if let countdown {
                countdownOverlay(countdown)
                    .transition(.opacity)
            }

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
        .animation(MMotion.state, value: levelEnabled)
        .animation(MMotion.state, value: camera.permission)
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
                mirrorPreview: mirrorFront && camera.isFront,
                volumeShutter: volumeShutter,
                onVolumeShutter: { capture() },
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

    // MARK: - 直出模式

    private struct MDirectDevelopEntry: Identifiable {
        let id: String
        let name: String
        let note: String
        let filmID: String
    }

    private struct MDirectGradeEntry: Identifiable {
        let id: String
        let name: String
        let note: String
        let paperID: String
    }

    private var developPickerEntries: [MDirectDevelopEntry] {
        MobileDevelopPresets.all.map {
            MDirectDevelopEntry(id: $0.id, name: $0.name, note: $0.note, filmID: $0.filmID)
        } + MDevelopPresetStore.shared.userPresets.map {
            MDirectDevelopEntry(id: $0.id, name: $0.name,
                                note: "我的 · \(MobileCatalog.filmName($0.filmID))",
                                filmID: $0.filmID)
        }
    }

    private var gradePickerEntries: [MDirectGradeEntry] {
        GradePresetStore.shared.all.map {
            MDirectGradeEntry(id: $0.id, name: $0.name,
                              note: $0.builtin ? "内置" : "我的预设",
                              paperID: Self.stablePaperID(for: $0.id))
        }
    }

    /// 调色预设没有自带图标：按 id 稳定地分配一张相纸 SVG，重复也没关系。
    private static func stablePaperID(for id: String) -> String {
        guard !MobileCatalog.papers.isEmpty else { return "" }
        let hash = id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
        return MobileCatalog.papers[hash % MobileCatalog.papers.count].id
    }

    private var selectedDevelopBuiltin: MDevelopPreset? {
        MobileDevelopPresets.all.first { $0.id == directDevelopID }
            ?? MobileDevelopPresets.all.first
    }

    private var selectedDevelopUser: MUserDevelopPreset? {
        MDevelopPresetStore.shared.preset(id: directDevelopID)
    }

    private var selectedGradePreset: GradePreset? {
        GradePresetStore.shared.all.first { $0.id == directGradeID }
            ?? GradePresetStore.shared.preset(id: "builtin:neutral")
            ?? GradePresetStore.shared.all.first
    }

    /// 预设被删除后把选择回退到默认，并写回 ID，避免选择器出现“没有勾选但实际在用默认”的错觉。
    private func normalizeDirectSelection() {
        let developExists = MobileDevelopPresets.all.contains { $0.id == directDevelopID }
            || MDevelopPresetStore.shared.preset(id: directDevelopID) != nil
        if !developExists {
            directDevelopID = MobileDevelopPresets.all.first?.id ?? "standard"
        }
        if GradePresetStore.shared.preset(id: directGradeID) == nil {
            directGradeID = "builtin:neutral"
        }
    }

    /// 从直出按钮下方展开的预设面板：上下两排，各自左右滚动。
    /// 宽度与屏幕齐平，用渐显出现。
    private var directPickerLayer: some View {
        GeometryReader { geo in
            let panelWidth = geo.size.width
            // 一屏正好 5 张卡、四道 4pt 间距：左右边缘与面板内边距严格对齐，
            // 不再出现第 5 张被裁掉半张的情况。
            let cardWidth = (panelWidth - 24 - 16) / 5
            let topY = directButtonFrame == .zero
                ? insets.top + 52
                : directButtonFrame.maxY + 8

            ZStack(alignment: .topLeading) {
                if directPickerOpen {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            directLongPressed = false
                            withAnimation(Self.directPickerFade) { directPickerOpen = false }
                        }
                        .transition(.opacity)

                    directPickerPanel(cardWidth: cardWidth)
                        .frame(width: panelWidth)
                        .offset(y: topY)
                        .transition(.opacity)
                }
            }
        }
    }

    /// 预设面板的渐显：短促的淡入淡出，不做缩放。
    private static let directPickerFade = Animation.easeOut(duration: 0.18)

    private func directPickerPanel(cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            directPickerSectionHead("显影", selected: developPickerName)
            MHScrollRail(itemCount: developPickerEntries.count,
                         itemWidth: cardWidth, spacing: 4,
                         leading: 0, trailing: 0, itemHeight: 82,
                         fadeColor: .clear) {
                ForEach(developPickerEntries) { entry in
                    let film = MobileCatalog.film(id: entry.filmID) ?? MobileCatalog.films[0]
                    directPresetCard(width: cardWidth,
                                     title: entry.name, note: entry.note,
                                     selected: entry.id == directDevelopID) {
                        MFilmStockIcon(film: film, size: 28)
                    } action: {
                        MHaptic.tick()
                        directDevelopID = entry.id
                    }
                }
            }
            .frame(height: 82)

            Rectangle()
                .fill(MColor.hairline)
                .frame(height: 1)

            directPickerSectionHead("调色", selected: gradePickerName)
            MHScrollRail(itemCount: gradePickerEntries.count,
                         itemWidth: cardWidth, spacing: 4,
                         leading: 0, trailing: 0, itemHeight: 82,
                         fadeColor: .clear) {
                ForEach(gradePickerEntries) { entry in
                    let paper = MobileCatalog.papers.first { $0.id == entry.paperID }
                        ?? MobileCatalog.papers[0]
                    directPresetCard(width: cardWidth,
                                     title: entry.name, note: entry.note,
                                     selected: entry.id == directGradeID) {
                        MPaperStockIcon(paper: paper, size: 28)
                    } action: {
                        MHaptic.tick()
                        directGradeID = entry.id
                    }
                }
            }
            .frame(height: 82)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MColor.surface2.opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.38), radius: 26, y: 12)
    }

    private func directPickerSectionHead(_ title: String, selected: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .mLabel(8, color: MColor.text4)
            Spacer(minLength: 4)
            Text(selected)
                .font(.mSans(8.5, .medium))
                .foregroundStyle(MColor.brassHigh)
                .lineLimit(1)
        }
    }

    private var developPickerName: String {
        developPickerEntries.first { $0.id == directDevelopID }?.name ?? "—"
    }

    private var gradePickerName: String {
        gradePickerEntries.first { $0.id == directGradeID }?.name ?? "—"
    }

    private func directPresetCard<Icon: View>(
        width: CGFloat,
        title: String, note: String, selected: Bool,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? MColor.brassWash : MColor.surface3.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected ? MColor.brass.opacity(0.9)
                                                       : MColor.hairline,
                                              lineWidth: 1)
                        )
                    icon()
                }

                Text(title)
                    .font(.mSans(8, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MColor.text1 : MColor.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(width: width)

                Text(note)
                    .font(.mSans(7, .medium))
                    .foregroundStyle(selected ? MColor.brassHigh.opacity(0.9) : MColor.text4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // 注释比卡片宽时会被相邻项裁掉；锁到卡片宽度内缩放/截断。
                    .frame(width: width)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
        .accessibilityLabel("\(title)，\(note)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 直出成片的片边

    private var directBorderName: String {
        MFilmBorderPreset.preset(id: directBorder.preset)?.name ?? "自定义"
    }

    private func directBorderMatches(_ preset: MFilmBorderPreset) -> Bool {
        guard directBorder.enabled == preset.config.enabled else { return false }
        return preset.config.matches(directBorder)
    }

    private var directBorderEnabled: Binding<Bool> {
        Binding(
            get: { directBorder.enabled },
            set: { isOn in
                var value = directBorder
                value.enabled = isOn
                if isOn, value.preset == "none",
                   let preset = MFilmBorderPreset.preset(id: "kodak135") {
                    value = value.matches(MFilmBorderConfig()) ? preset.config : value
                    value.enabled = true
                }
                if !isOn { value.preset = "none" }
                directBorder = value.normalized()
            }
        )
    }

    private func applyDirectBorder(_ preset: MFilmBorderPreset) {
        var value = preset.config
        value.enabled = preset.id != "none"
        value.preset = preset.id
        directBorder = value.normalized()
    }

    /// 片边参数绑定：所有改动统一归一化，随后由 onChange 记忆并重合成预览。
    private var directBorderConfig: Binding<MFilmBorderConfig> {
        Binding(
            get: { directBorder },
            set: { directBorder = $0.normalized() }
        )
    }

    private static let directBorderSpring = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// 直出显影卡片最短展示时长（秒），避免小图一闪而过（§5.3）。
    nonisolated private static let directCardMinDisplay: Double = 1.2

    /// 成片卡片按钮统一外壳：44pt 触控目标 + 圆角底，四个按钮共用一套样式。
    private func directCardButton<Label: View>(
        background: Color,
        disabled: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// 片边面板常驻在成片页最上层；用透明遮罩而不是系统 sheet，
    /// 这样预览不会被压暗，也不会被系统 sheet 的灰色蒙层盖住。
    private var directBorderLayer: some View {
        ZStack(alignment: .bottom) {
            if directBorderOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Self.directBorderSpring) { directBorderOpen = false }
                    }
                    .transition(.identity)

                directBorderPanel
                    .transition(.move(edge: .bottom))
            }
        }
        .allowsHitTesting(directBorderOpen)
    }

    private var directBorderPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(MColor.text4.opacity(0.35))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Text("片边")
                    .font(.mSans(13, .semibold))
                    .foregroundStyle(MColor.text1)
                Spacer()
                Button("完成") {
                    withAnimation(Self.directBorderSpring) { directBorderOpen = false }
                }
                .font(.mSans(11, .semibold))
                .foregroundStyle(MColor.brassHigh)
            }

            MToggleRow(label: "启用片边", isOn: directBorderEnabled, compact: true)

            MHScrollRail(itemCount: MFilmBorderPreset.all.count, itemWidth: 86,
                         spacing: 8, leading: 0, trailing: 0,
                         itemHeight: 84, fadeColor: .clear) {
                ForEach(MFilmBorderPreset.all) { preset in
                    MFilmBorderPresetCard(preset: preset,
                                         selected: directBorderMatches(preset)) {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { applyDirectBorder(preset) }
                    }
                }
            }
            .frame(height: 84)

            if directBorder.enabled {
                Divider()
                    .overlay(MColor.hairline)
                    .padding(.vertical, 2)

                ScrollView(.vertical) {
                    MFilmBorderControls(config: directBorderConfig)
                        .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.top)
                .frame(maxHeight: 320)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, max(12, insets.bottom))
        .frame(maxWidth: .infinity)
        .background(MPanelHeightReporter())
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22,
                                   style: .continuous)
                .fill(MColor.surface1)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// 换片边只重合成预览：显影结果保持不变，保存时再按同一份参数合成成片。
    private func refreshDirectBorderPreview() {
        guard let cg = directPreviewCG else { return }
        let config = directBorder
        guard config.enabled else {
            directPhoto = MImage.make(cgImage: cg)
            return
        }
        let filmID = directEdit?.filmStock ?? MobileCatalog.films.first?.id ?? ""
        let rawURL = directRawURL
        Task.detached(priority: .userInitiated) {
            // 日期戳内容取自拍摄文件，保证预览与保存的成片一致。
            let stamp = rawURL.map { MFilmBorderRenderer.captureStamp(url: $0) }
                ?? (date: "", time: "")
            let framed = MFilmBorderRenderer.preview(
                photo: cg, config: config, filmID: filmID, photoID: "direct-preview",
                dateLabel: stamp.date, timeLabel: stamp.time)
            await MainActor.run {
                guard directBorder == config, let framed else { return }
                directPhoto = MImage.make(cgImage: framed)
            }
        }
    }

    private var directPhaseKey: Int {
        switch directCard {
        case .developing: return 0
        case .ready: return 1
        case .failed: return 2
        case nil: return -1
        }
    }

    private func directCardView(_ phase: MDirectCardPhase) -> some View {
        GeometryReader { geo in
            let panelHeight = directBorderOpen ? max(directBorderPanelHeight, 220) : 0
            // 面板上方的可见高度（扣除状态栏）：预览按它缩放，保证整张照片不被遮住。
            let available = max(180, geo.size.height - panelHeight - insets.top - 24)
            let contentHeight: CGFloat = 452
            let scale = directBorderOpen ? min(1, available / contentHeight) : 1

            ZStack {
                // 独立显影页：与主页同一底色，不渲染相机取景，也不让相机继续跑。
                MColor.app
                    .ignoresSafeArea()

                VStack(spacing: 22) {
                    directPhotoCard(phase)

                    VStack(spacing: 12) {
                        switch phase {
                        case .developing:
                            VStack(spacing: 8) {
                                ProgressView(value: min(max(directProgress, 0), 1))
                                    .progressViewStyle(.linear)
                                    .tint(MColor.brass)
                                    .frame(width: 176)
                                Text("正在显影 \(Int(min(max(directProgress, 0), 1) * 100))%")
                                    .font(.mSans(10, .medium).monospacedDigit())
                                    .foregroundStyle(MColor.text2)
                            }
                            .frame(height: 52)

                        case .ready(let result):
                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    directCardButton(background: Color.white.opacity(0.1),
                                                     disabled: directSaving || directOpeningDevelop) {
                                        MHaptic.light()
                                        retakeDirect(result)
                                    } label: {
                                        Text("重拍")
                                            .font(.mSans(11, .medium))
                                            .foregroundStyle(MColor.text1)
                                    }

                                    // 显影完成后仍然可以改片边：只重合成预览与成片，不再跑显影。
                                    directCardButton(background: Color.white.opacity(0.1),
                                                     disabled: directSaving || directOpeningDevelop) {
                                        MHaptic.tick()
                                        withAnimation(Self.directBorderSpring) { directBorderOpen = true }
                                    } label: {
                                        VStack(spacing: 1) {
                                            Image(systemName: "square.dashed")
                                                .font(.system(size: 12, weight: .medium))
                                            Text(directBorder.enabled ? directBorderName : "片边")
                                                .font(.mSans(8.5, .medium))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                        .foregroundStyle(MColor.brassHigh)
                                    }

                                    directCardButton(background: MColor.brass,
                                                     disabled: directSaving || directOpeningDevelop) {
                                        MHaptic.light()
                                        saveDirectResult(result)
                                    } label: {
                                        Group {
                                            if directSaving {
                                                ProgressView().controlSize(.small).tint(MColor.brassInk)
                                            } else {
                                                Text("保存").font(.mSans(11, .semibold))
                                            }
                                        }
                                        .foregroundStyle(MColor.brassInk)
                                    }
                                }

                                // 原片带拍摄时的显影 / 调色预设进显影台，不经过这张直出成片。
                                directCardButton(background: Color.white.opacity(0.1),
                                                 disabled: directSaving || directOpeningDevelop) {
                                    MHaptic.light()
                                    openDirectDevelop(result)
                                } label: {
                                    HStack(spacing: 5) {
                                        if directOpeningDevelop {
                                            ProgressView().controlSize(.small).tint(MColor.text1)
                                        } else {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 11, weight: .medium))
                                            Text("进入显影台")
                                                .font(.mSans(11, .medium))
                                        }
                                    }
                                    .foregroundStyle(MColor.text1)
                                }
                            }
                            .frame(width: 300)

                        case .failed(let message):
                            VStack(spacing: 10) {
                                Text(message)
                                    .font(.mSans(9.5, .medium))
                                    .foregroundStyle(MColor.filmRed)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 260)
                                HStack(spacing: 18) {
                                    Button("重拍") { retakeDirect(nil) }
                                        .font(.mSans(10.5, .medium))
                                        .foregroundStyle(MColor.text2)
                                    Button("重试") { retryDirect() }
                                        .font(.mSans(10.5, .semibold))
                                        .foregroundStyle(MColor.brassHigh)
                                }
                            }
                            .frame(minHeight: 52)
                        }
                    }
                    .animation(MMotion.state, value: directPhaseKey)
                }
                .padding(.horizontal, 24)
                // 片边面板打开时整体缩放并上移：整张照片落在面板上方的可见区域。
                .scaleEffect(scale)
                .offset(y: directBorderOpen ? (insets.top - panelHeight) / 2 : 0)
                .animation(Self.directBorderSpring, value: directBorderOpen)
            }
        }
        .onChange(of: directBorder) { _, value in
            MFilmBorderMemory.save(value)
            refreshDirectBorderPreview()
        }
        .onPreferenceChange(MPanelHeightKey.self) { height in
            guard height > 0, abs(height - directBorderPanelHeight) > 0.5 else { return }
            directBorderPanelHeight = height
        }
        .overlay { directBorderLayer }
        .overlay(alignment: .topTrailing) {
            Button {
                // 片边面板开着时，X 先收起面板，避免误把整张成片丢掉。
                if directBorderOpen {
                    withAnimation(Self.directBorderSpring) { directBorderOpen = false }
                } else {
                    cancelDirectAndClose()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MColor.text1)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle(scale: 0.9))
            .padding(.top, insets.top + 6)
            .padding(.trailing, 16)
            .accessibilityLabel("取消并关闭相机")
        }
    }

    /// 白色相纸卡：显影阶段盖一层逐渐褪去的白雾，不打断相机页的其他状态。
    /// 一旦启用片边，就撤掉白色卡纸与内边距，让带片边的画面完整显示，不再被白框遮住。
    private func directPhotoCard(_ phase: MDirectCardPhase) -> some View {
        let framed: Bool = {
            if case .ready = phase { return directBorder.enabled }
            return false
        }()
        return ZStack {
            if let directPhoto {
                MImage.swiftUI(directPhoto)
                    .resizable()
                    .aspectRatio(contentMode: framed ? .fit : .fill)
                    .id(directPreviewToken)
                    .transition(.opacity)
            } else {
                Color(white: 0.93)
            }

            if case .developing = phase {
                Color.white.opacity(max(0.05, 0.95 - directProgress * 0.9))
            }
        }
        .animation(MMotion.state, value: directPreviewToken)
        .animation(.linear(duration: 0.16), value: directProgress)
        .frame(width: framed ? 316 : 258, height: framed ? 380 : 344)
        .clipped()
        .padding(.horizontal, framed ? 0 : 9)
        .padding(.top, framed ? 0 : 9)
        .padding(.bottom, framed ? 0 : 30)
        .background(framed ? Color.clear : Color(hex: 0xF6F2E9))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(framed ? 0.32 : 0.5), radius: 26, y: 12)
    }

    /// 验收用：不按快门也能进直出成片页，检查片边面板与预览排版。
    private func showDebugDirectImageIfNeeded() {
        guard let name = DebugLaunch.directImage, directCard == nil else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        guard let loaded = try? ImageLoader.load(url: url, maxSize: 1200, allowEncoded: true),
              let cg = PreviewRenderer.cgImage(from: loaded.image) else { return }
        if let id = DebugLaunch.gradeBorder,
           let preset = MFilmBorderPreset.preset(id: id) {
            var value = preset.config
            value.enabled = preset.id != "none"
            value.preset = preset.id
            directBorder = value.normalized()
        }
        directPhoto = MImage.make(cgImage: cg)
        directPreviewCG = cg
        directCard = .ready(MDirectRenderResult(url: url, preview: cg, clampedEdge: nil))
        // 验收「进入显影台」时也要有可入库的原片与拍摄预设。
        directRawURL = url
        directBaseline = MDirectRenderer.makeBaseline(meta: MCameraCaptureMeta())
        let user = selectedDevelopUser
        directEdit = MDirectRenderer.makeEdit(builtin: user == nil ? selectedDevelopBuiltin : nil, user: user)
        if let gradePreset = selectedGradePreset {
            var ui = MGradeRecipe()
            let groups = gradePreset.appliedGroups
            ui.merge(gradePreset.recipe, groups: groups)
            directRecipe = ui.gradeRecipe(lutPath: groups.contains(.lut) ? gradePreset.recipe.lut.path : "")
        }
        refreshDirectBorderPreview()
        if DebugLaunch.directBorderPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(Self.directBorderSpring) { directBorderOpen = true }
            }
        }
        if DebugLaunch.directDevelop, case .ready(let result) = directCard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                openDirectDevelop(result)
            }
        }
    }

    private func beginDirect(_ shot: MCameraShot) {
        guard let gradePreset = selectedGradePreset else {
            showHint("直出预设不可用，请长按直出按钮重新选择")
            return
        }
        directToken += 1
        let token = directToken
        directSaving = false
        directProgress = 0
        // 显影是独立页面：立刻停相机与水平仪，把 CPU / 内存留给显影管线。
        camera.stop()
        level.stop()
        directCancel?.cancel()
        let cancel = MDirectRenderToken()
        directCancel = cancel
        withAnimation(MMotion.state) {
            directPhoto = shot.thumbnail
            directPreviewToken += 1
            directPreviewCG = nil
            directRawURL = shot.url
            directBorderOpen = false
            directCard = .developing
        }

        let user = selectedDevelopUser
        let builtin = user == nil ? selectedDevelopBuiltin : nil
        let edit = MDirectRenderer.makeEdit(builtin: builtin, user: user, meta: shot.meta)
        var ui = MGradeRecipe()
        let groups = gradePreset.appliedGroups
        ui.merge(gradePreset.recipe, groups: groups)
        let lutPath = groups.contains(.lut) ? gradePreset.recipe.lut.path : ""
        let recipe = ui.gradeRecipe(lutPath: lutPath)
        var settings = MDirectRenderSettings.fromPreferences()
        settings.aspect = directAspect
        settings.resolution = effectiveResolution
        if settings.downgradedFromEXR {
            showHint("相册不支持 EXR，直出已使用 JPEG")
        }
        let sourceURL = shot.url
        directEdit = edit
        directBaseline = MDirectRenderer.makeBaseline(meta: shot.meta)
        directRecipe = recipe

        let renderStart = CFAbsoluteTimeGetCurrent()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try MDirectRenderer.render(
                    sourceURL: sourceURL,
                    edit: edit,
                    grade: recipe,
                    settings: settings,
                    isCancelled: { cancel.isCancelled }
                ) { value in
                    // 进度最多每 1% 推一次主线程，显影动画不被高频回调打断。
                    Task { @MainActor in
                        guard token == directToken, !cancel.isCancelled else { return }
                        guard value >= 1 || value - directProgress >= 0.01 else { return }
                        directProgress = value
                    }
                }
                // §5.3：显影卡片最短展示 1.2s，小图秒完也不闪卡。
                // 动画不早于真实完成：这里等的只是渲染返回后的剩余展示时间。
                let remaining = Self.directCardMinDisplay - (CFAbsoluteTimeGetCurrent() - renderStart)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                await MainActor.run {
                    guard token == directToken, !cancel.isCancelled else {
                        try? FileManager.default.removeItem(at: result.url)
                        return
                    }
                    presentDirectReady(result)
                }
            } catch MDirectRenderer.RenderError.cancelled {
                // 用户已经重拍 / 关闭：静默退出，不弹错误卡片。
            } catch {
                NSLog("MDirect failed: %@", String(describing: error))
                await MainActor.run {
                    guard token == directToken, !cancel.isCancelled else { return }
                    withAnimation(MMotion.state) {
                        directCard = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// 渲染真正完成：进度跳 1.0、切成片卡片、触感与降级提示。
    @MainActor
    private func presentDirectReady(_ result: MDirectRenderResult) {
        withAnimation(MMotion.state) {
            directProgress = 1
            if let preview = result.preview {
                directPreviewCG = preview
                directPhoto = MImage.make(cgImage: preview)
                directPreviewToken += 1
            }
            directCard = .ready(result)
        }
        // 成片页沿用记忆里的片边；没有开启时保持无片边。
        refreshDirectBorderPreview()
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        if let clamped = result.clampedEdge {
            showHint("已按内存上限 \(clamped) px 渲染")
        } else if result.usedFallback {
            showHint("RAW 解码较慢 · 已使用内嵌预览")
        }
    }

    private func retakeDirect(_ result: MDirectRenderResult?) {
        guard !directSaving, !directOpeningDevelop else { return }
        directCancel?.cancel()
        directCancel = nil
        directToken += 1
        if let result { try? FileManager.default.removeItem(at: result.url) }
        if let raw = directRawURL { try? FileManager.default.removeItem(at: raw) }
        withAnimation(MMotion.state) {
            directCard = nil
            directPhoto = nil
            directPreviewCG = nil
            directRawURL = nil
            directEdit = nil
            directBaseline = nil
            directRecipe = nil
            directProgress = 0
            directBorderOpen = false
        }
        directSaving = false
        camera.start()
        syncLevelMonitor()
    }

    private func retryDirect() {
        guard let raw = directRawURL else { return }
        let shot = MCameraShot(
            url: raw, thumbnail: directPhoto,
            meta: MCameraCaptureMeta(exposureBias: camera.exposureBias,
                                    temperature: camera.temperature))
        directCard = nil
        beginDirect(shot)
    }

    private func cancelDirectAndClose() {
        guard !directSaving, !directOpeningDevelop else { return }
        directCancel?.cancel()
        directCancel = nil
        directToken += 1
        if let raw = directRawURL { try? FileManager.default.removeItem(at: raw) }
        if case .ready(let result) = directCard {
            try? FileManager.default.removeItem(at: result.url)
        }
        withAnimation(MMotion.state) { directCard = nil; directBorderOpen = false }
        directRawURL = nil
        onClose()
    }

    private func saveDirectResult(_ result: MDirectRenderResult) {
        guard !directSaving, !directOpeningDevelop,
              let raw = directRawURL,
              let edit = directEdit,
              let recipe = directRecipe else { return }
        directSaving = true
        let request = MDirectSaveRequest(rawURL: raw, renderedURL: result.url,
                                         edit: edit, grade: recipe,
                                         border: directBorder,
                                         baseline: directBaseline,
                                         aspect: directAspect)
        Task {
            let outcome = await onDirectSave(request)
            await MainActor.run {
                directSaving = false
                switch outcome {
                case .saved(let message):
                    withAnimation(MMotion.state) {
                        directCard = nil
                        directPhoto = nil
                        directPreviewCG = nil
                        directRawURL = nil
                        directEdit = nil
                        directBaseline = nil
                        directRecipe = nil
                        directBorderOpen = false
                    }
                    camera.start()
                    syncLevelMonitor()
                    showHint(message)
                case .denied:
                    showHint("无法写入相册，请在设置中允许访问")
                case .failed(let message):
                    showHint(message)
                }
            }
        }
    }

    /// 直出成片页「进入显影台」：原片入库，并沿用拍摄时选择的显影 / 调色预设。
    private func openDirectDevelop(_ result: MDirectRenderResult) {
        guard !directSaving, !directOpeningDevelop,
              let raw = directRawURL,
              let edit = directEdit,
              let recipe = directRecipe else { return }
        directOpeningDevelop = true
        let request = MDirectDevelopRequest(
            rawURL: raw, renderedURL: result.url, edit: edit, grade: recipe,
            baseline: directBaseline, aspect: directAspect)
        Task {
            let outcome = await onDirectDevelop(request)
            await MainActor.run {
                directOpeningDevelop = false
                if case .failed(let message) = outcome {
                    showHint(message)
                }
            }
        }
    }

    // MARK: - 动作

    private func capture() {
        guard countdown == nil else { return }
        guard directCard == nil, !directSaving else {
            showHint("正在显影，请稍候")
            return
        }
        guard camera.canCapture else {
            showHint(camera.blockedHint)
            return
        }
        timerMenuOpen = false
        if timerSeconds > 0 {
            startCountdown()
        } else {
            fire()
        }
    }

    private func fire() {
        MHaptic.medium()
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.8 }
        withAnimation(.easeIn(duration: 0.24).delay(0.07)) { flashOpacity = 0 }
        camera.capture()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        let total = timerSeconds
        withAnimation(MMotion.state) { countdown = total }
        countdownTask = Task { @MainActor in
            var remaining = total
            while remaining > 0 {
                if Task.isCancelled { return }
                withAnimation(MMotion.state) { countdown = remaining }
                MHaptic.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
            }
            withAnimation(MMotion.state) { countdown = nil }
            countdownTask = nil
            fire()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation(MMotion.state) { countdown = nil }
    }

    private func syncLevelMonitor() {
        if levelEnabled, scenePhase == .active,
           directCard == nil, countdown == nil,
           camera.permission == .authorized, camera.unusableReason == nil {
            level.start()
        } else {
            level.stop()
        }
    }

    /// 拍完交给根视图异步入库；入库完成后由根视图删除临时文件，
    /// 相册写入也由引擎在入库后统一处理，避免两边争抢同一个临时文件。
    private func handleShot() {
        guard let shot = camera.lastShot else { return }
        if directMode {
            beginDirect(shot)
        } else {
            // 关闭「拍摄后进入显影台」时停留取景页，可继续连拍。
            onCaptured(shot.url, enterDevelopAfterShot, shot.meta)
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
/// AVCaptureVideoPreviewLayer 的 SwiftUI 容器；点击对焦，长按锁定 AE/AF，按住上下拖动改 ISO。
struct MCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrorPreview: Bool
    let volumeShutter: Bool
    let onVolumeShutter: () -> Void
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
        view.setMirrored(mirrorPreview)
        view.setVolumeShutter(enabled: volumeShutter, handler: onVolumeShutter)
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
    /// iOS 17.2 才有的类型：用 AnyObject 存储，避免整个类被标成 17.2+。
    private var captureInteraction: AnyObject?

    /// 镜像只作用于预览；RAW 原片不翻转（DNG 无法无损镜像）。
    func setMirrored(_ mirrored: Bool) {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    func setVolumeShutter(enabled: Bool, handler: @escaping () -> Void) {
        guard #available(iOS 17.2, *) else { return }
        if captureInteraction == nil, enabled {
            let interaction = AVCaptureEventInteraction { event in
                guard event.phase == .ended else { return }
                handler()
            }
            addInteraction(interaction)
            captureInteraction = interaction
        }
        (captureInteraction as? AVCaptureEventInteraction)?.isEnabled = enabled
    }

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

// MARK: - 水平仪

/// 极简水平仪。
/// - 水平：三根横杠整组绕自身中心旋转，始终与地平线平行，不自上而下平移。
/// - 俯拍：两个十字重叠，白十字固定、另一十字随重力偏移，重叠即水平。
/// 没有任何文字读数；水平模式按设备方向旋转，横屏拿手机时参考线会跟着转。
private struct MLevelOverlay: View {
    @ObservedObject var monitor: MLevelMonitor

    /// 水平仪只用白色：固定参考线略暗，移动线略亮，对齐后一起提到最亮。
    private var fixedTint: Color {
        Color.white.opacity(monitor.isLevel ? 0.9 : 0.55)
    }

    private var movingTint: Color {
        Color.white.opacity(monitor.isLevel ? 1.0 : 0.92)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if monitor.mode == .horizontal {
                    horizontal
                } else {
                    topDown
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.06), value: monitor.roll)
        .animation(.linear(duration: 0.06), value: monitor.pitch)
        .animation(.easeOut(duration: 0.18), value: monitor.isLevel)
        .animation(.easeOut(duration: 0.2), value: monitor.deviceAngle)
    }

    /// 三根杠：左右两根是固定参考线，只跟着握持方向（横屏转 90°）；
    /// 中间那根才随重力倾斜转动。俯拍的双十字旋转对称，不跟随设备方向。
    private var horizontal: some View {
        HStack(spacing: 7) {
            bar(width: 30, color: fixedTint)
            bar(width: 46, color: movingTint)
                .rotationEffect(.degrees(monitor.roll))
            bar(width: 30, color: fixedTint)
        }
        .rotationEffect(.degrees(monitor.deviceAngle))
        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: 0.8)
    }

    private var topDown: some View {
        // 世界竖直方向的屏幕投影直接决定气泡方向与幅度：倾斜越大偏移越大。
        let dx = min(16, max(-16, monitor.planarTilt.width * 55))
        let dy = min(16, max(-16, monitor.planarTilt.height * 55))
        return ZStack {
            plus(size: 32, thickness: 0.8, color: fixedTint)
            plus(size: 32, thickness: 0.8, color: movingTint)
                .offset(x: monitor.isLevel ? 0 : dx,
                        y: monitor.isLevel ? 0 : dy)
        }
        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }

    private func plus(size: CGFloat, thickness: CGFloat, color: Color) -> some View {
        ZStack {
            Capsule().fill(color).frame(width: size, height: thickness)
            Capsule().fill(color).frame(width: thickness, height: size)
        }
    }
}

// MARK: - 倒计时

/// 倒计时只保留数字与每秒走一圈的环，不显示任何说明文字；点屏幕仍可取消。
private struct MCountdownDial: View {
    let seconds: Int
    @State private var ringProgress: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 3)
                .frame(width: 118, height: 118)

            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(Color.white.opacity(0.92),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 118, height: 118)

            Text("\(seconds)")
                .font(.system(size: 60, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .id(seconds)
        .onAppear {
            ringProgress = 1
            withAnimation(.linear(duration: 1)) { ringProgress = 0 }
        }
    }
}

// MARK: - 直出辅助

/// 线程安全的取消令牌：关闭相机 / 重拍后让后台显影尽快退出。
private final class MDirectRenderToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 直出按钮在根坐标系中的位置，供预设面板从按钮下方弹出。
private struct MDirectButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
