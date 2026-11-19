import SwiftUI
import AVFoundation
import UIKit
import CoreMedia

// MARK: - iOS 视频显影台
//
// 布局与照片显影台一致：上方画布 + 悬浮参数面板 + 底部胶囊。
// 差异（按需求）：没有调色台、没有专业/快速模式、没有旋转裁切、没有预设；
// 底部页签胶囊换成播放控制器（左播放暂停 + 中间可拖动进度条）。

struct MVideoScreen: View {
    @ObservedObject var session: MVideoSession
    let onBack: () -> Void
    let onToast: (String) -> Void

    @State private var exportOpen = false
    /// 参数面板收起后画布让出整块空间，只留播放条的位置。
    @State private var drawerCollapsed = false
    /// 进场：面板与播放条从下方浮入，视频画面只随整页淡入。
    @State private var entered = false
    @Environment(\.mSafeInsets) private var insets

    /// 参数两段轨道 + 十余条轴：固定一个高度，超出部分在面板内滚动。
    private var drawerHeight: CGFloat {
        min(max(316, insets.contentHeight * 0.46), 470)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MColor.app

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    MVideoStage(session: session)
                        .frame(height: max(150, insets.contentHeight
                            - (drawerCollapsed ? 96 : drawerHeight)))

                    MVideoTopChrome(
                        session: session,
                        onBack: {
                            session.pausePlayback()
                            onBack()
                        },
                        onRender: {
                            session.pausePlayback()
                            withAnimation(MMotion.panelSlide) { exportOpen = true }
                        }
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.top, insets.top)

            MVideoDrawer(session: session, onCollapse: {
                MHaptic.light()
                withAnimation(MMotion.panelSlide) { drawerCollapsed = true }
            })
            .frame(height: drawerHeight)
            .padding(.horizontal, MMetric.floatingPanelInset)
            .padding(.bottom, insets.bottom + MMetric.tabCapsuleBottom
                + MMetric.tabCapsuleHeight + MMetric.floatingPanelGap)
            // 收起后要连把手一起移出屏幕，只差一点会露出一条边。
            .offset(y: (drawerCollapsed ? drawerHeight + 190 : 0) + (entered ? 0 : 46))
            .opacity(entered ? 1 : 0)
            .allowsHitTesting(!drawerCollapsed)

            MVideoPlaybackBar(
                session: session,
                showsDrawerToggle: drawerCollapsed,
                onExpandDrawer: {
                    MHaptic.light()
                    withAnimation(MMotion.panelSlide) { drawerCollapsed = false }
                }
            )
            .padding(.bottom, 8 + insets.bottom)
            .offset(y: entered ? 0 : 34)
            .opacity(entered ? 1 : 0)

            MBackSwipe(action: {
                session.pausePlayback()
                onBack()
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top, insets.top)
        }
        .background(MColor.app)
        .onAppear {
            guard !entered else { return }
            // 比整页淡入稍晚一点起手，控件落位在画面之后，观感才有层次。
            withAnimation(.easeOut(duration: 0.34).delay(0.06)) { entered = true }
            if DebugLaunch.videoCollapse {
                withAnimation(MMotion.panelSlide.delay(0.5)) { drawerCollapsed = true }
            }
        }
        .overlay {
            if exportOpen {
                MVideoExportOverlay(
                    session: session,
                    onClose: { withAnimation(MMotion.panelSlide) { exportOpen = false } },
                    onToast: onToast
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(20)
            }
        }
        .task {
            await session.start()
            for quick in DebugLaunch.videoQuicks {
                session.applyQuick(quick.0, value: quick.1)
            }
            if DebugLaunch.videoExport {
                withAnimation(MMotion.state) { exportOpen = true }
            }
        }
    }
}

// MARK: - 顶栏

private struct MVideoTopChrome: View {
    @ObservedObject var session: MVideoSession
    let onBack: () -> Void
    let onRender: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MCircleIconButton(icon: "chevron.left", size: 13, frame: 34) {
                onBack()
            }

