import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum EngineScreen {
    case library
    case editor
    case grade
}

struct EngineRootView: View {
    @ObservedObject var host: EngineHost

    @State private var screen: EngineScreen = .library
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            EngineChrome()

            ZStack {
                switch screen {
                case .library:
                    LibraryView(snapshot: host.librarySnapshot(), actions: actions)
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkinColor.app)
        .ignoresSafeArea()
        .onAppear {
            if selectedID == nil {
                selectedID = host.photos.first?.id
                if let id = selectedID { host.select(photoID: id) }
            }
            host.warmThumbnails()
        }
    }

    private var activeID: String {
        selectedID ?? host.photos.first?.id ?? ""
    }

    private var actions: SkinActions {
        var actions = SkinActions.preview
        actions.openPhoto = { id in
            selectedID = id
            host.select(photoID: id)
            withAnimation(SkinMotion.page) { screen = .editor }
        }
        actions.openGradeDirect = { id in
            let photos = host.librarySnapshot().photos
            guard let item = photos.first(where: { $0.id == id }), item.isRaw else {
                actions.openPhoto(id)
                return
            }
            selectedID = id
            host.beginGradeDirect(photoID: id)
            withAnimation(SkinMotion.page) { screen = .grade }
        }
        actions.backToLibrary = {
            withAnimation(SkinMotion.page) { screen = .library }
        }
        actions.backToLibraryFromGrade = {
            host.endGrade()
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
        actions.toggleFavorite = { host.toggleFavorite($0) }
        actions.setColorLabel = { host.setColorLabel($0, $1) }
        actions.removePhoto = { host.removePhoto($0) }
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
        actions.gradePreviewScaleChanged = { host.setGradePreviewScale($0) }
        actions.gradeReRender = { host.reRenderGrade() }
        return actions
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
}

private struct EngineChrome: View {
    var body: some View {
        ZStack {
            SkinColor.app
            BrandChrome()
        }
        .frame(height: SkinMetric.chromeHeight)
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
