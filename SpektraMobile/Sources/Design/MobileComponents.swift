import SwiftUI

// MARK: - iOS 26 玻璃材质
//
// iOS 26 起浮动控件默认是 Liquid Glass。这里只在 26+ 采用系统材质，
// 17–25 仍用原来的实心垫底——否则等于把旧观感一直带到新系统上。
// 统一走一个 modifier，避免每处控件各写一遍 `#available`。

struct MGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var fallbackFill: Color = MColor.surface2
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                (interactive ? Glass.regular.interactive() : Glass.regular).tint(tint),
                in: shape
            )
        } else {
            content.background(shape.fill(fallbackFill))
        }
    }
}

extension View {
    func mGlassSurface<S: Shape>(_ shape: S, tint: Color? = nil,
                                 fallbackFill: Color = MColor.surface2,
                                 interactive: Bool = false) -> some View {
        modifier(MGlassSurface(shape: shape, tint: tint,
                               fallbackFill: fallbackFill, interactive: interactive))
    }
}

// MARK: - 线

struct MHairline: View {
    var color: Color = MColor.hairline
    var body: some View {
        Rectangle().fill(color).frame(height: 1).allowsHitTesting(false)
    }
}

/// 顶部黑色渐隐：铺在顶栏按钮下面，放大后的照片从控件下方经过时保住文字可读性，
/// 又不会像实色条一样截断照片。调用方自行负责 offset(y: -insets.top) 顶到状态栏。
struct MTopScrim: View {
    var height: CGFloat = 170

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.72), location: 0),
                .init(color: Color.black.opacity(0.34), location: 0.45),
                .init(color: Color.clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

struct MVerticalHairline: View {
    var color: Color = MColor.hairline
    var height: CGFloat = 18
    var body: some View {
        Rectangle().fill(color).frame(width: 1, height: height).allowsHitTesting(false)
    }
}

// MARK: - 按压

struct MPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(MMotion.press, value: configuration.isPressed)
    }
}

// MARK: - 圆形图标按钮

struct MCircleIconButton: View {
    let icon: String
    var size: CGFloat = 15
    var frame: CGFloat = 40
    var active: Bool = false
    var action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? MColor.brass : MColor.text2)
                .frame(width: frame, height: frame)
                .mGlassSurface(Circle(),
                               tint: active ? MColor.brassWash : nil,
                               fallbackFill: active ? MColor.brassWash : MColor.surface1,
                               interactive: true)
                .overlay(
                    Circle().strokeBorder(active ? MColor.brass.opacity(0.3) : MColor.hairline, lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(MPressStyle(scale: 0.92))
    }
}

// MARK: - 黄铜主按钮

struct MBrassPill: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 32
    var fullWidth: Bool = false
    var disabled: Bool = false
    var loading: Bool = false
    var action: () -> Void

    var body: some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(MColor.brassInk)
                        .scaleEffect(0.8)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.mSans(11.5, .semibold))
            }
            .foregroundStyle(disabled ? MColor.text4 : MColor.brassInk)
            .padding(.horizontal, 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(
                Capsule().fill(disabled ? MColor.surface3 : MColor.brass)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
        .disabled(disabled)
    }
}

// MARK: - 导出进度

/// 导出要十几秒：给「现在到哪一段 + 百分比 + 细进度条」，比禁用态胶囊上的转圈有用。
struct MExportProgressRow: View {
    let label: String
    let progress: Double
    var height: CGFloat = 46

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(label.isEmpty ? "导出中" : label)
                    .font(.mSans(11.5, .semibold))
                    .foregroundStyle(MColor.text1)
                Spacer(minLength: 0)
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.mSans(10.5, .medium).monospacedDigit())
                    .foregroundStyle(MColor.text3)
            }
            Capsule()
                .fill(MColor.surface3)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(MColor.brass)
                            .frame(width: geo.size.width * clamped)
                            .animation(MMotion.state, value: clamped)
                    }
                }
        }
        .padding(.horizontal, 16)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MColor.surface2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("导出进度")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%，\(label.isEmpty ? "导出中" : label)")
    }
}

// MARK: - 筛选片

struct MFilterChip: View {
    let title: String
    var tone: MColorLabel? = nil
    var selected: Bool = false
    var action: () -> Void

