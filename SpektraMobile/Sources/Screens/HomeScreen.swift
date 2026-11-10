import SwiftUI
import Photos
import UniformTypeIdentifiers

struct HomeScreen: View {
    @ObservedObject var engine: MobileEngine
    let onOpenDevelop: (MPhoto) -> Void
    let onOpenGrade: (MPhoto) -> Void
    let onOpenCamera: () -> Void
    let onToast: (String) -> Void

    @State private var filter: HomeFilter = .all
    @State private var sortMode: HomeSort = .recent
    @State private var actionPhoto: MPhoto?
    @State private var folderPickerOpen = false
    @State private var didDebugOpen = false
    @State private var searchOpen = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.mSafeInsets) private var insets

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        filterRow
                        sectionHead
                        photoGrid
                        emptyHint
                    }
                    .padding(.bottom, 106)
                }
                .scrollIndicators(.never)
                // 下拉刷新＝重新扫描相册里的 RAW。
                .refreshable { await engine.refreshAssets() }
            }

            bottomBar

            if let photo = actionPhoto {
                photoActions(for: photo)
            }
        }
        .background(MColor.app)
        .fileImporter(
            isPresented: $folderPickerOpen,
            allowedContentTypes: [.folder, .rawImage, .image],
            allowsMultipleSelection: true
        ) { result in
            handleFolderImport(result)
        }
        .task {
            // 主页默认就是「相册里所有 RAW」，不再需要先点导入。
            await engine.refreshAssets()
        }
        .task {
            guard !didDebugOpen else { return }
            didDebugOpen = true
            if DebugLaunch.showSheet, let first = engine.photos.first {
                actionPhoto = first
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌字标落在开孔正下方居中：位置由真实安全区推导，刘海 / 灵动岛 / 无开孔三种形态都成立。
            HStack(spacing: 5) {
                Circle()
                    .fill(MColor.brass)
                    .frame(width: 4, height: 4)
                Text("SPEKTRAFILM")
                    .font(.mSans(8, .semibold))
                    .tracking(2.0)
                    .foregroundStyle(MColor.text4)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
            .padding(.bottom, 10)

            HStack(alignment: .center, spacing: 10) {
                if searchOpen {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MColor.text3)

                        TextField("搜索", text: $query)
                            .textFieldStyle(.plain)
                            .font(.mSans(12))
                            .foregroundStyle(MColor.text1)
                            .tint(MColor.brass)
                            .focused($searchFocused)

                        Button {
                            MHaptic.tick()
                            withAnimation(MMotion.state) {
                                query = ""
                                searchOpen = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(MColor.text3)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(MColor.surface1))
                    .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))
                } else {
                    Text("照片库")
                        .font(.pageTitle)
                        .tracking(0.3)
                        .foregroundStyle(MColor.text1)

                    Spacer(minLength: 0)

                    MCircleIconButton(icon: "magnifyingglass", size: 15) {
                        withAnimation(MMotion.state) {
                            searchOpen = true
                        }
                        searchFocused = true
                    }

                    Menu {
                        Button("最近导入") { sortMode = .recent }
                        Button("文件名") { sortMode = .filename }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MColor.text2)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(MColor.surface1))
                            .overlay(Circle().strokeBorder(MColor.hairline, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(visibleAssets.count) 张 RAW · \(gradedCount) 张已调色")
                    .mMeta(10, color: MColor.text3)

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, MMetric.pageMargin)
        .padding(.top, insets.top + 8)
        .padding(.bottom, 12)
    }

    // MARK: - 筛选

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(HomeFilter.allCases) { item in
                    MFilterChip(
                        title: item.title,
                        tone: item.tone,
                        selected: filter == item
                    ) {
                        withAnimation(MMotion.state) { filter = item }
                    }
                }

                MVerticalHairline(height: 16)
                    .padding(.horizontal, 3)

                ForEach(MColorLabel.allCases) { label in
                    MColorDotFilter(
                        label: label,
                        selected: filter == .label(label)
                    ) {
                        toggleLabel(label)
                    }
                }
            }
            .padding(.horizontal, MMetric.pageMargin)
        }
        .scrollIndicators(.never)
    }

    private func toggleLabel(_ label: MColorLabel) {
        MHaptic.tick()
        withAnimation(MMotion.state) {
            filter = filter == .label(label) ? .all : .label(label)
        }
    }

    private var sectionHead: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(filter.title)
                .font(.mSans(11, .semibold))
                .foregroundStyle(MColor.text2)

            Text("\(visibleAssets.count)")
                .mMeta(9.5, color: MColor.text4)

            Spacer(minLength: 0)

            Button {
                MHaptic.tick()
                withAnimation(MMotion.state) {
                    sortMode = sortMode == .recent ? .filename : .recent
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sortMode.title)
                        .font(.mSans(10, .medium))
                        .foregroundStyle(MColor.text3)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(MColor.text4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MMetric.pageMargin)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 网格

    private var photoGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            alignment: .leading,
            spacing: 18
        ) {
            ForEach(Array(visibleAssets.enumerated()), id: \.element.id) { item in
                MPhotoCard(
                    asset: item.element,
                    index: item.offset + 1,
                    busy: engine.importingAssetID == item.element.id,
                    onOpen: { open(item.element) },
                    onLongPress: {
                        guard let photo = item.element.photo else { return }
                        MHaptic.medium()
                        withAnimation(MMotion.drawer) { actionPhoto = photo }
                    }
                )
            }
        }
        .padding(.horizontal, MMetric.pageMargin)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MColor.text3)
                    Text("全部 · \(visibleAssets.count)")
                        .font(.mSans(10, .medium))
                        .foregroundStyle(MColor.text3)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Capsule().fill(MColor.surface1.opacity(0.92)))
                .overlay(Capsule().strokeBorder(MColor.hairline, lineWidth: 1))

                Spacer(minLength: 0)

                MCircleIconButton(icon: "arrow.up.arrow.down", size: 13, frame: 42) {
                    MHaptic.tick()
                    withAnimation(MMotion.state) {
                        sortMode = sortMode == .recent ? .filename : .recent
                    }
                }

                Button {
                    MHaptic.tick()
                    folderPickerOpen = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("导入")
                            .font(.mSans(12, .semibold))
                    }
                    .foregroundStyle(MColor.brassInk)
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .background(Capsule().fill(MColor.brass))
                    .contentShape(Capsule())
                }
                .buttonStyle(MPressStyle(scale: 0.94))
            }

            cameraEntry
        }
        .frame(height: 46)
        .padding(.horizontal, MMetric.pageMargin)
        .padding(.top, 10)
        .padding(.bottom, insets.bottom)
        .background(
            LinearGradient(
                colors: [MColor.app.opacity(0), MColor.app.opacity(0.94), MColor.app],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    /// 底部居中的圆形拍照入口：黄铜光圈按钮。
    private var cameraEntry: some View {
        Button {
            MHaptic.medium()
            onOpenCamera()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [MColor.brassHigh, MColor.brass, MColor.brassDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .strokeBorder(MColor.brassInk.opacity(0.24), lineWidth: 1)
                    .padding(4)

                Image(systemName: "camera.aperture")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(MColor.brassInk)
            }
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.46), radius: 10, y: 4)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(MColor.filmRed)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(MColor.app.opacity(0.55), lineWidth: 1))
                    .offset(x: -4, y: 4)
            }
        }
        .buttonStyle(MPressStyle(scale: 0.92))
        .accessibilityLabel("拍照")
    }

    // MARK: - 长按菜单

    private func photoActions(for photo: MPhoto) -> some View {
        ZStack(alignment: .bottom) {
            MColor.scrim
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture {
                    withAnimation(MMotion.drawer) { actionPhoto = nil }
                }

            VStack(spacing: 0) {
                MGrabber()

                HStack(spacing: 11) {
                    thumbnail(photo, width: 58, height: 46)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(photo.filename)
                            .font(.mSans(12, .semibold))
                            .foregroundStyle(MColor.text1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(photo.film) · \(photo.dimensions)")
                            .mMeta(9.5, color: MColor.text3)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(MMotion.drawer) { actionPhoto = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MColor.text3)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(MColor.surface2))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 12)

                MHairline()

                actionRow(
                    icon: "slider.horizontal.3",
                    title: "直接调色",
                    brass: true
                ) {
                    withAnimation(MMotion.drawer) { actionPhoto = nil }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        onOpenGrade(photo)
                    }
                }

                actionRow(
                    icon: "film",
                    title: "进入显影台"
                ) {
                    withAnimation(MMotion.drawer) { actionPhoto = nil }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        onOpenDevelop(photo)
                    }
                }

                MHairline().padding(.leading, 20)

                favoriteRow(photo)
                labelRow(photo)

                MHairline().padding(.leading, 20)

                actionRow(icon: "trash", title: "从库中移除", danger: true) {
                    withAnimation(MMotion.drawer) {
                        actionPhoto = nil
                        engine.remove(photoID: photo.id)
                    }
                    onToast("已从照片库移除")
                }

                Button {
                    withAnimation(MMotion.drawer) { actionPhoto = nil }
                } label: {
                    Text("取消")
                        .font(.mSans(12.5, .medium))
                        .foregroundStyle(MColor.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, insets.bottom + 4)
            }
            .background(MColor.surface1)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: MRadius.sheet,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: MRadius.sheet,
                    style: .continuous
                )
            )
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: MRadius.sheet,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: MRadius.sheet,
                    style: .continuous
                )
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
            }
            .transition(.move(edge: .bottom))
        }
        .ignoresSafeArea()
    }

    private func actionRow(
        icon: String,
        title: String,
        brass: Bool = false,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            MHaptic.light()
            action()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(brass ? MColor.brass : (danger ? MColor.danger : MColor.text3))
                    .frame(width: 26)

                Text(title)
                    .font(.mSans(12.5, .medium))
                    .foregroundStyle(danger ? MColor.danger : MColor.text1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MColor.text4)
            }
            .padding(.horizontal, 20)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func favoriteRow(_ photo: MPhoto) -> some View {
        Button {
            MHaptic.tick()
            withAnimation(MMotion.state) {
                engine.setFavorite(photoID: photo.id, value: !photo.favorite)
                actionPhoto = engine.photos.first { $0.id == photo.id }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: photo.favorite ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(photo.favorite ? MColor.brass : MColor.text3)
                    .frame(width: 26)
                Text(photo.favorite ? "取消收藏" : "加入收藏")
                    .font(.mSans(12.5, .medium))
                    .foregroundStyle(MColor.text1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func labelRow(_ photo: MPhoto) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "tag")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(MColor.text3)
                .frame(width: 26)

            Text("颜色标签")
                .font(.mSans(12.5, .medium))
                .foregroundStyle(MColor.text1)

            Spacer()

            HStack(spacing: 9) {
                ForEach(MColorLabel.allCases) { label in
                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.state) {
                            let newLabel: MColorLabel? = photo.color == label ? nil : label
                            engine.setColorLabel(photoID: photo.id, label: newLabel)
                            actionPhoto = engine.photos.first { $0.id == photo.id }
                        }
                    } label: {
                        Circle()
                            .fill(MColor.labelTone(label))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(MColor.text1, lineWidth: photo.color == label ? 1.5 : 0)
                                    .padding(-3)
                            )
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
    }

    /// 空态：没权限 / 没 RAW / 还在扫描，三种情况说清下一步。
    @ViewBuilder
    private var emptyHint: some View {
        if visibleAssets.isEmpty {
            VStack(spacing: 8) {
                switch engine.assetPhase {
                case .scanning, .idle:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(MColor.text4)
                    Text("正在扫描相册里的 RAW…")
                        .mMeta(10.5, color: MColor.text3)
                case .denied:
                    Image(systemName: "lock")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(MColor.text4)
                    Text("没有相册读取权限")
                        .font(.mSans(11.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Text("授权后主页会直接显示相册里所有 RAW")
                        .mMeta(10, color: MColor.text4)
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Text("打开设置")
                            .font(.mSans(11, .semibold))
                            .foregroundStyle(MColor.brassInk)
                            .padding(.horizontal, 15)
                            .frame(height: 32)
                            .background(Capsule().fill(MColor.brass))
                    }
                    .buttonStyle(MPressStyle(scale: 0.94))
                    .padding(.top, 2)
                case .ready:
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(MColor.text4)
                    Text("相册里没有 RAW 照片")
                        .font(.mSans(11.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Text("可以用「导入」从文件夹里挑 RAW")
                        .mMeta(10, color: MColor.text4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 56)
            .padding(.horizontal, MMetric.pageMargin)
        }
    }

    // MARK: - 从文件夹导入

    /// 导入按钮指向文件系统：可以选文件夹（递归取里面的 RAW），也可以直接多选 RAW 文件。
    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            return
        case .success(let urls):
            guard !urls.isEmpty else { return }
            var raws: [URL] = []
            var scoped: [URL] = []
            for url in urls {
                if url.startAccessingSecurityScopedResource() { scoped.append(url) }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    continue
                }
                if isDirectory.boolValue {
                    raws.append(contentsOf: Self.rawFiles(in: url))
                } else if ImageLoader.rawSuffixes.contains(url.pathExtension.lowercased()) {
                    raws.append(url)
                }
            }
            defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
            guard !raws.isEmpty else {
                onToast("选中的位置里没有 RAW 文件")
                return
            }
            let report = engine.importPhotos(raws)
            onToast(report.imported > 0
                    ? "已导入 \(report.imported) 张 RAW"
                    : (report.reason.isEmpty ? "导入失败" : report.reason))
        }
    }

    /// 递归列出目录下的 RAW 文件（跳过隐藏文件与包）。
    private static func rawFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let file as URL in enumerator
        where ImageLoader.rawSuffixes.contains(file.pathExtension.lowercased()) {
            found.append(file)
        }
        return found
    }

    // MARK: - 数据

    /// 主页数据源：相册里所有 RAW；没有相册权限时退化为已入库照片。
    private var visibleAssets: [MLibraryAsset] {
        let source: [MLibraryAsset] = engine.assetPhase == .ready
            ? engine.assets
            : engine.photos.map {
                MLibraryAsset(id: $0.id, filename: $0.filename, photo: $0, phAsset: nil)
            }

        var filtered = source.filter { asset in
            let photo = asset.photo
            switch filter {
            case .all: return true
            case .favorite: return photo?.favorite ?? false
            case .graded: return photo?.isGraded ?? false
            case .raw: return true
            case .label(let label): return photo?.color == label
            }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !keyword.isEmpty {
            filtered = filtered.filter { asset in
                asset.filename.lowercased().contains(keyword)
                    || (asset.photo?.film.lowercased().contains(keyword) ?? false)
                    || (asset.photo?.paper.lowercased().contains(keyword) ?? false)
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

    private var gradedCount: Int {
        engine.assets.isEmpty
            ? engine.photos.filter(\.isGraded).count
            : engine.assets.filter(\.isGraded).count
    }

    /// 点开一张照片：已入库直接进显影台，未入库先取回原片再进。
    private func open(_ asset: MLibraryAsset) {
        if let photo = asset.photo {
            onOpenDevelop(photo)
            return
        }
        guard asset.phAsset != nil else { return }
        Task {
            guard let photoID = await engine.importAsset(assetID: asset.id),
                  let photo = engine.photos.first(where: { $0.id == photoID }) else {
                onToast("这张 RAW 没能取回：可能还在 iCloud 且网络不可用")
                return
            }
            onOpenDevelop(photo)
        }
    }

    private func thumbnail(_ photo: MPhoto, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(MColor.surface2)
            if let image = MPhotoImage.load(photo) {
                image.resizable().scaledToFill()
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MColor.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 照片卡

private struct MPhotoCard: View {
    let asset: MLibraryAsset
    let index: Int
    /// 正在取回原片（iCloud 下载 / 入库）。
    let busy: Bool
    let onOpen: () -> Void
    let onLongPress: () -> Void

    @State private var longPressFired = false

    var body: some View {
        Button {
            if longPressFired {
                longPressFired = false
                return
            }
            MHaptic.light()
            onOpen()
        } label: {
            imageStage
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(MPressStyle(scale: 0.97))
        .disabled(busy)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.44)
                .onEnded { _ in
                    longPressFired = true
                    onLongPress()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        longPressFired = false
                    }
                }
        )
    }

    private var imageStage: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(MColor.surface2)

                if let photo = asset.photo, let image = MPhotoImage.load(photo) {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let phAsset = asset.phAsset {
                    MAssetThumb(asset: phAsset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.22), .clear, Color.black.opacity(0.38)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(alignment: .top) {
                    Text("RAW")
                        .font(.mSans(7.5, .semibold))
                        .tracking(0.8)
                        .foregroundStyle(MColor.text1.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(Color.black.opacity(0.52))
                        )

                    Spacer(minLength: 0)

                    Text(String(format: "%02d", index))
                        .font(.mSans(8, .medium).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.62))
                }
                .padding(8)

                HStack(spacing: 4) {
                    if asset.isImported {
                        Text(asset.photo?.film ?? "")
                            .font(.mSans(7.5, .medium))
                            .foregroundStyle(MColor.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(Color.black.opacity(0.55))
                            )
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 7, weight: .semibold))
                            Text("未导入")
                                .font(.mSans(7.5, .medium))
                        }
                        .foregroundStyle(MColor.text3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(Color.black.opacity(0.55))
                        )
                    }

                    if asset.isGraded {
                        HStack(spacing: 3) {
                            Circle().fill(MColor.brass).frame(width: 3, height: 3)
                            Text("已调色")
                                .font(.mSans(7.5, .medium))
                                .foregroundStyle(MColor.brass)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(Color.black.opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(MColor.brass.opacity(0.35), lineWidth: 1)
                        )
                    }

                    Spacer()

                    if asset.photo?.favorite == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(MColor.brass)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                    if let color = asset.photo?.color {
                        Circle()
                            .fill(MColor.labelTone(color))
                            .frame(width: 6, height: 6)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                    }
                }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .bottom)

                if busy {
                    ZStack {
                        Color.black.opacity(0.42)
                        VStack(spacing: 5) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(.white)
                            Text("取回原片")
                                .font(.mSans(8, .medium))
                                .foregroundStyle(Color.white.opacity(0.86))
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(height: 128)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRadius.card, style: .continuous)
                .strokeBorder(MColor.hairline, lineWidth: 1)
        )
    }
}

/// 相册缩略图（未入库的 RAW）。
private struct MAssetThumb: View {
    let asset: PHAsset

    @State private var image: UIImage?
    @State private var requested = false

    var body: some View {
        ZStack {
            Rectangle().fill(MColor.surface2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .onAppear(perform: request)
    }

    private func request() {
        guard !requested else { return }
        requested = true
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 360, height: 360),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async { image = result }
        }
    }
}

// MARK: - 筛选 / 排序

enum HomeFilter: Identifiable, Hashable, CaseIterable {
    case all, favorite, graded, raw, label(MColorLabel)

    var id: String { title }

    static var allCases: [HomeFilter] {
        [.all, .favorite, .graded, .raw]
    }

    var title: String {
        switch self {
        case .all: return "全部"
        case .favorite: return "收藏"
        case .graded: return "已调色"
        case .raw: return "RAW"
        case .label(let label): return label.title
        }
    }

    var tone: MColorLabel? {
        if case .label(let label) = self { return label }
        return nil
    }
}

enum HomeSort {
    case recent, filename

    var title: String {
        switch self {
        case .recent: return "最近"
        case .filename: return "文件名"
        }
    }
}

private struct MColorDotFilter: View {
    let label: MColorLabel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Circle()
                .fill(MColor.labelTone(label))
                .frame(width: 9, height: 9)
                .frame(width: 28, height: 30)
                .background(
                    Circle().fill(selected ? MColor.surface3 : Color.clear)
                )
                .overlay(
                    Circle().strokeBorder(
                        selected ? MColor.labelTone(label).opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
