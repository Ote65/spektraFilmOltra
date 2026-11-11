import SwiftUI
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - 水印配置

enum MWatermarkKind: String, CaseIterable, Identifiable {
    case text
    case image

    var id: String { rawValue }
    var title: String { self == .text ? "文本" : "图形" }
}

enum MWatermarkAlignment: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

/// 水印参数全部存在本地设置里；导出时读同一份配置合成。
struct MWatermarkConfig: Codable, Equatable {
    var enabled: Bool = false
    var kind: String = MWatermarkKind.text.rawValue
    var text: String = "SPEKTRAFILMOLTRA"
    var bold: Bool = true
    var italic: Bool = false
    var alignment: String = MWatermarkAlignment.center.rawValue
    var rotation: Double = 0
    var shadow: Bool = true
    /// 1…10：相对画面短边的字号 / 图形高度档位。
    var size: Double = 4
    /// 0…100
    var opacity: Double = 80
    /// -50…50，按画面宽高百分比换算。
    var offsetX: Double = 0
    var offsetY: Double = 0
    var imageName: String = ""
    var imagePath: String = ""

    var kindValue: MWatermarkKind {
        MWatermarkKind(rawValue: kind) ?? .text
    }

    var alignmentValue: MWatermarkAlignment {
        MWatermarkAlignment(rawValue: alignment) ?? .center
    }

    func normalized() -> MWatermarkConfig {
        var value = self
        value.kind = value.kindValue.rawValue
        value.alignment = value.alignmentValue.rawValue
        value.size = min(max(value.size, 1), 10)
        value.opacity = min(max(value.opacity, 0), 100)
        value.rotation = min(max(value.rotation, -180), 180)
        value.offsetX = min(max(value.offsetX, -50), 50)
        value.offsetY = min(max(value.offsetY, -50), 50)
        value.text = String(value.text.prefix(64))
        return value
    }
}

