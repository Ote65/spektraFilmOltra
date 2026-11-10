import SwiftUI

struct MobileRootView: View {
    @StateObject private var engine = MobileEngine()
    @Environment(\.mHousing) private var housingSetting

    @State private var screen: MScreen = .home
    @State private var develop: MobileDevelopSession?
    @State private var grade: MobileGradeSession?
    @State private var gradeEntry: MGradeEntry = .direct
    @State private var gradeReturn: MScreen = .home
    @State private var toast: String? = nil
    @State private var toastToken = 0
    @State private var debugOpened = false

    // 显影 → 调色的「吸入」过渡
    @State private var metrics: MSafeInsets = .fallback
    @State private var flightPhase: MFlightPhase = .idle
    @State private var flightImage: MPlatformImage?
    @State private var flightRect: CGRect = .zero
    @State private var flightRadius: CGFloat = 3
    @State private var flightOpacity: Double = 0
    @State private var developPreviewHidden = false

    private enum MFlightPhase { case idle, sucking }

    init() {
        let args = ProcessInfo.processInfo.arguments
        var start: MScreen = .home
        if let index = args.firstIndex(of: "--screen"), args.indices.contains(index + 1) {
            switch args[index + 1] {
            case "camera": start = .camera
            case "develop": start = .develop
            case "grade": start = .grade
            default: break
            }
        }
        _screen = State(initialValue: start)
    }

    var body: some View {
        content(insets: metrics)
            .environment(\.mSafeInsets, metrics)
            // 模拟器上 `machineIdentifier()` 返回宿主架构，`detect()` 永远判成灵动岛，
            // 刘海分支在模拟器里跑不到。`--housing notch` 用来强制走刘海路径做视觉验收。
            .environment(\.mHousing, DebugLaunch.housingOverride)
            .ignoresSafeArea()
            .background(MColor.app)
            .preferredColorScheme(.dark)
    }