    var body: some View {
        Button {
            MHaptic.tick()
            action()
        } label: {
            HStack(spacing: 5) {
                if let tone {
                    Circle()
                        .fill(MColor.labelTone(tone))
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.mSans(11, selected ? .semibold : .regular))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(selected ? MColor.surface3 : MColor.surface1.opacity(0.5))
            )
            .overlay(
                Capsule().strokeBorder(selected ? MColor.hairlineStrong : MColor.hairlineFaint, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(MPressStyle(scale: 0.95))
    }

    private var textColor: Color {
        if selected {
            if let tone { return MColor.labelTone(tone) }
            return MColor.text1
        }
        return MColor.text3
    }
}

// MARK: - 下划线页签

struct MUnderlineTabs: View {
    let titles: [String]
    @Binding var selection: Int
    var fontSize: CGFloat = 12.5
    var underlineWidth: CGFloat = 26
    var height: CGFloat = 40
    var badgeCount: Int = 0

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { item in
                Button {
                    guard selection != item.offset else { return }
                    MHaptic.tick()
                    withAnimation(MMotion.push) { selection = item.offset }
                } label: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 5) {
                            Text(item.element)
                                .font(.mSans(fontSize, selection == item.offset ? .semibold : .regular))
                                .foregroundStyle(selection == item.offset ? MColor.text1 : MColor.text3)
                            if item.offset == 0, badgeCount > 0 {
                                Text("\(badgeCount)")
                                    .font(.mSans(8.5, .semibold).monospacedDigit())
                                    .foregroundStyle(MColor.brass)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(MColor.brassWash))
                            }
                        }
                        Spacer(minLength: 0)
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 2)
                            if selection == item.offset {
                                Capsule()
                                    .fill(MColor.brass)
                                    .frame(width: underlineWidth, height: 2)
                                    .matchedGeometryEffect(id: "tab-underline", in: underline)
                            }
                        }
                        .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 分组标题

struct MSectionHead: View {
    let title: String
    var trailing: String? = nil
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).mLabel(compact ? 8.5 : 9.5, color: MColor.text3)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).mMeta(compact ? 8 : 9, color: MColor.text4)
            }
        }
    }
}

// MARK: - 抽屉把手

struct MGrabber: View {
    var compact: Bool = false

    var body: some View {
        Capsule()
            .fill(MColor.text4.opacity(0.65))
            .frame(width: compact ? 30 : 34, height: compact ? 3.5 : 4)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 20 : 22)
            .contentShape(Rectangle())
    }
}

/// 抽屉档位切换：点击而不是上拉。系统 chevron 自带钝角端头，命中区 44×22。
/// 只有一个档位的页面不显示（`isVisible == false`）。
struct MDrawerChevron: View {
    let isExpanded: Bool
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button {
            MHaptic.tick()
            action()
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MColor.text3)
                .frame(width: 44, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .accessibilityLabel(isExpanded ? "收起面板" : "展开面板")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - 参数滑条

struct MParamSlider: View {
    let label: String
    @Binding var value: Double
    let base: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals: Int = 0
    var suffix: String = ""
    var isEnabled: Bool = true
    var compact: Bool = false

    @State private var dragging = false
    @State private var lastTick: Double = 0
    /// 按下时的锚点：值按「位移增量」换算，而不是手指的绝对位置。
    @State private var dragStartValue: Double = 0
    @State private var dragStartX: CGFloat = 0

    var body: some View {
        // 栅格化布局：每个单元 = 标签区 + 滑轨区，所有滑轨严格等间距。
        // 标签在标签区内垂直居中 → 恰好落在「上一条滑轨 ↔ 自己这条滑轨」的正中间，水平左对齐。
        // compact：单元 44（标签区 26 + 滑轨区 18）；常规：单元 52（30 + 22）。
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.mSans(compact ? 11 : 12.5))
                    .foregroundStyle(isEnabled ? MColor.text2 : MColor.text4)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(text(for: value))
                    .font(.mSans(compact ? 9.5 : 10.5, .medium).monospacedDigit())
                    .foregroundStyle(isDirty ? MColor.brass : MColor.text3)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            // 实测校准：.mSans 行盒内字形比 frame 中心偏高 8pt，导致标签离上一条轨 14pt、
            // 离自己的轨 30pt。下移 8pt 后字形视觉中心正好落在两轨连线中点，两侧等距。
            .offset(y: 8)
            .frame(height: labelZoneH, alignment: .leading)

            track
                .frame(height: trackZoneH)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .frame(height: unitH)
        .animation(MMotion.quick, value: dragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text(for: value))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let delta = max(step, (range.upperBound - range.lowerBound) / 100)
            switch direction {
            case .increment:
                value = min(range.upperBound, value + delta)
            case .decrement:
                value = max(range.lowerBound, value - delta)
            @unknown default:
                break
            }
        }
    }

