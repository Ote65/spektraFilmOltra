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
    /// 导入准备（文件复制 + 头部探测）在后台串行执行，主线程只提交结果。
    nonisolated private static let importQueue = DispatchQueue(
        label: "spektra.mobile.import", qos: .userInitiated)
    /// 相册刷新令牌：切换筛选或重复触发时只认最后一次结果，避免旧扫描覆盖新列表。
    private var assetRefreshToken = 0
    /// 缩略图连续写回时的合并刷新任务。
    private var refreshWork: DispatchWorkItem?
    /// 只为调色临时创建的显影会话；关闭调色台时必须一并取消。
    private var transientDevelopSession: MobileDevelopSession?

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
    /// 这条路径必须同步完成，后续截图才会拿到库内照片；只在显式调试参数下执行。
    private func importDebugFileIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--import"), args.indices.contains(index + 1) else { return }
        let path = args[index + 1]
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let photo = try? store.importPhoto(
            from: URL(fileURLWithPath: path), allowingEncoded: MobileSettings.allowNonRaw
        ) else { return }
        generateThumbnail(for: photo)
        refreshPhotos()
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

    /// 切换主页筛选：立即按目标相簿重新映射相册。
    func selectScope(_ newScope: MAssetScope) {
        guard scope != newScope else { return }
        scope = newScope
        Task { await refreshAssets() }
    }

    /// 直接映射系统相册：RAW 用系统 RAW 智能相簿，收藏用系统收藏相簿，
    /// 其余按用户相簿取图。不做逐张 EXIF 扫描，切筛选不额外读盘。
    /// 主页打开就调这个：不需要先「导入」，相册里的照片直接可浏览。
    func refreshAssets() async {
        assetPhase = .scanning
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
        // 兜底：已入库但还没出现在相册里的照片（例如导入后相册写入尚未完成）也要可见。
        // 只在「全部」合并，避免收藏 / RAW / 相簿范围出现相册以外的条目。
        // 用过滤后的 photos（跟随「支持 JPEG」开关），不能直接用 store.photos。
        if case .all = scope {
            let mapped = Set(assets.map(\.filename))
            let extras = photos
                .filter { !mapped.contains($0.filename) }
                .map {
                    MLibraryAsset(id: $0.id, filename: $0.filename,
                                  photo: $0, phAsset: nil)
                }
            assets.insert(contentsOf: extras, at: 0)
        }
        assetPhase = .ready
        NSLog("MAssets scope=%@ count=%d", String(describing: scope), assets.count)
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

        // 这张照片本来就来自系统相册，入库即可，不要再写回相册制造副本。
        let report = await importPhotos([named], publishToAlbum: false)
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

    /// 导入照片：文件复制与头部探测在后台串行完成，主线程只提交库状态与刷新列表。
    /// 新入库的原片随后异步写进系统相册（`publishToAlbum`），主页按相册映射才能看到它们。
    @discardableResult
    func importPhotos(_ urls: [URL], publishToAlbum: Bool = true) async -> ImportReport {
        var report = ImportReport()
        guard !urls.isEmpty else { return report }
        isImporting = true
        defer { isImporting = false }

        let allowingEncoded = MobileSettings.allowNonRaw
        let store = self.store
        let staged = await Self.stageImports(
            urls, allowingEncoded: allowingEncoded, store: store)
        var imported: [LibraryPhoto] = []
        // 只有真正新增的库内记录才写相册；重复导入同名照片不会再产生相册副本。
        let knownIDs = Set(store.photos.map(\.id))
        var publishedIDs = Set<String>()
        for item in staged {
            switch item.result {
            case .success(let value):
                do {
                    let photo = try store.commitImport(value, persist: false)
                    report.imported += 1
                    report.firstID = report.firstID ?? photo.id
                    if !knownIDs.contains(photo.id), publishedIDs.insert(photo.id).inserted {
                        imported.append(photo)
                    }
                    generateThumbnail(for: photo)
                } catch {
                    report.rejected += 1
                    if report.reason.isEmpty {
                        report.reason = "\(item.url.lastPathComponent)：\(error.localizedDescription)"
                    }
                }
            case .failure(let error):
                report.rejected += 1
                if report.reason.isEmpty {
                    report.reason = "\(item.url.lastPathComponent)：\((error as NSError).localizedDescription)"
                }
                NSLog("MImport rejected %@ — %@", item.url.lastPathComponent,
                      (error as NSError).localizedDescription)
            }
        }
        if report.imported > 0 {
            // 整批只落盘一次；索引用异步快照，主线程不做 JSON 编码与磁盘 IO。
            store.saveAsync()
        }
        refreshPhotos()
        if publishToAlbum {
            publishImportsToAlbum(imported)
        }
        return report
    }

    /// 后台准备导入：只做复制与探测，不触碰库状态。
    private nonisolated static func stageImports(
        _ urls: [URL], allowingEncoded: Bool, store: LibraryStore
    ) async -> [(url: URL, result: Result<LibraryStore.StagedImport, Error>)] {
        await withCheckedContinuation { continuation in
            importQueue.async {
                var results: [(URL, Result<LibraryStore.StagedImport, Error>)] = []
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    let result = Result {
                        try store.stageImport(from: url, allowingEncoded: allowingEncoded)
                    }
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    results.append((url, result))
                }
                continuation.resume(returning: results)
            }
        }
    }

    /// 把新导入的原片写进系统相册。主页只映射相册，不写相册就等于「导入后看不见」。
    /// 相册权限被拒时静默跳过，库内记录与缩略图仍然保留。
    private func publishImportsToAlbum(_ imported: [LibraryPhoto]) {
        guard !imported.isEmpty else { return }
        let store = self.store
        Task { [weak self] in
            guard let self else { return }
            for photo in imported {
                let source = store.originalURL(for: photo)
                let filename = photo.filename
                guard let temp = await Task.detached(priority: .utility, operation: {
                    Self.prepareAlbumFile(source: source, filename: filename)
                }).value else { continue }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    PhotoLibraryExport.save(temp) { _ in
                        try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
                        continuation.resume()
                    }
                }
            }
            await self.refreshAssets()
        }
    }

    /// 相册写入要求文件名保持原样，主页按 originalFilename 把资产映射回库内记录。
    /// 每个文件放在独立临时目录里，避免并发导入同名文件时互相覆盖。
    private nonisolated static func prepareAlbumFile(source: URL, filename: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(filename)
        guard (try? FileManager.default.copyItem(at: source, to: temp)) != nil else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return temp
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
        let store = self.store
        let url = store.originalURL(for: photo)
        let edit = photo.edit
        let options = edit.rawDecoderOptions()
        thumbnailQueue.async { [weak self, store] in
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
            // PNG 编码与写盘留在后台队列；主线程只写回路径并做一次合并刷新。
            let path = try? store.writeThumbnailFile(
                id: id, image: output, colorSpace: edit.io.outputColorSpace)
            Task { @MainActor in
                guard let self, let path else { return }
                self.store.commitThumbnail(id: id, relativePath: path)
                self.refreshPhotosSoon()
            }
        }
    }

    /// 批量补缩略图时避免每张都全量重建主页列表。
    private func refreshPhotosSoon() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refreshPhotos()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - 显影会话

    @discardableResult
    func openDevelop(photoID: String) -> MobileDevelopSession? {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else { return nil }
        transientDevelopSession?.cancel()
        transientDevelopSession = nil
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
            transientDevelopSession?.cancel()
            transientDevelopSession = nil
            develop = current
            current.finish()
        } else {
            let temp = MobileDevelopSession(photo: photo, store: store)
            if entry != .direct {
                temp.start()
            }
            transientDevelopSession?.cancel()
            transientDevelopSession = temp
            develop = temp
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
        // 分栏胶片条换图产生的临时显影会话不归 developSession 管，必须在这里收尾。
        transientDevelopSession?.cancel()
        transientDevelopSession = nil
    }
}
