import SwiftUI

struct DevelopScreen: View {
    @ObservedObject var session: MobileDevelopSession
    let onBack: () -> Void
    /// 点击调色时把当前预览图与它在根坐标系里的实际落点交给根视图，用于「吸入」动画。
    let onOpenGrade: (MPlatformImage?, CGRect) -> Void
    /// 吸入动画进行时隐藏原画布，避免照片被吸入后原位还留着一张。
    let previewHidden: Bool
    let onToast: (String) -> Void

    @State private var mode = DebugLaunch.modePro ? 1 : 0
    @State private var page = DebugLaunch.developPage
    @State private var drawerHeight: CGFloat = DebugLaunch.developDrawer
    @State private var panelContentHeight: CGFloat = 0
    @State private var panelViewportHeight: CGFloat = 0
    @State private var drawerChrome: CGFloat = 0

    @State private var showOriginal = false
    @State private var pressToken = 0
    @State private var zoom: CGFloat = DebugLaunch.canvasZoom
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
    @State private var exportOpen = DebugLaunch.exportOpen
    @State private var stageSize: CGSize = .zero
    // 分栏右栏的直方图：随预览图刷新，后台采样不阻塞显影渲染。
    @State private var histogram = MHistogramData.empty
    @State private var histogramToken = 0
    @State private var histogramInFlight = false
    // 首帧就绪前先弹出一块白色画布，再显影渐变成照片
    @State private var cardRect: CGRect = .zero
    @State private var cardOpacity: Double = 1
    @State private var cardVisible = false
    @State private var cardStarted = false
    @State private var cardRadius: CGFloat = 2
    @State private var imageRevealed = false
    /// 点击照片进入纯预览：顶栏、抽屉、底栏全部隐去，再点一次恢复。
    @State private var chromeHidden = false
    @Namespace private var tabPill

    @Environment(\.mHousing) private var housingSetting
    @Environment(\.mSafeInsets) private var insets
    private var housing: MHousingKind { MDeviceHousing.resolved(housingSetting) }

