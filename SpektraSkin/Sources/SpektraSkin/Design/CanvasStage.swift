import SwiftUI
import AppKit

// MARK: - 画布手势层

/// 显影台与调色台共用的画布交互：滚轮/触控板缩放、拖拽平移、双击或空格回正。
struct CanvasInteractionLayer: NSViewRepresentable {
    var onZoom: (CGFloat) -> Void
    var onPan: (CGSize) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> CanvasEventView {
        let view = CanvasEventView()
        view.onZoom = onZoom
        view.onPan = onPan
        view.onReset = onReset
        return view
    }

    func updateNSView(_ view: CanvasEventView, context: Context) {
        view.onZoom = onZoom
        view.onPan = onPan
        view.onReset = onReset
    }
}

final class CanvasEventView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onReset: (() -> Void)?

    private var lastPoint: NSPoint?
    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installKeyMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeKeyMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        removeKeyMonitor()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 6
        guard abs(delta) > 0 else { return }
        onZoom?(CGFloat(exp(Double(delta) / 260.0)))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        lastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lastPoint else {
            self.lastPoint = point
            return
        }
        onPan?(CGSize(width: point.x - lastPoint.x, height: point.y - lastPoint.y))
        self.lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func installKeyMonitorIfNeeded() {
        guard window != nil, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.keyCode == 49, !event.isARepeat,
                  !self.isHiddenOrHasHiddenAncestor,
                  !self.isEditingText(in: self.window) else {
                return event
            }
            self.onReset?()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 保存预设等输入框聚焦时，空格必须留给文本输入。
    private func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
    }
}

// MARK: - 预览工具条

struct SkinPreviewToolbar: View {
    @Binding var zoom: CGFloat
    @Binding var rotation: Double
    @Binding var pan: CGSize
    var compare: Binding<Bool>? = nil

    let previewScale: Double
    let onScaleChanged: (Double) -> Void
    let onReRender: () -> Void

    private var renderScaleLabel: String {
        switch previewScale {
        case ..<0.2: return "1/8"
        case ..<0.4: return "1/4"
        case ..<0.8: return "1/2"
        default: return "1/1"
        }
    }

    private var zoomLabel: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach([0.125, 0.25, 0.5, 1.0], id: \.self) { value in
                    Button(scaleTitle(value)) { onScaleChanged(value) }
                }
            } label: {
                ToolbarLabel(title: renderScaleLabel, chevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            divider

            if let compare {
                ToolbarTextButton(
                    title: "对比",
                    icon: "rectangle.split.2x1",
                    active: compare.wrappedValue
                ) {
                    withAnimation(SkinMotion.state) { compare.wrappedValue.toggle() }
                }
            }

            ToolbarTextButton(title: "渲染") { onReRender() }

            SkinVerticalHairline(color: SkinColor.hairlineStrong, height: 14)
                .padding(.horizontal, 3)

            SkinIconButton("rotate.left", size: 12, frame: 26) {
                withAnimation(SkinMotion.state) { rotation -= 90 }
            }
            SkinIconButton("rotate.right", size: 12, frame: 26) {
                withAnimation(SkinMotion.state) { rotation += 90 }
            }
            SkinIconButton("arrow.up.left.and.arrow.down.right", size: 12, frame: 26) {
                resetView()
            }

            Menu {
                Button("适应窗口") { resetView() }
                ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { value in
                    Button("\(Int(value * 100))%") {
                        withAnimation(SkinMotion.state) {
                            zoom = CGFloat(value)
                            pan = .zero
                        }
                    }
                }
            } label: {
                ToolbarLabel(title: zoomLabel, chevron: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SkinColor.surface1.opacity(0.94))
                .shadow(color: .black.opacity(0.36), radius: 16, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
        )
    }

    private func resetView() {
        withAnimation(SkinMotion.state) {
            zoom = 1
            pan = .zero
        }
    }

    private func scaleTitle(_ value: Double) -> String {
        switch value {
        case 0.125: return "渲染 1/8"
        case 0.25: return "渲染 1/4"
        case 0.5: return "渲染 1/2"
        default: return "渲染 1/1"
        }
    }

    private var divider: some View {
        SkinVerticalHairline(color: SkinColor.hairlineStrong, height: 14)
            .padding(.horizontal, 3)
    }
}

private struct ToolbarLabel: View {
    let title: String
    var chevron: Bool = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.skin(10.5, .medium))
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .medium))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(hovered ? SkinColor.text1 : SkinColor.text2)
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? SkinColor.wash : .clear)
        )
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}

private struct ToolbarTextButton: View {
    let title: String
    var icon: String?
    var chevron: Bool = false
    var active: Bool = false
    var action: () -> Void = {}

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title)
                    .font(.skin(10.5, .medium))
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .medium))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(active ? SkinColor.accent : (hovered ? SkinColor.text1 : SkinColor.text2))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? SkinColor.accent.opacity(0.10) : (hovered ? SkinColor.wash : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}