    /// 滑轨行：底轨 + 已调进度 + 圆球，全部在行内垂直居中。
    private var track: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let ratio = normalized(value)
            let knob: CGFloat = dragging
                ? (compact ? 19 : 22)
                : (compact ? 17 : 20)
            let knobX = min(max(width * ratio - knob / 2, 0), max(0, width - knob))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MColor.surface4)
                    .frame(width: width, height: trackHeight)

                Capsule()
                    .fill(isDirty ? MColor.brass.opacity(0.9) : Color.white.opacity(0.20))
                    .frame(width: max(width * ratio, 0), height: trackHeight)

                Circle()
                    .fill(Color(hex: 0xF1ECE3))
                    .frame(width: knob, height: knob)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(0.32), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.38), radius: compact ? 2 : 3, y: 1)
                    // 命中区只围着圆点：轨道本身不接收拖动，列表滚动不会被滑条抢走。
                    .frame(width: knob + 28, height: 36)
                    .contentShape(Rectangle())
                    .offset(x: knobX - 14)
                    .allowsHitTesting(isEnabled)
                    .gesture(dragGesture(width: width))
            }
            .frame(maxHeight: .infinity)
        }
    }

    // 栅格常量：标签区（上一轨到本轨间距的一半处放标签）、滑轨区。
    private var labelZoneH: CGFloat { compact ? 26 : 30 }
    private var trackZoneH: CGFloat { compact ? 18 : 22 }
    private var unitH: CGFloat { labelZoneH + trackZoneH }

    /// 相对拖动：记录按下锚点，之后只用位移增量换算，永远不会「碰到就跳值」。
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !dragging {
                    dragging = true
                    dragStartValue = value
                    dragStartX = gesture.startLocation.x
                    lastTick = value
                    MHaptic.light()
                }
                let span = range.upperBound - range.lowerBound
                guard span > 0 else { return }
                let delta = Double((gesture.location.x - dragStartX) / width) * span
                let raw = dragStartValue + delta
                let stepped = step > 0 ? (raw / step).rounded() * step : raw
                let clamped = min(range.upperBound, max(range.lowerBound, stepped))
                if abs(clamped - value) > 1e-9 {
                    value = clamped
                    if abs(clamped - lastTick) >= max(step, 1e-9) {
                        lastTick = clamped
                        MHaptic.tick()
                    }
                }
            }
            .onEnded { _ in
                dragging = false
                lastTick = value
            }
    }

    private var trackHeight: CGFloat { compact ? 2.5 : 3 }

    private var isDirty: Bool { abs(value - base) > 1e-9 }

    private func normalized(_ value: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }

    private func text(for value: Double) -> String {
        let cutoff = pow(10, Double(-decimals)) * 0.5
        let v = abs(value) < cutoff ? 0 : value
        var string = String(format: "%.\(decimals)f", v)
        if decimals > 0, string.contains(".") {
            while string.hasSuffix("0") { string.removeLast() }
            if string.hasSuffix(".") { string.removeLast() }
        }
        if range.lowerBound < 0, v > 0 { string = "+" + string }
        return string + suffix
    }
}

// MARK: - 开关行

struct MToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var compact: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.mSans(compact ? 11 : 12.5))
                .foregroundStyle(MColor.text2)
            Spacer()
            Button {
                MHaptic.tick()
                withAnimation(MMotion.state) { isOn.toggle() }
            } label: {
                Capsule()
                    .fill(isOn ? MColor.brass.opacity(0.88) : MColor.surface3)
                    .frame(width: compact ? 38 : 42, height: compact ? 22 : 24)
                    .overlay(
                        Capsule().strokeBorder(isOn ? .clear : MColor.hairline, lineWidth: 1)
                    )
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(isOn ? MColor.brassInk : MColor.text3)
                            .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                            .padding(.horizontal, 3)
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(height: compact ? 42 : 48)
    }
}

// MARK: - 下拉选择行