    /// 真实可用画布高度：由根视图注入的设备安全区算出，不再写死 852/54/34。
    private var availableHeight: CGFloat { insets.contentHeight }

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
                    canExport: session.isLoaded,
                    readFailed: session.loadFailure != nil,
                    onClose: { withAnimation(MMotion.pill) { exportOpen = false } },
                    onReturnHome: {
                        exportOpen = false
                        onBack()
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
            if housing != .none {
                MHousingAura(
                    housing: housing,
                    isActive: session.isRendering,
                    label: session.isRendering
                        ? (session.phaseLabel.isEmpty ? "显影中" : session.phaseLabel)
                        : ""
                )
            }
        }
        .onChange(of: stageSize) { _, _ in popCardIfReady() }
        .onChange(of: session.previewImage != nil) { _, hasImage in
            if hasImage { popCardIfReady() }
        }
        .onChange(of: isSplit) { _, split in
            // 进入分栏后右栏页签只剩光调/色彩/细节：停在预设或胶片页时回落到光调。
            if split && (page == 0 || page == 1) { page = 2 }
            // 直方图只在分栏可见：切入时补算当前预览，切回单列释放数据。
            if split {
                refreshHistogram(session.previewImage)
            } else {
                histogram = .empty
            }
        }
        .onChange(of: session.previewImage) { _, image in
            refreshHistogram(image)
        }
    }

    /// 后台采样预览图的 RGB 直方图；token 保证只采纳最新一帧。
    /// 只在分栏计算，且同一时刻只跑一个任务，避免单列白算与拖动期任务堆积。
    private func refreshHistogram(_ image: MPlatformImage?) {
        histogramToken += 1
        let token = histogramToken
        guard let image else {
            histogram = .empty
            return
        }
        guard isSplit, !histogramInFlight else { return }
        histogramInFlight = true
        Task.detached(priority: .utility) {
            let data = MHistogramSampler.compute(image) ?? .empty
            await MainActor.run {
                histogramInFlight = false
                guard token == histogramToken else { return }
                histogram = data
            }
        }
    }

    // MARK: - 单列布局（iPhone / iPad 竖屏 / 分屏）

    private var stackedLayout: some View {
        Group {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    previewStage
                        .frame(height: max(96, availableHeight - drawerHeight))
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
                    floatingChrome
                        .opacity(chromeHidden ? 0 : 1)
                        .allowsHitTesting(!chromeHidden)
                        .animation(MMotion.quick, value: chromeHidden)
                }
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

            tabBar(bottomPadding: 8 + insets.bottom)
                .opacity(chromeHidden ? 0 : 1)
                .allowsHitTesting(!chromeHidden)
                .animation(MMotion.quick, value: chromeHidden)

            MBackSwipe(action: onBack)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.top, insets.top)
        }
    }

    // MARK: - 分栏布局（iPad 横屏，参考 macOS 三栏：胶片轨 / 画布 / 参数栏）

    private var splitLayout: some View {
        HStack(spacing: 0) {
            filmStockRail
                .frame(width: MLayout.sideRailWidth(for: insets.size))

            Rectangle()
                .fill(MColor.hairline)
                .frame(width: 1)

            ZStack(alignment: .top) {
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

                floatingChrome
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                    .animation(MMotion.quick, value: chromeHidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                MBackSwipe(action: onBack)
                    .frame(width: 22)
            }

            Rectangle()
                .fill(MColor.hairline)
                .frame(width: 1)

            VStack(spacing: 0) {
                // 快速 / 专业：模式选择从画布悬浮移到参数栏顶部（参考 macOS Inspector）。
                HStack(spacing: 10) {
                    MModeCapsule(titles: ["快速", "专业"], mode: $mode)
                        .overlay { capsuleProgressRing }
                        .animation(MMotion.quick, value: session.phaseLabel)
                        .accessibilityLabel("显影模式")

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                // 直方图：macOS 编辑页同款卡片，显影参数调整时观察影调分布。
                splitHistogramCard
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                // 参数页签在顶部（预设 / 胶片相纸都在左轨）。
                MSplitTabRow(
                    titles: ["光调", "色彩", "细节"],
                    selection: splitPageIndex,
                    onSelect: { index in
                        withAnimation(MMotion.state) { page = splitPageIndices[index] }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)

                // 旋转 / 预览比例 / 撤销：参数栏的固定工具行。
                drawerToolRow
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                // 启动即横屏时 onChange 不会触发：渲染侧直接把预设/胶片页兜底成光调。
                splitPageContent
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, insets.bottom)
            }
            .frame(width: MLayout.inspectorWidth(for: insets.size))
        }
        .padding(.top, insets.top)
    }

    /// 分栏右栏的参数页 → 原 page 状态的下标映射（预设与胶片页已移到左轨）。
    private let splitPageIndices = [2, 3, 4]
    private var splitPageIndex: Int { splitPageIndices.firstIndex(of: page) ?? 0 }

    /// 分栏右栏永远渲染这三个参数页：page 停在预设/胶片页时显示光调。
    @ViewBuilder private var splitPageContent: some View {
        switch splitPageIndex {
        case 1: colorPage
        case 2: detailPage
        default: tonePage
        }
    }

    /// 直方图卡片：标题行 + RGB 折线，数据随预览图刷新。
    private var splitHistogramCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("直方图").mLabel(8, color: MColor.text3)
                Spacer(minLength: 8)
                Text("亮度 / RGB").mMeta(7.5, color: MColor.text4)
            }
            MHistogram(data: histogram)
        }
    }

    /// 左轨：显影预设 / 胶片 / 相纸切换 + 竖排列表（参考 macOS 预设栏）。
    @State private var railTab = 0

    private var filmStockRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MSideRailTab(title: "预设", selected: railTab == 0) {
                    withAnimation(MMotion.state) { railTab = 0 }
                }
                MSideRailTab(title: "胶片", selected: railTab == 1) {
                    withAnimation(MMotion.state) { railTab = 1 }
                }
                MSideRailTab(title: "相纸", selected: railTab == 2) {
                    withAnimation(MMotion.state) { railTab = 2 }
                }
                Spacer(minLength: 0)
                Text(railCountLabel)
                    .mMeta(8.5, color: MColor.text4)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    switch railTab {
                    case 0:
                        ForEach(MobileDevelopPresets.all) { preset in
                            developPresetRow(preset)
                        }
                    case 1:
                        ForEach(MobileCatalog.films) { film in filmRow(film) }

                        MHairline()
                            .padding(.vertical, 10)

                        MToggleRow(label: "黑白模式",
                                   isOn: Binding(
                                    get: { session.isMonochrome },
                                    set: { session.setMonochrome($0) }
                                   ),
                                   compact: true)

                        if mode == 1 {
                            proGroupsView(2)
                            resetButton("重置专业参数", action: resetPro)
                        }
                    default:
                        ForEach(MobileCatalog.papers) { paper in paperRow(paper) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, insets.bottom + 12)
            }
            .scrollIndicators(.never)
        }
        .background(MColor.app)
    }

    private var railCountLabel: String {
        switch railTab {
        case 0: return "\(MobileDevelopPresets.all.count) 个"
        case 1: return "\(MobileCatalog.films.count) 种"
        default: return "\(MobileCatalog.papers.count) 种"
        }
    }

    private func filmRow(_ film: MFilm) -> some View {
        let selected = film.id == session.filmID
        return Button {
            MHaptic.tick()
            withAnimation(MMotion.state) { session.setFilm(film.id) }
        } label: {
            HStack(spacing: 10) {
                MFilmStockIcon(film: film, size: 30)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? MColor.brassWash : MColor.surface2.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? MColor.brass.opacity(0.5) : MColor.hairline,
                                          lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(film.name)
                        .font(.mSans(12, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? MColor.brass : MColor.text1)
                        .lineLimit(1)
                    Text("\(film.brand) · \(film.kind)")
                        .mMeta(8, color: MColor.text4)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MColor.brass)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func paperRow(_ paper: MPaper) -> some View {
        let selected = paper.id == session.paperID
        return Button {
            MHaptic.tick()
            withAnimation(MMotion.state) { session.setPaper(paper.id) }
        } label: {
            HStack(spacing: 10) {
                MPaperStockIcon(paper: paper, size: 28)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? MColor.brassWash : MColor.surface2.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? MColor.brass.opacity(0.5) : MColor.hairline,
                                          lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(paper.name)
                        .font(.mSans(12, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? MColor.brass : MColor.text1)
                        .lineLimit(1)
                    Text(paper.note)
                        .mMeta(8, color: MColor.text4)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MColor.brass)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 开孔光效
    //
    // 光效由 MHousingAura 统一绘制：不表达进度，只有沿开孔轮廓游走的漏光与当前步骤文字。

    // MARK: - 顶部悬浮控件

    private var floatingChrome: some View {
        HStack(spacing: 8) {
            MCircleIconButton(icon: "chevron.left", size: 13, frame: 34) {
                onBack()
            }

            Spacer(minLength: 0)

            // 调色入口从底部页签移到顶栏，和调色台的导出按钮同一套黄铜胶囊。
            MBrassPill(title: "调色", icon: "slider.horizontal.3", height: 32) {
                openGrade()
            }
            .accessibilityLabel("进入调色台")
        }
        .frame(height: 34)
        .padding(.horizontal, 14)
        .overlay(alignment: .center) {
            // 分栏下快速/专业移到参数栏顶部：画布顶部只留返回与调色入口。
            if !isSplit {
                MModeCapsule(titles: ["快速", "专业"], mode: $mode)
                    .overlay { capsuleProgressRing }
                    .overlay(alignment: .bottom) { capsuleProgressText }
                    .offset(y: session.isRendering ? 16 : 0)
                    .animation(MMotion.drawer, value: session.isRendering)
                    .animation(MMotion.quick, value: session.phaseLabel)
            }
        }
        .padding(.top, 10)
        // 顶部按钮下面铺一层从上到下的黑色渐隐：放大后照片从控件下方经过时，模式胶囊与文件信息仍然可读。
        .background(alignment: .top) {
            MTopScrim(height: 170)
                .offset(y: -insets.top)
        }
    }

    /// 点击调色：把当前预览与落点交给根视图做吸入动画。
    private func openGrade() {
        let rect = fittedPreviewRect(in: stageSize)
        onOpenGrade(
            session.previewImage,
            CGRect(
                x: rect.minX,
                y: insets.top + rect.minY,
                width: rect.width,
                height: rect.height
            )
        )
    }

    /// 预览渲染比例菜单：1/8、1/4、1/2、1/1，与 Swift 主线的 previewScale 档位一致。
    private var previewScaleMenu: some View {
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
            .foregroundStyle(MColor.text2)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .mGlassSurface(Capsule(), fallbackFill: MColor.surface2.opacity(0.9))
            .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))
        }
        .accessibilityLabel("预览渲染比例")
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

    /// 没有刘海 / 灵动岛时，光效改套在「快速 / 专业」胶囊外圈；步骤文字统一落在胶囊下方，
    /// 不再由开孔光效绘制（那会和胶囊重叠）。
    @ViewBuilder private var capsuleProgressRing: some View {
        if housing == .none {
            MGlowSweep(
                shape: Capsule().inset(by: -4),
                isActive: session.isRendering,
                period: 4.2,
                coreWidth: 1.4
            )
        }
    }

    @ViewBuilder private var capsuleProgressText: some View {
        // 有开孔时文字归 MHousingAura 画在开孔下方；无开孔机型没有让位空间，才落在胶囊下方。
        if session.isRendering, housing == .none {
            Text(session.phaseLabel.isEmpty ? "显影中" : session.phaseLabel)
                .font(.mSans(9, .medium))
                .foregroundStyle(MColor.brassHigh.opacity(0.92))
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(y: 24)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 预览

    private var previewStage: some View {
        ZStack {
            // 预览区不再铺自己的深色底：照片直接落在页面底色上，四周没有额外衬底，
            // 放大时也不会出现一圈「背景层」读成蒙版。
            Group {
                if let image = showOriginal ? session.originalImage : session.previewImage {
                    MImage.swiftUI(image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .scaleEffect(zoom, anchor: zoomAnchor)
                        .offset(pan)
                        .animation(MMotion.state, value: showOriginal)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(MColor.text4)
                }
            }
            // 不再按预览槽裁切：画布是整个页面，放大后照片可以延伸到顶部控件与抽屉下面。
            .opacity(imageRevealed && !previewHidden ? 1 : 0)
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

            if let failure = session.loadFailure, !session.isLoaded {
                loadFailureCard(failure)
                    .zIndex(3)
                    .transition(.opacity)
            }

            cropMarks
                .zIndex(2)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.60)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
            .opacity(chromeHidden ? 0 : 1)
            .animation(MMotion.quick, value: chromeHidden)

            VStack {
                Spacer(minLength: 0)
                previewMeta
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            .opacity(chromeHidden ? 0 : 1)
            .animation(MMotion.quick, value: chromeHidden)
        }
        .overlay(alignment: .bottom) {
            MHairline(color: MColor.hairlineFaint)
        }
    }

    /// 原片读取失败时替代空白画布的失败卡：说明原因并给出重试入口。
    private func loadFailureCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(MColor.brassHigh)
            Text("原片读取失败")
                .font(.mSans(12, .semibold))
                .foregroundStyle(MColor.text1)
            Text(message)
                .font(.mSans(10, .regular))
                .foregroundStyle(MColor.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                MHaptic.light()
                session.retryLoad()
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

    private var previewMeta: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(showOriginal ? MColor.text3 : MColor.brass)
                        .frame(width: 4, height: 4)

                    Text(session.filename)
                        .font(.mSans(9.5, .medium))
                        .foregroundStyle(MColor.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("\(currentFilm.name) · \(currentPaper.name)")
                    .font(.mSans(8.5, .medium))
                    .foregroundStyle(MColor.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // 拖动期的 LUT 预测帧精度低于精算帧，必须让用户知道当前看到的是过渡画面。
            if session.isPredicted, !showOriginal {
                Text("预测")
                    .font(.mSans(8.5, .medium))
                    .foregroundStyle(MColor.brassHigh.opacity(0.92))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .mGlassSurface(Capsule(), fallbackFill: Color.black.opacity(0.42))
                    .accessibilityLabel("LUT 预测帧，停手后替换为精算帧")
            }

            if abs(zoom - 1) > 0.001 || showOriginal {
                Text(showOriginal ? "原片" : "\(Int(zoom * 100))%")
                    .font(.mSans(8.5, .medium).monospacedDigit())
                    .foregroundStyle(showOriginal ? MColor.text2 : MColor.text4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .mGlassSurface(Capsule(), fallbackFill: Color.black.opacity(0.42))
            }
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
        .opacity(chromeHidden || abs(zoom - 1) > 0.001 ? 0 : 1)
    }

    /// 与预览图 `.scaledToFit` 的落点保持一致（照片现在铺满预览区宽度），取景角只贴着照片。
    private func fittedPreviewRect(in size: CGSize) -> CGRect {
        let availableWidth = max(1, size.width)
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
            cardRect = fittedPreviewRect(in: stageSize)
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

    private func cardStartRect() -> CGRect {
        let width = stageSize.width
        var stageInsets = insets
        stageInsets.size.width = width
        let opening = MDeviceHousing.opening(kind: housing, insets: stageInsets)
        // 预览画布自身已经从安全区顶部开始，所以减去 insets.top 才是画布内坐标。
        return CGRect(
            x: opening.minX,
            y: opening.minY - insets.top,
            width: opening.width,
            height: opening.height
        )
    }

    // MARK: - 抽屉工具行

    private var drawerToolRow: some View {
        HStack(spacing: 6) {
            MCircleIconButton(icon: "rotate.right", size: 10, frame: 28) {
                MHaptic.tick()
                session.rotateClockwise()
            }
            .accessibilityLabel("顺时针旋转 90 度")

            previewScaleMenu

            Spacer(minLength: 0)

            MCircleIconButton(icon: "arrow.uturn.backward", size: 10, frame: 28) {
                session.undo()
            }
            .opacity(session.canUndo ? 1 : 0.36)
            .allowsHitTesting(session.canUndo)
            .accessibilityLabel("撤销")
        }
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
                pageContent
                    .id("\(page)-\(mode)")
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        )
                    )
            }
            .clipped()
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
            .animation(MMotion.state, value: page)
            .animation(MMotion.state, value: mode)
            .frame(maxHeight: .infinity)
        }
        // 抽屉和底部页签胶囊共用同一套原生液态玻璃材质，色调保持一致。
        .mGlassSurface(drawerShape, fallbackFill: MColor.surface2.opacity(0.96))
        .overlay {
            drawerShape
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
        // 阴影分两层：近处极淡、远处大半径，让边界是渐隐而不是一圈硬黑边。
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        // 旋转 / 预览比例 / 撤销浮在 sheet 外面顶部，和原本撤销按钮同一行。
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

    /// 内容高度变化后：短页锁成单档（并贴合内容），长页只负责收掉多余留白。
    private func syncDrawerToContent() {
        // 分栏下面板高度由右栏自然分配，drawerHeight 不参与布局，别再写状态引发多余重绘。
        guard !isSplit else { return }
        guard panelViewportHeight > 0, panelContentHeight > 0 else { return }
        let fit = fitHeight(for: panelContentHeight)
        let target: CGFloat
        if isLockedTab {
            target = fit
        } else {
            target = min(drawerHeight, fit)
        }
        guard abs(drawerHeight - target) > 1 else { return }
        // 在布局回调里只做赋值，不再启动动画：preference → 动画 → 布局 → preference 会形成反馈环。
        drawerHeight = target
        if DebugLaunch.probeGeometry {
            NSLog("MDrawer content=%.0f viewport=%.0f fit=%.0f min=%.0f locked=%d height=%.0f",
                  panelContentHeight, panelViewportHeight, fit, MMetric.drawerMin,
                  isLockedTab ? 1 : 0, target)
        }
    }

    /// 抽屉的固定装饰高度：把手 + 分页 + 底栏 + 安全区。与内容高度无关。
    private var chromeHeight: CGFloat { drawerChrome }

    /// 当前 tab 全部内容所需的抽屉高度，封顶三档。
    private func fitHeight(for content: CGFloat) -> CGFloat {
        guard content > 0, panelViewportHeight > 0 else { return MMetric.drawerMin }
        let needed = content + chromeHeight + 4
        if needed <= MMetric.drawerMin + 14 { return MMetric.drawerMin }
        return min(MMetric.drawerMax, needed)
    }

    private var fitDrawerHeight: CGFloat { fitHeight(for: panelContentHeight) }

    /// 二档判据：内容比「一档时能看到的视口」还高 → 展开有意义 → 显示 chevron。
    /// 以前用「fit 比一档高 120pt」，导致绝大多数调参页都被判成单档，箭头永远不出现。
    private var isLockedTab: Bool {
        guard panelContentHeight > 0 else { return true }
        let collapsedViewport = MMetric.drawerMin - chromeHeight - 4
        return panelContentHeight <= collapsedViewport + 24
    }

    private var minDrawerHeight: CGFloat {
        isLockedTab ? fitDrawerHeight : MMetric.drawerMin
    }

    /// 二档是否已展开（只差 1pt 以内视为同档）。
    private var isDrawerExpanded: Bool {
        drawerHeight > minDrawerHeight + 1
    }

    /// 点击 chevron：在「一档」与「刚好容纳当前页内容」之间切换。
    /// 用带轻微回弹的 spring，而非线性计时；iOS 26 上系统 chevron 的按压反馈由 Button 自带。
    private func toggleDrawer() {
        guard !isLockedTab else { return }
        let target = isDrawerExpanded ? minDrawerHeight : fitDrawerHeight
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            drawerHeight = target
        }
    }

    // MARK: - 分页

    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0:
            developPresetPage
        case 1:
            filmPage
        case 2:
            tonePage
        case 3:
            colorPage
        default:
            detailPage
        }
    }

    // MARK: - 显影预设

    private var developPresetPage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MSectionHead(title: "显影预设", trailing: "\(MobileDevelopPresets.all.count) 个")
                    .padding(.top, 10)

                ForEach(MobileDevelopPresets.all) { preset in
                    developPresetRow(preset)
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 16)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
    }

    private func developPresetRow(_ preset: MDevelopPreset) -> some View {
        let film = MobileCatalog.film(id: preset.filmID) ?? MobileCatalog.films[0]
        let selected = session.matches(preset)
        return Button {
            MHaptic.light()
            withAnimation(MMotion.state) {
                session.applyDevelopPreset(preset)
            }
            onToast("已套用 \(preset.name)")
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? MColor.brassWash : MColor.surface2.opacity(0.6))
                        .frame(width: 38, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selected ? MColor.brass.opacity(0.5) : MColor.hairline,
                                              lineWidth: 1)
                        )
                    MFilmStockIcon(film: film, size: 28)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.mSans(11.5, .medium))
                        .foregroundStyle(MColor.text1)
                    Text(preset.note)
                        .font(.mSans(8.5, .medium))
                        .foregroundStyle(MColor.text4)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MColor.brass)
                }
            }
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 胶片页

    private var filmPage: some View {
        ScrollView(.vertical) {
            VStack(spacing: 14) {
                filmRail
                paperRail

                MToggleRow(label: "黑白模式",
                           isOn: Binding(
                            get: { session.isMonochrome },
                            set: { session.setMonochrome($0) }
                           ),
                           compact: true)

                if mode == 1 {
                    proGroupsView(2)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.vertical, 6)
            .background(MPanelHeightReporter())
            // 内容不足一屏时在 sheet 里垂直居中。面板顶部还有 22pt 把手（chrome），
            // 只在把手以下视口居中会让内容整体偏下一个 chrome/2；
            // 在底部补回等量 padding，让居中基准回到整块面板。
            .padding(.bottom, drawerChrome)
            .frame(minHeight: max(0, panelViewportHeight), alignment: .center)
        }
        .scrollIndicators(.never)
    }

    private var filmRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            railTitle("胶片")

            MHScrollRail(itemCount: MobileCatalog.films.count,
                         leading: MMetric.pageMargin, itemHeight: 52,
                         fadeColor: .clear) {
                ForEach(MobileCatalog.films) { film in
                    MFilmRailItem(film: film, selected: film.id == session.filmID) {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { session.setFilm(film.id) }
                    }
                }
            }
            .frame(height: 52)
            // 滚动行铺满 sheet 宽度：只保留首项对齐标题的左边距，两侧不再有渐隐边框。
            .padding(.horizontal, -MMetric.pageMargin)
        }
    }

    private var paperRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            railTitle("相纸")

            MHScrollRail(itemCount: MobileCatalog.papers.count,
                         leading: MMetric.pageMargin, itemHeight: 52,
                         fadeColor: .clear) {
                ForEach(MobileCatalog.papers) { paper in
                    MPaperRailItem(paper: paper, selected: paper.id == session.paperID) {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { session.setPaper(paper.id) }
                    }
                }
            }
            .frame(height: 52)
            .padding(.horizontal, -MMetric.pageMargin)
        }
    }

    private func railTitle(_ title: String) -> some View {
        Text(title)
            .mLabel(7.5, color: MColor.text4)
            .padding(.leading, 1)
    }

    // MARK: - 光调页

    private var tonePage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if mode == 0 {
                    quickSectionHead(
                        "光调",
                        trailing: lightDirtyCount > 0 ? "\(lightDirtyCount) 项已调" : "基线"
                    ) {
                        resetQuick()
                    }
                    .padding(.top, 2)

                    quickSlider("camera_exposure")
                    quickSlider("print_brightness")
                    quickSlider("tonal_contrast")
                    quickSlider("highlight_softening")

                    if scanFilmMode {
                        Text(printOnlyQuickNote)
                            .mMeta(7.5, color: MColor.text4)
                            .padding(.top, -2)
                    }
                } else {
                    proGroupsView(0)
                        .padding(.top, 2)

                    resetButton("重置专业参数", action: resetPro)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 16)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
    }

    // MARK: - 色彩页

    private var colorPage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if mode == 0 {
                    quickSectionHead("色彩") {
                        resetQuick()
                    }

                    quickSlider("color_density")

                    HStack(spacing: 4) {
                        Text("印相色彩").mLabel(8, color: MColor.text4)
                        Spacer(minLength: 0)
                        Text("Y / M").mMeta(7.5, color: MColor.text4)
                    }
                    .padding(.top, 8)

                    GeometryReader { geo in
                        MColorPad(
                            x: padXBinding,
                            y: padYBinding,
                            width: max(1, geo.size.width),
                            height: 96,
                            isEnabled: !scanFilmMode
                        )
                    }
                    .frame(height: 96)
                    .padding(.top, 6)

                    HStack(spacing: 6) {
                        Text("冷暖 \(ccText(session.padX))")
                            .font(.mSans(8, .medium).monospacedDigit())
                            .foregroundStyle(abs(session.padX) > 0.5 && !scanFilmMode ? MColor.brass : MColor.text3)
                        Spacer(minLength: 0)
                        Text("品红 \(ccText(session.padY))")
                            .font(.mSans(8, .medium).monospacedDigit())
                            .foregroundStyle(abs(session.padY) > 0.5 && !scanFilmMode ? MColor.brass : MColor.text3)
                    }
                    .padding(.top, 6)

                    if scanFilmMode {
                        Text(printOnlyQuickNote)
                            .mMeta(7.5, color: MColor.text4)
                            .padding(.top, 4)
                    }

                } else {
                    proGroupsView(1)
                        .padding(.top, 2)

                    resetButton("重置专业参数", action: resetPro)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
            .padding(.bottom, 16)
            .background(MPanelHeightReporter())
        }
        .scrollIndicators(.never)
    }

    // MARK: - 细节页

    private var detailPage: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if mode == 0 {
                        quickSectionHead("质感") {
                            resetQuick()
                        }

                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 0) {
                                quickSlider("grain_amount")
                                quickSlider("grain_size")
                                quickSlider("scanner_clarity")
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)

                            // 与左侧三条滑杆整块垂直居中：颗粒预览不再顶在上沿。
                            MGrainSample(intensity: grainIntensity)
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .padding(.top, 2)

                    } else {
                        proGroupsView(3)
                            .padding(.top, 2)

                        resetButton("重置专业参数", action: resetPro)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, MMetric.pageMargin)
                .padding(.bottom, 16)
                .background(MPanelHeightReporter())
            }
            .scrollIndicators(.never)
            .onAppear {
                guard DebugLaunch.developPanelBottom, mode == 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(nil) { proxy.scrollTo("detail-output", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - 通用小组件

    @ViewBuilder private func quickSlider(_ id: String) -> some View {
        if let axis = allQuickAxes.first(where: { $0.id == id }) {
            MParamSlider(
                label: axis.label,
                value: binding(for: axis),
                base: axis.base,
                range: axis.range,
                step: axis.step,
                decimals: axis.decimals,
                suffix: axis.suffix,
                isEnabled: !(scanFilmMode && printOnlyQuickAxes.contains(id)),
                compact: true
            )
        }
    }

    @ViewBuilder private func proGroupsView(_ pageIndex: Int) -> some View {
        ForEach(MobileCatalog.proPages[pageIndex].groups) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(group.title)
                    .mLabel(8, color: MColor.text4)
                    .padding(.top, 12)
                    .padding(.bottom, 1)

                ForEach(group.rows) { row in
                    proRow(row)
                }
            }
            .id(group.id)
        }
    }

    private func proRow(_ row: MProRow) -> some View {
        Group {
            switch row.control {
            case .slider(_, let base, let range, let step, let decimals, let suffix):
                MParamSlider(
                    label: row.label,
                    value: Binding(
                        get: { session.proValues[row.id] ?? base },
                        set: { session.applyPro(row.id, $0) }
                    ),
                    base: session.proBaseline(row.id),
                    range: range,
                    step: step,
                    decimals: decimals,
                    suffix: suffix,
                    compact: true
                )
            case .toggle(let isOn):
                MToggleRow(
                    label: row.label,
                    isOn: Binding(
                        get: { session.proToggles[row.id] ?? isOn },
                        set: { session.applyProToggle(row.id, $0) }
                    ),
                    compact: true
                )
            case .choice(let options, let fallback):
                let current = session.choiceValue(row.id)
                let currentLabel = options.first(where: { $0.value == current })?.label ?? fallback
                HStack {
                    Text(row.label)
                        .font(.rowLabel)
                        .foregroundStyle(MColor.text2)
                    Spacer()
                    Menu {
                        ForEach(options, id: \.value) { option in
                            Button {
                                MHaptic.tick()
                                session.applyProChoice(row.id, option.value)
                            } label: {
                                Text(option.label)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentLabel)
                                .font(.mSans(10.5, .medium))
                                .foregroundStyle(current == fallback ? MColor.text2 : MColor.brass)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(MColor.text4)
                        }
                    }
                }
                .frame(height: 50)
            }
        }
    }

    private func quickSectionHead(
        _ title: String,
        trailing: String? = nil,
        reset: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).mLabel(8.5, color: MColor.text3)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).mMeta(8, color: MColor.text4)
            }

            Button {
                MHaptic.tick()
                withAnimation(MMotion.state) { reset() }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(MColor.text3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func resetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            MHaptic.medium()
            withAnimation(MMotion.state) { action() }
        } label: {
            Text(title)
                .font(.mSans(10, .medium))
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
        .padding(.top, 10)
    }

    // MARK: - 底部页签

    private func tabBar(bottomPadding: CGFloat) -> some View {
        MGlassTabCapsule {
            ForEach(Array(pageItems.enumerated()), id: \.offset) { item in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { page = item.offset }
                } label: {
                    tabLabel(item.element, index: item.offset)
                }
                .buttonStyle(.plain)
            }
        }
        // iOS 26 悬浮玻璃胶囊：不再贴边铺一条实底，而是留出左右与底部的呼吸。
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

    private func tabLabel(_ item: (title: String, icon: String), index: Int) -> some View {
        VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tabTone(index))
                .frame(height: 21)

            Text(item.title)
                .font(.mSans(8.5, tabWeight(index)))
                .foregroundStyle(tabTone(index))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background {
            if page == index {
                // 选中项只铺一层很薄的黄铜玻璃，不再画独立的小方块图标底。
                Capsule()
                    .fill(MColor.brassWash)
                    .overlay(Capsule().strokeBorder(MColor.brass.opacity(0.20), lineWidth: 1))
                    .padding(.vertical, 3)
                    .matchedGeometryEffect(id: "glass-tab", in: tabPill)
            }
        }
        .contentShape(Rectangle())
    }

    private func tabTone(_ index: Int) -> Color {
        page == index ? MColor.brass : MColor.text3
    }

    private func tabWeight(_ index: Int) -> Font.Weight {
        page == index ? .semibold : .medium
    }

    private var pageItems: [(title: String, icon: String)] {
        [
            ("预设", "square.stack"),
            ("胶片", "film"),
            ("光调", "sun.max"),
            ("色彩", "drop"),
            ("细节", "camera.filters"),
        ]
    }

    // MARK: - 状态与绑定

    private var allQuickAxes: [MQuickAxis] {
        MobileCatalog.quickGroups.flatMap(\.axes)
    }

    /// 正片扫描模式：管线跳过印相曝光/显影，印相专属快速轴不参与成像。
    private var scanFilmMode: Bool {
        session.proToggles["scan_film"] ?? false
    }

    /// 与参考 `PRINT_ONLY_AXES` 对齐：印相明暗、影调反差、高光柔和（色盘 Y/M 单独处理）。
    private var printOnlyQuickAxes: Set<String> {
        ["print_brightness", "tonal_contrast", "highlight_softening"]
    }

    private let printOnlyQuickNote = "正片扫描模式：管线跳过印相阶段，本项不参与成像"

    private var currentFilm: MFilm {
        MobileCatalog.film(id: session.filmID) ?? MobileCatalog.films[0]
    }

    private var currentPaper: MPaper {
        MobileCatalog.paper(id: session.paperID) ?? MobileCatalog.papers[0]
    }

    private var lightDirtyCount: Int {
        dirtyCount(in: "光调")
    }

    private func dirtyCount(in group: String) -> Int {
        allQuickAxes.filter { axis in
            axis.group == group
                && abs((session.quickValues[axis.id] ?? axis.base) - axis.base) > 1e-9
        }.count
    }

    private var padXBinding: Binding<Double> {
        Binding(
            get: { session.padX },
            set: { session.applyPad(x: $0, y: session.padY) }
        )
    }

    private var padYBinding: Binding<Double> {
        Binding(
            get: { session.padY },
            set: { session.applyPad(x: session.padX, y: $0) }
        )
    }

    private var grainIntensity: Double {
        let value = session.quickValues["grain_amount"] ?? 0
        return min(1, max(0.04, (value + 100) / 200))
    }

    private func ccText(_ value: Double) -> String {
        let cc = value * 0.6
        if abs(cc) < 0.05 { return "0 CC" }
        let text = String(format: "%.1f", cc).replacingOccurrences(of: ".0", with: "")
        return (cc > 0 ? "+\(text)" : text) + " CC"
    }

    private func binding(for axis: MQuickAxis) -> Binding<Double> {
        Binding(
            get: { session.quickValues[axis.id] ?? axis.base },
            set: { session.applyQuick(axis.id, $0) }
        )
    }

    private func resetQuick() {
        session.resetQuick()
    }

    private func resetPro() {
        session.resetPro()
    }
}

