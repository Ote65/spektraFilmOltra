import SwiftUI
import UniformTypeIdentifiers

struct GradeScreen: View {
    @ObservedObject var session: MobileGradeSession
    let entry: MGradeEntry
    let onBack: () -> Void
    let onGoHome: () -> Void
    let onToast: (String) -> Void

    @Environment(\.mHousing) private var housingSetting
    private var housing: MHousingKind { MDeviceHousing.resolved(housingSetting) }

    @State private var recipe = MGradeRecipe()
    @State private var tabIndex = DebugLaunch.gradeTab
    @State private var drawerHeight: CGFloat = MMetric.drawerMin
    @State private var drawerBeforeCurve: CGFloat?
    @State private var panelContentHeight: CGFloat = 0
    @State private var panelViewportHeight: CGFloat = 0
    @State private var drawerChrome: CGFloat = 0
    @State private var pendingCurveExpand = DebugLaunch.gradeTab == 2
    @State private var exportOpen = DebugLaunch.exportOpen
    @State private var showLUTImporter = false
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
    @State private var pan: CGSize = CGSize(width: 0, height: DebugLaunch.canvasPanY)
    @State private var lastPan: CGSize = CGSize(width: 0, height: DebugLaunch.canvasPanY)

    @State private var curvePoints: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 0.26, y: 0.26),
        CGPoint(x: 0.52, y: 0.52),
        CGPoint(x: 0.78, y: 0.78),
        CGPoint(x: 1.0, y: 1.0),
    ]
    @State private var curveChannel = "RGB"
    @Namespace private var toolPill

    private var availableHeight: CGFloat { insets.contentHeight }

    @Environment(\.mSafeInsets) private var insets

    var body: some View {
        ZStack(alignment: .bottom) {
            MColor.app

            VStack(spacing: 0) {
                navigationBar
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

            drawer
                .padding(.horizontal, 10)
                .frame(height: drawerHeight)
                .padding(.bottom, 64 + insets.bottom)

            toolbar

            MBackSwipe(action: onBack)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.top, insets.top)
        }
        .background(MColor.app)
        .overlay {
            if exportOpen {
                MExportSheet(
                    filename: session.filename,
                    phaseLabel: session.exportLabel,
                    originalLongEdge: session.exportOriginalEdge,
                    canExport: session.sourceReady,
                    onClose: { withAnimation(MMotion.pill) { exportOpen = false } },
                    onReturnHome: {
                        exportOpen = false
                        onGoHome()
                    },
                    onNote: onToast,
                    onExport: { format, edge, done in
                        session.export(format: format, longEdgeIndex: edge) { result in
                            if case .failure = result { onToast("导出失败") }
                            done(result)
                        }
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            MHousingAura(
                housing: housing,
                isActive: session.isRendering || !session.sourceReady,
                label: "显影中"
            )
        }
        .onChange(of: stageSize) { _, _ in popCardIfReady() }
        .onChange(of: session.previewImage != nil) { _, hasImage in
            if hasImage { popCardIfReady() }
        }
        .onChange(of: recipe) { _, newValue in
            session.apply(newValue)
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
                if let entry = session.importLUT(url: url) {
                    recipe.lutName = entry.name
                    recipe.lutStrength = 60
                    onToast("已导入 \(entry.name)")
                } else {
                    onToast("LUT 导入失败")
                }
            case .failure:
                onToast("LUT 导入失败")
            }
        }
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

            // 与显影台同一入口：预览分辨率档位始终可见，不随抽屉高度变化。
            gradeScaleMenu

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
                        .scaleEffect(zoom)
                        .offset(pan)
                        .animation(MMotion.state, value: showOriginal)
                        .animation(MMotion.drawer, value: zoom)
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
                    if zoom > 1 {
                        zoom = 1
                        pan = .zero
                        lastPan = .zero
                    } else {
                        zoom = 2.2
                    }
                }
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in zoom = min(4, max(1, value)) }
                    .onEnded { value in
                        zoom = min(4, max(1, value))
                        if zoom <= 1 { pan = .zero; lastPan = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { gesture in
                        guard zoom > 1 else { return }
                        pan = CGSize(
                            width: lastPan.width + gesture.translation.width,
                            height: lastPan.height + gesture.translation.height
                        )
                    }
                    .onEnded { _ in lastPan = pan }
            )
            .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 18, pressing: { pressing in
                if pressing {
                    pressToken += 1
                    let token = pressToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard token == pressToken else { return }
                        MHaptic.light()
                        withAnimation(MMotion.quick) { showOriginal = true }
                    }
                } else {
                    pressToken += 1
                    withAnimation(MMotion.quick) { showOriginal = false }
                }
            }, perform: {})

            VStack {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 78)
                .allowsHitTesting(false)
                .opacity(drawerHeight > 500 ? 0 : 1)
                .animation(MMotion.quick, value: drawerHeight)
            }
            .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top, spacing: 6) {
                    Spacer()

                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.drawer) {
                            if zoom > 1 {
                                zoom = 1
                                pan = .zero
                                lastPan = .zero
                            } else {
                                zoom = 2.2
                            }
                        }
                    } label: {
                        Text(zoom > 1 ? "\(Int(zoom * 100))%" : "1×")
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

                    if showOriginal || zoom > 1 {
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
                .opacity(drawerHeight > 500 ? 0 : 1)
                .animation(MMotion.quick, value: drawerHeight)
            }
        }
        .overlay(alignment: .bottom) { MHairline(color: MColor.hairlineFaint) }
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
        .scaleEffect(zoom)
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

    // MARK: - 抽屉

    private var drawer: some View {
        VStack(spacing: 0) {
            MDrawerChevron(isExpanded: isDrawerExpanded, isVisible: !isLockedTab) {
                toggleDrawer()
            }

            MHairline(color: MColor.hairlineFaint)

            Group {
                switch MGradeTab.allCases[min(tabIndex, 2)] {
                case .presets: presetPanel
                case .adjust: adjustPanel
                case .curve: curvePanel
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
        // 抽屉是悬浮玻璃层：放大后的照片会从下面透出来，而不是被整块实色盖住。
        .background(
            ZStack {
                drawerShape.fill(.ultraThinMaterial)
                drawerShape.fill(Color.black.opacity(0.30))
            }
        )
        .overlay {
            drawerShape
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.55), radius: 20, y: 8)
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
        guard panelViewportHeight > 0, panelContentHeight > 0 else { return }
        let fit = fitHeight(for: panelContentHeight)
        let target: CGFloat
        if pendingCurveExpand {
            target = fit
            if abs(drawerHeight - fit) <= 1 { pendingCurveExpand = false }
        } else if isLockedTab {
            target = fit
        } else {
            target = min(drawerHeight, fit)
        }
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

    /// 点击 chevron 切换档位；曲线页由 `selectTab` 自动展开，这里只做手动两档。
    private func toggleDrawer() {
        guard !isLockedTab else { return }
        if tabIndex == 2 { pendingCurveExpand = false }
        let target = isDrawerExpanded ? minDrawerHeight : fitDrawerHeight
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            drawerHeight = target
        }
    }

    /// 切到曲线时自动升到刚好容纳曲线内容的高度；切回其他页时恢复到进入曲线前的高度。
    /// 横向换页与高度变化放在同一次动画里，保证面板和内容一起横移、一起下移。
    private func selectTab(_ index: Int) {
        guard index != tabIndex, index < 3 else { return }
        let wasCurve = tabIndex == 2
        let willCurve = index == 2
        var target = drawerHeight
        if willCurve, !wasCurve {
            drawerBeforeCurve = drawerHeight
            pendingCurveExpand = true
            target = drawerHeight
        } else if wasCurve, !willCurve {
            pendingCurveExpand = false
            target = drawerBeforeCurve ?? MMetric.drawerMin
            drawerBeforeCurve = nil
            if target > fitDrawerHeight { target = fitDrawerHeight }
        }
        withAnimation(MMotion.drawer) {
            tabIndex = index
            drawerHeight = target
        }
    }

    // MARK: - 预设

    private var presetPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MSectionHead(title: "LUT 胶片查找表", trailing: "\(session.luts.count) 个")
                    .padding(.top, 12)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        MLUTCard(lut: noLUTCard, selected: recipe.lutName == "无 LUT") {
                            withAnimation(MMotion.state) {
                                recipe.lutName = "无 LUT"
                                recipe.lutStrength = 0
                                session.setLUT(entry: nil)
                            }
                        }

                        ForEach(session.luts) { entry in
                            MLUTCard(lut: card(for: entry), selected: recipe.lutName == entry.name) {
                                withAnimation(MMotion.state) {
                                    recipe.lutName = entry.name
                                    recipe.lutStrength = max(60, recipe.lutStrength)
                                    session.setLUT(entry: entry)
                                }
                            }
                        }

                        Button {
                            MHaptic.light()
                            showLUTImporter = true
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .medium))
                                Text("导入 LUT")
                                    .font(.mSans(9, .medium))
                            }
                            .foregroundStyle(MColor.text3)
                            .frame(width: 90, height: 70)
                            .background(
                                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                                    .fill(MColor.surface2.opacity(0.4))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                                    .strokeBorder(MColor.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, MMetric.pageMargin)
                }
                .scrollIndicators(.never)
                .padding(.top, 9)
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        colors: [MColor.surface1.opacity(0), MColor.surface1],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)
                    .allowsHitTesting(false)
                }

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

    private var noLUTCard: MLUT {
        MLUT(id: "none", name: "无 LUT", meta: "原始线性", tints: [0x2A251C, 0x17140F])
    }

    private func card(for entry: GradeLUTEntry) -> MLUT {
        MLUT(id: entry.path, name: entry.name, meta: "CUBE 3D", tints: [0xE3C08A, 0x8E5F39, 0x241A12])
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

    // MARK: - 调整

    private var adjustPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MSectionHead(title: "光调", trailing: "\(gradeDirtyCount) 项已调").padding(.top, 12)

                MParamSlider(label: "曝光", value: $recipe.exposure, base: 0, range: -5...5, step: 0.05, decimals: 2, suffix: " EV", compact: true)
                MParamSlider(label: "对比度", value: $recipe.contrast, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "高光", value: $recipe.highlights, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "阴影", value: $recipe.shadows, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "白色", value: $recipe.whites, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "黑色", value: $recipe.blacks, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "中间调", value: $recipe.midtones, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "高光柔和", value: $recipe.highlightRolloff, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                MSectionHead(title: "白平衡").padding(.top, 8)

                MParamSlider(label: "色温", value: $recipe.temperature, base: 0, range: -100...100, step: 1, decimals: 0, suffix: " CC", compact: true)
                MParamSlider(label: "色调", value: $recipe.tint, base: 0, range: -100...100, step: 1, decimals: 0, suffix: " CC", compact: true)

                // 引擎的 `applySaturation` / `applyVignette` / `applyGrain` 一直存在，
                // 只是此前没有接到调色台 UI 与 `MGradeRecipe`。补上后颗粒、暗角、浓度
                // 在调色台可用，且导出走同一份 recipe。
                MSectionHead(title: "质感").padding(.top, 8)

                MParamSlider(label: "浓度", value: $recipe.saturation, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "暗角", value: $recipe.vignette, base: 0, range: -100...100, step: 1, decimals: 0, suffix: "", compact: true)
                MParamSlider(label: "颗粒", value: $recipe.grain, base: 0, range: 0...100, step: 1, decimals: 0, suffix: "", compact: true)

                HStack(spacing: 8) {
                    Button {
                        MHaptic.medium()
                        withAnimation(MMotion.state) { recipe = MGradeRecipe() }
                        onToast("调色参数已重置")
                    } label: {
                        Text("重置调色")
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

                    Button {
                        MHaptic.light()
                        selectTab(2)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 10, weight: .medium))
                            Text("曲线")
                                .font(.mSans(11, .medium))
                        }
                        .foregroundStyle(MColor.brass)
                        .frame(width: 88)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                                .fill(MColor.brassWash)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                                .strokeBorder(MColor.brass.opacity(0.28), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(DebugLaunch.gradePanelBottom ? .bottom : .top)
    }

    // MARK: - 曲线

    private var curvePanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(["RGB", "R", "G", "B"], id: \.self) { channel in
                        Button {
                            MHaptic.tick()
                            withAnimation(MMotion.state) { curveChannel = channel }
                        } label: {
                            Text(channel)
                                .font(.mSans(9.5, curveChannel == channel ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(curveChannel == channel ? MColor.brass : MColor.text3)
                                .padding(.horizontal, 11)
                                .frame(height: 26)
                                .background(
                                    Capsule().fill(curveChannel == channel ? MColor.brassWash : MColor.surface2.opacity(0.7))
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        curveChannel == channel ? MColor.brass.opacity(0.32) : MColor.hairlineFaint,
                                        lineWidth: 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(channel != "RGB")
                        .opacity(channel == "RGB" ? 1 : 0.35)
                    }

                    Spacer()

                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.state) {
                            curvePoints = [
                                CGPoint(x: 0.0, y: 0.0),
                                CGPoint(x: 0.26, y: 0.26),
                                CGPoint(x: 0.52, y: 0.52),
                                CGPoint(x: 0.78, y: 0.78),
                                CGPoint(x: 1.0, y: 1.0),
                            ]
                        }
                    } label: {
                        Text("复位")
                            .font(.mSans(9.5, .medium))
                            .foregroundStyle(MColor.text3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 12)

                MCurveEditor(points: $curvePoints, channel: curveChannel)
                    .frame(height: 208)
                    .padding(.top, 10)

                HStack(spacing: 8) {
                    Spacer()
                    Text("中灰锁定")
                        .mMeta(8, color: MColor.text4)
                }
                .padding(.top, 7)
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 14)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
    }

    // MARK: - 工具条

    private var toolbar: some View {
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
        .padding(.bottom, 8 + insets.bottom)
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

    /// 底部只放三个分页；导出由顶栏承担，避免同一动作出现两个入口。
    private var toolItems: [(title: String, icon: String)] {
        [
            ("预设", "rectangle.stack"),
            ("调整", "slider.horizontal.3"),
            ("曲线", "waveform.path"),
        ]
    }

    private var gradeDirtyCount: Int {
        var count = 0
        if abs(recipe.exposure) > 1e-9 { count += 1 }
        if abs(recipe.contrast) > 1e-9 { count += 1 }
        if abs(recipe.highlights) > 1e-9 { count += 1 }
        if abs(recipe.shadows) > 1e-9 { count += 1 }
        if abs(recipe.whites) > 1e-9 { count += 1 }
        if abs(recipe.blacks) > 1e-9 { count += 1 }
        if abs(recipe.midtones) > 1e-9 { count += 1 }
        if abs(recipe.highlightRolloff) > 1e-9 { count += 1 }
        if abs(recipe.temperature) > 1e-9 { count += 1 }
        if abs(recipe.tint) > 1e-9 { count += 1 }
        if abs(recipe.saturation) > 1e-9 { count += 1 }
        if abs(recipe.vignette) > 1e-9 { count += 1 }
        if recipe.grain > 1e-9 { count += 1 }
        if recipe.lutName != "无 LUT" { count += 1 }
        return count
    }

    /// 把拖动后的点曲线折算成引擎已有的四段曲线量（阴影 / 暗部 / 亮部 / 高光）。
    private func syncCurve() {
        recipe.curveShadows = curveOffset(at: 0.12)
        recipe.curveDarks = curveOffset(at: 0.35)
        recipe.curveLights = curveOffset(at: 0.65)
        recipe.curveHighlights = curveOffset(at: 0.92)
    }

    private func curveOffset(at x: Double) -> Double {
        let sorted = curvePoints.sorted { $0.x < $1.x }
        guard sorted.count > 1 else { return 0 }
        let clamped = min(max(x, Double(sorted[0].x)), Double(sorted[sorted.count - 1].x))
        var y = clamped
        for index in 1..<sorted.count {
            let left = sorted[index - 1]
            let right = sorted[index]
            if clamped >= Double(left.x), clamped <= Double(right.x) {
                let dx = Double(right.x - left.x)
                if dx > 1e-9 {
                    let t = (clamped - Double(left.x)) / dx
                    y = Double(left.y) + (Double(right.y) - Double(left.y)) * t
                } else {
                    y = Double(right.y)
                }
                break
            }
        }
        return min(max((y - clamped) * 100, -100), 100)
    }
}