struct MChoiceRow: View {
    let label: String
    let value: String
    let options: [MProOption]
    var isEnabled: Bool = true
    let action: (String) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.mSans(11))
                .foregroundStyle(isEnabled ? MColor.text2 : MColor.text4)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        MHaptic.tick()
                        action(option.value)
                    } label: {
                        Text(option.label)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.mSans(10.5, .medium))
                        .foregroundStyle(isEnabled ? MColor.brass : MColor.text4)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(MColor.text4)
                }
                .contentShape(Rectangle())
            }
            .disabled(!isEnabled)
        }
        .frame(height: 42)
    }
}

// MARK: - 文本输入行

struct MTextFieldRow: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var limit: Int = 28

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.mSans(11))
                .foregroundStyle(MColor.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.mSans(10.5, .medium))
                .foregroundStyle(MColor.text1)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 8)
                .frame(width: 150, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MColor.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(MColor.hairline, lineWidth: 1)
                )
                .onChange(of: text) { _, newValue in
                    if newValue.count > limit { text = String(newValue.prefix(limit)) }
                }
        }
        .frame(height: 42)
    }
}

// MARK: - iOS 26 悬浮玻璃页签

/// 底部页签的玻璃胶囊外壳：内容仍由各页面自己排，
/// 这样显影页「调色」按钮的长按手势和调色页的三页签都不用重写。
struct MGlassTabCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(.horizontal, 5)
        .frame(height: 50)
        .mGlassSurface(Capsule(), fallbackFill: MColor.surface2.opacity(0.96))
        .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 16, y: 6)
        .padding(.horizontal, 18)
    }
}


// MARK: - 胶片 / 相纸图标
//
// 胶片图标几何取自 Bootstrap Icons "film"（MIT License）
// https://icons.getbootstrap.com/icons/film/
// 源文件保存在 SpektraMobile/Resources/Icons/film.svg

struct MFilmStockIcon: View {
    let film: MFilm
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let image = photoIcon {
                MImage.swiftUI(image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                legacyDrawing
            }
        }
        .frame(width: size, height: size)
    }

    /// 真实胶片图标：每支胶片一张按自身色相调色的 PNG，统一 256×256 画布。
    /// 找不到资源时自动回退到手绘图标，不会出现空白。
    private var photoIcon: MPlatformImage? {
        guard let url = Bundle.main.url(
            forResource: film.id,
            withExtension: "png",
            subdirectory: "Icons/Films"
        ) else { return nil }
        return MImage.thumbnail(url: url)
    }

    private var legacyDrawing: some View {
        Canvas { context, canvas in
            var path = Path()
            path.addPath(
                Path(
                    roundedRect: CGRect(x: 0, y: 0, width: 16, height: 16),
                    cornerRadius: 1.2
                )
            )

            let holes: [CGRect] = [
                CGRect(x: 1, y: 1, width: 2, height: 2),
                CGRect(x: 1, y: 4, width: 2, height: 2),
                CGRect(x: 1, y: 7, width: 2, height: 2),
                CGRect(x: 1, y: 10, width: 2, height: 2),
                CGRect(x: 1, y: 13, width: 2, height: 2),
                CGRect(x: 13, y: 1, width: 2, height: 2),
                CGRect(x: 13, y: 4, width: 2, height: 2),
                CGRect(x: 13, y: 7, width: 2, height: 2),
                CGRect(x: 13, y: 10, width: 2, height: 2),
                CGRect(x: 13, y: 13, width: 2, height: 2),
            ]
            for rect in holes {
                path.addRect(rect)
            }

            path.addRect(CGRect(x: 4, y: 1, width: 8, height: 6))
            path.addRect(CGRect(x: 4, y: 9, width: 8, height: 6))

            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: filmColors),
                    startPoint: .zero,
                    endPoint: CGPoint(x: canvas.width, y: canvas.height)
                ),
                style: FillStyle(eoFill: true)
            )
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        )
    }

    private var filmColors: [Color] {
        let h = film.hue
        let s = film.saturation
        let b = film.brightness
        return [
            Color(hue: h, saturation: min(0.66, s), brightness: min(0.88, b + 0.24)),
            Color(hue: h + 0.01, saturation: s * 0.8, brightness: b * 0.70),
            Color(hue: h - 0.006, saturation: s * 0.35, brightness: b * 0.34),
        ]
    }
}

