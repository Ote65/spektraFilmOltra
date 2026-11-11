import SwiftUI
import UniformTypeIdentifiers

// MARK: - 全局设置

/// 设置项直接落 UserDefaults：显影会话、导出面板与启动页读同一份值。
enum MobileSettings {
    static let predictivePreviewKey = "mobile.preview.predictive"
    static let defaultExportFormatKey = "mobile.export.defaultFormatIndex"
    static let defaultExportEdgeKey = "mobile.export.defaultEdgeIndex"
    static let defaultExportQualityKey = "mobile.export.defaultQualityIndex"
    static let launchScreenKey = "mobile.launch.screen"

    /// 与导出面板的 formats 顺序一致：JPEG / TIFF sRGB / TIFF ProPhoto / EXR。
    static let exportFormatTitles = [
        "JPEG",
        "TIFF · sRGB 16-bit",
        "TIFF · ProPhoto 16-bit",
        "EXR · ACES half",
    ]
    static let exportEdgeTitles = ["最大可用尺寸", "2048 px", "4096 px"]
    static let exportQualityTitles = ["100%", "95%", "90%", "80%"]

    enum MLaunchScreen: String, CaseIterable, Identifiable {
        case home
        case camera

        var id: String { rawValue }
        var title: String { self == .home ? "访达" : "相机" }
    }

    static var predictivePreviewEnabled: Bool {
        UserDefaults.standard.object(forKey: predictivePreviewKey) as? Bool ?? true
    }

    static var defaultExportFormatIndex: Int {
        index(forKey: defaultExportFormatKey, count: exportFormatTitles.count, fallback: 0)
    }

    static var defaultExportEdgeIndex: Int {
        index(forKey: defaultExportEdgeKey, count: exportEdgeTitles.count, fallback: 0)
    }

    static var defaultExportQualityIndex: Int {
        index(forKey: defaultExportQualityKey, count: exportQualityTitles.count, fallback: 1)
    }

    static var launchScreen: MLaunchScreen {
        guard let raw = UserDefaults.standard.string(forKey: launchScreenKey),
              let value = MLaunchScreen(rawValue: raw) else { return .home }
        return value
    }

    private static func index(forKey key: String, count: Int, fallback: Int) -> Int {
        guard let number = UserDefaults.standard.object(forKey: key) as? Int else {
            return fallback
        }
        return (0..<count).contains(number) ? number : fallback
    }
}

// MARK: - 设置页

/// 全屏设置页：导出默认值、预览、启动页面、水印、LUT 库。
struct SettingsScreen: View {
    let onBack: () -> Void
    let onToast: (String) -> Void
    var previewURL: URL? = nil

    @AppStorage(MobileSettings.predictivePreviewKey) private var predictivePreview = true
    @AppStorage(MobileSettings.defaultExportFormatKey) private var exportFormat = 0
    @AppStorage(MobileSettings.defaultExportEdgeKey) private var exportEdge = 0
    @AppStorage(MobileSettings.defaultExportQualityKey) private var exportQuality = 1
    @AppStorage(MobileSettings.launchScreenKey) private var launchScreen = MobileSettings.MLaunchScreen.home.rawValue

    @State private var watermark = MWatermarkStore.load()
    @State private var watermarkEditorOpen = false
    @State private var luts: [GradeLUTEntry] = []
    @State private var showLUTImporter = false
    @State private var pendingDelete: GradeLUTEntry?
    @Environment(\.mSafeInsets) private var insets

    var body: some View {
        ZStack {
            MColor.app
            VStack(spacing: 0) {
                navigationBar
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        exportSection
                        previewSection
                        launchSection
                        watermarkSection
                        lutSection
                    }
                    .padding(.horizontal, MMetric.pageMargin)
                    .padding(.bottom, insets.bottom + 28)
                }
                .scrollIndicators(.never)
            }
            .padding(.top, insets.top)
            .offset(x: watermarkEditorOpen ? -72 : 0)

            if watermarkEditorOpen {
                MWatermarkEditor(
                    config: $watermark,
                    previewURL: previewURL,
                    onBack: {
                        withAnimation(MMotion.push) { watermarkEditorOpen = false }
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(3)
            }
        }
        .onAppear { luts = GradePresetStore.shared.luts() }
        .onChange(of: watermark) { _, value in
            MWatermarkStore.saveSoon(value)
        }
        .onDisappear {
            MWatermarkStore.flush(watermark)
        }
        .fileImporter(
            isPresented: $showLUTImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            handleLUTImport(result)
        }
        .alert(
            "删除这个 LUT？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { entry in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { removeLUT(entry) }
        } message: { entry in
            Text(entry.name)
        }
    }

    // MARK: 顶栏