enum MWatermarkStore {
    private static let key = "mobile.watermark.config"
    private static var pendingSave: DispatchWorkItem?

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Spektrafilm/Watermark", isDirectory: true)
    }

    /// 只存文件名而不是绝对路径：App 更新后容器 UUID 会变，绝对路径会失效。
    static func imageURL(for name: String) -> URL {
        directory.appendingPathComponent((name as NSString).lastPathComponent)
    }

    static func load() -> MWatermarkConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(MWatermarkConfig.self, from: data) else {
            return MWatermarkConfig()
        }
        return decoded.normalized()
    }

    static func save(_ config: MWatermarkConfig) {
        guard let data = try? JSONEncoder().encode(config.normalized()) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 拖动水印时不要每帧写一次偏好；停手一小会儿再落盘。
    static func saveSoon(_ config: MWatermarkConfig) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { save(config) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    static func flush(_ config: MWatermarkConfig) {
        pendingSave?.cancel()
        pendingSave = nil
        save(config)
    }

    /// 把用户选的 PNG 复制进水印目录；只用文件名做后续引用。
    static func importImage(from source: URL) throws -> (name: String, path: String) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let storedName = "watermark-\(UUID().uuidString).\(ext)"
        let target = directory.appendingPathComponent(storedName)
        try FileManager.default.copyItem(at: source, to: target)
        return (source.lastPathComponent, storedName)
    }

    static func removeImage(path: String) {
        guard !path.isEmpty else { return }
        let url = imageURL(for: path)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 导出合成

enum MWatermarkRenderer {
    static func composite(image: ImageRGB, config raw: MWatermarkConfig,
                          colorSpace: String, cctfEncoding: Bool) -> ImageRGB {
        let config = raw.normalized()
        guard config.enabled, config.opacity > 0 else { return image }
        let text = config.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = config.kindValue
        if kind == .text, text.isEmpty { return image }
        let markImage: CGImage?
        if kind == .image {
            markImage = ImageBridge.cgImage(contentsOf: MWatermarkStore.imageURL(for: config.imagePath))
            if markImage == nil { return image }
        } else {
            markImage = nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        // 换成左上角原点，和 SwiftUI 预览保持一致。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let shortSide = CGFloat(min(width, height))
        let center = CGPoint(
            x: CGFloat(width) / 2 + CGFloat(config.offsetX / 100) * CGFloat(width),
            y: CGFloat(height) / 2 + CGFloat(config.offsetY / 100) * CGFloat(height)
        )
        let alpha = CGFloat(min(max(config.opacity, 0), 100) / 100)
        context.setAlpha(alpha)

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(config.rotation) * .pi / 180)
        if config.shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: shortSide * 0.004),
                blur: shortSide * 0.012,
                color: CGColor(gray: 0, alpha: 0.65)
            )
        }
        if let markImage {
            drawImage(markImage, in: context, shortSide: shortSide, size: config.size)
        } else {
            drawText(text, in: context, shortSide: shortSide,
                     config: config)
        }
        context.restoreGState()

        return blend(context: context, width: width, height: height,
                     into: image, colorSpace: colorSpace, cctfEncoding: cctfEncoding)
    }

    // MARK: 文本

    private static func drawText(_ text: String, in context: CGContext,
                                 shortSide: CGFloat, config: MWatermarkConfig) {
        let fontSize = max(8, shortSide * CGFloat(0.012 + config.size * 0.010))
        let fontName = config.bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let tracking = fontSize * 0.04
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return }

        var lineWidths: [CGFloat] = []
        var linesRef: [CTLine] = []
        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking,
            ]
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let lineRef = CTLineCreateWithAttributedString(attributed)
            linesRef.append(lineRef)
            lineWidths.append(CGFloat(CTLineGetTypographicBounds(lineRef, nil, nil, nil)))
        }

        let lineHeight = fontSize * 1.22
        let blockWidth = lineWidths.max() ?? 0
        let blockHeight = lineHeight * CGFloat(lines.count)
        let alignment = config.alignmentValue

        // 斜体：在当前坐标系里做一点剪切，和 SwiftUI 的 synthetic italic 近似。
        if config.italic, blockHeight > 0 {
            context.concatenate(CGAffineTransform(a: 1, b: 0, c: 0.22, d: 1, tx: 0, ty: 0))
        }

        for (index, line) in linesRef.enumerated() {
            let lineWidth = lineWidths[index]
            let x: CGFloat
            switch alignment {
            case .left: x = -blockWidth / 2
            case .center: x = -lineWidth / 2
            case .right: x = blockWidth / 2 - lineWidth
            }
            let baseline = -blockHeight / 2 + fontSize * 0.86 + CGFloat(index) * lineHeight
            context.saveGState()
            context.translateBy(x: x, y: baseline)
            // 外层已经是 y 向下；文字再翻一次，字形才是正的。
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    // MARK: 图片

    private static func drawImage(_ image: CGImage, in context: CGContext,
                                  shortSide: CGFloat, size: Double) {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var height = shortSide * CGFloat(0.04 + size * 0.016)
        height = min(height, CGFloat(image.height))
        let width = height * aspect
        context.saveGState()
        // 外层 y 向下，图片再翻一次，避免导出图上下颠倒。
        context.translateBy(x: 0, y: height / 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: -width / 2, y: 0, width: width, height: height))
        context.restoreGState()
    }

    // MARK: 叠加

    private static func blend(context: CGContext, width: Int, height: Int,
                              into image: ImageRGB, colorSpace: String,
                              cctfEncoding: Bool) -> ImageRGB {
        guard let buffer = context.data else { return image }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let needsConversion = !(colorSpace == "sRGB" && cctfEncoding)
        let sRGBKind = ColorMath.cctfKind(for: "sRGB")
        let outKind = ColorMath.cctfKind(for: colorSpace)
        var cache: [UInt32: Vec3] = [:]
        var output = image

        output.data.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            for index in 0..<(width * height) {
                let alpha = Double(pixels[index * 4 + 3]) / 255.0
                guard alpha > 0 else { continue }
                let invAlpha = 1.0 / alpha
                let channels = (
                    UInt8(min(255, max(0, Double(pixels[index * 4]) * invAlpha))),
                    UInt8(min(255, max(0, Double(pixels[index * 4 + 1]) * invAlpha))),
                    UInt8(min(255, max(0, Double(pixels[index * 4 + 2]) * invAlpha)))
                )
                let converted: Vec3
                if needsConversion {
                    let key = (UInt32(channels.0) << 16) | (UInt32(channels.1) << 8) | UInt32(channels.2)
                    if let cached = cache[key] {
                        converted = cached
                    } else {
                        let linear = Vec3(
                            ColorMath.cctfDecode(Double(channels.0) / 255.0, kind: sRGBKind),
                            ColorMath.cctfDecode(Double(channels.1) / 255.0, kind: sRGBKind),
                            ColorMath.cctfDecode(Double(channels.2) / 255.0, kind: sRGBKind)
                        )
                        var target = ColorMath.rgbToRGB(linear, from: "sRGB", to: colorSpace)
                        if cctfEncoding {
                            target = Vec3(
                                ColorMath.cctfEncode(target.x, kind: outKind),
                                ColorMath.cctfEncode(target.y, kind: outKind),
                                ColorMath.cctfEncode(target.z, kind: outKind)
                            )
                        }
                        converted = target
                        if cache.count < 131_072 { cache[key] = target }
                    }
                } else {
                    converted = Vec3(Double(channels.0) / 255.0,
                                     Double(channels.1) / 255.0,
                                     Double(channels.2) / 255.0)
                }
                let target = index * 3
                let keep = 1.0 - alpha
                dst[target] = Float(converted.x * alpha + Double(dst[target]) * keep)
                dst[target + 1] = Float(converted.y * alpha + Double(dst[target + 1]) * keep)
                dst[target + 2] = Float(converted.z * alpha + Double(dst[target + 2]) * keep)
            }
        }
        return output
    }
}

