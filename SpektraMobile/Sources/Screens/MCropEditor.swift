import CoreGraphics
import SwiftUI

/// 调色台的裁切与校正页。
/// 数据流：取景底图（完整交接图调色结果）→ 本页几何预览 → 完成后交给调色台，
/// 片边在裁切完成后才合成，所以裁切永远只裁照片本身。
struct MCropEditor: View {
    let base: CGImage
    let initial: MPhotoGeometry
    let onCancel: () -> Void
    let onDone: (MPhotoGeometry) -> Void

    @State private var draft: MPhotoGeometry
    @State private var tool: MTool = .crop
    @State private var ratio: MRatio = .original
    @StateObject private var preview: MCropPreviewRenderer

    init(base: CGImage, initial: MPhotoGeometry,
         onCancel: @escaping () -> Void, onDone: @escaping (MPhotoGeometry) -> Void) {
        self.base = base
        self.initial = initial
        self.onCancel = onCancel
        self.onDone = onDone
        _draft = State(initialValue: initial)
        _ratio = State(initialValue: initial.hasCrop ? .free : .original)
        _preview = StateObject(wrappedValue: MCropPreviewRenderer(base: base))
    }

    private var baseAspect: CGFloat {
        CGFloat(base.width) / CGFloat(max(1, base.height))
    }

    /// 方向变换后的像素长宽比（奇数次 90° 旋转会翻转）。
    private var orientedAspect: CGFloat {
        draft.quarterTurns % 2 == 0 ? baseAspect : 1 / baseAspect
    }

    private var previewAspect: CGFloat {
        guard let image = preview.image else { return orientedAspect }
        return CGFloat(image.width) / CGFloat(max(1, image.height))
    }