struct MPaperStockIcon: View {
    let paper: MPaper
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let image = photoIcon {
                MImage.swiftUI(image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                legacyDrawing
            }
        }
        .frame(width: size, height: size)
    }

    /// 真实相纸图标：与胶片同一套 256×256 画布逻辑，保证显示尺寸一致。
    private var photoIcon: MPlatformImage? {
        guard let url = Bundle.main.url(
            forResource: paper.id,
            withExtension: "png",
            subdirectory: "Icons/Papers"
        ) else { return nil }
        return MImage.thumbnail(url: url)
    }

    private var legacyDrawing: some View {
        Canvas { context, canvas in
            let unit = min(canvas.width, canvas.height) / 16
            let sheet = CGRect(x: 2.2 * unit, y: 1.2 * unit, width: 11.6 * unit, height: 13.6 * unit)
            let rounded = Path(roundedRect: sheet, cornerRadius: 1.1 * unit)

            context.fill(
                rounded,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(hex: 0xF4EDDC),
                        Color(hex: 0xE2D6BC),
                        Color(hex: 0xC9B995),
                    ]),
                    startPoint: CGPoint(x: sheet.minX, y: sheet.minY),
                    endPoint: CGPoint(x: sheet.maxX, y: sheet.maxY)
                )
            )

            context.drawLayer { layer in
                layer.clip(to: rounded)

                layer.fill(
                    Path(CGRect(origin: CGPoint(x: sheet.minX, y: sheet.minY), size: sheet.size)),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.white.opacity(0.22),
                            Color.clear,
                            Color.black.opacity(0.14),
                        ]),
                        startPoint: CGPoint(x: sheet.minX, y: sheet.minY),
                        endPoint: CGPoint(x: sheet.maxX, y: sheet.maxY)
                    )
                )

                for offset in [5.0, 8.2, 11.4] {
                    var line = Path()
                    line.move(to: CGPoint(x: sheet.minX + 2.0 * unit, y: offset * unit))
                    line.addLine(to: CGPoint(x: sheet.maxX - 3.2 * unit, y: offset * unit))
                    layer.stroke(line, with: .color(Color.white.opacity(0.16)), lineWidth: 0.5 * unit)
                }
            }

            var fold = Path()
            fold.move(to: CGPoint(x: 10.6 * unit, y: 1.2 * unit))
            fold.addLine(to: CGPoint(x: 13.8 * unit, y: 4.4 * unit))
            fold.addLine(to: CGPoint(x: 13.8 * unit, y: 1.2 * unit))
            context.fill(fold, with: .color(Color(hex: 0xB9A681)))

            var foldLine = Path()
            foldLine.move(to: CGPoint(x: 10.6 * unit, y: 1.2 * unit))
            foldLine.addLine(to: CGPoint(x: 13.8 * unit, y: 4.4 * unit))
            context.stroke(foldLine, with: .color(Color.white.opacity(0.24)), lineWidth: 0.5 * unit)

            context.stroke(rounded, with: .color(Color.white.opacity(0.18)), lineWidth: 0.6 * unit)
        }
        .frame(width: size, height: size)
    }
}

struct MFilmRailItem: View {
    let film: MFilm
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

                Text(film.name)
                    .font(.mSans(7.5, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MColor.text1 : MColor.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
    }
}

struct MPaperRailItem: View {
    let paper: MPaper
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

                    MPaperStockIcon(paper: paper, size: 27)
                }
                .frame(width: 33, height: 33)

                Text(paper.name)
                    .font(.mSans(7.5, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MColor.text1 : MColor.text3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
    }
}


// MARK: - 横向滚动轨

struct MHScrollRail<Content: View>: View {
    let itemCount: Int
    var itemWidth: CGFloat = 58
    var spacing: CGFloat = 5
    var trailing: CGFloat = 20
    var itemHeight: CGFloat = 52
    var fadeColor: Color = MColor.surface1
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let contentWidth = CGFloat(itemCount) * itemWidth
                + CGFloat(max(0, itemCount - 1)) * spacing
                + trailing
            let maxOffset = max(0, contentWidth - geo.size.width)

