import SwiftUI

/// iOS 真机 / 模拟器入口。macOS 宿主预览走 `Host/PreviewApp.swift`，两者互不参与对方的编译。
@main
struct SpektraMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .task { Self.forceLandscapeIfNeeded() }
        }
    }

    /// 截图验收用：`--landscape` 把场景强制转到横屏，好在没有 GUI 旋转能力的模拟器上验收 iPad 分栏。
    private static func forceLandscapeIfNeeded() {
        #if os(iOS)
        guard ProcessInfo.processInfo.arguments.contains("--landscape") else { return }
        Task { @MainActor in
            for _ in 0..<20 {
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                        NSLog("LandscapeRequest failed: \(error.localizedDescription)")
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        #endif
    }
}