    private var lockedRatio: CGFloat? {
        ratio.value(orientedAspect: orientedAspect)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controlPanel
                toolBar
            }
            .background(MColor.app.ignoresSafeArea())
            .navigationTitle("裁切")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(MColor.app, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .foregroundStyle(MColor.text2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(draft.normalized()) }
                        .fontWeight(.semibold)
                        .foregroundStyle(MColor.brass)
                }
            }
            .tint(MColor.brass)
        }
        .preferredColorScheme(.dark)
        .onAppear { preview.render(draft) }
        .onChange(of: draft) { _, value in preview.render(value) }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { proxy in
            let rect = MImageFit.rect(aspect: previewAspect, in: proxy.size, horizontalPadding: 18)
            ZStack {
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    MCropFrame(
                        imageRect: rect,
                        crop: Binding(get: { draft.crop }, set: { draft.crop = $0 }),
                        pixelRatio: lockedRatio,
                        orientedAspect: orientedAspect
                    )
                } else {
                    ProgressView()
                        .tint(MColor.brass)
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: - 参数区

    @ViewBuilder
    private var controlPanel: some View {
        Group {
            switch tool {
            case .crop:
                ratioBar
            case .straighten:
                rulerPanel(title: "水平", value: $draft.straighten,
                           range: -45...45, step: 0.1, suffix: "°")
            case .perspective:
                perspectivePanel
            case .flip:
                flipPanel
            }
        }
        .frame(height: 116)
    }

    private var ratioBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MRatio.allCases) { item in
                    Button {
                        apply(ratio: item)
                    } label: {
                        Text(item.title)
                            .font(.mSans(12, .medium))
                            .foregroundStyle(ratio == item ? MColor.brassInk : MColor.text2)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(
                                Capsule().fill(ratio == item
                                               ? MColor.brass
                                               : Color.white.opacity(0.06))
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    Color.white.opacity(ratio == item ? 0 : 0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(MPressStyle(scale: 0.96))
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rulerPanel(title: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.mSans(11, .medium))
                    .foregroundStyle(MColor.text3)
                Text(formatted(value.wrappedValue, suffix: suffix))
                    .font(.mSans(13, .medium).monospacedDigit())
                    .foregroundStyle(MColor.text1)
                Spacer()
                Button("复位") {
                    withAnimation(MMotion.state) { value.wrappedValue = 0 }
                }
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text3)
            }
            .padding(.horizontal, 20)

            MTickRuler(range: range, step: step, value: value, haptics: true)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var perspectivePanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("透视纠正")
                    .font(.mSans(11, .medium))
                    .foregroundStyle(MColor.text3)
                Spacer()
                Button("复位") {
                    withAnimation(MMotion.state) {
                        draft.perspectiveV = 0
                        draft.perspectiveH = 0
                    }
                }
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text3)
            }
            .padding(.horizontal, 20)

            perspectiveRow(title: "垂直", value: $draft.perspectiveV)
            perspectiveRow(title: "水平", value: $draft.perspectiveH)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func perspectiveRow(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.mSans(10, .medium))
                .foregroundStyle(MColor.text3)
                .frame(width: 26, alignment: .leading)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.mSans(10, .medium).monospacedDigit())
                .foregroundStyle(MColor.text2)
                .frame(width: 30, alignment: .trailing)
            MTickRuler(range: -100...100, step: 1, value: value, haptics: true)
        }
        .padding(.horizontal, 20)
    }

    private var flipPanel: some View {
        HStack(spacing: 12) {
            flipButton(title: "水平翻转", icon: "flip.horizontal",
                       active: draft.flippedH) { draft.flippedH.toggle() }
            flipButton(title: "垂直翻转", icon: "flip.horizontal", rotation: 90,
                       active: draft.flippedV) { draft.flippedV.toggle() }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func flipButton(title: String, icon: String, rotation: Double = 0,
                            active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .rotationEffect(.degrees(rotation))
                Text(title)
                    .font(.mSans(12, .medium))
            }
            .foregroundStyle(active ? MColor.brass : MColor.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(active ? MColor.brass.opacity(0.14) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(active ? MColor.brass.opacity(0.55)
                                         : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(MPressStyle(scale: 0.97))
    }

    // MARK: - 工具栏

    private var toolBar: some View {
        HStack(spacing: 0) {
            toolButton(.crop, icon: "crop", title: "裁切")
            toolButton(.straighten, icon: "angle", title: "水平")
            toolButton(.perspective, icon: "perspective", title: "透视")
            toolButton(.flip, icon: "flip.horizontal", title: "镜像")
            instantButton(icon: "rotate.right", title: "旋转", action: rotateClockwise)
            instantButton(icon: "arrow.counterclockwise", title: "重置", action: reset)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(MColor.surface1)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.055)).frame(height: 0.5)
        }
    }

    private func toolButton(_ item: MTool, icon: String, title: String) -> some View {
        Button {
            withAnimation(MMotion.state) { tool = item }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.mSans(9.5, .medium))
            }
            .foregroundStyle(tool == item ? MColor.brass : MColor.text3)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tool == item ? MColor.brass.opacity(0.13) : Color.clear)
            )
        }
        .buttonStyle(MPressStyle(scale: 0.95))
    }

    private func instantButton(icon: String, title: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.mSans(9.5, .medium))
            }
            .foregroundStyle(MColor.text3)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .buttonStyle(MPressStyle(scale: 0.95))
    }

    // MARK: - 动作

    private func apply(ratio item: MRatio) {
        ratio = item
        guard let value = item.value(orientedAspect: orientedAspect) else { return }
        let crop = Self.centeredCrop(ratio: value, orientedAspect: orientedAspect)
        withAnimation(MMotion.state) { draft.crop = crop }
    }

    private func rotateClockwise() {
        MHaptic.tick()
        var rotated = draft.rotatedClockwise()
        let aspect = rotated.quarterTurns % 2 == 0 ? baseAspect : 1 / baseAspect
        // 原始比例与自由格式的取景框转过来仍然合法，保留用户已经拉好的框；
        // 固定比例（正方形/16:9…）转 90° 后比例会变成倒数，只能重新居中。
        if ratio != .free, ratio != .original,
           let value = ratio.value(orientedAspect: aspect) {
            rotated.crop = Self.centeredCrop(ratio: value, orientedAspect: aspect)
        }
        withAnimation(MMotion.state) { draft = rotated }
    }

    private func reset() {
        MHaptic.tick()
        withAnimation(MMotion.state) {
            draft = MPhotoGeometry()
            ratio = .original
            tool = .crop
        }
    }

    private func formatted(_ value: Double, suffix: String) -> String {
        String(format: "%.1f%@", value, suffix)
    }

    static func centeredCrop(ratio: Double, orientedAspect: CGFloat) -> MPhotoGeometry.Crop {
        let aspect = Double(orientedAspect)
        var width = 1.0
        var height = width * aspect / ratio
        if height > 1 {
            height = 1
            width = height * ratio / aspect
        }
        return MPhotoGeometry.Crop(x: (1 - width) / 2, y: (1 - height) / 2,
                                   width: width, height: height)
    }
}

