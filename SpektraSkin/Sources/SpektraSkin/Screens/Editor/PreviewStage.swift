import SwiftUI

// MARK: - Canvas

struct PreviewStage: View {
    let photo: PhotoItem
    let filmName: String
    let paperName: String
    var previewImage: NSImage? = nil
    var originalImage: NSImage? = nil
    var previewScale: Double = 0.25
    var renderPhase: RenderPhase = .idle
    var previewRevision: Int = 0
    let actions: SkinActions

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var rotation: Double = 0
    @State private var compare = false
    @State private var compareSplit: CGFloat = 50
    @State private var displayedImage: NSImage?
    @State private var outgoingImage: NSImage?
    @State private var previewFade: Double = 1
    @State private var fadeGeneration = 0

    var body: some View {
        ZStack {
            SkinColor.canvas

            RadialGradient(
                colors: [Color(hex: 0x2B251D).opacity(0.55), .clear],
                center: UnitPoint(x: 0.5, y: 0.44),
                startRadius: 8,
                endRadius: 460
            )

            LinearGradient(
                colors: [Color.white.opacity(0.018), .clear],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.3)
            )

            GeometryReader { geo in
                let fit = SkinPrintFit.fit(geo.size, aspect: photo.aspectRatio)
                let matte: CGFloat = 22

                ZStack {
                    Rectangle()
                        .fill(Color(hex: 0xF1EDE3))
                        .frame(width: fit.width + matte * 2, height: fit.height + matte * 2)
                        .overlay(
                            Rectangle()
                                .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.48), radius: 22, y: 16)

                    ZStack {
                        if let outgoingImage {
                            Image(nsImage: outgoingImage)
                                .resizable()
                                .scaledToFill()
                                .opacity(1 - previewFade)
                        }
                        if let displayedImage {
                            Image(nsImage: displayedImage)
                                .resizable()
                                .scaledToFill()
                                .opacity(previewFade)
                        }
                        if displayedImage == nil && outgoingImage == nil {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("等待显影")
                                    .font(.skin(10.5))
                                    .foregroundStyle(SkinColor.text4)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(SkinColor.surface2)
                        }

                        if compare, let original = originalImage {
                            Image(nsImage: original)
                                .resizable()
                                .scaledToFill()
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: fit.width * compareSplit / 100)
                                }
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .overlay {
                        if compare, originalImage != nil {
                            compareHandle
                        }
                    }
                    .scaleEffect(zoom)
                    .rotationEffect(.degrees(rotation))
                    .offset(pan)
                    .clipped()
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            CanvasInteractionLayer(
                onZoom: { factor in
                    zoom = min(max(zoom * factor, 0.25), 8)
                },
                onPan: { delta in
                    pan = CGSize(width: pan.width + delta.width,
                                 height: pan.height + delta.height)
                },
                onReset: {
                    withAnimation(SkinMotion.state) {
                        zoom = 1
                        pan = .zero
                        rotation = 0
                    }
                }
            )

            VStack(spacing: 0) {
                HStack {
                    Text(compare ? "原图 ↔ 显影" : "照片")
                        .font(.skin(10.5))
                        .foregroundStyle(SkinColor.text2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(SkinColor.surface1.opacity(0.92))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
                        )

                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                if renderPhase.isBusy {
                    HStack {
                        Spacer(minLength: 0)
                        RenderProgressView(phase: renderPhase)
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 10)
                }

                HStack(alignment: .bottom, spacing: 16) {
                    Text("\(photo.filename) · \(photo.dimensions) · \(filmName) · \(paperName)")
                        .font(.skin(10.5).monospacedDigit())
                        .foregroundStyle(SkinColor.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    PreviewToolbar(
                        compare: $compare,
                        zoom: $zoom,
                        rotation: $rotation,
                        pan: $pan,
                        previewScale: previewScale,
                        actions: actions
                    )
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if displayedImage == nil { displayedImage = previewImage }
        }
        .onChange(of: previewRevision) { _, _ in
            let previous = displayedImage
            displayedImage = previewImage
            outgoingImage = previous
            previewFade = 0
            fadeGeneration += 1
            let generation = fadeGeneration
            withAnimation(.easeOut(duration: 0.18)) { previewFade = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if fadeGeneration == generation { outgoingImage = nil }
            }
        }
    }

    /// 原图/显影分割线：拖动改变裁剪比例。
    private var compareHandle: some View {
        GeometryReader { geo in
            let centerX = geo.size.width * compareSplit / 100
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.72))
                    .frame(width: 1)
                    .position(x: centerX, y: geo.size.height / 2)

                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 13, height: 13)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                    )
                    .position(x: centerX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let width = max(geo.size.width, 1)
                        compareSplit = min(max(value.location.x / width * 100, 2), 98)
                    }
            )
        }
    }
}

// MARK: - Zoom / pan / scroll

private struct CanvasInteractionLayer: NSViewRepresentable {
    var onZoom: (CGFloat) -> Void
    var onPan: (CGSize) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> CanvasEventView {
        let view = CanvasEventView()
        view.onZoom = onZoom
        view.onPan = onPan
        view.onReset = onReset
        return view
    }

    func updateNSView(_ view: CanvasEventView, context: Context) {
        view.onZoom = onZoom
        view.onPan = onPan
        view.onReset = onReset
    }
}

private final class CanvasEventView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onReset: (() -> Void)?
    private var lastPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 6
        guard abs(delta) > 0 else { return }
        onZoom?(CGFloat(exp(Double(delta) / 260.0)))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        lastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lastPoint else {
            self.lastPoint = point
            return
        }
        onPan?(CGSize(width: point.x - lastPoint.x, height: lastPoint.y - point.y))
        self.lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}


