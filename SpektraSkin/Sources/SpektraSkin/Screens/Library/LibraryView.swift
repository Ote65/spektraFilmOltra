import SwiftUI

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, favorite, adjusted, red, yellow, green, blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .favorite: return "收藏"
        case .adjusted: return "已调整"
        case .red: return "红"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        }
    }

    var tone: ColorLabel? {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        default: return nil
        }
    }
}

private enum LibraryViewMode {
    case grid
    case list
}

private enum LibrarySortMode: String {
    case recent
    case filename

    var title: String {
        switch self {
        case .recent: return "最近导入"
        case .filename: return "文件名"
        }
    }
}

struct LibraryView: View {
    let snapshot: LibrarySnapshot
    let actions: SkinActions

    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var viewMode: LibraryViewMode = .grid
    @State private var sortMode: LibrarySortMode = .recent

    private var visiblePhotos: [PhotoItem] {
        let searched = snapshot.photos.filter { photo in
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            return photo.filename.localizedCaseInsensitiveContains(text)
                || photo.film.localizedCaseInsensitiveContains(text)
                || (photo.paper?.localizedCaseInsensitiveContains(text) ?? false)
        }
        let filtered = searched.filter { photo in
            switch filter {
            case .all: return true
            case .favorite: return photo.favorite
            case .adjusted: return photo.isGraded
            case .red, .yellow, .green, .blue:
                return photo.color == filter.tone
            }
        }
        switch sortMode {
        case .recent:
            return filtered
        case .filename:
            return filtered.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            statusBar
        }
        .background(SkinColor.app)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 11) {
            titleRow
            controlRow
        }
        .padding(.horizontal, SkinMetric.pageMargin)
        .padding(.top, 16)
        .padding(.bottom, 13)
        .background(SkinColor.app)
        .overlay(alignment: .bottom) {
            SkinHairline()
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("照片库")
                    .font(.pageTitle)
                    .tracking(0.4)
                    .foregroundStyle(SkinColor.text1)

                Text("\(snapshot.folderCount) 个文件夹 · \(snapshot.photoCount) 张照片")
                    .font(.pageSubtitle.monospacedDigit())
                    .foregroundStyle(SkinColor.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            SkinButton("导入文件夹", icon: "folder", kind: .secondary) { actions.importFolder() }
            SkinButton("导入照片", icon: "square.and.arrow.down", kind: .primary) { actions.importPhotos() }
        }
        .frame(height: 32)
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach([LibraryFilter.all, .favorite, .adjusted]) { item in
                    SkinChip(
                        title: item.title,
                        tone: nil,
                        selected: filter == item
                    ) {
                        withAnimation(SkinMotion.state) { filter = item }
                    }
                }

                SkinVerticalHairline(height: 16)
                    .padding(.horizontal, 2)

                ForEach([LibraryFilter.red, .yellow, .green, .blue]) { item in
                    SkinChip(
                        title: item.title,
                        tone: item.tone,
                        selected: filter == item
                    ) {
                        withAnimation(SkinMotion.state) { filter = item }
                    }
                }
            }

            Spacer(minLength: 12)

            SkinSearchField(
                placeholder: "搜索照片、胶片或相纸",
                text: $query,
                width: 240
            )

            LibrarySortButton(mode: $sortMode)

