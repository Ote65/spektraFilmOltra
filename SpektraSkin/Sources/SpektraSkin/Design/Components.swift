import AppKit
import SwiftUI

// MARK: - Hairline

struct SkinHairline: View {
    var color: Color = SkinColor.hairline
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .allowsHitTesting(false)
    }
}

struct SkinVerticalHairline: View {
    var color: Color = SkinColor.hairline
    var height: CGFloat = 18
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 1, height: height)
            .allowsHitTesting(false)
    }
}

// MARK: - Buttons

private struct SkinPressEffect: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SkinButton: View {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    private let title: String
    private let icon: String?
    private let kind: Kind
    private let height: CGFloat
    private let disabled: Bool
    private let action: () -> Void

    @State private var hovered = false

    init(
        _ title: String,
        icon: String? = nil,
        kind: Kind = .secondary,
        height: CGFloat = SkinMetric.controlHeight,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.height = height
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.skin(12, kind == .primary ? .semibold : .medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: kind == .secondary ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous))
        }
        .buttonStyle(SkinPressEffect())
        .disabled(disabled)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }

    private var horizontalPadding: CGFloat {
        kind == .quiet ? 9 : 13
    }

    private var background: Color {
        if disabled {
            return kind == .primary ? SkinColor.surface3 : .clear
        }
        switch kind {
        case .primary:
            return hovered ? SkinColor.accentHover : SkinColor.accent
        case .secondary:
            return hovered ? SkinColor.surface2 : .clear
        case .quiet:
            return hovered ? SkinColor.wash : .clear
        }
    }

    private var borderColor: Color {
        guard kind == .secondary, !disabled else { return .clear }
        return hovered ? SkinColor.hairlineStrong : SkinColor.hairline
    }

    private var textColor: Color {
        if disabled { return SkinColor.text4 }
        switch kind {
        case .primary: return SkinColor.accentOn
        case .secondary: return hovered ? SkinColor.text1 : SkinColor.text2
        case .quiet: return hovered ? SkinColor.text1 : SkinColor.text3
        }
    }

    private var iconColor: Color {
        if disabled { return SkinColor.text4 }
        switch kind {
        case .primary: return SkinColor.accentOn
        case .secondary: return hovered ? SkinColor.text1 : SkinColor.text3
        case .quiet: return hovered ? SkinColor.text2 : SkinColor.text3
        }
    }
}

struct SkinIconButton: View {
    private let icon: String
    private let size: CGFloat
    private let frame: CGFloat
    private let active: Bool
    private let disabled: Bool
    private let help: String?
    private let action: () -> Void

    @State private var hovered = false

    init(
        _ icon: String,
        size: CGFloat = 13,
        frame: CGFloat = SkinMetric.iconButton,
        active: Bool = false,
        disabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.icon = icon
        self.size = size
        self.frame = frame
        self.active = active
        self.disabled = disabled
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: frame, height: frame)
                .background(
                    RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                        .strokeBorder(active ? SkinColor.accent.opacity(0.24) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous))
        }
        .buttonStyle(SkinPressEffect())
        .disabled(disabled)
        .help(help ?? "")
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }

    private var background: Color {
        if disabled { return .clear }
        if active { return SkinColor.accent.opacity(hovered ? 0.16 : 0.11) }
        return hovered ? SkinColor.wash : .clear
    }

    private var iconColor: Color {
        if disabled { return SkinColor.text4 }
        if active { return SkinColor.accent }
        return hovered ? SkinColor.text1 : SkinColor.text2
    }
}

// MARK: - Inputs

struct SkinSearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 240
    var height: CGFloat = SkinMetric.controlHeight
    var fontSize: CGFloat = 11.5

    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(focused ? SkinColor.text2 : SkinColor.text3)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.skin(fontSize))
                        .foregroundStyle(SkinColor.text3)
                        .lineLimit(1)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.skin(fontSize))
                    .foregroundStyle(focused ? SkinColor.text1 : SkinColor.text2)
                    .focused($focused)
            }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SkinColor.text4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                .fill(focused ? SkinColor.surface2 : SkinColor.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                .strokeBorder(hovered ? SkinColor.hairlineStrong : SkinColor.hairline, lineWidth: 1)
        )
        .shadow(color: SkinColor.accent.opacity(focused ? 0.16 : 0), radius: 6)
        .contentShape(RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous))
        .onTapGesture { focused = true }
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
        .animation(SkinMotion.state, value: focused)
    }
}

