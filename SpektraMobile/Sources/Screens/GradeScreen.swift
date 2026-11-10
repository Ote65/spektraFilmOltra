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
    @State private var panelContentHeight: CGFloat = 0
    @State private var panelViewportHeight: CGFloat = 0
    @State private var drawerChrome: CGFloat = 0
    @State private var exportOpen = DebugLaunch.exportOpen
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

            // 参数面板是悬浮在底部胶囊上方的圆角窗口：底边与胶囊顶边留固定间距。
            drawer
                .padding(.horizontal, MMetric.floatingPanelInset)
                .frame(height: drawerHeight)
                .padding(.bottom, insets.bottom + MMetric.tabCapsuleBottom
                    + MMetric.tabCapsuleHeight + MMetric.floatingPanelGap)

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

            HStack(spacing: 8) {
                Spacer()
                Text("中灰锁定")
                    .mMeta(8, color: MColor.text4)
            }
            .padding(.top, 7)
        }
    }

    private func resetCurve() {
        curvePoints = [
            CGPoint(x: 0.0, y: 0.0),
            CGPoint(x: 0.26, y: 0.26),
            CGPoint(x: 0.52, y: 0.52),
            CGPoint(x: 0.78, y: 0.78),
            CGPoint(x: 1.0, y: 1.0),
        ]
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
                    MHaptic.medium()
                    withAnimation(MMotion.state) {
                        recipe = MGradeRecipe()
                        resetCurve()
                    }
                    onToast("调色参数已重置")
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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("片边")
                        .mLabel(8.5, color: MColor.text3)
                    Spacer(minLength: 8)
                    Text(MFilmBorderPreset.name(for: session.border))
                        .mMeta(8, color: MColor.text4)
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
                }
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

                MToggleRow(label: "启用片边", isOn: borderEnabled, compact: true)

                if session.border.enabled {
                    MChoiceRow(label: "片边预设", value: MFilmBorderPreset.name(for: session.border),
                               options: borderPresetOptions) { id in
                        guard let preset = MFilmBorderPreset.preset(id: id) else { return }
                        withAnimation(MMotion.state) { session.setBorderPreset(preset) }
                    }

                    MChoiceRow(label: "底片规格", value: session.border.gaugeValue.label,
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

                    MParamSlider(label: "片边宽度", value: borderDouble(\.borderScale),
                                 base: 1, range: 0.4...2.0, step: 0.01, decimals: 2,
                                 suffix: "×", compact: true)

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

                    MChoiceRow(label: "片基色调", value: baseValue.label,
                               options: baseOptions) { raw in
                        session.updateBorder { $0.baseTone = raw }
                    }
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
                        MToggleRow(label: "DX 码", isOn: borderBool(\.dxCode), compact: true)
                    }

                    if session.border.gaugeValue.isSheet {
                        MToggleRow(label: "片缺口", isOn: borderBool(\.notch), compact: true)
                    }

                    MParamSlider(label: "划痕", value: borderDouble(\.scratches),
                                 base: 0.18, range: 0...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)
                    MParamSlider(label: "灰尘", value: borderDouble(\.dust),
                                 base: 0.14, range: 0...1, step: 0.01, decimals: 2,
                                 suffix: "", compact: true)
                    MParamSlider(label: "边缘雾化", value: borderDouble(\.fog),
                                 base: 0.10, range: 0...1, step: 0.01, decimals: 2,
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

    private var borderPresetOptions: [MProOption] {
        MFilmBorderPreset.all.map { MProOption(value: $0.id, label: $0.name) }
    }

    private var gaugeOptions: [MProOption] {
        MFilmBorderGauge.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var cornerOptions: [MProOption] {
        MFilmBorderCorner.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var perfOptions: [MProOption] {
        MFilmBorderPerf.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var baseOptions: [MProOption] {
        MFilmBorderBase.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
    }

    private var textToneOptions: [MProOption] {
        MFilmBorderTextTone.allCases.map { MProOption(value: $0.rawValue, label: $0.label) }
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