            ZStack(alignment: .leading) {
                HStack(spacing: spacing) {
                    content()
                }
                .padding(.trailing, trailing)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [fadeColor, fadeColor.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 22)
                .opacity(offset < -6 ? 1 : 0)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                LinearGradient(
                    colors: [fadeColor.opacity(0), fadeColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 26)
                .opacity(offset > -maxOffset + 6 ? 1 : 0)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { gesture in
                        if dragStart == nil { dragStart = offset }
                        let base = dragStart ?? offset
                        let raw = base + gesture.translation.width
                        if raw > 0 {
                            offset = raw * 0.25
                        } else if raw < -maxOffset {
                            offset = -maxOffset + (raw + maxOffset) * 0.25
                        } else {
                            offset = raw
                        }
                    }
                    .onEnded { gesture in
                        let projected = offset + gesture.predictedEndTranslation.width
                        let target = min(0, max(-maxOffset, projected))
                        withAnimation(MMotion.drawer) { offset = target }
                        dragStart = nil
                    }
            )
        }
        .frame(height: itemHeight)
        .clipped()
    }
}

// MARK: - 二维印相色彩盘

struct MColorPad: View {
    @Binding var x: Double
    @Binding var y: Double
    var width: CGFloat = 156
    var height: CGFloat = 92
    /// 正片扫描模式等场景下印相滤色不参与成像，需要置灰并停止手势。
    var isEnabled: Bool = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(MColor.surface2.opacity(0.8))

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(MColor.hairline, lineWidth: 1)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1, height: height - 36)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: width - 48, height: 1)

            Circle()
                .fill(Color.white.opacity(0.20))
                .frame(width: 3.5, height: 3.5)

            handle
                .offset(handleOffset)

            Text("绿")
                .font(.mSans(7, .medium))
                .foregroundStyle(MColor.text4)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)

            Text("品红")
                .font(.mSans(7, .medium))
                .foregroundStyle(MColor.text4)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 4)

            Text("暖")
                .font(.mSans(7, .medium))
                .foregroundStyle(MColor.text4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)

            Text("冷")
                .font(.mSans(7, .medium))
                .foregroundStyle(MColor.text4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 7)
        }
        .frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // 色盘在 ScrollView 里：用高优先级手势，避免纵向拖动被列表滚动抢走。
        // y = +100（上）→ +M 滤镜 → 负片印相偏绿；y = -100（下）→ -M → 偏品红。
        // 与盘面「上绿下品红」的标注一致（原生引擎的 M 正方向是滤色片方向，不是成片色相）。
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    x = min(100, max(-100, Double(gesture.location.x / width) * 200 - 100))
                    y = min(100, max(-100, Double(100 - gesture.location.y / height * 200)))
                }
        )
        .onTapGesture(count: 2) {
            MHaptic.light()
            withAnimation(MMotion.state) {
                x = 0
                y = 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("印相色彩盘")
        .accessibilityValue("冷暖 \(Int(x.rounded()))，绿品红 \(Int(y.rounded()))")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: x = min(100, x + 5)
            case .decrement: x = max(-100, x - 5)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "更绿") { guard isEnabled else { return }; y = max(-100, y - 5) }
        .accessibilityAction(named: "更品红") { guard isEnabled else { return }; y = min(100, y + 5) }
        .accessibilityAction(named: "回到中性") {
            guard isEnabled else { return }
            x = 0
            y = 0
        }
        .allowsHitTesting(isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var handle: some View {
        ZStack {
            Circle()
                .strokeBorder(MColor.brass.opacity(0.75), lineWidth: 1)
                .frame(width: 13, height: 13)
                .background(Circle().fill(MColor.brass.opacity(0.10)))
            Circle()
                .fill(MColor.brass)
                .frame(width: 4.5, height: 4.5)
                .shadow(color: MColor.brass.opacity(0.35), radius: 3)
        }
    }

    private var handleOffset: CGSize {
        CGSize(
            width: (CGFloat((x + 100) / 200) - 0.5) * (width - 22),
            height: -(CGFloat((y + 100) / 200) - 0.5) * (height - 22)
        )
    }
}

// MARK: - 颗粒样张

struct MGrainSample: View {
    let intensity: Double

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x6B6456), Color(hex: 0x2A261E)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            var state: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }

            let strength = min(1, max(0.04, intensity))
            let count = Int(120 + strength * 420)

            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height
                let radius = 0.4 + next() * 1.1
                let bright = next() > 0.5
                let alpha = 0.07 + strength * (0.10 + next() * 0.26)
                let color = bright
                    ? Color.white.opacity(alpha)
                    : Color.black.opacity(alpha * 1.4)
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                    with: .color(color)
                )
            }
        }
    }
}

// MARK: - LUT 卡

