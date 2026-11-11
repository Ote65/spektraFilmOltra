import Foundation
import SwiftUI
import Photos
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
    /// 主页网格的数据源：相册里所有带 RAW 本体的照片（已入库的会带上编辑信息）。
    @Published private(set) var assets: [MLibraryAsset] = []
    @Published private(set) var assetPhase: AssetPhase = .idle
    @Published private(set) var developSession: MobileDevelopSession?
    @Published private(set) var gradeSession: MobileGradeSession?
    @Published private(set) var isImporting = false
    /// 正在按需取原片的资产 id（iCloud 下载 + 入库），用于格子上显示转圈。
    @Published private(set) var importingAssetID: String?
    /// 未入库相册 RAW 的收藏：只记在本地偏好里，不强迫用户为了收藏先把原片复制进库。
    @Published private(set) var assetFavorites: Set<String> = []

    private let thumbnailQueue = DispatchQueue(label: "spektra.mobile.thumb", qos: .utility)
    private static let assetFavoritesKey = "mobile.asset.favorites"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spektrafilm/MobileLibrary", isDirectory: true)
        store = LibraryStore(root: base)
        assetFavorites = Set(UserDefaults.standard.stringArray(forKey: Self.assetFavoritesKey) ?? [])
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
        photos = store.photos
            .sorted { $0.importedAt > $1.importedAt }
            .map(makePhoto)
        relinkAssets()
    }

    // MARK: - 相册 RAW

    /// 扫描系统相册，只保留真正带 RAW 本体的资产，并把已入库的编辑记录接上。
    /// 主页打开就调这个：不需要先「导入」，相册里的 RAW 直接可浏览。
    func refreshAssets() async {
        assetPhase = .scanning
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            assets = []
            assetPhase = .denied
            return
        }
        let scanned = await Self.scanRawAssets()
        let byName = Dictionary(
            store.photos.map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        assets = scanned.map { item in
            MLibraryAsset(
                id: item.asset.localIdentifier,
                filename: item.filename,
                photo: byName[item.filename].map(makePhoto),
                phAsset: item.asset
            )
        }
        assetPhase = .ready
        NSLog("MAssets scanned raw=%d imported=%d",
              assets.count, assets.filter(\.isImported).count)
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

    /// 点开一张还没入库的相册 RAW：取回原片（iCloud 上也允许下载）→ 入库。
    /// 返回可用的 photoID；失败返回 nil。
    func importAsset(assetID: String) async -> String? {
        guard importingAssetID == nil else { return nil }
        if let existing = assets.first(where: { $0.id == assetID })?.photo {
            return existing.id
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID], options: nil
        ).firstObject else { return nil }
        guard let resource = Self.rawResource(for: asset) else { return nil }

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
        // 入库前收藏过这张相册 RAW：把收藏状态接到编辑记录上，避免看起来丢了。
        if let id = report.firstID, assetFavorites.contains(assetID) {
            setFavorite(photoID: id, value: true)
            setAssetFavorite(assetID: assetID, value: false)
        }
        return report.firstID
    }

    private static func scanRawAssets() async -> [(asset: PHAsset, filename: String)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: .image, options: options)
                var found: [(asset: PHAsset, filename: String)] = []
                result.enumerateObjects { asset, _, _ in
                    guard let resource = self.rawResource(for: asset) else { return }
                    found.append((asset, resource.originalFilename))
                }
                continuation.resume(returning: found)
            }
        }
    }

    private static func rawResource(for asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        }
    }

    @discardableResult
    func importPhotos(_ urls: [URL]) -> ImportReport {
        var report = ImportReport()
        isImporting = true
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let photo = try store.importPhoto(from: url)
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
        for assetID in assetIDs where assetFavorites.contains(assetID) {
            setAssetFavorite(assetID: assetID, value: false)
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

    func setFavorite(photoID: String, value: Bool) {
        mutate(photoID: photoID) { $0.favorite = value }
    }

    /// 未入库相册 RAW 的收藏：只落本地偏好，不在相册或库里产生任何改动。
    func setAssetFavorite(assetID: String, value: Bool) {
        if value {
            assetFavorites.insert(assetID)
        } else {
            assetFavorites.remove(assetID)
        }
        UserDefaults.standard.set(Array(assetFavorites).sorted(),
                                  forKey: Self.assetFavoritesKey)
    }

    func isFavorite(_ asset: MLibraryAsset) -> Bool {
        asset.photo?.favorite ?? assetFavorites.contains(asset.id)
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
        for photo in store.photos where photo.thumbnailPath == nil {
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
                                                     rotationTurns: edit.rotationTurns),
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
    func openGrade(photoID: String, entry: MGradeEntry) -> MobileGradeSession? {
        guard let photo = store.photos.first(where: { $0.id == photoID }) else { return nil }
        let develop: MobileDevelopSession
        if let current = developSession, current.photoID == photoID {
            develop = current
            current.finish()
        } else {
            develop = MobileDevelopSession(photo: photo, store: store)
            develop.start()
        }
        let grade = MobileGradeSession(photo: photo, store: store, develop: develop)
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
