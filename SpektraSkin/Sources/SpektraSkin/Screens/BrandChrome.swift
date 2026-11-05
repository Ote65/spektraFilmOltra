import AppKit
import SwiftUI

/// 顶部状态栏的 SpektrafilmOltra 品牌标识：应用图标 + 字标。
struct BrandChrome: View {
    var body: some View {
        HStack(spacing: 6) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text("SPEKTRAFILM")
                .font(.skin(9, .medium))
                .tracking(2.4)
                .foregroundStyle(SkinColor.text4)
        }
    }
}
