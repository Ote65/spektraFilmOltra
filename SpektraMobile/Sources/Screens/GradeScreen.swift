import SwiftUI
import UniformTypeIdentifiers

struct GradeScreen: View {
    @ObservedObject var session: MobileGradeSession
    let entry: MGradeEntry
    let onBack: () -> Void
    let onGoHome: () -> Void
    let onToast: (String) -> Void
    /// 分栏底部胶片条的数据源：库内全部照片（iPad 横屏切换照片用）。
    let library: [MPhoto]
    /// 点击胶片条缩略图时切换调色对象。
    let onSwitchPhoto: (String) -> Void

    @Environment(\.mHousing) private var housingSetting
    private var housing: MHousingKind { MDeviceHousing.resolved(housingSetting) }

    @State private var recipe = MGradeRecipe()
    /// 撤销栈：每一轮连续调参只记录一次改动前的状态（配方 + 裁切几何）。
    @State private var undoStack: [MGradeUndoSnapshot] = []
    @State private var lastChangeTime = Date.distantPast
    @State private var tabIndex = DebugLaunch.gradeTab
    @State private var drawerHeight: CGFloat = MMetric.drawerMin
    @State private var panelContentHeight: CGFloat = 0
    @State private var panelViewportHeight: CGFloat = 0
    @State private var drawerChrome: CGFloat = 0
    @State private var exportOpen = DebugLaunch.exportOpen
    @State private var cropOpen = false
    @State private var showLUTImporter = false
    @State private var hslBand = 0
    @State private var gradingZone = 1
    @State private var stageSize: CGSize = .zero
    // 交接图就绪前先弹出一块白色画布，再显影渐变成照片
    @State private var cardRect: CGRect = .zero
    @State private var cardOpacity: Double = 1
    @State private var cardVisible = false
    @State private var cardStarted = false
    @State private var cardRadius: CGFloat = 2
    @State private var imageRevealed = false

    @State private var showOriginal = false
    @State private var pressToken = 0
    @State private var zoom: CGFloat = DebugLaunch.canvasZoom
    /// 点击照片进入纯预览：顶栏、抽屉、底栏全部隐去，再点一次恢复。
    @State private var chromeHidden = false
    @State private var pan: CGSize = CGSize(width: 0, height: DebugLaunch.canvasPanY)
    @State private var lastPan: CGSize = CGSize(width: 0, height: DebugLaunch.canvasPanY)
    /// 捏合缩放锚点：锚在双指中心，捏哪里哪里不动。
    @State private var zoomAnchor: UnitPoint = .center
    @State private var isPinching = false
    @State private var pinchBaseZoom: CGFloat = 1
    @State private var pinchBasePan: CGSize = .zero
    @State private var pinchDragT0: CGSize = .zero
    @State private var isDragging = false
    @State private var dragT0: CGSize = .zero
    @State private var dragBasePan: CGSize = .zero
    @State private var lastDragT: CGSize = .zero

    /// 曲线默认没有任何控制点，恒等曲线；用户点击曲线才新增点。
    @State private var curvePoints: [CGPoint] = []
    @State private var curveChannel = "RGB"
    @Namespace private var toolPill

    private var availableHeight: CGFloat { insets.contentHeight }

    @Environment(\.mSafeInsets) private var insets

    /// iPad 横屏：左画布 + 右参数栏。竖屏与分屏保持原来的单列布局。
    private var isSplit: Bool { MLayout.usesSplit(insets.size) }