            LibraryViewToggle(mode: $viewMode)
        }
        .frame(height: SkinMetric.controlHeight)
    }

    // MARK: Content

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHead

                if snapshot.photos.isEmpty {
                    LibraryEmptyView(actions: actions)
                        .padding(.top, 64)
                } else if visiblePhotos.isEmpty {
                    VStack(spacing: 8) {
                        Text("没有匹配的照片")
                            .font(.skin(14, .medium))
                            .foregroundStyle(SkinColor.text2)
                        Text("试试清除搜索或切换筛选")
                            .font(.skin(11))
                            .foregroundStyle(SkinColor.text4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    Group {
                        switch viewMode {
                        case .grid:
                            grid
                        case .list:
                            list
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, SkinMetric.pageMargin)
            .padding(.top, 15)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionHead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(snapshot.sectionTitle)
                .font(.sectionTitle)
                .tracking(0.2)
                .foregroundStyle(SkinColor.text2)

            Text("\(visiblePhotos.count) 张照片")
                .font(.skin(10.5).monospacedDigit())
                .foregroundStyle(SkinColor.text3)

            Spacer(minLength: 0)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 20, alignment: .top)]
    }

    private var grid: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
            ForEach(snapshot.folders) { folder in
                LibraryFolderCard(folder: folder) {}
            }

            ForEach(visiblePhotos) { photo in
                LibraryPhotoCard(
                    photo: photo,
                    selected: photo.id == snapshot.currentID,
                    actions: actions
                ) {
                    actions.openPhoto(photo.id)
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 4) {
            ForEach(visiblePhotos) { photo in
                LibraryPhotoRow(
                    photo: photo,
                    isCurrent: photo.id == snapshot.currentID,
                    actions: actions
                ) {
                    actions.openPhoto(photo.id)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(snapshot.statusMessage)
                .font(.skin(10.5))
                .foregroundStyle(SkinColor.text3)

            Spacer()
        }
        .padding(.horizontal, SkinMetric.pageMargin)
        .frame(height: SkinMetric.statusBarHeight)
        .background(SkinColor.surface1)
        .overlay(alignment: .top) {
            SkinHairline()
        }
    }
}

// MARK: - Sort

private struct LibrarySortButton: View {
    @Binding var mode: LibrarySortMode
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach([LibrarySortMode.recent, .filename], id: \.rawValue) { item in
                Button(item.title) { mode = item }
            }
        } label: {
            HStack(spacing: 0) {
                Text(mode.title)
                    .font(.skin(11.5))
                    .foregroundStyle(hovered ? SkinColor.text1 : SkinColor.text3)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(SkinColor.text4)
            }
            .padding(.horizontal, 8)
            .frame(width: 112, height: SkinMetric.controlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}

// MARK: - View toggle

private struct LibraryViewToggle: View {
    @Binding var mode: LibraryViewMode

    var body: some View {
        HStack(spacing: 0) {
            toggle(icon: "square.grid.2x2", selected: mode == .grid) {
                withAnimation(SkinMotion.state) { mode = .grid }
            }
            toggle(icon: "list.bullet", selected: mode == .list) {
                withAnimation(SkinMotion.state) { mode = .list }
            }
        }
        .padding(2)
        .frame(width: 58, height: SkinMetric.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                .fill(SkinColor.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SkinRadius.control, style: .continuous)
                .strokeBorder(SkinColor.hairline, lineWidth: 1)
        )
    }

    private func toggle(icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(selected ? SkinColor.text1 : SkinColor.text3)
                .frame(width: 27, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(selected ? SkinColor.surface3 : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid cards

private struct LibraryFolderCard: View {
    let folder: FolderItem
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(folder.isCurrent || hovered ? SkinColor.surface2 : SkinColor.surface1)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    LinearGradient(
                        colors: [Color.white.opacity(0.028), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay {
                    Image(systemName: "folder")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(folder.isCurrent ? SkinColor.accent : (hovered ? SkinColor.text2 : SkinColor.text3))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            folder.isCurrent ? SkinColor.accent.opacity(0.8) : (hovered ? SkinColor.hairlineStrong : SkinColor.hairline),
                            lineWidth: folder.isCurrent ? 1.4 : 1
                        )
                )

            Spacer().frame(height: 9)

            Text(folder.name)
                .font(.skin(12, .medium))
                .foregroundStyle(SkinColor.text1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 18, alignment: .leading)

            Spacer().frame(height: 3)

            Text("\(folder.count) 张照片")
                .font(.skin(10.5).monospacedDigit())
                .foregroundStyle(SkinColor.text3)
                .lineLimit(1)
                .frame(height: 15, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}

private struct LibraryPhotoCard: View {
    let photo: PhotoItem
    let selected: Bool
    let actions: SkinActions
    let action: () -> Void

    @State private var hovered = false
    @State private var controlsVisible = false

    init(photo: PhotoItem, selected: Bool, actions: SkinActions,
         action: @escaping () -> Void) {
        self.photo = photo
        self.selected = selected
        self.actions = actions
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            Spacer().frame(height: 9)
            Text(photo.filename)
                .font(.skin(12))
                .foregroundStyle(selected ? SkinColor.accentHover : SkinColor.text1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 18, alignment: .leading)

            Spacer().frame(height: 3)

            Text(photo.metaLine)
                .font(.skin(10.5).monospacedDigit())
                .foregroundStyle(SkinColor.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 15, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !hovered { action() }
        }
        .onHover { inside in
            hovered = inside
            withAnimation(SkinMotion.hover) {
                controlsVisible = inside || photo.favorite || photo.color != nil || selected
            }
        }
        .animation(SkinMotion.hover, value: hovered)
    }

    private var thumbnail: some View {
        Rectangle()
            .fill(SkinColor.surface1)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image = photo.thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .overlay(Color.white.opacity(hovered ? 0.045 : 0))
                } else {
                    Rectangle()
                        .fill(SkinColor.surface2)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(SkinColor.text4)
                        )
                        .overlay(Color.white.opacity(hovered ? 0.045 : 0))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? SkinColor.accent.opacity(0.9) : (hovered ? SkinColor.hairlineStrong : SkinColor.hairline),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .overlay {
                LibraryPhotoHoverActions(photo: photo, actions: actions)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            }
            .overlay(alignment: .topLeading) {
                if photo.isGraded {
                    Text("已调色")
                        .font(.skin(9, .medium))
                        .foregroundStyle(SkinColor.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(Color.black.opacity(0.62))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .strokeBorder(SkinColor.accent.opacity(0.45), lineWidth: 1)
                        )
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if photo.color != nil || hovered {
                        colorButton
                    }
                    starButton
                    if hovered {
                        moreButton
                    }
                }
                .padding(8)
                .opacity(controlsVisible || photo.favorite || photo.color != nil || selected ? 1 : 0)
            }
    }

    private var colorButton: some View {
        Menu {
            Button("无标签") { actions.setColorLabel(photo.id, nil) }
            ForEach(ColorLabel.allCases) { label in
                Button(label.title) { actions.setColorLabel(photo.id, label) }
            }
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.52))
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                if let color = photo.color {
                    Circle()
                        .fill(SkinColor.labelTone(color))
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .strokeBorder(SkinColor.text2, lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("颜色标签")
    }

    private var starButton: some View {
        Button {
            actions.toggleFavorite(photo.id)
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.52))
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                Image(systemName: photo.favorite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(photo.favorite ? SkinColor.accent : SkinColor.text2)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("收藏")
    }

    private var moreButton: some View {
        Menu {
            Button("从库中移除", role: .destructive) {
                actions.removePhoto(photo.id)
            }
        } label: {
            ZStack {
                Circle().fill(Color.black.opacity(0.52))
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SkinColor.text2)
            }
            .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
    }
}

// MARK: - Hover actions

private struct LibraryPhotoHoverActions: View {
    let photo: PhotoItem
    let actions: SkinActions
    @State private var hoveredZone: Int?

    var body: some View {
        VStack(spacing: 0) {
            zone(
                index: 0, title: "显影台", subtitle: "完整显影",
                icon: "camera.aperture", iconTint: nil
            ) {
                actions.openPhoto(photo.id)
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)

            zone(
                index: 1, title: "仅调色", subtitle: "跳过显影",
                icon: "slider.horizontal.3", iconTint: SkinColor.accent
            ) {
                actions.openGradeDirect(photo.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func zone(
        index: Int, title: String, subtitle: String, icon: String,
        iconTint: Color?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(
                        iconTint ?? (hoveredZone == index ? SkinColor.accentHover : SkinColor.text1)
                    )
                    .frame(width: 18, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.skin(12, .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.skin(9.5))
                        .foregroundStyle(
                            hoveredZone == index ? SkinColor.accentHover.opacity(0.8) : SkinColor.text4
                        )
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .foregroundStyle(hoveredZone == index ? SkinColor.accentHover : SkinColor.text1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                hoveredZone == index
                    ? SkinColor.accent.opacity(0.12)
                    : Color.black.opacity(0.18)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(SkinMotion.hover) {
                if inside {
                    hoveredZone = index
                } else if hoveredZone == index {
                    hoveredZone = nil
                }
            }
        }
    }
}

// MARK: - List row

private struct LibraryPhotoRow: View {
    let photo: PhotoItem
    let isCurrent: Bool
    let actions: SkinActions
    let action: () -> Void

    @State private var hovered = false

    init(photo: PhotoItem, isCurrent: Bool, actions: SkinActions,
         action: @escaping () -> Void) {
        self.photo = photo
        self.isCurrent = isCurrent
        self.actions = actions
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(SkinColor.surface1)
                .frame(width: 96, height: 72)
                .overlay {
                    if let image = photo.thumbnailImage {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle()
                            .fill(SkinColor.surface2)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(SkinColor.text4)
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(SkinColor.hairline, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(photo.filename)
                    .font(.skin(12))
                    .foregroundStyle(isCurrent ? SkinColor.accentHover : SkinColor.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(photo.metaLine)
                    .font(.skin(10.5).monospacedDigit())
                    .foregroundStyle(SkinColor.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if let color = photo.color {
                    Circle()
                        .fill(SkinColor.labelTone(color))
                        .frame(width: 7, height: 7)
                        .frame(width: 28, height: 28)
                }
                SkinIconButton(
                    photo.favorite ? "star.fill" : "star",
                    size: 11, frame: 28, active: photo.favorite
                ) {
                    actions.toggleFavorite(photo.id)
                }
                Menu {
                    Button("从库中移除", role: .destructive) {
                        actions.removePhoto(photo.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SkinColor.text2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: SkinMetric.listRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? SkinColor.accent.opacity(0.07) : (hovered ? SkinColor.surface1 : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isCurrent ? SkinColor.accent.opacity(0.28) : (hovered ? SkinColor.hairline : .clear),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}

// MARK: - Empty

private struct LibraryEmptyView: View {
    let actions: SkinActions

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(SkinColor.surface1)
                Circle()
                    .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
                Image(systemName: "film")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(SkinColor.text2)
            }
            .frame(width: 76, height: 76)

            Spacer().frame(height: 18)

            Text("照片库还是空的")
                .font(.skin(16, .medium))
                .foregroundStyle(SkinColor.text1)

            Spacer().frame(height: 7)

            Text("把照片拖到这里，或点右上角导入。")
                .font(.skin(12))
                .foregroundStyle(SkinColor.text3)

            Spacer().frame(height: 12)

            Text("RAW · TIFF · PNG · JPEG")
                .font(.skin(9).monospacedDigit())
                .tracking(1.3)
                .foregroundStyle(SkinColor.text4)

            Spacer().frame(height: 20)

            HStack(spacing: 8) {
                SkinButton("导入照片", icon: "square.and.arrow.down", kind: .primary) { actions.importPhotos() }
                SkinButton("导入文件夹", icon: "folder", kind: .secondary) { actions.importFolder() }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