            Spacer(minLength: 0)

            MBrassPill(title: "渲染视频", icon: "wand.and.stars", height: 32) {
                onRender()
            }
            .accessibilityLabel("渲染视频")
        }
        .frame(height: 44)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .overlay(alignment: .center) {
            VStack(spacing: 1) {
                Text(session.project.displayName)
                    .font(.mSans(11, .medium))
                    .foregroundStyle(MColor.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(session.project.resolutionText) · \(session.project.durationText) · \(Int(session.fps)) fps")
                    .font(.mSans(8.5).monospacedDigit())
                    .foregroundStyle(MColor.text4)
                    .lineLimit(1)
            }
            // 左右各留出按钮的实际宽度（返回 48 / 渲染胶囊 112），
            // 标题只在中间这段里居中并截断，长文件名不会压到按钮底下。
            .padding(.horizontal, 112)
            .allowsHitTesting(false)
        }
        .background(alignment: .top) {
            MTopScrim(height: 160)
        }
    }
}

// MARK: - 画布（原片 + 暂停显影帧）

private struct MVideoStage: View {
    @ObservedObject var session: MVideoSession

    /// 只有显影帧的时间点与当前时间一致时才盖上去，避免换帧瞬间串图。
    private var showsStill: Bool {
        guard !session.isPlaying, session.stillImage != nil else { return false }
        return abs(session.stillTime - session.currentTime) < 0.08
    }

