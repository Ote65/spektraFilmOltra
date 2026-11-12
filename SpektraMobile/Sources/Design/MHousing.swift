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
    /// 灵动岛是**硬件常数**（14 Pro 起各代一致）：126×37、距顶 11、水平居中。
    /// 早先按 `top − 22` 推导，在 top = 62 的机型上会算出 136×40，比真实开孔每边大 5pt，
    /// 光效看起来比开孔"胖一圈"。刘海则确实是随安全区变化的（13 上推导为 160×32，真值 ≈162×32）。
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
            let height = max(26, insets.top - 15)
            let notchWidth = min(height * 5.0, width * 0.45)
            return CGRect(x: (width - notchWidth) / 2, y: 0, width: notchWidth, height: height)
        case .none:
            return CGRect(x: (width - 90) / 2, y: 0, width: 90, height: 3)
        }
    }

    #if os(iOS)
    /// 只按**实测安全区高度**判断形态，不解析机型标识：
    /// - `machineIdentifier()` 在模拟器上返回宿主架构（arm64），解析失败后被当成灵动岛，
    ///   于是 iPhone 13 / SE 这些机型在模拟器上永远跑不到刘海/无开孔分支；
    /// - 顶部安全区高度是系统按真实屏幕给的值：无开孔 20、刘海 44–50、灵动岛 59–62。
    private static func detect() -> MHousingKind {
        // iPad 没有开孔：横屏安全区顶部约 24pt，按高度判会误命中「刘海」，
        // 于是屏幕上会多出一圈假的刘海光效。平板直接判为无开孔。
        if UIDevice.current.userInterfaceIdiom == .pad { return .none }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
            let window = scene.windows.first else { return .none }
        let top = window.safeAreaInsets.top
        if top <= 20 { return .none }       // iPhone SE / 8 及更早：没有开孔
        if top < 52 { return .notch }       // X–16e 一类的刘海
        return .island                       // 14 Pro 起的灵动岛
    }
    #endif
}