// MARK: - 导出面板

/// 导出面板：居中浮卡、四个圆角、无顶部横条。
/// 选项按参考图排成「标签 + 下拉行」；保存动画只走「转圈 → 对勾」两拍，不显示进度条。
struct MExportSheet: View {
    let filename: String
    let phaseLabel: String
    /// 原图真实长边，用于「最大可用尺寸」的具体像素数。
    var originalLongEdge: Int = 0
    /// 原片还没读完时不能导出：`session.export` 会以 `.busy` 立刻失败。
    var canExport: Bool = true
    /// 读取已经失败（而不是仍在读取），副标题需要给出失败提示而不是「正在读取原片…」。
    var readFailed: Bool = false
    let onClose: () -> Void
    let onReturnHome: () -> Void
    /// 相册写入是后台静默的，失败时用调用方的 toast 说明「文件已在 App 内」。
    var onNote: (String) -> Void = { _ in }
    let onExport: (Int, Int, Double, @escaping (Result<URL, Error>) -> Void) -> Void

    /// 指针指向 `formats` 的下标；初始值来自设置里的默认导出格式。
    @State private var formatIndex = MobileSettings.defaultExportFormatIndex
    /// 0 最大可用尺寸、1 2048、2 4096。
    @State private var edgeIndex = MobileSettings.defaultExportEdgeIndex
    /// 0 100%、1 95%、2 90%、3 80%。
    @State private var qualityIndex = MobileSettings.defaultExportQualityIndex
    @State private var showMore = false
    @State private var phase: MExportPhase = .idle
    /// 完成对勾的入场动画开关。
    @State private var donePop = false
    @Environment(\.mSafeInsets) private var insets

