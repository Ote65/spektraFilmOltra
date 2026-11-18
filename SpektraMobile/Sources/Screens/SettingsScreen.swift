import SwiftUI
import UniformTypeIdentifiers

// MARK: - 全局设置

/// 设置项直接落 UserDefaults：显影会话、导出面板与启动页读同一份值。
enum MobileSettings {
    static let predictivePreviewKey = "mobile.preview.predictive"
    /// 允许导入并显影 JPEG/HEIC/PNG 等编码图；关闭时主页只映射相册里的 RAW。
    static let allowNonRawKey = "mobile.import.allowNonRaw"
    static let defaultExportFormatKey = "mobile.export.defaultFormatIndex"
    static let defaultExportEdgeKey = "mobile.export.defaultEdgeIndex"
    static let defaultExportQualityKey = "mobile.export.defaultQualityIndex"
    static let launchScreenKey = "mobile.launch.screen"
    /// 冷启动时主页默认选中的筛选类型；相簿 ID 不稳定，不参与默认值。
    static let launchScopeKey = "mobile.launch.scope"
    // 相机
    static let cameraLevelKey = "mobile.camera.level"
    static let cameraMirrorFrontKey = "mobile.camera.mirrorFront"
    static let cameraEnterDevelopKey = "mobile.camera.enterDevelop"
    static let cameraVolumeShutterKey = "mobile.camera.volumeShutter"
    static let cameraDirectSaveOriginalKey = "mobile.camera.directSaveOriginal"

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

    /// 启动筛选只开放固定类型；系统相簿是动态 ID，不适合做默认值。
    enum MLaunchScope: String, CaseIterable, Identifiable {
        case all
        case captured
        case saved
        case favorites
        case raw
        case graded

        var id: String { rawValue }

        var title: String { scope.title }

        var requiresEncoded: Bool { self == .captured || self == .saved }

        var scope: MAssetScope {
            switch self {
            case .all: return .all
            case .captured: return .captured
            case .saved: return .saved
            case .favorites: return .favorites
            case .raw: return .raw
            case .graded: return .graded
            }
        }
    }

    static var predictivePreviewEnabled: Bool {
        UserDefaults.standard.object(forKey: predictivePreviewKey) as? Bool ?? true
    }

