import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 表面
//
// 暗房石墨 + 相纸白 + 黄铜。只在选中、改过的参数和主操作上出现颜色；
// 其余全部交给亮度台阶与发丝线。

enum MColor {
    static let clear = Color.clear
    static let app = Color(hex: 0x0E0D0B)
    static let canvas = Color(hex: 0x080706)
    static let surface1 = Color(hex: 0x17150F)
    static let surface2 = Color(hex: 0x1F1C15)
    static let surface3 = Color(hex: 0x28241B)
    static let surface4 = Color(hex: 0x353024)

    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.13)
    static let hairlineFaint = Color.white.opacity(0.035)

    static let text1 = Color(hex: 0xF4F0E7)
    static let text2 = Color(hex: 0xBDB6A8)
    static let text3 = Color(hex: 0x968F81)
    static let text4 = Color(hex: 0x7C7568)

    static let brass = Color(hex: 0xC7A577)
    static let brassHigh = Color(hex: 0xE2C99F)
    static let brassDeep = Color(hex: 0x9C7C52)
    static let brassInk = Color(hex: 0x17130C)
    static let brassWash = Color(hex: 0xC7A577).opacity(0.11)

    static let danger = Color(hex: 0xC0705E)
    static let filmRed = Color(hex: 0xC0705E)
    static let filmYellow = Color(hex: 0xC9A872)
    static let filmGreen = Color(hex: 0x7E9B77)
    static let filmBlue = Color(hex: 0x6D8BA7)

    static let scrim = Color.black.opacity(0.62)
    static let wash = Color.white.opacity(0.05)
    static let washStrong = Color.white.opacity(0.085)

    static func labelTone(_ label: MColorLabel) -> Color {
        switch label {
        case .red: return filmRed
        case .yellow: return filmYellow
        case .green: return filmGreen
        case .blue: return filmBlue
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

enum MRadius {
    static let micro: CGFloat = 4
    static let control: CGFloat = 10
    static let card: CGFloat = 14
    static let sheet: CGFloat = 28
    static let pill: CGFloat = 15
}

enum MMetric {
    /// 兜底值：真实布局一律用 `MSafeInsets`（由根视图按设备安全区注入）。
    static let safeTopFallback: CGFloat = 54
    static let safeBottomFallback: CGFloat = 34
    static let pageMargin: CGFloat = 20
    static let navHeight: CGFloat = 44
    static let tabsHeight: CGFloat = 42
    static let touch: CGFloat = 44
    /// 底部液态玻璃页签胶囊的固定高度与离屏距离。
    static let tabCapsuleHeight: CGFloat = 50
    static let tabCapsuleBottom: CGFloat = 8
    /// 参数面板悬浮在胶囊上方时留出的呼吸间距：面板底边与胶囊顶边之间保持 14pt。
    static let floatingPanelGap: CGFloat = 14
    /// 参数面板左右留边：比胶囊略宽，读起来是「浮在胶囊上的窗口」而不是贴边抽屉。
    static let floatingPanelInset: CGFloat = 12
    static let drawerMin: CGFloat = 234
    static let drawerMid: CGFloat = 468
    static let drawerMax: CGFloat = 560
}

/// 设备安全区与可用画布：换机型后所有页面都按真实值排版，不再写死 393×852。
struct MSafeInsets: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    var size: CGSize

    var width: CGFloat { size.width }
    var height: CGFloat { size.height }
    var contentHeight: CGFloat { max(1, size.height - top - bottom) }

    static let fallback = MSafeInsets(
        top: MMetric.safeTopFallback,
        bottom: MMetric.safeBottomFallback,
        size: CGSize(width: 393, height: 852)
    )
}

private struct MSafeInsetsKey: EnvironmentKey {
    static let defaultValue = MSafeInsets.fallback
}

extension EnvironmentValues {
    var mSafeInsets: MSafeInsets {
        get { self[MSafeInsetsKey.self] }
        set { self[MSafeInsetsKey.self] = newValue }
    }
}

// MARK: - 自适应布局
//
// iPad 横屏走左右分栏（左画布 / 右参数），竖屏与分屏（宽度小于高度）保持 iPhone 的单列布局。
// 判断只看当前真实窗口尺寸，不解析机型：分屏、台前调度、旋转都能自然切换。

enum MLayout {
    static var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    /// 横屏且画布放得下三栏时才分栏；接近手机竖屏比例的竖条窗口、
    /// 以及台前调度那种挤不下左右轨的小横窗，一律退回 iPhone 的单列布局。
    /// 判断只看当前真实窗口尺寸，不解析机型：分屏、台前调度、旋转都能自然切换。
    /// `--force-split` 为截图验收用：在竖屏窗口上也强制走分栏版式。
    static func usesSplit(_ size: CGSize) -> Bool {
        if DebugLaunch.forceSplit { return true }
        let size = DebugLaunch.windowOverride ?? size
        guard isPad, size.width > size.height * 1.02 else { return false }
        // 左轨 + 右栏之外要给画布留出最小宽度，放不下就别硬分。
        let canvas = size.width - inspectorWidth(for: size) - sideRailWidth(for: size)
        return size.width >= 800 && size.height >= 640 && canvas >= 470
    }

    /// 分栏右栏宽度：随屏宽增长，但给画布留足空间。
    static func inspectorWidth(for size: CGSize) -> CGFloat {
        min(430, max(330, size.width * 0.34))
    }

    /// 分栏左轨宽度（胶片相纸 / LUT 预设）：参考 macOS 的侧栏比例，触控目标不放太小。
    static func sideRailWidth(for size: CGSize) -> CGFloat {
        min(320, max(250, size.width * 0.21))
    }

    /// 主页网格列数：按可用宽度决定，iPad 横屏不再固定两列。
    static func gridColumns(for width: CGFloat) -> Int {
        if width >= 1180 { return 5 }
        if width >= 980 { return 4 }
        if width >= 720 { return 3 }
        return 2
    }
}

/// 真实屏幕度量：整屏尺寸 + 安全区。
///
/// 不能从 `GeometryReader.safeAreaInsets` 取——根视图一旦 `ignoresSafeArea()`
/// 填满全屏，代理就会报 0。这里直接读窗口的真实几何，只读一次。
enum MScreenMetrics {
    static func current() -> MSafeInsets {
        #if os(iOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
        guard let window else { return .fallback }
        let insets = window.safeAreaInsets
        return MSafeInsets(top: insets.top, bottom: insets.bottom, size: window.bounds.size)
        #else
        return .fallback
        #endif
    }
}

// MARK: - 字体

extension Font {
    /// 全局使用苹方：中文与数字都走同一套字族，不再混 SF Pro。
    static func mSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(pingFangName(weight), size: size)
    }

    static func mSerif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom(pingFangName(weight), size: size)
    }

    private static func pingFangName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "PingFangSC-Ultralight"
        case .thin: return "PingFangSC-Thin"
        case .light: return "PingFangSC-Light"
        case .medium: return "PingFangSC-Medium"
        case .semibold, .bold, .heavy, .black: return "PingFangSC-Semibold"
        default: return "PingFangSC-Regular"
        }
    }

    static let pageTitle = Font.mSerif(30, .semibold)
    static let navTitle = Font.mSans(13, .semibold)
    static let rowLabel = Font.mSans(12.5)
    static let bodyText = Font.mSans(12)
    static let caption = Font.mSans(10.5)
    static let micro = Font.mSans(9, .medium)
    static let readout = Font.mSans(10.5, .medium).monospacedDigit()
    static let groupLabel = Font.mSans(9.5, .semibold)
    static let button = Font.mSans(12, .medium)
}