struct MLUTCard: View {
    let lut: MLUT
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: lut.tints.map { Color(hex: $0) },
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(lut.name)
                        .font(.mSans(10, .semibold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)
                    Text(lut.meta)
                        .font(.mSans(8, .medium))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(8)

                if selected {
                    RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                        .strokeBorder(MColor.brass, lineWidth: 1.6)
                    Circle()
                        .fill(MColor.brass)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(MColor.brassInk)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .frame(width: 108, height: 70)
            .contentShape(RoundedRectangle(cornerRadius: MRadius.control, style: .continuous))
        }
        .buttonStyle(MPressStyle(scale: 0.96))
    }
}

// MARK: - 曲线

struct MCurveEditor: View {
    @Binding var points: [CGPoint]
    var channel: String = "RGB"

    @State private var dragIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .fill(MColor.surface2.opacity(0.7))

                grid(size: size)

                diagonal(size: size)

                curvePath(size: size)
                    .stroke(
                        channel == "RGB" ? MColor.brass : MColor.text1,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                    )

                ForEach(Array(points.enumerated()), id: \.offset) { item in
                    Circle()
                        .fill(dragIndex == item.offset ? MColor.brassHigh : Color(hex: 0xF1ECE3))
                        .frame(width: dragIndex == item.offset ? 12 : 9, height: dragIndex == item.offset ? 12 : 9)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                        .position(x: item.element.x * size.width, y: (1 - item.element.y) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragIndex == nil {
                            dragIndex = nearest(to: gesture.location, size: size)
                            MHaptic.light()
                        }
                        guard let index = dragIndex, index > 0, index < points.count - 1 else { return }
                        let x = min(1, max(0, gesture.location.x / size.width))
                        let y = min(1, max(0, 1 - gesture.location.y / size.height))
                        let low = points[index - 1].x + 0.03
                        let high = points[index + 1].x - 0.03
                        points[index] = CGPoint(x: min(high, max(low, x)), y: y)
                    }
                    .onEnded { _ in dragIndex = nil }
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .strokeBorder(MColor.hairline, lineWidth: 1)
            )
        }
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for i in 1...3 {
                let x = size.width * CGFloat(i) / 4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(i) / 4
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 1)
    }

    private func diagonal(size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    private func curvePath(size: CGSize) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let mapped = points.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
        path.move(to: mapped[0])
        for i in 0..<(mapped.count - 1) {
            let p0 = mapped[max(i - 1, 0)]
            let p1 = mapped[i]
            let p2 = mapped[i + 1]
            let p3 = mapped[min(i + 2, mapped.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func nearest(to location: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)? = nil
        for (index, point) in points.enumerated() {
            let dx = point.x * size.width - location.x
            let dy = (1 - point.y) * size.height - location.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < 34 {
                if best == nil || distance < best!.distance {
                    best = (index, distance)
                }
            }
        }
        return best?.index
    }
}

// MARK: - 边缘返回手势

struct MBackSwipe: View {
    let action: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { gesture in
                        if gesture.translation.width > 72, abs(gesture.translation.height) < 60 {
                            action()
                        }
                    }
            )
    }
}

// MARK: - 悬浮模式胶囊

