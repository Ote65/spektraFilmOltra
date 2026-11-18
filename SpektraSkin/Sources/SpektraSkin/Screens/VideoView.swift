import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CoreMedia

// MARK: - 视频显影台
//
// 与照片共用同一个库和同一个显影台入口，只有中间画布不同：
// **播放时显示原片，暂停时把当前帧抽出来走一次显影，把显影帧叠在播放器上。**
// 预览分辨率可选 完整 / 1/2 / 1/4，只影响预览抽帧，不影响成片。

struct VideoEditorView: View {
    @ObservedObject var host: VideoHost
    let actions: SkinActions
    var onBack: () -> Void = {}

    @State private var exportOpen = false

    var body: some View {
        VStack(spacing: 0) {
            editorTopBar

            HStack(spacing: 0) {
                PresetRail(
                    presets: PreviewData.presets,
                    currentFilmID: host.edit.filmStock,
                    currentPaperID: host.edit.printStock,
                    actions: actions
                )
                .frame(width: SkinMetric.sideRailWidth)

                SkinVerticalHairline()

                VStack(spacing: 0) {
                    VideoStage(host: host)
                    VideoTimeline(host: host)
                        .frame(height: 116)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                SkinVerticalHairline()

                VideoInspector(host: host)
                    .frame(width: SkinMetric.inspectorWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkinColor.app)
        .sheet(isPresented: $exportOpen) {
            VideoRenderPanel(host: host, onCancel: { exportOpen = false })
        }
    }

    private var editorTopBar: some View {
        HStack(spacing: 12) {
            SkinButton("媒体库", icon: "chevron.left", kind: .secondary, height: 28) {
                host.pausePlayback()
                onBack()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(host.current?.displayName ?? "未选择视频")
                    .font(.skin(13.5, .medium)).foregroundStyle(SkinColor.text1)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(host.current?.resolutionText ?? "—") · \(host.current?.durationText ?? "—") · \(host.currentFilmName()) · \(host.currentPaperName())")
                    .font(.skin(10.5).monospacedDigit()).foregroundStyle(SkinColor.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if host.isDevelopingStill || host.isBusy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(host.isBusy ? "渲染中" : "显影中")
                        .font(.skin(10)).foregroundStyle(SkinColor.text3)
                }
            }

            SkinButton("开始渲染", icon: "wand.and.stars", kind: .primary, height: 30) {
                host.pausePlayback()
                exportOpen = true
            }
        }
        .padding(.horizontal, 16)
        .frame(height: SkinMetric.topBarHeight)
        .background(SkinColor.app)
        .overlay(alignment: .bottom) { SkinHairline() }
    }
}

// MARK: - 中间放大画布（原片 + 暂停显影帧）

private struct VideoStage: View {
    @ObservedObject var host: VideoHost

    /// 只有显影帧的时间点与当前时间一致时才盖上去，避免换帧瞬间串图。
    private var showsStill: Bool { host.showsDevelopedStill }

    var body: some View {
        ZStack {
            SkinColor.canvas
            RadialGradient(colors: [Color(hex: 0x2B251D).opacity(0.5), .clear],
                           center: UnitPoint(x: 0.5, y: 0.44), startRadius: 8, endRadius: 480)

            GeometryReader { geo in
                if let project = host.current {
                    let aspect = CGFloat(project.pixelWidth) / CGFloat(max(project.pixelHeight, 1))
                    let fit = SkinPrintFit.fit(geo.size, aspect: aspect)
                    let matte: CGFloat = 20

                    ZStack {
                        // 相纸白边（与照片台一致）
                        Rectangle()
                            .fill(Color(hex: 0xF1EDE3))
                            .frame(width: fit.width + matte * 2, height: fit.height + matte * 2)
                            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 22, y: 16)

                        ZStack {
                            // 1) 播放器：只在播放时露出来。
                            VideoPlayerSurface(host: host)
                                .frame(width: fit.width, height: fit.height)

                            // 2) 冻帧：暂停瞬间用播放器自己那一帧的像素铺满，瞬时替换（无动画）。
                            //    它和下面的显影帧是同一块像素，渐显时不存在第二张画面。
                            if let base = host.stillBase {
                                Image(nsImage: base)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: fit.width, height: fit.height)
                                    .opacity(host.showsStillBase ? 1 : 0)
                                    .allowsHitTesting(false)
                            }

                            // 3) 显影帧：只在冻帧上面做不透明度渐显，画面内容从头到尾是同一帧。
                            if let image = host.stillImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: fit.width, height: fit.height)
                                    .opacity(showsStill ? 1 : 0)
                                    .animation(.easeInOut(duration: VideoHost.stillFadeDuration), value: showsStill)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: fit.width, height: fit.height)
                        .clipped()
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(host.isPlaying ? SkinColor.yellow : SkinColor.green)
                        .frame(width: 5, height: 5)
                    Text(host.isPlaying
                         ? "播放原片"
                         : (host.isReturningToOriginal
                            ? "切回原片 · 淡出后起播"
                            : (showsStill ? "已显影当前帧 · \(host.stillPixelSize)" : "正在显影当前帧…")))
                        .font(.skin(9.5).monospacedDigit()).foregroundStyle(SkinColor.text3)
                }

                Spacer(minLength: 0)

                PreviewScalePicker(scale: $host.previewScale)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

/// 预览渲染分辨率：完整 / 1/2 / 1/4。
private struct PreviewScalePicker: View {
    @Binding var scale: Double

    private let options: [(label: String, value: Double)] = [
        ("完整", 1.0), ("1/2", 0.5), ("1/4", 0.25),
    ]

    var body: some View {
        HStack(spacing: 6) {
            Text("预览").font(.skin(9)).foregroundStyle(SkinColor.text4)

            HStack(spacing: 2) {
                ForEach(options, id: \.value) { item in
                    let active = abs(scale - item.value) < 0.001
                    Button { scale = item.value } label: {
                        Text(item.label)
                            .font(.skin(9.5, active ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(active ? SkinColor.text1 : SkinColor.text4)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(active ? SkinColor.surface3 : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("预览抽帧分辨率：\(item.label)（成片始终按原分辨率渲染）")
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.42))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// MARK: - 播放器（AVPlayerLayer + 时间观察 + seek 同步）

private struct VideoPlayerSurface: NSViewRepresentable {
    @ObservedObject var host: VideoHost

    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.host = host
        return v
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.host = host
        nsView.syncSource()
        nsView.syncPlayback()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}

    final class PlayerHostView: NSView {
        weak var host: VideoHost?
        var player: AVPlayer?
        var playerLayer: AVPlayerLayer?
        var videoOutput: AVPlayerItemVideoOutput?
        var timeObserver: Any?
        var currentURL: String?
        var endObserver: NSObjectProtocol?
        var lastSeekVersion = -1

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

        deinit {
            if let timeObserver { player?.removeTimeObserver(timeObserver) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            player?.pause()
        }

        func syncSource() {
            guard let host, let project = host.current else { return }
            let url = project.sourceURL
            if currentURL != url.path {
                currentURL = url.path
                if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
                player?.pause()
                let item = AVPlayerItem(url: url)
                // 挂一路视频输出：暂停时把"正在显示的那一帧"原样取出来冻屏，
                // 显影只在这块像素上做，渐显不可能混入相邻帧。
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ])
                item.add(output)
                videoOutput = output
                let player = AVPlayer(playerItem: item)
                self.player = player
                playerLayer?.removeFromSuperlayer()
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resizeAspectFill
                layer.frame = bounds
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                self.layer?.addSublayer(layer)
                playerLayer = layer

                // 时间观察：只更新 host.currentTime，播放中绝不触发显影。
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
                        guard let self, let host = self.host else { return }
                        if host.isPlaying { host.currentTime = time.seconds }
                    }
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                        guard let self, let host = self.host else { return }
                        host.pausePlayback()
                        host.seek(to: 0)
                        self.player?.seek(to: .zero)
                    }
                DispatchQueue.main.async { host.playerDidPause(at: 0) }
            }
        }

        func syncPlayback() {
            guard let host, let player else { return }

            if lastSeekVersion != host.seekVersion {
                lastSeekVersion = host.seekVersion
                let t = CMTime(seconds: max(0, host.seekTarget), preferredTimescale: 600)
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            if host.isPlaying {
                if player.rate == 0 { player.play() }
            } else if player.rate != 0 {
                player.pause()
                // 先把播放器停在"当前这一帧"，顺手把这一帧的像素取出来；冻屏和显影都用它。
                let t = player.currentTime()
                var captured: CVPixelBuffer?
                var stamp = t.seconds
                if let output = videoOutput, output.hasNewPixelBuffer(forItemTime: t) {
                    var display = CMTime.invalid
                    if let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) {
                        captured = buffer
                        if display.isValid, display.seconds.isFinite { stamp = display.seconds }
                    }
                }
                // 别在视图更新里改 @Published：推到下一轮 runloop。
                DispatchQueue.main.async {
                    host.playerDidPause(at: stamp, frameBuffer: captured)
                }
            }
        }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}

// MARK: - 底部时间线

private struct VideoTimeline: View {
    @ObservedObject var host: VideoHost

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if host.isPlaying {
                        host.pausePlayback()
                    } else {
                        host.togglePlay()
                    }
                } label: {
                    Image(systemName: host.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12)).foregroundStyle(SkinColor.text1)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(SkinColor.surface3))
                }
                .buttonStyle(.plain)

                let duration = host.current?.duration ?? 1
                let progress = duration > 0 ? min(1, max(0, host.currentTime / duration)) : 0

                Text(formatTime(host.currentTime))
                    .font(.skin(10).monospacedDigit()).foregroundStyle(SkinColor.text3)
                    .frame(width: 42)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(SkinColor.surface2).frame(height: 30)
                        HStack(spacing: 2) {
                            ForEach(0..<20) { i in
                                Rectangle().fill(Color.white.opacity(0.06 + 0.02 * Double(i % 3)))
                                    .frame(width: max(2, (geo.size.width - 8) / 20), height: 26)
                            }
                        }
                        .padding(.horizontal, 4)
                        Rectangle().fill(SkinColor.accent.opacity(0.25)).frame(width: geo.size.width * progress, height: 30)
                        Rectangle().fill(SkinColor.accent).frame(width: 2, height: 34)
                            .offset(x: geo.size.width * progress)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            host.isScrubbing = true
                            if host.isPlaying { host.pausePlayback() }
                            let ratio = min(1, max(0, g.location.x / geo.size.width))
                            host.seek(to: ratio * duration)
                        }
                        .onEnded { _ in
                            host.isScrubbing = false
                            host.playerDidPause(at: host.currentTime)
                        })
                }
                .frame(height: 30)

                Text(formatTime(duration))
                    .font(.skin(10).monospacedDigit()).foregroundStyle(SkinColor.text3)
                    .frame(width: 42)
            }
            HStack {
                Text("播放看原片 · 暂停显影当前帧 · 参数只重显影这一帧")
                    .font(.skin(9.5)).foregroundStyle(SkinColor.text4)
                Spacer()
                Text("\(Int(host.current?.fps ?? 24)) fps · 颗粒逐帧独立")
                    .font(.skin(9.5).monospacedDigit()).foregroundStyle(SkinColor.text4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(SkinColor.surface1)
        .overlay(alignment: .top) { SkinHairline() }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - 右侧视频参数 Inspector

private struct VideoInspector: View {
    @ObservedObject var host: VideoHost

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("显影参数").font(.sectionTitle).foregroundStyle(SkinColor.text1)
                Spacer()
                SkinButton("重置", kind: .secondary, height: 26) { host.resetParameters() }
            }
            .padding(.horizontal, 14).frame(height: 48)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(host.videoAxisGroups()) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title).font(.groupLabel).foregroundStyle(SkinColor.text3)
                            ForEach(group.axes) { axis in
                                VideoAxisRow(axis: axis, host: host)
                            }
                        }
                        .padding(12)
                        .background(cardBg)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("渲染设置").font(.groupLabel).foregroundStyle(SkinColor.text3)
                        ForEach(VideoCodec.allCases) { codec in
                            Button { host.setCodec(codec) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: host.current?.exportSettings.codec == codec
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(host.current?.exportSettings.codec == codec
                                                         ? SkinColor.accent : SkinColor.text4)
                                    Text(codec.title).font(.skin(10.5)).foregroundStyle(SkinColor.text2)
                                    Spacer()
                                }
                                .frame(height: 24)
                            }
                            .buttonStyle(.plain)
                        }
                        if let p = host.current {
                            Text("预估 \(String(format: "%.0f", p.exportSettings.estimatedSizeMB(duration: p.duration))) MB · 颗粒需足够码率保留")
                                .font(.skin(9.5)).foregroundStyle(SkinColor.text4)
                        }
                    }
                    .padding(12)
                    .background(cardBg)
                }
                .padding(.horizontal, 14).padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(SkinColor.app)
    }

    private var cardBg: some View {
        RoundedRectangle(cornerRadius: SkinRadius.panel, style: .continuous)
            .fill(SkinColor.surface1)
            .overlay(RoundedRectangle(cornerRadius: SkinRadius.panel, style: .continuous)
                .strokeBorder(SkinColor.hairline, lineWidth: 1))
    }
}

