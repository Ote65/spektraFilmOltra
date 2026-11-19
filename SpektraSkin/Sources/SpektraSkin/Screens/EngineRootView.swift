import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum EngineScreen {
    case library
    case editor
    case grade
    case videoEditor
}

/// 空格键路由。
///
/// macOS 会把空格当成「按下当前获得焦点的按钮」——显影台里焦点一旦落在
/// 「媒体库」上，按空格就直接退回首页。这里在事件进入响应链之前拦下来：
/// - 视频台：播放 / 暂停
/// - 照片台：预览回到默认大小（zoom=1、pan=0）
/// - 库 / 调色台：吞掉，不让焦点按钮被触发
/// 文本输入框与弹窗保持系统原行为。
final class KeyRouter: ObservableObject {
    static let shared = KeyRouter()

    var screen: EngineScreen = .library
    /// 照片台空格信号：自增一次即要求预览复位。
    @Published var zoomResetToken = 0

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event
            }
            if NSApp.keyWindow?.attachedSheet != nil { return event }
            return MainActor.assumeIsolated { self.handleSpace() } ? nil : event
        }
    }

    @MainActor
    private func handleSpace() -> Bool {
        switch screen {
        case .videoEditor:
            let host = VideoHost.shared
            if host.isPlaying {
                host.pausePlayback()
            } else {
                host.togglePlay()
            }
            return true
        case .editor:
            zoomResetToken += 1
            return true
        case .library, .grade:
            return true
        }
    }
}

struct EngineRootView: View {
    @ObservedObject var host: EngineHost
    @ObservedObject private var videoHost = VideoHost.shared

    /// 首页默认落在库：照片和视频是同一个访达。
    @State private var screen: EngineScreen = .library
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            EngineChrome()