    var body: some View {
        GeometryReader { geo in
            let width = CGFloat(max(1, session.project.pixelWidth))
            let height = CGFloat(max(1, session.project.pixelHeight))
            let box = CGSize(width: max(1, geo.size.width - 24),
                             height: max(1, geo.size.height - 84))
            let fit = Self.aspectFit(width / height, in: box)

            ZStack {
                MColor.app

                ZStack {
                    MVideoPlayerSurface(session: session)
                        .frame(width: fit.width, height: fit.height)
                        .clipped()

                    if showsStill, let image = session.stillImage {
                        MImage.swiftUI(image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: fit.width, height: fit.height)
                            .clipped()
                            .id(session.stillRevision)
                            .transition(.opacity)
                    }
                }
                .overlay(
                    Rectangle().strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                .position(x: geo.size.width / 2, y: geo.size.height / 2 + 10)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isPlaying ? MColor.brass : MColor.text3)
                    .frame(width: 5, height: 5)
                Text(statusText)
                    .font(.mSans(9, .medium).monospacedDigit())
                    .foregroundStyle(MColor.text3)
                    .lineLimit(1)

                Spacer(minLength: 8)

                MVideoPreviewScaleMenu(session: session)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var statusText: String {
        if session.isPlaying { return "播放原片" }
        if showsStill { return "已显影当前帧" }
        return session.isDevelopingStill ? "正在显影当前帧…" : "暂停后显影当前帧"
    }

    private static func aspectFit(_ aspect: CGFloat, in box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        if box.width / box.height > aspect {
            return CGSize(width: box.height * aspect, height: box.height)
        }
        return CGSize(width: box.width, height: box.width / aspect)
    }
}

/// 预览抽帧分辨率：完整 / 1/2 / 1/4（只影响预览，不影响成片）。
private struct MVideoPreviewScaleMenu: View {
    @ObservedObject var session: MVideoSession

    var body: some View {
        Menu {
            ForEach([1.0, 0.5, 0.25], id: \.self) { value in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.quick) { session.previewScale = value }
                } label: {
                    Text(title(value))
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title(session.previewScale))
                    .font(.mSans(9, .medium).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(MColor.text2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .mGlassSurface(Capsule(), fallbackFill: MColor.surface2.opacity(0.9))
            .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))
        }
        .accessibilityLabel("预览渲染比例")
    }

    private func title(_ value: Double) -> String {
        switch value {
        case ..<0.4: return "1/4"
        case ..<0.8: return "1/2"
        default: return "完整"
        }
    }
}

// MARK: - 播放器（AVPlayerLayer + 时间观察 + seek 同步）

private struct MVideoPlayerSurface: UIViewRepresentable {
    @ObservedObject var session: MVideoSession

    func makeUIView(context: Context) -> MVideoPlayerUIView {
        let view = MVideoPlayerUIView()
        view.session = session
        return view
    }

    func updateUIView(_ uiView: MVideoPlayerUIView, context: Context) {
        uiView.session = session
        uiView.syncSource()
        uiView.syncPlayback()
    }
}

private final class MVideoPlayerUIView: UIView {
    weak var session: MVideoSession?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentPath: String?
    private var lastSeekVersion = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        layer.masksToBounds = true
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    func syncSource() {
        guard let session else { return }
        let url = session.sourceURL
        guard currentPath != url.path else { return }
        currentPath = url.path

        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player?.pause()
        playerLayer?.removeFromSuperlayer()

        let newPlayer = AVPlayer(url: url)
        let layer = AVPlayerLayer(player: newPlayer)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer.addSublayer(layer)
        self.player = newPlayer
        self.playerLayer = layer

        // 时间观察：只更新 currentTime，播放中绝不触发显影。
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            guard let self, let session = self.session, session.isPlaying else { return }
            session.currentTime = time.seconds
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newPlayer.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, let session = self.session else { return }
            session.pausePlayback()
            session.seek(to: 0)
            self.player?.seek(to: .zero)
        }

        session.playerDidPause(at: 0)
    }

    func syncPlayback() {
        guard let session, let player else { return }

        if lastSeekVersion != session.seekVersion {
            lastSeekVersion = session.seekVersion
            let target = CMTime(seconds: max(0, session.seekTarget), preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if session.isPlaying {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
            session.playerDidPause(at: player.currentTime().seconds)
        }
    }
}

// MARK: - 参数面板（胶片 / 相纸 + 显影参数）

private struct MVideoDrawer: View {
    @ObservedObject var session: MVideoSession
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 把手换成向下箭头：点一下整块面板下沉收起，画布同时长高。
            MDrawerChevron(isExpanded: true, isVisible: true) {
                onCollapse()
            }
            .padding(.top, 1)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    railTitle("胶片")
                    MHScrollRail(itemCount: MobileCatalog.films.count,
                                 leading: MMetric.pageMargin,
                                 itemHeight: 52,
                                 fadeColor: .clear) {
                        ForEach(MobileCatalog.films) { film in
                            MFilmRailItem(film: film, selected: film.id == session.edit.filmStock) {
                                MHaptic.tick()
                                withAnimation(MMotion.state) { session.setFilm(film.id) }
                            }
                        }
                    }
                    .frame(height: 52)
                    .padding(.horizontal, -MMetric.pageMargin)

                    railTitle("相纸")
                        .padding(.top, 2)
                    MHScrollRail(itemCount: MobileCatalog.papers.count,
                                 leading: MMetric.pageMargin,
                                 itemHeight: 52,
                                 fadeColor: .clear) {
                        ForEach(MobileCatalog.papers) { paper in
                            MPaperRailItem(paper: paper, selected: paper.id == session.edit.printStock) {
                                MHaptic.tick()
                                withAnimation(MMotion.state) { session.setPaper(paper.id) }
                            }
                        }
                    }
                    .frame(height: 52)
                    .padding(.horizontal, -MMetric.pageMargin)

                    MHairline()
                        .padding(.vertical, 2)

                    HStack {
                        Text("显影参数").mLabel(7.5, color: MColor.text4)
                        Spacer(minLength: 8)
                        Button {
                            MHaptic.tick()
                            session.resetParameters()
                        } label: {
                            Text("重置")
                                .font(.mSans(9, .semibold))
                                .foregroundStyle(MColor.brass)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(session.videoAxes()) { axis in
                        MVideoAxisRow(axis: axis, session: session)
                    }

                    Text("参数只重显影当前帧；点右上角「渲染视频」才对全片逐帧显影。")
                        .font(.mSans(8.5))
                        .foregroundStyle(MColor.text4)
                        .padding(.top, 2)
                }
                .padding(.horizontal, MMetric.pageMargin)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(DebugLaunch.videoAxesBottom ? .bottom : .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mGlassSurface(drawerShape, fallbackFill: MColor.surface2.opacity(0.96))
        .overlay {
            drawerShape
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
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

    private func railTitle(_ title: String) -> some View {
        Text(title)
            .mLabel(7.5, color: MColor.text4)
            .padding(.leading, 1)
    }
}

private struct MVideoAxisRow: View {
    let axis: MVideoAxis
    @ObservedObject var session: MVideoSession
    @State private var value: Double = 0

    var body: some View {
        MParamSlider(
            label: axis.label,
            value: $value,
            base: axis.base,
            range: axis.range,
            step: axis.step,
            decimals: axis.decimals,
            suffix: axis.suffix,
            compact: true
        )
        .onAppear { value = axis.value }
        .onChange(of: axis.value) { _, new in value = new }
        .onChange(of: value) { _, new in
            guard abs(new - axis.value) > 1e-9 else { return }
            session.applyQuick(axis.id, value: new)
        }
    }
}

// MARK: - 底部播放控制器（替代页签胶囊）

private struct MVideoPlaybackBar: View {
    @ObservedObject var session: MVideoSession
    /// 面板收起后，胶囊右端出现向上箭头，点它把参数面板叫回来。
    let showsDrawerToggle: Bool
    let onExpandDrawer: () -> Void

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    /// 拖动起点比例与当时的轨道宽度。胶囊在拖动中会变宽，锁住这两个值，
    /// 手指位移才和进度线性对应，不会因为轨道左端左移而回跳。
    @State private var scrubBaseRatio: CGFloat = 0
    @State private var dragWidth: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            timeRow
            controlRow
        }
        .padding(.horizontal, scrubbing ? 18 : 13)
        .padding(.top, scrubbing ? 13 : 5)
        .padding(.bottom, scrubbing ? 17 : 5)
        .frame(maxWidth: .infinity)
        .background(backdrop)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.42), radius: 16, y: 6)
        // 展开时胶囊左右各外扩 6pt：变宽是形态变化的一部分，不只是变高。
        .padding(.horizontal, scrubbing ? 12 : 18)
        .animation(MMotion.drawer, value: scrubbing)
        .task {
            guard DebugLaunch.videoScrub else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            session.pausePlayback()
            scrubValue = session.duration * 0.42
            scrubBaseRatio = 0.42
            withAnimation(MMotion.drawer) { scrubbing = true }
        }
    }

    /// 时间码行：只在拖动时出现，收起时高度归零，不占位也不可点。
    private var timeRow: some View {
        HStack(spacing: 8) {
            Text(Self.timecode(scrubbing ? scrubValue : session.currentTime))
            Spacer(minLength: 0)
            Text(Self.clock(session.duration))
        }
        .font(.system(size: 16, weight: .semibold).monospacedDigit())
        .foregroundStyle(Self.ink)
        .frame(height: scrubbing ? 19 : 0)
        .padding(.bottom, scrubbing ? 12 : 0)
        .opacity(scrubbing ? 1 : 0)
        .clipped()
        .allowsHitTesting(false)
    }

    private var controlRow: some View {
        // 展开时按钮宽度归零，间距也要一起收掉，否则轨道两端内缩不对称。
        HStack(spacing: scrubbing ? 0 : 10) {
            Button {
                MHaptic.light()
                if session.isPlaying {
                    session.pausePlayback()
                } else {
                    session.togglePlay()
                }
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Self.ink)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isPlaying ? "暂停" : "播放")
            .frame(width: scrubbing ? 0 : 32)
            .opacity(scrubbing ? 0 : 1)
            .clipped()

            GeometryReader { geo in
                let width = max(1, geo.size.width)

                ZStack(alignment: .leading) {
                    Capsule().fill(Self.track)
                    // 用直角矩形填充、整体裁成胶囊：右端是平的分界线，
                    // 和参考图一致（不是圆头跟着走）。
                    Rectangle()
                        .fill(Self.fill)
                        .frame(width: width * progress)
                }
                .frame(height: scrubbing ? 9.5 : 7)
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: width))
            }

            if showsDrawerToggle {
                Button {
                    onExpandDrawer()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.ink)
                        .frame(width: 32, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开参数面板")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .frame(height: scrubbing ? 10 : 36)
    }

    private var backdrop: some View {
        ZStack {
            Capsule().fill(MColor.surface2.opacity(0.96))
            Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        }
    }

    private var progress: CGFloat {
        guard session.duration > 0 else { return 0 }
        let time = scrubbing ? scrubValue : session.currentTime
        return CGFloat(min(max(time / session.duration, 0), 1))
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !scrubbing {
                    // 变形发生在这轮回调之后：此刻宽度和坐标都还是拖动前的，
                    // 正好用它定起点，按下就跳到手指所在位置。
                    let base = min(max(value.startLocation.x / width, 0), 1)
                    scrubBaseRatio = base
                    dragWidth = width
                    scrubValue = Double(base) * session.duration
                    session.isScrubbing = true
                    session.pausePlayback()
                    session.seek(to: scrubValue)
                    MHaptic.light()
                    withAnimation(MMotion.drawer) { scrubbing = true }
                } else {
                    // 展开后轨道左端左移、变宽，绝对坐标不再可靠，用位移增量累加。
                    let ratio = scrubBaseRatio + value.translation.width / dragWidth
                    scrubValue = Double(min(max(ratio, 0), 1)) * session.duration
                    session.seek(to: scrubValue)
                }
            }
            .onEnded { _ in
                session.isScrubbing = false
                session.playerDidPause(at: scrubValue)
                withAnimation(MMotion.drawer) { scrubbing = false }
            }
    }

    /// 拖动态时间码：`MM:SS.cc`。百分秒跟着手指走，精确定位才有依据。
    private static func timecode(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "00:00.00" }
        let hundredths = Int((time * 100).rounded())
        return String(format: "%02d:%02d.%02d",
                      hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }

    /// 总时长：参考图是 `MM:SS`，不带百分秒。
    private static func clock(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "00:00" }
        let whole = Int(time.rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private static let ink = MColor.text1
    /// 轨道要压在 surface2 胶囊上还看得清，用比 hairline 略强的一档。
    private static let track = MColor.hairlineStrong
    private static let fill = MColor.brass
}

// MARK: - 渲染 / 导出面板

private struct MVideoExportOverlay: View {
    @ObservedObject var session: MVideoSession
    let onClose: () -> Void
    let onToast: (String) -> Void

    @State private var codec: VideoCodec
    @State private var isRendering = false
    @State private var finished = false

    init(session: MVideoSession, onClose: @escaping () -> Void, onToast: @escaping (String) -> Void) {
        self.session = session
        self.onClose = onClose
        self.onToast = onToast
        _codec = State(initialValue: DebugLaunch.videoCodec ?? session.project.exportSettings.codec)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isRendering else { return }
                    onClose()
                }

            panel
                .padding(.horizontal, 42)
                // 成功后点弹窗任意位置就关闭；编码态点空白处不动，
                // 避免选规格时误触。遮罩层仍负责点外部关闭。
                .onTapGesture {
                    guard finished else { return }
                    MHaptic.tick()
                    onClose()
                }
        }
        .transition(.opacity)
        .task {
            guard DebugLaunch.videoExportRun, !isRendering, !finished else { return }
            startRender()
        }
    }