    var body: some View {
        ZStack(alignment: .bottom) {
            MColor.app

            if isSplit {
                splitLayout
            } else {
                stackedLayout
            }
        }
        .background(MColor.app)
        .overlay {
            if exportOpen {
                MExportSheet(
                    filename: session.filename,
                    phaseLabel: session.exportLabel,
                    originalLongEdge: session.exportOriginalEdge,
                    canExport: session.sourceReady,
                    readFailed: session.sourceFailure != nil,
                    onClose: { withAnimation(MMotion.pill) { exportOpen = false } },
                    onReturnHome: {
                        exportOpen = false
                        onGoHome()
                    },
                    onNote: onToast,
                    onExport: { format, edge, quality, done in
                        session.export(format: format, longEdgeIndex: edge,
                                       jpegQuality: quality) { result in
                            if case .failure(let error) = result {
                                onToast((error as? LUTParseError)?.errorDescription ?? "导出失败")
                            }
                            done(result)
                        }
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            // iPad 开孔为 .none：与显影台同一守卫，避免顶部画出假光效。
            if housing != .none {
                MHousingAura(
                    housing: housing,
                    isActive: session.isRendering || !session.sourceReady,
                    label: "显影中"
                )
            }
        }
        .onChange(of: stageSize) { _, _ in popCardIfReady() }
        .onChange(of: session.previewImage != nil) { _, hasImage in
            if hasImage { popCardIfReady() }
        }
        .onChange(of: isSplit) { _, split in
            // 进入分栏后预设 / 边框移到左轨：右栏参数页签停在其上时回落到光影。
            if split && (tabIndex == 0 || tabIndex == 4) { tabIndex = 1 }
        }
        .onChange(of: recipe) { oldValue, newValue in
            pushUndo(oldValue)
            session.apply(newValue)
        }
        .onChange(of: session.lutFailure) { _, message in
            // 只在失败原因发生变化时提示一次，避免每次调参渲染重复弹窗。
            if let message { onToast(message) }
        }
        .onChange(of: curvePoints) { _, _ in
            syncCurve()
        }
        .fileImporter(
            isPresented: $showLUTImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let entry = try session.importLUT(url: url)
                    recipe.lutName = entry.name
                    recipe.lutStrength = 60
                    onToast("已导入 \(entry.name)")
                } catch {
                    onToast(error.localizedDescription)
                }
            case .failure:
                onToast("LUT 导入失败")
            }
        }
        .sheet(isPresented: $cropOpen, onDismiss: { session.clearCropBase() }) {
            ZStack {
                MColor.app.ignoresSafeArea()
                if let base = session.cropBaseImage {
                    MCropEditor(
                        base: base,
                        initial: session.geometry,
                        onCancel: { cropOpen = false },
                        onDone: { geometry in
                            cropOpen = false
                            // 裁切确认前压一步栈，撤销可以连同裁切一起回退。
                            pushUndo(recipe, force: true)
                            session.setGeometry(geometry)
                        }
                    )
                } else if let failure = session.cropBaseFailure {
                    // 底图失败不再无限转圈：给出原因与重试入口。
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(MColor.brassHigh)
                        Text("裁切底图生成失败")
                            .font(.mSans(12, .semibold))
                            .foregroundStyle(MColor.text1)
                        Text(failure)
                            .font(.mSans(10, .regular))
                            .foregroundStyle(MColor.text3)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            MHaptic.light()
                            session.prepareCropBase()
                        } label: {
                            Text("重试")
                                .font(.mSans(11, .semibold))
                                .foregroundStyle(MColor.brassInk)
                                .padding(.horizontal, 20)
                                .frame(height: 32)
                                .background(Capsule().fill(MColor.brass))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 270)
                    .mGlassSurface(
                        RoundedRectangle(cornerRadius: 18, style: .continuous),
                        fallbackFill: MColor.surface2.opacity(0.96)
                    )
                } else {
                    ProgressView()
                        .tint(MColor.brass)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(MColor.app)
        }
    }

    // MARK: - 单列布局（iPhone / iPad 竖屏 / 分屏）

    private var stackedLayout: some View {
        Group {
            VStack(spacing: 0) {
                navigationBar
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                    .animation(MMotion.quick, value: chromeHidden)
                previewStage
                    .frame(height: max(60, availableHeight - MMetric.navHeight - drawerHeight))
                    .overlay {
                        if cardVisible {
                            MCanvasCard(rect: cardRect, opacity: cardOpacity, radius: cardRadius)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { stageSize = geo.size }
                                .onChange(of: geo.size) { _, newValue in stageSize = newValue }
                        }
                    )
                Spacer(minLength: 0)
            }
            .padding(.top, insets.top)

            // 参数面板是悬浮在底部胶囊上方的圆角窗口：底边与胶囊顶边留固定间距。
            drawer
                .opacity(chromeHidden ? 0 : 1)
                .allowsHitTesting(!chromeHidden)
                .animation(MMotion.quick, value: chromeHidden)
                .padding(.horizontal, MMetric.floatingPanelInset)
                .frame(height: drawerHeight)
                .padding(.bottom, insets.bottom + MMetric.tabCapsuleBottom
                    + MMetric.tabCapsuleHeight + MMetric.floatingPanelGap)

            toolbar(bottomPadding: 8 + insets.bottom)
                .opacity(chromeHidden ? 0 : 1)
                .allowsHitTesting(!chromeHidden)
                .animation(MMotion.quick, value: chromeHidden)

            MBackSwipe(action: onBack)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.top, insets.top)
        }
    }

    // MARK: - 分栏布局（iPad 横屏，参考 macOS 三栏：LUT 边框轨 / 画布 / 调色参数）

    private var splitLayout: some View {
        VStack(spacing: 0) {
            navigationBar
                .opacity(chromeHidden ? 0 : 1)
                .allowsHitTesting(!chromeHidden)
                .animation(MMotion.quick, value: chromeHidden)

            HStack(spacing: 0) {
                gradeSideRail
                    .frame(width: MLayout.sideRailWidth(for: insets.size))

                Rectangle()
                    .fill(MColor.hairline)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    previewStage
                        .overlay {
                            if cardVisible {
                                MCanvasCard(rect: cardRect, opacity: cardOpacity, radius: cardRadius)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { stageSize = geo.size }
                                    .onChange(of: geo.size) { _, newValue in stageSize = newValue }
                            }
                        )
                        .frame(maxHeight: .infinity)

                    if library.count > 1 {
                        gradeFilmstrip
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    MBackSwipe(action: onBack)
                        .frame(width: 22)
                }

                Rectangle()
                    .fill(MColor.hairline)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    // 调色参数页签在参数栏顶部（光影 / 色调 / 质感）。
                    MSplitTabRow(
                        titles: ["光影", "色调", "质感"],
                        selection: gradeParamTabIndex,
                        onSelect: { index in
                            selectTab(gradeParamTabIndices[index])
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    // 裁切 / 预览比例：参数栏的固定工具行。
                    drawerToolRow
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    gradeParamPanel
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, insets.bottom)
                }
                .frame(width: MLayout.inspectorWidth(for: insets.size))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, insets.top)
    }

    /// 分栏右栏的调色参数页 → tabIndex 的下标映射（预设 / 边框已移到左轨）。
    private let gradeParamTabIndices = [1, 2, 3]
    private var gradeParamTabIndex: Int { gradeParamTabIndices.firstIndex(of: tabIndex) ?? 0 }

    @ViewBuilder private var gradeParamPanel: some View {
        switch tabIndex {
        case 2: colorPanel
        case 3: texturePanel
        default: lightPanel
        }
    }

    /// 左轨：LUT 预设 / 边框切换（参考 macOS 的左侧预设栏）。
    private var gradeSideRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                MSideRailTab(title: "预设", selected: tabIndex != 4) {
                    withAnimation(MMotion.drawer) { tabIndex = 0 }
                }
                MSideRailTab(title: "边框", selected: tabIndex == 4) {
                    withAnimation(MMotion.drawer) { tabIndex = 4 }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            Group {
                if tabIndex == 4 {
                    borderPanel
                } else {
                    presetPanel
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(MColor.app)
    }

    /// 底部胶片条：横向缩略图切换照片（参考 macOS 的 Filmstrip）。
    private var gradeFilmstrip: some View {
        VStack(spacing: 0) {
            MHairline()

            ScrollView(.horizontal) {
                // 懒加载：只为可见格子建视图、解缩略图，照片多时不会一次解全库。
                LazyHStack(spacing: 8) {
                    ForEach(library) { photo in
                        Button {
                            MHaptic.tick()
                            onSwitchPhoto(photo.id)
                        } label: {
                            ZStack {
                                Rectangle().fill(MColor.surface2)
                                if let image = MPhotoImage.load(photo) {
                                    image.resizable().scaledToFill()
                                }
                            }
                            .frame(width: 64, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(
                                        photo.id == session.photoID ? MColor.brass : MColor.hairline,
                                        lineWidth: photo.id == session.photoID ? 1.6 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(.bottom, insets.bottom)
    }

    // MARK: - 预览就绪：白色画布弹出并显影成照片

    private func popCardIfReady() {
        guard !cardStarted,
              session.previewImage != nil,
              stageSize.width > 1,
              stageSize.height > 1 else { return }
        cardStarted = true
        let start = cardStartRect()
        cardRect = start
        cardRadius = min(start.width, start.height) / 2
        cardVisible = true
        cardOpacity = 1
        imageRevealed = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
            cardRect = cardTargetRect()
            cardRadius = 2
        } completion: {
            withAnimation(.easeOut(duration: 0.32)) {
                cardOpacity = 0
                imageRevealed = true
            } completion: {
                cardVisible = false
            }
        }
    }

    private func cardTargetRect() -> CGRect {
        MImageFit.rect(aspect: session.previewAspect, in: stageSize, horizontalPadding: 14)
    }

    private func cardStartRect() -> CGRect {
        let width = stageSize.width
        let top = insets.top + MMetric.navHeight
        switch housing {
        case .notch:
            let notchWidth = width * 0.432
            let notchHeight = notchWidth * 0.241
            return CGRect(
                x: (width - notchWidth) / 2,
                y: 1 - top,
                width: notchWidth,
                height: notchHeight
            )
        case .none:
            return CGRect(x: (width - 90) / 2, y: -top, width: 90, height: 3)
        default:
            let islandWidth = width * 0.336
            let islandHeight = islandWidth * 0.318
            return CGRect(
                x: (width - islandWidth) / 2,
                y: width * 0.0178 - top,
                width: islandWidth,
                height: islandHeight
            )
        }
    }

    // MARK: - 顶栏

    private var navigationBar: some View {
        HStack(spacing: 8) {
            MCircleIconButton(icon: "chevron.left", size: 14, frame: 38) {
                onBack()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("调色台")
                    .font(.navTitle)
                    .foregroundStyle(MColor.text1)
                    .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
                HStack(spacing: 5) {
                    Circle().fill(MColor.brass).frame(width: 4, height: 4)
                    Text(entry == .handoff ? "显影交接 · 线性" : "原片直达 · 线性")
                    Text("·")
                    Text("ProPhoto RGB")
                }
                .mMeta(9, color: MColor.text3)
                .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MCircleIconButton(icon: "arrow.counterclockwise", size: 13, frame: 32) {
                resetAllGrade()
            }
            .accessibilityLabel("重置全部调整")

            MBrassPill(title: "导出", icon: "square.and.arrow.up", height: 32) {
                withAnimation(MMotion.pill) { exportOpen = true }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: MMetric.navHeight)
        // 顶栏按钮下面铺一层从上到下的黑色渐隐，保住标题与副标题的可读性，又不会像实色条一样截断照片。
        .background(alignment: .top) {
            MTopScrim(height: 190)
                .offset(y: -insets.top)
        }
        .zIndex(1)
    }

    // MARK: - 预览

    private var previewStage: some View {
        ZStack {
            MColor.canvas

            RadialGradient(
                colors: [Color.white.opacity(0.035), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 260
            )
            .allowsHitTesting(false)

            cropMarks

            Group {
                if let image = showOriginal ? session.originalImage : session.previewImage {
                    MImage.swiftUI(image)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 14)
                        .scaleEffect(zoom, anchor: zoomAnchor)
                        .offset(pan)
                        .animation(MMotion.state, value: showOriginal)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(MColor.text4)
                }
            }
            // 画布是整个页面：放大后的照片可以延伸到顶栏与抽屉下面，只由屏幕边界裁切。
            .opacity(imageRevealed ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                MHaptic.light()
                withAnimation(MMotion.drawer) {
                    if abs(zoom - 1) > 0.001 {
                        zoom = 1
                        pan = .zero
                        lastPan = .zero
                    } else {
                        zoom = 2.2
                    }
                    zoomAnchor = .center
                }
            }
            // 单击在双击之后挂载：双击优先识别，单击只在没有第二击时触发。
            .onTapGesture {
                MHaptic.light()
                withAnimation(MMotion.quick) { chromeHidden.toggle() }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            // 以手势开始时的状态为基线：连续两次捏合不会互相跳变。
                            pinchBaseZoom = zoom
                            pinchBasePan = pan
                            zoomAnchor = value.startAnchor
                            pinchDragT0 = lastDragT
                            // 双指操作开始时作废在途的长按对比，避免捏合途中图片切到原片。
                            pressToken += 1
                        }
                        zoom = min(4, max(0.5, pinchBaseZoom * value.magnification))
                        if isDragging {
                            pan = CGSize(
                                width: pinchBasePan.width + lastDragT.width - pinchDragT0.width,
                                height: pinchBasePan.height + lastDragT.height - pinchDragT0.height
                            )
                        }
                    }
                    .onEnded { _ in
                        isPinching = false
                        if zoom <= 1.001 {
                            pan = .zero
                            lastPan = .zero
                            zoomAnchor = .center
                        } else {
                            lastPan = pan
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragT0 = gesture.translation
                            dragBasePan = pan
                            pressToken += 1
                        }
                        lastDragT = gesture.translation
                        if isPinching {
                            // 双指整体移动 1:1 平移，与缩放叠加互不打架。
                            pan = CGSize(
                                width: pinchBasePan.width + gesture.translation.width - pinchDragT0.width,
                                height: pinchBasePan.height + gesture.translation.height - pinchDragT0.height
                            )
                        } else {
                            guard zoom > 1.001 else { return }
                            pan = CGSize(
                                width: dragBasePan.width + gesture.translation.width - dragT0.width,
                                height: dragBasePan.height + gesture.translation.height - dragT0.height
                            )
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastDragT = .zero
                        lastPan = pan
                    }
            )
            .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 18, pressing: { pressing in
                if pressing {
                    pressToken += 1
                    let token = pressToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard token == pressToken else { return }
                        guard !isPinching, !isDragging else { return }
                        MHaptic.light()
                        withAnimation(MMotion.quick) { showOriginal = true }
                    }
                } else {
                    pressToken += 1
                    withAnimation(MMotion.quick) { showOriginal = false }
                }
            }, perform: {})

            if let failure = session.sourceFailure, !session.sourceReady {
                sourceFailureCard(failure)
                    .zIndex(3)
                    .transition(.opacity)
            }

            VStack {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 78)
                .allowsHitTesting(false)
                .opacity(chromeHidden || drawerHeight > 500 ? 0 : 1)
                .animation(MMotion.quick, value: chromeHidden)
                .animation(MMotion.quick, value: drawerHeight)
            }
            .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top, spacing: 6) {
                    Spacer()

                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.drawer) {
                            if abs(zoom - 1) > 0.001 {
                                zoom = 1
                                pan = .zero
                                lastPan = .zero
                            } else {
                                zoom = 2.2
                            }
                        }
                    } label: {
                        Text(abs(zoom - 1) > 0.001 ? "\(Int(zoom * 100))%" : "1×")
                            .font(.mSans(9, .medium).monospacedDigit())
                            .foregroundStyle(MColor.text3)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recipe.lutName == "无 LUT" ? "原始线性" : recipe.lutName)
                            .font(.mSans(10, .medium))
                            .foregroundStyle(MColor.text2)
                            .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                        if session.isRendering || !session.sourceReady {
                            Text(session.phaseLabel.isEmpty ? "显影中" : session.phaseLabel)
                                .font(.mSans(9, .medium))
                                .foregroundStyle(MColor.brass)
                                .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                        } else {
                            Text(recipe.lutName == "无 LUT" ? "未套用 LUT" : "LUT 强度 \(Int(recipe.lutStrength))%")
                                .font(.mSans(9, .medium).monospacedDigit())
                                .foregroundStyle(MColor.text3)
                                .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                        }
                    }

                    Spacer()

                    if showOriginal || abs(zoom - 1) > 0.001 {
                        Text(showOriginal ? "原片" : "\(Int(zoom * 100))%")
                            .font(.mSans(9, .medium).monospacedDigit())
                            .foregroundStyle(showOriginal ? MColor.text2 : MColor.text4)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.42)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .opacity(chromeHidden || drawerHeight > 500 ? 0 : 1)
                .animation(MMotion.quick, value: chromeHidden)
                .animation(MMotion.quick, value: drawerHeight)
            }
        }
        .overlay(alignment: .bottom) { MHairline(color: MColor.hairlineFaint) }
    }

    /// 交接图失败时替代空白画布的失败卡：说明原因并给出重试入口。
    private func sourceFailureCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(MColor.brassHigh)
            Text("交接图生成失败")
                .font(.mSans(12, .semibold))
                .foregroundStyle(MColor.text1)
            Text(message)
                .font(.mSans(10, .regular))
                .foregroundStyle(MColor.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                MHaptic.light()
                session.retrySource()
            } label: {
                Text("重试")
                    .font(.mSans(11, .semibold))
                    .foregroundStyle(MColor.brassInk)
                    .padding(.horizontal, 20)
                    .frame(height: 32)
                    .background(Capsule().fill(MColor.brass))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 270)
        .mGlassSurface(
            RoundedRectangle(cornerRadius: 18, style: .continuous),
            fallbackFill: MColor.surface2.opacity(0.96)
        )
    }

    /// 调色台预览渲染比例菜单：1/8、1/4、1/2、1/1（相对 1600 交接图）。
    private var gradeScaleMenu: some View {
        Menu {
            ForEach([0.125, 0.25, 0.5, 1.0], id: \.self) { value in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { session.setPreviewScale(value) }
                } label: {
                    Text(previewScaleTitle(value))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(previewScaleTitle(session.previewScale))
                    .font(.mSans(9, .medium).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(MColor.text3)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .mGlassSurface(Capsule(), fallbackFill: Color.black.opacity(0.5))
            .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))
        }
        .accessibilityLabel("调色台预览渲染比例")
        .accessibilityValue(previewScaleTitle(session.previewScale))
    }

    private func previewScaleTitle(_ value: Double) -> String {
        switch value {
        case ..<0.2: return "1/8"
        case ..<0.4: return "1/4"
        case ..<0.8: return "1/2"
        default: return "1/1"
        }
    }

    private var cropMarks: some View {
        GeometryReader { geo in
            let rect = fittedPreviewRect(in: geo.size)
            Canvas { context, _ in
                let inset: CGFloat = 7
                let length: CGFloat = 10
                let color = MColor.brass.opacity(0.22)
                let corners: [(CGPoint, CGSize)] = [
                    (CGPoint(x: rect.minX + inset, y: rect.minY + inset),
                     CGSize(width: length, height: length)),
                    (CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
                     CGSize(width: -length, height: length)),
                    (CGPoint(x: rect.minX + inset, y: rect.maxY - inset),
                     CGSize(width: length, height: -length)),
                    (CGPoint(x: rect.maxX - inset, y: rect.maxY - inset),
                     CGSize(width: -length, height: -length)),
                ]
                for (origin, delta) in corners {
                    var path = Path()
                    path.move(to: CGPoint(x: origin.x + delta.width, y: origin.y))
                    path.addLine(to: origin)
                    path.addLine(to: CGPoint(x: origin.x, y: origin.y + delta.height))
                    context.stroke(path, with: .color(color), lineWidth: 0.8)
                }
            }
        }
        .allowsHitTesting(false)
        .scaleEffect(zoom, anchor: zoomAnchor)
        .offset(pan)
    }

    private func fittedPreviewRect(in size: CGSize) -> CGRect {
        let horizontalInset: CGFloat = 14
        let availableWidth = max(1, size.width - horizontalInset * 2)
        let availableHeight = max(1, size.height)
        let aspect = max(0.1, session.previewAspect)
        var width = availableWidth
        var height = width / aspect
        if height > availableHeight {
            height = availableHeight
            width = height * aspect
        }
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width, height: height
        )
    }

    // MARK: - 抽屉工具行

    private var drawerToolRow: some View {
        HStack(spacing: 6) {
            MCircleIconButton(icon: "crop", size: 12, frame: 28) {
                MHaptic.tick()
                session.prepareCropBase()
                cropOpen = true
            }
            .accessibilityLabel("裁切与校正")

            gradeScaleMenu

            Spacer(minLength: 0)

            MCircleIconButton(icon: "arrow.uturn.backward", size: 10, frame: 28) {
                undoGrade()
            }
            .opacity(undoStack.isEmpty ? 0.36 : 1)
            .allowsHitTesting(!undoStack.isEmpty)
            .accessibilityLabel("撤销")
        }
    }

    // MARK: - 撤销 / 重置

    /// 一步撤销快照：调色配方 + 裁切几何，两者一起回退才不会出现「参数回去了、裁切没回去」。
    private struct MGradeUndoSnapshot {
        let recipe: MGradeRecipe
        let geometry: MPhotoGeometry
    }

    /// 按轮次合并：一轮连续调参只有第一次（新起点）才把改动前的状态压栈。
    /// `force` 用于裁切确认、整体重置这类一次成型的动作。
    private func pushUndo(_ previous: MGradeRecipe, force: Bool = false) {
        let now = Date()
        defer { lastChangeTime = now }
        if !force, now.timeIntervalSince(lastChangeTime) <= 0.5 { return }
        undoStack.append(MGradeUndoSnapshot(recipe: previous, geometry: session.geometry))
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    private func undoGrade() {
        guard let previous = undoStack.popLast() else { return }
        session.syncLUTPath(name: previous.recipe.lutName)
        // 撤回自身会触发 recipe 的 onChange，先刷新时间戳，避免撤回也被压栈。
        lastChangeTime = Date()
        withAnimation(MMotion.state) {
            recipe = previous.recipe
            restoreCurveFromRecipe()
        }
        if previous.geometry != session.geometry {
            session.setGeometry(previous.geometry)
        }
    }

    /// 只重置调色参数（色调页底部按钮）。
    private func resetGrade() {
        MHaptic.medium()
        session.syncLUTPath(name: "无 LUT")
        withAnimation(MMotion.state) {
            recipe = MGradeRecipe()
            resetCurve()
        }
        onToast("调色参数已重置")
    }

    /// 顶栏重置：让照片回到刚从显影台出来的状态 —— 调色参数与裁切几何全部复原。
    private func resetAllGrade() {
        MHaptic.medium()
        pushUndo(recipe, force: true)
        session.syncLUTPath(name: "无 LUT")
        withAnimation(MMotion.state) {
            recipe = MGradeRecipe()
            resetCurve()
        }
        session.resetGeometry()
        onToast("已重置全部调整")
    }

    // MARK: - 抽屉

    private var drawer: some View {
        VStack(spacing: 0) {
            if !isSplit {
                MDrawerChevron(isExpanded: isDrawerExpanded, isVisible: !isLockedTab) {
                    toggleDrawer()
                }
            }

            ZStack {
                switch MGradeTab.allCases[min(tabIndex, MGradeTab.allCases.count - 1)] {
                case .presets: presetPanel
                case .light: lightPanel
                case .color: colorPanel
                case .texture: texturePanel
                case .border: borderPanel
                }
            }
            .id(tabIndex)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .leading)
                )
            )
            .frame(maxHeight: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size.height, initial: true) { _, height in
                            panelViewportHeight = height
                            if drawerChrome == 0, height > 0 {
                                drawerChrome = max(0, drawerHeight - height)
                            }
                        }
                }
            )
            .clipped()
        }
        // 抽屉和底部页签胶囊共用同一套原生液态玻璃材质，色调保持一致。
        .mGlassSurface(drawerShape, fallbackFill: MColor.surface2.opacity(0.96))
        .clipShape(drawerShape)
        .overlay {
            drawerShape
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
        // 阴影分两层：近处极淡、远处大半径，让边界是渐隐而不是一圈硬黑边。
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        // 裁切 / 预览比例浮在 sheet 外面顶部，和原本撤销按钮同一行；分栏时移到参数栏顶部固定行。
        .overlay(alignment: .top) {
            if !isSplit {
                drawerToolRow
                    .padding(.horizontal, 10)
                    .offset(y: -36)
            }
        }
        .onPreferenceChange(MPanelHeightKey.self) { height in
            panelContentHeight = height
            syncDrawerToContent()
        }
        .onChange(of: panelViewportHeight) { _, _ in
            syncDrawerToContent()
        }
    }

    /// 面板内容或可视高度变化后，把抽屉对齐到自适应高度。
    /// 布局回调里只赋值，不启动动画，避免 preference → 动画 → 布局的反馈环。
    private func syncDrawerToContent() {
        // 分栏下面板高度由右栏自然分配，drawerHeight 不参与布局，别再写状态引发多余重绘。
        guard !isSplit else { return }
        guard panelViewportHeight > 0, panelContentHeight > 0 else { return }
        let fit = fitHeight(for: panelContentHeight)
        let target: CGFloat = isLockedTab ? fit : min(drawerHeight, fit)
        guard abs(drawerHeight - target) > 1 else { return }
        drawerHeight = target
    }

    private var chromeHeight: CGFloat { drawerChrome }

    private func fitHeight(for content: CGFloat) -> CGFloat {
        guard content > 0, panelViewportHeight > 0 else { return MMetric.drawerMin }
        let needed = content + chromeHeight + 4
        if needed <= MMetric.drawerMin + 14 { return MMetric.drawerMin }
        return min(MMetric.drawerMax, needed)
    }

    private var fitDrawerHeight: CGFloat { fitHeight(for: panelContentHeight) }

    /// 二档判据：内容比「一档时能看到的视口」还高 → 展开有意义 → 显示 chevron。
    private var isLockedTab: Bool {
        guard panelContentHeight > 0 else { return true }
        let collapsedViewport = MMetric.drawerMin - chromeHeight - 4
        return panelContentHeight <= collapsedViewport + 24
    }

    private var minDrawerHeight: CGFloat {
        isLockedTab ? fitDrawerHeight : MMetric.drawerMin
    }

    private var isDrawerExpanded: Bool {
        drawerHeight > minDrawerHeight + 1
    }

    /// 点击 chevron 切换两档高度。
    private func toggleDrawer() {
        guard !isLockedTab else { return }
        let target = isDrawerExpanded ? minDrawerHeight : fitDrawerHeight
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            drawerHeight = target
        }
    }

    /// 横向换页只换内容；高度交给 `syncDrawerToContent` 按新页内容收敛。
    private func selectTab(_ index: Int) {
        guard index != tabIndex, index < MGradeTab.allCases.count else { return }
        withAnimation(MMotion.drawer) {
            tabIndex = index
        }
    }

    // MARK: - 预设

    private var presetPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MSectionHead(title: "LUT 胶片查找表", trailing: "\(session.luts.count) 个")
                    .padding(.top, 12)

                // 与显影台的胶片轨同一套样式：图标 + 名称，右侧不做黑色渐隐遮罩。
                MHScrollRail(itemCount: session.luts.count + 2,
                             itemWidth: 58, spacing: 5,
                             leading: MMetric.pageMargin, trailing: 22,
                             itemHeight: 52, fadeColor: .clear) {
                    MLUTRailItem(film: currentRailFilm, title: "无 LUT",
                                 selected: recipe.lutName == "无 LUT") {
                        withAnimation(MMotion.state) {
                            recipe.lutName = "无 LUT"
                            recipe.lutStrength = 0
                            session.setLUT(entry: nil)
                        }
                    }

                    ForEach(session.luts) { entry in
                        MLUTRailItem(film: currentRailFilm, title: entry.name,
                                     selected: recipe.lutName == entry.name) {
                            withAnimation(MMotion.state) {
                                recipe.lutName = entry.name
                                recipe.lutStrength = max(60, recipe.lutStrength)
                                session.setLUT(entry: entry)
                            }
                        }
                    }

                    MLUTImportRailItem {
                        MHaptic.light()
                        showLUTImporter = true
                    }
                }
                .frame(height: 52)
                .padding(.horizontal, -MMetric.pageMargin)
                .padding(.top, 9)

                MParamSlider(
                    label: "LUT 强度",
                    value: $recipe.lutStrength,
                    base: 60,
                    range: 0...100,
                    step: 1,
                    decimals: 0,
                    suffix: "%",
                    isEnabled: recipe.lutName != "无 LUT",
                    compact: true
                )
                .padding(.top, 6)

                MHairline().padding(.top, 12)

                MSectionHead(title: "预设", trailing: "\(session.presets.count) 个")
                    .padding(.top, 14)

                ForEach(session.presets) { preset in
                    gradePresetRow(preset)
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
    }

    /// LUT 轨的图标沿用当前胶片，和显影台的胶片选择保持同一视觉语言。
    private var currentRailFilm: MFilm {
        MobileCatalog.film(id: session.filmID) ?? MobileCatalog.films[0]
    }

    private func presetMeta(_ recipe: GradeRecipe) -> String {
        var parts: [String] = []
        if abs(recipe.light.exposure) > 1e-9 {
            parts.append(String(format: "曝光 %+.2f", recipe.light.exposure))
        }
        if abs(recipe.light.contrast) > 1e-9 {
            parts.append("对比 \(Int(recipe.light.contrast))")
        }
        if abs(recipe.color.temperature) > 1e-9 {
            parts.append("色温 \(Int(recipe.color.temperature))")
        }
        if abs(recipe.color.saturation) > 1e-9 {
            parts.append("饱和 \(Int(recipe.color.saturation))")
        }
        return parts.isEmpty ? "基线" : parts.joined(separator: " · ")
    }

    private func gradePresetRow(_ preset: GradePreset) -> some View {
        Button {
            MHaptic.light()
            let name = preset.recipe.lut.path.isEmpty
                ? "无 LUT"
                : (session.luts.first { $0.path == preset.recipe.lut.path }?.name ?? "LUT")
            recipe = MGradeRecipe(grade: preset.recipe, lutName: name)
            restoreCurveFromRecipe()
            session.applyPreset(preset)
            onToast("已套用 \(preset.name)")
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [0x3A342A, 0x262119, 0x14120D].map { Color(hex: $0) },
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(MColor.hairline, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.mSans(11.5, .medium))
                        .foregroundStyle(MColor.text1)
                    Text(presetMeta(preset.recipe))
                        .font(.mSans(8.5, .medium).monospacedDigit())
                        .foregroundStyle(MColor.text4)
                }

                Spacer()

                Image(systemName: preset.builtin ? "square.stack" : "arrow.down.to.line")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MColor.text4)
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 光影

    private var lightPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MParamSlider(label: "曝光", value: $recipe.exposure, base: 0, range: -5...5, step: 0.05, decimals: 2, suffix: " EV", compact: true)
                MParamSlider(label: "对比度", value: $recipe.contrast, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "高光", value: $recipe.highlights, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "阴影", value: $recipe.shadows, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "白色", value: $recipe.whites, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "黑色", value: $recipe.blacks, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "中间调", value: $recipe.midtones, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "高光柔和", value: $recipe.highlightRolloff, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                // 曲线并回光影页：先走滑条定调，再在最下面用点曲线精修。
                MHairline().padding(.top, 14)
                curveSection
            }
            // 顶部不再放分组标题，滑条直接从抽屉上沿开始。
            .padding(.top, 4)
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(DebugLaunch.gradePanelBottom ? .bottom : .top)
    }

    /// 光影页底部的点曲线（原「曲线」页签）。
    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("曲线")
                    .mLabel(8.5, color: MColor.text3)

                Spacer(minLength: 8)

                ForEach(["RGB", "R", "G", "B"], id: \.self) { channel in
                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { curveChannel = channel }
                    } label: {
                        Text(channel)
                            .font(.mSans(9, curveChannel == channel ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(curveChannel == channel ? MColor.brass : MColor.text3)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                Capsule().fill(curveChannel == channel ? MColor.brassWash : MColor.surface2.opacity(0.7))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(channel != "RGB")
                    .opacity(channel == "RGB" ? 1 : 0.35)
                }

                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { resetCurve() }
                } label: {
                    Text("复位")
                        .font(.mSans(9, .medium))
                        .foregroundStyle(MColor.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)

            MCurveEditor(points: $curvePoints, channel: curveChannel)
                .frame(height: 208)
                .padding(.top, 10)
        }
    }

    private func resetCurve() {
        curvePoints = []
    }

    /// 套用预设后按四个曲线锚点还原控制点；全为 0 时回到恒等曲线。
    private func restoreCurveFromRecipe() {
        let anchors: [(Double, Double)] = [
            (0.12, recipe.curveShadows),
            (0.35, recipe.curveDarks),
            (0.62, recipe.curveLights),
            (0.88, recipe.curveHighlights),
        ]
        curvePoints = anchors.compactMap { anchor -> CGPoint? in
            let (x, offset) = anchor
            guard abs(offset) > 1e-9 else { return nil }
            return CGPoint(x: x, y: min(1, max(0, x + offset / 100)))
        }
    }

    // MARK: - 色调

    private var colorPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MSectionHead(title: "白平衡").padding(.top, 4)

                MParamSlider(label: "色温", value: $recipe.temperature, base: 0, range: -100...100, step: 1, decimals: 0, suffix: " CC", compact: true)
                MParamSlider(label: "色调", value: $recipe.tint, base: 0, range: -100...100, step: 1, decimals: 0, suffix: " CC", compact: true)

                MSectionHead(title: "饱和度").padding(.top, 8)

                MParamSlider(label: "自然饱和度", value: $recipe.vibrance, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "饱和度", value: $recipe.saturation, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "浓度", value: $recipe.colorDensity, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "混合").padding(.top, 8)

                bandChips(
                    labels: ["红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红"],
                    colors: [0.00, 0.08, 0.15, 0.33, 0.50, 0.60, 0.75, 0.90],
                    selected: hslBand
                ) { index in
                    hslBand = index
                }
                .padding(.top, 6)

                MParamSlider(label: "色相", value: hslBinding(\.hue), base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "饱和度", value: hslBinding(\.saturation), base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "明度", value: hslBinding(\.luminance), base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "颜色分级").padding(.top, 8)

                bandChips(
                    labels: ["阴影", "中间调", "高光"],
                    colors: nil,
                    selected: gradingZone
                ) { index in
                    gradingZone = index
                }
                .padding(.top, 6)

                MParamSlider(label: "色相", value: gradingBinding(\.hue), base: 0, range: 0...360, step: 1, decimals: 0, suffix: "°", compact: true)
                MParamSlider(label: "饱和度", value: gradingBinding(\.saturation), base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "明度", value: gradingBinding(\.luminance), base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "混合", value: $recipe.grading.blending, base: 50, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "平衡", value: $recipe.grading.balance, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)

                resetButton("重置调色") {
                    resetGrade()
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(DebugLaunch.gradePanelBottom ? .bottom : .top)
    }

    // MARK: - 质感

    private var texturePanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MSectionHead(title: "质感").padding(.top, 4)

                MParamSlider(label: "清晰度", value: $recipe.clarity, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "纹理", value: $recipe.texture, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "去朦胧", value: $recipe.dehaze, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "锐化").padding(.top, 8)

                MParamSlider(label: "锐化", value: $recipe.sharpenAmount, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "半径", value: $recipe.sharpenRadius, base: 1, range: 0.5...3, step: 0.1, decimals: 1, suffix: "", compact: true)
                MParamSlider(label: "阈值", value: $recipe.sharpenThreshold, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "降噪").padding(.top, 8)

                MParamSlider(label: "亮度降噪", value: $recipe.noiseLuminance, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "色彩降噪", value: $recipe.noiseColor, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "颗粒").padding(.top, 8)

                MParamSlider(label: "颗粒", value: $recipe.grain, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "大小", value: $recipe.grainSize, base: 25, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "粗糙度", value: $recipe.grainRoughness, base: 50, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "暗角").padding(.top, 8)

                MParamSlider(label: "数量", value: $recipe.vignette, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "中间点", value: $recipe.vignetteMidpoint, base: 50, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "圆度", value: $recipe.vignetteRoundness, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "羽化", value: $recipe.vignetteFeather, base: 50, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "色差").padding(.top, 8)

                MParamSlider(label: "色差", value: $recipe.chromaticAberration, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                resetButton("重置质感") {
                    MHaptic.medium()
                    withAnimation(MMotion.state) {
                        recipe.clarity = 0
                        recipe.texture = 0
                        recipe.dehaze = 0
                        recipe.sharpenAmount = 0
                        recipe.sharpenRadius = 1
                        recipe.sharpenThreshold = 0
                        recipe.noiseLuminance = 0
                        recipe.noiseColor = 0
                        recipe.grain = 0
                        recipe.grainSize = 25
                        recipe.grainRoughness = 50
                        recipe.vignette = 0
                        recipe.vignetteMidpoint = 50
                        recipe.vignetteRoundness = 0
                        recipe.vignetteFeather = 50
                        recipe.chromaticAberration = 0
                    }
                    onToast("质感参数已重置")
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(DebugLaunch.gradePanelBottom ? .bottom : .top)
    }

    // MARK: - 边框

    private var borderPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MToggleRow(label: "启用片边", isOn: borderEnabled, compact: true)
                    .padding(.top, 6)

                MHScrollRail(itemCount: MFilmBorderPreset.all.count, itemWidth: 86,
                             spacing: 8, leading: MMetric.pageMargin, trailing: 22,
                             itemHeight: 84, fadeColor: .clear) {
                    ForEach(MFilmBorderPreset.all) { preset in
                        MFilmBorderPresetCard(
                            preset: preset,
                            selected: borderPresetIsSelected(preset)
                        ) {
                            MHaptic.tick()
                            withAnimation(MMotion.state) { session.setBorderPreset(preset) }
                        }
                    }
                }
                .frame(height: 84)
                .padding(.horizontal, -MMetric.pageMargin)
                .padding(.top, 8)

                if session.border.enabled {
                    MChoiceRow(label: "比例", value: session.border.gaugeValue.label,
                               options: gaugeOptions) { raw in
                        guard let gauge = MFilmBorderGauge(rawValue: raw) else { return }
                        session.updateBorder {
                            $0.gauge = raw
                            $0.baseTone = gauge.defaultBase.rawValue
                            $0.perf = MFilmBorderPerf.auto.rawValue
                            $0.notch = gauge.isSheet
                            $0.edgeText = !gauge.isSheet
                        }
                    }

                    borderColorRail

                    MParamSlider(label: "片边宽度", value: borderDouble(\.borderScale),
                                 base: 1, range: 0.4...2.0, step: 0.01, decimals: 2,
                                 suffix: "×", compact: true)

                    MChoiceRow(label: "宽度口径", value: session.border.widthModeValue.label,
                               options: borderWidthModeOptions) { raw in
                        session.updateBorder { $0.widthMode = raw }
                    }

                    MChoiceRow(label: "画幅角型", value: cornerValue.label,
                               options: cornerOptions) { raw in
                        session.updateBorder { $0.corner = raw }
                    }

                    MParamSlider(label: "角口大小", value: borderDouble(\.cornerScale),
                                 base: 1, range: 0...3, step: 0.01, decimals: 2,
                                 suffix: "×", isEnabled: cornerValue != .square, compact: true)

                    MChoiceRow(label: "齿孔类型", value: session.border.perfValue.label,
                               options: perfOptions) { raw in
                        session.updateBorder { $0.perf = raw }
                    }

                    MParamSlider(label: "齿孔大小", value: borderDouble(\.perfScale),
                                 base: 1, range: 0.5...1.8, step: 0.01, decimals: 2,
                                 suffix: "×", compact: true)
                    MParamSlider(label: "齿孔间距", value: borderDouble(\.perfPitch),
                                 base: 1, range: 0.5...2.0, step: 0.01, decimals: 2,
                                 suffix: "×", compact: true)
                    MParamSlider(label: "齿孔明暗", value: borderDouble(\.perfBrightness),
                                 base: 0, range: -1...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)

                    MParamSlider(label: "片基明暗", value: borderDouble(\.baseBrightness),
                                 base: 0, range: -1...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)

                    MToggleRow(label: "边字", isOn: borderBool(\.edgeText), compact: true)
                    if session.border.edgeText {
                        MTextFieldRow(label: "边字内容", text: borderText,
                                      placeholder: "自动（随胶片）")
                        MChoiceRow(label: "边字颜色", value: textToneValue.label,
                                   options: textToneOptions) { raw in
                            session.updateBorder { $0.textTone = raw }
                        }
                        MParamSlider(label: "边字大小", value: borderDouble(\.textScale),
                                     base: 1, range: 0.5...2.5, step: 0.01, decimals: 2,
                                     suffix: "×", compact: true)
                        MToggleRow(label: "画幅编号", isOn: borderBool(\.frameNumbers),
                                   compact: true)
                        MToggleRow(label: "片边编码", isOn: borderBool(\.dxCode), compact: true)
                    }

                    MToggleRow(label: "日期戳", isOn: borderBool(\.dateStamp), compact: true)
                    if session.border.dateStamp {
                        MChoiceRow(label: "日期位置", value: datePositionValue.label,
                                   options: datePositionOptions) { raw in
                            session.updateBorder { $0.datePosition = raw }
                        }
                        MChoiceRow(label: "日期内容", value: dateModeValue.label,
                                   options: dateModeOptions) { raw in
                            session.updateBorder { $0.dateMode = raw }
                        }
                        MChoiceRow(label: "日期字体", value: dateFontValue.label,
                                   options: dateFontOptions) { raw in
                            session.updateBorder { $0.dateFont = raw }
                        }
                        MChoiceRow(label: "日期颜色", value: dateStyleValue.label,
                                   options: dateStyleOptions) { raw in
                            session.updateBorder { $0.dateStyle = raw }
                        }
                    }

                    if session.border.gaugeValue.isSheet {
                        MToggleRow(label: "片缺口", isOn: borderBool(\.notch), compact: true)
                    }

                    MSectionHead(title: "做旧", trailing: "默认关闭", compact: true)
                    MParamSlider(label: "划痕", value: borderDouble(\.scratches),
                                 base: 0, range: 0...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)
                    MParamSlider(label: "灰尘", value: borderDouble(\.dust),
                                 base: 0, range: 0...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)
                    MParamSlider(label: "边缘雾化", value: borderDouble(\.fog),
                                 base: 0, range: 0...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(DebugLaunch.gradePanelBottom ? .bottom : .top)
    }

    /// 边框颜色：横向滚动的圆形色板，选色不用再进折叠菜单。
    private var borderColorRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("边框颜色")
                    .font(.mSans(11))
                    .foregroundStyle(MColor.text2)
                Text(baseValue.label)
                    .mMeta(8, color: MColor.text4)
                Spacer(minLength: 8)
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { session.resetBorder() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MColor.text3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重置片边")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(MFilmBorderBase.allCases) { tone in
                        borderColorDot(tone)
                    }
                }
                .padding(.horizontal, MMetric.pageMargin)
                .padding(.vertical, 3)
            }
            .scrollIndicators(.never)
            .padding(.horizontal, -MMetric.pageMargin)
        }
        .padding(.top, 12)
    }

    private func borderColorDot(_ tone: MFilmBorderBase) -> some View {
        let rgb = MFilmBorderRenderer.baseSwatch(tone, brightness: session.border.baseBrightness)
        let selected = baseValue == tone
        return Button {
            MHaptic.tick()
            withAnimation(MMotion.state) {
                session.updateBorder { $0.baseTone = tone.rawValue }
            }
        } label: {
            Circle()
                .fill(Color(red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2)))
                .frame(width: 30, height: 30)
                .overlay(
                    Circle().strokeBorder(selected ? MColor.brass : MColor.hairline,
                                          lineWidth: selected ? 1.8 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Circle()
                            .fill(MColor.brass)
                            .frame(width: 10, height: 10)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(MColor.brassInk)
                            )
                            .offset(x: 2, y: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(MPressStyle(scale: 0.92))
        .accessibilityLabel(tone.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 调色/片边绑定

    private func hslBinding(_ keyPath: WritableKeyPath<HslBand, Double>) -> Binding<Double> {
        Binding(
            get: {
                recipe.hslBands.indices.contains(hslBand)
                    ? recipe.hslBands[hslBand][keyPath: keyPath] : 0
            },
            set: { value in
                guard recipe.hslBands.indices.contains(hslBand) else { return }
                recipe.hslBands[hslBand][keyPath: keyPath] = value
            }
        )
    }

    private var gradingZoneKeyPath: WritableKeyPath<ColorGrading, GradeZone> {
        switch gradingZone {
        case 0: return \.shadows
        case 2: return \.highlights
        default: return \.midtones
        }
    }

    private func gradingBinding(_ keyPath: WritableKeyPath<GradeZone, Double>) -> Binding<Double> {
        let zone = gradingZoneKeyPath
        return Binding(
            get: { recipe.grading[keyPath: zone][keyPath: keyPath] },
            set: { recipe.grading[keyPath: zone][keyPath: keyPath] = $0 }
        )
    }

    private func bandChips(
        labels: [String],
        colors: [Double]?,
        selected: Int,
        action: @escaping (Int) -> Void
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { action(index) }
                    } label: {
                        HStack(spacing: 4) {
                            if let colors {
                                Circle()
                                    .fill(Color(hue: colors[index], saturation: 0.72, brightness: 0.86))
                                    .frame(width: 7, height: 7)
                            }
                            Text(label)
                                .font(.mSans(9, selected == index ? .semibold : .regular))
                                .foregroundStyle(selected == index ? MColor.brass : MColor.text3)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(
                            Capsule().fill(selected == index ? MColor.brassWash : MColor.surface2.opacity(0.7))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                selected == index ? MColor.brass.opacity(0.32) : MColor.hairlineFaint,
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func resetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text2)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                        .fill(MColor.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                        .strokeBorder(MColor.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    private var cornerValue: MFilmBorderCorner {
        MFilmBorderCorner(rawValue: session.border.corner) ?? .rounded
    }

    private var baseValue: MFilmBorderBase {
        MFilmBorderBase(rawValue: session.border.baseTone) ?? .colorNegative
    }

    private var textToneValue: MFilmBorderTextTone {
        MFilmBorderTextTone(rawValue: session.border.textTone) ?? .auto
    }

    private var datePositionValue: MFilmBorderDatePosition {
        session.border.datePositionValue
    }

    private var dateStyleValue: MFilmBorderDateStyle {
        session.border.dateStyleValue
    }

    private var dateModeValue: MFilmBorderDateMode {
        session.border.dateModeValue
    }

    private var dateFontValue: MFilmBorderDateFont {
        session.border.dateFontValue
    }

    private var gaugeOptions: [MProOption] {
        MFilmBorderGauge.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var borderWidthModeOptions: [MProOption] {
        MFilmBorderWidthMode.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var cornerOptions: [MProOption] {
        MFilmBorderCorner.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var perfOptions: [MProOption] {
        MFilmBorderPerf.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var textToneOptions: [MProOption] {
        MFilmBorderTextTone.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var datePositionOptions: [MProOption] {
        MFilmBorderDatePosition.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var dateStyleOptions: [MProOption] {
        MFilmBorderDateStyle.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var dateModeOptions: [MProOption] {
        MFilmBorderDateMode.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var dateFontOptions: [MProOption] {
        MFilmBorderDateFont.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private func borderPresetIsSelected(_ preset: MFilmBorderPreset) -> Bool {
        guard session.border.enabled == preset.config.enabled else { return false }
        return preset.config.matches(session.border)
    }

    private var borderEnabled: Binding<Bool> {
        Binding(
            get: { session.border.enabled },
            set: { isOn in
                if isOn, session.border.preset == "none",
                   let preset = MFilmBorderPreset.preset(id: "kodak135") {
                    withAnimation(MMotion.state) { session.setBorderPreset(preset) }
                } else {
                    session.updateBorder { $0.enabled = isOn }
                }
            }
        )
    }

    private func borderDouble(
        _ keyPath: WritableKeyPath<MFilmBorderConfig, Double>
    ) -> Binding<Double> {
        Binding(
            get: { session.border[keyPath: keyPath] },
            set: { value in session.updateBorder { $0[keyPath: keyPath] = value } }
        )
    }

    private func borderBool(
        _ keyPath: WritableKeyPath<MFilmBorderConfig, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { session.border[keyPath: keyPath] },
            set: { value in session.updateBorder { $0[keyPath: keyPath] = value } }
        )
    }

    private var borderText: Binding<String> {
        Binding(
            get: { session.border.customText },
            set: { value in session.updateBorder { $0.customText = value } }
        )
    }

    // MARK: - 工具条

    private func toolbar(bottomPadding: CGFloat) -> some View {
        MGlassTabCapsule {
            ForEach(Array(toolItems.enumerated()), id: \.offset) { item in
                Button {
                    MHaptic.tick()
                    selectTab(item.offset)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.element.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(tabIndex == item.offset ? MColor.brass : MColor.text3)
                            .frame(height: 21)

                        Text(item.element.title)
                            .font(.mSans(8.5, .medium))
                            .foregroundStyle(tabIndex == item.offset ? MColor.brass : MColor.text4)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background {
                        if tabIndex == item.offset {
                            Capsule()
                                .fill(MColor.brassWash)
                                .overlay(Capsule().strokeBorder(MColor.brass.opacity(0.20), lineWidth: 1))
                                .padding(.vertical, 3)
                                .matchedGeometryEffect(id: "glass-tool", in: toolPill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.element.title)
                .accessibilityAddTraits(tabIndex == item.offset ? [.isSelected] : [])
            }
        }
        .padding(.bottom, bottomPadding)
    }

    private var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: MRadius.sheet,
            bottomLeadingRadius: MRadius.sheet,
            bottomTrailingRadius: MRadius.sheet,
            topTrailingRadius: MRadius.sheet,
            style: .continuous
        )
    }

    /// 底部四个分页：光影 / 色调 取代原来的「调整」合并页。导出由顶栏承担，避免同一动作出现两个入口。
    private var toolItems: [(title: String, icon: String)] {
        [
            ("预设", "rectangle.stack"),
            ("光影", "sun.max"),
            ("色调", "paintpalette"),
            ("质感", "camera.filters"),
            ("边框", "film"),
        ]
    }

    /// 把拖动后的点曲线折算成引擎已有的四段曲线量（阴影 / 暗部 / 亮部 / 高光）。
    private func syncCurve() {
        recipe.curveShadows = curveOffset(at: 0.12)
        recipe.curveDarks = curveOffset(at: 0.35)
        recipe.curveLights = curveOffset(at: 0.62)
        recipe.curveHighlights = curveOffset(at: 0.88)
    }

    private func curveOffset(at x: Double) -> Double {
        // 没有控制点 = 恒等曲线，不写任何偏移。
        guard !curvePoints.isEmpty else { return 0 }
        // 端点由代码固定为 (0,0)、(1,1)，用户点只作为中间控制点。
        var knots: [(x: Double, y: Double)] = [(0, 0)]
        knots.append(contentsOf: curvePoints.sorted { $0.x < $1.x }
            .map { (Double($0.x), Double($0.y)) })
        knots.append((1, 1))
        let clamped = min(max(x, 0), 1)
        var y = clamped
        for index in 1..<knots.count {
            let left = knots[index - 1]
            let right = knots[index]
            if clamped >= left.x, clamped <= right.x {
                let dx = right.x - left.x
                if dx > 1e-9 {
                    let t = (clamped - left.x) / dx
                    y = left.y + (right.y - left.y) * t
                } else {
                    y = right.y
                }
                break
            }
        }
        return min(max((y - clamped) * 100, -100), 100)
    }
}

// MARK: - LUT 横向轨道

/// 与显影台胶片轨一致的 LUT 项：复用胶片图标，选中时图标外套黄铜描边。
private struct MLUTRailItem: View {
    let film: MFilm
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(MColor.surface3)
                            .frame(width: 33, height: 33)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(MColor.brass.opacity(0.9), lineWidth: 1)
                            )
                    }
                    MFilmStockIcon(film: film, size: 27)
                }
                .frame(width: 33, height: 33)

                Text(title)
                    .font(.mSans(7.5, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MColor.text1 : MColor.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 导入 LUT：和胶片图标同样大小的方框，只用一个加号表达。
private struct MLUTImportRailItem: View {
    let action: () -> Void

    var body: some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MColor.surface2.opacity(0.45))
                        .frame(width: 33, height: 33)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(MColor.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 33, height: 33)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MColor.text3)
                }
                .frame(width: 33, height: 33)

                Text("导入")
                    .font(.mSans(7.5, .medium))
                    .foregroundStyle(MColor.text4)
                    .lineLimit(1)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
        .accessibilityLabel("导入 LUT")
    }
}