    private enum MExportPhase {
        case idle
        case exporting
        case done
    }

    private struct Format {
        /// 引擎档位：0 sRGB TIFF16、1 ProPhoto TIFF16、2 ACES EXR、3 JPEG。
        let id: Int
        let title: String
        let space: String
        let bitDepth: String
    }

    private let formats: [Format] = [
        Format(id: 3, title: "JPEG", space: "sRGB", bitDepth: "8-bit"),
        Format(id: 0, title: "TIFF · sRGB 16-bit", space: "sRGB", bitDepth: "16-bit"),
        Format(id: 1, title: "TIFF · ProPhoto 16-bit", space: "ProPhoto RGB", bitDepth: "16-bit 线性"),
        Format(id: 2, title: "EXR · ACES half", space: "ACES2065-1", bitDepth: "16-bit half"),
    ]
    private let qualityValues = [100, 95, 90, 80]

    private var format: Format { formats[min(max(formatIndex, 0), formats.count - 1)] }
    private var isJPEG: Bool { format.id == 3 }

    /// 居中浮卡：收窄成小窗，左右留白更足。
    private var cardWidth: CGFloat { min(insets.size.width - 64, 330) }

    var body: some View {
        ZStack {
            // scrim：导出进行中不允许点空白关闭，防止半途丢上下文。
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture {
                    guard phase != .exporting else { return }
                    withAnimation(MMotion.pill) { onClose() }
                }
                .transition(.opacity)

            card
                .transition(.scale(0.94).combined(with: .opacity))
        }
        // 截图验收：等原片读完再自动开跑导出（原片没读完时 export 会以 .busy 立刻失败）
        .onChange(of: canExport) { _, ready in
            guard ready, DebugLaunch.exportAutoStart, phase == .idle else { return }
            beginExport()
        }
        .task {
            guard canExport, DebugLaunch.exportAutoStart, phase == .idle else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if phase == .idle { beginExport() }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            Text(subtitle)
                .font(.mSans(12, .medium))
                .foregroundStyle(phase == .done ? MColor.brass : MColor.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 20)

            switch phase {
            case .idle:
                optionRows
            case .exporting, .done:
                statusBlock
            }
        }
        .padding(.bottom, 14)
        .frame(width: cardWidth)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                    .fill(MColor.surface1.opacity(0.92))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 26, y: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                guard phase != .exporting else { return }
                MHaptic.light()
                withAnimation(MMotion.pill) { onClose() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MColor.text2)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(MColor.surface3))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(phase == .exporting)
            .opacity(phase == .exporting ? 0.35 : 1)
            .accessibilityLabel("关闭")