// MARK: - 预览

/// 编辑页里的水印预览：位置、字号、旋转、透明度都和导出用同一套比例。
struct MWatermarkPreview: View {
    let config: MWatermarkConfig
    let size: CGSize

    var body: some View {
        Group {
            if config.kindValue == .image {
                imagePreview
            } else {
                textPreview
            }
        }
        // 先旋转/透明度，再定位：position 必须最后，否则旋转会绕整个预览框转。
        .rotationEffect(.degrees(config.rotation))
        .opacity(min(max(config.opacity, 0), 100) / 100)
        .position(
            x: size.width / 2 + CGFloat(config.offsetX / 100) * size.width,
            y: size.height / 2 + CGFloat(config.offsetY / 100) * size.height
        )
        .allowsHitTesting(false)
    }

    private var textPreview: some View {
        Group {
            if config.italic {
                watermarkText.italic()
            } else {
                watermarkText
            }
        }
        .multilineTextAlignment(textAlignment)
        // 与导出保持一致：只按换行断行，不让预览自己折行。
        .fixedSize()
        .shadow(
            color: config.shadow ? Color.black.opacity(0.62) : .clear,
            radius: config.shadow ? max(1, shortSide * 0.012) : 0,
            x: 0,
            y: config.shadow ? max(1, shortSide * 0.004) : 0
        )
    }

    private var watermarkText: Text {
        Text(config.text.isEmpty ? " " : config.text)
            .font(.mSans(max(8, shortSide * CGFloat(0.012 + config.size * 0.010)),
                         config.bold ? .semibold : .regular))
            .foregroundStyle(Color.white)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if !config.imagePath.isEmpty,
           let image = MImage.thumbnail(url: MWatermarkStore.imageURL(for: config.imagePath)) {
            let height = min(shortSide * CGFloat(0.04 + config.size * 0.016), size.height)
            MImage.swiftUI(image)
                .resizable()
                .scaledToFit()
                .frame(height: height)
        } else {
            EmptyView()
        }
    }