struct MModeCapsule: View {
    let titles: [String]
    @Binding var mode: Int

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { item in
                Button {
                    guard mode != item.offset else { return }
                    MHaptic.tick()
                    withAnimation(MMotion.push) { mode = item.offset }
                } label: {
                    Text(item.element)
                        .font(.mSans(11.5, mode == item.offset ? .semibold : .medium))
                        .foregroundStyle(mode == item.offset ? MColor.brass : MColor.text3)
                        .frame(width: 66, height: 30)
                        .background {
                            if mode == item.offset {
                                Capsule()
                                    .fill(MColor.surface4)
                                    .overlay(
                                        Capsule().strokeBorder(MColor.brass.opacity(0.24), lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "mode-pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.element)
                .accessibilityAddTraits(mode == item.offset ? [.isSelected] : [])
            }
        }
        .padding(3)
        .mGlassSurface(Capsule(), fallbackFill: MColor.surface2.opacity(0.97))
        .overlay(Capsule().strokeBorder(MColor.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模式")
    }
}

// MARK: - 轮廓漏光
//
// 整体轮廓的微弱「呼吸」：亮度在整圈上同步起伏，没有任何亮带沿边移动，
// 也没有每圈的淡出与重启。只表示「正在处理」，不携带进度信息。

struct MGlowSweep<S: Shape>: View {
    let shape: S
    var isActive: Bool
    var period: Double = 4.2
    var coreWidth: CGFloat = 1.3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let t = (elapsed / period).truncatingRemainder(dividingBy: 1)
            // 单圈正弦呼吸：起点与终点都停在 0.5，跨圈没有熄灭、没有跳变。
            let breath = 0.5 + 0.5 * sin(2 * Double.pi * t)
            // 范围 0.42–0.92：真机上「基本看不见」反馈过，抬到肉眼明确的漏光强度。
            let envelope = 0.42 + 0.50 * breath

            ZStack {
                shape
                    .stroke(MColor.brassHigh.opacity(0.16 * envelope), lineWidth: coreWidth * 7.0)
                    .blur(radius: coreWidth * 7)
                shape
                    .stroke(MColor.brass.opacity(0.52 * envelope), lineWidth: coreWidth * 3.0)
                    .blur(radius: coreWidth * 3)
                shape
                    .stroke(MColor.brassHigh.opacity(0.92 * envelope), lineWidth: coreWidth * 1.15)
            }
        }
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.24), value: isActive)
        .allowsHitTesting(false)
    }
}

// MARK: - 开孔光效
//
// 灵动岛 / 刘海：光沿着开孔轮廓与屏幕边界游走，并在下方显示当前步骤；
// 无开孔（平顶）：只在顶边做一道漏光。

struct MHousingAura: View {
    let housing: MHousingKind
    let isActive: Bool
    let label: String

    @Environment(\.mSafeInsets) private var insets

    var body: some View {
        GeometryReader { geo in
            let opening = MDeviceHousing.opening(
                kind: housing,
                insets: MSafeInsets(top: insets.top, bottom: insets.bottom, size: geo.size)
            )
            ZStack(alignment: .top) {
                if housing == .none {
                    MGlowSweep(
                        shape: Capsule().inset(by: 1),
                        isActive: isActive,
                        period: 4.2,
                        coreWidth: 1.2
                    )
                    .frame(width: max(1, insets.width - 44), height: 4)
                    .padding(.top, 2)
                } else {
                    ZStack {
                        housingShape()
                            .stroke(Color.white.opacity(isActive ? 0.10 : 0), lineWidth: 1)
                            .animation(.easeOut(duration: 0.24), value: isActive)

                        MGlowSweep(
                            shape: housingShape(),
                            isActive: isActive,
                            period: housing == .notch ? 4.6 : 4.2,
                            coreWidth: 1.3
                        )
                    }
                    .frame(width: opening.width, height: opening.height)
                    // 轮廓必须与真实开孔重合。此前把整个 VStack 按 `maxY` 下推，
                    // 轮廓会被推到开孔下方，正好压住「快速 / 专业」胶囊，
                    // 屏幕上读成两个错位的同心胶囊。
                    .offset(y: opening.minY)

                    if !label.isEmpty {
                        Text(label)
                            .font(.mSans(9, .medium))
                            .foregroundStyle(MColor.brassHigh.opacity(0.92))
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .opacity(isActive ? 1 : 0)
                            .animation(.easeOut(duration: 0.24), value: isActive)
                            .animation(MMotion.quick, value: label)
                            .offset(y: opening.maxY + 6)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
    }

    private func housingShape() -> AnyShape {
        if housing == .notch {
            return AnyShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 3,
                    bottomLeadingRadius: 20,
                    bottomTrailingRadius: 20,
                    topTrailingRadius: 3,
                    style: .continuous
                )
            )
        }
        return AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - 预览落点

/// 首帧就绪前弹出的白色画布：先给一块空的相纸，再显影渐变成照片。
struct MCanvasCard: View {
    var rect: CGRect
    var opacity: Double
    var radius: CGFloat = 2

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xF8F3E8), Color(hex: 0xE9DFCB)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .opacity(opacity)
    }
}

enum MImageFit {
    /// 与 `.scaledToFit` + 左右 14pt 内边距的落点保持一致。
    static func rect(aspect: CGFloat, in size: CGSize, horizontalPadding: CGFloat = 14) -> CGRect {
        let availableWidth = max(1, size.width - horizontalPadding * 2)
        let availableHeight = max(1, size.height)
        let ratio = max(0.1, aspect)
        var width = availableWidth
        var height = width / ratio
        if height > availableHeight {
            height = availableHeight
            width = height * ratio
        }
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }
}