    static var allowNonRaw: Bool {
        UserDefaults.standard.object(forKey: allowNonRawKey) as? Bool ?? false
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

    static var launchScope: MAssetScope {
        guard let raw = UserDefaults.standard.string(forKey: launchScopeKey),
              let value = MLaunchScope(rawValue: raw) else { return .all }
        // 关闭「支持 JPEG」后拍摄/保存筛选没有入口，启动时回落到全部。
        if value.requiresEncoded && !allowNonRaw { return .all }
        return value.scope
    }

    static var cameraLevelEnabled: Bool {
        UserDefaults.standard.object(forKey: cameraLevelKey) as? Bool ?? true
    }

    static var cameraEnterDevelop: Bool {
        UserDefaults.standard.object(forKey: cameraEnterDevelopKey) as? Bool ?? true
    }

    static var cameraVolumeShutter: Bool {
        UserDefaults.standard.object(forKey: cameraVolumeShutterKey) as? Bool ?? true
    }

    static var cameraDirectSaveOriginal: Bool {
        UserDefaults.standard.object(forKey: cameraDirectSaveOriginalKey) as? Bool ?? false
    }

    static var cameraMirrorFront: Bool {
        UserDefaults.standard.object(forKey: cameraMirrorFrontKey) as? Bool ?? false
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
    /// 库根目录：用于统计 / 清理显影交接图缓存。
    var cacheRoot: URL? = nil

    @AppStorage(MobileSettings.predictivePreviewKey) private var predictivePreview = true
    @AppStorage(MobileSettings.allowNonRawKey) private var allowNonRaw = false
    @AppStorage(MobileSettings.defaultExportFormatKey) private var exportFormat = 0
    @AppStorage(MobileSettings.defaultExportEdgeKey) private var exportEdge = 0
    @AppStorage(MobileSettings.defaultExportQualityKey) private var exportQuality = 1
    @AppStorage(MobileSettings.launchScreenKey) private var launchScreen = MobileSettings.MLaunchScreen.home.rawValue
    @AppStorage(MobileSettings.launchScopeKey) private var launchScope = MobileSettings.MLaunchScope.all.rawValue
    @AppStorage(MobileSettings.cameraLevelKey) private var cameraLevel = true
    @AppStorage(MobileSettings.cameraMirrorFrontKey) private var cameraMirrorFront = false
    @AppStorage(MobileSettings.cameraEnterDevelopKey) private var cameraEnterDevelop = true
    @AppStorage(MobileSettings.cameraVolumeShutterKey) private var cameraVolumeShutter = true
    @AppStorage(MobileSettings.cameraDirectSaveOriginalKey) private var cameraDirectSaveOriginal = false

    @State private var watermark = MWatermarkStore.load()
    @State private var watermarkEditorOpen = false
    @State private var luts: [GradeLUTEntry] = []
    /// LUT 库默认折叠：列表长了会把缓存分区推得太远。
    @State private var lutExpanded = false
    @State private var showLUTImporter = false
    @State private var pendingDelete: GradeLUTEntry?
    @State private var handoffCacheCount = 0
    @State private var handoffCacheBytes: Int64 = 0
    @State private var clearingCache = false
    @Environment(\.mSafeInsets) private var insets

    var body: some View {
        ZStack {
            MColor.app
            VStack(spacing: 0) {
                navigationBar
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        inputSection
                        cameraSection
                        exportSection
                        previewSection
                        launchSection
                        watermarkSection
                        lutSection
                        cacheSection
                    }
                    .padding(.horizontal, MMetric.pageMargin)
                    .padding(.bottom, insets.bottom + 28)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(DebugLaunch.settingsBottom ? .bottom : .top)
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
        .onAppear {
            luts = GradePresetStore.shared.luts()
            refreshCacheStats()
        }
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

    // MARK: 输入

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "输入")
                .padding(.top, 8)

            MToggleRow(label: "支持 JPEG", isOn: $allowNonRaw, compact: true)

            hairline
        }
    }

    // MARK: 相机

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "相机")
                .padding(.top, 18)

            MToggleRow(label: "水平仪", isOn: $cameraLevel, compact: true,
                       detail: "取景框中央显示水平与俯拍参考")

            MToggleRow(label: "镜像前置相机", isOn: $cameraMirrorFront, compact: true,
                       detail: "前置成片镜像为取景所见（和预览一样）；显影台与 RAW 原片保持原始画面")

            MToggleRow(label: "拍摄后进入显影台", isOn: $cameraEnterDevelop, compact: true,
                       detail: "关闭后停留在取景页，可连续拍摄")

            MToggleRow(label: "音量键拍摄", isOn: $cameraVolumeShutter,
                       isEnabled: volumeShutterAvailable, compact: true,
                       detail: volumeShutterDetail)

            MToggleRow(label: "直出模式保存原图", isOn: $cameraDirectSaveOriginal, compact: true,
                       detail: "开启后保留 RAW 与可回放的显影 / 调色工程")