    /// 极简弹窗：没有标题、没有文件名、没有内部卡片框。
    /// 编码态 → 进度态 → 完成态之间用非线性位移 + 缩放衔接，不做生硬替换。
    private var panel: some View {
        VStack(spacing: 0) {
            if isRendering || finished {
                progressBlock
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)),
                        removal: .opacity
                    ))
            } else {
                codecBlock
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 26)
        .frame(maxWidth: 360)
        // 必须是固定高度：内部用 maxHeight: .infinity 做居中定位，
        // 只给 minHeight 会让弹窗一路撑到全屏。
        .frame(height: 248)
        .background(
            RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                .fill(MColor.surface1.opacity(0.98))
        )
        .animation(MMotion.panelSlide, value: isRendering)
        .animation(MMotion.panelSlide, value: finished)
    }

    /// 只有「编码」和三个档位，选完直接点开始渲染；不放预估体积、不放说明。
    private var codecBlock: some View {
        VStack(spacing: 0) {
            Text("编码")
                .font(.mSans(9.5, .semibold))
                .tracking(0.4)
                .foregroundStyle(MColor.text4)
                .padding(.top, 2)

            Spacer(minLength: 10)

            VStack(spacing: 2) {
                ForEach(VideoCodec.allCases) { item in
                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.quick) { codec = item }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: codec == item ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(codec == item ? MColor.brass : MColor.text4)
                            Text(item.title)
                                .font(.mSans(11.5))
                                .foregroundStyle(codec == item ? MColor.text1 : MColor.text3)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 10)

            MBrassPill(title: "开始渲染", icon: "wand.and.stars", height: 38) {
                startRender()
            }
            .padding(.bottom, 2)
        }
    }

    /// 弹窗主体占满固定高度后按坐标排版：百分比 / 对勾严格居中，
    /// 只有渲染中才显示「取消」；成功后只剩对勾，点弹窗任意处关闭。
    private var progressBlock: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                MVideoExportBeat(target: exportTarget, finished: finished)
                    .frame(width: w, height: 54)
                    .position(x: w / 2, y: h / 2)

                if !finished {
                    Button {
                        MHaptic.tick()
                        session.cancelExport()
                    } label: {
                        Text("取消")
                            .font(.mSans(12.5, .medium))
                            .foregroundStyle(.white)
                            .frame(width: w, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .position(x: w / 2, y: h - 24)
                }
            }
        }
    }

    private func startRender() {
        isRendering = true
        session.setCodec(codec)

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spektrafilm/Videos/Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let raw = session.project.displayName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? "video" : raw
        let name = "\(base)-film-\(Self.stamp()).\(codec.fileExtension)"
        let destination = directory.appendingPathComponent(name)

        Task {
            let ok = await session.renderFull(destination: destination)
            // 取消是用户主动行为，退回编码态即可，不弹「失败」；
            // 用导出阶段判断，别去比对 status 文案。
            guard ok else {
                if session.exportProgress.stage == .cancelled {
                    NSLog("MVideoRender cancelled")
                } else {
                    NSLog("MVideoRender failed: %@", session.status)
                    onToast("渲染失败：\(session.status)")
                }
                isRendering = false
                return
            }
            // 成功路径保持 isRendering=true，进度态一直显示到 finished 置位，
            // 中间不留空档——否则 saveVideo 的异步回调前会闪回编码选项 UI。
            PhotoLibraryExport.saveVideo(destination, album: PhotoLibraryExport.albumTitle) { outcome in
                // 渲染成功就置完成态（对勾 + 点屏幕关闭）；相册写入是否成功
                // 只由 toast 说明，不能让「写相册失败」把成功态打回进度态。
                finished = true
                switch outcome {
                case .saved:
                    onToast("已渲染并保存到相册")
                case .denied:
                    onToast("成片已存到 App 文件，相册权限未开启")
                case .failed:
                    onToast("成片已存到 App 文件，写入相册失败")
                }
            }
        }
    }

    /// 成片帧数只覆盖渲染段；烘焙和写入各自占一小段，
    /// 否则烘焙时进度停在 0% 会像卡死。
    private var exportTarget: Double {
        guard !finished else { return 1 }
        let p = session.exportProgress
        switch p.stage {
        case .probing: return 0.03
        case .baking: return 0.06
        case .rendering: return 0.06 + 0.86 * min(max(p.fraction, 0), 1)
        case .writing, .exporting: return 0.94
        default: return min(max(p.fraction, 0), 1)
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 渲染进度（跳动百分比 → 对勾）

/// 复刻相机直出显影的进度反馈：真实进度是分段跳的，这里在跳点之间补伪过渡，
/// 每滚过 1% 给一次最轻的选择触感；完成瞬间换成对勾并 bounce。
private struct MVideoExportBeat: View {
    let target: Double
    let finished: Bool

    @State private var eased: Double = 0
    /// 目标值只更新、不重启循环：以前每次进度回调都取消重建任务，
    /// 触感还没发出去就被下一次取消失效，全部堆到导出完成那一下。
    @State private var goal: Double = 0
    @State private var hapticPercent = 0
    @State private var ticker: Task<Void, Never>?
    /// 完成后不立刻切对勾：先让百分比平滑补到 100%，再由 ticker 置位切换，
    /// 避免「百分比还没走完就硬切对勾」的断裂感。
    @State private var showCheck = false

    private var percent: Int {
        Int((min(max(eased, 0), 1) * 100).rounded(.down))
    }

    var body: some View {
        Group {
            if showCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, options: .speed(1.05))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Text("\(percent)%")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MColor.text1)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.smooth(duration: 0.26), value: percent)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        // 百分比 ↔ 对勾的切换动画；两者都在同一坐标系，无位移跳变。
        .animation(MMotion.state, value: showCheck)
        .onAppear {
            goal = min(max(target, 0), 1)
            startTicker()
        }
        .onChange(of: target) { _, new in
            guard !finished else { return }
            goal = min(max(new, 0), 1)
        }
        .onChange(of: finished) { _, done in
            guard done else { return }
            // 只把目标推到 1，交给常驻 ticker 平滑补满；不直接 eased=1。
            goal = 1
        }
        .onDisappear {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// 常驻 60ms ticker：缓动追 `goal`，每跨过 1% 给一次最轻的选择触感。
    /// 数字和触感读同一个 `eased`，所以手感永远跟百分比同步，不会攒到结束。
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Task.isCancelled { break }
                let remaining = goal - eased
                if remaining <= 0.001 {
                    eased = goal
                    // goal 只会被完成回调推到 1（普通进度最高 0.94），
                    // 用它当完成信号——不能直接读 finished：ticker 在旧 View 实例
                    // 里启动，闭包捕获的是旧值 false，对勾会永远不切。
                    if goal >= 0.999 {
                        withAnimation(MMotion.state) { showCheck = true }
                        ticker?.cancel()
                        ticker = nil
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                        break
                    }
                    continue
                }
                // 每步约 1.5 个百分点，带 ±30% 随机微抖，越接近越慢。
                // 完成补满阶段（goal=1）用大步长，约 0.5s 走到 100%，不让对勾等太久。
                let finishing = goal >= 0.999
                let raw = finishing
                    ? max(0.05, remaining * 0.35)
                    : max(0.0025, remaining * 0.10) * Double.random(in: 0.7...1.3)
                eased = min(goal, eased + min(raw, finishing ? 0.12 : 0.02))
                let value = Int((eased * 100).rounded(.down))
                if value > hapticPercent {
                    hapticPercent = value
                    #if os(iOS)
                    Self.haptic.prepare()
                    Self.haptic.selectionChanged()
                    #endif
                }
            }
        }
    }

    #if os(iOS)
    private static let haptic = UISelectionFeedbackGenerator()
    #endif
}