    private func content(insets: MSafeInsets) -> some View {
        ZStack {
            HomeScreen(
                engine: engine,
                onOpenDevelop: { photo in
                    openDevelop(photo.id)
                },
                onOpenGrade: { photo in
                    openGrade(photo.id, entry: .direct, returningTo: .home)
                },
                onOpenCamera: openCamera,
                onToast: showToast
            )
            .offset(x: screen == .home || screen == .camera ? 0 : -72)
            .allowsHitTesting(screen == .home)

            if screen == .camera {
                CameraScreen(
                    onClose: closeCamera,
                    onCaptured: handleCapture
                )
                .transition(.opacity)
                .zIndex(3)
            }

            if let develop {
                DevelopScreen(
                    session: develop,
                    onBack: { closeDevelop() },
                    onOpenGrade: { image, rect in
                        beginSuck(image: image, from: rect, photoID: develop.photoID, insets: insets)
                    },
                    previewHidden: developPreviewHidden,
                    onToast: showToast
                )
                .offset(x: screen == .grade && gradeReturn == .develop ? -72 : 0)
                .allowsHitTesting(screen == .develop)
                .zIndex(1)
            }

            if let grade {
                GradeScreen(
                    session: grade,
                    entry: gradeEntry,
                    onBack: { closeGrade() },
                    onGoHome: goHome,
                    onToast: showToast
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.mSans(11, .medium))
                        .foregroundStyle(MColor.text1)
                        .padding(.horizontal, 15)
                        .frame(height: 38)
                        .background(Capsule().fill(MColor.surface3.opacity(0.96)))
                        .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.bottom, insets.bottom + 76)
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
                .allowsHitTesting(false)
            }

            if let flightImage {
                MImage.swiftUI(flightImage)
                    .resizable()
                    .frame(
                        width: max(1, flightRect.width),
                        height: max(1, flightRect.height)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: max(0, flightRadius), style: .continuous)
                    )
                    .position(x: flightRect.midX, y: flightRect.midY)
                    .opacity(flightOpacity)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }
        }
        .animation(MMotion.push, value: screen)
        .task {
            guard !debugOpened else { return }
            debugOpened = true
            // 窗口就绪后再取真实安全区：此时 UIWindow 已经完成第一次布局。
            let current = MScreenMetrics.current()
            if current != metrics { metrics = current }
            if DebugLaunch.probeGeometry {
                let housing = MDeviceHousing.resolved(housingSetting)
                let opening = MDeviceHousing.opening(kind: housing, insets: current)
                NSLog("MGeometry size=%.0fx%.0f top=%.0f bottom=%.0f housing=%@ opening=%@",
                      current.size.width, current.size.height,
                      current.top, current.bottom, housing.rawValue,
                      NSCoder.string(for: opening))
            }
            guard let first = engine.photos.first else { return }
            // 首帧直达：此时窗口还没完成第一次布局，带 transition 插入会让视图停在屏幕外。
            switch screen {
            case .develop:
                develop = engine.openDevelop(photoID: first.id)
            case .grade:
                grade = engine.openGrade(photoID: first.id, entry: .direct)
            case .home, .camera:
                break
            }
            applyDebugQuickIfNeeded(to: develop)
        }
    }

    /// 验收脚本用：`--quick color_density=80,grain_amount=60` 在首帧后施加参数，
    /// 用来比对「预测帧是否真的随参数变化」。
    private func applyDebugQuickIfNeeded(to session: MobileDevelopSession?) {
        guard let session else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--quick"), args.indices.contains(index + 1) else { return }
        for pair in args[index + 1].split(separator: ",") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            session.applyQuick(String(parts[0]), value)
        }
    }

    // MARK: - 导航

    private func openCamera() {
        withAnimation(MMotion.push) { screen = .camera }
    }

    private func closeCamera() {
        withAnimation(MMotion.push) { screen = .home }
    }

    /// 相机拍完：RAW 入库 → 同步写入系统相册 → 直接进显影台看片。
    private func handleCapture(_ url: URL) {
        // 入库要复制 DNG、读写库索引，别压在这一拍的视图更新里，否则快门反馈和转场会顿一下。
        Task { @MainActor in
            await Task.yield()
            let report = engine.importPhotos([url])
            // 主页网格的数据源是系统相册，所以拍到的 DNG 也要写进相册才能立刻出现在列表里。
            PhotoLibraryExport.save(url) { _ in
                try? FileManager.default.removeItem(at: url)
            }

            guard report.imported > 0, let photoID = report.firstID else {
                showToast(report.reason.isEmpty ? "拍摄的 RAW 没能入库" : report.reason)
                withAnimation(MMotion.push) { screen = .home }
                return
            }
            showToast("已拍摄 · RAW 已入库")
            openDevelop(photoID)
        }
    }

    private func openDevelop(_ photoID: String) {
        engine.closeGrade()
        resetFlight()
        grade = nil
        withAnimation(MMotion.push) {
            develop = engine.openDevelop(photoID: photoID)
            screen = .develop
        }
    }

    private func closeDevelop() {
        engine.closeDevelop()
        resetFlight()
        withAnimation(MMotion.push) {
            develop = nil
            screen = .home
        }
    }

    private func goHome() {
        engine.closeGrade()
        engine.closeDevelop()
        resetFlight()
        withAnimation(MMotion.push) {
            grade = nil
            develop = nil
            screen = .home
        }
    }

    private func openGrade(_ photoID: String, entry: MGradeEntry, returningTo target: MScreen) {
        withAnimation(MMotion.push) {
            gradeEntry = entry
            gradeReturn = target
            grade = engine.openGrade(photoID: photoID, entry: entry)
            screen = .grade
        }
    }

    private func closeGrade() {
        engine.closeGrade()
        resetFlight()
        withAnimation(MMotion.push) {
            grade = nil
            screen = gradeReturn
        }
    }

    // MARK: - 照片吸入

    /// 开孔落点：灵动岛 / 刘海 / 平顶顶部边缘，按真实安全区推导。
    private func housingTarget(_ insets: MSafeInsets) -> CGRect {
        MDeviceHousing.opening(kind: MDeviceHousing.resolved(housingSetting), insets: insets)
    }

    private func beginSuck(image: MPlatformImage?, from rect: CGRect, photoID: String,
                           insets: MSafeInsets) {
        guard flightPhase == .idle else { return }
        guard let image, rect.width > 1, rect.height > 1 else {
            openGrade(photoID, entry: .handoff, returningTo: .develop)
            return
        }

        let target = housingTarget(insets)
        flightImage = image
        flightRect = rect
        flightRadius = 3
        flightOpacity = 1
        flightPhase = .sucking
        developPreviewHidden = true

        withAnimation(.spring(response: 0.48, dampingFraction: 0.66)) {
            flightRect = target
            flightRadius = min(target.width, target.height) / 2
        } completion: {
            withAnimation(.easeIn(duration: 0.18)) {
                flightOpacity = 0
            } completion: {
                guard flightPhase == .sucking else { return }
                flightPhase = .idle
                flightRect = target
                flightOpacity = 0
                flightImage = nil
                // 画布保持隐藏，等从调色台返回时再由 resetFlight 恢复，避免横移过程中背后又出现一张。
                openGrade(photoID, entry: .handoff, returningTo: .develop)
            }
        }
    }

    private func resetFlight() {
        flightPhase = .idle
        flightImage = nil
        flightOpacity = 0
        developPreviewHidden = false
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation(MMotion.state) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            guard token == toastToken else { return }
            withAnimation(MMotion.state) { toast = nil }
        }
    }
}
