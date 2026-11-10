import SwiftUI

// MARK: - 表面
//
// 暖中性石墨阶。相邻表面只差约 2% 亮度，分隔靠发丝线与光，而不是粗描边。

enum SkinColor {
    static let app = Color(hex: 0x141311)
    static let canvas = Color(hex: 0x0E0D0B)
    static let surface1 = Color(hex: 0x191713)
    static let surface2 = Color(hex: 0x1F1C18)
    static let surface3 = Color(hex: 0x26231D)
    static let surface4 = Color(hex: 0x302C25)

    static let hairline = Color.white.opacity(0.055)
    static let hairlineStrong = Color.white.opacity(0.105)
    static let hairlineFaint = Color.white.opacity(0.032)

    static let text1 = Color(hex: 0xF2EFE8)
    static let text2 = Color(hex: 0xB6B0A4)
    static let text3 = Color(hex: 0x8A8478)
    static let text4 = Color(hex: 0x605B52)

    static let accent = Color(hex: 0xC5A373)
    static let accentHover = Color(hex: 0xD8BB8C)
    static let accentPressed = Color(hex: 0x9E7E55)
    static let accentOn = Color(hex: 0x15120D)
    static let accentGlow = Color(hex: 0xC5A373).opacity(0.16)
    static let danger = Color(hex: 0xC0705D)

    static let red = Color(hex: 0xC0705E)
    static let yellow = Color(hex: 0xC9A872)
    static let green = Color(hex: 0x7E9B77)
    static let blue = Color(hex: 0x6D8BA7)

    static let scrim = Color.black.opacity(0.55)
    static let wash = Color.white.opacity(0.045)
    static let washStrong = Color.white.opacity(0.075)

    static func labelTone(_ label: ColorLabel) -> Color {
        switch label {
        case .red: return red
        case .yellow: return yellow
        case .green: return green
        case .blue: return blue
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - 几何

enum SkinRadius {
    static let micro: CGFloat = 4
    static let control: CGFloat = 7
    static let card: CGFloat = 10
    static let panel: CGFloat = 12
    static let pill: CGFloat = 13
}

enum SkinMetric {
    static let chromeHeight: CGFloat = 28
    static let pageMargin: CGFloat = 28
    static let topBarHeight: CGFloat = 54
    static let sideRailWidth: CGFloat = 300
    static let inspectorWidth: CGFloat = 300
    static let controlHeight: CGFloat = 30
    static let smallControlHeight: CGFloat = 26
    static let iconButton: CGFloat = 28
    static let statusBarHeight: CGFloat = 26
    static let filmstripHeight: CGFloat = 96
    static let presetCardHeight: CGFloat = 54
    static let listRowHeight: CGFloat = 76
}

// MARK: - 字体

extension Font {
    static func skin(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let pageTitle = Font.skin(23, .medium)
    static let pageSubtitle = Font.skin(11)
    static let sectionTitle = Font.skin(13, .semibold)
    static let body = Font.skin(12)
    static let caption = Font.skin(11)
    static let micro = Font.skin(10)
    static let groupLabel = Font.skin(10.5, .semibold)
    static let button = Font.skin(12, .medium)
    static let readout = Font.skin(11.5).monospacedDigit()
    static let meta = Font.skin(10.5).monospacedDigit()
    static let titleBarMark = Font.skin(9, .medium)
}

extension View {
    /// 元信息、尺寸和读数一律等宽，避免数字跳动。
    func skinMeta(_ size: CGFloat = 10.5, color: Color = SkinColor.text3) -> some View {
        self.font(.skin(size).monospacedDigit()).foregroundStyle(color)
    }

    func skinHairlineOverlay(_ radius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(SkinColor.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 动效

enum SkinMotion {
    static let hover = Animation.easeOut(duration: 0.13)
    static let state = Animation.easeOut(duration: 0.18)
    static let page = Animation.easeInOut(duration: 0.24)
    static let slide = Animation.spring(response: 0.28, dampingFraction: 0.92)
}