private struct PreviewToolbar: View {
    @Binding var compare: Bool
    @Binding var zoom: CGFloat
    @Binding var rotation: Double
    @Binding var pan: CGSize
    let previewScale: Double
    let actions: SkinActions

    private var renderScaleLabel: String {
        switch previewScale {
        case ..<0.2: return "1/8"
        case ..<0.4: return "1/4"
        case ..<0.8: return "1/2"
        default: return "1/1"
        }
    }

    private var zoomLabel: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach([0.125, 0.25, 0.5, 1.0], id: \.self) { value in
                    Button(scaleTitle(value)) {
                        actions.renderScaleChanged(value)
                    }
                }
            } label: {
                ToolbarLabel(title: renderScaleLabel, chevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            divider

            ToolbarTextButton(
                title: "对比",
                icon: "rectangle.split.2x1",
                active: compare
            ) {
                withAnimation(SkinMotion.state) { compare.toggle() }
            }
            ToolbarTextButton(title: "渲染") {
                actions.reRender()
            }

            SkinVerticalHairline(color: SkinColor.hairlineStrong, height: 14)
                .padding(.horizontal, 3)

            SkinIconButton("rotate.left", size: 12, frame: 26) {
                withAnimation(SkinMotion.state) { rotation -= 90 }
            }
            SkinIconButton("rotate.right", size: 12, frame: 26) {
                withAnimation(SkinMotion.state) { rotation += 90 }
            }
            SkinIconButton("arrow.up.left.and.arrow.down.right", size: 12, frame: 26) {
                withAnimation(SkinMotion.state) {
                    zoom = 1
                    pan = .zero
                }
            }

            Menu {
                Button("适应窗口") {
                    withAnimation(SkinMotion.state) {
                        zoom = 1
                        pan = .zero
                    }
                }
                ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { value in
                    Button("\(Int(value * 100))%") {
                        withAnimation(SkinMotion.state) {
                            zoom = CGFloat(value)
                            pan = .zero
                        }
                    }
                }
            } label: {
                ToolbarLabel(title: zoomLabel, chevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SkinColor.surface1.opacity(0.94))
                .shadow(color: .black.opacity(0.36), radius: 16, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
        )
    }

    private func scaleTitle(_ value: Double) -> String {
        switch value {
        case 0.125: return "渲染 1/8"
        case 0.25: return "渲染 1/4"
        case 0.5: return "渲染 1/2"
        default: return "渲染 1/1"
        }
    }

    private var divider: some View {
        SkinVerticalHairline(color: SkinColor.hairlineStrong, height: 14)
            .padding(.horizontal, 3)
    }
}

private struct RenderProgressView: View {
    let phase: RenderPhase

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(phase.label)
                    .font(.skin(10.5, .medium))
                    .foregroundStyle(SkinColor.text2)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(phase.index == 0 ? "…" : "\(phase.index)/\(max(phase.total, 1))")
                    .font(.skin(10).monospacedDigit())
                    .foregroundStyle(SkinColor.text3)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SkinColor.hairlineStrong)
                        .frame(height: 3)
                    Capsule()
                        .fill(SkinColor.accent)
                        .frame(
                            width: geo.size.width * progressFraction,
                            height: 3
                        )
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 232)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SkinColor.surface1.opacity(0.94))
                .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
        )
    }

    private var progressFraction: CGFloat {
        guard phase.index > 0, phase.total > 0 else { return 0.38 }
        return CGFloat(min(1, Double(phase.index) / Double(phase.total)))
    }
}

private struct ToolbarLabel: View {
    let title: String
    var chevron: Bool = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.skin(10.5, .medium))
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .medium))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(hovered ? SkinColor.text1 : SkinColor.text2)
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? SkinColor.wash : .clear)
        )
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}


private struct ToolbarTextButton: View {
    let title: String
    var icon: String?
    var chevron: Bool = false
    var active: Bool = false
    var action: () -> Void = {}

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title)
                    .font(.skin(10.5, .medium))
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .medium))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(active ? SkinColor.accent : (hovered ? SkinColor.text1 : SkinColor.text2))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? SkinColor.accent.opacity(0.10) : (hovered ? SkinColor.wash : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    let items: [PhotoItem]
    let currentID: String
    let actions: SkinActions

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    FilmThumbnail(
                        photo: item,
                        selected: item.id == currentID
                    ) {
                        actions.selectStripPhoto(item.id)
                    }
                }

                AddThumbnail {
                    actions.importPhotos()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .scrollIndicators(.hidden)
        .frame(height: SkinMetric.filmstripHeight)
        .background(SkinColor.app)
        .overlay(alignment: .top) {
            SkinHairline()
        }
    }
}

private struct FilmThumbnail: View {
    let photo: PhotoItem
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image = photo.thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(SkinColor.surface2)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(SkinColor.text4)
                        )
                }
            }
            .frame(width: 84, height: 63)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        selected ? SkinColor.accent.opacity(0.95) : (hovered ? SkinColor.hairlineStrong : SkinColor.hairline),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .frame(width: 92, height: 69)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? SkinColor.surface2 : (hovered ? SkinColor.surface1 : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? SkinColor.accent.opacity(0.7) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
        .help(photo.filename)
    }
}

private struct AddThumbnail: View {
    var action: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(hovered ? SkinColor.accent : SkinColor.text3)
                .frame(width: 92, height: 69)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovered ? SkinColor.accent.opacity(0.07) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            hovered ? SkinColor.accent.opacity(0.5) : SkinColor.hairlineStrong,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
        .help("导入照片")
    }
}