    private var shortSide: CGFloat { min(size.width, size.height) }

    private var textAlignment: TextAlignment {
        switch config.alignmentValue {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

// MARK: - 水印编辑

struct MWatermarkEditor: View {
    @Binding var config: MWatermarkConfig
    let previewURL: URL?
    let onBack: () -> Void

    @State private var tab: Int
    @State private var showImporter = false
    @State private var dragStart: CGSize?
    @State private var background: MPlatformImage?
    @Environment(\.mSafeInsets) private var insets

    init(config: Binding<MWatermarkConfig>, previewURL: URL?, onBack: @escaping () -> Void) {
        self._config = config
        self.previewURL = previewURL
        self.onBack = onBack
        _tab = State(initialValue: config.wrappedValue.kindValue == .image ? 1 : 0)
    }

    var body: some View {
        ZStack {
            MColor.app
            VStack(spacing: 0) {
                navigationBar
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        tabBar
                        preview
                            .padding(.top, 12)
                        if tab == 0 {
                            textControls
                        } else {
                            imageControls
                        }
                    }
                    .padding(.horizontal, MMetric.pageMargin)
                    .padding(.bottom, insets.bottom + 28)
                }
                .scrollIndicators(.never)
            }
            .padding(.top, insets.top)
        }
        .onAppear(perform: loadBackground)
        .onChange(of: tab) { _, newValue in
            config.kind = newValue == 0
                ? MWatermarkKind.text.rawValue
                : MWatermarkKind.image.rawValue
        }
        .onChange(of: config.text) { _, newValue in
            // 与导出配置的上限保持一致，避免预览完整、导出被截断。
            if newValue.count > 64 {
                config.text = String(newValue.prefix(64))
            }
        }
        .onChange(of: config) { _, newValue in
            MWatermarkStore.saveSoon(newValue)
        }
        .onDisappear {
            MWatermarkStore.flush(config)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image, .png],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text("自定义水印")
                .font(.navTitle)
                .foregroundStyle(MColor.text1)

            HStack {
                MCircleIconButton(icon: "chevron.left", size: 14, frame: 38) {
                    onBack()
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: MMetric.navHeight)
    }

    private var tabBar: some View {
        MUnderlineTabs(titles: ["文本", "图形"], selection: $tab, height: 42)
    }

    // MARK: 预览

    private var preview: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let background {
                    MImage.swiftUI(background)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [Color(hex: 0x3B4348), Color(hex: 0x8A7A62), Color(hex: 0x17130E)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                MWatermarkPreview(config: config, size: size)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRadius.card, style: .continuous)
                    .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = CGSize(width: config.offsetX, height: config.offsetY)
                        }
                        let base = dragStart ?? .zero
                        let dx = Double(value.translation.width / max(1, size.width)) * 100
                        let dy = Double(value.translation.height / max(1, size.height)) * 100
                        config.offsetX = min(50, max(-50, base.width + dx))
                        config.offsetY = min(50, max(-50, base.height + dy))
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(height: 300)
    }

    private func loadBackground() {
        if let previewURL, let image = MImage.load(url: previewURL) {
            background = image
            return
        }
        if let sample = MFilmBorderRenderer.samplePhoto(width: 480, height: 640) {
            background = MImage.make(cgImage: sample)
        }
    }

    // MARK: 文本参数

    private var textControls: some View {
        VStack(spacing: 0) {
            TextField("水印文字", text: $config.text)
                .textFieldStyle(.plain)
                .font(.mSans(13))
                .foregroundStyle(MColor.text1)
                .tint(MColor.brass)
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                        .fill(MColor.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                        .strokeBorder(MColor.hairline, lineWidth: 1)
                )
                .padding(.top, 14)

            textStyleRow
                .padding(.top, 10)

            MParamSlider(label: "旋转", value: $config.rotation, base: 0,
                         range: -180...180, step: 1, decimals: 0, suffix: "°", compact: true)
                .padding(.top, 4)

            MToggleRow(label: "使用投影", isOn: $config.shadow, compact: true)

            commonSliders
        }
    }

    private var textStyleRow: some View {
        HStack(spacing: 6) {
            styleButton(icon: "bold", active: config.bold) {
                config.bold.toggle()
            }
            styleButton(icon: "italic", active: config.italic) {
                config.italic.toggle()
            }

            Rectangle()
                .fill(MColor.hairline)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            ForEach(MWatermarkAlignment.allCases) { alignment in
                styleButton(icon: alignment.icon, active: config.alignmentValue == alignment) {
                    config.alignment = alignment.rawValue
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 34)
    }

    private func styleButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            MHaptic.tick()
            withAnimation(MMotion.state) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? MColor.brass : MColor.text3)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? MColor.brassWash : MColor.surface2.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(active ? MColor.brass.opacity(0.3) : MColor.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.94))
    }