            hairline
        }
    }

    private var volumeShutterAvailable: Bool {
        if #available(iOS 17.2, *) { return true }
        return false
    }

    private var volumeShutterDetail: String {
        if #available(iOS 17.2, *) {
            return "音量键或相机控制键触发快门"
        }
        return "需要 iOS 17.2 或更高版本"
    }

    // MARK: 导出

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "导出")
                .padding(.top, 18)

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
            // 尺寸档位只缩小、不放大：原图长边不足所选值时按原图输出，
            // 所以 12 MP 原机上 4096 档与最大可用尺寸输出相同——保存成功提示里
            // 会带实际长边，可当场核对。
            Text("档位只缩小不放大：原图长边不足所选值时按原图输出")
                .font(.mSans(9))
                .foregroundStyle(MColor.text4)
                .padding(.top, 2)

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

            MChoiceRow(label: "默认筛选", value: launchScopeTitle,
                       options: launchScopeOptions) { raw in
                guard MobileSettings.MLaunchScope(rawValue: raw) != nil else { return }
                launchScope = raw
            }

            hairline
        }
    }

    private var launchTitle: String {
        // iPad 无相机功能：已存过「相机」的值显示时兜底回「访达」。
        let value = MobileSettings.MLaunchScreen(rawValue: launchScreen) ?? .home
        if MLayout.isPad && value == .camera { return MobileSettings.MLaunchScreen.home.title }
        return value.title
    }

    private var launchOptions: [MProOption] {
        MobileSettings.MLaunchScreen.allCases
            .filter { !MLayout.isPad || $0 != .camera }
            .map {
                MProOption(value: $0.rawValue, label: $0.title)
            }
    }

    private var launchScopeTitle: String {
        let value = MobileSettings.MLaunchScope(rawValue: launchScope) ?? .all
        // 关闭「支持 JPEG」时拍摄/保存没有入口，显示与启动行为都回落到全部。
        if value.requiresEncoded && !allowNonRaw { return MobileSettings.MLaunchScope.all.title }
        return value.title
    }

    private var launchScopeOptions: [MProOption] {
        MobileSettings.MLaunchScope.allCases
            .filter { allowNonRaw || !$0.requiresEncoded }
            .map {
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
            Button {
                MHaptic.tick()
                withAnimation(MMotion.state) { lutExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("LUT 库")
                        .mLabel(9.5, color: MColor.text3)
                    Spacer(minLength: 8)
                    Text("\(luts.count) 个")
                        .mMeta(9, color: MColor.text4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MColor.text4)
                        .rotationEffect(.degrees(lutExpanded ? 180 : 0))
                }
                .padding(.top, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("LUT 库")
            .accessibilityValue(lutExpanded ? "已展开" : "已折叠")

            if lutExpanded {
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

    // MARK: 缓存

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHead(title: "缓存")
                .padding(.top, 18)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("显影交接图")
                        .font(.mSans(11.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Text(handoffCacheDetail)
                        .font(.mSans(9.5, .medium))
                        .foregroundStyle(MColor.text4)
                }

                Spacer(minLength: 8)

                Button {
                    clearCaches()
                } label: {
                    Text(clearingCache ? "清理中…" : "清理")
                        .font(.mSans(10.5, .semibold))
                        .foregroundStyle(MColor.brassInk)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(MColor.brass))
                }
                .buttonStyle(MPressStyle(scale: 0.94))
                .disabled(clearingCache || handoffCacheCount == 0)
                .opacity(clearingCache || handoffCacheCount == 0 ? 0.45 : 1)
            }
            .padding(.vertical, 7)

            Text("清理交接图与缩略图内存缓存；原片、导出成片与调色参数不受影响。")
                .font(.mSans(9, .medium))
                .foregroundStyle(MColor.text4)
                .fixedSize(horizontal: false, vertical: true)

            hairline.padding(.top, 10)
        }
    }

    private var handoffCacheDetail: String {
        guard handoffCacheCount > 0 else { return "暂无缓存" }
        return "\(handoffCacheCount) 张 · \(cacheSizeText(handoffCacheBytes)) · 用于调色台秒开"
    }

    private func cacheSizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func refreshCacheStats() {
        guard let cacheRoot else { return }
        let stats = MDevelopHandoffCache.statistics(root: cacheRoot)
        handoffCacheCount = stats.count
        handoffCacheBytes = stats.bytes
    }

    private func clearCaches() {
        guard let cacheRoot, !clearingCache else { return }
        let freed = handoffCacheBytes
        clearingCache = true
        MHaptic.medium()
        Task.detached(priority: .userInitiated) {
            MDevelopHandoffCache.clear(root: cacheRoot)
            await MainActor.run {
                // 缩略图只是解码加速层；清掉后滚动时会按需重新读盘。
                MThumbnailCache.shared.removeAll()
                clearingCache = false
                refreshCacheStats()
                onToast(freed > 0 ? "已清理 \(cacheSizeText(freed)) 缓存" : "缓存已清理")
            }
        }
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
