import SwiftUI
import Photos

struct MobileRootView: View {
    @StateObject private var engine = MobileEngine()
    @Environment(\.mHousing) private var housingSetting

    @State private var screen: MScreen = .home
    /// 访达访问序号：每次切回 .home 递增，首页据此在「真正进入访达」时弹切换提示。
    @State private var homeVisit = 0
    @State private var develop: MobileDevelopSession?
    @State private var grade: MobileGradeSession?
    @State private var video: MVideoSession?
    /// 相册视频取回中：避免连续点击叠出多个导入任务。
    @State private var openingVideo = false
    @State private var gradeEntry: MGradeEntry = .direct
    @State private var gradeReturn: MScreen = .home
    /// 显影台的返回目标：从相机进（直出/本次列表/拍完即进）回相机，从主页进回主页。
    @State private var developReturn: MScreen = .home
    @State private var toast: String? = nil
    @State private var toastAction: MToastAction? = nil
    @State private var toastToken = 0
    @State private var debugOpened = false
    /// 台前调度窗口宽度锁的去重状态（视图持有，不放全局）。
    @State private var lastWidthFloor: CGFloat = -1

    // 显影 → 调色的「吸入」过渡
    @State private var metrics: MSafeInsets = .fallback
    @State private var flightPhase: MFlightPhase = .idle
    @State private var flightImage: MPlatformImage?
    @State private var flightRect: CGRect = .zero
    @State private var flightOpacity: Double = 0
    @State private var developPreviewHidden = false
    /// 吸入时的原图与起始矩形：从调色台返回时用来倒放「吐出来」，保证与吸入同一张图、同一位置。
    @State private var returnImage: MPlatformImage?
    @State private var returnRect: CGRect = .zero

    private enum MFlightPhase { case idle, sucking, spitting }

    init() {
        let args = ProcessInfo.processInfo.arguments
        var start: MScreen = (MobileSettings.launchScreen == .camera && !MLayout.isPad) ? .camera : .home
        if let index = args.firstIndex(of: "--screen"), args.indices.contains(index + 1) {
            switch args[index + 1] {
            case "camera": start = MLayout.isPad ? .home : .camera
            case "home": start = .home
            case "develop": start = .develop
            case "grade": start = .grade
            case "settings": start = .settings
            default: break
            }
        }
        _screen = State(initialValue: start)
        // 不能再从 `.fallback`（393×852）起步：飞行图层直接用这里的 metrics 算开孔落点，
        // 真机 428 宽时会让终点左移 17.5pt，看起来就是吸入错位。
        _metrics = State(initialValue: MScreenMetrics.current())
    }

    var body: some View {
        content(insets: metrics)
            .environment(\.mSafeInsets, metrics)
            // 模拟器上 `machineIdentifier()` 返回宿主架构，`detect()` 永远判成灵动岛，
            // 刘海分支在模拟器里跑不到。`--housing notch` 用来强制走刘海路径做视觉验收。
            .environment(\.mHousing, DebugLaunch.housingOverride)
            .ignoresSafeArea()
            .background(MColor.app)
            // 允许跟随系统字号放大，但封顶到 accessibility1：
            // 这类密集参数面板放大到 AX3+ 会把画布和面板全部挤爆，封顶比完全不支持好。
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .preferredColorScheme(.dark)
            .onAppear { noteHomeVisit() }
            .onChange(of: activeScreen) { _, new in
                noteHomeVisit()
                // session 已清空但 screen 还停在子页时归位，防止状态长期脱钩
                // （脱钩时主页虽能正常显示/点击，但 screen 会让 probe 日志与提示计数失真）。
                if new == .home, screen != .home, screen != .camera {
                    screen = .home
                }
            }
    }

