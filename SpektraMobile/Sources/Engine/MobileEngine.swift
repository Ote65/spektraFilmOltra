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

    /// 上次成功扫描的相册快照：冷启动先出列表，再后台刷新。
    struct AlbumSnapshot: Codable, Sendable {
        let id: String
        let filename: String
        let isRaw: Bool
    }
    /// 按范围缓存的扫描结果：所有写入都必须带上写入时的 generation。
    private struct AssetCacheKey: Hashable {
        let scope: MAssetScope
        let allowNonRaw: Bool
    }
    /// 一次扫描产出的资产信息：包含来源分类与是否需要 EXIF 精修。
    private struct ScannedAsset {
        let asset: PHAsset
        let filename: String
        let isRaw: Bool
        let included: Bool
        let isCaptured: Bool
        let needsProbe: Bool
    }

    /// 相册映射的内存索引：范围缓存、快照复用表、EXIF 来源覆盖与变更代数收在一起。
    /// 缓存写入只走 `store`，并显式携带 generation，避免不同路径用不同 token
    /// 把旧列表当成新数据（此前来源精修写回就出现过这个问题）。
    private struct AlbumIndex {
        struct ScopeEntry {
            var assets: [MLibraryAsset]
            let generation: Int
        }

        private(set) var generation = 0
        private(set) var scopes: [AssetCacheKey: ScopeEntry] = [:]
        private(set) var snapshotLookup: [String: AlbumSnapshot] = [:]
        private(set) var captureOverrides: [String: Bool] = [:]

        mutating func markLibraryChanged() { generation &+= 1 }
        mutating func resetScopes() { scopes.removeAll() }

        func entry(_ scope: MAssetScope, allowNonRaw: Bool) -> ScopeEntry? {
            scopes[AssetCacheKey(scope: scope, allowNonRaw: allowNonRaw)]
        }

        mutating func store(_ assets: [MLibraryAsset], for scope: MAssetScope,
                            allowNonRaw: Bool, generation: Int) {
            scopes[AssetCacheKey(scope: scope, allowNonRaw: allowNonRaw)] =
                ScopeEntry(assets: assets, generation: generation)
        }

        mutating func setSnapshot(_ list: [AlbumSnapshot]) {
            snapshotLookup = Dictionary(
                list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        mutating func setOverrides(_ values: [String: Bool]) {
            captureOverrides = values
        }

        mutating func mergeOverrides(_ results: [String: Bool]) {
            captureOverrides.merge(results) { _, new in new }
        }

        /// 丢掉已不存在照片的精修结果；返回是否发生变化。
        mutating func pruneOverrides(keeping ids: Set<String>) -> Bool {
            let pruned = captureOverrides.filter { ids.contains($0.key) }
            guard pruned.count != captureOverrides.count else { return false }
            captureOverrides = pruned
            return true
        }

        /// 把精修结果同步到所有已缓存范围，保持列表中的来源标记一致。
        mutating func applyCaptureFlags(_ results: [String: Bool]) {
            for key in Array(scopes.keys) {
                guard var entry = scopes[key] else { continue }
                var changed = false
                for index in entry.assets.indices {
                    guard let captured = results[entry.assets[index].id] else { continue }
                    entry.assets[index].isCaptured = captured
                    entry.assets[index].captureNeedsProbe = false
                    changed = true
                }
                if changed { scopes[key] = entry }
            }
        }
    }

    private var index = AlbumIndex()
    private var captureOverrideURL: URL {
        store.root.appendingPathComponent("capture-origins.json")
    }
    /// 本次会话最多精修多少张模糊照片，避免首次进入筛选时读太多原图。
    private var captureRefineBudget = 240
    /// 快照只在本次会话恢复一次，避免并发刷新重复读盘。
    private var didRestoreSnapshot = false
    /// 正在执行的刷新数量：有强制刷新在飞时，不允许另一次缓存命中把它顶掉。
    private var refreshInFlight = 0
    private let photoObserver = MPhotoLibraryObserver()
    private var observerRegistered = false
    private var snapshotURL: URL {
        store.root.appendingPathComponent("album-snapshot.json")
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spektrafilm/MobileLibrary", isDirectory: true)
        store = LibraryStore(root: base, keepsEncodedRecords: true)
        loadCaptureOverrides()
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
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let allowed = ImageLoader.rawSuffixes.contains(ext)
            || (MobileSettings.allowNonRaw
                && MAssetFormat.isAllowed(filename: url.lastPathComponent, isRaw: false))
        guard allowed else { return }
        guard let photo = try? store.importPhoto(
            from: url, allowingEncoded: MobileSettings.allowNonRaw
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
                guard MAssetFormat.isAllowed(originalPath: $0.originalPath) else { return false }
                let ext = URL(fileURLWithPath: $0.originalPath).pathExtension.lowercased()
                if ImageLoader.rawSuffixes.contains(ext) { return true }
                return allowNonRaw
            }
            .sorted { $0.importedAt > $1.importedAt }
            .map(makePhoto)
        relinkAssets()
    }

    // MARK: - 相册映射

    /// 切换主页筛选：已有缓存时立即出列表，只有相册真的变化过才后台重扫。
    func selectScope(_ newScope: MAssetScope) {
        guard scope != newScope else { return }
        scope = newScope
        let allowNonRaw = MobileSettings.allowNonRaw
        if let cached = index.entry(newScope, allowNonRaw: allowNonRaw) {
            apply(cached.assets)
            assetPhase = .ready
            if cached.generation == index.generation { return }
        }
        Task { await refreshAssets() }
    }

    /// 关闭「支持 JPEG」后拍摄/保存筛选不再有入口：把当前范围回落到全部，
    /// 避免按钮消失但列表仍按隐藏范围过滤。
    func resetOriginScopeIfNeeded() {
        guard !MobileSettings.allowNonRaw, scope.isOriginFilter else { return }
        scope = .all
    }

    /// 直接映射系统相册：RAW 用系统 RAW 智能相簿，收藏用系统收藏相簿，
    /// 其余按用户相簿取图。不做逐张 EXIF 扫描，切筛选不额外读盘。
    /// 主页打开就调这个：不需要先「导入」，相册里的照片直接可浏览。
    /// - `force == false`：无变化时直接吃缓存；冷启动先出快照，再后台刷新。
    /// - `force == true`：下拉刷新、权限/开关变化、导入或收藏/删除后强制重扫。
    func refreshAssets(force: Bool = false) async {
        refreshInFlight += 1
        defer { refreshInFlight -= 1 }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            assets = []
            assetPhase = .denied
            index.resetScopes()
            return
        }
        ensurePhotoObserver()
        assetRefreshToken += 1
        let token = assetRefreshToken
        let scope = self.scope
        let fetchScope: MAssetScope = scope.isOriginFilter ? .all : scope
        let allowNonRaw = MobileSettings.allowNonRaw
        NSLog("MAssets refresh force=%d scope=%@", force ? 1 : 0, String(describing: scope))

        // 冷启动：先用上次的快照出列表，扫描在后台继续。
        if assets.isEmpty, fetchScope == .all, await restoreSnapshotIfNeeded() {
            assets = filterOrigin(assets, for: scope)
            assetPhase = .ready
        }

        // 相册没有变化时直接复用上一次的扫描结果，不再全量重扫。
        // 只在本次是唯一刷新时允许命中，避免把正在进行的强制刷新顶掉。
        if !force, refreshInFlight == 1 {
            if scope.isOriginFilter,
               let cachedAll = index.entry(.all, allowNonRaw: allowNonRaw),
               cachedAll.generation == index.generation {
                assets = filterOrigin(cachedAll.assets, for: scope)
                index.store(assets, for: scope, allowNonRaw: allowNonRaw,
                            generation: cachedAll.generation)
                assetPhase = .ready
                NSLog("MAssets cache hit scope=%@ count=%d",
                      String(describing: scope), assets.count)
                refineCaptureOrigins(cachedAll.assets)
                return
            }
            if let cached = index.entry(scope, allowNonRaw: allowNonRaw),
               cached.generation == index.generation {
                apply(cached.assets)
                assetPhase = .ready
                NSLog("MAssets cache hit scope=%@ count=%d",
                      String(describing: scope), assets.count)
                return
            }
        }
        loadAlbums()

        // 有旧结果就先展示，避免刷新期间列表闪空。
        if assets.isEmpty, let cached = index.entry(scope, allowNonRaw: allowNonRaw) {
            apply(cached.assets)
        }
        assetPhase = assets.isEmpty ? .scanning : .ready

        if case .graded = scope {
            assets = gradedAssets()
            assetPhase = .ready
            return
        }

        let scanToken = index.generation
        let scanned = await Self.fetchAssets(scope: fetchScope,
                                             allowNonRaw: allowNonRaw,
                                             known: index.snapshotLookup,
                                             overrides: index.captureOverrides)
        // 旧扫描晚回来时丢弃，避免列表被过期结果覆盖。
        guard token == assetRefreshToken else { return }
        let byName = Dictionary(
            store.photos.map { ($0.filename, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let visible = scanned.filter { $0.included }
        for item in visible {
            phAssetByFilename[item.filename] = item.asset
        }
        let built = visible.map { item in
            MLibraryAsset(
                id: item.asset.localIdentifier,
                filename: item.filename,
                photo: byName[item.filename].map(makePhoto),
                phAsset: item.asset,
                isCaptured: item.isCaptured,
                captureNeedsProbe: item.needsProbe
            )
        }
        if fetchScope == .all {
            index.store(built, for: .all, allowNonRaw: allowNonRaw, generation: scanToken)
            saveSnapshot(scanned)
            pruneCaptureOverrides(keeping: Set(scanned.map { $0.asset.localIdentifier }))
            NSLog("MAssets origin captured=%d saved=%d needsProbe=%d",
                  built.filter(\.isCaptured).count,
                  built.filter { !$0.isCaptured }.count,
                  built.filter(\.captureNeedsProbe).count)
        }
        assets = filterOrigin(built, for: scope)
        index.store(assets, for: scope, allowNonRaw: allowNonRaw, generation: scanToken)
        assetPhase = .ready
        NSLog("MAssets scope=%@ count=%d", String(describing: scope), assets.count)
        if scope.isOriginFilter {
            refineCaptureOrigins(built)
        }
    }

    /// 拍摄/保存是在「全部」列表上的来源过滤，不额外请求 PhotoKit。
    private func filterOrigin(_ list: [MLibraryAsset], for scope: MAssetScope) -> [MLibraryAsset] {
        switch scope {
        case .captured: return list.filter(\.isCaptured)
        case .saved: return list.filter { !$0.isCaptured }
        default: return list
        }
    }

    /// 应用缓存结果：保留 PHAsset 本体，重新接上当前库内记录。
    private func apply(_ cached: [MLibraryAsset]) {
        assets = cached
        for item in cached {
            if let asset = item.phAsset {
                phAssetByFilename[item.filename] = asset
            }
        }
        relinkAssets()
    }

    // MARK: - 相册快照与变更监听

    /// 只读上次快照并一次性取回 PHAsset；不触发全量资源探测。
    private func restoreSnapshotIfNeeded() async -> Bool {
        guard !didRestoreSnapshot, assets.isEmpty,
              scope == .all || scope.isOriginFilter else { return false }
        didRestoreSnapshot = true
        let url = snapshotURL
        let list: [AlbumSnapshot] = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([AlbumSnapshot].self, from: data) else {
                return []
            }
            return decoded
        }.value
        // 读盘期间用户可能已切到别的范围：只在仍需要全量列表时应用快照。
        guard !list.isEmpty, scope == .all || scope.isOriginFilter else { return false }
        index.setSnapshot(list)

        let allowNonRaw = MobileSettings.allowNonRaw
        let overrides = index.captureOverrides
        // makePhoto 只读库内记录，提前在主线程生成；后台只做 PhotoKit 抓取与分类。
        let photosByName = Dictionary(
            store.photos.map { ($0.filename, makePhoto($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        // 抓取、枚举与逐张分类都移到后台：快照条数等于整库条数，
        // 放在主线程会直接拖慢冷启动首帧。
        let restored: [MLibraryAsset] = await Task.detached(priority: .userInitiated) {
            let usable = list.filter {
                (allowNonRaw || $0.isRaw)
                    && MAssetFormat.isAllowed(filename: $0.filename, isRaw: $0.isRaw)
            }
            guard !usable.isEmpty else { return [] }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: usable.map(\.id), options: nil)
            var byID: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
            return usable.compactMap { item -> MLibraryAsset? in
                guard let asset = byID[item.id] else { return nil }
                let verdict = MCaptureClassifier.classify(
                    asset: asset, filename: item.filename, isRaw: item.isRaw)
                let override = overrides[item.id]
                return MLibraryAsset(
                    id: item.id, filename: item.filename,
                    photo: photosByName[item.filename], phAsset: asset,
                    isCaptured: override ?? verdict.isCaptured,
                    captureNeedsProbe: override == nil && !verdict.confident
                )
            }
        }.value
        guard !restored.isEmpty else { return false }
        assets = restored
        for item in restored {
            if let asset = item.phAsset {
                phAssetByFilename[item.filename] = asset
            }
        }
        NSLog("MAssets snapshot restored count=%d", restored.count)
        return true
    }

    /// 刷新成功后落盘，供下次冷启动秒开；只写 id / 文件名 / 是否 RAW。
    private func saveSnapshot(_ scanned: [ScannedAsset]) {
        let list = scanned.map {
            AlbumSnapshot(id: $0.asset.localIdentifier,
                          filename: $0.filename, isRaw: $0.isRaw)
        }
        index.setSnapshot(list)
        let url = snapshotURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 相册内容变化时只递增变更代数、让范围缓存失效；下一次前台/切筛选再后台重扫。
    fileprivate func handlePhotoLibraryChange() {
        index.markLibraryChanged()
        NSLog("MAssets library changed token=%d", index.generation)
    }

    // MARK: - 来源分类缓存与 EXIF 精修

    private func loadCaptureOverrides() {
        guard let data = try? Data(contentsOf: captureOverrideURL),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return
        }
        index.setOverrides(decoded)
    }

    private func persistCaptureOverrides() {
        let snapshot = index.captureOverrides
        let url = captureOverrideURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 全量扫描后丢掉已不存在照片的精修结果。
    private func pruneCaptureOverrides(keeping ids: Set<String>) {
        guard index.pruneOverrides(keeping: ids) else { return }
        persistCaptureOverrides()
    }

    /// 只对文件名/子类型无法确定的照片读 EXIF；每会话有预算，结果落盘。
    private func refineCaptureOrigins(_ allAssets: [MLibraryAsset]) {
        guard captureRefineBudget > 0 else { return }
        let probes = allAssets.filter { $0.captureNeedsProbe && $0.phAsset != nil }
        guard !probes.isEmpty else { return }
        let batch = Array(probes.prefix(captureRefineBudget))
        captureRefineBudget -= batch.count
        let items: [(String, PHAsset)] = batch.compactMap { item in
            guard let asset = item.phAsset else { return nil }
            return (item.id, asset)
        }
        guard !items.isEmpty else { return }
        NSLog("MAssets capture refine count=%d", items.count)

        Task.detached(priority: .utility) { [weak self] in
            var results: [String: Bool] = [:]
            let lock = NSLock()
            var next = 0
            DispatchQueue.concurrentPerform(iterations: min(2, items.count)) { _ in
                while true {
                    lock.lock()
                    let index = next
                    next += 1
                    lock.unlock()
                    guard index < items.count else { return }
                    if let captured = Self.probeCaptureEXIF(asset: items[index].1) {
                        lock.lock()
                        results[items[index].0] = captured
                        lock.unlock()
                    }
                }
            }
            let capturedResults = results
            await MainActor.run { [weak self] in
                self?.applyCaptureOverrides(capturedResults)
            }
        }
    }

    /// 相机 EXIF 判定：厂商/机型/光学参数/拍摄时间至少命中两项才算拍摄。
    private nonisolated static func probeCaptureEXIF(asset: PHAsset) -> Bool? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        var captured: Bool?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
            data, _, _, _ in
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [String: Any] else { return }
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let make = (tiff?[kCGImagePropertyTIFFMake as String] as? String) ?? ""
            let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String) ?? ""
            let lens = (exif?[kCGImagePropertyExifLensModel as String] as? String) ?? ""
            let exposure = (exif?[kCGImagePropertyExifExposureTime as String] as? Double) ?? 0
            let fnumber = (exif?[kCGImagePropertyExifFNumber as String] as? Double) ?? 0
            let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]) ?? []
            let dateOriginal =
                (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String) ?? ""
            var score = 0
            if !make.isEmpty { score += 1 }
            if !model.isEmpty { score += 1 }
            if !lens.isEmpty || exposure > 0 || fnumber > 0 || !iso.isEmpty { score += 1 }
            if !dateOriginal.isEmpty { score += 1 }
            captured = score >= 2
        }
        return captured
    }

    private func applyCaptureOverrides(_ results: [String: Bool]) {
        guard !results.isEmpty else { return }
        index.mergeOverrides(results)
        persistCaptureOverrides()

        var updated = assets
        for i in updated.indices {
            guard let captured = results[updated[i].id] else { continue }
            updated[i].isCaptured = captured
            updated[i].captureNeedsProbe = false
        }
        assets = updated
        index.applyCaptureFlags(results)

        let allowNonRaw = MobileSettings.allowNonRaw
        if scope.isOriginFilter, let all = index.entry(.all, allowNonRaw: allowNonRaw) {
            assets = filterOrigin(all.assets, for: scope)
            // 复用来源列表的 generation，不能用当前代数：精修在飞时相册可能已经变化，
            // 否则旧列表会被标记成新数据，之后普通刷新会命中它而漏掉新照片。
            index.store(assets, for: scope, allowNonRaw: allowNonRaw,
                        generation: all.generation)
        }
    }

    private func ensurePhotoObserver() {
        guard !observerRegistered else { return }
        PHPhotoLibrary.shared().register(photoObserver)
        photoObserver.engine = self
        observerRegistered = true
    }

    deinit {
        if observerRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(photoObserver)
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
            .filter { MAssetFormat.isAllowed(originalPath: $0.originalPath) }
            .filter { !$0.edit.quickIntents.isEmpty }
            .sorted { $0.importedAt > $1.importedAt }
            .map {
                let verdict = MCaptureClassifier.classify(
                    filename: $0.filename,
                    isRaw: ImageLoader.rawSuffixes.contains(
                        URL(fileURLWithPath: $0.originalPath).pathExtension.lowercased()))
                return MLibraryAsset(
                    id: $0.id, filename: $0.filename,
                    photo: makePhoto($0), phAsset: nil,
                    isCaptured: verdict.isCaptured,
                    captureNeedsProbe: !verdict.confident)
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
                                     photo: nil, phAsset: asset.phAsset,
                                     isCaptured: asset.isCaptured,
                                     captureNeedsProbe: asset.captureNeedsProbe)
            }
            return MLibraryAsset(id: asset.id, filename: asset.filename,
                                 photo: makePhoto(photo), phAsset: asset.phAsset,
                                 isCaptured: asset.isCaptured,
                                 captureNeedsProbe: asset.captureNeedsProbe)
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
        guard let info = Self.displayResource(for: asset,
                                              allowNonRaw: MobileSettings.allowNonRaw) else {
            return nil
        }
        let resource = info.resource

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
    /// `known` 提供上次快照的文件名与 RAW 判定，命中时跳过昂贵的 `PHAssetResource` 探测。
    /// `overrides` 是已经 EXIF 精修过的来源结果，优先于快速规则。
    nonisolated private static func fetchAssets(
        scope: MAssetScope, allowNonRaw: Bool,
        known: [String: AlbumSnapshot], overrides: [String: Bool]
    ) async -> [ScannedAsset] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result: PHFetchResult<PHAsset>
                switch scope {
                case .all, .graded, .captured, .saved:
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
                var found: [ScannedAsset] = []
                var seen = Set<String>()
                result.enumerateObjects { asset, _, _ in
                    // 主页用 localIdentifier 当卡片身份，重复项会让网格重复渲染同一张照片。
                    guard seen.insert(asset.localIdentifier).inserted else { return }
                    let filename: String
                    let isRaw: Bool
                    if let cached = known[asset.localIdentifier] {
                        filename = cached.filename
                        isRaw = cached.isRaw
                    } else {
                        guard let info = scanResource(for: asset) else { return }
                        filename = info.resource.originalFilename
                        isRaw = info.isRaw
                    }
                    // 只允许 RAW / JPEG / HEIC；PNG、GIF、WebP、TIFF 在任何筛选里都不出现。
                    guard MAssetFormat.isAllowed(filename: filename, isRaw: isRaw) else { return }
                    let verdict = MCaptureClassifier.classify(
                        asset: asset, filename: filename, isRaw: isRaw)
                    let override = overrides[asset.localIdentifier]
                    found.append(ScannedAsset(
                        asset: asset,
                        filename: filename,
                        isRaw: isRaw,
                        included: allowNonRaw || isRaw,
                        isCaptured: override ?? verdict.isCaptured,
                        needsProbe: override == nil && !verdict.confident
                    ))
                }
                continuation.resume(returning: found)
            }
        }
    }

    /// 扫描用：优先 RAW，其次 JPEG / HEIC 等编码图；返回资源与是否 RAW，是否展示交给调用方。
    private nonisolated static func scanResource(
        for asset: PHAsset
    ) -> (resource: PHAssetResource, isRaw: Bool)? {
        let resources = PHAssetResource.assetResources(for: asset)
        let raw = resources.first {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        }
        let encoded = resources.filter {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .image) == true
                && isAllowedEncodedResource($0)
        }
        let jpeg = encoded.first {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .jpeg) == true
        }
        guard let chosen = raw ?? jpeg ?? encoded.first else { return nil }
        return (chosen, raw != nil)
    }

    /// 编码图只收 JPEG / HEIC(HEIF)；PNG、GIF、WebP、TIFF 一律不进入主页或导入。
    private nonisolated static func isAllowedEncodedResource(_ resource: PHAssetResource) -> Bool {
        guard let type = UTType(resource.uniformTypeIdentifier) else {
            return MAssetFormat.isAllowed(filename: resource.originalFilename, isRaw: false)
        }
        return type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// 主页可见的本体：RAW 一律收；打开「支持 JPEG」后收 JPEG / HEIC(HEIF)；
    /// 关闭时非 RAW 全部不收。PNG、GIF、WebP、TIFF 在任何筛选里都不出现。
    private nonisolated static func displayResource(
        for asset: PHAsset, allowNonRaw: Bool
    ) -> (resource: PHAssetResource, isRaw: Bool)? {
        let resources = PHAssetResource.assetResources(for: asset)
        if let raw = resources.first(where: {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        }) {
            return (raw, true)
        }
        guard allowNonRaw else { return nil }
        let encoded = resources.filter {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .image) == true
                && isAllowedEncodedResource($0)
        }
        // 优先 JPEG；没有 JPEG 时用 HEIC / HEIF。
        let jpeg = encoded.first {
            UTType($0.uniformTypeIdentifier)?.conforms(to: .jpeg) == true
        }
        guard let chosen = jpeg ?? encoded.first else { return nil }
        return (chosen, false)
    }

    /// 导入照片：文件复制与头部探测在后台串行完成，主线程只提交库状态与刷新列表。
    /// 新入库的原片随后异步写进系统相册（`publishToAlbum`），主页按相册映射才能看到它们。
    @discardableResult
    func importPhotos(_ urls: [URL], publishToAlbum: Bool = true) async -> ImportReport {
        var report = ImportReport()
        guard !urls.isEmpty else { return report }

        // 移动端只导入 RAW / JPEG / HEIC(HEIF)；PNG、GIF、WebP、TIFF 直接拒绝。
        let allowingEncoded = MobileSettings.allowNonRaw
        var accepted: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let isRaw = ImageLoader.rawSuffixes.contains(ext)
            let allowed = isRaw
                || (allowingEncoded && MAssetFormat.isAllowed(
                    filename: url.lastPathComponent, isRaw: false))
            if allowed {
                accepted.append(url)
            } else {
                report.rejected += 1
                if report.reason.isEmpty {
                    report.reason = "\(url.lastPathComponent)：只支持 RAW / JPEG / HEIC"
                }
            }
        }
        guard !accepted.isEmpty else { return report }

        isImporting = true
        defer { isImporting = false }

        let store = self.store
        let staged = await Self.stageImports(
            accepted, allowingEncoded: allowingEncoded, store: store)
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
            // 整批共用一个临时根目录，结束后一次清理；每张仍放在独立子目录里，
            // 既保证同名文件不互相覆盖，也让中断时最多遗留一个 album-* 目录。
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("album-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            for photo in imported {
                let source = store.originalURL(for: photo)
                let filename = photo.filename
                guard let temp = await Task.detached(priority: .utility, operation: {
                    Self.prepareAlbumFile(source: source, filename: filename, root: root)
                }).value else { continue }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    PhotoLibraryExport.save(temp) { _ in
                        continuation.resume()
                    }
                }
            }
            await self.refreshAssets(force: true)
        }
    }

    /// 相册写入要求文件名保持原样，主页按 originalFilename 把资产映射回库内记录。
    /// 每张文件放在批次根目录下的独立子目录里，避免同名文件互相覆盖。
    private nonisolated static func prepareAlbumFile(
        source: URL, filename: String, root: URL
    ) -> URL? {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(filename)
        guard (try? FileManager.default.copyItem(at: source, to: temp)) != nil else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return temp
    }

    func remove(photoID: String) {
        remove(photoIDs: [photoID])
    }

    /// 批量删除库内记录：一次移除、只同步落盘一次，再清缩略图缓存。
    func remove(photoIDs: [String]) {
        guard !photoIDs.isEmpty else { return }
        for photoID in photoIDs {
            if let photo = store.photos.first(where: { $0.id == photoID }),
               let thumbnail = store.thumbnailURL(for: photo) {
                // 缓存键是缩略图的绝对路径，不能传索引里的相对路径。
                MThumbnailCache.shared.remove(path: thumbnail.path)
            }
        }
        try? store.remove(ids: photoIDs)
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
        // 同一次删除只落盘一次；逐张 remove 会让每条记录都做一次整库编码。
        remove(photoIDs: photoIDs)
        await refreshAssets(force: true)
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
        await refreshAssets(force: true)
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

    /// 批量补缩略图时避免每张都全量重建主页列表：固定 0.12 秒合并一帧。
    /// 不能每次完成都取消重排，否则连续完成会把刷新无限顺延。
    private func refreshPhotosSoon() {
        guard refreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refreshPhotos()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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

// MARK: - 相册变更监听

/// PhotoKit 的变更回调可能来自任意队列，这里只把「相册有变化」通知回主线程。
private final class MPhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    weak var engine: MobileEngine?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak engine] in
            engine?.handlePhotoLibraryChange()
        }
    }
}