    private var navigationBar: some View {
        ZStack {
            Text("设置")
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

    // MARK: 导出

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "导出")
                .padding(.top, 8)

            MChoiceRow(label: "文件类型", value: exportFormatTitle,
                       options: formatOptions) { raw in
                guard let value = Int(raw) else { return }
                exportFormat = value
            }

            MChoiceRow(label: "尺寸", value: exportEdgeTitle,
                       options: edgeOptions) { raw in
                guard let value = Int(raw) else { return }
                exportEdge = value
            }

            MChoiceRow(label: "图像品质",
                       value: isJPEGExport ? exportQualityTitle : "无损",
                       options: qualityOptions,
                       isEnabled: isJPEGExport) { raw in
                guard let value = Int(raw) else { return }
                exportQuality = value
            }

            hairline
        }
    }

    private var isJPEGExport: Bool { exportFormat == 0 }

    private var exportFormatTitle: String {
        MobileSettings.exportFormatTitles[
            min(max(exportFormat, 0), MobileSettings.exportFormatTitles.count - 1)
        ]
    }

    private var exportEdgeTitle: String {
        MobileSettings.exportEdgeTitles[
            min(max(exportEdge, 0), MobileSettings.exportEdgeTitles.count - 1)
        ]
    }

    private var exportQualityTitle: String {
        MobileSettings.exportQualityTitles[
            min(max(exportQuality, 0), MobileSettings.exportQualityTitles.count - 1)
        ]
    }

    private var formatOptions: [MProOption] {
        MobileSettings.exportFormatTitles.enumerated().map {
            MProOption(value: "\($0.offset)", label: $0.element)
        }
    }

    private var edgeOptions: [MProOption] {
        MobileSettings.exportEdgeTitles.enumerated().map {
            MProOption(value: "\($0.offset)", label: $0.element)
        }
    }

    private var qualityOptions: [MProOption] {
        MobileSettings.exportQualityTitles.enumerated().map {
            MProOption(value: "\($0.offset)", label: $0.element)
        }
    }

    // MARK: 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "预览")
                .padding(.top, 18)

            MToggleRow(label: "双层预览预测", isOn: $predictivePreview, compact: true)
        }
    }

    // MARK: 启动页面

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "软件打开页面")
                .padding(.top, 18)

            MChoiceRow(label: "打开页面", value: launchTitle,
                       options: launchOptions) { raw in
                guard let value = MobileSettings.MLaunchScreen(rawValue: raw) else { return }
                launchScreen = value.rawValue
            }

            hairline
        }
    }

    private var launchTitle: String {
        (MobileSettings.MLaunchScreen(rawValue: launchScreen) ?? .home).title
    }

    private var launchOptions: [MProOption] {
        MobileSettings.MLaunchScreen.allCases.map {
            MProOption(value: $0.rawValue, label: $0.title)
        }
    }

    // MARK: 水印

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "水印")
                .padding(.top, 18)

            MToggleRow(label: "导出时添加水印", isOn: $watermark.enabled, compact: true)

            Button {
                MHaptic.light()
                withAnimation(MMotion.push) { watermarkEditorOpen = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: watermark.kindValue == .text ? "textformat" : "photo")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MColor.brass)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("自定义水印")
                            .font(.mSans(12, .medium))
                            .foregroundStyle(MColor.text1)
                        Text(watermarkSummary)
                            .mMeta(9, color: MColor.text4)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MColor.text4)
                }
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            hairline
        }
    }

    private var watermarkSummary: String {
        guard watermark.enabled else { return "未启用" }
        switch watermark.kindValue {
        case .text:
            let text = watermark.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "文本 · 未填写" : "文本 · \(text)"
        case .image:
            return watermark.imageName.isEmpty ? "图形 · 未选择 PNG" : "图形 · \(watermark.imageName)"
        }
    }

    // MARK: LUT

    private var lutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MSectionHead(title: "LUT 库")
                Spacer(minLength: 8)
                Text("\(luts.count) 个")
                    .mMeta(9, color: MColor.text4)
            }
            .padding(.top, 18)

            if luts.isEmpty {
                Text("暂无 LUT")
                    .mMeta(10, color: MColor.text4)
                    .padding(.top, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(luts) { entry in
                        lutRow(entry)
                        if entry.id != luts.last?.id {
                            hairline
                        }
                    }
                }
                .padding(.top, 4)
            }

            importLUTButton
                .padding(.top, 12)
        }
    }

    private func lutRow(_ entry: GradeLUTEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MColor.brass)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.mSans(12, .medium))
                    .foregroundStyle(MColor.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("CUBE 3D")
                    .font(.mSans(8, .medium))
                    .tracking(0.5)
                    .foregroundStyle(MColor.text4)
            }

            Spacer(minLength: 0)

            Button {
                MHaptic.tick()
                pendingDelete = entry
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MColor.text3)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(entry.name)")
        }
        .frame(height: 48)
    }

    private var importLUTButton: some View {
        Button {
            MHaptic.light()
            showLUTImporter = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("导入 LUT")
                    .font(.mSans(11.5, .medium))
            }
            .foregroundStyle(MColor.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .fill(MColor.surface2.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                    .strokeBorder(MColor.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle(scale: 0.98))
    }

    private var hairline: some View {
        Rectangle().fill(MColor.hairline).frame(height: 1)
    }

    // MARK: 行为

    private func handleLUTImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            onToast("LUT 导入失败")
        case .success(let urls):
            var imported = 0
            var firstError: Error?
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try GradePresetStore.shared.importLUT(from: url)
                    imported += 1
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            luts = GradePresetStore.shared.luts()
            if imported > 0 {
                onToast("已导入 \(imported) 个 LUT")
            } else if let error = firstError {
                onToast(error.localizedDescription)
            } else {
                onToast("LUT 导入失败")
            }
        }
    }

    private func removeLUT(_ entry: GradeLUTEntry) {
        try? GradePresetStore.shared.removeLUT(path: entry.path)
        luts = GradePresetStore.shared.luts()
        pendingDelete = nil
        onToast("已删除 LUT")
    }
}