    /// 实际呈现的页面。`screen` 与 develop/grade/video 这些 optional session 分开更新，
    /// 一旦脱钩（openGrade 失败、吸入动画被打断、快速连点返回），
    /// screen 会停在非 home 而页面并未渲染。此时主页会裸露在 push 让位的 -72 位置，
    /// 左半边被屏幕裁掉，而且因为 allowsHitTesting 也看 screen，整页还会点不动。
    /// 视觉与命中都以「页面是否真的呈现」为准，session 缺失即视为 home。
    private var activeScreen: MScreen {
        switch screen {
        case .develop: return develop == nil ? .home : .develop
        case .grade:   return grade == nil ? .home : .grade
        case .video:   return video == nil ? .home : .video
        default:       return screen
        }
    }

    private func noteHomeVisit() {
        guard activeScreen == .home else { return }
        homeVisit += 1
    }

    private func content(insets: MSafeInsets) -> some View {
        ZStack {
            HomeScreen(
                engine: engine,
                onOpenDevelop: { photo in
                    openDevelop(photo.id, filename: photo.filename)
                },
                onOpenGrade: { photo in
                    openGrade(photo.id, filename: photo.filename,
                              entry: .direct, returningTo: .home)
                },
                onOpenVideo: { asset in
                    openVideo(asset)
                },
                onOpenCamera: openCamera,
                onOpenSettings: openSettings,
                onToast: showToast,
                hintToken: homeVisit
            )
            .offset(x: activeScreen == .home || activeScreen == .camera ? 0 : -72)
            .allowsHitTesting(activeScreen == .home)

            if screen == .camera {
                // 拍完入库并写相册；是否立即进显影台由相机页按设置决定，
                // 不进的那张留在「本次拍摄」列表里供稍后打开。
                CameraScreen(onClose: closeCamera,
                             onCaptured: { url, meta in
                                 await importCaptured(url, meta: meta)
                             },
                             onOpenDevelop: { photoID in
                                 // 入库期间用户可能已关掉相机：只保留结果，不强行跳页。
                                 guard screen == .camera else { return }
                                 openDevelop(photoID, returningTo: .camera)
                             },
                             onOriginalURL: { photoID in
                                 engine.originalURL(forPhotoID: photoID)
                             },
                             onDirectSave: { request in
                                 await saveDirect(request)
                             },
                             onDirectDevelop: { request in
                                 await openDirectDevelop(request)
                             })
                    .transition(.opacity)
                    .zIndex(3)
            }

            if screen == .settings {
                SettingsScreen(
                    onBack: closeSettings,
                    onToast: showToast,
                    previewURL: engine.photos.first?.thumbnailURL,
                    cacheRoot: engine.store.root
                )
                .transition(.move(edge: .trailing))
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
                    onToast: showToast,
                    onToastAction: { text, action in showToast(text, action: action) }
                )
                .offset(x: activeScreen == .grade && gradeReturn == .develop ? -72 : 0)
                .allowsHitTesting(activeScreen == .develop)
                .zIndex(1)
            }

            if let video {
                MVideoScreen(
                    session: video,
                    onBack: { closeVideo() },
                    onToast: showToast
                )
                // 画布是 AVPlayerLayer 宿主视图，位移转场里它不会跟着滑，
                // 会「先出现在终点再被挤过去」。整页改成淡入，层次交给页面内部。
                .transition(.opacity)
                .zIndex(2)
            }

            if let grade {
                GradeScreen(
                    session: grade,
                    entry: gradeEntry,
                    onBack: { closeGrade() },
                    onGoHome: goHome,
                    onToast: showToast,
                    onToastAction: { text, action in showToast(text, action: action) },
                    library: engine.photos,
                    onSwitchPhoto: switchGradePhoto
                )
                // 胶片条换照片时整块重建：recipe / 撤销栈 / 曲线点都属于上一张，
                // 跟着新 session 一起归零，避免旧参数和旧裁切被写进新照片。
                .id(grade.photoID)
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }

            if let toast {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Text(toast)
                            .font(.mSans(11, .medium))
                            .foregroundStyle(MColor.text1)
                        if let toastAction {
                            Button(toastAction.title) {
                                toastAction.handler()
                                toastToken += 1
                                withAnimation(MMotion.state) {
                                    self.toast = nil
                                    self.toastAction = nil
                                }
                            }
                            .font(.mSans(11, .semibold))
                            .foregroundStyle(MColor.brass)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 15)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(MColor.surface3.opacity(0.96)))
                    .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .padding(.bottom, insets.bottom + 76)
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
                .allowsHitTesting(toastAction != nil)
            }

