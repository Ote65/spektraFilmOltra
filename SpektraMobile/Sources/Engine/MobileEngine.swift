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

    private let thumbnailQueue = DispatchQueue(label: "spektra.mobile.thumb", qos: .utility)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spektrafilm/MobileLibrary", isDirectory: true)
        store = LibraryStore(root: base)
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

    func setFavorite(photoID: String, value: Bool) {
        mutate(photoID: photoID) { $0.favorite = value }
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
        return MPhoto(
            id: photo.id,
            filename: photo.filename,
            film: MobileCatalog.filmName(photo.edit.filmStock),
            paper: MobileCatalog.paperName(photo.edit.printStock),
            dimensions: photo.width > 0 ? "\(photo.width)×\(photo.height)" : "",
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
            guard let loaded = try? ImageLoader.load(url: url, maxSize: 320, rawOptions: options),
                  var params = try? edit.runtimeParams() else { return }
            params.io.inputColorSpace = loaded.colorSpace
            params.io.inputCCTFDecoding = loaded.cctfDecoding
            let small = Resize.smallPreview(loaded.image, maxSize: 320)
            let output = SimulationPipeline(params: params, keepTaps: false).process(small).rgbOut
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
        developSession = nil
        refreshPhotos()
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
