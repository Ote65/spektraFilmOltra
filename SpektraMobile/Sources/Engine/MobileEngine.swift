import Foundation
import SwiftUI
import Photos
import ImageIO
import UniformTypeIdentifiers

/// 移动端状态中枢：照片库、导入、缩略图、显影/调色会话。
/// 照片库放在 `Spektrafilm/MobileLibrary`，与桌面版库互不干扰。
@MainActor
final class MobileEngine: ObservableObject {
    struct ImportReport {
        var imported: Int = 0
        var rejected: Int = 0
        var firstID: String?
        /// 第一张被拒的原因（文件名 / 错误文案），用于把失败原因透出到 toast 与日志。
        var reason: String = ""
    }

    /// 主页相册扫描的状态机。
    enum AssetPhase: Equatable {
        case idle
        case scanning
        /// 没有相册权限：主页退化显示已入库照片。
        case denied
        case ready
    }

    let store: LibraryStore

    @Published private(set) var photos: [MPhoto] = []
    /// 主页网格的数据源：当前选中相簿/智能筛选对应的相册资产。
    @Published private(set) var assets: [MLibraryAsset] = []
    @Published private(set) var assetPhase: AssetPhase = .idle
    /// 主页筛选：全部 / 收藏 / RAW / 已调色 / 某个相簿。
    @Published private(set) var scope: MAssetScope = .all
    /// 系统相册里的用户相簿，供顶部类型按钮使用。
    @Published private(set) var albums: [MAlbum] = []
    /// 相册里是否存在 RAW 智能相簿（没有 RAW 照片时系统不提供）。
    @Published private(set) var hasRawAlbum = false
    @Published private(set) var developSession: MobileDevelopSession?
    @Published private(set) var gradeSession: MobileGradeSession?
    @Published private(set) var isImporting = false
    /// 正在按需取原片的资产 id（iCloud 下载 + 入库），用于格子上显示转圈。
    @Published private(set) var importingAssetID: String?
    /// 文件名 → 相册资产：软件里的收藏/删除要同步回系统相册。
    private var phAssetByFilename: [String: PHAsset] = [:]

