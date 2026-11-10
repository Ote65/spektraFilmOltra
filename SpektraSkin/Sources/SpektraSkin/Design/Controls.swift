import SwiftUI

struct SkinPrintFit {
    let width: CGFloat
    let height: CGFloat

    static func fit(
        _ size: CGSize,
        horizontalInset: CGFloat = 150,
        verticalInset: CGFloat = 120,
        aspect: CGFloat = 4.0 / 3.0
    ) -> SkinPrintFit {
        let maxWidth = max(size.width - horizontalInset, 1)
        let maxHeight = max(size.height - verticalInset, 1)
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return SkinPrintFit(width: width, height: height)
    }
}

// MARK: - Slider

struct SkinSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var dirty: Bool = false
    var isEnabled: Bool = true

    @State private var hovered = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - 12, 1)
            let ratio = normalized(value)
            let knobX = 6 + usable * ratio

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SkinColor.surface4)
                    .frame(width: usable, height: 3)
                    .offset(x: 6)

                Capsule()
                    .fill(dirty ? SkinColor.accent : Color.white.opacity(0.22))
                    .frame(width: max(usable * ratio, 0), height: 3)
                    .offset(x: 6)

                Circle()
                    .fill(Color(hex: 0xEDE9E0))
                    .frame(width: hovered || dragging ? 13 : 11, height: hovered || dragging ? 13 : 11)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 2, y: 1)
                    .offset(x: knobX - (hovered || dragging ? 6.5 : 5.5))
                    .animation(.easeOut(duration: 0.12), value: hovered)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        dragging = true
                        let ratio = min(1, max(0, (gesture.location.x - 6) / usable))
                        let raw = range.lowerBound + Double(ratio) * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { hovered = $0 }
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.38)
        .animation(SkinMotion.hover, value: hovered)
    }

    private func normalized(_ value: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }
}

// MARK: - Histogram

struct SkinHistogram: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            for fraction in [0.25, 0.5, 0.75] {
                let y = size.height * fraction
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Color.white.opacity(0.045)), lineWidth: 1)
            }

            let maxValue = max(0.01, (data.red + data.green + data.blue).max() ?? 1)

            draw(data.red, color: SkinColor.red.opacity(0.58), maxValue: maxValue, context: context, size: size)
            draw(data.green, color: SkinColor.green.opacity(0.55), maxValue: maxValue, context: context, size: size)
            draw(data.blue, color: SkinColor.blue.opacity(0.55), maxValue: maxValue, context: context, size: size)
        }
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
        )
    }

    private func draw(
        _ values: [Double],
        color: Color,
        maxValue: Double,
        context: GraphicsContext,
        size: CGSize
    ) {
        guard values.count > 1 else { return }
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height - 2 - CGFloat(value / maxValue) * (size.height - 4) * 0.92
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1)
    }
}

// MARK: - Print colour pad

struct SkinColorPad: View {
    @Binding var x: Double
    @Binding var y: Double

    var width: CGFloat = 168
    var height: CGFloat = 112

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SkinColor.surface2)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(SkinColor.hairline, lineWidth: 1)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: height - 36)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: width - 56, height: 1)

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 4, height: 4)

            padHandle
                .offset(handleOffset)

            Text("品红")
                .font(.skin(9))
                .foregroundStyle(SkinColor.text4)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)

            Text("绿")
                .font(.skin(9))
                .foregroundStyle(SkinColor.text4)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 4)

            Text("暖")
                .font(.skin(9))
                .foregroundStyle(SkinColor.text4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)

            Text("冷")
                .font(.skin(9))
                .foregroundStyle(SkinColor.text4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 7)
        }
        .frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    x = min(100, max(-100, Double(gesture.location.x / width) * 200 - 100))
                    y = min(100, max(-100, Double(100 - gesture.location.y / height * 200)))
                }
        )
        .help("拖动调整印相色彩；双击回到中心。方向以灰卡标定为准。")
        .onTapGesture(count: 2) {
            withAnimation(SkinMotion.state) {
                x = 0
                y = 0
            }
        }
    }

    private var padHandle: some View {
        ZStack {
            Circle()
                .strokeBorder(SkinColor.accent.opacity(0.72), lineWidth: 1)
                .frame(width: 14, height: 14)
                .background(Circle().fill(SkinColor.accent.opacity(0.08)))
            Circle()
                .fill(SkinColor.accent)
                .frame(width: 5, height: 5)
                .shadow(color: SkinColor.accent.opacity(0.35), radius: 3)
        }
    }

    private var handleOffset: CGSize {
        CGSize(
            width: (CGFloat((x + 100) / 200) - 0.5) * (width - 24),
            height: -(CGFloat((y + 100) / 200) - 0.5) * (height - 24)
        )
    }
}

// MARK: - Preset swatch

struct SkinPresetSwatch: View {
    let preset: PresetItem

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(baseGradient)

            if preset.kind == .paper {
                paperLines
            } else {
                perforations
            }

            LinearGradient(
                colors: [Color.white.opacity(0.18), .clear, Color.black.opacity(0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .frame(width: 38, height: 38)
    }

    private var baseGradient: LinearGradient {
        if preset.kind == .paper {
            return LinearGradient(
                colors: [Color(hex: 0xE7DFCC), Color(hex: 0xCFC2A8), Color(hex: 0x9A8B70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        let hue = preset.hue
        let top = Color(hue: hue, saturation: 0.30, brightness: preset.kind == .reversal ? 0.62 : 0.50)
        let middle = Color(hue: hue + 0.01, saturation: 0.22, brightness: 0.32)
        let bottom = Color(hue: hue - 0.01, saturation: 0.10, brightness: 0.13)
        return LinearGradient(
            colors: [top, middle, bottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var perforations: some View {
        HStack {
            VStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.black.opacity(0.34))
                        .frame(width: 2.5, height: 4)
                }
            }
            .padding(.leading, 3)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    private var paperLines: some View {
        VStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 0.5)
            }
        }
        .padding(.horizontal, 8)
    }
}