            if let flightImage {
                // 吸入不是把照片压成开孔那么大的胶囊：照片保持原比例向上流，
                // 用「开孔底边以下」做遮罩——照片整体越过那条水平线就被吞掉。
                // 遮罩必须加在满屏容器上，坐标才是全窗口坐标；加在图片本身上会跟着图片跑。
                let maskTop = housingTarget(insets).maxY
                GeometryReader { geo in
                    ZStack {
                        MImage.swiftUI(flightImage)
                            .resizable()
                            .frame(
                                width: max(1, flightRect.width),
                                height: max(1, flightRect.height)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .position(x: flightRect.midX, y: flightRect.midY)
                            .opacity(flightOpacity)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(
                                width: geo.size.width,
                                height: max(0, geo.size.height - maskTop)
                            )
                            .offset(y: maskTop)
                    }
                }
                .frame(width: insets.width, height: insets.height)
                .allowsHitTesting(false)
                .zIndex(30)
            }
        }
        .animation(MMotion.push, value: screen)
        .background {
            // 旋转 / 分屏 / 台前调度都会改变窗口尺寸：跟着刷新安全区，分栏与单列才能实时切换。
            GeometryReader { proxy in
                Color.clear
                    .preference(key: MWindowSizeKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(MWindowSizeKey.self) { layoutSize in
            guard layoutSize.width > 1, layoutSize.height > 1 else { return }
            guard abs(layoutSize.width - metrics.width) > 1
                    || abs(layoutSize.height - metrics.height) > 1 else { return }
            let current = MScreenMetrics.current()
            // iPhone 上坐标必须跟真实窗口一致：393 的 fallback 会让吸入落点整块左移。
            // iPad 台前调度时 UIWindow.bounds 可能是虚拟画布，布局尺寸仍以 GeometryReader 为准。
            let resolvedSize = MLayout.isPad ? layoutSize : current.size
            let resolved = MSafeInsets(top: current.top, bottom: current.bottom, size: resolvedSize)
            if resolved != metrics { metrics = resolved }
            // 去重状态放在视图里；窗口场景改动推迟到布局回调之外，
            // 避免在 SwiftUI 布局事务里写 sizeRestrictions 形成反馈环。
            if let floor = MLayout.windowWidthFloor(for: layoutSize),
               abs(floor - lastWidthFloor) > 1 {
                lastWidthFloor = floor
                DispatchQueue.main.async { MLayout.applyWindowWidthFloor(floor) }
            }
        }
        .task {
            guard !debugOpened else { return }
            debugOpened = true
            let current = MScreenMetrics.current()
            // 这里必须整块替换：原来只改 top/bottom、保留 fallback 的 393×852，
            // 飞行图层就一直按 393 宽算开孔，落点比真机左移 17.5pt。
            let resolvedSize = MLayout.isPad ? metrics.size : current.size
            let resolved = MSafeInsets(top: current.top, bottom: current.bottom, size: resolvedSize)
            if resolved != metrics { metrics = resolved }
            if DebugLaunch.probeGeometry {
                let housing = MDeviceHousing.resolved(housingSetting)
                let opening = MDeviceHousing.opening(kind: housing, insets: current)
                NSLog("MGeometry size=%.0fx%.0f top=%.0f bottom=%.0f housing=%@ opening=%@",
                      current.size.width, current.size.height,
                      current.top, current.bottom, housing.rawValue,
                      NSCoder.string(for: opening))
            }
            // 调试直达：视频显影台（`--video-open` 取相册第一个视频）。
            if DebugLaunch.videoOpenFirst {
                await engine.refreshVideos()
                if let asset = engine.videoAssets.first { openVideo(asset) }
                return
            }
            // 调试直达：先扫相册，第一张 RAW 未入库时自动取回入库（等效于点开主页卡片）。
            guard screen == .develop || screen == .grade else { return }
            await engine.refreshAssets()
            var first = engine.assets.first?.photo ?? engine.photos.first
            if let name = DebugLaunch.developFile,
               let photo = engine.photos.first(where: { $0.filename == name }) {
                first = photo
            }
            if first == nil, let asset = engine.assets.first,
               let photoID = await engine.importAsset(assetID: asset.id) {
                first = engine.photos.first(where: { $0.id == photoID })
            }
            guard let first else { return }
            // 首帧直达：此时窗口还没完成第一次布局，带 transition 插入会让视图停在屏幕外。
            switch screen {
            case .develop:
                develop = engine.openDevelop(photoID: first.id)
            case .grade:
                grade = engine.openGrade(
                    photoID: first.id,
                    entry: DebugLaunch.gradeHandoff ? .handoff : .direct)
            case .home, .camera, .settings, .video:
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
        // iPad 版不提供相机：只从相册导入与显影。
        guard !MLayout.isPad else { return }
        withAnimation(MMotion.push) { screen = .camera }
    }

    private func openSettings() {
        withAnimation(MMotion.push) { screen = .settings }
    }

    private func closeSettings() {
        withAnimation(MMotion.push) { screen = .home }
    }

    private func closeCamera() {
        withAnimation(MMotion.push) { screen = .home }
        // 相册里可能刚多了一张 RAW：回主页时重扫一遍。
        Task { await engine.refreshAssets() }
    }

    /// 拍完 → 入库 → 写系统相册 → 返回 photoID 给相机页。
    /// 是否立即进显影台由相机页按设置决定：不进的那张 photoID 会留在「本次拍摄」列表。
    /// 成功后清理相机临时文件；失败时只在仍停留拍摄页才退回主页，
    /// 避免异步失败回调把用户从其他页面拽走。
    private func importCaptured(_ url: URL, meta: MCameraCaptureMeta) async -> String? {
        let report = await engine.importPhotos([url], captureMeta: meta)
        guard let photoID = report.firstID else {
            showToast(report.reason.isEmpty ? "拍摄的照片没能入库" : report.reason)
            if screen == .camera { closeCamera() }
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return photoID
    }

    /// 直出保存：先把成片写进系统相册，再按设置决定是否保留 RAW 工程。
    /// 先相册后工程可以避免相册被拒时重复导入同一张 RAW。
    private func saveDirect(_ request: MDirectSaveRequest) async -> MDirectSaveOutcome {
        // 片边在保存时合进成片：只解码编码图，不重新显影。
        var borderedURL: URL?
        if request.border.enabled {
            let source = request.renderedURL
            let border = request.border
            let filmID = request.edit.filmStock
            // 与预览用同一个标识，片边的随机纹理 / 编号在预览与成片之间保持一致。
            let identifier = "direct-preview"
            let quality = MDirectRenderSettings.fromPreferences().jpegQuality
            let rawURL = request.rawURL
            borderedURL = await Task.detached(priority: .userInitiated) {
                // 日期戳内容取自拍摄文件，与成片页预览保持一致。
                let stamp = MFilmBorderRenderer.captureStamp(url: rawURL)
                return MDirectRenderer.compositeBorder(
                    renderedURL: source, config: border, filmID: filmID,
                    photoID: identifier, jpegQuality: quality,
                    dateLabel: stamp.date, timeLabel: stamp.time)
            }.value
            // 用户选了片边就必须带上；合成失败时宁可报错重试，也不能悄悄保存成无片边。
            guard borderedURL != nil else { return .failed("片边合成失败，请重试") }
        }
        defer {
            if let borderedURL { try? FileManager.default.removeItem(at: borderedURL) }
        }
        let albumURL = borderedURL ?? request.renderedURL

        let outcome: PhotoLibraryExport.Outcome = await withCheckedContinuation { continuation in
            PhotoLibraryExport.save(albumURL, album: PhotoLibraryExport.albumTitle) {
                continuation.resume(returning: $0)
            }
        }

        switch outcome {
        case .denied:
            // 保留临时成片，用户授权后可以在卡片上直接重试保存。
            return .denied
        case .failed:
            return .failed("成片写入相册失败")
        case .saved:
            break
        }

        // 保存成功的提示带上实际输出长边：设置页的尺寸档位是否生效一眼可证。
        let savedSize = LibraryStore.pixelSize(url: albumURL)
        let savedEdge = max(savedSize.width, savedSize.height)
        let sizeNote = savedEdge > 0 ? " · 长边 \(savedEdge) px" : ""

        guard MobileSettings.cameraDirectSaveOriginal else {
            // 关闭保存原图：不生成工程、不写 RAW，只保留渲染成片。
            try? FileManager.default.removeItem(at: request.rawURL)
            try? FileManager.default.removeItem(at: request.renderedURL)
            return .saved("成片已保存到相册" + sizeNote)
        }

        defer {
            try? FileManager.default.removeItem(at: request.rawURL)
            try? FileManager.default.removeItem(at: request.renderedURL)
        }
        let report = await engine.importPhotos([request.rawURL], publishToAlbum: true,
                                              generateThumbnails: false)
        guard let photoID = report.firstID else {
            return .saved("成片已保存，原图保存失败")
        }
        await engine.applyDirectResult(
            photoID: photoID,
            edit: request.edit,
            grade: request.grade,
            border: request.border,
            baseline: request.baseline,
            renderedURL: albumURL,
            aspect: request.aspect,
            capturedLandscape: request.capturedLandscape,
            mirrorFront: request.mirrorFront
        )
        return .saved("已保存原图与成片" + sizeNote)
    }

    /// 直出成片页「进入显影台」：原片入库后写回拍摄时的显影 / 调色参数，再打开显影台。
    /// 显影台必须有库记录，RAW 一定入库；是否写进系统相册跟随「保存原图」设置（§5.5）。
    @MainActor
    private func openDirectDevelop(_ request: MDirectDevelopRequest) async -> MDirectDevelopOutcome {
        let report = await engine.importPhotos([request.rawURL],
                                               publishToAlbum: MobileSettings.cameraDirectSaveOriginal,
                                               generateThumbnails: false)
        guard let photoID = report.firstID else {
            return .failed(report.reason.isEmpty ? "原片没能入库" : report.reason)
        }
        await engine.applyDirectResult(
            photoID: photoID,
            edit: request.edit,
            grade: request.grade,
            border: request.border,
            baseline: request.baseline,
            renderedURL: request.renderedURL,
            aspect: request.aspect,
            capturedLandscape: request.capturedLandscape,
            mirrorFront: request.mirrorFront
        )
        openDevelop(photoID, returningTo: .camera)
        return .opened
    }

    private func openDevelop(_ photoID: String, filename: String? = nil,
                             returningTo target: MScreen = .home) {
        engine.closeGrade()
        resetFlight()
        grade = nil
        // 会话建不出来时不要切 screen：否则主页会被关闭命中测试，
        // 看起来就是整页点不动。但要给提示——静默 return 会让用户以为是卡片点不动。
        guard let session = engine.openDevelop(photoID: photoID, filename: filename) else {
            NSLog("MOpen develop failed id=%@", photoID)
            showToast("打不开这张照片，请重试或重新导入")
            return
        }
        withAnimation(MMotion.push) {
            developReturn = target
            develop = session
            screen = .develop
        }
    }

    private func closeDevelop() {
        engine.closeDevelop()
        resetFlight()
        let target = developReturn
        withAnimation(MMotion.push) {
            develop = nil
            screen = target
        }
    }

    // MARK: - 视频显影

    /// 相册视频 → 沙盒工程 → 视频显影台。
    /// 同一个 PHAsset 只会导入一次，再次点开沿用上次调好的参数。
    private func openVideo(_ asset: PHAsset) {
        guard !openingVideo else { return }
        openingVideo = true
        showToast("正在取回视频…")
        Task {
            defer { openingVideo = false }
            guard let file = await engine.exportVideoResource(for: asset) else {
                showToast(engine.importFailureMessage ?? "这个视频没能取回，请检查网络后重试")
                return
            }
            defer { try? FileManager.default.removeItem(at: file.url) }

            do {
                let session = try await MVideoLibrary.shared.session(
                    forAssetID: asset.localIdentifier,
                    displayName: file.filename,
                    downloadedURL: file.url
                )
                withAnimation(MMotion.push) {
                    video = session
                    screen = .video
                }
            } catch {
                showToast("视频导入失败：\(error.localizedDescription)")
            }
        }
    }

    private func closeVideo() {
        video?.pausePlayback()
        withAnimation(MMotion.push) {
            video = nil
            screen = .home
        }
    }

    private func goHome() {
        engine.closeGrade()
        engine.closeDevelop()
        video?.pausePlayback()
        resetFlight()
        withAnimation(MMotion.push) {
            grade = nil
            develop = nil
            video = nil
            screen = .home
        }
    }

    private func openGrade(_ photoID: String, filename: String? = nil,
                           entry: MGradeEntry, returningTo target: MScreen) {
        guard let session = engine.openGrade(photoID: photoID, filename: filename,
                                             entry: entry) else {
            NSLog("MOpen grade failed id=%@ filename=%@", photoID, filename ?? "-")
            showToast("打不开这张照片，请重试或重新导入")
            return
        }
        withAnimation(MMotion.push) {
            gradeEntry = entry
            gradeReturn = target
            grade = session
            screen = .grade
        }
    }

    /// 调色台底部的胶片条切换照片：换一张继续调，保持同一入口与交接待性。
    private func switchGradePhoto(_ photoID: String) {
        guard photoID != grade?.photoID else { return }
        engine.closeGrade()
        // 胶片条 id 可能来自 relink 前的快照，带文件名兜底避免切图静默失败。
        let filename = engine.photos.first(where: { $0.id == photoID })?.filename
        withAnimation(MMotion.push) {
            grade = engine.openGrade(photoID: photoID, filename: filename, entry: gradeEntry)
            // 换图后旧的显影会话仍属于上一张，不能再作为返回目标；回主页重新进入。
            if gradeReturn == .develop {
                engine.closeDevelop()
                develop = nil
                gradeReturn = .home
            }
        }
    }

    private func closeGrade() {
        engine.closeGrade()
        let target = gradeReturn
        withAnimation(MMotion.push) {
            grade = nil
            // 分栏换图后返回主页时，旧的显影会话也要一并关闭，避免后台继续持有。
            if target != .develop, develop != nil {
                engine.closeDevelop()
                develop = nil
            }
            screen = target
        }
        // 回到显影台时把吸入动画倒放：同一张照片从开孔遮罩线吐出、落回吸入起点。
        // 其它返回目标（主页 / 换图后）没有对应的吸入起点，直接清掉飞行层。
        if target == .develop && develop != nil {
            beginSpit()
        } else {
            resetFlight()
        }
    }

    /// 吸入的倒放：照片从开孔底边那条遮罩线下方浮出，放大并落回吸入时的原始矩形。
    /// 复用 beginSuck 记下的 returnImage / returnRect，保证同一张图、同一位置；
    /// 遮罩与吸入时共用（只显示 y ≥ 开孔底边），视觉上就是「翻转回放」。
    private func beginSpit() {
        guard !MLayout.isPad,
              let image = returnImage,
              returnRect.width > 1, returnRect.height > 1,
              flightPhase == .idle else {
            resetFlight()
            return
        }
        let opening = housingTarget(metrics)
        // 起点 = 吸入的终点：照片底边刚好贴住开孔底边，整张藏在遮罩线上方。
        let shrink: CGFloat = 0.55
        let startW = returnRect.width * shrink
        let startH = returnRect.height * shrink
        let start = CGRect(
            x: metrics.width / 2 - startW / 2,
            y: opening.maxY - startH,
            width: startW, height: startH
        )
        if DebugLaunch.probeGeometry {
            NSLog("MSpit from=%@ to=%@",
                  NSCoder.string(for: start), NSCoder.string(for: returnRect))
        }
        flightImage = image
        flightRect = start
        flightOpacity = 1
        flightPhase = .spitting
        developPreviewHidden = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            flightRect = returnRect
        } completion: {
            guard flightPhase == .spitting else { return }
            // 飞行图已落到预览原位，此时才恢复真实预览，避免出现两张重叠。
            withAnimation(.easeOut(duration: 0.12)) {
                developPreviewHidden = false
            } completion: {
                guard flightPhase == .spitting else { return }
                flightPhase = .idle
                flightImage = nil
                flightRect = .zero
                flightOpacity = 0
                returnImage = nil
                returnRect = .zero
            }
        }
    }

    // MARK: - 照片吸入

    /// 开孔落点：灵动岛 / 刘海 / 平顶顶部边缘，按真实安全区推导。
    private func housingTarget(_ insets: MSafeInsets) -> CGRect {
        MDeviceHousing.opening(kind: MDeviceHousing.resolved(housingSetting), insets: insets)
    }

    private func beginSuck(image: MPlatformImage?, from rect: CGRect, photoID: String,
                           insets: MSafeInsets) {
        // iPad 没有开孔，照片飞向一条细线读不出意义；分栏里直接切换即可。
        guard !MLayout.isPad else {
            openGrade(photoID, entry: .handoff, returningTo: .develop)
            return
        }
        guard flightPhase == .idle else { return }
        guard let image, rect.width > 1, rect.height > 1 else {
            openGrade(photoID, entry: .handoff, returningTo: .develop)
            return
        }

        let opening = housingTarget(insets)
        // 终点不是开孔矩形本身，而是「照片底边刚好越过开孔底边」的位置：
        // 遮罩裁掉 y < opening.maxY 的部分，照片继续上移就会整张消失在那条水平线上。
        // 保留宽高比、只做适度缩小，不会挤出胶囊轮廓。
        let shrink: CGFloat = 0.55
        let endW = rect.width * shrink
        let endH = rect.height * shrink
        let target = CGRect(
            x: insets.width / 2 - endW / 2,
            y: opening.maxY - endH,
            width: endW,
            height: endH
        )
        if DebugLaunch.probeGeometry {
            let housing = MDeviceHousing.resolved(housingSetting)
            NSLog("MFlight housing=%@ from=%@ opening=%@ flowTarget=%@",
                  housing.rawValue,
                  NSCoder.string(for: rect),
                  NSCoder.string(for: opening),
                  NSCoder.string(for: target))
        }
        flightImage = image
        flightRect = rect
        flightOpacity = 1
        flightPhase = .sucking
        developPreviewHidden = true
        // 记下吸入的原图与起点，返回时倒放「吐出来」复用同一组数据。
        returnImage = image
        returnRect = rect

        withAnimation(.spring(response: 0.48, dampingFraction: 0.66)) {
            flightRect = target
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
        returnImage = nil
        returnRect = .zero
    }

    private func showToast(_ text: String) {
        presentToast(text, action: nil, duration: 2.1)
    }

    /// 带一次操作（例如删除预设后的“撤销”）的 Toast。
    private func showToast(_ text: String, action: MToastAction) {
        presentToast(text, action: action, duration: 4.0)
    }

    private func presentToast(_ text: String, action: MToastAction?, duration: TimeInterval) {
        toastToken += 1
        let token = toastToken
        toastAction = action
        withAnimation(MMotion.state) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard token == toastToken else { return }
            withAnimation(MMotion.state) {
                toast = nil
                toastAction = nil
            }
        }
    }
}

/// 根视图窗口尺寸：旋转、分屏与台前调度都会触发，用于刷新真实安全区。
private struct MWindowSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
