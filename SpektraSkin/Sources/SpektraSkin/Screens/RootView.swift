import SwiftUI

private enum Screen {
    case library
    case editor
    case grade
}

struct RootView: View {
    @State private var screen: Screen = .library
    @State private var selectedPhotoID: PhotoItem.ID?

    private let data: SpektraSkinDataSource = PreviewDataSource()

    var body: some View {
        VStack(spacing: 0) {
            WindowChrome()

            ZStack {
                switch screen {
                case .library:
                    LibraryView(snapshot: data.library, actions: actions)
                        .transition(.opacity)
                case .editor:
                    EditorView(
                        snapshot: data.editor(for: activePhotoID),
                        presets: data.presets,
                        actions: actions
                    )
                    .transition(.opacity)
                case .grade:
                    GradeView(
                        snapshot: data.grade(for: activePhotoID),
                        actions: actions
                    )
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkinColor.app)
        .ignoresSafeArea()
    }

    private var activePhotoID: PhotoItem.ID {
        selectedPhotoID ?? data.library.photos.first?.id ?? ""
    }

    private var actions: SkinActions {
        var actions = SkinActions.preview
        actions.openPhoto = { id in
            selectedPhotoID = id
            withAnimation(SkinMotion.page) { screen = .editor }
        }
        actions.backToLibrary = {
            withAnimation(SkinMotion.page) { screen = .library }
        }
        actions.openGrade = {
            withAnimation(SkinMotion.page) { screen = .grade }
        }
        actions.backToEditor = {
            withAnimation(SkinMotion.page) { screen = .editor }
        }
        return actions
    }
}

private struct WindowChrome: View {
    var body: some View {
        ZStack {
            SkinColor.app

            BrandChrome()
        }
        .frame(height: SkinMetric.chromeHeight)
    }
}