    private let thumbnailQueue = DispatchQueue(label: "spektra.mobile.thumb", qos: .utility)
    /// 相册刷新令牌：切换筛选或重复触发时只认最后一次结果，避免旧扫描覆盖新列表。
    private var assetRefreshToken = 0
    /// 上次成功映射的相册快照：冷启动先出列表，再后台刷新。
    private var snapshotURL: URL { store.root.appendingPathComponent("album-snapshot.json") }
    /// 本次运行内各筛选的结果缓存：切回已看过的筛选时直接出列表，不再等重新取图。
    private var scopeCache: [MAssetScope: [MLibraryAsset]] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spektrafilm/MobileLibrary", isDirectory: true)
        store = LibraryStore(root: base, keepsEncodedRecords: true)
        refreshPhotos()
        warmThumbnails()
        importDebugFileIfNeeded()
    }

    /// 验收脚本用：`--import <绝对路径>` 在启动时把指定 RAW 入库，省掉手工点「导入」。
    /// 只在显式传入该参数时生效，Release 构建也保留（自动化截图需要）。
    private func importDebugFileIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--import"), args.indices.contains(index + 1) else { return }
        let path = args[index + 1]
        guard FileManager.default.fileExists(atPath: path) else { return }
        _ = importPhotos([URL(fileURLWithPath: path)])
    }

    // MARK: - 照片库

    func refreshPhotos() {
        // 关掉「支持 JPEG」时，库里已导入的编码图只是不在主页露出，记录本身保留。
        let allowNonRaw = MobileSettings.allowNonRaw
        photos = store.photos
            .filter {
                allowNonRaw || ImageLoader.rawSuffixes.contains(
                    URL(fileURLWithPath: $0.originalPath).pathExtension.lowercased()
                )
            }
            .sorted { $0.importedAt > $1.importedAt }
            .map(makePhoto)
        relinkAssets()
    }

    // MARK: - 相册映射

    /// 切换主页筛选：有缓存时立刻换列表，再后台刷新该筛选。
    func selectScope(_ newScope: MAssetScope) {
        guard scope != newScope else { return }
        scope = newScope
        if case .graded = newScope {
            // 已调色是本地库数据，同步算出来，切过去立刻生效。
            assets = gradedAssets()
            scopeCache[.graded] = assets
            assetPhase = .ready
        } else if let cached = scopeCache[newScope], !cached.isEmpty {
            assets = cached
            assetPhase = .ready
        } else if newScope == .all {
            // 还没有「全部」缓存时，至少用上次的快照先铺满列表，避免停在旧筛选上。
            _ = restoreSnapshotIfNeeded()
        }
        Task { await refreshAssets() }
    }

    /// 直接映射系统相册：RAW 用系统 RAW 智能相簿，收藏用系统收藏相簿，
    /// 其余按用户相簿取图。不做逐张 EXIF 扫描，切筛选不额外读盘。
    /// 主页打开就调这个：不需要先「导入」，相册里的照片直接可浏览。
    func refreshAssets() async {
        // 冷启动先用上次的相册快照秒开，再后台刷新；扫描期间列表不会空着。
        let restored = restoreSnapshotIfNeeded()
        assetPhase = restored ? .ready : .scanning
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            assets = []
            assetPhase = .denied
            return
        }
        loadAlbums()
        assetRefreshToken += 1
        let token = assetRefreshToken
        let scope = self.scope
        if case .graded = scope {
            assets = gradedAssets()
            scopeCache[scope] = assets
            assetPhase = .ready
            return
        }
        let scanned = await Self.fetchAssets(scope: scope,
                                             allowNonRaw: MobileSettings.allowNonRaw)
        // 旧扫描晚回来时丢弃，避免列表被过期结果覆盖。
        guard token == assetRefreshToken else { return }
        let byName = Dictionary(
            store.photos.map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in scanned {
            phAssetByFilename[item.filename] = item.asset
        }
        assets = scanned.map { item in
            MLibraryAsset(
                id: item.asset.localIdentifier,
                filename: item.filename,
                photo: byName[item.filename].map(makePhoto),
                phAsset: item.asset
            )
        }
        assetPhase = .ready
        scopeCache[scope] = assets
        if case .all = scope {
            saveSnapshot(scanned)
        }
        NSLog("MAssets scope=%@ count=%d", String(describing: scope), assets.count)
    }

    // MARK: - 相册快照

    private struct AlbumSnapshot: Codable {
        let id: String
        let filename: String
        let isRaw: Bool
    }

    /// 冷启动恢复：读上次的资产 id 列表，一次性按 id 取回 PHAsset，列表立即可见。
    /// 只用于「全部」，其余相簿由用户点选后现取；快照不在时退回正常加载。
    private func restoreSnapshotIfNeeded() -> Bool {
        guard case .all = scope, scopeCache[.all] == nil else { return false }
        guard let data = try? Data(contentsOf: snapshotURL),
              let list = try? JSONDecoder().decode([AlbumSnapshot].self, from: data) else {
            return false
        }
        let allowNonRaw = MobileSettings.allowNonRaw
        let usable = list.filter { allowNonRaw || $0.isRaw }
        guard !usable.isEmpty else { return false }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: usable.map(\.id), options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }

        let byName = Dictionary(
            store.photos.map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let restored: [MLibraryAsset] = usable.compactMap { item in
            guard let asset = byID[item.id] else { return nil }
            return MLibraryAsset(id: item.id, filename: item.filename,
                                 photo: byName[item.filename].map(makePhoto), phAsset: asset)
        }
        guard !restored.isEmpty else { return false }
        for item in restored {
            if let asset = item.phAsset { phAssetByFilename[item.filename] = asset }
        }
        assets = restored
        scopeCache[.all] = restored
        return true
    }

    /// 刷新成功后落盘，供下次冷启动秒开；只写资产 id / 文件名 / 是否 RAW。
    private func saveSnapshot(_ scanned: [(asset: PHAsset, filename: String)]) {
        let list = scanned.map { item in
            AlbumSnapshot(
                id: item.asset.localIdentifier,
                filename: item.filename,
                isRaw: ImageLoader.rawSuffixes.contains(
                    (item.filename as NSString).pathExtension.lowercased()
                )
            )
        }
        let url = snapshotURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 用户相簿列表 + 系统 RAW 智能相簿是否可用。
    private func loadAlbums() {
        var found: [MAlbum] = []
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle else { return }
            found.append(MAlbum(id: collection.localIdentifier, title: title))
        }
        albums = found.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        hasRawAlbum = Self.smartAlbum(.smartAlbumRAW) != nil
    }

    nonisolated static func smartAlbum(_ subtype: PHAssetCollectionSubtype) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: subtype, options: nil
        ).firstObject
    }

    /// 已调色是软件自己的筛选标准，直接取本地库里调过的照片。
    private func gradedAssets() -> [MLibraryAsset] {
        store.photos
            .filter { !$0.edit.quickIntents.isEmpty }
            .sorted { $0.importedAt > $1.importedAt }
            .map {
                MLibraryAsset(id: $0.id, filename: $0.filename,
                              photo: makePhoto($0), phAsset: nil)
            }
    }

    /// 已入库状态变化时（导入 / 调色落盘）只重接引用，不重扫相册。
    private func relinkAssets() {
        guard !assets.isEmpty else { return }
        let byName = Dictionary(
            store.photos.map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        assets = assets.map { asset in
            guard let photo = byName[asset.filename] else {
                return MLibraryAsset(id: asset.id, filename: asset.filename,
                                     photo: nil, phAsset: asset.phAsset)
            }
            return MLibraryAsset(id: asset.id, filename: asset.filename,
                                 photo: makePhoto(photo), phAsset: asset.phAsset)
        }
        // 编辑记录变化后同步缓存，切回这个筛选时不会看到旧状态。
        scopeCache[scope] = assets
    }

    /// 点开一张还没入库的相册照片：取回原片（iCloud 上也允许下载）→ 入库。
    /// 返回可用的 photoID；失败返回 nil。
    func importAsset(assetID: String) async -> String? {
        guard importingAssetID == nil else { return nil }
        if let existing = assets.first(where: { $0.id == assetID })?.photo {
            return existing.id
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID], options: nil
        ).firstObject else { return nil }
        guard let resource = Self.displayResource(for: asset,
                                                  allowNonRaw: MobileSettings.allowNonRaw) else {
            return nil
        }

        importingAssetID = assetID
        defer { importingAssetID = nil }

        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "dng"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource, toFile: url, options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            NSLog("MAssets fetch failed %@ — %@", assetID, error.localizedDescription)
            return nil
        }

        // 用相册里的原始文件名入库：`LibraryStore.importPhoto` 靠「同名 + 同尺寸」
        // 去重，所以重复点开同一张不会产生副本，编辑记录也还在。
        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent(resource.originalFilename)
        try? FileManager.default.removeItem(at: named)
        guard (try? FileManager.default.moveItem(at: url, to: named)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: named) }

        let report = importPhotos([named])
        return report.firstID
    }

    /// 按当前筛选直接取相册内容；同一个资产只收一次。
    /// nonisolated：真正的取图与筛选在后台队列执行，不继承 @MainActor 隔离。
    nonisolated private static func fetchAssets(scope: MAssetScope, allowNonRaw: Bool)
        async -> [(asset: PHAsset, filename: String)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result: PHFetchResult<PHAsset>
                switch scope {
                case .all, .graded:
                    result = PHAsset.fetchAssets(with: .image, options: options)
                case .favorites:
                    result = smartAlbum(.smartAlbumFavorites).map {
                        PHAsset.fetchAssets(in: $0, options: options)
                    } ?? PHAsset.fetchAssets(with: .image, options: options)
                case .raw:
                    // RAW 直接用系统自带的 RAW 智能相簿，不再逐张判断扩展名。
                    result = smartAlbum(.smartAlbumRAW).map {
                        PHAsset.fetchAssets(in: $0, options: options)
                    } ?? PHAsset.fetchAssets(with: .image, options: options)
                case .album(let id):
                    let collection = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [id], options: nil).firstObject
                    result = collection.map {
                        PHAsset.fetchAssets(in: $0, options: options)
                    } ?? PHAsset.fetchAssets(with: .image, options: options)
                }
                var found: [(asset: PHAsset, filename: String)] = []
                var seen = Set<String>()
                result.enumerateObjects { asset, _, _ in
                    // 主页用 localIdentifier 当卡片身份，重复项会让网格重复渲染同一张照片。
                    guard seen.insert(asset.localIdentifier).inserted else { return }
                    guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
                    guard let resource = displayResource(for: asset, allowNonRaw: allowNonRaw) else {
                        return
                    }
                    found.append((asset, resource.originalFilename))
                }
                continuation.resume(returning: found)
            }
        }
    }

    /// 主页可见的本体：RAW 一律收；打开「支持 JPEG」后收所有可显影编码图
    /// （JPEG / HEIC / PNG / TIFF…），「全部 / 收藏」才能和系统相册一致；
    /// 关闭时非 RAW 全部不收。
    private nonisolated static func displayResource(for asset: PHAsset,
                                                    allowNonRaw: Bool) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if let raw = resources.first(where: {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        }) {
            return raw
        }
        guard allowNonRaw else { return nil }
        let encoded = resources.filter {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .image) == true
        }
        // 优先 JPEG；没有 JPEG 时用 HEIC / PNG / TIFF 等可解码编码图。
        return encoded.first { UTType($0.uniformTypeIdentifier)?.conforms(to: .jpeg) == true }
            ?? encoded.first
    }

    @discardableResult
    func importPhotos(_ urls: [URL]) -> ImportReport {
        var report = ImportReport()
        isImporting = true
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let photo = try store.importPhoto(from: url,
                                                  allowingEncoded: MobileSettings.allowNonRaw)
                report.imported += 1
                report.firstID = report.firstID ?? photo.id
                generateThumbnail(for: photo)
            } catch {
                report.rejected += 1
                if report.reason.isEmpty {
                    report.reason = "\(url.lastPathComponent)：\((error as NSError).localizedDescription)"
                }
                NSLog("MImport rejected %@ — %@", url.lastPathComponent,
                      (error as NSError).localizedDescription)
            }
        }
        isImporting = false
        refreshPhotos()
        return report
    }

    func remove(photoID: String) {
        if let photo = store.photos.first(where: { $0.id == photoID }),
           let thumbnail = photo.thumbnailPath {
            MThumbnailCache.shared.remove(path: thumbnail)
        }
        try? store.remove(id: photoID)
        refreshPhotos()
    }

    /// 从系统相册删除选中的 RAW。系统会自己弹一次删除确认；
    /// 成功后再清掉库里的编辑记录与原图副本，避免主页残留「已入库」条目。
    func deleteAssets(assetIDs: [String], photoIDs: [String]) async -> Int {
        guard !assetIDs.isEmpty else { return 0 }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard fetched.count > 0 else { return 0 }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(fetched)
            }
        } catch {
            NSLog("MDelete failed %@", error.localizedDescription)
            return 0
        }
        for id in photoIDs {
            remove(photoID: id)
        }
        await refreshAssets()
        return fetched.count
    }

    /// 把显影/胶片/相纸/片边全部还原到导入时的初始状态。
    /// 只有 RAW 解码所需的输入色彩信息保留，否则原片会读不出来。
    func resetEdits(photoID: String) {
        guard var photo = store.photos.first(where: { $0.id == photoID }) else { return }
        var restored: PhotoEdit
        if let data = photo.initialEditData,
           let decoded = try? JSONDecoder().decode(PhotoEdit.self, from: data) {
            restored = decoded
        } else {
            restored = PhotoEdit()
            restored.io.inputColorSpace = photo.edit.io.inputColorSpace
            restored.io.inputCCTFDecoding = photo.edit.io.inputCCTFDecoding
        }
        restored.io.outputColorSpace = photo.edit.io.outputColorSpace
        restored.io.outputCCTFEncoding = photo.edit.io.outputCCTFEncoding
        photo.edit = restored
        photo.quickBaselineData = nil
        photo.borderData = nil

        // 缩略图是按旧参数显影的，清掉后按初始状态重建。
        // 缓存键用的是缩略图绝对路径，必须按 URL 清，否则会继续显示旧图。
        if photo.thumbnailPath != nil, let url = store.thumbnailURL(for: photo) {
            MThumbnailCache.shared.remove(path: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        photo.thumbnailPath = nil
        try? store.update(photo)
        refreshPhotos()
        if let refreshed = store.photos.first(where: { $0.id == photoID }) {
            generateThumbnail(for: refreshed)
        }
    }

    /// 软件里的收藏直接写回系统相册，主页「收藏」读的也是相册收藏。
    func setFavorite(photoID: String, value: Bool) {
        mutate(photoID: photoID) { $0.favorite = value }
        guard let photo = store.photos.first(where: { $0.id == photoID }),
              let asset = phAssetByFilename[photo.filename] else { return }
        Task { await applyFavorite(asset: asset, filename: photo.filename, value: value) }
    }

    /// 未入库的相册照片：收藏/取消收藏写进系统相册。
    func setAssetFavorite(assetID: String, value: Bool) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID],
                                              options: nil).firstObject else { return }
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
        Task { await applyFavorite(asset: asset, filename: filename, value: value) }
    }

    private func applyFavorite(asset: PHAsset, filename: String?, value: Bool) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = value
            }
        } catch {
            NSLog("MFavorite failed %@", error.localizedDescription)
            return
        }
        if let filename, let photo = store.photos.first(where: { $0.filename == filename }) {
            mutate(photoID: photo.id) { $0.favorite = value }
        }
        await refreshAssets()
    }

    func isFavorite(_ asset: MLibraryAsset) -> Bool {
        // 相册收藏优先；本地库里没有对应资产时才退回软件收藏。
        asset.phAsset?.isFavorite ?? asset.photo?.favorite ?? false
    }

    func setColorLabel(photoID: String, label: MColorLabel?) {
        mutate(photoID: photoID) { $0.colorLabel = label?.rawValue }
    }

    private func mutate(photoID: String, _ body: (inout LibraryPhoto) -> Void) {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else { return }
        var copy = photo
        body(&copy)
        try? store.update(copy)
        refreshPhotos()
    }

    private func makePhoto(_ photo: LibraryPhoto) -> MPhoto {
        let ev = photo.edit.camera.exposureCompensationEV
        let exposure: String
        if abs(ev) < 0.05 {
            exposure = "0"
        } else {
            exposure = String(format: "%+.1f EV", ev)
        }
        let sideways = photo.edit.rotationTurns % 2 == 1
        let displayWidth = sideways ? photo.height : photo.width
        let displayHeight = sideways ? photo.width : photo.height
        return MPhoto(
            id: photo.id,
            filename: photo.filename,
            film: MobileCatalog.filmName(photo.edit.filmStock),
            paper: MobileCatalog.paperName(photo.edit.printStock),
            dimensions: displayWidth > 0 ? "\(displayWidth)×\(displayHeight)" : "",
            isRaw: photo.isRaw,
            favorite: photo.favorite,
            color: photo.colorLabel.flatMap(MColorLabel.init(rawValue:)),
            isGraded: !photo.edit.quickIntents.isEmpty,
            exposure: exposure,
            thumbnailURL: store.thumbnailURL(for: photo)
        )
    }

    private func warmThumbnails() {
        let allowNonRaw = MobileSettings.allowNonRaw
        for photo in store.photos where photo.thumbnailPath == nil {
            // 关掉「支持 JPEG」时编码图不在主页显示，不必为它们提前解码。
            guard allowNonRaw || ImageLoader.rawSuffixes.contains(
                URL(fileURLWithPath: photo.originalPath).pathExtension.lowercased()
            ) else { continue }
            generateThumbnail(for: photo)
        }
    }

    private func generateThumbnail(for photo: LibraryPhoto) {
        guard photo.thumbnailPath == nil else { return }
        let id = photo.id
        let url = store.originalURL(for: photo)
        let edit = photo.edit
        let options = edit.rawDecoderOptions()
        thumbnailQueue.async { [weak self] in
            guard let self else { return }
            guard let loaded = try? ImageLoader.load(url: url, maxSize: 320, rawOptions: options,
                                                     rotationTurns: edit.rotationTurns,
                                                     allowEncoded: true),
                  var params = try? edit.runtimeParams() else { return }
            params.io.inputColorSpace = loaded.colorSpace
            params.io.inputCCTFDecoding = loaded.cctfDecoding
            let small = Resize.smallPreview(loaded.image, maxSize: 320)
            var output = SimulationPipeline(params: params, keepTaps: false).process(small).rgbOut
            if edit.monochrome {
                // 缩略图跟随显影台的黑白模式，避免主页仍显示彩色预览。
                output = output.map { pixel in
                    let value = pixel.x * 0.2126 + pixel.y * 0.7152 + pixel.z * 0.0722
                    return Vec3(value, value, value)
                }
            }
            Task { @MainActor in
                try? self.store.writeThumbnail(id: id, image: output)
                self.refreshPhotos()
            }
        }
    }

    // MARK: - 显影会话

    @discardableResult
    func openDevelop(photoID: String) -> MobileDevelopSession? {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else { return nil }
        developSession?.cancel()
        let session = MobileDevelopSession(photo: photo, store: store)
        session.onPersist = { [weak self] _ in self?.refreshPhotos() }
        developSession = session
        session.start()
        return session
    }

    func closeDevelop() {
        developSession?.finish()
        developSession?.cancel()
        let photoID = developSession?.photoID
        developSession = nil
        refreshPhotos()
        // 回主页前按最终显影参数重建缩略图，黑白预设或换片后主页不再显示旧观感。
        if let photoID {
            regenerateThumbnail(photoID: photoID)
        }
    }

    private func regenerateThumbnail(photoID: String) {
        guard var photo = store.photos.first(where: { $0.id == photoID }) else { return }
        if photo.thumbnailPath != nil, let url = store.thumbnailURL(for: photo) {
            MThumbnailCache.shared.remove(path: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        photo.thumbnailPath = nil
        try? store.update(photo)
        refreshPhotos()
        if let refreshed = store.photos.first(where: { $0.id == photoID }) {
            generateThumbnail(for: refreshed)
        }
    }

    // MARK: - 调色会话

    /// 从主页直接进调色台时，临时建一个不显示的显影会话，只为产出交接像素。
    /// `.direct` 入口不跑显影：交接图由原片直接解码，照片原样进入调色台。
    func openGrade(photoID: String, entry: MGradeEntry) -> MobileGradeSession? {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else { return nil }
        let develop: MobileDevelopSession
        if let current = developSession, current.photoID == photoID {
            develop = current
            current.finish()
        } else {
            develop = MobileDevelopSession(photo: photo, store: store)
            if entry != .direct {
                develop.start()
            }
        }
        let grade = MobileGradeSession(
            photo: photo, store: store, develop: develop,
            source: entry == .direct ? .original : .developed)
        gradeSession = grade
        if let id = DebugLaunch.gradeBorder,
           let preset = MFilmBorderPreset.preset(id: id) {
            grade.setBorderPreset(preset)
        }
        grade.start()
        return grade
    }

    func closeGrade() {
        gradeSession?.cancel()
        gradeSession = nil
    }
}
