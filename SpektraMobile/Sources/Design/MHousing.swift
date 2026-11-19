import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 顶部开孔形态：灵动岛 / 刘海 / 没有开孔。
enum MHousingKind: String {
    case island
    case notch
    case none
    case auto
}

private struct MHousingKey: EnvironmentKey {
    static let defaultValue: MHousingKind = .auto
}

extension EnvironmentValues {
    var mHousing: MHousingKind {
        get { self[MHousingKey.self] }
        set { self[MHousingKey.self] = newValue }
    }
}

enum MDeviceHousing {
    /// 显式指定优先（宿主预览用）；真机上按顶部安全区和机型判断。
    static func resolved(_ explicit: MHousingKind) -> MHousingKind {
        if explicit != .auto { return explicit }
        #if os(iOS)
        return detect()
        #else
        return .island
        #endif
    }

    /// 开孔矩形。
    ///
    /// 灵动岛与刘海都是**硬件常数**，不该从安全区反推：
    /// - 灵动岛：126×37，距顶 11，水平居中（14 Pro 起各代一致）。
    /// - 刘海：高度全代一致（≈5.3mm ≈ 32pt）；宽度分两档——
    ///   13/14 代 26mm（窄刘海），X–12 代 35mm（宽刘海）。
    ///   点值换算 = 毫米 × ppi ÷ 3 ÷ 25.4（@3x）。
    ///
    /// 早先按 `top − 15` 与 `5 × 高` 推导，只在 13 Pro Max 上碰巧接近，其余机型都是错的：
    /// - iPhone 11（top 44）算成 145×29，真实约 210×32 —— 横向差 65pt，照片会落在刘海两侧；
    /// - 13 mini（top 50）算成 175×35，每个侧边各胖 6pt；
    /// - 13 Pro Max（top 47）算成 160×32，真实 156×32 —— 每个侧边仍宽 2pt。
    static func opening(kind: MHousingKind, insets: MSafeInsets) -> CGRect {
        let width = max(1, insets.width)
        switch kind {
        case .island, .auto:
            let islandWidth = min(126, width * 0.9)
            return CGRect(
                x: (width - islandWidth) / 2,
                y: 11,
                width: islandWidth,
                height: 37
            )
        case .notch:
            let notchWidth = self.notchWidth(screenWidth: width)
            return CGRect(
                x: (width - notchWidth) / 2,
                y: 0,
                width: notchWidth,
                height: 32
            )
        case .none:
            return CGRect(x: (width - 90) / 2, y: 0, width: 90, height: 3)
        }
    }

    /// 刘海宽度：按机型给出代际常数，不再用「屏宽 × 比例」猜。
    /// 数值 = 开孔物理宽度（26mm / 35mm）× 该机型每毫米点值（ppi ÷ 3 ÷ 25.4）。
    private static func notchWidth(screenWidth: CGFloat) -> CGFloat {
        guard let id = machineID() else {
            // 模拟器（machine 返回 arm64 / x86_64）与未知机型：两代差异太大，
            // 取 13 代比例——照片边缘溢到刘海两侧比欠一点更刺眼。
            return min(157, screenWidth * 0.40)
        }
        switch id {
        // ── 13 / 14 代：26mm 窄刘海 ──
        case "iPhone14,4":                                 return 162   // 13 mini（476ppi）
        case "iPhone14,2", "iPhone14,5", "iPhone14,7":     return 157   // 13 / 13 Pro / 14（460ppi）
        case "iPhone14,3", "iPhone14,8":                   return 156   // 13 Pro Max / 14 Plus（458ppi）
        case "iPhone17,5":                                 return 157   // 16e（6.1" 460ppi，刘海非灵动岛）
        // ── X–12 代：35mm 宽刘海 ──
        case "iPhone10,3", "iPhone10,6", "iPhone11,2",     // X / XS
             "iPhone11,4", "iPhone11,6",                   // XS Max
             "iPhone12,3", "iPhone12,5",                   // 11 Pro / 11 Pro Max
             "iPhone13,4":                                 return 210   // 12 Pro Max（458ppi）
        case "iPhone13,1":                                 return 219   // 12 mini（476ppi）
        case "iPhone13,2", "iPhone13,3":                   return 211   // 12 / 12 Pro（460ppi）
        case "iPhone11,8", "iPhone12,1":                   return 225   // XR / 11（326ppi @2x）
        default:                                           return min(157, screenWidth * 0.40)
        }
    }

    /// 机型标识（`uname().machine`，与 `sysctlbyname("hw.machine")` 同源）。
    /// 形态与刘海宽度都以此为准：这是硬件事实，不受显示缩放 / 辅助功能影响。
    private static func machineID() -> String? {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.hasPrefix("iPhone") ? identifier : nil
    }

    #if os(iOS)
    /// 按机型标识判断形态（硬件事实，不受显示缩放影响）。
    /// 取不到机型标识（模拟器 / 未知设备）时才回退到安全区高度。
    ///
    /// 机型的分界是硬件代际，不是安全区数值：
    /// - iPhone 14 Pro（iPhone15,2/15,3）及以后 → 灵动岛
    /// - iPhone X–14 / 14 Plus → 刘海
    /// - iPhone 8 及更早 / SE 全系 → 无开孔
    ///
    /// 为什么不能只看安全区：灵动岛机型开启「显示缩放 → 更大文本」后
    /// `safeAreaInsets.top` 会从 59 掉到 51，纯按高度会被误判成刘海。
    private static func detect() -> MHousingKind {
        // iPad 没有开孔。
        if UIDevice.current.userInterfaceIdiom == .pad { return .none }
        if let id = machineID() { return formFactor(for: id) }

        // 回退：模拟器上 machineID() 返回宿主架构，解析不到 iPhone 型号。
        // 模拟器跑的是默认显示缩放，灵动岛 top=59、刘海 top≤50，阈值 52 能分开。
        // 真机不走这里——真机按机型判，大文本模式的 top≈51 也能正确识别为灵动岛。
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
            let window = scene.windows.first else { return .none }
        let top = window.safeAreaInsets.top
        if top <= 20 { return .none }
        if top < 52 { return .notch }
        return .island
    }

    /// 机器码 → 形态。用前缀数字分组，新增机型无需改这里。
    private static func formFactor(for id: String) -> MHousingKind {
        // 无开孔：Touch ID 机型 + SE 全系。
        let noNotch: Set<String> = [
            "iPhone7,1", "iPhone7,2",                              // 6 / 6 Plus
            "iPhone8,1", "iPhone8,2", "iPhone8,4",                 // 6s / 6s+ / SE1
            "iPhone9,1", "iPhone9,2", "iPhone9,3", "iPhone9,4",   // 7 / 7+
            "iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5", // 8 / 8+
            "iPhone12,8", "iPhone14,6"                             // SE2 / SE3
        ]
        if noNotch.contains(id) { return .none }

        // 「e」系列排在当代数字里但沿用刘海：16e 机型码 iPhone17,5，
        // 用 series >= 15 一刀切会被判成灵动岛，开孔底边从 32 跳到 48，
        // 吸入的吞噬线和落点会整体下移 16pt。这类机型只能显式列举。
        let notchInModernSeries: Set<String> = ["iPhone17,5"]
        if notchInModernSeries.contains(id) { return .notch }

        guard let head = id.split(separator: ",").first,
              let series = Int(head.dropFirst("iPhone".count)) else { return .notch }
        // iPhone15,x 起是 14 Pro/Pro Max（灵动岛首代），此后全系灵动岛。
        return series >= 15 ? .island : .notch
    }
    #endif
}