// MARK: - Chips

struct SkinChip: View {
    let title: String
    var tone: ColorLabel?
    var selected: Bool = false
    var height: CGFloat = SkinMetric.smallControlHeight
    var icon: String?
    var action: () -> Void = {}

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let tone {
                    Circle()
                        .fill(SkinColor.labelTone(tone))
                        .frame(width: 7, height: 7)
                }
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.skin(11.5, selected ? .medium : .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(background)
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: selected ? 1 : 0)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(SkinPressEffect())
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }

    private var background: Color {
        if selected {
            if let tone {
                return SkinColor.labelTone(tone).opacity(0.13)
            }
            return SkinColor.surface3
        }
        return hovered ? SkinColor.wash : .clear
    }

    private var borderColor: Color {
        guard selected else { return .clear }
        if let tone {
            return SkinColor.labelTone(tone).opacity(0.45)
        }
        return SkinColor.hairlineStrong
    }

    private var textColor: Color {
        if selected {
            if let tone { return SkinColor.labelTone(tone) }
            return SkinColor.text1
        }
        return hovered ? SkinColor.text2 : SkinColor.text3
    }

    private var iconColor: Color {
        selected ? SkinColor.text1 : SkinColor.text3
    }
}

// MARK: - Segmented control

struct SkinSegmented: View {
    let titles: [String]
    @Binding var selection: Int
    var width: CGFloat? = 176

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { item in
                Button {
                    withAnimation(SkinMotion.slide) { selection = item.offset }
                } label: {
                    Text(item.element)
                        .font(.skin(11.5, selection == item.offset ? .medium : .regular))
                        .foregroundStyle(selection == item.offset ? SkinColor.text1 : SkinColor.text3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == item.offset {
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(SkinColor.surface3)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                            .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "segment", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: width, height: 30)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                .fill(SkinColor.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                .strokeBorder(SkinColor.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Underline tabs

struct SkinUnderlineTabs: View {
    let titles: [String]
    @Binding var selection: Int
    var fontSize: CGFloat = 10.5
    var height: CGFloat = 30

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { item in
                Button {
                    withAnimation(SkinMotion.slide) { selection = item.offset }
                } label: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(item.element)
                            .font(.skin(fontSize, selection == item.offset ? .medium : .regular))
                            .foregroundStyle(selection == item.offset ? SkinColor.text1 : SkinColor.text3)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        ZStack {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(height: 2)
                            if selection == item.offset {
                                Capsule()
                                    .fill(SkinColor.accent)
                                    .frame(width: underlineWidth(for: item.element), height: 2)
                                    .matchedGeometryEffect(id: "underline", in: underline)
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

    private func underlineWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return (title as NSString).size(withAttributes: [.font: font]).width + 8
    }
}

// MARK: - Toggle

struct SkinToggle: View {
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    @State private var hovered = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            withAnimation(.easeInOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(trackColor)
                .frame(width: 32, height: 18)
                .overlay(
                    Capsule()
                        .strokeBorder(isOn ? SkinColor.accent.opacity(0.55) : SkinColor.hairline, lineWidth: 1)
                )
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Color(hex: 0xF5F1E9) : Color(hex: 0xA9A298))
                        .frame(width: 13, height: 13)
                        .padding(.horizontal, 2.5)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }

    private var trackColor: Color {
        if isOn {
            return hovered ? SkinColor.accent.opacity(0.88) : SkinColor.accent.opacity(0.78)
        }
        return hovered ? SkinColor.surface4 : SkinColor.surface3
    }
}

// MARK: - Card

struct SkinCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: SkinRadius.panel, style: .continuous)
                    .fill(SkinColor.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SkinRadius.panel, style: .continuous)
                    .strokeBorder(SkinColor.hairline, lineWidth: 1)
            )
    }
}