private struct VideoAxisRow: View {
    let axis: VideoHost.VideoAxis
    @ObservedObject var host: VideoHost
    @State private var value: Double = 0

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(axis.label).font(.skin(11.5)).foregroundStyle(SkinColor.text2)
                Spacer()
                Text(axis.text()).font(.readout)
                    .foregroundStyle(axis.isDirty ? SkinColor.accent : SkinColor.text3)
            }
            SkinSlider(value: $value, range: axis.range, step: axis.step, dirty: axis.isDirty)
        }
        .onAppear { value = axis.value }
        .onChange(of: axis.value) { _, new in value = new }
        .onChange(of: value) { _, new in host.applyQuick(axis.id, value: new) }
        .help(axis.hint)
    }
}

// MARK: - 渲染面板

private struct VideoRenderPanel: View {
    @ObservedObject var host: VideoHost
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("渲染成片").font(.sectionTitle).foregroundStyle(SkinColor.text1)
            if let p = host.current {
                Text("\(p.displayName) · \(p.resolutionText) · \(p.durationText)")
                    .font(.skin(11)).foregroundStyle(SkinColor.text3)
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("单帧显影已确认参数；开始渲染将对全片 \(p.durationText) 逐帧显影并编码。")
                        .font(.skin(10.5))
                }
                .foregroundStyle(SkinColor.text4)

                let progress = host.exportProgress
                if progress.stage != .idle {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(progress.label).font(.skin(10.5)).foregroundStyle(SkinColor.text2)
                            Spacer()
                            Text("\(progress.frameIndex)/\(progress.frameCount)")
                                .font(.meta).foregroundStyle(SkinColor.text3)
                        }
                        ProgressView(value: progress.fraction)
                    }
                }

                HStack {
                    if host.exporter.canCancel {
                        SkinButton("取消渲染", kind: .secondary) { host.cancelExport() }
                    }
                    Spacer()
                    SkinButton("返回", kind: .quiet) { onCancel() }
                    SkinButton("选择位置并渲染", kind: .primary) {
                        onCancel()
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.movie]
                        panel.nameFieldStringValue =
                            "\(p.displayName)-film-\(Self.stamp()).\(p.exportSettings.codec.fileExtension)"
                        if panel.runModal() == .OK, let url = panel.url {
                            Task { await host.renderFull(destination: url) }
                        }
                    }
                    .disabled(host.isBusy)
                }
            }
        }
        .padding(20).frame(width: 440).background(SkinColor.surface1)
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
