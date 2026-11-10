import AppKit
import SwiftUI

@main
struct SpektraMobilePreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DeviceShell()
                .frame(width: 445, height: 944)
                .preferredColorScheme(.dark)
                .background(Color(hex: 0x070606))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 445, height: 944)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.title = "Spektrafilm iOS Preview"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(srgbRed: 7 / 255, green: 6 / 255, blue: 6 / 255, alpha: 1)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.setContentSize(NSSize(width: 445, height: 944))
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - 设备外壳

struct DeviceShell: View {
    private var housing: MHousingKind {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--housing"), args.indices.contains(index + 1) {
            switch args[index + 1] {
            case "notch": return .notch
            case "none": return .none
            default: return .island
            }
        }
        return .island
    }

    var body: some View {
        let housing = housing
        return VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 58, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x4A4438),
                                Color(hex: 0x15120E),
                                Color(hex: 0x2C2820),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 417, height: 876)
                    .shadow(color: .black.opacity(0.6), radius: 28, y: 16)

                RoundedRectangle(cornerRadius: 54, style: .continuous)
                    .fill(Color(hex: 0x080706))
                    .frame(width: 409, height: 868)

                RoundedRectangle(cornerRadius: 52, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    .frame(width: 410, height: 869)
                    .allowsHitTesting(false)

                ZStack {
                    MobileRootView()
                        .environment(\.mHousing, housing)
                        .frame(width: 393, height: 852)
                        .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
                        .focusEffectDisabled()

                    DeviceChrome(housing: housing)
                        .frame(width: 393, height: 852)
                        .clipShape(RoundedRectangle(cornerRadius: 46, style: .continuous))
                        .allowsHitTesting(false)
                }
                .frame(width: 393, height: 852)
                .overlay(
                    RoundedRectangle(cornerRadius: 46, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                Circle().fill(MColor.brass).frame(width: 4, height: 4)
                Text("SPEKTRAFILM · iOS 393 × 852")
                    .font(.mSans(8.5, .semibold))
                    .tracking(2.0)
                    .foregroundStyle(MColor.text4)
            }
        }
        .padding(.vertical, 22)
        .frame(width: 445, height: 944)
        .background(Color(hex: 0x070606))
    }
}

// MARK: - 状态栏与指示条

struct DeviceChrome: View {
    var housing: MHousingKind = .island

    var body: some View {
        VStack {
            ZStack(alignment: .top) {
                HStack {
                    Text("9:41")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MColor.text1)

                    Spacer()

                    HStack(spacing: 6) {
                        signalBars
                        Text("5G")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MColor.text1)
                        battery
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 17)

                if housing == .island {
                    island
                } else if housing == .notch {
                    notch
                }
            }
            .frame(height: 54)

            Spacer()
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.white.opacity(0.72))
                .frame(width: 138, height: 5)
                .padding(.bottom, 8)
        }
    }

    private var island: some View {
        Capsule()
            .fill(Color.black)
            .frame(width: 124, height: 36)
            .overlay(alignment: .trailing) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: 0x1B2A33))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().fill(Color(hex: 0x35566B)).frame(width: 3, height: 3))
                        .padding(.trailing, 12)
                }
            }
            .padding(.top, 10)
    }

    private var notch: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 18,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        .frame(width: 162, height: 33)
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: 0x1B2A33))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().fill(Color(hex: 0x35566B)).frame(width: 3, height: 3))
                    .padding(.trailing, 16)
            }
        }
    }

    private var signalBars: some View {
        HStack(alignment: .bottom, spacing: 1.6) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(index == 3 ? MColor.text1 : MColor.text1.opacity(0.9))
                    .frame(width: 2.6, height: CGFloat(4 + index * 2))
            }
        }
        .frame(height: 10, alignment: .bottom)
    }

    private var battery: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.4, style: .continuous)
                    .strokeBorder(MColor.text1.opacity(0.45), lineWidth: 1)
                    .frame(width: 24, height: 12)

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MColor.text1)
                    .frame(width: 17, height: 8)
                    .padding(.leading, 3)
            }

            RoundedRectangle(cornerRadius: 1)
                .fill(MColor.text1.opacity(0.45))
                .frame(width: 1.6, height: 4)
        }
    }
}
