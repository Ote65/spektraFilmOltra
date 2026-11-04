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

                    SkinPreviewToolbar(
                        zoom: $zoom,
                        rotation: $rotation,
                        pan: $pan,
                        compare: $compare,
                        previewScale: previewScale,
                        onScaleChanged: { actions.renderScaleChanged($0) },
                        onReRender: { actions.reRender() }
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

// MARK: - Progress

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