extension View {
    /// 小字距的全大写标签，欧创的“样张说明”语气。
    func mLabel(_ size: CGFloat = 9.5, color: Color = MColor.text3) -> some View {
        self.font(.mSans(size, .semibold))
            .tracking(1.35)
            .foregroundStyle(color)
    }

    func mMeta(_ size: CGFloat = 10, color: Color = MColor.text3) -> some View {
        self.font(.mSans(size, .medium).monospacedDigit())
            .foregroundStyle(color)
    }

    func mHairlineOverlay(_ radius: CGFloat, color: Color = MColor.hairline) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color, lineWidth: 1)
        )
    }
}

// MARK: - 动效

enum MMotion {
    static let push = Animation.spring(response: 0.38, dampingFraction: 0.9)
    static let drawer = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// 弹窗上弹：阻尼更低，收尾带一点回弹。
    static let pill = Animation.spring(response: 0.42, dampingFraction: 0.66)
    static let state = Animation.easeOut(duration: 0.2)
    static let quick = Animation.easeOut(duration: 0.14)
    static let press = Animation.easeOut(duration: 0.16)
    /// 预览画布的缩放 / 归位：系统相册同款弹簧，收尾带一点回弹。
    static let canvas = Animation.spring(response: 0.4, dampingFraction: 0.86)
}

// MARK: - 预览调试参数

