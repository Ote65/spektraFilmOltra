import SwiftUI

/// iOS 真机 / 模拟器入口。macOS 宿主预览走 `Host/PreviewApp.swift`，两者互不参与对方的编译。
@main
struct SpektraMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