    // MARK: 图形参数

    private var imageControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MColor.text3)
                    .frame(width: 24)

                Text(config.imageName.isEmpty ? "未选择 PNG" : config.imageName)
                    .font(.mSans(12, .medium))
                    .foregroundStyle(config.imageName.isEmpty ? MColor.text4 : MColor.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if !config.imagePath.isEmpty {
                    Button {
                        MHaptic.tick()
                        MWatermarkStore.removeImage(path: config.imagePath)
                        config.imagePath = ""
                        config.imageName = ""
                    } label: {
                        Text("移除")
                            .font(.mSans(10, .medium))
                            .foregroundStyle(MColor.text3)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    MHaptic.light()
                    showImporter = true
                } label: {
                    Text("选择")
                        .font(.mSans(10.5, .semibold))
                        .foregroundStyle(MColor.brass)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(MColor.brassWash))
                        .overlay(Capsule().strokeBorder(MColor.brass.opacity(0.26), lineWidth: 1))
                }
                .buttonStyle(MPressStyle(scale: 0.94))
            }
            .frame(height: 44)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .fill(MColor.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .strokeBorder(MColor.hairline, lineWidth: 1)
            )
            .padding(.top, 14)

            MParamSlider(label: "旋转", value: $config.rotation, base: 0,
                         range: -180...180, step: 1, decimals: 0, suffix: "°", compact: true)
                .padding(.top, 6)

            commonSliders
        }
    }

    private var commonSliders: some View {
        VStack(spacing: 0) {
            MParamSlider(label: "大小", value: $config.size, base: 4,
                         range: 1...10, step: 0.1, decimals: 1, suffix: "", compact: true)
            MParamSlider(label: "不透明度", value: $config.opacity, base: 80,
                         range: 0...100, step: 1, decimals: 0, suffix: "%", compact: true)
            MParamSlider(label: "水平偏移", value: $config.offsetX, base: 0,
                         range: -50...50, step: 1, decimals: 0, suffix: "%", compact: true)
            MParamSlider(label: "垂直偏移", value: $config.offsetY, base: 0,
                         range: -50...50, step: 1, decimals: 0, suffix: "%", compact: true)
        }
    }

    // MARK: 导入

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            return
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let imported = try MWatermarkStore.importImage(from: url)
                MWatermarkStore.removeImage(path: config.imagePath)
                config.imageName = imported.name
                config.imagePath = imported.path
                config.kind = MWatermarkKind.image.rawValue
                tab = 1
            } catch {
                // 复制失败时保留原配置，交给导出时的空图判断兜底。
            }
        }
    }
}