enum DebugLaunch {
    private static let args = ProcessInfo.processInfo.arguments

    static var showSheet: Bool { args.contains("--sheet") }
    static var exportOpen: Bool { args.contains("--export") }
    /// 截图验收用：iPadOS 27 模拟器窗口模式禁止程序化转向，用这个参数在竖屏上直接验收分栏版式。
    static var forceSplit: Bool { args.contains("--force-split") }
    /// 截图验收用：假装窗口是给定的逻辑尺寸（`--window 1024x768`），验证台前调度小窗下的单列回退。
    static var windowOverride: CGSize? {
        guard let index = args.firstIndex(of: "--window"), args.indices.contains(index + 1) else {
            return nil
        }
        let parts = args[index + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
    /// 截图验收用：等原片读完（`canExport` 为真）后自动开跑导出，好截到「导出中」的进度行。
    static var exportAutoStart: Bool { args.contains("--export-run") }
    /// 截图验收用：调色「调整」面板默认从底部开始，好截到「质感」分区。
    static var gradePanelBottom: Bool { args.contains("--grade-bottom") }
    /// 截图验收用：显影「细节」专业页默认滚到底部，好截到输入/输出分组。
    static var developPanelBottom: Bool { args.contains("--detail-bottom") }
    /// 机型矩阵验收用：启动时把真实安全区与推导出的开孔矩形打到日志（`log show` 可读）。
    static var probeGeometry: Bool { args.contains("--probe-geometry") }

    /// 强制开孔形态。真机按安全区高度自动判断（`MHousing.detect`）；
    /// `--housing notch|island|none` 用来在任意机型上强制跑某一分支做视觉验收。
    static var housingOverride: MHousingKind {
        guard let index = args.firstIndex(of: "--housing"), args.indices.contains(index + 1) else {
            return .auto
        }
        switch args[index + 1] {
        case "notch": return .notch
        case "island": return .island
        case "none": return .none
        default: return .auto
        }
    }

    static var modePro: Bool {
        guard let index = args.firstIndex(of: "--mode"), args.indices.contains(index + 1) else { return false }
        return args[index + 1] == "pro"
    }

    static var gradeTab: Int {
        guard let index = args.firstIndex(of: "--tab"), args.indices.contains(index + 1) else { return 1 }
        switch args[index + 1] {
        case "presets": return 0
        case "color": return 2
        case "texture": return 3
        case "border": return 4
        case "curve": return 1
        default: return 1
        }
    }

    static var developPage: Int {
        guard let index = args.firstIndex(of: "--page"), args.indices.contains(index + 1) else { return 0 }
        switch args[index + 1] {
        case "film": return 1
        case "tone": return 2
        case "color": return 3
        case "detail": return 4
        default: return 0
        }
    }

    /// 截图验收用：直接以指定缩放启动画布，检查放大后照片是否延伸到顶栏与抽屉下面。
    static var canvasZoom: CGFloat {
        guard let index = args.firstIndex(of: "--zoom"), args.indices.contains(index + 1),
              let value = Double(args[index + 1]) else { return 1 }
        return CGFloat(min(max(value, 1), 4))
    }

    /// 截图验收用：给画布一个初始纵向偏移，检查玻璃抽屉后面确实透出照片而不是实色。
    static var canvasPanY: CGFloat {
        guard let index = args.firstIndex(of: "--pan-y"), args.indices.contains(index + 1),
              let value = Double(args[index + 1]) else { return 0 }
        return CGFloat(value)
    }

    /// 预览用：直接以指定抽屉档位启动，方便检查不同高度下的排版。
    static var developDrawer: CGFloat {
        guard let index = args.firstIndex(of: "--drawer"), args.indices.contains(index + 1) else {
            return MMetric.drawerMin
        }
        switch args[index + 1] {
        case "mid": return MMetric.drawerMid
        case "max": return MMetric.drawerMax
        default: return MMetric.drawerMin
        }
    }

    /// 截图验收用：启动时直接套用某个片边预设，检查调色台预览/导出。
    static var gradeBorder: String? {
        guard let index = args.firstIndex(of: "--border"), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}

// MARK: - 面板高度测量
//
// 抽屉要按当前 tab 的内容高度自适应：内容在最小档放得下就锁死一档，否则二档刚好收纳全部内容。

struct MPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MPanelHeightReporter: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: MPanelHeightKey.self, value: geo.size.height)
        }
    }
}

// MARK: - 触感
enum MHaptic {
    static func tick() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

// MARK: - 图片