            Spacer(minLength: 0)

            Text(phaseTitle)
                .font(.mSans(15, .semibold))
                .foregroundStyle(MColor.text1)
                .lineLimit(1)

            Spacer(minLength: 0)

            confirmButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var confirmButton: some View {
        Button {
            switch phase {
            case .idle:
                beginExport()
            case .exporting:
                break
            case .done:
                withAnimation(MMotion.pill) { onReturnHome() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(phase == .exporting ? MColor.surface3 : MColor.brass)
                switch phase {
                case .exporting:
                    // 进行中的转圈只留在卡片中央，右上角退成禁用态，避免两个转圈抢视线。
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MColor.text4)
                case .idle:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canExport ? MColor.brassInk : MColor.text4)
                case .done:
                    Image(systemName: "house.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MColor.brassInk)
                }
            }
            .frame(width: 32, height: 32)
            .opacity(phase == .idle && !canExport ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(phase == .exporting || (phase == .idle && !canExport))
        .accessibilityLabel(phase == .done ? "完成并返回" : "确认导出")
    }

    private var phaseTitle: String {
        switch phase {
        case .idle: return "导出设置"
        case .exporting: return "正在导出"
        case .done: return "导出完成"
        }
    }

    private var subtitle: String {
        switch phase {
        case .idle:
            if canExport { return "副本将保存到设备" }
            return readFailed ? "原片读取失败，请返回重试" : "正在读取原片…"
        case .exporting:
            return phaseLabel.isEmpty ? "正在印相…" : phaseLabel
        case .done:
            return "副本已保存到设备"
        }
    }

    // MARK: 选项

    private var optionRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("文件类型") { formatField }
            field("尺寸") { edgeField }
            field("图像品质") { qualityField }

            hairline

            moreOptions
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var formatField: some View {
        Menu {
            ForEach(Array(formats.enumerated()), id: \.offset) { item in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { formatIndex = item.offset }
                } label: {
                    if item.offset == formatIndex {
                        Label(item.element.title, systemImage: "checkmark")
                    } else {
                        Text(item.element.title)
                    }
                }
            }
        } label: {
            fieldChrome {
                Text(format.title)
                    .font(.mSans(13.5, .medium))
                    .foregroundStyle(MColor.text1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .accessibilityLabel("文件类型")
        .accessibilityValue(format.title)
    }

    private var edgeField: some View {
        Menu {
            ForEach(0..<3, id: \.self) { index in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { edgeIndex = index }
                } label: {
                    if index == edgeIndex {
                        Label(edgeTitle(index), systemImage: "checkmark")
                    } else {
                        Text(edgeTitle(index))
                    }
                }
            }
        } label: {
            fieldChrome {
                VStack(alignment: .leading, spacing: 1) {
                    Text(edgeTitle(edgeIndex))
                        .font(.mSans(13.5, .medium))
                        .foregroundStyle(MColor.text1)
                        .lineLimit(1)
                    Text(edgeMeta)
                        .mMeta(9, color: MColor.text3)
                        .lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .accessibilityLabel("尺寸")
        .accessibilityValue(edgeTitle(edgeIndex))
    }

    @ViewBuilder
    private var qualityField: some View {
        if isJPEG {
            Menu {
                ForEach(Array(qualityValues.enumerated()), id: \.offset) { item in
                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { qualityIndex = item.offset }
                    } label: {
                        if item.offset == qualityIndex {
                            Label("\(item.element)%", systemImage: "checkmark")
                        } else {
                            Text("\(item.element)%")
                        }
                    }
                }
            } label: {
                fieldChrome {
                    Text("\(qualityValues[min(qualityIndex, qualityValues.count - 1)])%")
                        .font(.mSans(13.5, .medium).monospacedDigit())
                        .foregroundStyle(MColor.text1)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("图像品质")
        } else {
            fieldChrome(chevron: false) {
                HStack(spacing: 7) {
                    Text("无损")
                        .font(.mSans(13.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Text("· \(format.bitDepth)")
                        .mMeta(9.5, color: MColor.text3)
                }
            }
            .accessibilityLabel("图像品质")
            .accessibilityValue("无损")
        }
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                MHaptic.tick()
                withAnimation(MMotion.state) { showMore.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("更多选项")
                        .font(.mSans(12.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MColor.text3)
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                VStack(spacing: 8) {
                    infoRow("文件名", filename)
                    infoRow("色彩空间", format.space)
                    infoRow("位深", format.bitDepth)
                    infoRow("输出长边", edgeMeta)
                    infoRow("保存位置", "相册 · 文件 App")
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 保存动画只走两拍：转圈 → 对勾。不放进度条，也不再展开选项行。
    private var statusBlock: some View {
        Group {
            switch phase {
            case .exporting:
                ProgressView()
                    .tint(MColor.text2)
                    .scaleEffect(1.15)
                    .transition(.opacity.combined(with: .scale(0.7)))
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(MColor.brassInk)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(MColor.brass))
                    .scaleEffect(donePop ? 1 : 0.55)
                    .opacity(donePop ? 1 : 0)
                    .onAppear {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                            donePop = true
                        }
                    }
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 组件

    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text3)
            content()
        }
    }

    private func fieldChrome<Content: View>(
        chevron: Bool = true, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MColor.text3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                .fill(MColor.surface2.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                .strokeBorder(MColor.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .mMeta(10, color: MColor.text3)
            Spacer(minLength: 0)
            Text(value)
                .font(.mSans(10.5, .medium))
                .foregroundStyle(MColor.text2)
                .lineLimit(1)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(MColor.hairline)
            .frame(height: 1)
    }

    // MARK: 行为

    private func edgeTitle(_ index: Int) -> String {
        index == 0 ? "最大可用尺寸" : (index == 1 ? "2048 px" : "4096 px")
    }

    private var edgeMeta: String {
        switch edgeIndex {
        case 0:
            return originalLongEdge > 0 ? "原图长边 \(originalLongEdge) px" : "按原图长边"
        case 1:
            return "长边 2048 px"
        default:
            return "长边 4096 px"
        }
    }

    private func beginExport() {
        guard phase == .idle, canExport else { return }
        MHaptic.medium()
        donePop = false
        withAnimation(MMotion.state) { phase = .exporting }
        let quality = isJPEG ? Double(qualityValues[min(qualityIndex, qualityValues.count - 1)]) / 100 : 0.95
        onExport(format.id, edgeIndex, quality) { result in
            switch result {
            case .success(let url):
                // 默认保存到相册：成功不打扰，失败/被拒时必须告诉用户文件还在 App 内。
                PhotoLibraryExport.save(url) { outcome in
                    switch outcome {
                    case .saved:
                        break
                    case .denied:
                        onNote("未授权相册 · 文件已导出到 App 内")
                    case .failed:
                        onNote("相册写入失败 · 文件已导出到 App 内")
                    }
                }
                withAnimation(MMotion.state) { phase = .done }
            case .failure:
                withAnimation(MMotion.state) { phase = .idle }
            }
        }
    }
}