// MARK: - 工具与比例

private enum MTool: Hashable {
    case crop
    case straighten
    case perspective
    case flip
}

private enum MRatio: String, CaseIterable, Identifiable {
    case original
    case free
    case square
    case fourThree
    case threeTwo
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始比例"
        case .free: return "自由格式"
        case .square: return "正方形"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    /// 返回裁切框的像素长宽比；自由格式返回 nil。
    func value(orientedAspect: CGFloat) -> CGFloat? {
        switch self {
        case .original: return orientedAspect
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

// MARK: - 取景框

/// 归一化裁切框 + 手势。坐标全部相对“已校正画面”，与像素渲染同一套映射。
private struct MCropFrame: View {
    let imageRect: CGRect
    @Binding var crop: MPhotoGeometry.Crop
    let pixelRatio: CGFloat?
    let orientedAspect: CGFloat

    @State private var dragOrigin: MPhotoGeometry.Crop?

    private var cropRect: CGRect {
        CGRect(
            x: imageRect.minX + crop.x * imageRect.width,
            y: imageRect.minY + crop.y * imageRect.height,
            width: crop.width * imageRect.width,
            height: crop.height * imageRect.height
        )
    }

    var body: some View {
        ZStack {
            dimming
            grid
            border
            corners

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(0, cropRect.width - 30), height: max(0, cropRect.height - 30))
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(gesture(.move))

            handle(.topLeft, at: CGPoint(x: cropRect.minX, y: cropRect.minY))
            handle(.topRight, at: CGPoint(x: cropRect.maxX, y: cropRect.minY))
            handle(.bottomLeft, at: CGPoint(x: cropRect.minX, y: cropRect.maxY))
            handle(.bottomRight, at: CGPoint(x: cropRect.maxX, y: cropRect.maxY))
            handle(.left, at: CGPoint(x: cropRect.minX, y: cropRect.midY))
            handle(.right, at: CGPoint(x: cropRect.maxX, y: cropRect.midY))
            handle(.top, at: CGPoint(x: cropRect.midX, y: cropRect.minY))
            handle(.bottom, at: CGPoint(x: cropRect.midX, y: cropRect.maxY))
        }
    }

    private var dimming: some View {
        Path { path in
            path.addRect(imageRect)
            path.addRect(cropRect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private var grid: some View {
        Path { path in
            for index in 1...2 {
                let x = cropRect.minX + cropRect.width * CGFloat(index) / 3
                let y = cropRect.minY + cropRect.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: cropRect.minY))
                path.addLine(to: CGPoint(x: x, y: cropRect.maxY))
                path.move(to: CGPoint(x: cropRect.minX, y: y))
                path.addLine(to: CGPoint(x: cropRect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            .frame(width: cropRect.width, height: cropRect.height)
            .position(x: cropRect.midX, y: cropRect.midY)
            .allowsHitTesting(false)
    }

    private var corners: some View {
        ZStack {
            cornerMark(rotation: 0)
                .position(x: cropRect.minX, y: cropRect.minY)
            cornerMark(rotation: 90)
                .position(x: cropRect.maxX, y: cropRect.minY)
            cornerMark(rotation: 180)
                .position(x: cropRect.maxX, y: cropRect.maxY)
            cornerMark(rotation: 270)
                .position(x: cropRect.minX, y: cropRect.maxY)
        }
        .allowsHitTesting(false)
    }

    private func cornerMark(rotation: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 18))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 18, y: 0))
        }
        .stroke(MColor.brass, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        .frame(width: 18, height: 18)
        .rotationEffect(.degrees(rotation))
    }

    private func handle(_ kind: MCropHandle, at point: CGPoint) -> some View {
        let isCorner = kind.isCorner
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: isCorner ? 46 : 34, height: isCorner ? 46 : 34)
            .position(point)
            .gesture(gesture(kind))
    }

    private func gesture(_ kind: MCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = crop }
                guard let origin = dragOrigin else { return }
                crop = Self.adjust(
                    origin, handle: kind,
                    dx: value.translation.width / max(1, imageRect.width),
                    dy: value.translation.height / max(1, imageRect.height),
                    pixelRatio: pixelRatio,
                    orientedAspect: orientedAspect
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// 拖拽解算：固定比例时先锁比例再按锚点收进画面，避免取景框被拖出画布。
    private static func adjust(
        _ origin: MPhotoGeometry.Crop, handle: MCropHandle,
        dx: Double, dy: Double, pixelRatio: CGFloat?, orientedAspect: CGFloat
    ) -> MPhotoGeometry.Crop {
        let minSize = 0.06
        let ratio = pixelRatio.map(Double.init)
        let aspect = Double(orientedAspect)

        if handle == .move {
            let x = min(max(origin.x + dx, 0), 1 - origin.width)
            let y = min(max(origin.y + dy, 0), 1 - origin.height)
            return MPhotoGeometry.Crop(x: x, y: y, width: origin.width, height: origin.height)
        }

        if let ratio {
            let left = handle.touchesLeft
            let right = handle.touchesRight
            let top = handle.touchesTop
            let bottom = handle.touchesBottom
            let centerX = origin.x + origin.width / 2
            let centerY = origin.y + origin.height / 2

            if left || right {
                let anchorX = left ? origin.x + origin.width : origin.x
                let available = left ? anchorX : 1 - anchorX
                var width = left ? origin.width - dx : origin.width + dx
                width = min(max(width, minSize), available)
                var height = width * aspect / ratio
                let anchorY = top ? origin.y + origin.height : origin.y
                let maxHeight: Double
                if top || bottom {
                    maxHeight = top ? anchorY : 1 - anchorY
                } else {
                    maxHeight = 2 * min(centerY, 1 - centerY)
                }
                if height > maxHeight {
                    height = maxHeight
                    width = height * ratio / aspect
                }
                let x = left ? anchorX - width : anchorX
                let y = top ? origin.y + origin.height - height
                    : bottom ? origin.y : centerY - height / 2
                return MPhotoGeometry.Crop(x: x, y: y, width: width, height: height).clamped
            } else {
                let anchorY = top ? origin.y + origin.height : origin.y
                let available = top ? anchorY : 1 - anchorY
                var height = top ? origin.height - dy : origin.height + dy
                height = min(max(height, minSize), available)
                var width = height * ratio / aspect
                let maxWidth = 2 * min(centerX, 1 - centerX)
                if width > maxWidth {
                    width = maxWidth
                    height = width * aspect / ratio
                }
                let x = centerX - width / 2
                let y = top ? anchorY - height : anchorY
                return MPhotoGeometry.Crop(x: x, y: y, width: width, height: height).clamped
            }
        }

        var x = origin.x
        var y = origin.y
        var width = origin.width
        var height = origin.height
        if handle.touchesLeft { x += dx; width -= dx }
        if handle.touchesRight { width += dx }
        if handle.touchesTop { y += dy; height -= dy }
        if handle.touchesBottom { height += dy }

        width = max(width, minSize)
        height = max(height, minSize)
        x = min(max(x, 0), max(0, 1 - width))
        y = min(max(y, 0), max(0, 1 - height))
        return MPhotoGeometry.Crop(x: x, y: y, width: width, height: height).clamped
    }
}

private enum MCropHandle {
    case move
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    var touchesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var touchesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var touchesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var touchesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

// MARK: - 取景预览

/// 裁切页的实时预览：在后台按同一套几何映射重采样，只保留最新一帧。
final class MCropPreviewRenderer: ObservableObject {
    @Published private(set) var image: CGImage?

    private let queue = DispatchQueue(label: "spektra.mobile.crop.preview", qos: .userInitiated)
    private var source: MRGBACopy.Buffer?
    private var last: MPhotoGeometry?
    private var token = 0
    private let maxEdge = 1200

    init(base: CGImage) {
        queue.async { [weak self] in
            guard let buffer = MRGBACopy.read(base) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.source = buffer
                self.render(MPhotoGeometry())
            }
        }
    }

    /// 主线程调用；只比较方向/校正，纯裁切框变化不触发重采样。
    func render(_ geometry: MPhotoGeometry) {
        guard let source else { return }
        let target = geometry.withoutCrop()
        guard target != last else { return }
        last = target
        token += 1
        let current = token
        queue.async { [weak self] in
            let image = target.apply(buffer: source, maxLongEdge: self?.maxEdge ?? 1200)
            DispatchQueue.main.async {
                guard let self, self.token == current else { return }
                self.image = image
            }
        }
    }
}