            ZStack {
                switch screen {
                case .library:
                    LibraryView(
                        snapshot: host.librarySnapshot(),
                        currentID: selectedID,
                        actions: actions
                    )
                    .transition(.opacity)
                case .editor:
                    EditorView(
                        snapshot: host.editorSnapshot(for: activeID),
                        presets: PreviewData.presets,
                        actions: actions
                    )
                    .transition(.opacity)
                case .grade:
                    GradeView(snapshot: host.gradeSnapshot(for: activeID), actions: actions)
                        .transition(.opacity)
                case .videoEditor:
                    VideoEditorView(host: videoHost, actions: videoActions) {
                        withAnimation(SkinMotion.page) { screen = .library }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkinColor.app)
        .ignoresSafeArea()
        .onAppear {
            KeyRouter.shared.screen = screen
            KeyRouter.shared.install()
            if selectedID == nil, let first = host.photos.first {
                selectedID = first.id
                host.select(photoID: first.id)
            }
            host.warmThumbnails()
        }
        .onChange(of: screen) { _, new in KeyRouter.shared.screen = new }
    }

    private var activeID: String {
        selectedID ?? host.photos.first?.id ?? ""
    }

    private var actions: SkinActions {
        var actions = SkinActions.preview
        actions.openPhoto = { id in
            selectedID = id
            if host.isVideoID(id) {
                VideoHost.shared.select(id: id)
                withAnimation(SkinMotion.page) { screen = .videoEditor }
            } else {
                host.select(photoID: id)
                withAnimation(SkinMotion.page) { screen = .editor }
            }
        }
        actions.backToLibrary = {
            withAnimation(SkinMotion.page) { screen = .library }
        }
        actions.openGrade = {
            guard host.currentPhoto() != nil else { return }
            host.beginGrade()
            withAnimation(SkinMotion.page) { screen = .grade }
        }
        actions.backToEditor = {
            host.endGrade()
            withAnimation(SkinMotion.page) { screen = .editor }
        }
        actions.selectFilm = { host.setFilm($0) }
        actions.selectPaper = { host.setPaper($0) }
        actions.selectStripPhoto = { id in
            selectedID = id
            host.select(photoID: id)
        }
        actions.resetParameters = { host.resetParameters() }
        actions.exportCurrent = { host.exportCurrent() }
        actions.exportOptions = { host.exportCurrent() }
        actions.quickChanged = { host.applyQuick($0, $1) }
        actions.padChanged = { host.applyPad($0, $1) }
        actions.proChanged = { host.applyPro($0, $1) }
        actions.proToggled = { host.applyProToggle($0, $1) }
        actions.importMedia = {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = Self.mediaContentTypes
            panel.message = "选择照片或视频，导入到同一个媒体库"
            if panel.runModal() == .OK {
                let urls = panel.urls
                let videoURLs = urls.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
                let photoURLs = urls.filter { !Self.videoExtensions.contains($0.pathExtension.lowercased()) }
                var firstID: String?
                if !photoURLs.isEmpty { firstID = host.importPhotos(photoURLs) }
                if !videoURLs.isEmpty {
                    firstID = VideoHost.shared.importVideos(videoURLs).first ?? firstID
                }
                if let id = firstID {
                    selectedID = id
                    if !host.isVideoID(id) { host.select(photoID: id) }
                }
            }
        }
        actions.importPhotos = {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = Self.rawContentTypes
            if panel.runModal() == .OK {
                if let id = host.importPhotos(panel.urls) {
                    selectedID = id
                    host.select(photoID: id)
                }
            }
        }
        actions.importVideos = {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
            if panel.runModal() == .OK {
                let ids = VideoHost.shared.importVideos(panel.urls)
                if let first = ids.first {
                    selectedID = first
                }
            }
        }
        actions.importFolder = {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                host.importFolder(url)
                if let first = host.photos.first {
                    selectedID = first.id
                    host.select(photoID: first.id)
                }
            }
        }
        actions.exportAs = { host.exportAs($0) }
        actions.exportWithSettings = { host.export($0) }
        actions.refreshExportPreflight = { host.refreshExportPreflight() }
        actions.renderScaleChanged = { host.setPreviewScale($0) }
        actions.reRender = { host.renderPreview() }
        actions.toggleFavorite = { id in
            if host.isVideoID(id) { VideoHost.shared.toggleFavorite(id: id) }
            else { host.toggleFavorite(id) }
        }
        actions.setColorLabel = { id, label in
            if host.isVideoID(id) { VideoHost.shared.setColorLabel(id: id, label) }
            else { host.setColorLabel(id, label) }
        }
        actions.removePhoto = { id in
            if host.isVideoID(id) {
                VideoHost.shared.remove(id: id)
                if selectedID == id { selectedID = nil }
            } else {
                host.removePhoto(id)
            }
        }
        actions.gradeRecipeChanged = { host.setGradeRecipe($0) }
        actions.gradePresetSaved = { host.saveGradePreset(name: $0, recipe: $1) }
        actions.gradePresetDeleted = { host.deleteGradePreset(id: $0) }
        actions.gradeLUTImported = {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
            if panel.runModal() == .OK, let url = panel.url {
                host.importGradeLUT(from: url)
            }
        }
        actions.gradeExport = { host.exportGrade($0) }
        return actions
    }

    /// 视频显影台复用同一套左侧 rail / 导出按钮，只是动作打到 VideoHost。
    private var videoActions: SkinActions {
        var a = SkinActions.preview
        a.selectFilm = { VideoHost.shared.setFilm($0) }
        a.selectPaper = { VideoHost.shared.setPaper($0) }
        a.resetParameters = { VideoHost.shared.resetParameters() }
        a.backToLibrary = {
            VideoHost.shared.pausePlayback()
            withAnimation(SkinMotion.page) { screen = .library }
        }
        a.exportCurrent = {}
        a.exportOptions = {}
        a.reRender = {}
        return a
    }

    private static var rawContentTypes: [UTType] {
        var types: [UTType] = [.rawImage]
        for suffix in ImageLoader.rawSuffixes {
            if let type = UTType(filenameExtension: suffix) {
                types.append(type)
            }
        }
        return Array(Set(types))
    }

    /// 「导入媒体」一个入口同时收照片与视频。
    private static var mediaContentTypes: [UTType] {
        var types = rawContentTypes
        types.append(contentsOf: [.image, .movie, .mpeg4Movie, .quickTimeMovie])
        return Array(Set(types))
    }

    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "qt", "hevc"]
}

private struct EngineChrome: View {
    var body: some View {
        ZStack {
            SkinColor.app
            Text("SPEKTRAFILM")
                .font(.skin(9, .medium))
                .tracking(2.4)
                .foregroundStyle(SkinColor.text4)
        }
        .frame(height: 34)
        .overlay(WindowDragArea())
    }
}

/// 只有顶部状态栏可以拖动窗口；内容区不再响应整窗拖拽。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
